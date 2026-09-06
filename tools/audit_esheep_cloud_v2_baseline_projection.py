#!/usr/bin/env python3
"""Read-only business-field reconciliation of a replay copy, not a phone.

Differences are evidence, never an instruction to copy a developer database
over the cloud. Identity, audit/revision and derived-count models are separate.
"""
import collections
import json
import pathlib
import sqlite3
import sys
import uuid
from repair_esheep_cloud_v2_history import read, save
from build_esheep_cloud_v2_baseline_repair import OUT
from prepare_esheep_cloud_v2_baseline_repair import DEV_STORE

IGNORED={"Z_PK","Z_ENT","Z_OPT","ZCREATEDAT","ZUPDATEDAT","ZREVISION"}


def main():
    global OUT
    if '--extended' in sys.argv:
        from build_esheep_cloud_v2_extended_repair import OUT
    replay=pathlib.Path(sys.argv[1]).resolve()
    assert any(replay.is_relative_to(pathlib.Path(root).resolve()) for root in
               ('/tmp/esheep-cloud-v2-baseline-acceptance','/tmp/esheep-cloud-v2-extended-acceptance'))
    def connect(path):
        db=sqlite3.connect(path.resolve().as_uri()+"?mode=ro",uri=True)
        db.row_factory=sqlite3.Row
        db.execute("PRAGMA query_only=ON")
        assert db.execute("PRAGMA quick_check").fetchone()[0]=="ok"
        return db
    actual,expected=connect(replay),connect(DEV_STORE)
    def encoded(value):
        if isinstance(value,bytes):
            return str(uuid.UUID(bytes=value)) if len(value)==16 else value.hex()
        return value
    def rows(db,table):
        assert table.startswith('Z') and table.isalnum()
        columns={r[1] for r in db.execute(f'PRAGMA table_info({table})')}
        if 'ZID' not in columns:return {},set()
        query=f'SELECT * FROM {table}'
        if 'ZDELETEDAT' in columns:query+=' WHERE ZDELETEDAT IS NULL'
        return {r['ZID']:r for r in db.execute(query)},columns
    summary=[]
    details=[]
    inventory=read(pathlib.Path('backups/device/20260905-air-count-audit-report/summary.json'))
    for source in inventory['businessTables']:
        table=source['table']
        a,ac=rows(actual,table);e,ec=rows(expected,table)
        counts=collections.Counter()
        for identifier in a.keys()&e.keys():
            for field in (ac&ec)-IGNORED:
                av,ev=a[identifier][field],e[identifier][field]
                # The schema migrated optional legacy switches to an explicit
                # false value. This is not a business-state discrepancy.
                if field in ('ZLEGACYSTATUSSNAPSHOTISAUTHORITATIVE','ZLEGACYPENSNAPSHOTISAUTHORITATIVE'):
                    av,ev=bool(av),bool(ev)
                if field.endswith('JSON') and isinstance(av,str) and isinstance(ev,str):
                    try:
                        if json.loads(av)==json.loads(ev):continue
                    except ValueError:pass
                if field=='ZRECORDEDAT' and table=='ZTRANSFERRECORD' and av is not None and ev is not None:
                    if abs(av-ev)<0.001:continue
                if av!=ev:
                    counts[field]+=1
                    details.append({'table':table,'id':encoded(identifier),'field':field,
                                    'replay':encoded(av),'dev':encoded(ev)})
        summary.append({'table':table,'replayCount':len(a),'devCount':len(e),
            'replayOnlyIDs':sorted(encoded(i) for i in a.keys()-e.keys()),
            'devOnlyIDs':sorted(encoded(i) for i in e.keys()-a.keys()),
            'fieldDifferences':dict(sorted(counts.items()))})
    save(OUT/'post-repair-field-audit.json',{'replayCopy':str(replay),'developerReadOnlyCopy':str(DEV_STORE),
        'ignoredColumns':sorted(IGNORED),'tables':summary,'differences':details,
        'allBusinessFieldsEqual':not details and all(not s['replayOnlyIDs'] and not s['devOnlyIDs'] for s in summary)})
    for s in summary:
        if s['fieldDifferences'] or s['replayOnlyIDs'] or s['devOnlyIDs']:
            print(s['table'],s['replayCount'],s['devCount'],s['fieldDifferences'])


if __name__=='__main__':main()
