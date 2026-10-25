"""Exercise iOS compatibility gate decisions without Xcode or simulators."""

import copy
from contextlib import redirect_stderr, redirect_stdout
import io
from itertools import combinations
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

import verify_ios_compatibility as compatibility
from verify_ios_compatibility import (GateError, parse_skipped_test_identifiers,
                                      select_destinations, validate_summary, validate_xcode)


LEGACY_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-17-7"
MODERN_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-1"
LEGACY_UDID = "00000000-0000-0000-0000-000000000017"
MODERN_UDID = "00000000-0000-0000-0000-000000000026"

# Completed skip results and reason lines copied from the 2026-10-04 main
# baseline (run 37191100882). No private fixture contents are included.
BASELINE_SKIP_LOG = """\
2026-10-04T09:35:05.4142660Z /Users/runner/work/esheep/esheep/eSheepNextTests/ESheepCloudIntegratedTests.swift:365: -[eSheepNextTests.ESheepCloudIntegratedTests testRealCloudSourceBuildsCheckpointAndImportsWithoutHistoricalReceipts] : Test skipped - Requires a sealed SELECT-only cloud source
2026-10-04T09:35:05.4146040Z Test Case '-[eSheepNextTests.ESheepCloudIntegratedTests testRealCloudSourceBuildsCheckpointAndImportsWithoutHistoricalReceipts]' skipped (0.011 seconds).
2026-10-04T09:35:08.2582130Z /Users/runner/work/esheep/esheep/eSheepNextTests/ESheepCloudV2Tests.swift:85: -[eSheepNextTests.ESheepCloudV2Tests testRealFarmForwardHistoryRepairMatchesEverySheepInIncrementalAndFreshReplay] : Test skipped - Private owner-approved baseline fixture not installed
2026-10-04T09:35:08.2596160Z Test Case '-[eSheepNextTests.ESheepCloudV2Tests testRealFarmForwardHistoryRepairMatchesEverySheepInIncrementalAndFreshReplay]' skipped (0.002 seconds).
2026-10-04T09:35:08.2599320Z /Users/runner/work/esheep/esheep/eSheepNextTests/ESheepCloudV2Tests.swift:320: -[eSheepNextTests.ESheepCloudV2Tests testRealFarmRepairSnapshotVerifiesAndActivatesFromEmptyStore] : Test skipped - Set ESHEEP_V2_REPLAY_FIXTURE to a private full-scale repair fixture
2026-10-04T09:35:08.2600760Z Test Case '-[eSheepNextTests.ESheepCloudV2Tests testRealFarmRepairSnapshotVerifiesAndActivatesFromEmptyStore]' skipped (0.001 seconds).
/Users/runner/work/esheep/esheep/eSheepNextTests/RealFarmIsolationAcceptanceTests.swift:130: -[eSheepNextTests.RealFarmIsolationAcceptanceTests testPrivateAuthoritativeCheckpointAndEventReplay] : Test skipped - Supply a private authoritative checkpoint directory
Test Case '-[eSheepNextTests.RealFarmIsolationAcceptanceTests testPrivateAuthoritativeCheckpointAndEventReplay]' skipped (0.005 seconds).
/Users/runner/work/esheep/esheep/eSheepNextTests/RealFarmIsolationAcceptanceTests.swift:11: -[eSheepNextTests.RealFarmIsolationAcceptanceTests testPrivateDatabaseMigrationAndPageProjections] : Test skipped - Supply a private backup directory for isolated real-farm acceptance
Test Case '-[eSheepNextTests.RealFarmIsolationAcceptanceTests testPrivateDatabaseMigrationAndPageProjections]' skipped (0.006 seconds).
/Users/runner/work/esheep/esheep/eSheepNextTests/ReproductionCycleResolverTests.swift:88: -[eSheepNextTests.ReproductionCycleResolverTests testAuthoritativeReadOnlyCloudAuditMatchesWebAtSameCutoffWhenProvided] : Test skipped - Provide the private, read-only authoritative cloud audit fixture
Test Case '-[eSheepNextTests.ReproductionCycleResolverTests testAuthoritativeReadOnlyCloudAuditMatchesWebAtSameCutoffWhenProvided]' skipped (0.029 seconds).
"""


