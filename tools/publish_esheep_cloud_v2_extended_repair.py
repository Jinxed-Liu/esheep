#!/usr/bin/env python3
"""Forward-only atomic owner repair. Prepare, rehearse, seal, then explicit apply.

No generation switch, historical ledger update, snapshot replacement or V1
write. Production requires the exact tested candidate and compatible Air app.
"""
import argparse
import base64
import datetime
import json
import os
import pathlib
import shlex
import subprocess
from build_esheep_cloud_v2_extended_repair import ROOT,OUT,FARM,OWNER,DEVICE
from repair_esheep_cloud_v2_history import read,save,digest,sql_literal,insert_rows
from publish_esheep_cloud_v2_baseline_repair import sql,BASE

TARGET=OUT/'publication-v5'
MIGRATION=pathlib.Path('supabase/migrations/20260905043413_esheep_cloud_owner_history_repair.sql')
DB='esheep_extended_publication_20260905_v5'


def prepare():
    assert read(OUT/'semantic-reconciliation.json')['passed']
    TARGET.mkdir(mode=0o700,exist_ok=False)
    commands=read(OUT/'commands.json')
    signed=[r for p in sorted((OUT/'signed').glob('*.json')) for r in read(p)]
    assert len(commands)==len(signed)==14477
    for c,r in zip(commands,signed):
        raw=base64.b64decode(r['unsigned_command_base64'],validate=True)
        assert json.loads(raw)==c and digest(raw)==r['content_digest']
    subprocess.run(['node','--input-type=module','-e',"""
      import fs from 'node:fs'; import crypto from 'node:crypto';
      const root=process.argv[1];
      const key=crypto.createPublicKey({key:JSON.parse(fs.readFileSync(root+'/repair-public.json')),format:'jwk'});
      let count=0;
      for(const file of fs.readdirSync(root+'/signed').sort())
        for(const r of JSON.parse(fs.readFileSync(root+'/signed/'+file))) {
          if(!crypto.verify('sha256',Buffer.from(r.unsigned_command_base64,'base64'),
            {key,dsaEncoding:'ieee-p1363'},Buffer.from(r.device_signature_base64,'base64'))) throw Error('signature mismatch');
          count++;
        }
      if(count!==14477) throw Error('signature count');
    """,str(OUT)],check=True)
    before=read(ROOT/'state-before.json')[0]
    meta=read(pathlib.Path('backups/cloud-v2-history-repair-20260905/source/metadata.json'))
    now=datetime.datetime.now(datetime.timezone.utc).isoformat()
    device={**meta['public.devices'][0],'device_id':DEVICE,'user_id':OWNER,'status':'active',
      'revoked_at':None,'registered_at':now,'display_name':'Owner approved extended projection repair 20260905',
      'public_key_jwk':read(OUT/'repair-public.json')}
    approvals=[{**a,'created_at':now} for a in read(OUT/'approvals.json')]
    assert len(approvals)==14452
    preserved=f"""
SELECT 'registry' kind,md5(to_jsonb(r)::text) digest FROM public.farm_registry r WHERE farm_id='{FARM}'
UNION ALL SELECT 'assets',md5(string_agg(md5(to_jsonb(a)::text),'' ORDER BY asset_id)) FROM esheep_cloud.assets a WHERE farm_id='{FARM}'
UNION ALL SELECT 'snapshots',md5(string_agg(md5(to_jsonb(s)::text),'' ORDER BY snapshot_id)) FROM esheep_cloud.snapshots s WHERE farm_id='{FARM}'
UNION ALL SELECT 'snapshot_chunks',md5(string_agg(md5(to_jsonb(c)::text),'' ORDER BY c.snapshot_id,c.chunk_index))
 FROM esheep_cloud.snapshot_chunks c JOIN esheep_cloud.snapshots s USING(snapshot_id) WHERE s.farm_id='{FARM}'
"""
    # Keep one atomic transaction, but release each decoded input batch at the
    # DO boundary. Hash each immutable row BEFORE aggregation, so snapshot
    # bytes and command bodies never accumulate into a farm-sized text value.
    batches='\n'.join(f"""DO $$ DECLARE c jsonb; r jsonb; BEGIN
FOR c IN SELECT value FROM jsonb_array_elements({sql_literal(json.dumps(signed[start:start+250]))}::jsonb) LOOP
 r:=esheep_cloud.process_command_v2('{FARM}',3,'{OWNER}',c);
 IF r->>'type'<>'accepted' THEN RAISE EXCEPTION 'repair rejected: %',r; END IF;
END LOOP; END $$;""" for start in range(0,len(signed),250))
    statement=f"""BEGIN;
SET LOCAL statement_timeout='10min'; SET LOCAL lock_timeout='10s';
SET LOCAL work_mem='1MB';
SELECT farm_id FROM esheep_cloud.farm_state WHERE farm_id='{FARM}' FOR UPDATE;
SELECT farm_id FROM public.farm_registry WHERE farm_id='{FARM}' FOR UPDATE;
DO $$ BEGIN
IF NOT EXISTS(SELECT 1 FROM esheep_cloud.farm_state WHERE farm_id='{FARM}' AND farm_generation=3
 AND event_head=34842 AND v2_ready AND NOT write_frozen AND projection_digest='{before['projection_digest']}'
 AND latest_snapshot_id='{before['latest_snapshot_id']}') THEN RAISE EXCEPTION 'baseline changed'; END IF;
IF NOT EXISTS(SELECT 1 FROM public.farm_registry WHERE farm_id='{FARM}' AND provider='esheep_cloud'
 AND authority_generation=3 AND current_revision=2061 AND owner_user_id='{OWNER}') THEN RAISE EXCEPTION 'registry changed'; END IF;
IF EXISTS(SELECT 1 FROM public.devices WHERE device_id='{DEVICE}') THEN RAISE EXCEPTION 'repair identity already used'; END IF;
END $$;
CREATE TEMP TABLE extended_preserved ON COMMIT DROP AS {preserved};
CREATE TEMP TABLE extended_ledger_preserved ON COMMIT DROP AS
SELECT 'commands' kind,farm_generation,md5(string_agg(md5(to_jsonb(c)::text),'' ORDER BY command_id)) digest
 FROM esheep_cloud.commands c WHERE farm_id='{FARM}' GROUP BY farm_generation
UNION ALL SELECT 'events',farm_generation,md5(string_agg(md5(to_jsonb(e)::text),'' ORDER BY event_sequence))
 FROM esheep_cloud.events e WHERE farm_id='{FARM}' GROUP BY farm_generation;
{insert_rows('public.devices',[device])}
{insert_rows('esheep_cloud.history_repair_approvals',approvals)}
{batches}
DO $$ DECLARE report jsonb; BEGIN
IF NOT EXISTS(SELECT 1 FROM esheep_cloud.farm_state WHERE farm_id='{FARM}' AND farm_generation=3
 AND event_head=49344 AND latest_snapshot_id='{before['latest_snapshot_id']}' AND v2_ready AND NOT write_frozen)
 OR (SELECT count(*) FROM esheep_cloud.commands WHERE farm_id='{FARM}' AND farm_generation=3)<>38302
 THEN RAISE EXCEPTION 'result count mismatch'; END IF;
IF EXISTS(SELECT * FROM extended_preserved EXCEPT ({preserved})) THEN RAISE EXCEPTION 'registry/assets/snapshot/chunks changed'; END IF;
IF EXISTS(SELECT * FROM extended_ledger_preserved EXCEPT (
 SELECT 'commands',farm_generation,md5(string_agg(md5(to_jsonb(c)::text),'' ORDER BY command_id))
 FROM esheep_cloud.commands c WHERE farm_id='{FARM}' AND device_id<>'{DEVICE}' GROUP BY farm_generation
 UNION ALL SELECT 'events',farm_generation,md5(string_agg(md5(to_jsonb(e)::text),'' ORDER BY event_sequence))
 FROM esheep_cloud.events e WHERE farm_id='{FARM}' AND event_sequence<=34842 GROUP BY farm_generation))
 THEN RAISE EXCEPTION 'immutable ledger changed'; END IF;
report:=esheep_cloud.audit_farm_integrity_v2('{FARM}',3);
IF NOT coalesce((report->>'passed')::boolean,false) THEN RAISE EXCEPTION 'integrity failed: %',report; END IF;
UPDATE public.devices SET status='revoked',revoked_at=clock_timestamp() WHERE device_id='{DEVICE}' AND status='active';
IF NOT FOUND THEN RAISE EXCEPTION 'repair identity closeout failed'; END IF;
END $$;
COMMIT;
SELECT json_build_object('generation',farm_generation,'head',event_head,'digest',projection_digest,
 'snapshotID',latest_snapshot_id,'integrityPassed',last_integrity_report->'passed')
 FROM esheep_cloud.farm_state WHERE farm_id='{FARM}';
"""
    p=TARGET/'forward-transaction.sql';p.write_text(statement);p.chmod(0o600)
    files=[OUT/n for n in ('commands.json','approvals.json','expected-business.json','expected-sheep.json',
          'source-evidence.json','repair-public.json','semantic-reconciliation.json')]
    files += [MIGRATION,*sorted((OUT/'signed').glob('*.json'))]
    save(TARGET/'manifest.json',{'sha256':digest(p.read_bytes()),'sourceHashes':{str(p):digest(p.read_bytes()) for p in files},
      'commands':14477,'events':14502,'targetHead':49344,'productionExecuted':False})
    print('Signed, source-checked atomic transaction prepared; no production writes')


