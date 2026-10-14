#!/usr/bin/env python3
"""Fingerprint and verify local iOS build artifacts without contacting a device."""
import argparse
import hashlib
import ipaddress
import json
import plistlib
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    return digest(Path(path).read_bytes())


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def source(repo, configuration, bench, baseline):
    flags = (["DEBUG"] if configuration == "Debug" else [])
    if bench:
        flags.append("BEAROUND_ADAPTIVE_BENCH")
    if baseline:
        flags.append("BEAROUND_ADAPTIVE_BASELINE")
    files = [p for p in (repo / "BearoundSDK").rglob("*") if p.is_file() and p.name != ".DS_Store"]
    files.append(repo / "BearoundSDK.xcodeproj/project.pbxproj")
    if baseline:
        reference = "562254a025aee18fae73f683e0e1b3a690657b79"
        paths = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", reference, "BearoundSDK"], cwd=repo, text=True).splitlines()
        expected = set(paths + ["BearoundSDK.xcodeproj/project.pbxproj"])
        actual = {p.relative_to(repo).as_posix() for p in files}
        if actual != expected:
            raise ValueError("Baseline SDK file set differs from the frozen transport-only tree")
        for path in files:
            relative = path.relative_to(repo).as_posix()
            original = subprocess.check_output(["git", "show", reference + ":" + relative], cwd=repo)
            if file_hash(path) != digest(original):
                raise ValueError("Baseline SDK source differs from the frozen transport-only tree")
    inputs = {"schema": 1, "configuration": configuration, "benchEnabled": bench, "baseline": baseline,
              "swiftFlags": flags, "xcodeVersion": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
              "sources": [{"path": p.relative_to(repo).as_posix(), "sha256": file_hash(p)}
                          for p in sorted(files, key=lambda p: p.relative_to(repo).as_posix())]}
    return {**inputs, "sourceFingerprint": digest(canonical(inputs)),
            "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()}


def uuids(binary):
    output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(binary)], text=True)
    result = {arch: uuid.upper() for uuid, arch in re.findall(r"UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", output)}
    if not result:
        raise ValueError("Mach-O UUID is missing")
    return result


def read_plist(path):
    with Path(path).open("rb") as stream:
        return plistlib.load(stream)


def write_plist(path, value):
    with Path(path).open("wb") as stream:
        plistlib.dump(value, stream, fmt=plistlib.FMT_XML, sort_keys=False)


def local_endpoint(value):
    url = urlsplit(value)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ("", "/"):
        raise ValueError("Bench endpoint must be a trusted local HTTPS origin")
    host = url.hostname.lower()
    local = host == "localhost" or host.endswith(".local")
    try:
        address = ipaddress.ip_address(host)
        local = address.is_loopback or address in ipaddress.ip_network("10.0.0.0/8") or address in ipaddress.ip_network("172.16.0.0/12") or address in ipaddress.ip_network("192.168.0.0/16") or address in ipaddress.ip_network("fc00::/7") or address in ipaddress.ip_network("fe80::/10")
    except ValueError:
        pass
    if not local:
        raise ValueError("Bench endpoint host must be loopback, private LAN, or .local")
    if url.port == 0:
        raise ValueError("Bench endpoint port must be positive")
    return value.rstrip("/")


def host_info(args):
    endpoint = local_endpoint(args.endpoint)
    if not re.fullmatch(r"fixture-[A-Za-z0-9_-]+", args.fixture_token) or not re.fullmatch(r"fixture-[A-Za-z0-9_-]+", args.fixture_user):
        raise ValueError("Bench token and user must use the synthetic fixture- prefix")
    if args.baseline and args.adaptive == "true":
        raise ValueError("Pre-change baseline cannot enable adaptive sampling")
    data = read_plist(args.input)
    data.update({"BEAROUND_ADAPTIVE_BENCH": True, "BEAROUND_ADAPTIVE_BENCH_ENDPOINT": endpoint,
                 "BEAROUND_ADAPTIVE_BENCH_TOKEN": args.fixture_token, "BEAROUND_ADAPTIVE_BENCH_USER": args.fixture_user,
                 "BEAROUND_ADAPTIVE_BENCH_ENABLED": args.adaptive == "true",
                 "BEAROUND_ADAPTIVE_BENCH_BASELINE": args.baseline})
    # Existing host permissions remain unchanged; no Motion key or TLS exception is added.
    write_plist(args.output, data)