def skipped_result(identifier):
    target, test_class, method = identifier.split("/")
    return f"Test Case '-[{target}.{test_class} {method}]' skipped (0.001 seconds).\n"


def fixture_summary(identifiers=(), *, passed=4):
    skipped = len(set(identifiers))
    return {"totalTestCount": passed + skipped, "passedTests": passed,
            "failedTests": 0, "skippedTests": skipped, "result": "Passed"}


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


class FixtureSkipValidationTests(unittest.TestCase):
    def setUp(self):
        self.known = tuple(compatibility.KNOWN_FULL_UNIT_FIXTURE_SKIPS)

    def validate_unit(self, summary, identifiers=None):
        return validate_summary(summary, allow_fixture_skips=True,
                                skipped_test_identifiers=identifiers)

    def test_real_baseline_result_lines_are_parsed_without_double_counting_reasons(self):
        identifiers = parse_skipped_test_identifiers(BASELINE_SKIP_LOG)
        self.assertEqual(identifiers, frozenset(self.known))
        self.validate_unit(fixture_summary(identifiers, passed=786), identifiers)

    def test_each_allowed_subset_including_no_skips_is_accepted(self):
        for size in range(len(self.known) + 1):
            for identifiers in combinations(self.known, size):
                with self.subTest(identifiers=identifiers):
                    summary = fixture_summary(identifiers)
                    original = copy.deepcopy(summary)
                    self.assertIs(self.validate_unit(summary, identifiers), summary)
                    self.assertEqual(summary, original)

    def test_default_validation_still_rejects_known_skips(self):
        for identifiers in (None, self.known):
            with self.subTest(identifiers=identifiers):
                with self.assertRaises(GateError):
                    validate_summary(fixture_summary(self.known),
                                     skipped_test_identifiers=identifiers)

    def test_unknown_test_target_class_and_method_suffix_cannot_use_allowlist(self):
        identifier = self.known[0]
        unknown = (
            "eSheepNextTests/OtherTests/testSkipped",
            identifier.replace("eSheepNextTests/", "eSheepNextUITests/", 1),
            identifier.replace("/ESheepCloudIntegratedTests/", "/OtherTests/", 1),
            identifier + "Extra",
        )
        for test in unknown:
            with self.subTest(identifier=test):
                with self.assertRaisesRegex(GateError, "rejected skipped tests"):
                    self.validate_unit(fixture_summary([test]), [test])

    def test_skip_count_requires_completed_log_identifiers(self):
        for identifiers in (None, (), parse_skipped_test_identifiers("Test Case '-[truncated")):
            with self.subTest(identifiers=identifiers):
                with self.assertRaises(GateError):
                    self.validate_unit(fixture_summary(self.known), identifiers)

    def test_three_skips_cannot_hide_an_unknown_test_among_known_fixtures(self):
        identifiers = [*self.known[:2], "eSheepNextTests/UnexpectedTests/testSkipped"]
        with self.assertRaisesRegex(GateError, "UnexpectedTests/testSkipped"):
            self.validate_unit(fixture_summary(identifiers), identifiers)

    def test_skip_reason_alone_is_not_a_completed_skip_result(self):
        reasons = "\n".join(line for line in BASELINE_SKIP_LOG.splitlines()
                            if "Test skipped -" in line)
        self.assertEqual(parse_skipped_test_identifiers(reasons), frozenset())
        with self.assertRaises(GateError):
            self.validate_unit(fixture_summary(self.known), parse_skipped_test_identifiers(reasons))

    def test_duplicate_result_lines_count_as_one_distinct_test(self):
        identifier = self.known[0]
        identifiers = parse_skipped_test_identifiers(skipped_result(identifier) * 2)
        self.assertEqual(identifiers, frozenset([identifier]))
        self.validate_unit(fixture_summary([identifier]), identifiers)
        summary = fixture_summary([identifier])
        summary.update(totalTestCount=6, skippedTests=2)
        with self.assertRaisesRegex(GateError, "does not match test.log"):
            self.validate_unit(summary, identifiers)

    def test_log_and_summary_skip_counts_must_match_in_both_directions(self):
        cases = (
            (fixture_summary(self.known), self.known[:2]),
            (fixture_summary(self.known[:1]), self.known),
            (fixture_summary(), self.known[:1]),
        )
        for summary, identifiers in cases:
            with self.subTest(summary=summary, identifiers=identifiers):
                with self.assertRaisesRegex(GateError, "does not match test.log"):
                    self.validate_unit(summary, identifiers)

    def test_passed_plus_skipped_must_equal_total(self):
        for difference in (-1, 1):
            with self.subTest(difference=difference):
                summary = fixture_summary(self.known)
                summary["totalTestCount"] += difference
                with self.assertRaises(GateError):
                    self.validate_unit(summary, self.known)

    def test_all_skipped_and_zero_execution_cannot_pass(self):
        for identifiers in ((), self.known):
            with self.subTest(identifiers=identifiers):
                with self.assertRaises(GateError):
                    self.validate_unit(fixture_summary(identifiers, passed=0), identifiers)

    def test_known_skips_cannot_hide_failures_or_unsuccessful_result(self):
        for change in ({"failedTests": 1}, {"result": "Failed"},
                       {"testFailures": [{"message": "An assertion failed"}]}):
            with self.subTest(change=change):
                summary = fixture_summary(self.known)
                summary.update(change)
                with self.assertRaises(GateError):
                    self.validate_unit(summary, self.known)

    def test_completed_skip_without_complete_identifier_is_rejected(self):
        for identifier in ("", "Unknown", "-[Class testCase]"):
            with self.subTest(identifier=identifier):
                with self.assertRaisesRegex(GateError, "Cannot identify skipped XCTest"):
                    parse_skipped_test_identifiers(f"Test Case '{identifier}' skipped (0.01 seconds).")


