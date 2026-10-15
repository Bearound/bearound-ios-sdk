#!/usr/bin/env python3
"""Verify the app presence declarations of a built iOS app.

Reads the final ``Info.plist`` and the linked SDK (``LC_BUILD_VERSION``) of a built ``.app``,
checks the host's whole ``LSApplicationQueriesSchemes`` list against the scheme ceiling, and
verifies (or emits) the ``BeAroundAppPresenceBuildEvidence`` dictionary the SDK reads at
runtime to allow the 50-scheme ceiling.

Ceilings:
  * the platform allows 50 schemes for apps linked against an SDK older than iOS 27 and 25
    from iOS 27 on;
  * the BeAround runtime uses 25 unless the Info.plist carries evidence matching the bundle
    id, the linked SDK major (< 27) and the SHA-256 of the normalized scheme list.

Usage:
  verify_app_presence_build.py path/to/App.app [--report report.json] [--emit-evidence]

Exit codes: 0 conforming, 1 mismatch or budget exceeded, 2 unreadable input or tool error.
The script never modifies the app bundle (that would invalidate its signature): with
``--emit-evidence`` it prints the evidence dictionary to add to the source Info.plist.
"""

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys

EVIDENCE_KEY = "BeAroundAppPresenceBuildEvidence"
SCHEMES_KEY = "LSApplicationQueriesSchemes"
CONSERVATIVE_CEILING = 25
EXTENDED_CEILING = 50
REDUCED_CEILING_SDK_MAJOR = 27


class VerificationError(Exception):
    """Input could not be read (exit code 2)."""


def declared_schemes(info_plist):
    """Lowercased schemes in Info.plist order; non-string entries are ignored, like the SDK."""
    raw = info_plist.get(SCHEMES_KEY)
    if not isinstance(raw, list):
        return []
    return [entry.lower() for entry in raw if isinstance(entry, str)]


def schemes_sha256(schemes):
    """Same normalization as AppPresenceSchemeBudget.schemesSha256 in the SDK:
    lowercase, sorted (byte order), duplicates kept, joined with a newline, UTF-8, hex."""
    normalized = sorted((scheme.lower() for scheme in schemes), key=lambda value: value.encode("utf-8"))
    return hashlib.sha256("\n".join(normalized).encode("utf-8")).hexdigest()


def platform_ceiling(linked_sdk_major):
    return EXTENDED_CEILING if linked_sdk_major < REDUCED_CEILING_SDK_MAJOR else CONSERVATIVE_CEILING


def parse_linked_sdk_major(load_commands_output):
    """Extracts the linked SDK major from `vtool -show-build` / `otool -l` output.
    Fat binaries can report several slices; the highest SDK is the conservative choice."""
    majors = [int(match) for match in re.findall(r"^\s*sdk\s+(\d+)(?:\.\d+)*\s*$", load_commands_output, re.MULTILINE)]
    if not majors:
        raise VerificationError("no LC_BUILD_VERSION / LC_VERSION_MIN sdk entry found in the binary")
    return max(majors)


def read_linked_sdk_major(binary_path, runner=subprocess.run):
    """Reads the binary's load commands with Apple tools (vtool first, otool as fallback)."""
    errors = []
    for command in (["xcrun", "vtool", "-show-build", binary_path], ["xcrun", "otool", "-l", binary_path]):
        try:
            completed = runner(command, capture_output=True, text=True, check=False)
        except OSError as error:
            errors.append(f"{command[1]}: {error}")
            continue
        if completed.returncode == 0:
            try:
                return parse_linked_sdk_major(completed.stdout)
            except VerificationError as error:
                errors.append(f"{command[1]}: {error}")
        else:
            errors.append(f"{command[1]}: exit {completed.returncode}: {completed.stderr.strip()}")
    raise VerificationError("could not read the linked SDK: " + "; ".join(errors))


def load_info_plist(app_path):
    plist_path = os.path.join(app_path, "Info.plist")
    try:
        with open(plist_path, "rb") as handle:
            return plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise VerificationError(f"cannot read {plist_path}: {error}") from error


def build_evidence(bundle_id, linked_sdk_major, schemes):
    return {
        "bundleId": bundle_id,
        "linkedSdkMajor": linked_sdk_major,
        "schemesSha256": schemes_sha256(schemes),
    }


