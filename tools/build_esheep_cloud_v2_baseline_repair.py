#!/usr/bin/env python3
"""Build the explicitly authorized forward repair; local rehearsal only.

Never connects to production for writes. Source artifacts remain immutable.
"""
import base64
import datetime
import json
import pathlib
import sqlite3
import subprocess
import uuid
import repair_esheep_cloud_v2_history as local_helpers
from repair_esheep_cloud_v2_history import FARM, read, save, digest, local_sql, insert_rows, sql_literal
from prepare_esheep_cloud_v2_baseline_repair import DEVICE, DEV_STORE, identifier

ROOT = pathlib.Path("backups/cloud-v2-baseline-repair-20260905")
OUT = ROOT / "execution-v2"
# Dedicated second candidate cloned from the unchanged pre-repair rehearsal.
# This never selects a remote database or modifies the failed first candidate.
local_helpers.LOCAL_DB = "esheep_baseline_20260905_v2"
ACCOUNT = "5d741fd3-9339-5597-a68c-d8b768e1527c"
OWNER = "fa0cfb7d-8b35-430e-8fd9-5a6768518699"


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def date(value):
    return None if value is None else round((value + 978307200) * 1000)


def build():
    OUT.mkdir(mode=0o700, exist_ok=False)
    for name, expected in read(ROOT / "capture-inventory.json").items():
        assert digest((ROOT / name).read_bytes()) == expected
    db = sqlite3.connect(DEV_STORE.resolve().as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA query_only=ON")
    assert db.execute("PRAGMA quick_check").fetchone()[0] == "ok"
    legacy = {r["entity_id"]:r for p in sorted((ROOT / "legacy-sheep").glob("*.json")) for r in read(p)}
    commands, approval, sources = [], [], []
    created = round(datetime.datetime.now(datetime.timezone.utc).timestamp()*1000)
    def append(kind, body, key, source, streams=None, original=None):
        nonlocal commands
        cid = str(uuid.uuid5(uuid.UUID(FARM), "owner-history-repair-20260905:"+key))
        command = original or {"accountID":ACCOUNT,"farmID":FARM,"farmGeneration":3,
            "protocolVersion":2,"schemaVersion":1,"commandKind":kind,
            "payload":{"kind":kind,"body":body},"affectedStreams":streams or [{"type":"migrationRepair","id":cid}],
            "affectedFields":[],"fieldChanges":[],"requiredAssetIDs":[],"prerequisiteCommandIDs":[],
            "commandID":cid,"sourceRequestID":str(uuid.uuid5(uuid.UUID(FARM),"owner-history-source:"+key)),
            "createdAt":created,"occurredAt":created}
        command["deviceID"] = DEVICE
        command["deviceSequence"] = len(commands)+1
        raw = canonical(command)
        head = 34842 + sum(len(c["affectedStreams"]) for c in commands)
        if kind.startswith("migration."):
            approval.append({"command_id":command["commandID"],"farm_id":FARM,"farm_generation":3,
                "approved_by_user_id":OWNER,"command_kind":kind,"content_digest":digest(raw),
                "source_manifest_digest":digest(canonical(source)),"expected_event_head":head,
                "expires_at":(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=2)).isoformat()})
        sources.append({"commandID":command["commandID"],"source":source})
        commands.append(command)

    # Restore by immutable revoke command ID, not random device-local tombstone
    # UUID. This works identically for an already activated and a fresh store.
    for revocation in read(ROOT / "disputed-removal-command-provenance.json"):
        if revocation["command_kind"] != "record.revoke": continue
        removal_id = revocation["unsigned"]["payload"]["body"]["tombstone"]["entityID"]
        row = db.execute("SELECT * FROM ZREMOVALRECORD WHERE ZID=?", (uuid.UUID(removal_id).bytes,)).fetchone()
        assert row and row["ZKINDRAWVALUE"] == "deceased" and row["ZDELETEDAT"] is None
        source = {"revocation":revocation,"ownerDecision":"restore_actual_death_20260905"}
        append("migration.restoreRemoval",{"restoreRemoval":{"removalID":removal_id,
            "sheepID":identifier(row["ZSHEEPID"]),"revokedByCommandID":revocation["command_id"],
            "sourceDigest":digest(canonical(source)),"reason":"所有者确认：测试时已恢复，实际死亡，保留原死亡事实"}},
            "death:"+removal_id.lower(),source)
    assert len(commands)==8

    expected = []
    for row in db.execute("SELECT * FROM ZSHEEPRECORD WHERE ZDELETEDAT IS NULL ORDER BY ZID"):
        sid = identifier(row["ZID"])
        assert sid in legacy and legacy[sid]["deleted_at"] is None
        fields = {"sheepID":sid,"purpose":row["ZPURPOSE"],"isBreedingRam":bool(row["ZISBREEDINGRAM"]),
            "status":row["ZSTATUSRAWVALUE"],"removedAt":date(row["ZREMOVEDAT"]),
            "legacyEarTag":row["ZLEGACYEARTAG"],"legacySourceKey":row["ZLEGACYSOURCEKEY"],
            "legacyStatusSnapshotIsAuthoritative":bool(row["ZLEGACYSTATUSSNAPSHOTISAUTHORITATIVE"]),
            "legacyPenSnapshotIsAuthoritative":bool(row["ZLEGACYPENSNAPSHOTISAUTHORITATIVE"]),
            "damProvenance":row["ZDAMPROVENANCERAWVALUE"],"sireProvenance":row["ZSIREPROVENANCERAWVALUE"]}
        for key,col in (("currentPenID","ZCURRENTPENID"),("damID","ZDAMID"),("sireID","ZSIREID")):
            fields[key] = identifier(row[col]) if row[col] is not None else None
        source = {"legacyEntity":legacy[sid],"approvedCurrentProjection":fields,
                  "basis":"Air sourced baseline plus accepted history and owner-approved pending operations"}
        fields["sourceDigest"] = digest(canonical(source))
        append("migration.restoreSheepBaseline",{"restoreSheepBaseline":{"_0":fields}},"sheep:"+sid,source)
        expected.append({**fields,"earTag":row["ZEARTAG"],"isHistoricalArchive":bool(row["ZISHISTORICALARCHIVE"])})
    # Restore qualification/profile baselines before validating the queued
    # pedigree confirmation. In the broken projection MG012934 lost its
    # breeding-ram flag; skipping that validation would mask a real dependency.
    for entry in read(ROOT / "pending-v2/approved-pending-operations.json"):
        c = entry["command"]
        assert c["affectedFields"]==[] and c["farmGeneration"]==3 and c["accountID"]==ACCOUNT
        append(c["commandKind"],c["payload"]["body"],entry["operationID"],entry,original=c)
    assert len(expected)==3264 and len(commands)==3297
    save(OUT / "expected-sheep.json",expected)
    save(OUT / "commands.json",commands)
    save(OUT / "approvals.json",approval)
    save(OUT / "source-evidence.json",sources)
    for offset in range(0,len(commands),100):
        save(OUT / "unsigned" / f"batch-{offset:06d}.json",[
            {"unsigned_command_base64":base64.b64encode(canonical(c)).decode(),"content_digest":digest(canonical(c))}
            for c in commands[offset:offset+100]])
    subprocess.run(["node","tools/sign_esheep_cloud_v2_repair.mjs",str(OUT)],check=True)
    print(f"Prepared {len(commands)} forward commands; head 34842 -> 38164; no production write")


