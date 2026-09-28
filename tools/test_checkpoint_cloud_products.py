import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

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
