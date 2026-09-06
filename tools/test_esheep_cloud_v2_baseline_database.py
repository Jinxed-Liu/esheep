#!/usr/bin/env python3
"""Run pgTAP on a fresh schema, never on a production-shape data fixture.

The suite has global row-count assertions. Keep privileges (including test
role schema access), so this is not a --no-privileges rehearsal clone.
"""
import pathlib
import subprocess
import sys
from repair_esheep_cloud_v2_history import read, save, insert_rows
from publish_esheep_cloud_v2_baseline_repair import sql, BASE, OUT

DB = "esheep_baseline_empty_test_20260905_v3"


def main():
    if "--rerun" in sys.argv:
        assert sql("select count(*) from esheep_cloud.commands;",DB)=="0"
        return run_tests()
    assert not sql(f"select 1 from pg_database where datname='{DB}';", "postgres")
    sql(f"create database {DB} owner supabase_admin;", "postgres")
    schema=subprocess.run(["docker","exec","supabase_db_eSheepNext","pg_dump",
        "-U","supabase_admin","-d","postgres","--schema-only","--no-owner"],
        text=True,capture_output=True,check=True).stdout
    sql(schema, DB)
    root=pathlib.Path("backups/cloud-v2-history-repair-20260905")
    for function in read(root/"source/cloud-function-definitions.json"):
        sql(function["definition"]+";", DB)
    sql(insert_rows("esheep_cloud.command_catalog",read(root/"catalogue.json")),DB)
    migration=pathlib.Path("supabase/migrations/20260905043413_esheep_cloud_owner_history_repair.sql")
    sql("BEGIN;"+migration.read_text()+"COMMIT;",DB)
    # pgTAP deliberately SET ROLE postgres for fixture-only owner writes.
    # --no-owner imports are owned by supabase_admin, unlike a normal migrated
    # database. Restore that owner-equivalent access only in this empty local
    # harness, without granting anything to anon/authenticated/service_role.
    sql("GRANT USAGE ON SCHEMA public,esheep_cloud TO postgres; "
        "GRANT ALL ON ALL TABLES IN SCHEMA public,esheep_cloud TO postgres; "
        "GRANT ALL ON ALL SEQUENCES IN SCHEMA public,esheep_cloud TO postgres;",DB)
    run_tests()


def run_tests():
    test=pathlib.Path("supabase/tests/database/esheep_cloud_v2.test.sql")
    result=subprocess.run(BASE+["-d",DB],input=test.read_text(),text=True,capture_output=True)
    passed=sum(line.startswith("ok ") for line in result.stdout.splitlines())
    failed=[line for line in result.stdout.splitlines() if line.startswith("not ok ")]
    name="pgtap-final.json" if "--rerun" in sys.argv else "pgtap-empty-database-v3.json"
    save(OUT/name,{"exitCode":result.returncode,"passed":passed,
        "failed":failed,"stdout":result.stdout,"stderr":result.stderr,"database":DB})
    print(f"pgTAP: {passed}/150 passed; {len(failed)} failures; exit {result.returncode}")
    assert result.returncode==0 and passed==150 and not failed


if __name__=="__main__":main()
