import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('cloud_worker', Path(__file__).resolve().parents[1]/'ci_scripts/run_checkpoint_refresh.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class CloudProductsTests(unittest.TestCase):
    def write_plan(self, root, name, target='eSheepNextTests'):
        path = root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [{'BlueprintName': target}]}]}))
        return path

    def test_cloud_bundle_precedes_derived_data_and_uses_target_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cloud = root/'TestProducts.xctestproducts'
            expected = self.write_plan(cloud, 'Tests/0/Default.xctestrun')
            self.write_plan(root/'DerivedData', 'eSheepNext_iphonesimulator.xctestrun')
            self.write_plan(cloud, 'Tests/1/Other.xctestrun', 'OtherTests')
            self.assertEqual(worker.find_test_plan({'CI_TEST_PRODUCTS_PATH': str(cloud), 'CI_DERIVED_DATA_PATH': str(root/'DerivedData')}), expected)

    def test_fallback_and_ambiguity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            expected = self.write_plan(root, 'eSheepNext.xctestrun')
            env = {'CI_DERIVED_DATA_PATH': str(root)}
            self.assertEqual(worker.find_test_plan(env), expected)
            self.write_plan(root, 'CheckpointRefreshWorker.xctestrun')
            self.assertEqual(worker.find_test_plan(env), expected)
            self.write_plan(root, 'Another.xctestrun')
            with self.assertRaisesRegex(RuntimeError, 'Ambiguous'):
                worker.find_test_plan(env)

    def test_worker_launches_refresh_from_repository_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = self.write_plan(Path(tmp), 'Cloud/Default.xctestrun')
            environment = {
                'CI_TEST_PRODUCTS_PATH': str(plan.parent),
                'ESHEEP_CHECKPOINT_PROJECT': 'test-only-project',
            }
            devices = {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [
                {'name': 'iPhone 18 Pro', 'udid': 'test-only-simulator', 'isAvailable': True}
            ]}}
            with patch.dict(worker.os.environ, environment, clear=True), \
                    patch.object(worker.subprocess, 'check_output', return_value=json.dumps(devices).encode()), \
                    patch.object(worker.subprocess, 'run') as run:
                run.return_value.returncode = 0
                with self.assertRaises(SystemExit) as completed:
                    worker.main()
                self.assertEqual(completed.exception.code, 0)
            repository = Path(__file__).resolve().parents[1]
            command = run.call_args.args[0]
            self.assertEqual(Path(command[1]), repository/'tools/refresh_esheep_cloud_checkpoints.py')
            self.assertTrue(Path(command[1]).is_file())
            self.assertEqual(run.call_args.kwargs['cwd'], repository)
            self.assertEqual(command[command.index('--prebuilt-test-plan') + 1], str(plan))
            self.assertIn('platform=iOS Simulator,id=test-only-simulator', command)
