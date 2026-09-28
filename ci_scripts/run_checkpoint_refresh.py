"""Reuse Xcode Cloud's built test product in one private post-build stage."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent
derived = Path(os.environ['CI_DERIVED_DATA_PATH'])
plans = [p for p in derived.rglob('*.xctestrun') if p.name.startswith('eSheepNext')]
if len(plans) != 1:
    raise RuntimeError('Expected exactly one eSheepNext simulator test plan')
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
        '--execute','--prebuilt-test-plan',str(plans[0]),
        '--destination','platform=iOS Simulator,id='+device['udid']],cwd=root)
    raise SystemExit(result.returncode)
