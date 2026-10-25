#!/usr/bin/env python3
"""Run the complete XCTest schemes on iOS 17 and the latest stable iOS runtime.

Requires a Mac with full Xcode and both simulator runtimes already installed.
For offline selection checks, use --list/--dry-run with --simctl-json and
--sdk-version. No simulator devices or runtimes are created, deleted or fetched.
"""

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
SCHEMES = ("eSheepNextUI", "eSheepNext")
# These opt-in acceptance tests are unchanged from main and require private
# inputs absent from hosted CI. This is an identifier allowlist, never an
# allowance for an arbitrary number of skipped tests. Keep them reported as
# skipped, not passed, in both the raw summary and the evidence manifest.
KNOWN_FULL_UNIT_FIXTURE_SKIPS = {
    "eSheepNextTests/ESheepCloudIntegratedTests/"
    "testRealCloudSourceBuildsCheckpointAndImportsWithoutHistoricalReceipts":
        "Requires a sealed SELECT-only cloud source",
    "eSheepNextTests/ESheepCloudV2Tests/"
    "testRealFarmForwardHistoryRepairMatchesEverySheepInIncrementalAndFreshReplay":
        "Private owner-approved baseline fixture not installed",
    "eSheepNextTests/ESheepCloudV2Tests/"
    "testRealFarmRepairSnapshotVerifiesAndActivatesFromEmptyStore":
        "Set ESHEEP_V2_REPLAY_FIXTURE to a private full-scale repair fixture",
    "eSheepNextTests/RealFarmIsolationAcceptanceTests/"
    "testPrivateAuthoritativeCheckpointAndEventReplay":
        "Supply a private authoritative checkpoint directory",
    "eSheepNextTests/RealFarmIsolationAcceptanceTests/"
    "testPrivateDatabaseMigrationAndPageProjections":
        "Supply a private backup directory for isolated real-farm acceptance",
    "eSheepNextTests/ReproductionCycleResolverTests/"
    "testAuthoritativeReadOnlyCloudAuditMatchesWebAtSameCutoffWhenProvided":
        "Provide the private, read-only authoritative cloud audit fixture",
}


class GateError(RuntimeError):
    pass


@dataclass(frozen=True)
class Destination:
    runtime_id: str
    version: str
    name: str
    udid: str

    @property
    def label(self):
        return "iOS-" + self.version

    @property
    def destination(self):
        return "platform=iOS Simulator,id=" + self.udid


