#!/usr/bin/env python3
"""Owner-confirmed reconciliation inputs. No production write capability.

Captures immutable evidence and translates exactly the approved 25 queued
operations. It never marks the developer outbox confirmed or changes a store.
Historical baselines and disputed revocations remain separate input sets.
"""
import argparse
import base64
import datetime
import hashlib
import json
import pathlib
import sqlite3
import subprocess
import uuid

from repair_esheep_cloud_v2_history import FARM, remote_select, save, millis

DEVICE = str(uuid.uuid5(uuid.UUID(FARM), "confirmed-dev-import-20260905-device"))
DEV_STORE = pathlib.Path("backups/device/20260905-air-count-audit-dev/eSheepNext.store")


def identifier(value):
    if not isinstance(value, bytes) or len(value) != 16:
        raise ValueError("invalid persisted UUID")
    return str(uuid.UUID(bytes=value))


def translate(payload, entity_id):
    """Closed allow-list: no generic payload passthrough into V2."""
    if payload["kind"] == "transferSheep":
        body = {
            "sheepID": payload["identifiers"]["sheepID"],
            "occurredAt": millis(payload["dates"]["occurredAt"]),
            "note": payload["strings"]["note"],
        }
        pen = payload["optionalIdentifiers"].get("toPenID")
        if pen is not None:
            body["toPenID"] = pen
        return "transfer.record", {"transferSheep": body}, [
            {"type": "transfer", "id": entity_id},
            {"type": "sheepLocation", "id": body["sheepID"]},
        ], [], body["occurredAt"]
    if payload["kind"] != "care":
        raise ValueError("unapproved operation kind")
    care = payload["careCommand"]
    if len(care) != 1:
        raise ValueError("ambiguous care payload")
    if "setSheepPurpose" in care:
        body = care["setSheepPurpose"]
        if uuid.UUID(body["sheepID"]) != uuid.UUID(entity_id):
            raise ValueError("purpose target mismatch")
        if body["purpose"] != "繁殖母羊":
            raise ValueError("unapproved purpose")
        return "care.sheep.setPurpose", care, [
            {"type": "sheep", "id": entity_id},
            {"type": "sheepProfile", "id": entity_id},
        ], ["purpose"], millis(payload["dates"]["sheepPurposeChangedAt"])
    if "updateSheepPedigree" in care:
        body = care["updateSheepPedigree"]["_0"]
        if uuid.UUID(body["sheepID"]) != uuid.UUID(entity_id):
            raise ValueError("pedigree target mismatch")
        return "care.sheepPedigree.update", care, [
            {"type": "sheep", "id": entity_id},
            {"type": "sheepPedigree", "id": entity_id},
        ], ["dam", "sire", "semenDonor"], None
    raise ValueError("unapproved care operation")