def verify(app_path, sdk_reader=read_linked_sdk_major):
    """Returns the report dictionary. `report["ok"]` is False on any mismatch."""
    info = load_info_plist(app_path)
    bundle_id = info.get("CFBundleIdentifier")
    executable = info.get("CFBundleExecutable")
    if not isinstance(bundle_id, str) or not bundle_id:
        raise VerificationError("Info.plist has no CFBundleIdentifier")
    if not isinstance(executable, str) or not executable:
        raise VerificationError("Info.plist has no CFBundleExecutable")

    linked_major = sdk_reader(os.path.join(app_path, executable))
    schemes = declared_schemes(info)
    expected = build_evidence(bundle_id, linked_major, schemes)
    platform_limit = platform_ceiling(linked_major)

    problems = []
    evidence_raw = info.get(EVIDENCE_KEY)
    evidence_status = "absent"
    if evidence_raw is not None:
        evidence_status = "valid"
        if not isinstance(evidence_raw, dict):
            evidence_status = "invalid"
            problems.append(f"{EVIDENCE_KEY} is not a dictionary")
        else:
            for field in ("bundleId", "linkedSdkMajor", "schemesSha256"):
                actual = evidence_raw.get(field)
                if field == "linkedSdkMajor" and (isinstance(actual, bool) or not isinstance(actual, int)):
                    evidence_status = "invalid"
                    problems.append(f"{EVIDENCE_KEY}.{field} must be an integer")
                    continue
                if field == "schemesSha256" and isinstance(actual, str):
                    actual = actual.lower()
                if actual != expected[field]:
                    evidence_status = "invalid"
                    problems.append(
                        f"{EVIDENCE_KEY}.{field} is {actual!r}, the final build has {expected[field]!r}"
                    )

    # Mirrors AppPresenceSchemeBudget.ceiling: 50 only with valid evidence and SDK < 27.
    runtime_limit = EXTENDED_CEILING if (evidence_status == "valid" and linked_major < REDUCED_CEILING_SDK_MAJOR) else CONSERVATIVE_CEILING

    if len(schemes) > platform_limit:
        problems.append(
            f"{SCHEMES_KEY} has {len(schemes)} entries; the linked SDK {linked_major} allows {platform_limit}"
        )
    if len(schemes) > runtime_limit:
        problems.append(
            f"{SCHEMES_KEY} has {len(schemes)} entries; the SDK runtime ceiling is {runtime_limit} "
            f"(evidence {evidence_status}), every iOS target would be unknown/scheme_budget_exceeded"
        )

    return {
        "ok": not problems,
        "app": os.path.abspath(app_path),
        "bundleId": bundle_id,
        "linkedSdkMajor": linked_major,
        "schemeCount": len(schemes),
        "platformCeiling": platform_limit,
        "runtimeCeiling": runtime_limit,
        "evidenceStatus": evidence_status,
        "expectedEvidence": expected,
        "problems": problems,
    }


def main(argv=None, sdk_reader=read_linked_sdk_major, stdout=sys.stdout, stderr=sys.stderr):
    parser = argparse.ArgumentParser(description="Verify app presence declarations of a built iOS app.")
    parser.add_argument("app", help="path to the built .app bundle")
    parser.add_argument("--report", help="write the JSON report to this path")
    parser.add_argument(
        "--emit-evidence",
        action="store_true",
        help=f"print the {EVIDENCE_KEY} dictionary (XML plist) for the source Info.plist",
    )
    args = parser.parse_args(argv)

    try:
        report = verify(args.app, sdk_reader=sdk_reader)
    except VerificationError as error:
        print(f"error: {error}", file=stderr)
        if args.report:
            with open(args.report, "w", encoding="utf-8") as handle:
                json.dump({"ok": False, "app": os.path.abspath(args.app), "error": str(error)}, handle, indent=2)
        return 2

    if args.report:
        with open(args.report, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)

    if args.emit_evidence:
        stdout.write(plistlib.dumps({EVIDENCE_KEY: report["expectedEvidence"]}).decode("utf-8"))
    for problem in report["problems"]:
        print(f"error: {problem}", file=stderr)
    if report["ok"]:
        print(
            f"app presence build OK: {report['schemeCount']} schemes, runtime ceiling {report['runtimeCeiling']}, "
            f"evidence {report['evidenceStatus']}",
            file=stderr,
        )
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
