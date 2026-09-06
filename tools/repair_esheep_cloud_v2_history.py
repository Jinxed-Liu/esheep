#!/usr/bin/env python3
"""Evidence and isolated rehearsal for the owner-authorized Air V2 repair.

Remote access in `export` is SELECT-only. All results are stored privately;
stdout contains counts and hashes, never credentials or farm payloads.
"""
import argparse
import base64
import copy
import datetime
import decimal
import hashlib
import json
import pathlib
import subprocess
import uuid

FARM = "8b0fa55e-2a34-4398-ae77-7d7d3701c5dd"
PROJECT = "rnqrvthbunrzqtprquqx"
LOCAL_DB = "esheep_repair_20260905_v2"
DEVICE = str(uuid.uuid5(uuid.UUID(FARM), "history-repair-20260905-device"))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
    with path.open("xb") as handle:
        handle.write(data)
    path.chmod(0o600)
    return digest(data)


def remote_select(sql):
    assert sql.lstrip().lower().startswith("select ")
    result = subprocess.run(
        ["supabase", "db", "query", "--project-ref", PROJECT, "--linked", sql, "-o", "json"],
        capture_output=True, text=True, check=True, timeout=60,
    )
    return json.loads(result.stdout)["rows"]


def export(root):
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    state = remote_select(f"select * from esheep_cloud.farm_state where farm_id='{FARM}'")
    assert len(state) == 1 and state[0]["farm_generation"] == 2
    assert state[0]["event_head"] == 34842 and not state[0]["write_frozen"]
    if (root / "state.json").exists():
        assert json.loads((root / "state.json").read_text()) == state
    else:
        save(root / "state.json", state)
    count = remote_select(f"select count(*) n from esheep_cloud.commands where farm_id='{FARM}' and farm_generation=2")[0]["n"]

    def page(offset):
        cached = root / "commands" / f"page-{offset:06d}.json"
        if cached.exists():
            return len(json.loads(cached.read_text()))
        rows = remote_select(f"select * from esheep_cloud.commands where farm_id='{FARM}' and farm_generation=2 order by device_sequence,command_id limit 500 offset {offset}")
        save(root / "commands" / f"page-{offset:06d}.json", rows)
        print(f"exported commands {offset + len(rows)}/{count}", flush=True)
        return len(rows)

    assert sum(page(offset) for offset in range(0, count, 500)) == count
    metadata = {}
    for table in ("public.farm_registry", "public.farm_members", "esheep_cloud.farm_profiles", "esheep_cloud.assets", "esheep_cloud.field_device_watermarks", "esheep_cloud.migration_reconciliations"):
        metadata[table] = remote_select(f"select * from {table} where farm_id='{FARM}'")
    metadata["public.devices"] = remote_select(f"select * from public.devices where device_id in (select device_id from esheep_cloud.commands where farm_id='{FARM}')")
    metadata["esheep_cloud.command_catalog"] = remote_select("select * from esheep_cloud.command_catalog order by command_kind")
    metadata["esheep_cloud.snapshots"] = remote_select(f"select * from esheep_cloud.snapshots where snapshot_id='{state[0]['latest_snapshot_id']}'")
    save(root / "metadata.json", metadata)
    sources = remote_select(f"select * from public.farm_entities where farm_id='{FARM}' and entity_type='feed'")
    save(root / "legacy-feed-entities.json", sources)
    definitions = remote_select("select p.proname,pg_get_functiondef(p.oid) definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='esheep_cloud' order by p.proname")
    save(root / "cloud-function-definitions.json", definitions)
    after = remote_select(f"select * from esheep_cloud.farm_state where farm_id='{FARM}'")
    assert state == after, "farm changed during export; stop and reconcile"
    inventory = {str(p.relative_to(root)):digest(p.read_bytes()) for p in sorted(root.rglob("*.json"))}
    save(root / "sha256-inventory.json", inventory)
    print(json.dumps({"export_complete":True,"command_count":count,"legacy_feed_count":len(sources),"files":len(inventory)}), flush=True)


