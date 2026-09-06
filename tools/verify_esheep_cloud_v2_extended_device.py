#!/usr/bin/env python3
"""Reconcile a read-only copied Air store; never opens the live phone database."""
import json
import pathlib
import sqlite3
import sys
import uuid
from build_esheep_cloud_v2_extended_repair import OUT,FARM
from repair_esheep_cloud_v2_history import read,save,digest
from verify_esheep_cloud_v2_extended_reconciliation import SCOPED
from audit_esheep_cloud_v2_baseline_projection import IGNORED


def main():
    path=pathlib.Path(sys.argv[1]).resolve()
    assert path.is_relative_to(pathlib.Path('/tmp/esheep-cloud-v2-extended-acceptance').resolve())
    def db(p):
        c=sqlite3.connect(p.resolve().as_uri()+'?mode=ro',uri=True);c.row_factory=sqlite3.Row
        c.execute('PRAGMA query_only=ON');assert c.execute('PRAGMA quick_check').fetchone()[0]=='ok'
        return c
    actual=db(path);baseline=read(OUT/'post-repair-field-audit.json')
    expected=db(pathlib.Path(baseline['replayCopy']))
    farm=uuid.UUID(FARM).bytes
    state=dict(actual.execute('SELECT * FROM ZESHEEPCLOUDFARMSTATE WHERE ZFARMID=?',(farm,)).fetchone())
    assert state['ZFARMGENERATION']==3 and state['ZLASTAPPLIEDEVENTSEQUENCE']==49344,state['ZLASTAPPLIEDEVENTSEQUENCE']
    repair=read(OUT/'publication-v5/production-result.json')
    server=json.loads(repair['stdout'].splitlines()[-1])
    assert state['ZPROJECTIONDIGEST']==server['digest']
    ledger_counts={}
    for table,expected_count in [('ZESHEEPCLOUDEVENTRECEIPT',49344),
        ('ZESHEEPCLOUDSTREAMSTATE',43433),('ZESHEEPCLOUDASSETSTATE',27)]:
        n=actual.execute(f'SELECT count(*) FROM {table} WHERE ZFARMID=? AND ZFARMGENERATION=3',(farm,)).fetchone()[0]
        assert n==expected_count,(table,n)
        ledger_counts[table]=n
    differences=[];counts=[]
    def rows(c,t):
        cols={r[1] for r in c.execute(f'PRAGMA table_info({t})')}
        if 'ZID' not in cols:return {},cols
        q=f'SELECT * FROM {t}'
        if 'ZDELETEDAT' in cols:q+=' WHERE ZDELETEDAT IS NULL'
        return {r['ZID']:r for r in c.execute(q)},cols
    for t in baseline['tables']:
        name=t['table'];a,ac=rows(actual,name);e,ec=rows(expected,name)
        assert a.keys()==e.keys(),(name,'identity mismatch')
        counts.append({'table':name,'count':len(a)})
        if name not in SCOPED:continue
        for sid,r in a.items():
            for col in (ac&ec)-IGNORED:
                av,ev=r[col],e[sid][col]
                if col in ('ZLEGACYPENSNAPSHOTISAUTHORITATIVE','ZLEGACYSTATUSSNAPSHOTISAUTHORITATIVE'):av,ev=bool(av),bool(ev)
                if col=='ZRECORDEDAT' and name=='ZTRANSFERRECORD' and av is not None and ev is not None and abs(av-ev)<0.001:continue
                if av!=ev:differences.append({'table':name,'id':str(uuid.UUID(bytes=sid)),'field':col})
    present=actual.execute("SELECT count(*) FROM ZSHEEPRECORD WHERE ZFARMID=? AND ZDELETEDAT IS NULL AND ZSTATUSRAWVALUE='active' AND ZISHISTORICALARCHIVE=0",(farm,)).fetchone()[0]
    occupied=actual.execute("SELECT count(distinct s.ZCURRENTPENID) FROM ZSHEEPRECORD s JOIN ZPENRECORD p ON p.ZID=s.ZCURRENTPENID WHERE s.ZFARMID=? AND p.ZFARMID=s.ZFARMID AND s.ZDELETEDAT IS NULL AND s.ZSTATUSRAWVALUE='active' AND s.ZISHISTORICALARCHIVE=0 AND p.ZDELETEDAT IS NULL",(farm,)).fetchone()[0]
    deaths=actual.execute("SELECT s.ZEARTAG,r.ZKINDRAWVALUE FROM ZSHEEPRECORD s JOIN ZREMOVALRECORD r ON r.ZSHEEPID=s.ZID WHERE s.ZDELETEDAT IS NULL AND r.ZDELETEDAT IS NULL AND s.ZEARTAG IN ('8115','8116','8117','8118','8119','8120','8121','8122') ORDER BY s.ZEARTAG").fetchall()
    assert present==560 and occupied==19 and not differences
    assert len(deaths)==8 and all(r[1]=='deceased' for r in deaths)
    save(path.parent/'device-business-acceptance.json',{'passed':True,'udid':'00008150-000128C93640401C',
      'bundleID':'com.sheepfarm.ios','build':'18','eventHead':49344,'projectionDigest':state['ZPROJECTIONDIGEST'],
      'activeSheep':present,'occupiedPens':occupied,'retainedDeaths':[r[0] for r in deaths],
      'scopedFieldDifferences':differences,'allBusinessTableIdentities':counts,
      'ledgerCounts':ledger_counts,
      'sqliteQuickCheck':'ok','visualAcceptance':False,'copiedStore':str(path),
      'storeSHA256':digest(path.read_bytes())})
    print('Air business data verified: head 49344, 560 sheep, 19 occupied pens, 8 original deaths; UI remains separate')


if __name__=='__main__':main()