def stamp(args):
    value = source(args.repo, args.configuration, args.bench, args.baseline)
    value.update({"builtAt": datetime.now(timezone.utc).isoformat(), "frameworks": [],
                  "buildSettings": {"BUILD_LIBRARY_FOR_DISTRIBUTION": "YES", "CODE_SIGNING_ALLOWED": "NO"}})
    for name, path in zip(["device", "simulator"], args.framework):
        binary = path / "BearoundSDK"
        plist = path / "Info.plist"
        data = read_plist(plist)
        data.update({"BEAROUND_SOURCE_FINGERPRINT": value["sourceFingerprint"],
                     "BEAROUND_SOURCE_COMMIT": value["sourceCommit"],
                     "BEAROUND_BUILD_CONFIGURATION": args.configuration,
                     "BEAROUND_ADAPTIVE_BENCH": args.bench,
                     "BEAROUND_ADAPTIVE_BASELINE": args.baseline,
                     "BEAROUND_SWIFT_FLAGS": value["swiftFlags"]})
        write_plist(plist, data)
        value["frameworks"].append({"kind": name, "machOUUID": uuids(binary), "binarySHA256": file_hash(binary)})
    args.output.write_text(json.dumps(value, indent=2) + "\n")


def check_source(args):
    expected = source(args.repo, args.configuration, args.bench, args.baseline)
    value = json.loads(args.manifest.read_text())
    if value["sourceFingerprint"] != expected["sourceFingerprint"]:
        raise ValueError("Framework source/configuration/flags fingerprint is stale")
    plist = read_plist(args.framework / "Info.plist")
    if plist.get("BEAROUND_SOURCE_FINGERPRINT") != expected["sourceFingerprint"]:
        raise ValueError("Framework plist fingerprint does not match its frozen manifest")
    device = next(row for row in value["frameworks"] if row["kind"] == "device")
    if uuids(args.framework / "BearoundSDK") != device["machOUUID"] or file_hash(args.framework / "BearoundSDK") != device["binarySHA256"]:
        raise ValueError("Framework Mach-O does not match its frozen manifest")
    return value