def version_tuple(version):
    if not isinstance(version, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", version):
        raise GateError(f"Invalid numeric iOS/SDK version: {version!r}")
    values = tuple(map(int, version.split(".")))
    return values + (0,) * (3 - len(values))


def validate_xcode(version_output, developer_dirs):
    version = re.search(r"^Xcode (\d+(?:\.\d+){0,2})\s*$", version_output, re.MULTILINE)
    build = re.search(r"^Build version (\S+)\s*$", version_output, re.MULTILINE)
    if not version or not build or version_tuple(version[1])[0] < 26:
        raise GateError("This gate requires stable Xcode 26 or later; check xcodebuild -version.")
    # Stable Xcode builds can end in a lowercase letter; the build suffix
    # alone does not establish release status. Reject explicit prerelease labels.
    if re.search(r"beta|preview|release candidate|\brc\b", version_output, re.IGNORECASE):
        raise GateError(f"Prerelease Xcode is not accepted: {version_output.strip()}")
    for directory in developer_dirs:
        if "beta" in directory.lower():
            raise GateError(f"Beta Xcode developer directory is not accepted: {directory}")
    return {"version": version[1], "buildVersion": build[1], "developerDirectories": developer_dirs}


def stable_runtime(runtime):
    description = " ".join(str(runtime.get(key, "")) for key in
                           ("name", "identifier", "version", "buildversion", "bundlePath"))
    if re.search(r"beta|seed|preview|release candidate|\brc\b",
                 description, re.IGNORECASE):
        return False
    # Simulator seeds use high build numbers, such as 23A5260n. A lowercase
    # suffix by itself is valid in stable runtimes, including iOS 26.5 (23F81a).
    seed = re.fullmatch(r"\d+[A-Z](\d{4,})[a-z]", str(runtime.get("buildversion", "")))
    return not (seed and int(seed[1]) >= 5000)


def select_destinations(runtimes, devices, sdk_version, legacy_udid=None, modern_udid=None):
    sdk = version_tuple(sdk_version)
    if (not isinstance(runtimes, dict) or not isinstance(runtimes.get("runtimes"), list)
            or not isinstance(devices, dict) or not isinstance(devices.get("devices"), dict)):
        raise GateError("simctl JSON must contain a runtimes list and a devices mapping.")
    available = []
    for runtime in runtimes.get("runtimes", []):
        identifier = runtime.get("identifier", "")
        if (runtime.get("isAvailable") is not True
                or ".SimRuntime.iOS-" not in identifier
                or not stable_runtime(runtime)):
            continue
        try:
            version = version_tuple(runtime.get("version"))
        except GateError:
            continue
        if version <= sdk:
            available.append((version, runtime))

    selected = []
    for label, matches, requested in (
        ("iOS 17", [r for r in available if r[0][0] == 17], legacy_udid),
        ("latest stable iOS >= 26", [r for r in available if r[0][0] >= 26], modern_udid),
    ):
        if not matches:
            raise GateError(f"Missing available {label} runtime supported by SDK {sdk_version}; "
                            "install it in Xcode before running this gate.")
        _, runtime = max(matches, key=lambda entry: entry[0])
        identifier = runtime["identifier"]
        phones = []
        for device in devices.get("devices", {}).get(identifier, []):
            device_type = device.get("deviceTypeIdentifier", "")
            is_phone = (".iPhone-" in device_type if device_type
                        else device.get("name", "").startswith("iPhone "))
            if device.get("isAvailable") is True and is_phone and device.get("udid"):
                phones.append(device)
        if requested:
            phones = [phone for phone in phones if phone["udid"] == requested]
        if not phones:
            requested_text = f" with UDID {requested}" if requested else ""
            raise GateError(f"No available iPhone{requested_text} in selected iOS "
                            f"{runtime['version']} runtime ({identifier}).")

        def phone_rank(phone):
            model = phone.get("deviceTypeIdentifier") or phone["name"]
            number = re.search(r"iPhone[- ](\d+)", model)
            return (phone.get("state") == "Booted", int(number[1]) if number else 0,
                    "Pro" in model, phone["name"], phone["udid"])

        phone = max(phones, key=phone_rank)
        selected.append(Destination(identifier, runtime["version"], phone["name"], phone["udid"]))
    return selected


def parse_skipped_test_identifiers(log_text):
    """Read completed XCTest skip results, not the separate skip-reason lines."""
    identifiers = set()
    for match in re.finditer(r"Test Case '([^'\r\n]*)' skipped(?:\s|$)", log_text):
        identifier = re.fullmatch(
            r"-\[([A-Za-z_][A-Za-z_0-9]*)\.([A-Za-z_][A-Za-z_0-9]*) "
            r"([A-Za-z_][A-Za-z_0-9]*)\]", match[1]
        )
        if not identifier:
            raise GateError(f"Cannot identify skipped XCTest in test.log: {match[1]!r}")
        identifiers.add("/".join(identifier.groups()))
    return frozenset(identifiers)


def validate_summary(summary, *, allow_fixture_skips=False, skipped_test_identifiers=None):
    if not isinstance(summary, dict):
        raise GateError("XCTest summary must be a JSON object.")
    counts = {}
    for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests"):
        value = summary.get(key)
        if type(value) is not int or value < 0:
            raise GateError(f"XCTest summary has missing or invalid {key}: {value!r}")
        counts[key] = value
    if (counts["totalTestCount"] <= 0 or counts["passedTests"] <= 0 or counts["failedTests"] != 0
            or counts["passedTests"] + counts["skippedTests"] != counts["totalTestCount"]
            or summary.get("result", "Passed") != "Passed" or summary.get("testFailures")):
        raise GateError(f"XCTest gate failed: discovered={counts['totalTestCount']}, "
                        f"passed={counts['passedTests']}, failed={counts['failedTests']}, skipped={counts['skippedTests']}"
                        + f", result={summary.get('result', 'unknown')}")
    if counts["skippedTests"] and skipped_test_identifiers is None:
        raise GateError("XCTest skips require the completed test identifiers from test.log.")
    skipped = frozenset(skipped_test_identifiers or ())
    if any(not isinstance(identifier, str) for identifier in skipped):
        raise GateError("Skipped XCTest identifiers must be complete target/class/method strings.")
    if counts["skippedTests"] != len(skipped):
        raise GateError(f"XCTest skipped count does not match test.log: "
                        f"summary={counts['skippedTests']}, distinct identifiers={len(skipped)}")
    allowed = KNOWN_FULL_UNIT_FIXTURE_SKIPS if allow_fixture_skips is True else ()
    unknown = skipped.difference(allowed)
    if unknown:
        raise GateError("XCTest gate rejected skipped tests: " + ", ".join(sorted(unknown)))
    return summary


def capture(command):
    try:
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)
    except FileNotFoundError as error:
        raise GateError(f"Missing {command[0]}; this gate requires a Mac with full Xcode. "
                        "Use --list/--dry-run with JSON fixtures for offline checks.") from error
    if result.returncode:
        raise GateError(f"Command failed ({result.returncode}): {shlex.join(command)}\n{result.stderr.strip()}")
    return result.stdout


