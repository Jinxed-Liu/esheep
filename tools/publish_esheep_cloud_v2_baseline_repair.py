#!/usr/bin/env python3
"""Prepare/rehearse the forward-only owner repair; never auto-publish.

The SQL is one atomic transaction, not a replacement ledger. Production use
requires a compatible client on the named Air and completed release gates.
"""
import argparse
import base64
import datetime
import json
import pathlib
import subprocess

from repair_esheep_cloud_v2_history import read, save, digest, sql_literal, insert_rows
from build_esheep_cloud_v2_baseline_repair import ROOT, OUT, FARM, OWNER, DEVICE

BASE = ["docker", "exec", "-i", "supabase_db_eSheepNext", "psql", "-X", "-qAt",
        "-U", "supabase_admin", "-v", "ON_ERROR_STOP=1"]
REHEARSAL_DB = "esheep_baseline_publication_20260905"


def sql(value, database):
    return subprocess.run(BASE+["-d", database], input=value, text=True,
                          capture_output=True, check=True).stdout.strip()


def prepare():
    target = OUT / "publication"
    target.mkdir(mode=0o700, exist_ok=False)
    commands = read(OUT / "commands.json")
    signed = [r for p in sorted((OUT / "signed").glob("*.json")) for r in read(p)]
    assert len(commands) == len(signed) == 3297
    for command, wrapper in zip(commands, signed):
        raw = base64.b64decode(wrapper["unsigned_command_base64"], validate=True)
        assert json.loads(raw) == command and digest(raw) == wrapper["content_digest"]
    # Reverify every real P-256 signature without reading or emitting the key.
    subprocess.run(["node", "--input-type=module", "-e", """
      import fs from 'node:fs'; import crypto from 'node:crypto';
      const root=process.argv[1];
      const key=crypto.createPublicKey({key:JSON.parse(fs.readFileSync(root+'/repair-public.json')),format:'jwk'});
      let count=0;
      for (const file of fs.readdirSync(root+'/signed').sort()) {
        for (const row of JSON.parse(fs.readFileSync(root+'/signed/'+file))) {
          if (!crypto.verify('sha256',Buffer.from(row.unsigned_command_base64,'base64'),
            {key,dsaEncoding:'ieee-p1363'},Buffer.from(row.device_signature_base64,'base64'))) throw Error('signature mismatch');
          count++;
        }
      }
      if(count!==3297) throw Error('signature count');
    """, str(OUT)], check=True)
    baseline = read(ROOT / "cloud-state-before.json")
    meta = read(pathlib.Path("backups/cloud-v2-history-repair-20260905/source/metadata.json"))
    device = dict(meta["public.devices"][0])
    device.update(device_id=DEVICE, user_id=OWNER, status="active", revoked_at=None,
                  public_key_jwk=read(OUT/"repair-public.json"),
                  registered_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  display_name="Owner approved baseline repair 20260905")
    approvals = [{**a, "created_at":device["registered_at"]} for a in read(OUT/"approvals.json")]
    assert len(approvals) == 3272
    source_hashes = {str(p):digest(p.read_bytes()) for p in [
        OUT/"commands.json", OUT/"approvals.json", OUT/"source-evidence.json",
        OUT/"repair-public.json", OUT/"expected-sheep.json",
        *sorted((OUT/"signed").glob("*.json"))]}
    prefix = f"""BEGIN;
SET LOCAL statement_timeout='10min';
SET LOCAL lock_timeout='10s';
SELECT farm_id FROM esheep_cloud.farm_state WHERE farm_id='{FARM}' FOR UPDATE;
SELECT farm_id FROM public.farm_registry WHERE farm_id='{FARM}' FOR UPDATE;
DO $$ BEGIN
IF NOT EXISTS(SELECT 1 FROM esheep_cloud.farm_state WHERE farm_id='{FARM}'
 AND farm_generation=3 AND event_head=34842 AND v2_ready AND NOT write_frozen
 AND projection_digest='{baseline['projection_digest']}'
 AND latest_snapshot_id='{baseline['latest_snapshot_id']}') THEN RAISE EXCEPTION 'baseline changed'; END IF;
IF NOT EXISTS(SELECT 1 FROM public.farm_registry WHERE farm_id='{FARM}'
 AND provider='esheep_cloud' AND authority_generation=3 AND current_revision=2061
 AND owner_user_id='{OWNER}') THEN RAISE EXCEPTION 'registry changed'; END IF;
IF EXISTS(SELECT 1 FROM public.devices WHERE device_id='{DEVICE}') THEN RAISE EXCEPTION 'repair device already used'; END IF;
END $$;
CREATE TEMP TABLE baseline_repair_preserved ON COMMIT DROP AS
SELECT 'commands' kind, farm_generation generation,
 md5(string_agg(to_jsonb(c)::text,'' ORDER BY command_id)) digest
 FROM esheep_cloud.commands c WHERE farm_id='{FARM}' GROUP BY farm_generation
UNION ALL SELECT 'events',farm_generation,md5(string_agg(to_jsonb(e)::text,'' ORDER BY event_sequence))
 FROM esheep_cloud.events e WHERE farm_id='{FARM}' GROUP BY farm_generation;
CREATE TEMP TABLE baseline_repair_other_preserved ON COMMIT DROP AS
SELECT 'registry' kind,md5(to_jsonb(r)::text) digest FROM public.farm_registry r WHERE farm_id='{FARM}'
UNION ALL SELECT 'assets',md5(string_agg(to_jsonb(a)::text,'' ORDER BY asset_id)) FROM esheep_cloud.assets a WHERE farm_id='{FARM}'
UNION ALL SELECT 'snapshots',md5(string_agg(to_jsonb(s)::text,'' ORDER BY snapshot_id)) FROM esheep_cloud.snapshots s WHERE farm_id='{FARM}';
{insert_rows('public.devices',[device])}
{insert_rows('esheep_cloud.history_repair_approvals',approvals)}
"""
    body = f"""DO $$ DECLARE c jsonb; r jsonb; BEGIN
FOR c IN SELECT value FROM jsonb_array_elements({sql_literal(json.dumps(signed))}::jsonb) LOOP
r:=esheep_cloud.process_command_v2('{FARM}',3,'{OWNER}',c);
IF r->>'type'<>'accepted' THEN RAISE EXCEPTION 'forward repair rejected: %',r; END IF;
END LOOP; END $$;
"""
    suffix = f"""DO $$ DECLARE report jsonb; BEGIN
IF NOT EXISTS(SELECT 1 FROM esheep_cloud.farm_state WHERE farm_id='{FARM}' AND farm_generation=3 AND event_head=38164
 AND latest_snapshot_id='{baseline['latest_snapshot_id']}' AND v2_ready AND NOT write_frozen)
 OR (SELECT count(*) FROM esheep_cloud.commands WHERE farm_id='{FARM}' AND farm_generation=3)<>27122
 THEN RAISE EXCEPTION 'repair result count mismatch'; END IF;
IF EXISTS(SELECT * FROM baseline_repair_preserved EXCEPT
 (SELECT 'commands',farm_generation,md5(string_agg(to_jsonb(c)::text,'' ORDER BY command_id))
 FROM esheep_cloud.commands c WHERE farm_id='{FARM}' AND device_id<>'{DEVICE}' GROUP BY farm_generation
 UNION ALL SELECT 'events',farm_generation,md5(string_agg(to_jsonb(e)::text,'' ORDER BY event_sequence))
 FROM esheep_cloud.events e WHERE farm_id='{FARM}' AND event_sequence<=34842 GROUP BY farm_generation))
 THEN RAISE EXCEPTION 'immutable ledger changed'; END IF;
IF EXISTS(SELECT * FROM baseline_repair_other_preserved EXCEPT
 (SELECT 'registry',md5(to_jsonb(r)::text) FROM public.farm_registry r WHERE farm_id='{FARM}'
 UNION ALL SELECT 'assets',md5(string_agg(to_jsonb(a)::text,'' ORDER BY asset_id)) FROM esheep_cloud.assets a WHERE farm_id='{FARM}'
 UNION ALL SELECT 'snapshots',md5(string_agg(to_jsonb(s)::text,'' ORDER BY snapshot_id)) FROM esheep_cloud.snapshots s WHERE farm_id='{FARM}'))
 THEN RAISE EXCEPTION 'registry/assets/snapshot changed'; END IF;
report:=esheep_cloud.audit_farm_integrity_v2('{FARM}',3);
IF NOT coalesce((report->>'passed')::boolean,false) THEN RAISE EXCEPTION 'integrity failed: %',report; END IF;
UPDATE public.devices SET status='revoked',revoked_at=clock_timestamp() WHERE device_id='{DEVICE}' AND status='active';
IF NOT FOUND THEN RAISE EXCEPTION 'repair identity closeout failed'; END IF;
END $$;
COMMIT;
SELECT json_build_object('generation',farm_generation,'eventHead',event_head,'integrityPassed',last_integrity_report->'passed')
FROM esheep_cloud.farm_state WHERE farm_id='{FARM}';
"""
    transaction = target/"forward-transaction.sql"
    transaction.write_text(prefix+body+suffix)
    transaction.chmod(0o600)
    save(target/"manifest.json", {"sha256":digest(transaction.read_bytes()),
        "sourceHashes":source_hashes,"commandCount":3297,"eventCount":3322,
        "productionExecuted":False,"requiresCompatibleAirClient":True})
    print("Prepared atomic forward transaction; no production access")


