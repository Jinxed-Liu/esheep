"""Exercise the release boundary without Apple credentials or Xcode."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CloudReleasePreparationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="esheep-cloud-release-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "Config").mkdir()
        (self.root / "eSheepNext.xcodeproj").mkdir()
        (self.root / "Config/ReleaseEnvironment.xcconfig").write_text("// fixture\n")
        self.project = self.root / "eSheepNext.xcodeproj/project.pbxproj"
        self.source = (ROOT / "eSheepNext.xcodeproj/project.pbxproj").read_text()
        self.project.write_text(self.source)
        self.config = self.root / "Config/ReleaseEnvironment.local.xcconfig"
        self.environment = {
            **os.environ,
            "CI_XCODE_CLOUD": "TRUE",
            "ESHEEP_TESTFLIGHT_RELEASE": "1",
            "CI_WORKFLOW": "TestFlight 3.2 Internal",
            "CI_XCODEBUILD_ACTION": "archive",
            "CI_BRANCH": "main",
            "CI_PULL_REQUEST_NUMBER": "",
            "CI_START_CONDITION": "manual",
            "CI_BUILD_NUMBER": "60",
            "CI_PRIMARY_REPOSITORY_PATH": str(self.root),
            "ESHEEP_RELEASE_SUPABASE_URL": "https://fixture.supabase.co",
            "ESHEEP_RELEASE_SUPABASE_PUBLISHABLE_KEY": "sb_publishable_fixture",
        }

    def prepare(self, **overrides):
        return subprocess.run(
            ["sh", str(ROOT / "ci_scripts/ci_pre_xcodebuild.sh")],
            env={**self.environment, **overrides},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_successive_cloud_numbers_reach_app_and_widget(self):
        for number in ("60", "61"):
            with self.subTest(number=number):
                result = self.prepare(CI_BUILD_NUMBER=number)
                self.assertEqual(result.returncode, 0, result.stderr)
                numbers = re.findall(r"CURRENT_PROJECT_VERSION\s*=\s*(\d+);", self.project.read_text())
                self.assertGreaterEqual(len(numbers), 2)
                self.assertEqual(set(numbers), {number})
                content = self.config.read_text()
                self.assertIn("https:$(XC_SLASH)$(XC_SLASH)fixture.supabase.co", content)
                self.assertIn("sb_publishable_fixture", content)
                self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
                self.assertNotIn("sb_publishable_fixture", result.stdout + result.stderr)

    def test_unapproved_runs_fail_before_writing_configuration(self):
        cases = (
            {"CI_BRANCH": "codex/unapproved"},
            {"CI_START_CONDITION": "schedule"},
            {"CI_PULL_REQUEST_NUMBER": "5"},
            {"CI_WORKFLOW": "Checkpoint Refresh"},
            {"CI_XCODEBUILD_ACTION": "build-for-testing"},
            {"CI_BUILD_NUMBER": "0"},
            {"CI_BUILD_NUMBER": "60; echo unsafe"},
            {"ESHEEP_RELEASE_SUPABASE_PUBLISHABLE_KEY": "sb_secret_fixture"},
            {"ESHEEP_RELEASE_SUPABASE_URL": "https://fixture.supabase.co/other"},
        )
        for overrides in cases:
            with self.subTest(overrides=overrides):
                result = self.prepare(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.config.exists())
                self.assertEqual(self.project.read_text(), self.source)

    def test_other_workflows_and_local_builds_keep_their_inputs(self):
        for overrides in ({"ESHEEP_TESTFLIGHT_RELEASE": "0"}, {"CI_XCODE_CLOUD": "FALSE"}):
            with self.subTest(overrides=overrides):
                self.assertEqual(self.prepare(**overrides).returncode, 0)
                self.assertFalse(self.config.exists())
                self.assertEqual(self.project.read_text(), self.source)


if __name__ == "__main__":
    unittest.main()