def rehearse():
    assert json.loads(local_sql("select row_to_json(s) from esheep_cloud.farm_state s;"))["event_head"]==34842
    meta=read(pathlib.Path("backups/cloud-v2-history-repair-20260905/source/metadata.json"))
    device=dict(meta["public.devices"][0]);device.update(device_id=DEVICE,
        display_name="Owner approved baseline repair 20260905",public_key_jwk=read(OUT/"repair-public.json"),status="active",revoked_at=None)
    approvals=[{**a,"created_at":datetime.datetime.now(datetime.timezone.utc).isoformat()} for a in read(OUT/"approvals.json")]
    local_sql(f"BEGIN; INSERT INTO public.profiles(user_id,app_account_id) VALUES ('{OWNER}','{ACCOUNT}') ON CONFLICT DO NOTHING;"
              +insert_rows("public.devices",[device])+insert_rows("esheep_cloud.history_repair_approvals",approvals)+"COMMIT;")
    for p in sorted((OUT/"signed").glob("*.json")):
        sql=f"""BEGIN; DO $$ DECLARE c jsonb; r jsonb; BEGIN
FOR c IN SELECT value FROM jsonb_array_elements({sql_literal(p.read_text())}::jsonb) LOOP
r:=esheep_cloud.process_command_v2('{FARM}',3,'{OWNER}',c);
IF r->>'type'<>'accepted' THEN RAISE EXCEPTION 'repair rejected: %',r; END IF;
END LOOP; END $$; COMMIT;"""
        try: local_sql(sql)
        except subprocess.CalledProcessError as e:
            print(e.stderr[-2000:]);raise
        print(p.name,flush=True)
    report=json.loads(local_sql(f"select esheep_cloud.farm_integrity_report_v2('{FARM}',3);"))
    save(OUT/"local-integrity.json",report)
    assert report["passed"]
    tail=json.loads(local_sql(f"select json_agg(json_build_object('record_kind','event','record',row_to_json(e)) order by event_sequence) from esheep_cloud.events e where farm_id='{FARM}' and farm_generation=3 and event_sequence>34842;"))
    save(OUT/"tail-records.json",tail)
    print("Local forward ledger integrity passed",flush=True)


def fixture():
    # Flat record wire shape, with the exact authenticated canonical body and
    # millisecond timestamps used by SnapshotCodec (not row_to_json dates).
    records=json.loads(local_sql(f"""select json_agg(
      (to_jsonb(e)-'event_body'-'occurred_at'-'received_at') || jsonb_build_object(
        'record_kind','event','event_body_canonical',esheep_cloud.canonical_json_text(e.event_body),
        'occurred_at_millis',round(extract(epoch from occurred_at)*1000)::bigint,
        'received_at_millis',round(extract(epoch from received_at)*1000)::bigint)
      order by event_sequence) from esheep_cloud.events e
      where farm_id='{FARM}' and farm_generation=3 and event_sequence>34842;"""))
    target=pathlib.Path('/tmp/esheep-cloud-v2-baseline-acceptance')
    target.mkdir(mode=0o700,exist_ok=False)
    save(target/'tail.json',records)
    save(target/'expected-sheep.json',read(OUT/'expected-sheep.json'))
    save(target/'state.json',json.loads(local_sql('select row_to_json(s) from esheep_cloud.farm_state s;')))
    import shutil
    for suffix in ('','-wal','-shm'):
        source=pathlib.Path('backups/device/20260905-air-count-audit-release/eSheepNext.store'+suffix)
        if source.exists():shutil.copy2(source,target/('air.store'+suffix))
    print(target)


if __name__=="__main__":
    import sys
    (fixture if "--fixture" in sys.argv else rehearse if "--rehearse" in sys.argv else build)()