def check_artifact():
    m=read(TARGET/'manifest.json');p=TARGET/'forward-transaction.sql'
    assert digest(p.read_bytes())==m['sha256']
    assert all(digest(pathlib.Path(p).read_bytes())==h for p,h in m['sourceHashes'].items())
    return m,p


def rehearse():
    m,p=check_artifact()
    assert not sql(f"select 1 from pg_database where datname='{DB}';",'postgres')
    sql(f'create database {DB} template esheep_publication_rehearsal_20260905;','postgres')
    sql('BEGIN;'+MIGRATION.read_text()+'COMMIT;',DB)
    # Production postgres is not a superuser. Exercise the exact artifact as
    # an inheriting, explicitly non-superuser local role. The harness alone
    # sets the test disk cap before lowering privilege; do not grant the real
    # repair session permission to alter server resource limits.
    role='esheep_extended_publication_test'
    sql(f"DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='{role}') THEN CREATE ROLE {role} NOLOGIN NOSUPERUSER INHERIT; END IF; END $$; GRANT supabase_admin TO {role};",'postgres')
    prefix=f"SET temp_file_limit='512MB'; SET ROLE {role}; DO $$ BEGIN IF (SELECT rolsuper FROM pg_roles WHERE rolname=current_user) THEN RAISE EXCEPTION 'superuser rehearsal is not allowed'; END IF; END $$;\n"
    r=subprocess.run(BASE+['-d',DB],input=prefix+p.read_text(),text=True,capture_output=True)
    save(TARGET/'rehearsal-result.json',{'exitCode':r.returncode,'stdout':r.stdout,'stderr':r.stderr,
      'artifactSHA256':m['sha256'],'database':DB})
    assert r.returncode==0,'exact publication failed; evidence retained'
    print('Exact atomic publication transaction passed local rehearsal')


