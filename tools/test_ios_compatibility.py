"""Exercise iOS compatibility gate decisions without Xcode or simulators."""

import copy
from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import verify_ios_compatibility as compatibility
from verify_ios_compatibility import GateError, select_destinations, validate_summary, validate_xcode


LEGACY_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-17-7"
MODERN_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-1"
LEGACY_UDID = "00000000-0000-0000-0000-000000000017"
MODERN_UDID = "00000000-0000-0000-0000-000000000026"


def runtime(version, *, identifier=None, name=None, build="23B74", available=True):
    return {
        "identifier": identifier or "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-"),
        "name": name or "iOS " + version,
        "version": version,
        "buildversion": build,
        "isAvailable": available,
    }


def device(udid, name, *, state="Shutdown", available=True, device_type=None):
    result = {"udid": udid, "name": name, "state": state, "isAvailable": available}
    if device_type is not None:
        result["deviceTypeIdentifier"] = device_type
    return result


class DestinationSelectionTests(unittest.TestCase):
    def setUp(self):
        self.runtimes = {
            "runtimes": [
                runtime("17.7", build="21H16"),
                runtime("26.1"),
            ]
        }
        self.devices = {
            "devices": {
                LEGACY_RUNTIME: [device(LEGACY_UDID, "iPhone 14")],
                MODERN_RUNTIME: [device(MODERN_UDID, "iPhone 17")],
            }
        }

    def select(self, **kwargs):
        return select_destinations(self.runtimes, self.devices, "26.3", **kwargs)

    def add_runtime(self, version, *, devices=None, **kwargs):
        entry = runtime(version, **kwargs)
        self.runtimes["runtimes"].append(entry)
        self.devices["devices"][entry["identifier"]] = devices or []
        return entry["identifier"]

    def test_selects_legacy_then_modern_without_fixed_phone_model(self):
        destinations = self.select()
        self.assertEqual(len(destinations), 2)
        self.assertEqual(
            [(item.version, item.runtime_id, item.udid, item.name) for item in destinations],
            [
                ("17.7", LEGACY_RUNTIME, LEGACY_UDID, "iPhone 14"),
                ("26.1", MODERN_RUNTIME, MODERN_UDID, "iPhone 17"),
            ],
        )

    def test_ignores_unavailable_beta_and_runtime_above_sdk(self):
        self.add_runtime("26.2", available=False, devices=[device("unavailable", "iPhone 17")])
        self.add_runtime("26.3", name="iOS 26.3 Beta", devices=[device("beta", "iPhone 17")])
        self.add_runtime("26.4", devices=[device("future", "iPhone 17")])
        self.assertEqual(self.select()[1].udid, MODERN_UDID)

    def test_prerelease_names_are_excluded_case_insensitively(self):
        for label in ("beta", "BETA 2", "RC", "Release Candidate", "preview", "Developer Preview"):
            with self.subTest(label=label):
                entry = runtime("26.2", name="iOS 26.2 " + label)
                self.runtimes["runtimes"] = self.runtimes["runtimes"][:2] + [entry]
                self.devices["devices"][entry["identifier"]] = [device("prerelease", "iPhone 17")]
                self.assertEqual(self.select()[1].udid, MODERN_UDID)

    def test_seed_style_runtime_build_is_excluded(self):
        self.add_runtime("26.2", build="23C5044b", devices=[device("beta-build", "iPhone 17")])
        self.assertEqual(self.select()[1].udid, MODERN_UDID)

    def test_official_stable_runtime_with_lowercase_build_suffix_is_selected(self):
        runtime_id = self.add_runtime("26.5", build="23F81a",
                                      devices=[device("official-stable", "iPhone 17")])
        destinations = select_destinations(self.runtimes, self.devices, "26.5")
        self.assertEqual(destinations[1].runtime_id, runtime_id)
        self.assertEqual(destinations[1].udid, "official-stable")

    def test_runtime_version_must_be_numeric(self):
        for version in ("26.2beta", "26.2 RC", "26.x", "", "26..2", "-26.2"):
            with self.subTest(version=version):
                entry = runtime(version, identifier="invalid", name="iOS 26.2")
                self.runtimes["runtimes"] = self.runtimes["runtimes"][:2] + [entry]
                self.devices["devices"]["invalid"] = [device("invalid-version", "iPhone 17")]
                self.assertEqual(self.select()[1].udid, MODERN_UDID)

    def test_modern_versions_are_compared_numerically(self):
        self.add_runtime("26.9", devices=[device("26.9", "iPhone 17", state="Booted")])
        latest_id = self.add_runtime("26.10", devices=[device("26.10", "iPhone 17")])
        destinations = select_destinations(self.runtimes, self.devices, "26.10")
        self.assertEqual(destinations[1].runtime_id, latest_id)
        self.assertEqual(destinations[1].version, "26.10")

    def test_sdk_limit_is_compared_numerically(self):
        supported_id = self.add_runtime("26.9", devices=[device("26.9", "iPhone 17")])
        self.add_runtime("26.10", devices=[device("26.10", "iPhone 17")])
        destinations = select_destinations(self.runtimes, self.devices, "26.9")
        self.assertEqual(destinations[1].runtime_id, supported_id)

    def test_selects_highest_available_ios17_minor_and_patch(self):
        self.add_runtime("17.6", build="21G80", devices=[device("older", "iPhone 15")])
        self.add_runtime("17.7.1", build="21H216", devices=[device("patch", "iPhone 15")])
        self.add_runtime("17.8", build="21J16", devices=[device("minor", "iPhone 16")])
        self.add_runtime("17.9", available=False, devices=[device("unavailable", "iPhone 16")])
        self.assertEqual(self.select()[0].udid, "minor")

    def test_does_not_use_ios18_as_legacy_runtime(self):
        self.runtimes["runtimes"].pop(0)
        self.add_runtime("18.7", devices=[device("18", "iPhone 16")])
        with self.assertRaises(GateError):
            self.select()

    def test_does_not_use_ios25_as_modern_runtime(self):
        self.runtimes["runtimes"].pop()
        self.add_runtime("25.9", devices=[device("25", "iPhone 16")])
        with self.assertRaises(GateError):
            self.select()

    def test_missing_either_required_runtime_fails(self):
        original = copy.deepcopy(self.runtimes)
        for missing_index in (0, 1):
            with self.subTest(missing_index=missing_index):
                self.runtimes = copy.deepcopy(original)
                self.runtimes["runtimes"].pop(missing_index)
                with self.assertRaises(GateError):
                    self.select()

    def test_runtime_requires_literal_true_availability(self):
        original = copy.deepcopy(self.runtimes)
        for available in (False, None, 1, "true"):
            with self.subTest(available=available):
                self.runtimes = copy.deepcopy(original)
                self.runtimes["runtimes"][0]["isAvailable"] = available
                with self.assertRaises(GateError):
                    self.select()
        self.runtimes = copy.deepcopy(original)
        self.runtimes["runtimes"][0].pop("isAvailable")
        with self.assertRaises(GateError):
            self.select()

    def test_latest_modern_runtime_without_iphone_fails_without_fallback(self):
        self.add_runtime("26.2", devices=[device("ipad", "iPad Pro")])
        with self.assertRaises(GateError):
            self.select()

    def test_missing_iphone_on_either_destination_fails(self):
        original = copy.deepcopy(self.devices)
        for runtime_id in (LEGACY_RUNTIME, MODERN_RUNTIME):
            with self.subTest(runtime_id=runtime_id):
                self.devices = copy.deepcopy(original)
                self.devices["devices"][runtime_id] = [device("ipad", "iPad Pro", state="Booted")]
                with self.assertRaises(GateError):
                    self.select()

    def test_booted_iphone_is_preferred_over_shutdown_iphone(self):
        self.devices["devices"][LEGACY_RUNTIME] = [
            device("shutdown", "iPhone 16"),
            device("booted", "iPhone SE (3rd generation)", state="Booted"),
            device("ipad", "iPad Pro", state="Booted"),
        ]
        self.assertEqual(self.select()[0].udid, "booted")

    def test_device_requires_literal_true_availability(self):
        for available in (False, None, 1, "true"):
            with self.subTest(available=available):
                self.devices["devices"][LEGACY_RUNTIME] = [
                    device("unavailable", "iPhone 17", state="Booted", available=available),
                    device(LEGACY_UDID, "iPhone 14"),
                ]
                self.assertEqual(self.select()[0].udid, LEGACY_UDID)
        unavailable = device("missing-availability", "iPhone 17", state="Booted")
        unavailable.pop("isAvailable")
        self.devices["devices"][LEGACY_RUNTIME] = [unavailable, device(LEGACY_UDID, "iPhone 14")]
        self.assertEqual(self.select()[0].udid, LEGACY_UDID)

    def test_device_type_identifier_overrides_misleading_name(self):
        self.devices["devices"][LEGACY_RUNTIME] = [
            device("renamed-ipad", "iPhone 14", state="Booted",
                   device_type="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4"),
            device("renamed-iphone", "QA phone",
                   device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-14"),
        ]
        self.assertEqual(self.select()[0].udid, "renamed-iphone")

    def test_explicit_udids_select_available_phones_on_selected_runtimes(self):
        self.devices["devices"][LEGACY_RUNTIME].append(device("booted", "iPhone 15", state="Booted"))
        destinations = self.select(legacy_udid=LEGACY_UDID, modern_udid=MODERN_UDID)
        self.assertEqual([item.udid for item in destinations], [LEGACY_UDID, MODERN_UDID])

    def test_explicit_udid_cannot_belong_to_the_other_runtime(self):
        for overrides in ({"legacy_udid": MODERN_UDID}, {"modern_udid": LEGACY_UDID}):
            with self.subTest(overrides=overrides):
                with self.assertRaises(GateError):
                    self.select(**overrides)

    def test_explicit_udid_cannot_pin_an_older_modern_runtime(self):
        self.add_runtime("26.2", devices=[device("latest", "iPhone 17")])
        with self.assertRaises(GateError):
            self.select(modern_udid=MODERN_UDID)

    def test_explicit_unknown_unavailable_or_ipad_udid_fails(self):
        self.devices["devices"][LEGACY_RUNTIME].extend([
            device("unavailable", "iPhone 14", available=False),
            device("ipad", "iPad Pro"),
        ])
        for udid in ("unknown", "unavailable", "ipad"):
            with self.subTest(udid=udid):
                with self.assertRaises(GateError):
                    self.select(legacy_udid=udid)

    def test_sdk_without_a_supported_modern_runtime_fails(self):
        with self.assertRaises(GateError):
            select_destinations(self.runtimes, self.devices, "18.7")


class TestSummaryValidationTests(unittest.TestCase):
    def setUp(self):
        self.summary = {
            "totalTestCount": 4,
            "passedTests": 4,
            "failedTests": 0,
            "skippedTests": 0,
            "result": "Passed",
        }

    def test_all_tests_passed_is_accepted(self):
        validate_summary(self.summary)

    def test_successful_counts_without_result_field_are_accepted(self):
        self.summary.pop("result")
        validate_summary(self.summary)

    def test_zero_test_result_cannot_pass(self):
        self.summary.update(totalTestCount=0, passedTests=0)
        with self.assertRaises(GateError):
            validate_summary(self.summary)

    def test_failures_cannot_pass_even_when_result_claims_success(self):
        self.summary.update(passedTests=3, failedTests=1)
        with self.assertRaises(GateError):
            validate_summary(self.summary)

    def test_skipped_tests_cannot_pass(self):
        self.summary.update(passedTests=3, skippedTests=1)
        with self.assertRaises(GateError):
            validate_summary(self.summary)

    def test_passed_count_must_equal_total(self):
        for passed in (3, 5):
            with self.subTest(passed=passed):
                self.summary["passedTests"] = passed
                with self.assertRaises(GateError):
                    validate_summary(self.summary)

    def test_missing_counts_cannot_pass(self):
        for field in ("totalTestCount", "passedTests", "failedTests", "skippedTests"):
            with self.subTest(field=field):
                summary = dict(self.summary)
                summary.pop(field)
                with self.assertRaises(GateError):
                    validate_summary(summary)

    def test_counts_must_be_nonnegative_integers(self):
        for field in ("totalTestCount", "passedTests", "failedTests", "skippedTests"):
            for value in (-1, "4", 4.0, True, None):
                with self.subTest(field=field, value=value):
                    summary = dict(self.summary)
                    summary[field] = value
                    with self.assertRaises(GateError):
                        validate_summary(summary)

    def test_explicit_failed_result_cannot_pass(self):
        self.summary["result"] = "Failed"
        with self.assertRaises(GateError):
            validate_summary(self.summary)

    def test_non_success_result_cannot_pass(self):
        for result in ("Skipped", "Unknown", "", None):
            with self.subTest(result=result):
                self.summary["result"] = result
                with self.assertRaises(GateError):
                    validate_summary(self.summary)


class XcodeValidationTests(unittest.TestCase):
    STABLE_VERSION = "Xcode 26.5\nBuild version 17F42\n"
    STABLE_DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"

    def test_xcode26_stable_build_and_path_are_accepted(self):
        validated = validate_xcode(self.STABLE_VERSION, [self.STABLE_DEVELOPER_DIR])
        self.assertIsInstance(validated, dict)

    def test_older_xcode_cannot_pass_the_gate(self):
        with self.assertRaises(GateError):
            validate_xcode("Xcode 25.4\nBuild version 16F42\n", [self.STABLE_DEVELOPER_DIR])

    def test_beta_version_label_is_rejected_even_with_stable_looking_build(self):
        with self.assertRaises(GateError):
            validate_xcode("Xcode 26.5 Beta 2\nBuild version 17F42\n", [self.STABLE_DEVELOPER_DIR])

    def test_xcode_build_suffix_alone_cannot_reject_an_unmarked_installation(self):
        validated = validate_xcode("Xcode 26.5\nBuild version 17F5032a\n",
                                   [self.STABLE_DEVELOPER_DIR])
        self.assertIsInstance(validated, dict)

    def test_effective_developer_directory_can_reveal_a_beta_installation(self):
        beta_paths = (
            "/Applications/Xcode-beta.app/Contents/Developer",
            "/Applications/Xcode_26.5_beta.app/Contents/Developer",
        )
        for beta_path in beta_paths:
            with self.subTest(directory=beta_path):
                with self.assertRaises(GateError):
                    validate_xcode(self.STABLE_VERSION, [beta_path])

    def test_stable_developer_dir_override_takes_priority_over_global_beta_xcode(self):
        inventory = {
            "runtimes": [runtime("17.7", build="21H16"), runtime("26.1")],
            "devices": {
                LEGACY_RUNTIME: [device(LEGACY_UDID, "iPhone 14")],
                MODERN_RUNTIME: [device(MODERN_UDID, "iPhone 17")],
            },
        }

        def capture(command):
            if command[0] == "xcode-select":
                return "/Applications/Xcode-beta.app/Contents/Developer\n"
            if command[0] == "xcodebuild":
                return self.STABLE_VERSION
            if "simctl" in command:
                return json.dumps(inventory)
            if "--show-sdk-version" in command:
                return "26.5\n"
            self.fail("Unexpected tool invocation: " + repr(command))

        summary = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        with tempfile.TemporaryDirectory(prefix="esheep-xcode-override-") as directory:
            output_dir = Path(directory) / "results"
            with patch.object(compatibility, "capture", side_effect=capture) as tools, \
                    patch.object(compatibility, "run_suite", return_value=summary) as run_suite, \
                    patch.dict(os.environ, {"DEVELOPER_DIR": self.STABLE_DEVELOPER_DIR}), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                exit_code = compatibility.main(["--output-dir", str(output_dir)])
            self.assertEqual(exit_code, 0)
            self.assertEqual(run_suite.call_count, 4)
            self.assertFalse(any(call.args[0][0] == "xcode-select" for call in tools.call_args_list))
            selection = json.loads((output_dir / "selection.json").read_text())
            self.assertEqual(selection["xcode"]["developerDirectories"], [self.STABLE_DEVELOPER_DIR])

    def test_missing_version_or_build_cannot_pass(self):
        for version_output in ("", "Xcode 26.5\n", "Build version 17F42\n"):
            with self.subTest(version_output=version_output):
                with self.assertRaises(GateError):
                    validate_xcode(version_output, [self.STABLE_DEVELOPER_DIR])

    def test_real_gate_rejects_unsupported_xcode_before_starting_a_suite(self):
        inventory = {
            "runtimes": [runtime("17.7", build="21H16"), runtime("26.1")],
            "devices": {
                LEGACY_RUNTIME: [device(LEGACY_UDID, "iPhone 14")],
                MODERN_RUNTIME: [device(MODERN_UDID, "iPhone 17")],
            },
        }
        cases = (
            ("Xcode 25.4\nBuild version 16F42\n", self.STABLE_DEVELOPER_DIR),
            (self.STABLE_VERSION, "/Applications/Xcode-beta.app/Contents/Developer"),
        )
        for version_output, developer_dir in cases:
            with self.subTest(version_output=version_output, developer_dir=developer_dir):
                with tempfile.TemporaryDirectory(prefix="esheep-unsupported-xcode-") as directory:
                    output_dir = Path(directory) / "results"

                    def capture(command):
                        if command[0] == "xcodebuild" and "-version" in command:
                            return version_output
                        if command[0] == "xcode-select":
                            return self.STABLE_DEVELOPER_DIR + "\n"
                        if "simctl" in command:
                            return json.dumps(inventory)
                        if "--show-sdk-version" in command:
                            return "26.5\n"
                        self.fail("Unexpected tool invocation: " + repr(command))

                    with patch.object(compatibility, "capture", side_effect=capture), \
                            patch.object(compatibility, "run_suite") as run_suite, \
                            patch.dict(os.environ, {"DEVELOPER_DIR": developer_dir}), \
                            redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                        exit_code = compatibility.main(["--output-dir", str(output_dir)])
                    self.assertNotEqual(exit_code, 0)
                    run_suite.assert_not_called()
                    self.assertFalse(output_dir.exists())


class OfflineCLITests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="esheep-ios-compatibility-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.fixture = self.root / "simctl.json"
        self.output_dir = self.root / "results with spaces"
        self.inventory = {
            "runtimes": [runtime("17.7", build="21H16"), runtime("26.1")],
            "devices": {
                LEGACY_RUNTIME: [device(LEGACY_UDID, "iPhone 14")],
                MODERN_RUNTIME: [device(MODERN_UDID, "iPhone 17")],
            },
        }

    def cli(self, *mode):
        self.fixture.write_text(json.dumps(self.inventory))
        # Offline previews must work even when xcrun and xcodebuild cannot be found.
        return subprocess.run(
            [sys.executable, str(Path(__file__).with_name("verify_ios_compatibility.py")),
             *mode, "--simctl-json", str(self.fixture), "--sdk-version", "26.1",
             "--output-dir", str(self.output_dir)],
            env={**os.environ, "PATH": ""},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_dry_run_prints_complete_suites_for_both_runtimes_without_apple_tools(self):
        result = self.cli("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = [shlex.split(line) for line in result.stdout.splitlines()
                    if line.startswith("xcodebuild ")]
        self.assertEqual(len(commands), 8)

        suites = {}
        result_bundles = set()
        for command in commands:
            self.assertNotIn("-only-testing", command)
            self.assertNotIn("-skip-testing", command)
            action = command[1]
            self.assertIn(action, ("build-for-testing", "test-without-building"))
            scheme = command[command.index("-scheme") + 1]
            destination = command[command.index("-destination") + 1]
            derived_data = command[command.index("-derivedDataPath") + 1]
            suites.setdefault((destination, scheme), []).append((action, derived_data))
            if action == "test-without-building":
                result_bundles.add(command[command.index("-resultBundlePath") + 1])

        self.assertEqual(
            set(suites),
            {(f"platform=iOS Simulator,id={udid}", scheme)
             for udid in (LEGACY_UDID, MODERN_UDID)
             for scheme in ("eSheepNextUI", "eSheepNext")},
        )
        derived_paths = set()
        for actions in suites.values():
            self.assertEqual({action for action, _ in actions},
                             {"build-for-testing", "test-without-building"})
            self.assertEqual(len(actions), 2)
            self.assertEqual(actions[0][1], actions[1][1])
            derived_paths.add(actions[0][1])
        self.assertEqual(len(derived_paths), 4)
        self.assertEqual(len(result_bundles), 4)
        for path in derived_paths | result_bundles:
            self.assertTrue(Path(path).is_relative_to(self.output_dir))
        self.assertFalse(self.output_dir.exists())

    def test_missing_ios17_makes_offline_cli_fail(self):
        self.inventory["runtimes"].pop(0)
        result = self.cli("--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("iOS 17", result.stderr)
        self.assertNotIn("xcodebuild ", result.stdout)
        self.assertFalse(self.output_dir.exists())

    def test_fixture_cannot_be_used_as_a_real_gate_run(self):
        result = self.cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("only with --list or --dry-run", result.stderr)
        self.assertFalse(self.output_dir.exists())


if __name__ == "__main__":
    unittest.main()