class UITestPlanPolicyTests(unittest.TestCase):
    def test_only_ios17_ui_uses_the_legacy_plan_for_build_and_test(self):
        for version in ("17.0", "17.5", "18.0", "26.5"):
            for scheme in compatibility.SCHEMES:
                with self.subTest(version=version, scheme=scheme):
                    destination = compatibility.Destination(LEGACY_RUNTIME, version, "iPhone", LEGACY_UDID)
                    _, build, test = compatibility.suite_commands(destination, scheme, Path("/tmp/plan-policy"))
                    for command in (build, test):
                        if version.startswith("17.") and scheme == "eSheepNextUI":
                            self.assertEqual(command[command.index("-testPlan") + 1], "Legacy17")
                            self.assertEqual(command.count("-testPlan"), 1)
                        else:
                            self.assertNotIn("-testPlan", command)

    def test_plans_run_the_same_complete_target_and_change_only_the_collector(self):
        plans = {}
        for name in ("ModernUI", "Legacy17"):
            plan = json.loads((compatibility.ROOT / "TestPlans" / f"{name}.xctestplan").read_text())
            self.assertEqual(plan["version"], 1)
            self.assertEqual(plan["testTargets"], [{
                "parallelizable": False,
                "skipped": False,
                "target": {
                    "containerPath": "container:eSheepNext.xcodeproj",
                    "identifier": "E5A500032FCA000100A00001",
                    "name": "eSheepNextUITests",
                },
            }])
            self.assertEqual(len(plan["configurations"]), 1)
            self.assertEqual(plan["configurations"][0]["options"], {})
            plans[name] = plan
        self.assertEqual(plans["ModernUI"]["defaultOptions"], {})
        self.assertEqual(set(plans["Legacy17"]["defaultOptions"]), {"runtimeIssueDetection"})
        self.assertIs(plans["Legacy17"]["defaultOptions"]["runtimeIssueDetection"]["enabled"], False)
        plans["Legacy17"]["defaultOptions"].clear()
        self.assertEqual(plans["Legacy17"], plans["ModernUI"])

    def test_ui_scheme_defaults_to_modern_and_has_one_test_target_source(self):
        path = compatibility.ROOT / "eSheepNext.xcodeproj/xcshareddata/xcschemes/eSheepNextUI.xcscheme"
        action = ET.parse(path).getroot().find("TestAction")
        self.assertIsNotNone(action)
        self.assertEqual(action.get("shouldUseLaunchSchemeArgsEnv"), "NO")
        self.assertIsNone(action.find("Testables"))
        self.assertNotIn("shouldAutocreateTestPlan", action.attrib)
        references = action.findall("TestPlans/TestPlanReference")
        self.assertEqual([reference.attrib for reference in references], [
            {"reference": "container:TestPlans/ModernUI.xctestplan", "default": "YES"},
            {"reference": "container:TestPlans/Legacy17.xctestplan", "default": "NO"},
        ])