def suite_commands(destination, scheme, output_dir):
    suite_dir = output_dir / destination.label / scheme
    common = ["-project", str(ROOT / "eSheepNext.xcodeproj"), "-scheme", scheme,
              "-configuration", "Debug", "-destination", destination.destination,
              "-derivedDataPath", str(suite_dir / "DerivedData"),
              "-parallel-testing-enabled", "NO", "-maximum-parallel-testing-workers", "1"]
    # iOS 17's XCTest automation library crashes in its os_log fault callback
    # for UIKit input analytics even with other-runtime-issue detection off.
    # Explicitly disable all three runtime diagnostic categories in the older
    # UI plan; disabling only two did not prevent this callback from crashing.
    # The modern plan and unit/performance suites retain default diagnostics.
    if scheme == "eSheepNextUI" and version_tuple(destination.version)[0] == 17:
        common += ["-testPlan", "Legacy17"]
    # Match package builds to the simulator's active architecture. Building both
    # architectures can leave the inactive app slice without its package modules.
    settings = ["ONLY_ACTIVE_ARCH=YES", "SWIFT_ENABLE_BATCH_MODE=NO",
                "COMPILER_INDEX_STORE_ENABLE=NO", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-",
                "OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -solver-expression-time-threshold=30 "
                "-Xfrontend -warn-long-expression-type-checking=500"]
    build = ["xcodebuild", "build-for-testing", *common, *settings]
    test = ["xcodebuild", "test-without-building", *common,
            "-resultBundlePath", str(suite_dir / "Tests.xcresult")]
    if scheme == "eSheepNextUI":
        # Keep ordinary UI cases at 240s, while honoring the poster suite's
        # existing explicit 480s editing and 600s two-relaunch allowances.
        # ios-runtime.yml already permits those same per-case budgets.
        test += ["-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "240",
                 "-maximum-test-execution-time-allowance", "600"]
    test += settings
    return suite_dir, build, test


def run_logged(command, log_path):
    print(f"\n$ {shlex.join(command)}\nLog: {log_path}", flush=True)
    with log_path.open("w") as log:
        with subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, errors="replace") as process:
            for line in process.stdout:
                log.write(line)
                log.flush()
                print(line, end="", flush=True)
            return process.wait()


