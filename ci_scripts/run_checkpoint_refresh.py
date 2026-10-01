"""Reuse Xcode Cloud's built test product in one private post-build stage."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def find_test_plan(environment):
    # Cloud uses -testProductsPath; the bundle is outside DerivedData and its
    # embedded xctestrun name need not match the scheme. Prefer that artifact.
    roots = [environment.get('CI_TEST_PRODUCTS_PATH'), environment.get('CI_DERIVED_DATA_PATH')]
    for value in roots:
        if not value:
            continue
        plans = []
        for path in Path(value).rglob('*.xctestrun'):
            if path.name == 'CheckpointRefreshWorker.xctestrun':
                continue
            settings = plistlib.loads(path.read_bytes())
            targets = [target for config in settings.get('TestConfigurations', [])
                       for target in config.get('TestTargets', [])
                       if target.get('BlueprintName') == 'eSheepNextTests']
            if len(targets) == 1:
                plans.append(path)
        if len(plans) == 1:
            return plans[0]
        if plans:
            raise RuntimeError('Ambiguous eSheepNext simulator test plans')
    raise RuntimeError('No eSheepNext test plan in Cloud test products or DerivedData')


def main():
    root = Path(__file__).resolve().parents[1]
    plan = find_test_plan(os.environ)
    devices = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json']))
    candidates = [(runtime, d) for runtime, rows in devices['devices'].items() if 'iOS-' in runtime
                  for d in rows if d['name'].startswith('iPhone') and d.get('isAvailable')]
    if not candidates:
        raise RuntimeError('No available iPhone simulator')
    _, device = sorted(candidates, key=lambda item: (item[0], item[1]['name']), reverse=True)[0]
    # All raw source, SQLite files and detailed logs are outside Xcode artifacts.
    # Xcode Cloud removes this isolated environment at the end of the action.
    with tempfile.TemporaryDirectory(prefix='esheep-checkpoint-') as private:
        result = subprocess.run(['python3',str(root/'tools/refresh_esheep_cloud_checkpoints.py'),
            '--project',os.environ['ESHEEP_CHECKPOINT_PROJECT'],'--output',str(Path(private)/'run'),
            '--execute','--max-age-hours','1','--prebuilt-test-plan',str(plan),
            '--destination','platform=iOS Simulator,id='+device['udid']],cwd=root)
        raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
