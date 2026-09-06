#!/usr/bin/env python3
"""Replay the original commands locally, then exercise the exact publication SQL.

This database has independently generated old receipt IDs/timestamps; it tests
transaction mechanics and preservation, not a byte-identical production clone.
The original production ledger and snapshot remain retained separately.
"""
import base64
import json
import pathlib
import subprocess
import sys
from repair_esheep_cloud_v2_history import FARM, read, save, bytea, insert_rows, sql_literal, digest

DB = "esheep_publication_rehearsal_20260905"
BASE = ["docker","exec","-i","supabase_db_eSheepNext","psql","-X","-qAt","-U","supabase_admin","-v","ON_ERROR_STOP=1"]


def sql(value, database=DB):
    return subprocess.run(BASE+["-d",database],input=value,text=True,capture_output=True,check=True).stdout.strip()


def main(root):
    assert not sql(f"select 1 from pg_database where datname='{DB}';", "postgres"), "use a fresh isolated database"
    sql(f"create database {DB} owner supabase_admin;", "postgres")
    schema = subprocess.run(["docker","exec","supabase_db_eSheepNext","pg_dump","-U","supabase_admin","-d","postgres","--schema-only","--no-owner","--no-privileges"],capture_output=True,text=True,check=True).stdout
    sql(schema)
    for function in read(root / "source/cloud-function-definitions.json"):
        sql(function["definition"]+";")
    source = read(root / "source/metadata.json")
    owner = source["public.farm_registry"][0]["owner_user_id"]
    setup = ["begin; set local session_replication_role=replica;",
             f"insert into auth.users(id) values ('{owner}');",
             f"insert into public.profiles(user_id,app_account_id) values ('{owner}','{source['esheep_cloud.farm_profiles'][0]['owner_account_id']}');"]
    for table in ("public.farm_registry","public.farm_members","public.devices",
                  "esheep_cloud.farm_profiles","esheep_cloud.assets"):
        setup.append(insert_rows(table,source[table]))
    setup.append(insert_rows("esheep_cloud.command_catalog",read(root / "catalogue.json")))
    setup.append(f"insert into esheep_cloud.farm_state(farm_id,farm_generation,status,v2_ready) values ('{FARM}',2,'active',true);")
    setup.append("insert into storage.buckets(id,name) values ('esheep-cloud-assets','esheep-cloud-assets');")
    for copied in read(root / "asset-copy-evidence.json"):
        setup.append(f"insert into storage.objects(bucket_id,name) values ('esheep-cloud-assets',{sql_literal(copied['destination'])});")
    setup.append("commit;")
    sql("\n".join(setup))
    commands = [r for p in sorted((root / "source/commands").glob("*.json")) for r in read(p)]
    commands.sort(key=lambda r:r["device_sequence"])
    for offset in range(0,len(commands),100):
        wrappers = [{"unsigned_command_base64":base64.b64encode(bytea(c["unsigned_command"])).decode(),
                     "content_digest":c["content_digest"],
                     "device_signature_base64":base64.b64encode(bytea(c["device_signature"])).decode()}
                    for c in commands[offset:offset+100]]
        encoded=json.dumps(wrappers)
        assert "$$" not in encoded
        sql(f"""begin; do $$ declare c jsonb; r jsonb; begin
for c in select value from jsonb_array_elements({sql_literal(encoded)}::jsonb) loop
r:=esheep_cloud.process_command_v2('{FARM}',2,'{owner}',c);
if r->>'type'<>'accepted' then raise exception 'original replay rejected: %',r; end if;
end loop; end $$; commit;""")
        if offset % 2000 == 0:
            print(f"Original-command rehearsal {offset+len(wrappers)}/{len(commands)}",flush=True)
    # The baseline guard uses the saved production snapshot pointer/digest.
    # Locally regenerated old receipts have different timestamps and IDs;
    # their own preservation hashes are checked by the publication transaction.
    baseline=read(root / "source/state.json")[0]
    sql(f"update esheep_cloud.farm_state set latest_snapshot_id='{baseline['latest_snapshot_id']}',projection_digest='{baseline['projection_digest']}' where farm_id='{FARM}';")
    execute_publication(root)


def execute_publication(root):
    publication=root / "publish-transaction.sql"
    assert digest(publication.read_bytes()) == read(root / "publication-artifact.json")["sha256"]
    with publication.open("rb") as handle:
        result=subprocess.run(BASE+["-d",DB],stdin=handle,capture_output=True)
    save(root / "publication-rehearsal-result.json",{
        "exitCode":result.returncode,"stdout":result.stdout.decode(),"stderr":result.stderr.decode(),
        "artifactSHA256":digest(publication.read_bytes()),"database":DB,
    })
    assert result.returncode==0,"publication rehearsal failed; inspect private result"
    print("Exact publication transaction passed isolated rehearsal",flush=True)


if __name__=="__main__":
    (execute_publication if "--publish-only" in sys.argv[2:] else main)(pathlib.Path(sys.argv[1]))