class SuiteSkipPolicyTests(unittest.TestCase):
    def run_mock_suite(self, root, scheme, *, summary, log=BASELINE_SKIP_LOG, test_exit=0):
        destination = compatibility.Destination(LEGACY_RUNTIME, "17.7", "iPhone 14", LEGACY_UDID)
        suite_dir, _, _ = compatibility.suite_commands(destination, scheme, root)
        summary_text = json.dumps(summary, indent=1) + "\n"

        def run_logged(command, log_path):
            if command[1] == "build-for-testing":
                log_path.write_text("Build succeeded\n")
                return 0
            log_path.write_text(log)
            (suite_dir / "Tests.xcresult").mkdir()
            return test_exit

        with patch.object(compatibility, "run_logged", side_effect=run_logged), \
                patch.object(compatibility, "capture", return_value=summary_text), \
                redirect_stdout(io.StringIO()):
            result = compatibility.run_suite(destination, scheme, root)
        return suite_dir, summary_text, result

    def test_full_unit_reads_completed_log_results_and_preserves_raw_summary(self):
        summary = fixture_summary(compatibility.KNOWN_FULL_UNIT_FIXTURE_SKIPS, passed=786)
        with tempfile.TemporaryDirectory(prefix="esheep-unit-skips-") as directory:
            suite_dir, summary_text, result = self.run_mock_suite(Path(directory), "eSheepNext",
                                                                 summary=summary)
            self.assertEqual(result, summary)
            self.assertEqual((suite_dir / "summary.json").read_text(), summary_text)
            records = json.loads((suite_dir / "skipped-tests.json").read_text())
            self.assertEqual({record["identifier"] for record in records},
                             set(compatibility.KNOWN_FULL_UNIT_FIXTURE_SKIPS))
            self.assertTrue(all(record["baselineReason"] for record in records))

    def test_ui_rejects_even_known_fixture_skips(self):
        with tempfile.TemporaryDirectory(prefix="esheep-ui-skips-") as directory:
            with self.assertRaisesRegex(GateError, "rejected skipped tests"):
                self.run_mock_suite(Path(directory), "eSheepNextUI",
                                    summary=fixture_summary(compatibility.KNOWN_FULL_UNIT_FIXTURE_SKIPS))

    def test_ui_without_skips_still_passes(self):
        with tempfile.TemporaryDirectory(prefix="esheep-ui-no-skips-") as directory:
            summary = fixture_summary()
            suite_dir, _, result = self.run_mock_suite(Path(directory), "eSheepNextUI",
                                                       summary=summary, log="Test Suite passed\n")
            self.assertEqual(result, summary)
            self.assertEqual(json.loads((suite_dir / "skipped-tests.json").read_text()), [])

    def test_unit_rejects_missing_log_results_despite_allowed_summary_count(self):
        with tempfile.TemporaryDirectory(prefix="esheep-missing-skips-") as directory:
            with self.assertRaisesRegex(GateError, "does not match test.log"):
                self.run_mock_suite(Path(directory), "eSheepNext", log="Test Suite passed\n",
                                    summary=fixture_summary(compatibility.KNOWN_FULL_UNIT_FIXTURE_SKIPS))

    def test_nonzero_xcode_exit_cannot_pass_a_valid_fixture_summary(self):
        with tempfile.TemporaryDirectory(prefix="esheep-xcode-exit-") as directory:
            with self.assertRaisesRegex(GateError, "xcodebuild exited 1"):
                self.run_mock_suite(Path(directory), "eSheepNext", test_exit=1,
                                    summary=fixture_summary(compatibility.KNOWN_FULL_UNIT_FIXTURE_SKIPS))


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
            if destination == f"platform=iOS Simulator,id={LEGACY_UDID}" and scheme == "eSheepNextUI":
                self.assertEqual(command[command.index("-testPlan") + 1], "Legacy17")
            else:
                self.assertNotIn("-testPlan", command)
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
