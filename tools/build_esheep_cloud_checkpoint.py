#!/usr/bin/env python3
"""Protected macOS worker: cloud SELECT export -> Swift replay -> independent gate.

Produces a candidate only. Publishing is a separate, explicitly gated step.
"""
import argparse
import hashlib
import shutil
import json
from pathlib import Path
import plistlib
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--project', required=True)
    p.add_argument('--farm', type=uuid.UUID, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--destination', required=True, help='Explicit installed iOS Simulator destination')
    p.add_argument('--only-if-due', action='store_true')
    p.add_argument('--approved-source', type=Path, help='Sealed owner-approved historical reconciliation records')
    p.add_argument('--derived-data', type=Path, help='Optional dedicated worker build cache')
    p.add_argument('--sealed-source', type=Path, help='Reuse an existing verified cloud SELECT capture; never a phone store')
    a = p.parse_args()
    work = a.output.resolve()
    work.mkdir(parents=True, exist_ok=False); work.chmod(0o700)
    def run(args, log):
        with (work/log).open('w') as output:
            subprocess.run(args, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True)
    if a.only_if_due:
        query = f"select s.event_head, c.boundary_event_sequence, c.verified_at, (s.event_head>coalesce(c.boundary_event_sequence,-1) and (c.verified_at is null or c.verified_at<now()-interval '24 hours' or s.event_head-c.boundary_event_sequence>5000)) due from esheep_cloud.farm_state s left join lateral (select boundary_event_sequence,verified_at from esheep_cloud.business_checkpoints c where c.farm_id=s.farm_id and c.farm_generation=s.farm_generation and c.status='verified' order by boundary_event_sequence desc limit 1) c on true where s.farm_id='{a.farm}' and s.v2_ready"
        result = subprocess.run(['supabase','db','query','--project-ref',a.project,'--linked',query,'-o','json'],capture_output=True,check=True)
        rows = json.loads(result.stdout)['rows']
        if len(rows) != 1: raise RuntimeError('Expected one eligible farm')
        if not rows[0]['due']:
            (work/'not-due.json').write_text(json.dumps(rows[0])); return
    if a.sealed_source:
        source=a.sealed_source.resolve()
        inventory=json.loads((source/'inventory.json').read_bytes())
        assert 'source.json' in inventory and 'profile.json' in inventory
        for name,digest in inventory.items():
            assert Path(name).name==name and hashlib.sha256((source/name).read_bytes()).hexdigest()==digest
        identity=json.loads((source/'source.json').read_bytes())
        assert identity['project']==a.project and uuid.UUID(identity['farmID'])==a.farm
        shutil.copytree(source,work/'source')
    else:
        run(['python3','tools/capture_esheep_cloud_checkpoint_source.py','--project',a.project,'--farm',str(a.farm),'--output',str(work/'source')], 'capture.log')
    if a.approved_source:
        run(['python3','tools/prepare_esheep_checkpoint_approved_metadata.py','--cloud-source',str(work/'source'),'--approved-source',str(a.approved_source.resolve())], 'approved-metadata.log')
    derived = a.derived_data.resolve() if a.derived_data else work/'DerivedData'
    run(['xcodebuild','-project','eSheepNext.xcodeproj','-scheme','eSheepNext','-configuration','Release',
         '-destination',a.destination,'-derivedDataPath',str(derived),'build-for-testing','CODE_SIGNING_ALLOWED=NO','ARCHS=arm64','ENABLE_TESTABILITY=YES'], 'build.log')
    files = [p for p in (derived/'Build/Products').glob('*.xctestrun') if not p.name.startswith('CheckpointWorker')]
    if len(files) != 1: raise RuntimeError('Expected one xctestrun product')
    plan = plistlib.loads(files[0].read_bytes())
    targets = [t for c in plan.get('TestConfigurations',[]) for t in c.get('TestTargets',[]) if t.get('BlueprintName')=='eSheepNextTests']
    if len(targets) != 1: raise RuntimeError('Expected one controlled Swift worker target')
    targets[0].setdefault('EnvironmentVariables',{}).update(ESHEEP_CHECKPOINT_SOURCE=str(work/'source'),ESHEEP_CHECKPOINT_OUTPUT=str(work/'candidate'))
    runner = files[0].parent/'CheckpointWorker.xctestrun'
    runner.write_bytes(plistlib.dumps(plan))
    run(['xcodebuild','test-without-building','-xctestrun',str(runner),'-destination',a.destination,
         '-only-testing:eSheepNextTests/ESheepCloudIntegratedTests/testRealCloudSourceBuildsCheckpointAndImportsWithoutHistoricalReceipts',
         '-parallel-testing-enabled','NO'], 'replay.log')
    run(['python3','tools/verify_esheep_checkpoint_candidate.py',str(work/'candidate')], 'independent-reconciliation.log')
    if not (work/'candidate/independent-reconciliation.json').exists(): raise RuntimeError('Worker was skipped or reconciliation is missing')
    identity=json.loads((work/'source/source.json').read_bytes())
    identity['sourceInventorySHA256']=hashlib.sha256((work/'source/inventory.json').read_bytes()).hexdigest()
    (work/'candidate/cloud-source-proof.json').write_text(json.dumps(identity,sort_keys=True))
    if a.approved_source:
        run(['python3','tools/verify_esheep_checkpoint_approved_history.py','--candidate',str(work/'candidate'),'--approved-source',str(a.approved_source.resolve())], 'approved-history-reconciliation.log')
    run(['python3','tools/verify_esheep_checkpoint_purpose_history.py','--candidate',str(work/'candidate'),'--cloud-source',str(work/'source')], 'purpose-history-reconciliation.log')
    print(f'Verified candidate: {work / "candidate"}')

if __name__ == '__main__': main()