def verify_app(args):
    value = check_source(args)
    embedded = args.app / "Frameworks/BearoundSDK.framework"
    plist = read_plist(embedded / "Info.plist")
    expected_uuid = next(row["machOUUID"] for row in value["frameworks"] if row["kind"] == "device")
    if plist.get("BEAROUND_SOURCE_FINGERPRINT") != value["sourceFingerprint"] or uuids(embedded / "BearoundSDK") != expected_uuid:
        raise ValueError("Embedded framework fingerprint or Mach-O UUID differs from the frozen build")
    if plist.get("BEAROUND_BUILD_CONFIGURATION") != args.configuration or plist.get("BEAROUND_ADAPTIVE_BENCH") != args.bench:
        raise ValueError("Embedded framework configuration or bench flag differs")
    host = read_plist(args.app / "Info.plist")
    bundle = host["CFBundleIdentifier"]
    if args.bench:
        if host.get("BEAROUND_ADAPTIVE_BENCH") is not True or not bundle.endswith(".adaptivebench"):
            raise ValueError("Bench app is missing the isolated bundle or explicit host opt-in")
        local_endpoint(host.get("BEAROUND_ADAPTIVE_BENCH_ENDPOINT", ""))
        if host.get("BEAROUND_ADAPTIVE_BENCH_BASELINE") != args.baseline:
            raise ValueError("Bench baseline flag differs")
        for key in ["BEAROUND_ADAPTIVE_BENCH_TOKEN", "BEAROUND_ADAPTIVE_BENCH_USER"]:
            if not re.fullmatch(r"fixture-[A-Za-z0-9_-]+", host.get(key, "")):
                raise ValueError("Embedded bench identity is not synthetic")
    elif host.get("BEAROUND_ADAPTIVE_BENCH") is True:
        raise ValueError("Normal build unexpectedly enables the bench")
    app_files = [p for p in (args.repo / "BeAroundScan/BeAroundScan").rglob("*") if p.is_file() and p.name != ".DS_Store"]
    app_files.append(args.repo / "BeAroundScan/BeAroundScan.xcodeproj/project.pbxproj")
    host_source = {"frameworkSourceFingerprint": value["sourceFingerprint"], "hostPlistSHA256": file_hash(args.app / "Info.plist"),
                   "sources": [{"path": p.relative_to(args.repo).as_posix(), "sha256": file_hash(p)} for p in sorted(app_files)]}
    executable = args.app / host["CFBundleExecutable"]
    proof = {"schema": 1, "sourceCommit": value["sourceCommit"], "configuration": args.configuration,
             "benchEnabled": args.bench, "baseline": args.baseline, "bundleIdentifier": bundle,
             "sourceFingerprint": value["sourceFingerprint"], "frameworkFingerprint": plist["BEAROUND_SOURCE_FINGERPRINT"],
             "appSourceFingerprint": digest(canonical(host_source)), "machOUUID": expected_uuid,
             "embeddedFramework": {"path": str(embedded / "BearoundSDK"), "sha256": file_hash(embedded / "BearoundSDK")},
             "binary": {"path": str(executable), "sha256": file_hash(executable)},
             "hostPlistSHA256": file_hash(args.app / "Info.plist"), "installation": {"status": "not_run"}}
    if args.bench:
        proof.update({"adaptiveEnabled": host["BEAROUND_ADAPTIVE_BENCH_ENABLED"],
                      "fixtureTokenSHA256": digest(host["BEAROUND_ADAPTIVE_BENCH_TOKEN"].encode())})
    args.output.write_text(json.dumps(proof, indent=2) + "\n")
    print("Embedded framework fingerprint and Mach-O UUID verified")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ["source", "stamp", "check-source", "verify-app"]:
        item = sub.add_parser(name)
        item.add_argument("--repo", type=Path, required=True)
        item.add_argument("--configuration", choices=["Debug", "Release"], required=True)
        item.add_argument("--bench", action="store_true")
        item.add_argument("--baseline", action="store_true")
        if name == "stamp":
            item.add_argument("--framework", type=Path, action="append", required=True)
            item.add_argument("--output", type=Path, required=True)
        elif name in ["check-source", "verify-app"]:
            item.add_argument("--framework", type=Path, required=True)
            item.add_argument("--manifest", type=Path, required=True)
            if name == "verify-app":
                item.add_argument("--app", type=Path, required=True)
                item.add_argument("--output", type=Path, required=True)
    host = sub.add_parser("host-info")
    for name in ["input", "output"]:
        host.add_argument("--" + name, type=Path, required=True)
    for name in ["endpoint", "fixture-token", "fixture-user"]:
        host.add_argument("--" + name, required=True)
    host.add_argument("--adaptive", choices=["true", "false"], required=True)
    host.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    if getattr(args, "bench", False) and args.configuration != "Debug":
        raise ValueError("Bench framework must use Debug")
    if getattr(args, "baseline", False) and hasattr(args, "bench") and not args.bench:
        raise ValueError("Baseline flag requires bench mode")
    if args.command == "source":
        print(source(args.repo, args.configuration, args.bench, args.baseline)["sourceFingerprint"])
    elif args.command == "stamp":
        if len(args.framework) != 2:
            raise ValueError("Exactly device and simulator frameworks are required")
        stamp(args)
    elif args.command == "check-source":
        check_source(args)
    elif args.command == "verify-app":
        verify_app(args)
    else:
        host_info(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        print("Build verification failed: " + str(error), file=sys.stderr)
        sys.exit(1)
