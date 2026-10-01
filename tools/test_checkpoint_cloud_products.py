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

    def test_worker_launches_refresh_without_ci_directory_aliases(self):
        with tempfile.TemporaryDirectory() as tmp:
            repository = Path(tmp)/'Checkout'
            cloud_entry = repository/'ci_scripts/run_checkpoint_refresh.py'
            cloud_entry.parent.mkdir(parents=True)
            cloud_entry.write_text('# Isolated checkout entry point\n')
            receipt = Path(tmp)/'launch-receipt.json'
            refresh = repository/'tools/refresh_esheep_cloud_checkpoints.py'
            refresh.parent.mkdir(parents=True)
            refresh.write_text(
                'import json, os, sys\n'
                'from pathlib import Path\n'
                'Path(os.environ["ESHEEP_CLOUD_ENTRY_TEST_RECEIPT"]).write_text('
                'json.dumps({"cwd": os.getcwd(), "arguments": sys.argv[1:]}))\n'
            )
            plan = self.write_plan(Path(tmp), 'Cloud/Default.xctestrun')
            environment = {
                'CI_TEST_PRODUCTS_PATH': str(plan.parent),
                'ESHEEP_CHECKPOINT_PROJECT': 'test-only-project',
                'ESHEEP_CLOUD_ENTRY_TEST_RECEIPT': str(receipt),
                'PATH': worker.os.environ.get('PATH', worker.os.defpath),
            }
            devices = {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [
                {'name': 'iPhone 18 Pro', 'udid': 'test-only-simulator', 'isAvailable': True}
            ]}}
            with patch.dict(worker.os.environ, environment, clear=True), \
                    patch.object(worker, '__file__', str(cloud_entry)), \
                    patch.object(worker.subprocess, 'check_output', return_value=json.dumps(devices).encode()):
                with self.assertRaises(SystemExit) as completed:
                    worker.main()
                self.assertEqual(completed.exception.code, 0)
            self.assertFalse((cloud_entry.parent/'tools').exists())
            launched = json.loads(receipt.read_text())
            self.assertEqual(Path(launched['cwd']).resolve(), repository.resolve())
            arguments = launched['arguments']
            self.assertEqual(arguments[arguments.index('--prebuilt-test-plan') + 1], str(plan))
            self.assertIn('platform=iOS Simulator,id=test-only-simulator', arguments)