def rehearse():
    target = OUT/"publication"
    manifest = read(target/"manifest.json")
    transaction = target/"forward-transaction.sql"
    assert digest(transaction.read_bytes()) == manifest["sha256"]
    assert all(digest(pathlib.Path(p).read_bytes())==h for p,h in manifest["sourceHashes"].items())
    assert not sql(f"select 1 from pg_database where datname='{REHEARSAL_DB}';", "postgres")
    sql(f"create database {REHEARSAL_DB} template esheep_publication_rehearsal_20260905;", "postgres")
    migration=pathlib.Path("supabase/migrations/20260905043413_esheep_cloud_owner_history_repair.sql")
    sql("BEGIN;"+migration.read_text()+"COMMIT;", REHEARSAL_DB)
    result=subprocess.run(BASE+["-d",REHEARSAL_DB],input=transaction.read_text(),text=True,capture_output=True)
    save(target/"rehearsal-result.json",{"exitCode":result.returncode,"stdout":result.stdout,
        "stderr":result.stderr,"artifactSHA256":manifest["sha256"],"database":REHEARSAL_DB})
    assert result.returncode==0,"rehearsal failed; inspect retained evidence before making another candidate"
    print("Exact forward transaction passed isolated rehearsal")


def seal_local_gates():
    results=[]
    for path, count in [("/tmp/esheep-baseline-final-gate.xcresult",121),
                        ("/tmp/esheep-baseline-regression-v2.xcresult",58)]:
        summary=json.loads(subprocess.run(["xcrun","xcresulttool","get","test-results","summary",
            "--path",path,"--compact"],text=True,capture_output=True,check=True).stdout)
        assert summary['result']=='Passed' and summary['passedTests']==count
        assert summary['failedTests']==0 and summary['skippedTests']==0
        results.append({'path':path,'summary':summary})
    database=read(OUT/'pgtap-final.json')
    assert database['exitCode']==0 and database['passed']==150 and not database['failed']
    reconciliation=read(OUT/'post-repair-field-audit.json')
    sources=[*pathlib.Path('eSheepNext').rglob('*.swift'),
             *pathlib.Path('eSheepNextTests').rglob('*.swift'),
             pathlib.Path('supabase/migrations/20260905043413_esheep_cloud_owner_history_repair.sql'),
             pathlib.Path('supabase/tests/database/esheep_cloud_v2.test.sql')]
    save(OUT/'local-gates.json',{'recordedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'xctest':results,'pgtapPassed':150,'authorization':read(OUT/'authorization-tests.json'),
        'sourceSHA256':{str(p):digest(p.read_bytes()) for p in sources},
        'allBusinessFieldsEqual':reconciliation['allBusinessFieldsEqual'],
        'productionReleaseAllowed':False,'airCompatibleClientInstalled':False,
        'blockingReason':'Additional batch/pen/lambing/history differences require separately scoped repair; Air locked',
        'fixtureSHA256':digest(pathlib.Path('/tmp/esheep-cloud-v2-baseline-acceptance/tail.json').read_bytes())})
    print('179/179 XCTest and 150/150 pgTAP recorded; production gate remains CLOSED')


if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--rehearse",action="store_true")
    parser.add_argument("--seal-local-gates",action="store_true")
    args=parser.parse_args()
    (seal_local_gates if args.seal_local_gates else rehearse if args.rehearse else prepare)()
