#!/usr/bin/env python3
"""Offline release regression: all three proofs must bind the same candidate."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import uuid

SCRIPT = Path(__file__).with_name('publish_esheep_cloud_checkpoint.py')


class PublicationGateTests(unittest.TestCase):
    def test_requires_bound_approved_history_even_for_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); archive = root / 'archive'; archive.mkdir()
            project = 'a' * 20
            farm, checkpoint = str(uuid.uuid4()), str(uuid.uuid4())
            data = b'private fixture bytes'
            digest = lambda value: hashlib.sha256(value).hexdigest()
            manifest = dict(formatVersion=1, farmID=farm, checkpointID=checkpoint,
                farmGeneration=3, boundaryEventSequence=7, modelCounts={'FarmRecord': 1}, chunks=[dict(
                    index=0, objectKey=f'{farm}/{checkpoint}/00000.json.gz', modelNames=['FarmRecord'],
                    compressedBytes=len(data), compressedSHA256=digest(data))])
            raw = json.dumps(manifest).encode(); (archive/'manifest.json').write_bytes(raw)
            (archive/'00000.json.gz').write_bytes(data)
            common = dict(passed=True, boundary=7, manifestSHA256=digest(raw), sourceInventorySHA256='b'*64)
            (root/'independent-reconciliation.json').write_text(json.dumps(dict(common,
                historicalProtocolReceipts=0, compressedBytes=len(data), databaseLogicalBytes=1024)))
            (root/'cloud-source-proof.json').write_text(json.dumps(dict(project=project,
                farmID=farm, generation=3, head=7, sourceInventorySHA256='b'*64)))
            (root/'purpose-history-reconciliation.json').write_text(json.dumps(common))
            approval = root/'approved-history-reconciliation.json'
            info = root/'Info.plist'; info.write_bytes(plistlib.dumps(dict(
                CFBundleIdentifier='com.sheepfarm.ios', SUPABASE_URL=f'https://{project}.supabase.co')))
            args = ['python3', str(SCRIPT), '--candidate', str(root), '--project', project,
                    '--release-info-plist', str(info)]
            run = lambda: subprocess.run(args, capture_output=True, text=True)
            self.assertNotEqual(run().returncode, 0, 'Missing approved history must reject publication preparation')
            for override in ({'passed': False}, {'manifestSHA256': 'c'*64},
                             {'sourceInventorySHA256': 'c'*64}, {'boundary': 6}):
                approval.write_text(json.dumps(dict(common, **override)))
                self.assertNotEqual(run().returncode, 0, override)
            approval.write_text(json.dumps(common))
            result = run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(json.loads(result.stdout)['networkMutations'])


if __name__ == '__main__':
    unittest.main()
