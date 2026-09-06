#!/usr/bin/env python3
"""Local-only full command replay and isolated client fixture generation."""
import datetime
import json
import pathlib
import shutil
import subprocess
from build_esheep_cloud_v2_extended_repair import OUT,FARM,OWNER,DEVICE,read,save
from publish_esheep_cloud_v2_baseline_repair import sql
from repair_esheep_cloud_v2_history import insert_rows,sql_literal

DB='esheep_extended_20260905_v1'


def main():
    assert not sql(f"select 1 from pg_database where datname='{DB}';",'postgres')
    sql(f'create database {DB} template esheep_publication_rehearsal_20260905;','postgres')
    migration=pathlib.Path('supabase/migrations/20260905043413_esheep_cloud_owner_history_repair.sql')
    sql('BEGIN;'+migration.read_text()+'COMMIT;',DB)
    old=read(pathlib.Path('backups/cloud-v2-history-repair-20260905/source/metadata.json'))
    device=dict(old['public.devices'][0]);device.update(device_id=DEVICE,user_id=OWNER,
        public_key_jwk=read(OUT/'repair-public.json'),status='active',revoked_at=None,
        display_name='Owner approved extended history repair')
    approvals=[{**a,'created_at':datetime.datetime.now(datetime.timezone.utc).isoformat()} for a in read(OUT/'approvals.json')]
    sql('BEGIN;'+insert_rows('public.devices',[device])+insert_rows('esheep_cloud.history_repair_approvals',approvals)+'COMMIT;',DB)
    for number,p in enumerate(sorted((OUT/'signed').glob('*.json'))):
        statement=f"""BEGIN; DO $$ DECLARE c jsonb; r jsonb; BEGIN
        FOR c IN SELECT value FROM jsonb_array_elements({sql_literal(p.read_text())}::jsonb) LOOP
        r:=esheep_cloud.process_command_v2('{FARM}',3,'{OWNER}',c);
        IF r->>'type'<>'accepted' THEN RAISE EXCEPTION 'extended repair rejected %',r; END IF;
        END LOOP; END $$; COMMIT;"""
        try:sql(statement,DB)
        except subprocess.CalledProcessError as e:print(e.stderr[-2500:]);raise
        if number%10==0:print(p.name,flush=True)
    report=json.loads(sql(f"select esheep_cloud.farm_integrity_report_v2('{FARM}',3);",DB))
    assert report['passed'] and report['event_head']==read(OUT/'summary.json')['targetHead']
    save(OUT/'local-integrity.json',report)
    records=json.loads(sql(f"""select json_agg((to_jsonb(e)-'event_body'-'occurred_at'-'received_at')||jsonb_build_object(
      'record_kind','event','event_body_canonical',esheep_cloud.canonical_json_text(e.event_body),
      'occurred_at_millis',round(extract(epoch from occurred_at)*1000)::bigint,
      'received_at_millis',round(extract(epoch from received_at)*1000)::bigint)
      order by event_sequence) from esheep_cloud.events e where farm_id='{FARM}' and farm_generation=3 and event_sequence>34842;""",DB))
    target=pathlib.Path('/tmp/esheep-cloud-v2-extended-acceptance');target.mkdir(mode=0o700,exist_ok=False)
    save(target/'tail.json',records)
    for name in ('expected-sheep.json','expected-business.json','summary.json'):shutil.copy2(OUT/name,target/name)
    for suffix in ('','-wal','-shm'):
        source=pathlib.Path('backups/device/20260905-air-count-audit-release/eSheepNext.store'+suffix)
        if source.exists():shutil.copy2(source,target/('air.store'+suffix))
    print('Full extended local ledger passed; client fixture prepared',flush=True)


if __name__=='__main__':main()
