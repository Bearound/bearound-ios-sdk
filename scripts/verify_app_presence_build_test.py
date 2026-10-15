#!/usr/bin/env python3
"""Tests for verify_app_presence_build.py (stdlib unittest, synthetic app bundles)."""

import hashlib
import io
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import verify_app_presence_build as verifier  # noqa: E402

BUNDLE_ID = "io.bearound.fixture.host"


def make_app(directory, schemes, evidence=None, extra=None):
    app = os.path.join(directory, "Host.app")
    os.makedirs(app, exist_ok=True)
    info = {"CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": "Host", SCHEMES_KEY: schemes}
    if evidence is not None:
        info[verifier.EVIDENCE_KEY] = evidence
    if extra:
        info.update(extra)
    with open(os.path.join(app, "Info.plist"), "wb") as handle:
        plistlib.dump(info, handle)
    with open(os.path.join(app, "Host"), "wb") as handle:
        handle.write(b"\0")
    return app


SCHEMES_KEY = verifier.SCHEMES_KEY


def sdk(major):
    return lambda _binary: major


class SchemesHashTest(unittest.TestCase):
    def test_matches_sdk_normalization_vector(self):
        # Same vector as AppPresenceModelsTests.schemesHashNormalized in the Swift SDK.
        expected = hashlib.sha256(b"a\nb").hexdigest()
        self.assertEqual(verifier.schemes_sha256(["b", "A"]), expected)
        self.assertEqual(verifier.schemes_sha256(["a", "B"]), expected)
        self.assertNotEqual(verifier.schemes_sha256(["a"]), expected)

    def test_duplicates_are_kept(self):
        self.assertEqual(verifier.schemes_sha256(["a", "a"]), hashlib.sha256(b"a\na").hexdigest())


class LinkedSdkParsingTest(unittest.TestCase):
    VTOOL = "Load command 10\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n platform IOS\n    minos 15.0\n      sdk 26.2\n   ntools 1\n"

    def test_parses_vtool_output(self):
        self.assertEqual(verifier.parse_linked_sdk_major(self.VTOOL), 26)

    def test_fat_binary_uses_highest_sdk(self):
        self.assertEqual(verifier.parse_linked_sdk_major(self.VTOOL + self.VTOOL.replace("26.2", "27.0")), 27)

    def test_missing_sdk_raises(self):
        with self.assertRaises(verifier.VerificationError):
            verifier.parse_linked_sdk_major("Load command 0\n cmd LC_SEGMENT_64\n")

    def test_reader_falls_back_to_otool(self):
        calls = []

        def runner(command, **_kwargs):
            calls.append(command[1])
            if command[1] == "vtool":
                return subprocess.CompletedProcess(command, 1, "", "unknown option")
            return subprocess.CompletedProcess(command, 0, self.VTOOL, "")

        self.assertEqual(verifier.read_linked_sdk_major("/tmp/Host", runner=runner), 26)
        self.assertEqual(calls, ["vtool", "otool"])


class VerifyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_main(self, app, *extra, major=26):
        report_path = os.path.join(self.tmp.name, "report.json")
        out, err = io.StringIO(), io.StringIO()
        code = verifier.main([app, "--report", report_path, *extra], sdk_reader=sdk(major), stdout=out, stderr=err)
        with open(report_path, encoding="utf-8") as handle:
            report = json.load(handle)
        return code, report, out.getvalue(), err.getvalue()

    def evidence(self, schemes, major=26, bundle_id=BUNDLE_ID):
        return {"bundleId": bundle_id, "linkedSdkMajor": major, "schemesSha256": verifier.schemes_sha256(schemes)}

    def test_within_conservative_ceiling_without_evidence_passes(self):
        schemes = [f"s{i}" for i in range(25)]
        code, report, _, _ = self.run_main(make_app(self.tmp.name, schemes))
        self.assertEqual(code, 0)
        self.assertTrue(report["ok"])
        self.assertEqual(report["evidenceStatus"], "absent")
        self.assertEqual(report["runtimeCeiling"], 25)
        self.assertEqual(report["schemeCount"], 25)

    def test_26_schemes_without_evidence_fails_runtime_ceiling(self):
        schemes = [f"s{i}" for i in range(26)]
        code, report, _, err = self.run_main(make_app(self.tmp.name, schemes))
        self.assertEqual(code, 1)
        self.assertFalse(report["ok"])
        self.assertIn("scheme_budget_exceeded", err)

    def test_valid_evidence_allows_50_before_sdk_27(self):
        schemes = [f"s{i}" for i in range(50)]
        code, report, _, _ = self.run_main(make_app(self.tmp.name, schemes, self.evidence(schemes)))
        self.assertEqual(code, 0)
        self.assertEqual(report["evidenceStatus"], "valid")
        self.assertEqual(report["runtimeCeiling"], 50)
        self.assertEqual(report["platformCeiling"], 50)

    def test_51_schemes_fail_even_with_evidence(self):
        schemes = [f"s{i}" for i in range(51)]
        code, report, _, _ = self.run_main(make_app(self.tmp.name, schemes, self.evidence(schemes)))
        self.assertEqual(code, 1)
        self.assertFalse(report["ok"])

    def test_sdk_27_drops_the_ceiling_to_25(self):
        schemes = [f"s{i}" for i in range(30)]
        app = make_app(self.tmp.name, schemes, self.evidence(schemes, major=27))
        code, report, _, _ = self.run_main(app, major=27)
        self.assertEqual(code, 1)
        self.assertEqual(report["platformCeiling"], 25)
        self.assertEqual(report["runtimeCeiling"], 25)

    def test_evidence_with_stale_scheme_hash_fails(self):
        schemes = ["bearound-presence-fixture"]
        app = make_app(self.tmp.name, schemes, self.evidence(["other-scheme"]))
        code, report, _, err = self.run_main(app)
        self.assertEqual(code, 1)
        self.assertEqual(report["evidenceStatus"], "invalid")
        self.assertIn("schemesSha256", err)

    def test_evidence_with_wrong_bundle_or_sdk_fails(self):
        schemes = ["bearound-presence-fixture"]
        for evidence in (self.evidence(schemes, bundle_id="io.bearound.other"), self.evidence(schemes, major=18)):
            with self.subTest(evidence=evidence):
                app = make_app(self.tmp.name, schemes, evidence)
                code, report, _, _ = self.run_main(app)
                self.assertEqual(code, 1)
                self.assertEqual(report["evidenceStatus"], "invalid")

    def test_boolean_sdk_major_is_rejected(self):
        schemes = ["bearound-presence-fixture"]
        evidence = self.evidence(schemes)
        evidence["linkedSdkMajor"] = True
        code, report, _, _ = self.run_main(make_app(self.tmp.name, schemes, evidence))
        self.assertEqual(code, 1)
        self.assertEqual(report["evidenceStatus"], "invalid")

    def test_emit_evidence_prints_matching_plist(self):
        schemes = ["Bearound-Presence-Fixture", "host-scheme"]
        code, report, out, _ = self.run_main(make_app(self.tmp.name, schemes), "--emit-evidence")
        self.assertEqual(code, 0)
        emitted = plistlib.loads(out.encode("utf-8"))[verifier.EVIDENCE_KEY]
        self.assertEqual(emitted, {"bundleId": BUNDLE_ID, "linkedSdkMajor": 26, "schemesSha256": verifier.schemes_sha256(schemes)})
        self.assertEqual(emitted, report["expectedEvidence"])

        # Feeding the emitted evidence back into the Info.plist verifies cleanly.
        code, report, _, _ = self.run_main(make_app(self.tmp.name, schemes, emitted))
        self.assertEqual(code, 0)
        self.assertEqual(report["evidenceStatus"], "valid")

    def test_unreadable_app_exits_2_with_report(self):
        missing = os.path.join(self.tmp.name, "Missing.app")
        code, report, _, _ = self.run_main(missing)
        self.assertEqual(code, 2)
        self.assertFalse(report["ok"])
        self.assertIn("error", report)

    def test_sdk_reader_failure_exits_2(self):
        app = make_app(self.tmp.name, ["a"])

        def failing(_binary):
            raise verifier.VerificationError("no load commands")

        out, err = io.StringIO(), io.StringIO()
        self.assertEqual(verifier.main([app], sdk_reader=failing, stdout=out, stderr=err), 2)
        self.assertIn("no load commands", err.getvalue())


if __name__ == "__main__":
    unittest.main()
