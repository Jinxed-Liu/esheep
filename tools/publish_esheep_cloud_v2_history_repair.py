#!/usr/bin/env python3
"""Publish only the locally accepted, owner-authorized generation 3 repair.

The default prepares a reviewable SQL transaction. --apply executes it once.
No migration, DELETE, V1 data update, old event rewrite, or Storage overwrite.
"""
import argparse
import datetime
import json
import os
import pathlib
import shlex
import subprocess

from repair_esheep_cloud_v2_history import (
    FARM, DEVICE, LOCAL_DB, read, save, digest, local_sql, insert_rows, sql_literal,
)

TABLES = ["commands", "events", "streams", "farm_profiles",
          "field_device_watermarks", "snapshots", "snapshot_chunks"]


def prepare(root):
    gate = read(root / "client-release-gate.json")
    snapshot = read(root / "validated-snapshot.json")
    assert gate["fullReplayPassed"] and gate["testFailures"] == 0
    assert all(digest(pathlib.Path(p).read_bytes()) == expected
               for p,expected in gate["sourceFilesSHA256"].items()), "tested source changed"
    assert gate["snapshotID"].lower() == snapshot["snapshot_id"]
    assets = read(root / "asset-copy-evidence.json")
    assert len(assets) == 81 and all(a["verified"] for a in assets)
    assert len({a["destination"] for a in assets}) == 81
    source = read(root / "source/metadata.json")
    assert "$$" not in json.dumps(source["esheep_cloud.assets"]), "unexpected dollar delimiter in asset evidence"
    baseline = read(root / "source/state.json")[0]
    state = json.loads(local_sql("select row_to_json(s) from esheep_cloud.farm_state s;"))
    assert state["farm_generation"] == 3 and state["event_head"] == 34842
    assert state["latest_snapshot_id"] == snapshot["snapshot_id"]
    assert state["last_integrity_report"]["passed"]
    device = json.loads(local_sql(f"select row_to_json(d) from public.devices d where device_id='{DEVICE}';"))
    device["registered_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    # The exact backup values detect unrelated writes before changing pointers.
    asset_guards = "\n".join(
        f"if not exists(select 1 from esheep_cloud.assets a where a.asset_id='{a['asset_id']}' "
        f"and a is not distinct from jsonb_populate_record(null::esheep_cloud.assets,{sql_literal(json.dumps(a))}::jsonb)) then raise exception 'source asset changed'; end if;"
        for a in source["esheep_cloud.assets"]
    )
    storage_guards = "\n".join(
        f"if not exists(select 1 from storage.objects where bucket_id='esheep-cloud-assets' and name={sql_literal(a['destination'])}) "
        "then raise exception 'verified destination missing'; end if;"
        for a in assets
    )
    prefix = f"""BEGIN;
SET LOCAL statement_timeout='15min';
SET LOCAL lock_timeout='10s';
SELECT farm_id FROM esheep_cloud.farm_state WHERE farm_id='{FARM}' FOR UPDATE;
SELECT farm_id FROM public.farm_registry WHERE farm_id='{FARM}' FOR UPDATE;
SELECT asset_id FROM esheep_cloud.assets WHERE farm_id='{FARM}' FOR UPDATE;
DO $$ BEGIN
IF NOT EXISTS (SELECT 1 FROM esheep_cloud.farm_state WHERE farm_id='{FARM}'
 AND farm_generation=2 AND event_head=34842 AND v2_ready AND NOT write_frozen
 AND latest_snapshot_id='{baseline['latest_snapshot_id']}'
 AND projection_digest='{baseline['projection_digest']}') THEN RAISE EXCEPTION 'authority changed'; END IF;
IF NOT EXISTS (SELECT 1 FROM public.farm_registry WHERE farm_id='{FARM}'
 AND authority_generation=2 AND provider='esheep_cloud'
 AND current_revision={source['public.farm_registry'][0]['current_revision']}) THEN RAISE EXCEPTION 'registry changed'; END IF;
IF EXISTS(SELECT 1 FROM esheep_cloud.commands WHERE farm_id='{FARM}' AND farm_generation<>2)
 OR (SELECT count(*) FROM esheep_cloud.commands WHERE farm_id='{FARM}' AND farm_generation=2)<>23825
 OR (SELECT count(*) FROM esheep_cloud.events WHERE farm_id='{FARM}' AND farm_generation=2)<>34842
 OR (SELECT count(*) FROM esheep_cloud.streams WHERE farm_id='{FARM}' AND farm_generation=2)<>28954
 THEN RAISE EXCEPTION 'ledger baseline changed'; END IF;
{asset_guards}
{storage_guards}
END $$;
CREATE TEMP TABLE repair_old_ledger_digest ON COMMIT DROP AS
 SELECT 'commands' kind, md5(string_agg(command_id::text||content_digest||status,'' ORDER BY command_id)) digest
 FROM esheep_cloud.commands WHERE farm_id='{FARM}' AND farm_generation=2
 UNION ALL SELECT 'events',md5(string_agg(event_digest,'' ORDER BY event_sequence))
 FROM esheep_cloud.events WHERE farm_id='{FARM}' AND farm_generation=2
 UNION ALL SELECT 'streams',md5(string_agg(stream_type||stream_id::text||content_digest,'' ORDER BY stream_type,stream_id))
 FROM esheep_cloud.streams WHERE farm_id='{FARM}' AND farm_generation=2;
{insert_rows('public.devices', [device])}
"""
    suffix = f"""
DO $$ DECLARE n integer; report jsonb; BEGIN
UPDATE esheep_cloud.assets SET farm_generation=3,
 thumbnail_path=replace(thumbnail_path,'{FARM}/2/','{FARM}/3/'),
 avatar_path=replace(avatar_path,'{FARM}/2/','{FARM}/3/'),
 original_path=replace(original_path,'{FARM}/2/','{FARM}/3/')
 WHERE farm_id='{FARM}' AND farm_generation=2;
GET DIAGNOSTICS n=ROW_COUNT;
IF n<>27 THEN RAISE EXCEPTION 'asset count changed'; END IF;
UPDATE esheep_cloud.farm_state SET farm_generation=3,
 latest_snapshot_id='{snapshot['snapshot_id']}', projection_digest='{state['projection_digest']}',
 last_integrity_check_at=NULL,last_integrity_report='{{}}'::jsonb,updated_at=clock_timestamp()
 WHERE farm_id='{FARM}' AND farm_generation=2 AND event_head=34842;
GET DIAGNOSTICS n=ROW_COUNT;
IF n<>1 THEN RAISE EXCEPTION 'authority CAS failed'; END IF;
UPDATE public.farm_registry SET authority_generation=3,updated_at=clock_timestamp() WHERE farm_id='{FARM}' AND authority_generation=2;
GET DIAGNOSTICS n=ROW_COUNT;
IF n<>1 THEN RAISE EXCEPTION 'registry CAS failed'; END IF;
report:=esheep_cloud.audit_farm_integrity_v2('{FARM}',3);
IF NOT coalesce((report->>'passed')::boolean,false) THEN RAISE EXCEPTION 'repaired integrity failed: %',report; END IF;
IF (SELECT count(*) FROM esheep_cloud.commands WHERE farm_id='{FARM}' AND farm_generation=3)<>23825
 OR (SELECT count(*) FROM esheep_cloud.events WHERE farm_id='{FARM}' AND farm_generation=3)<>34842
 OR (SELECT count(*) FROM esheep_cloud.streams WHERE farm_id='{FARM}' AND farm_generation=3)<>28954
 OR (SELECT count(*) FROM esheep_cloud.commands WHERE farm_id='{FARM}' AND farm_generation=3 AND command_kind='feed.importHistorical')<>1208
 OR EXISTS(SELECT 1 FROM esheep_cloud.commands WHERE farm_id='{FARM}' AND farm_generation=3 AND command_kind='feed.record')
 THEN RAISE EXCEPTION 'repaired counts mismatch'; END IF;
IF EXISTS(
 (SELECT * FROM repair_old_ledger_digest EXCEPT
 (SELECT 'commands',md5(string_agg(command_id::text||content_digest||status,'' ORDER BY command_id)) FROM esheep_cloud.commands WHERE farm_id='{FARM}' AND farm_generation=2
 UNION ALL SELECT 'events',md5(string_agg(event_digest,'' ORDER BY event_sequence)) FROM esheep_cloud.events WHERE farm_id='{FARM}' AND farm_generation=2
 UNION ALL SELECT 'streams',md5(string_agg(stream_type||stream_id::text||content_digest,'' ORDER BY stream_type,stream_id)) FROM esheep_cloud.streams WHERE farm_id='{FARM}' AND farm_generation=2)))
 THEN RAISE EXCEPTION 'old ledger changed'; END IF;
-- Retain the repair public key for historical signature audit, but grant no
-- ongoing write capability to this one-time repair identity.
UPDATE public.devices SET status='revoked',revoked_at=clock_timestamp()
 WHERE device_id='{DEVICE}' AND status='active';
GET DIAGNOSTICS n=ROW_COUNT;
IF n<>1 THEN RAISE EXCEPTION 'repair identity closeout failed'; END IF;
END $$;
COMMIT;
SELECT json_build_object('published',true,'generation',farm_generation,'head',event_head,'snapshotID',latest_snapshot_id,'integrity',last_integrity_report->'passed')
 FROM esheep_cloud.farm_state WHERE farm_id='{FARM}';
"""
    output = root / "publish-transaction.sql"
    with output.open("xb") as handle:
        output.chmod(0o600)
        handle.write(prefix.encode())
        # Flush before a child process writes through the shared descriptor;
        # otherwise Python's buffered BEGIN/guards would land after the COPY.
        handle.flush()
        args = ["docker", "exec", "supabase_db_eSheepNext", "pg_dump", "-U", "supabase_admin", "-d", LOCAL_DB,
                "--data-only", "--no-owner", "--no-privileges"]
        for table in TABLES:
            args += ["-t", "esheep_cloud." + table]
        subprocess.run(args, stdout=handle, stderr=subprocess.PIPE, check=True)
        handle.write(suffix.encode())
    save(root / "publication-artifact.json", {"file":str(output), "sha256":digest(output.read_bytes()), "snapshotID":snapshot["snapshot_id"]})
    print("Prepared guarded, single-transaction publication; not executed")


def apply(root):
    assert "$$" not in json.dumps(read(root / "source/metadata.json")["esheep_cloud.assets"])
    gate = read(root / "client-release-gate.json")
    assert all(digest(pathlib.Path(p).read_bytes()) == expected
               for p,expected in gate["sourceFilesSHA256"].items()), "tested source changed"
    artifact = read(root / "publication-artifact.json")
    rehearsal = read(root / "publication-rehearsal-result.json")
    assert rehearsal["exitCode"] == 0 and rehearsal["artifactSHA256"] == artifact["sha256"], "exact publication rehearsal required"
    sql = root / "publish-transaction.sql"
    assert str(sql) == artifact["file"] and digest(sql.read_bytes()) == artifact["sha256"]
    with sql.open("rb") as handle:
        assert handle.read(7) == b"BEGIN;\n", "transaction guard must precede all COPY data"
    assert not (root / "publication-result.json").exists(), "already attempted publication; inspect evidence first"
    # Parse only known PG assignments; never execute the generated shell or
    # print its temporary password. Credentials live in this subprocess only.
    dry = subprocess.run(["supabase","db","dump","--linked","--schema","esheep_cloud","--dry-run"],capture_output=True,text=True,check=True)
    env = os.environ.copy()
    found = set()
    for line in dry.stdout.splitlines():
        if line.startswith("export PG"):
            parts = shlex.split(line)
            if len(parts) == 2 and "=" in parts[1]:
                name,value = parts[1].split("=",1)
                if name in {"PGHOST","PGPORT","PGUSER","PGPASSWORD","PGDATABASE"}:
                    env[name]=value
                    found.add(name)
    assert len(found)==5, "database connection not resolved"
    env["PGSSLMODE"]="require"
    # The CLI's temporary login role does not inherit private-schema access.
    # Match its normal --role postgres behavior in this same connection;
    # this uses existing role membership and creates no new database grant.
    result = subprocess.run(["/opt/homebrew/opt/libpq@18/bin/psql","-X","-qAt","-v","ON_ERROR_STOP=1","-c","SET ROLE postgres","-f",str(sql)],env=env,capture_output=True,text=True)
    save(root / "publication-result.json", {"exitCode":result.returncode,"stdout":result.stdout,"stderr":result.stderr})
    print(f"Publication exit code: {result.returncode}; private result evidence saved")
    assert result.returncode==0, "publication failed; inspect private evidence before retry"


if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("root",type=pathlib.Path)
    parser.add_argument("--apply",action="store_true")
    args=parser.parse_args()
    (apply if args.apply else prepare)(args.root)