def seal():
    tests=[]
    for p,n in [('/tmp/esheep-extended-client-v2.xcresult',124),('/tmp/esheep-extended-regression-v1.xcresult',58)]:
        s=json.loads(subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',p,'--compact'],
          text=True,capture_output=True,check=True).stdout)
        assert s['result']=='Passed' and s['passedTests']==n and s['failedTests']==s['skippedTests']==0
        tests.append({'path':p,'summary':s})
    pg=read(OUT/'pgtap-empty-database-v3.json');assert pg['exitCode']==0 and pg['passed']==150 and not pg['failed']
    for name in ('business-authorization-tests.json','death-authorization-tests.json'):
        a=read(OUT/name);assert a['passed'] and a['adversarialChecks']==6
    assert read(OUT/'semantic-reconciliation.json')['passed']
    files=[*pathlib.Path('eSheepNext').rglob('*.swift'),*pathlib.Path('eSheepNextTests').rglob('*.swift'),
      pathlib.Path('eSheepNext/Localizable.xcstrings'),MIGRATION,pathlib.Path('eSheepNext.xcodeproj/project.pbxproj')]
    save(OUT/'local-gates.json',{'xctest':tests,'pgtapPassed':150,'authorizationChecks':12,'semanticReconciliationPassed':True,
      'sourceSHA256':{str(p):digest(p.read_bytes()) for p in files},
      'distributionScope':'local signed Release repair only; not App Store or TestFlight upload',
      'retailGateExceptions':['Staging local config absent (not targeted)','operator legal placeholders (no store submission)'],
      'productionWritten':False,'airUIAccepted':False})
    print('182 XCTest, 150 pgTAP, 12 authorization checks and semantic gate sealed')


def apply():
    m,p=check_artifact();g=read(OUT/'local-gates.json');installed=read(OUT/'air-compatible-install.json')
    assert installed['bundleID']=='com.sheepfarm.ios' and installed['build']=='18'
    assert installed['udid']=='00008150-000128C93640401C' and installed['installationVerified']
    assert all(digest(pathlib.Path(p).read_bytes())==h for p,h in g['sourceSHA256'].items())
    r=read(TARGET/'rehearsal-result.json');assert r['exitCode']==0 and r['artifactSHA256']==m['sha256']
    memory=read(TARGET/'memory-gate.json')
    assert memory['passed'] and memory['peakBackendResidentKiB']<384*1024
    assert memory['completeTransactionObserved'] and memory['artifactSHA256']==m['sha256']
    assert not (TARGET/'production-result.json').exists(),'already attempted; inspect evidence before retry'
    dry=subprocess.run(['supabase','db','dump','--linked','--schema','esheep_cloud','--dry-run'],capture_output=True,text=True,check=True)
    env=os.environ.copy();found=set()
    for line in dry.stdout.splitlines():
        if line.startswith('export PG'):
            parts=shlex.split(line)
            if len(parts)==2 and '=' in parts[1]:
                name,value=parts[1].split('=',1)
                if name in {'PGHOST','PGPORT','PGUSER','PGPASSWORD','PGDATABASE'}:env[name]=value;found.add(name)
    assert len(found)==5
    env['PGSSLMODE']='require'
    env['PGCONNECT_TIMEOUT']='20'
    r=subprocess.run(['/opt/homebrew/opt/libpq@18/bin/psql','-X','-qAt','-v','ON_ERROR_STOP=1',
      '-c','SET ROLE postgres','-f',str(p)],env=env,capture_output=True,text=True)
    save(TARGET/'production-result.json',{'exitCode':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'artifactSHA256':m['sha256']})
    assert r.returncode==0,'publication failed; do not blindly retry'
    print('Atomic forward repair committed; retained old ledger, snapshots and generation 3')


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=['prepare','rehearse','seal','apply'])
    globals()[p.parse_args().action]()
