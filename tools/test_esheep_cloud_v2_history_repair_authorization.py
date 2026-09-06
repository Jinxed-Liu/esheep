#!/usr/bin/env python3
"""Adversarial checks against the isolated server, all inside ROLLBACK."""
import base64
import copy
import datetime
import json
import uuid
from build_esheep_cloud_v2_baseline_repair import OUT, FARM, OWNER, read, save, canonical, digest, local_sql, sql_literal


def main(kind="migration.restoreRemoval", result_name="authorization-tests.json"):
    before=json.loads(local_sql("select row_to_json(s) from esheep_cloud.farm_state s;"))
    original=next(row for p in sorted((OUT/"signed").glob('*.json')) for row in read(p)
                  if json.loads(base64.b64decode(row['unsigned_command_base64']))['commandKind']==kind)
    command=json.loads(base64.b64decode(original["unsigned_command_base64"]))
    command.update(commandID=str(uuid.uuid4()),sourceRequestID=str(uuid.uuid4()),deviceSequence=90001)
    raw=canonical(command)
    candidate={"unsigned_command_base64":base64.b64encode(raw).decode(),
               "content_digest":digest(raw),"device_signature_base64":original["device_signature_base64"]}
    # This tests the private processor's authorization layer after transport
    # signature verification. Production must use the verified-signature RPC.
    wrapped=sql_literal(json.dumps(candidate))+"::jsonb"
    accepted=sql_literal(json.dumps(original))+"::jsonb"
    cid=command["commandID"]
    head=before["event_head"]
    def denied(message):
        return f"""BEGIN
 PERFORM esheep_cloud.process_command_v2('{FARM}',3,'{OWNER}',{wrapped});
 RAISE EXCEPTION 'unexpectedly accepted';
EXCEPTION WHEN insufficient_privilege THEN
 IF SQLERRM<>{sql_literal(message)} THEN RAISE; END IF;
END;"""
    sql=f"""BEGIN;
DO $$ DECLARE result jsonb; BEGIN
-- 1. Membership alone does not authorize baseline repair.
{denied('esheep_cloud_history_repair_not_approved')}
-- 2. A stale reviewed head is rejected.
INSERT INTO esheep_cloud.history_repair_approvals(command_id,farm_id,farm_generation,
 approved_by_user_id,command_kind,content_digest,source_manifest_digest,expected_event_head,expires_at)
VALUES('{cid}','{FARM}',3,'{OWNER}','{kind}','{digest(raw)}',repeat('a',64),{head-1},now()+interval '1 day');
{denied('esheep_cloud_history_repair_not_approved')}
-- 3. Wrong content, despite matching owner and head, is rejected.
UPDATE esheep_cloud.history_repair_approvals SET expected_event_head={head},content_digest=repeat('b',64) WHERE command_id='{cid}';
{denied('esheep_cloud_history_repair_not_approved')}
-- 4. Expired authorization is rejected.
UPDATE esheep_cloud.history_repair_approvals SET content_digest='{digest(raw)}',expires_at=now()-interval '1 hour' WHERE command_id='{cid}';
{denied('esheep_cloud_history_repair_not_approved')}
-- 5. Workers cannot use even an otherwise matching approved command.
UPDATE esheep_cloud.history_repair_approvals SET expires_at=now()+interval '1 day' WHERE command_id='{cid}';
UPDATE public.farm_members SET role='worker' WHERE farm_id='{FARM}' AND user_id='{OWNER}';
{denied('esheep_cloud_command_permission_denied')}
UPDATE public.farm_members SET role='owner' WHERE farm_id='{FARM}' AND user_id='{OWNER}';
-- 6. Retrying an accepted command returns its original receipt after expiry.
UPDATE esheep_cloud.history_repair_approvals SET expires_at=now()-interval '1 hour'
WHERE command_id='{json.loads(base64.b64decode(original['unsigned_command_base64']))['commandID']}';
result:=esheep_cloud.process_command_v2('{FARM}',3,'{OWNER}',{accepted});
IF result->>'type'<>'duplicate' OR result->'original'->>'type'<>'accepted' THEN
 RAISE EXCEPTION 'idempotent retry failed'; END IF;
IF (SELECT event_head FROM esheep_cloud.farm_state WHERE farm_id='{FARM}')<>{head} THEN
 RAISE EXCEPTION 'security checks changed ledger'; END IF;
END $$;
ROLLBACK;
"""
    local_sql(sql)
    assert json.loads(local_sql("select row_to_json(s) from esheep_cloud.farm_state s;"))==before
    acl=json.loads(local_sql("""select json_build_object('rls',relrowsecurity,
      'anonInsert',has_table_privilege('anon','esheep_cloud.history_repair_approvals','INSERT'),
      'authenticatedInsert',has_table_privilege('authenticated','esheep_cloud.history_repair_approvals','INSERT'))
      from pg_class where oid='esheep_cloud.history_repair_approvals'::regclass;"""))
    assert acl=={"rls":True,"anonInsert":False,"authenticatedInsert":False}
    save(OUT/result_name,{"passed":True,"kind":kind,"adversarialChecks":6,"approvalTable":acl,"rolledBack":True})
    print("6/6 authorization/idempotency checks passed; RLS and approval write isolation passed")


if __name__=="__main__":
    import subprocess
    try: main()
    except subprocess.CalledProcessError as e:
        print(e.stderr[-2000:]);raise SystemExit(1)
