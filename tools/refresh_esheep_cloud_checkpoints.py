#!/usr/bin/env python3
"""Protected Mac worker: refresh each due farm from its verified cloud parent.

Default is audit-only. --execute captures immutable cloud input, runs the same
Swift reducer as the clients, compares all SQLite fields after a fresh import,
checks Web compatibility, then publishes. No farm data or prior chunks are deleted.
A farm without a verified parent requires bootstrap approval and is reported.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import uuid
from checkpoint_worker_api import source_call

ROOT = Path(__file__).resolve().parents[1]


def checkpoint_due(row, *, now=None, max_age_hours=24, max_tail_events=500):
    now = now or datetime.now(timezone.utc)
    boundary = row.get('boundary_event_sequence')
    if boundary is None:
        return True
    tail = row['event_head'] - boundary
    if tail <= 0:
        return False
    verified = datetime.fromisoformat(row['verified_at'].replace('Z', '+00:00'))
    return tail >= max_tail_events or (now - verified).total_seconds() >= max_age_hours * 3600



def main():
    p = argparse.ArgumentParser()
    p.add_argument('--project', required=True)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--execute', action='store_true')
    p.add_argument('--destination', help='Explicit installed iOS Simulator destination')
    p.add_argument('--derived-data', type=Path)
    p.add_argument('--prebuilt-test-plan', type=Path, help='Reuse the Xcode Cloud build-for-testing product')
    p.add_argument('--max-age-hours', type=int, default=24)
    p.add_argument('--max-tail-events', type=int, default=500)
    a = p.parse_args()
    if not re.fullmatch('[a-z]{20}', a.project): p.error('Invalid project reference')
    if a.execute and (not a.destination or not (a.derived_data or a.prebuilt_test_plan)):
        p.error('Execution requires destination and derived-data or prebuilt-test-plan')
    if a.max_age_hours < 1 or a.max_tail_events < 1: p.error('Thresholds must be positive')
    os.umask(0o077)
    a.output = a.output.resolve()
    a.output.parent.mkdir(parents=True, exist_ok=True)
    # Scope the worker lock to the project, across output timestamps.
    with (a.output.parent / (a.project + '.refresh.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run(a)


def run(a):
    rows = source_call(a.project, 'list')
    a.output.mkdir(parents=True, exist_ok=False)
    outcomes = []
    plan = a.prebuilt_test_plan.resolve() if a.prebuilt_test_plan else None
    def command(args, log):
        with log.open('w') as output:
            subprocess.run(args,cwd=ROOT,stdout=output,stderr=subprocess.STDOUT,check=True,timeout=3600)
    for row in rows:
        farm = str(uuid.UUID(row['farm_id']))
        outcome = {'farm_id':farm,'generation':row['farm_generation'],'status':'current'}
        outcomes.append(outcome)
        if not checkpoint_due(row,max_age_hours=a.max_age_hours,max_tail_events=a.max_tail_events): continue
        if row['boundary_event_sequence'] is None:
            outcome.update(status='bootstrap_required',reason='No verified cloud parent; use the bootstrap approval flow')
            continue
        outcome['status'] = 'due'
        if not a.execute: continue
        work = a.output / farm
        work.mkdir()
        try:
            if plan is None:
                derived = a.derived_data.resolve()
                products = derived/'Build/Products'
                command(['xcodebuild','-project','eSheepNext.xcodeproj','-scheme','eSheepNext','-configuration','Debug',
                    '-destination',a.destination,'-derivedDataPath',str(derived),'build-for-testing',
                    'CODE_SIGNING_ALLOWED=NO','ARCHS=arm64','SYMROOT='+str(products)],a.output/'build.log')
                plans = list(products.glob('eSheepNext*iphonesimulator*.xctestrun'))
                if len(plans) != 1: raise RuntimeError('Expected one simulator test plan')
                plan = plans[0]
            command(['python3','tools/capture_esheep_checkpoint_refresh_source.py','--project',a.project,
                '--farm',farm,'--output',str(work/'source')],work/'capture.log')
            settings = plistlib.loads(plan.read_bytes())
            targets = [t for c in settings['TestConfigurations'] for t in c['TestTargets'] if t.get('BlueprintName')=='eSheepNextTests']
            if len(targets)!=1: raise RuntimeError('Expected one controlled Swift worker')
            targets[0].setdefault('EnvironmentVariables',{}).update(
                ESHEEP_CHECKPOINT_SOURCE=str(work/'source'),ESHEEP_CHECKPOINT_OUTPUT=str(work/'candidate'))
            # Keep beside products so __TESTROOT__ continues to resolve correctly.
            worker_plan = plan.with_name('CheckpointRefreshWorker.xctestrun')
            worker_plan.write_bytes(plistlib.dumps(settings))
            command(['xcodebuild','test-without-building','-xctestrun',str(worker_plan),'-destination',a.destination,
                '-only-testing:eSheepNextTests/ESheepCloudIntegratedTests/testRealCloudSourceBuildsCheckpointAndImportsWithoutHistoricalReceipts',
                '-parallel-testing-enabled','NO'],work/'replay.log')
            command(['python3','tools/verify_esheep_checkpoint_candidate.py',str(work/'candidate')],work/'independent.log')
            command(['node','tools/verify_web_checkpoint.mjs',str(work/'candidate')],work/'web.log')
            command(['python3','tools/publish_esheep_checkpoint_refresh.py','--project',a.project,
                '--source',str(work/'source'),'--candidate',str(work/'candidate'),'--activate'],work/'publish.log')
            outcome['status'] = 'published'
        except (subprocess.SubprocessError, RuntimeError, OSError):
            outcome.update(status='failed',reason='Read private worker logs; previous checkpoint retained')
    (a.output/'refresh-report.json').write_text(json.dumps(outcomes,indent=2)+'\n')
    counts = {status:sum(row['status']==status for row in outcomes)
              for status in ('current','due','bootstrap_required','published','failed')}
    print(json.dumps(counts))
    if counts['failed'] or counts['bootstrap_required']: raise SystemExit(1)


if __name__ == '__main__':
    main()
