#!/usr/bin/env python3
"""Read-only candidate comparison with explicitly supplied owner-approved facts.

The approved source is evidence, never copied into the candidate. Later legitimate
business edits may fail this gate and require a new source-backed review.
"""
import argparse
import functools
import hashlib
import json
from pathlib import Path
import sqlite3
import uuid


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--approved-source',type=Path,required=True)
    args=parser.parse_args()
    root=args.approved_source.resolve(); candidate=args.candidate.resolve()
    proof=json.loads((root/'semantic-reconciliation.json').read_bytes())
    assert proof['passed'] and proof['tableCount']==46
    source_hashes={}
    def read(name):
        data=(root/name).read_bytes(); source_hashes[name]=hashlib.sha256(data).hexdigest()
        return json.loads(data)
    sheep=read('expected-sheep.json'); business=read('expected-business.json'); commands=read('commands.json')
    prior_audit=read('post-repair-field-audit.json')
    # Validate the approval's sealed input digests before trusting its facts.
    for path,expected in proof['sourceHashes'].items():
        name=Path(path).name
        if name in source_hashes: assert source_hashes[name]==expected, f'Approval source changed: {name}'
    db=sqlite3.connect((candidate/'imported.store').as_uri()+'?mode=ro',uri=True)
    db.row_factory=sqlite3.Row
    assert db.execute('pragma quick_check').fetchone()[0]=='ok'
    checks=0
    aliases={'status':'statusRawValue','kind':'kindRawValue','damProvenance':'damProvenanceRawValue','sireProvenance':'sireProvenanceRawValue'}
    @functools.lru_cache(maxsize=None)
    def row(table,identifier):
        result=db.execute(f'SELECT * FROM {table} WHERE ZID=?',(uuid.UUID(identifier).bytes,)).fetchall()
        assert len(result)==1,(table,identifier,'missing or duplicate')
        return result[0]
    def compare(table,identifier,field,expected):
        nonlocal checks
        column='Z'+aliases.get(field,field).upper()
        # Production batches store their enum under statusRawValue too.
        actual=row(table,identifier)[column]
        if expected is not None and (field.endswith('ID') or field=='id'):
            expected=uuid.UUID(expected).bytes
        if expected is not None and field.endswith('At'):
            expected=expected/1000-978307200
            assert actual is not None and abs(actual-expected)<0.001,(table,identifier,field)
        else:
            assert actual==expected,(table,identifier,field,actual,expected)
        checks+=1
    for fact in sheep:
        for field,value in fact.items():
            if field not in {'sheepID','sourceDigest'}: compare('ZSHEEPRECORD',fact['sheepID'],field,value)
    tables={'pen':'ZPENRECORD','batchMembership':'ZBATCHMEMBERSHIPRECORD','productionBatch':'ZPRODUCTIONBATCHRECORD',
            'lambingOffspring':'ZLAMBINGOFFSPRINGRECORD','reproduction':'ZREPRODUCTIONRECORD','transfer':'ZTRANSFERRECORD'}
    for item in business:
        assert len(item['projection'])==1
        kind,fact=next(iter(item['projection'].items())); table=tables[kind]
        for field,value in fact.items():
            if field in {'id','duplicateProjectionID'}: continue
            compare(table,fact['id'],field,value)
        if fact.get('duplicateProjectionID'):
            assert row(table,fact['duplicateProjectionID'])['ZDELETEDAT'] is not None
            assert db.execute('SELECT count(*) FROM ZTOMBSTONERECORD WHERE ZENTITYID=? AND ZOPERATIONID IS NOT NULL',
                              (uuid.UUID(fact['duplicateProjectionID']).bytes,)).fetchone()[0]==1
    deaths=[c['payload']['body']['restoreRemoval'] for c in commands if c['commandKind']=='migration.restoreRemoval']
    assert len(deaths)==8
    for fact in deaths:
        actual=row('ZREMOVALRECORD',fact['removalID'])
        assert actual['ZSHEEPID']==uuid.UUID(fact['sheepID']).bytes and actual['ZDELETEDAT'] is None
        assert actual['ZKINDRAWVALUE']=='deceased'
    for table_proof in prior_audit['tables']:
        table=table_proof['table']; assert table.startswith('Z') and table.isalnum()
        columns={r[1] for r in db.execute(f'pragma table_info({table})')}
        where=' WHERE ZDELETEDAT IS NULL' if 'ZDELETEDAT' in columns else ''
        assert db.execute(f'SELECT count(*) FROM {table}'+where).fetchone()[0]==table_proof['replayCount'], (table,'approved record count changed')
    derived_photo_locators=0
    for difference in prior_audit['differences']:
        actual=row(difference['table'],difference['id'])[difference['field']]
        expected=difference['replay']
        if difference['table']=='ZPHOTOASSETRECORD' and difference['field']=='ZCLOUDRECORDNAME' and expected is None and actual is not None:
            asset=row('ZESHEEPCLOUDASSETSTATE',difference['id'])
            assert asset['ZORIGINALSTATERAWVALUE']=='verified' and asset['ZORIGINALSHA256']
            key=f"{uuid.UUID(bytes=asset['ZFARMID'])}/{asset['ZFARMGENERATION']}/{difference['id'].lower()}/{asset['ZORIGINALSHA256']}/original.bin"
            assert actual==key, 'Photo locator differs from the verified cloud asset contract'
            derived_photo_locators+=1
            continue
        if isinstance(actual,bytes): actual=str(uuid.UUID(bytes=actual)) if len(actual)==16 else actual.hex()
        if isinstance(actual,float) and isinstance(expected,(int,float)):
            assert abs(actual-expected)<0.001, (difference['table'],difference['id'],difference['field'])
        else:
            assert actual==expected, (difference['table'],difference['id'],difference['field'])
    manifest_bytes=(candidate/'archive/manifest.json').read_bytes()
    manifest=json.loads(manifest_bytes)
    cloud_source=json.loads((candidate/'cloud-source-proof.json').read_bytes())
    assert cloud_source['head']==manifest['boundaryEventSequence']
    assert cloud_source['farmID'].lower()==manifest['farmID'].lower() and cloud_source['generation']==manifest['farmGeneration']
    report=dict(passed=True,boundary=manifest['boundaryEventSequence'],
                manifestSHA256=hashlib.sha256(manifest_bytes).hexdigest(),
                sourceInventorySHA256=cloud_source['sourceInventorySHA256'],approvedSheep=len(sheep),
                approvedBusinessFacts=len(business),approvedTableCounts=len(prior_audit['tables']),preservedClassifiedDifferences=len(prior_audit['differences'])-derived_photo_locators,sourceDerivedPhotoLocators=derived_photo_locators,comparedFields=checks,restoredDeaths=len(deaths),sourceHashes=source_hashes,
                scope='Owner-approved repaired facts; complete baseline/import scalar equality is a separate gate')
    (candidate/'approved-history-reconciliation.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report))

if __name__=='__main__': main()