def run_suite(destination, scheme, output_dir):
    suite_dir, build, test = suite_commands(destination, scheme, output_dir)
    suite_dir.mkdir(parents=True)
    if run_logged(build, suite_dir / "build.log"):
        raise GateError(f"{destination.label} {scheme}: build-for-testing failed; see {suite_dir / 'build.log'}")
    test_exit = run_logged(test, suite_dir / "test.log")
    result_path = suite_dir / "Tests.xcresult"
    if not result_path.exists():
        raise GateError(f"{destination.label} {scheme}: no xcresult (xcodebuild exit {test_exit}); "
                        f"see {suite_dir / 'test.log'}")
    summary_text = capture(["xcrun", "xcresulttool", "get", "test-results", "summary",
                            "--path", str(result_path), "--compact"])
    (suite_dir / "summary.json").write_text(summary_text)
    summary = json.loads(summary_text)
    if isinstance(summary, dict):
        print(f"{destination.label} {scheme}: discovered={summary.get('totalTestCount', 'unknown')}, "
              f"failed={summary.get('failedTests', 'unknown')}, skipped={summary.get('skippedTests', 'unknown')}")
    skipped = parse_skipped_test_identifiers((suite_dir / "test.log").read_text(errors="replace"))
    validate_summary(summary, allow_fixture_skips=scheme == "eSheepNext",
                     skipped_test_identifiers=skipped)
    skip_records = [{"identifier": identifier,
                     "baselineReason": KNOWN_FULL_UNIT_FIXTURE_SKIPS[identifier]}
                    for identifier in sorted(skipped)]
    (suite_dir / "skipped-tests.json").write_text(json.dumps(skip_records, indent=2) + "\n")
    for record in skip_records:
        print(f"{destination.label} {scheme}: existing fixture skip "
              f"{record['identifier']} ({record['baselineReason']})")
    if test_exit:
        raise GateError(f"{destination.label} {scheme}: xcodebuild exited {test_exit} despite the test summary.")
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    preview = parser.add_mutually_exclusive_group()
    preview.add_argument("--list", action="store_true", help="Print the two required destinations without testing")
    preview.add_argument("--dry-run", action="store_true", help="Print destinations and build/test commands without testing")
    parser.add_argument("--simctl-json", type=Path, help="Offline fixture from xcrun simctl list --json (preview only)")
    parser.add_argument("--sdk-version", help="SDK version for offline preview (required with --simctl-json)")
    parser.add_argument("--legacy-udid", help="Available iPhone UDID in the selected iOS 17 runtime")
    parser.add_argument("--modern-udid", help="Available iPhone UDID in the selected latest stable runtime")
    parser.add_argument("--output-dir", type=Path, help="New directory for logs, derived data and xcresults")
    args = parser.parse_args(argv)
    if (args.simctl_json or args.sdk_version) and not (args.list or args.dry_run):
        parser.error("--simctl-json/--sdk-version are allowed only with --list or --dry-run")
    if args.simctl_json and not args.sdk_version:
        parser.error("--simctl-json requires --sdk-version")

    try:
        toolchain = None
        if not args.simctl_json:
            developer_dir = os.environ.get("DEVELOPER_DIR") or capture(["xcode-select", "-p"]).strip()
            directories = [developer_dir, str(Path(developer_dir).expanduser().resolve())]
            toolchain = validate_xcode(capture(["xcodebuild", "-version"]), sorted(set(directories)))
        inventory = (json.loads(args.simctl_json.read_text()) if args.simctl_json
                     else json.loads(capture(["xcrun", "simctl", "list", "--json"])))
        sdk_version = args.sdk_version or capture(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]).strip()
        destinations = select_destinations(inventory, inventory, sdk_version, args.legacy_udid, args.modern_udid)
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        output_dir = (args.output_dir or ROOT / "build" / "ios-compatibility" / run_id).expanduser().resolve()
        selection = {"sdkVersion": sdk_version, "destinations": [asdict(d) for d in destinations]}
        if toolchain:
            selection["xcode"] = toolchain
        print(json.dumps(selection, indent=2))
        if args.list:
            return 0
        if args.dry_run:
            for destination in destinations:
                for scheme in SCHEMES:
                    _, build, test = suite_commands(destination, scheme, output_dir)
                    print(shlex.join(build))
                    print(shlex.join(test))
            print(f"Results would be saved in {output_dir}")
            return 0

        output_dir.mkdir(parents=True, exist_ok=False)
        (output_dir / "selection.json").write_text(json.dumps(selection, indent=2) + "\n")
        (output_dir / "simctl.json").write_text(json.dumps(inventory, indent=2) + "\n")
        reports = []
        for destination in destinations:
            for scheme in SCHEMES:
                report = {"runtime": destination.version, "udid": destination.udid, "scheme": scheme}
                try:
                    report["summary"] = run_suite(destination, scheme, output_dir)
                    report["passed"] = True
                except (GateError, OSError, ValueError) as error:
                    report.update(passed=False, error=str(error))
                    print(str(error), file=sys.stderr, flush=True)
                reports.append(report)
                (output_dir / "results.json").write_text(json.dumps(reports, indent=2) + "\n")
        print(f"\nCompatibility gate {'passed' if all(r['passed'] for r in reports) else 'failed'}; results: {output_dir}")
        return 0 if all(report["passed"] for report in reports) else 1
    except (GateError, OSError, ValueError) as error:
        print(f"Compatibility gate failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