def read(path):
    return json.loads(path.read_text())


def bytea(value):
    # CLI serializes node-postgres Buffers as {type: Buffer, data: [...]},
    # whereas psql row_to_json emits PostgreSQL's hex representation.
    if isinstance(value, dict) and value.get("type") == "Buffer":
        return bytes(value["data"])
    assert isinstance(value, str) and value.startswith("\\x")
    return bytes.fromhex(value[2:])


def sql_literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def local_sql(sql):
    result = subprocess.run(
        ["docker", "exec", "-i", "supabase_db_eSheepNext", "psql", "-X", "-qAt", "-U", "supabase_admin", "-d", LOCAL_DB, "-v", "ON_ERROR_STOP=1"],
        input=sql, capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def insert_rows(table, rows):
    return f"insert into {table} select * from jsonb_populate_recordset(null::{table}, {sql_literal(json.dumps(rows, ensure_ascii=False))}::jsonb);"


def millis(iso):
    return round(datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)


def prepare(root):
    source = root / "source"
    for name, expected in read(source / "sha256-inventory.json").items():
        assert digest((source / name).read_bytes()) == expected, name
    rows = [r for p in sorted((source / "commands").glob("*.json")) for r in read(p)]
    assert len(rows) == 23825 and len({r["command_id"] for r in rows}) == len(rows)
    assert len({r["device_id"] for r in rows}) == 1
    rows.sort(key=lambda r: r["device_sequence"])
    assert all(r["status"] == "accepted" for r in rows)
    feeds = {r["entity_id"].lower():r for r in read(source / "legacy-feed-entities.json")}
    mapping = {r["command_id"]:str(uuid.uuid5(uuid.UUID(FARM), "repair-g3-command:" + r["command_id"])) for r in rows}
    audit, unsigned = [], []
    for ordinal, row in enumerate(rows, 1):
        raw = bytea(row["unsigned_command"])
        assert digest(raw) == row["content_digest"]
        command = json.loads(raw)
        original_payload = copy.deepcopy(command["payload"])
        if row["command_kind"] == "feed.record":
            entry = command["payload"]["body"]["record"]["_0"]
            assert not entry.get("excludedSheepIDs") and not entry.get("recipeID")
            source_row = feeds[entry["id"].lower()]
            payload = source_row["payload_json"]
            source_lines = {line["id"].lower():line for line in payload["feedLines"]}
            assert len(source_lines) == len(entry["lines"])
            assert payload["identifiers"]["penID"].lower() == entry["penID"].lower()
            assert payload["strings"]["mode"] == entry["mode"]
            assert millis(payload["dates"]["occurredAt"]) == entry["occurredAt"]
            assert payload["strings"].get("note", "") == entry.get("note", "")
            historic = {k:v for k,v in entry.items() if k not in ("excludedSheepIDs", "recipeID", "lines")}
            historic["legacySourceKey"] = "v2-history-repair:" + row["command_id"]
            historic["lines"] = []
            for line in entry["lines"]:
                old = source_lines[line["id"].lower()]
                assert old["ingredientID"].lower() == line["ingredientID"].lower()
                assert old["ingredientBatchID"].lower() == line["ingredientBatchID"].lower()
                assert decimal.Decimal(old["kilogramsText"]) == decimal.Decimal(line["kilogramsText"])
                assert old["ingredientNameSnapshot"] and old["nutrientSnapshotJSON"] and old["unitSnapshot"]
                replacement = {k:v for k,v in old.items() if k in (
                    "id", "ingredientID", "kilogramsText", "ingredientNameSnapshot",
                    "ingredientBatchNameSnapshot", "pricePerKilogramTextSnapshot",
                    "nutrientSnapshotJSON", "unitSnapshot", "dryMatterTextSnapshot")}
                replacement["kilogramsText"] = line["kilogramsText"]
                historic["lines"].append(replacement)
            command["commandKind"] = "feed.importHistorical"
            command["payload"] = {"kind":"feed.importHistorical", "body":{"importHistorical":{"_0":historic}}}
            audit.append({"originalCommandID":row["command_id"],"feedID":entry["id"],"originalPayload":original_payload,"repairedPayload":command["payload"],"sourcePayloadDigest":source_row["payload_digest"]})
        else:
            assert command["payload"] == original_payload
        command["commandID"] = mapping[row["command_id"]]
        command["sourceRequestID"] = str(uuid.uuid5(uuid.UUID(FARM), "repair-g3-source:" + row["source_request_id"]))
        command["farmGeneration"] = 3
        command["deviceID"] = DEVICE
        command["deviceSequence"] = ordinal
        command["prerequisiteCommandIDs"] = [mapping[p.lower()] for p in command.get("prerequisiteCommandIDs", [])]
        data = json.dumps(command, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
        unsigned.append({"unsigned_command_base64":base64.b64encode(data).decode(),"content_digest":digest(data)})
    assert len(audit) == 174
    if not (root / "catalogue.json").exists():
        save(root / "catalogue.json", remote_select("select * from esheep_cloud.command_catalog order by command_kind"))
    for offset in range(0, len(unsigned), 100):
        save(root / "unsigned" / f"batch-{offset:06d}.json", unsigned[offset:offset + 100])
    save(root / "feed-repair-preview.json", audit)
    save(root / "command-id-map.json", mapping)
    subprocess.run(["node", "tools/sign_esheep_cloud_v2_repair.mjs", str(root)], check=True)
    print(f"Prepared {len(unsigned)} commands; precisely {len(audit)} feed payloads repaired", flush=True)


def rehearse(root):
    assert local_sql("select count(*) from esheep_cloud.commands;") == "0", "use an empty isolated rehearsal database"
    source = root / "source"
    metadata = read(source / "metadata.json")
    definitions = read(source / "cloud-function-definitions.json")
    local_sql("\n".join(d["definition"] + ";" for d in definitions))
    sql = ["begin; set local session_replication_role=replica;"]
    owner = metadata["public.farm_registry"][0]["owner_user_id"]
    sql.append(f"insert into auth.users(id) values ('{owner}');")
    for table in ("public.farm_registry", "public.farm_members"):
        sql.append(insert_rows(table, metadata[table]))
    sql.append(insert_rows("esheep_cloud.command_catalog", read(root / "catalogue.json")))
    device = copy.deepcopy(metadata["public.devices"][0])
    device.update(device_id=DEVICE, display_name="Owner-authorized V2 history repair 20260905", public_key_jwk=read(root / "repair-public.json"), status="active", revoked_at=None)
    sql.append(insert_rows("public.devices", [device]))
    for table in ("esheep_cloud.farm_profiles", "esheep_cloud.assets"):
        transformed = copy.deepcopy(metadata[table])
        for row in transformed:
            row["farm_generation"] = 3
            if table.endswith("assets"):
                for field in ("thumbnail_path", "avatar_path", "original_path"):
                    row[field] = row[field].replace(f"{FARM}/2/", f"{FARM}/3/", 1)
        sql.append(insert_rows(table, transformed))
    sql.append(f"insert into esheep_cloud.farm_state(farm_id,farm_generation,status,v2_ready) values ('{FARM}',3,'active',true);")
    sql.append("commit;")
    local_sql("\n".join(sql))
    for p in sorted((root / "signed").glob("*.json")):
        sql = f"""begin;
do $$ declare item jsonb; r jsonb; begin
for item in select value from jsonb_array_elements({sql_literal(p.read_text())}::jsonb) loop
r := esheep_cloud.process_command_v2('{FARM}',3,'{owner}',item);
if r->>'type' <> 'accepted' then raise exception 'repair replay rejected: %', r; end if;
end loop; end $$; commit;"""
        try:
            local_sql(sql)
        except subprocess.CalledProcessError as error:
            print(f"Rehearsal failed at {p.name}: {error.stderr[-3000:]}", flush=True)
            raise RuntimeError("local replay failed") from None
        print(f"rehearsed {p.name}", flush=True)
    result = json.loads(local_sql(f"select esheep_cloud.farm_integrity_report_v2('{FARM}',3);"))
    save(root / "local-integrity.json", result)
    assert result["passed"], result["checks"]
    snapshot = local_sql(f"select esheep_cloud.build_snapshot_v2('{FARM}',3,500);")
    assert len(snapshot) == 36
    save(root / "local-snapshot-id.json", snapshot)
    print(f"Local snapshot ready: {snapshot}", flush=True)


def fixture(root):
    snapshot_id = read(root / "local-snapshot-id.json")
    snapshot = json.loads(local_sql(f"select row_to_json(s) from esheep_cloud.snapshots s where snapshot_id='{snapshot_id}';"))
    save(root / "validated-snapshot.json", snapshot)
    out = pathlib.Path("/tmp/esheep-cloud-v2-repair-acceptance")
    out.mkdir(mode=0o700, exist_ok=False)
    manifest = snapshot["manifest"]
    def camel(key):
        # Swift acronym spellings are part of the Codable contract.
        parts = key.split("_")
        return parts[0] + "".join({"id":"ID", "sha256":"SHA256"}.get(p, p.capitalize()) for p in parts[1:])
    converted = {camel(k):v for k,v in manifest.items()}
    converted["recordCounts"] = [{"recordType":k,"count":v} for k,v in manifest["record_counts"].items()]
    converted["chunks"] = [{camel(k):v for k,v in c.items()} for c in manifest["chunks"]]
    converted["assets"] = [{camel(k):v for k,v in a.items()} for a in manifest["assets"]]
    for field in ("createdAt","businessHistoryStartedAt","businessHistoryEndedAt"):
        if converted.get(field):
            converted[field] = millis(converted[field])
    profile = json.loads(bytes.fromhex(snapshot["farm_profile_data"][2:]))
    ticket = {"manifest":converted,"farmProfile":profile,"memberAccountID":profile["ownerAccountID"],"memberRole":"owner","membershipStatus":"active","expiresAt":int(datetime.datetime.now(datetime.timezone.utc).timestamp()*1000)+86400000}
    save(out / "ticket.json", ticket)
    for chunk in manifest["chunks"]:
        value = json.loads(local_sql(f"select row_to_json(c) from esheep_cloud.snapshot_chunks c where snapshot_id='{snapshot_id}' and chunk_index={chunk['index']};"))
        raw = bytes.fromhex(value["content_data"][2:])
        assert len(raw) == chunk["byte_count"] and digest(raw) == chunk["content_sha256"]
        path = out / f"chunk-{chunk['index']:05d}.json"
        with path.open("xb") as handle:
            handle.write(raw)
        path.chmod(0o600)
    save(root / "fixture-directory.json", str(out))
    print(f"Full-scale fixture: {out}", flush=True)


def postverify(root):
    state = remote_select(f"select * from esheep_cloud.farm_state where farm_id='{FARM}'")[0]
    assert state["farm_generation"] == 3 and state["event_head"] == 34842
    assert state["v2_ready"] and not state["write_frozen"] and state["last_integrity_report"]["passed"]
    assert state["latest_snapshot_id"] == read(root / "validated-snapshot.json")["snapshot_id"]
    counts = remote_select(f"select farm_generation,count(*) n from esheep_cloud.commands where farm_id='{FARM}' group by farm_generation order by farm_generation")
    assert counts == [{"farm_generation":2,"n":23825},{"farm_generation":3,"n":23825}]
    source = read(root / "source/metadata.json")
    old_snapshot = remote_select(f"select * from esheep_cloud.snapshots where snapshot_id='{source['esheep_cloud.snapshots'][0]['snapshot_id']}'")
    assert old_snapshot == source["esheep_cloud.snapshots"], "old immutable snapshot changed"
    assets = remote_select(f"select * from esheep_cloud.assets where farm_id='{FARM}'")
    expected = copy.deepcopy(source["esheep_cloud.assets"])
    for asset in expected:
        asset["farm_generation"] = 3
        for variant in ("thumbnail", "avatar", "original"):
            asset[variant+"_path"] = asset[variant+"_path"].replace(f"{FARM}/2/", f"{FARM}/3/")
    assert sorted(assets,key=lambda a:a["asset_id"]) == sorted(expected,key=lambda a:a["asset_id"])
    registry = remote_select(f"select provider,authority_generation,current_revision from public.farm_registry where farm_id='{FARM}'")[0]
    assert registry == {"provider":"esheep_cloud","authority_generation":3,"current_revision":source["public.farm_registry"][0]["current_revision"]}
    device = remote_select(f"select status,revoked_at from public.devices where device_id='{DEVICE}'")[0]
    assert device["status"] == "revoked" and device["revoked_at"]
    files = remote_select(f"""select count(*) filter(where current_object.id is not null) current_files,
count(*) filter(where old_object.id is not null) retained_files
from esheep_cloud.assets a cross join lateral (values(a.thumbnail_path),(a.avatar_path),(a.original_path)) p(path)
left join storage.objects current_object on current_object.bucket_id='esheep-cloud-assets' and current_object.name=p.path
left join storage.objects old_object on old_object.bucket_id='esheep-cloud-assets' and old_object.name=replace(p.path,'{FARM}/3/','{FARM}/2/')
where a.farm_id='{FARM}' and a.farm_generation=3""")[0]
    assert files == {"current_files":81,"retained_files":81}
    save(root / "post-publication-verification.json", {"passed":True,"state":state,"commands":counts,"registry":registry,"assetFiles":files,"repairDevice":device,"oldSnapshotUnchanged":True,"assetMetadataUnchangedExceptGenerationPaths":True})
    print("Independent post-publication verification passed")


def client_gate(root):
    result_path = "/tmp/esheep-cloud-v2-repair-cache-accepted.xcresult"
    summary = json.loads(subprocess.run(
        ["/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcresulttool", "get", "test-results", "summary", "--path", result_path, "--compact"],
        capture_output=True, text=True, check=True,
    ).stdout)
    assert summary["result"] == "Passed" and summary["failedTests"] == 0 and summary["skippedTests"] == 0
    fixture_root = pathlib.Path(read(root / "fixture-directory.json"))
    matches = [p for p in fixture_root.glob("run-*/acceptance.json")
               if summary["startTime"] <= p.stat().st_mtime <= summary["finishTime"]]
    assert len(matches) == 1, "exact full-scale acceptance evidence required"
    acceptance = read(matches[0])
    assert acceptance["activated"] and acceptance["eventHead"] == 34842
    assert acceptance["streamCount"] == 28954 and acceptance["assetCount"] == 27
    assert acceptance["elapsedSeconds"] < 600, "local acceptance exceeded hard duration bound"
    assert acceptance["snapshotID"].lower() == read(root / "validated-snapshot.json")["snapshot_id"]
    save(root / "client-release-gate.json", {
        "fullReplayPassed":True, "testFailures":0, "snapshotID":acceptance["snapshotID"],
        "summary":summary, "resultBundle":result_path, "acceptance":acceptance,
        "acceptanceSHA256":digest(matches[0].read_bytes()),
        "sourceFilesSHA256":{str(p):digest(p.read_bytes())
            for directory in (pathlib.Path("eSheepNext"), pathlib.Path("eSheepNextTests"))
            for p in sorted(directory.rglob("*.swift"))},
    })
    print(json.dumps({"clientGatePassed":True,"tests":summary["passedTests"],"elapsedSeconds":acceptance["elapsedSeconds"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["export", "prepare", "rehearse", "fixture", "client-gate", "postverify"])
    parser.add_argument("directory", type=pathlib.Path)
    args = parser.parse_args()
    {"export":export,"prepare":prepare,"rehearse":rehearse,"fixture":fixture,"client-gate":client_gate,"postverify":postverify}[args.action](args.directory)