def pending_rows(store):
    db = sqlite3.connect(store.resolve().as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA query_only=ON")
    assert db.execute("PRAGMA quick_check").fetchone()[0] == "ok"
    rows = db.execute("""SELECT o.ZID outbox_id,o.ZACCOUNTID account_id,
        o.ZFARMID farm_id,o.ZAUTHORITYGENERATION generation,
        o.ZDELIVERYPROVIDERRAWVALUE provider,o.ZERRORMESSAGE error,
        d.ZID operation_id,d.ZENTITYID entity_id,d.ZENTITYTYPE entity_type,
        d.ZPAYLOAD payload,d.ZPAYLOADDIGEST digest,d.ZCREATEDAT created_at,
        d.ZOCCURREDAT occurred_at,d.ZSOURCEREQUESTID source_request_id
        FROM ZOUTBOXITEM o JOIN ZDOMAINOPERATION d ON d.ZID=o.ZOPERATIONID
        WHERE o.ZSTATUSRAWVALUE <> 'confirmed' ORDER BY d.ZCREATEDAT,d.ZID""").fetchall()
    assert len(rows) == 25, "approved operation set changed"
    assert len({bytes(r["operation_id"]) for r in rows}) == 25
    assert len({bytes(r["outbox_id"]) for r in rows}) == 25
    return [dict(r) for r in rows]


def prepare(root, state):
    rows = pending_rows(DEV_STORE)
    audit, commands = [], []
    for sequence, row in enumerate(rows, 1):
        assert identifier(row["farm_id"]) == FARM
        assert row["generation"] == 1 and row["provider"] == "supabase"
        assert row["error"] == "farm_authority_not_writable"
        raw = bytes(row["payload"])
        assert hashlib.sha256(raw).hexdigest() == row["digest"]
        payload = json.loads(raw)
        entity_id, op_id = identifier(row["entity_id"]), identifier(row["operation_id"])
        kind, body, streams, fields, occurred = translate(payload, entity_id)
        created = round((row["created_at"] + 978307200) * 1000)
        occurred = occurred if occurred is not None else round((row["occurred_at"] + 978307200) * 1000)
        command = {
            "accountID": identifier(row["account_id"]), "farmID": FARM,
            "farmGeneration": state["farm_generation"], "deviceID": DEVICE,
            "deviceSequence": sequence, "protocolVersion": 2, "schemaVersion": 1,
            "commandID": str(uuid.uuid5(uuid.UUID(FARM), "confirmed-dev-operation:" + op_id)),
            "sourceRequestID": str(uuid.uuid5(uuid.UUID(FARM), "confirmed-dev-source:" + op_id)),
            "createdAt": created, "occurredAt": occurred,
            "commandKind": kind, "payload": {"kind": kind, "body": body},
            # V2 affectedFields contains observed versions/digests, not field
            # names. These immutable care/transfer commands have no legacy
            # field-level observation to invent; retain names in audit only.
            "affectedStreams": streams, "affectedFields": [], "fieldChanges": [],
            "requiredAssetIDs": [], "prerequisiteCommandIDs": [],
        }
        encoded = json.dumps(command, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
        commands.append({"unsigned_command_base64": base64.b64encode(encoded).decode(),
                         "content_digest": hashlib.sha256(encoded).hexdigest()})
        audit.append({"operationID": op_id, "outboxID": identifier(row["outbox_id"]),
                      "entityID": entity_id, "sourcePayloadSHA256": row["digest"],
                      "sourcePayload": payload, "affectedFieldKeys": sorted(set(fields)),
                      "command": command})
    kinds = [a["command"]["commandKind"] for a in audit]
    assert kinds.count("transfer.record") == 20
    assert kinds.count("care.sheep.setPurpose") == 4
    assert kinds.count("care.sheepPedigree.update") == 1
    save(root / "approved-pending-operations.json", audit)
    save(root / "pending-unsigned/batch-000000.json", commands)
    print("Prepared 25 approved operations; device store unchanged; not signed or published", flush=True)


def rehearse_pending(root):
    """Uses only the named disposable local rehearsal DB; always rolls back."""
    from repair_esheep_cloud_v2_history import local_sql, sql_literal, insert_rows
    state = json.loads(local_sql("select row_to_json(s) from esheep_cloud.farm_state s;"))
    assert state["farm_id"] == FARM and state["farm_generation"] == 3
    assert state["event_head"] == 34842
    rows = json.loads((root / "pending-unsigned/batch-000000.json").read_text())
    assert len(rows) == 25
    # Ephemeral signing key: never registers an identity on production.
    signing = subprocess.run(["node", "--input-type=module", "-e", """
        import crypto from 'node:crypto';
        let input=''; for await (const chunk of process.stdin) input+=chunk;
        const {privateKey,publicKey}=crypto.generateKeyPairSync('ec',{namedCurve:'prime256v1'});
        const rows=JSON.parse(input).map(row=>({...row,device_signature_base64:
          crypto.sign('sha256',Buffer.from(row.unsigned_command_base64,'base64'),
            {key:privateKey,dsaEncoding:'ieee-p1363'}).toString('base64')}));
        process.stdout.write(JSON.stringify({publicKey:publicKey.export({format:'jwk'}),rows}));
    """],input=json.dumps(rows),text=True,capture_output=True,check=True)
    signed = json.loads(signing.stdout)
    metadata = json.loads(pathlib.Path("backups/cloud-v2-history-repair-20260905/source/metadata.json").read_text())
    device = dict(metadata["public.devices"][0])
    device.update(device_id=DEVICE,public_key_jwk=signed["publicKey"],status="active",revoked_at=None,
                  display_name="Local-only approved pending operation rehearsal")
    owner = metadata["public.farm_registry"][0]["owner_user_id"]
    account = metadata["esheep_cloud.farm_profiles"][0]["owner_account_id"]
    # The earlier isolated fixture disabled FK triggers during bootstrap and
    # therefore lacks this profile row. Supply it inside the rolled-back test.
    sql = (f"BEGIN;\nINSERT INTO public.profiles(user_id,app_account_id) VALUES ('{owner}','{account}') ON CONFLICT DO NOTHING;\n"
           + insert_rows("public.devices", [device])) + f"""
DO $$ DECLARE c jsonb; first_result jsonb; repeated jsonb; h bigint; BEGIN
FOR c IN SELECT value FROM jsonb_array_elements({sql_literal(json.dumps(signed['rows']))}::jsonb) LOOP
 first_result:=esheep_cloud.process_command_v2('{FARM}',3,'{owner}',c);
 IF first_result->>'type'<>'accepted' THEN RAISE EXCEPTION 'rejected: %',first_result; END IF;
 SELECT event_head INTO h FROM esheep_cloud.farm_state WHERE farm_id='{FARM}';
 repeated:=esheep_cloud.process_command_v2('{FARM}',3,'{owner}',c);
 IF repeated->>'type'<>'duplicate' OR repeated->'original'<>first_result
 OR h<>(SELECT event_head FROM esheep_cloud.farm_state WHERE farm_id='{FARM}')
 THEN RAISE EXCEPTION 'duplicate changed ledger'; END IF;
END LOOP;
END $$;
SELECT json_build_object('accepted',25,'duplicateChecks',25,'eventHead',event_head)
FROM esheep_cloud.farm_state WHERE farm_id='{FARM}';
ROLLBACK;
"""
    result = json.loads(local_sql(sql))
    assert result["eventHead"] == 34892
    after = json.loads(local_sql("select row_to_json(s) from esheep_cloud.farm_state s;"))
    assert after == state
    save(root / "local-pending-rehearsal.json", {**result,"rolledBack":True,"productionWritten":False})
    print("Local server accepted 25/25; duplicate checks 25/25; transaction rolled back")


def capture(root):
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    state = remote_select(f"select * from esheep_cloud.farm_state where farm_id='{FARM}'")[0]
    assert state["farm_generation"] == 3 and state["event_head"] == 34842
    assert state["v2_ready"] and not state["write_frozen"]
    save(root / "cloud-state-before.json", state)
    n = remote_select(f"select count(*) n from public.farm_entities where farm_id='{FARM}' and entity_type='sheep'")[0]["n"]
    for offset in range(0, n, 500):
        rows = remote_select(f"select * from public.farm_entities where farm_id='{FARM}' and entity_type='sheep' order by entity_id limit 500 offset {offset}")
        save(root / f"legacy-sheep/page-{offset:06d}.json", rows)
        print(f"Captured legacy sheep {offset+len(rows)}/{n}", flush=True)
    audit = json.loads(pathlib.Path("backups/device/20260905-air-count-audit-report/summary.json").read_text())
    removal_ids = next(t["devOnlyIDs"] for t in audit["businessTables"] if t["table"] == "ZREMOVALRECORD")
    assert len(removal_ids) == 8
    filters = " or ".join(f"lower(affected_streams::text) like '%{i}%'" for i in removal_ids)
    provenance = remote_select(f"select command_id,command_kind,actor_user_id,occurred_at,source_request_id,convert_from(unsigned_command,'UTF8')::jsonb unsigned from esheep_cloud.commands where farm_id='{FARM}' and farm_generation=3 and ({filters}) order by device_sequence")
    save(root / "disputed-removal-command-provenance.json", provenance)
    assert len([r for r in provenance if r["command_kind"] == "record.revoke"]) == 8
    prepare(root, state)
    after = remote_select(f"select * from esheep_cloud.farm_state where farm_id='{FARM}'")[0]
    assert state == after, "cloud changed while capturing; reconcile before using evidence"
    save(root / "capture-inventory.json", {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob("*.json")})
    print("Evidence captured; no production write performed", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("--rehearse-pending", action="store_true",
                        help="Exercise 25 commands in the local DB and roll back; no production writes")
    args = parser.parse_args()
    if args.rehearse_pending:
        rehearse_pending(args.root)
    else:
        capture(args.root)
