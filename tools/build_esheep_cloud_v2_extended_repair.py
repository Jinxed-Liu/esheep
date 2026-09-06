#!/usr/bin/env python3
"""Build sourced, owner-approved business repairs, without production writes."""
import base64
import collections
import datetime
import json
import hashlib
import pathlib
import sqlite3
import subprocess
import uuid
from repair_esheep_cloud_v2_history import read,save,digest
from build_esheep_cloud_v2_baseline_repair import FARM,OWNER,ACCOUNT,DEVICE,canonical
from prepare_esheep_cloud_v2_baseline_repair import DEV_STORE

ROOT=pathlib.Path('backups/cloud-v2-extended-repair-20260905')
OUT=ROOT/'candidate-v1'
OLD=pathlib.Path('backups/cloud-v2-baseline-repair-20260905/execution-v2')


def identity(value):return None if value is None else str(uuid.UUID(bytes=value))
def millis(value):return None if value is None else (value+978307200)*1000
def time_value(value):
    if value is None:return None
    if isinstance(value,(int,float)):return value
    return datetime.datetime.fromisoformat(value.replace('Z','+00:00')).timestamp()*1000
def equal_date(a,b):return a==b or (a is not None and b is not None and abs(a-b)<1)


def sources():
    for p,h in read(ROOT/'inventory.json').items():assert digest((ROOT/p).read_bytes())==h
    result={}
    for path in sorted((ROOT/'source').glob('*/*.json')):
        for r in read(path):
            raw=base64.b64decode(r['payload_base64']) if r['payload_base64'] is not None else canonical(r['payload_json'])
            assert digest(raw)==r['payload_digest']
            result[(r['entity_type'],r['entity_id'])]=(r,json.loads(raw))
    return result


def build():
    if OUT.exists(): assert not any(OUT.iterdir()),'candidate artifacts already exist'
    OUT.mkdir(mode=0o700,exist_ok=True)
    db=sqlite3.connect(DEV_STORE.resolve().as_uri()+'?mode=ro',uri=True);db.row_factory=sqlite3.Row
    db.execute('PRAGMA query_only=ON');assert db.execute('PRAGMA quick_check').fetchone()[0]=='ok'
    source=sources()
    commands=read(OLD/'commands.json');approvals=read(OLD/'approvals.json');evidence=read(OLD/'source-evidence.json')
    approved_pending=read(pathlib.Path('backups/cloud-v2-baseline-repair-20260905/pending-v2/approved-pending-operations.json'))
    pending={e['command']['affectedStreams'][0]['id'].lower():e for e in approved_pending if e['command']['commandKind']=='transfer.record'}
    diffs=collections.defaultdict(set)
    for d in read(OLD/'post-repair-field-audit.json')['differences']:diffs[d['table']].add(d['id'])
    created=datetime.datetime.now(datetime.timezone.utc)
    head=38164
    counts=collections.Counter()
    expected=[]

    def append(case,value,proof):
        nonlocal head
        key=case+':'+value['id']
        cid=str(uuid.uuid5(uuid.UUID(FARM),'extended-owner-repair-20260905:'+key))
        source_hash=digest(canonical(proof))
        body={'restoreBusinessBaseline':{'_0':{'sourceDigest':source_hash,'projection':{case:value}}}}
        c={'accountID':ACCOUNT,'farmID':FARM,'farmGeneration':3,'deviceID':DEVICE,'deviceSequence':len(commands)+1,
           'protocolVersion':2,'schemaVersion':1,'commandKind':'migration.restoreBusinessBaseline',
           'payload':{'kind':'migration.restoreBusinessBaseline','body':body},
           'affectedStreams':[{'type':'migrationRepair','id':cid}],'affectedFields':[],'fieldChanges':[],
           'requiredAssetIDs':[],'prerequisiteCommandIDs':[],'commandID':cid,
           'sourceRequestID':str(uuid.uuid5(uuid.UUID(FARM),'extended-owner-repair-source:'+key)),
           'createdAt':round(created.timestamp()*1000),'occurredAt':round(created.timestamp()*1000)}
        approvals.append({'command_id':cid,'farm_id':FARM,'farm_generation':3,'approved_by_user_id':OWNER,
            'command_kind':c['commandKind'],'content_digest':digest(canonical(c)),
            'source_manifest_digest':source_hash,'expected_event_head':head,
            'expires_at':(created+datetime.timedelta(days=2)).isoformat()})
        commands.append(c);evidence.append({'commandID':cid,'source':proof});head+=1;counts[case]+=1
        expected.append({'sourceDigest':source_hash,'projection':{case:value}})

    def row(table,sid):
        value=db.execute(f'SELECT * FROM {table} WHERE ZID=? AND ZDELETEDAT IS NULL',(uuid.UUID(sid).bytes,)).fetchone()
        assert value is not None,(table,sid)
        return value

    for sid in sorted(diffs['ZPENRECORD']):
        r=row('ZPENRECORD',sid);entity,p=source[('pen',sid)]
        assert p['kind']=='setPenActive' and bool(p['integers']['isActive'])==bool(r['ZISACTIVE'])
        append('pen',{'id':sid,'isActive':bool(r['ZISACTIVE'])},{'legacyEntity':entity,'verifiedField':'isActive'})

    for sid in sorted(diffs['ZBATCHMEMBERSHIPRECORD']):
        r=row('ZBATCHMEMBERSHIPRECORD',sid);entity,p=source[('batchMembership',sid)]
        assert p['kind']=='assignBatchMembership',(sid,p['kind'])
        assert p['identifiers']['batchID'].lower()==identity(r['ZBATCHID'])
        assert p['identifiers']['sheepID'].lower()==identity(r['ZSHEEPID'])
        assert equal_date(time_value(p['dates']['joinedAt']),millis(r['ZJOINEDAT']))
        left=time_value(p['optionalDates'].get('leftAt'));reason=p['optionalStrings'].get('leaveReason')
        assert equal_date(left,millis(r['ZLEFTAT'])) and reason==r['ZLEAVEREASON'],('membership source mismatch',sid)
        append('batchMembership',{'id':sid,'batchID':identity(r['ZBATCHID']),'sheepID':identity(r['ZSHEEPID']),
            'joinedAt':millis(r['ZJOINEDAT']),'leftAt':left,'leaveReason':reason},{'legacyEntity':entity,'verifiedFields':['leftAt','leaveReason']})

    # Lifecycle is derived, not a separate operator decision: prove all 30
    # archived batches agree with the restored source membership intervals.
    for sid in sorted(diffs['ZPRODUCTIONBATCHRECORD']):
        r=row('ZPRODUCTIONBATCHRECORD',sid);entity,p=source[('productionBatch',sid)]
        members=list(db.execute('SELECT * FROM ZBATCHMEMBERSHIPRECORD WHERE ZBATCHID=? AND ZDELETEDAT IS NULL',(uuid.UUID(sid).bytes,)))
        assert members and all(m['ZLEFTAT'] is not None for m in members)
        assert r['ZSTATUSRAWVALUE']=='completed' and r['ZSOURCERAWVALUE']=='manual'
        assert max(m['ZLEFTAT'] for m in members)==r['ZENDEDAT']
        append('productionBatch',{'id':sid,'status':'completed','endedAt':millis(r['ZENDEDAT'])},
            {'legacyEntity':entity,'basis':'ProductionBatchLifecycle max(source-confirmed member leftAt)',
             'membershipIDs':[identity(m['ZID']) for m in members]})

    for sid in sorted(diffs['ZLAMBINGOFFSPRINGRECORD']):
        r=row('ZLAMBINGOFFSPRINGRECORD',sid);pid=identity(r['ZLAMBINGRECORDID']);entity,p=source[('reproduction',pid)]
        if p['kind']=='recordReproduction':
            child=next(c for c in p['lambingOffspring'] if c['id'].lower()==sid)
            assert child['sexRawValue']==r['ZSEXRAWVALUE']
            assert bool(child.get('isStillborn',False))==bool(r['ZISSTILLBORN'])
            assert bool(child.get('autoCreatedSheep',False))==bool(r['ZAUTOCREATEDSHEEP'])
            assert (child.get('autoBirthWeightRecordID') or '').lower()==(identity(r['ZAUTOBIRTHWEIGHTRECORDID']) or '')
        else:
            care=p['careCommand'];assert set(care)=={'recordLambing'},(pid,care.keys())
            draft=care['recordLambing']['_0'];child=next(c for c in draft['offspring'] if c['id'].lower()==sid)
            assert child['sex']==r['ZSEXRAWVALUE'] and child['createSheepRecord']==bool(r['ZAUTOCREATEDSHEEP'])
            assert bool(child.get('isStillborn',False))==bool(r['ZISSTILLBORN'])
            # Auto-weight ID is an existing local relationship, never a new
            # guessed UUID; verify its sheep/fact in the preserved source copy.
            if r['ZAUTOBIRTHWEIGHTRECORDID']:
                w=row('ZWEIGHTRECORD',identity(r['ZAUTOBIRTHWEIGHTRECORDID']))
                assert w['ZSHEEPID']==r['ZSHEEPID']
        append('lambingOffspring',{'id':sid,'lambingRecordID':pid,'sheepID':identity(r['ZSHEEPID']),
            'sexRawValue':r['ZSEXRAWVALUE'],'isStillborn':bool(r['ZISSTILLBORN']),
            'autoCreatedSheep':bool(r['ZAUTOCREATEDSHEEP']),'autoBirthWeightRecordID':identity(r['ZAUTOBIRTHWEIGHTRECORDID'])},
            {'legacyEntity':entity,'sourceChild':child,'verifiedLocalWeightID':identity(r['ZAUTOBIRTHWEIGHTRECORDID'])})

    for sid in sorted(diffs['ZREPRODUCTIONRECORD']):
        r=row('ZREPRODUCTIONRECORD',sid);entity,p=source[('reproduction',sid)]
        if p['kind']=='recordReproduction':
            assert p['identifiers']['eweID'].lower()==identity(r['ZEWEID'])
            assert p['optionalStrings'].get('paternalSource')==r['ZPATERNALSOURCERAWVALUE']
            assert (p['optionalIdentifiers'].get('batchID') or '').lower()==(identity(r['ZBATCHID']) or '')
        else:
            assert p['kind']=='care' and set(p['careCommand'])=={'recordLambing'}
            draft=p['careCommand']['recordLambing']['_0']
            assert draft['eweID'].lower()==identity(r['ZEWEID']) and r['ZKINDRAWVALUE']=='lambing'
            assert equal_date(time_value(draft['occurredAt']),millis(r['ZOCCURREDAT']))
            assert draft.get('semenID') is None
            assert (draft.get('sireID') or '').lower()==(identity(r['ZSIREID']) or '')
            assert r['ZPATERNALSOURCERAWVALUE']==('ram' if draft.get('sireID') else 'unknown')
        duplicate='01f6b45e-ea00-57e3-934b-a3f885bca6cb' if sid=='80052e79-aa05-232e-f8f8-48edb9141a31' else None
        duplicate_proof=None
        if duplicate:
            duplicate_proof=read(ROOT/'duplicate-abortion-command.json')[0]
            draft=duplicate_proof['unsigned']['payload']['body']['recordReproductionBatch']['_0']
            subject=draft['subjects'][0]
            assert len(draft['subjects'])==1 and subject['eweID'].lower()==identity(r['ZEWEID'])
            assert draft['id'].lower()==identity(r['ZBATCHID']) and draft['kind']=='abortion'
            assert equal_date(draft['occurredAt'],millis(r['ZOCCURREDAT']))
            b=bytearray(hashlib.sha256((draft['id'].lower()+'\n'+subject['id'].lower()).encode()).digest()[:16])
            b[6]=(b[6]&15)|80;b[8]=(b[8]&63)|128
            assert str(uuid.UUID(bytes=bytes(b)))==duplicate
        append('reproduction',{'id':sid,'eweID':identity(r['ZEWEID']),'kind':r['ZKINDRAWVALUE'],
            'occurredAt':millis(r['ZOCCURREDAT']),'batchID':identity(r['ZBATCHID']),
            'paternalSourceRawValue':r['ZPATERNALSOURCERAWVALUE'],'duplicateProjectionID':duplicate},
            {'legacyEntity':entity,'duplicateProjectionID':duplicate,'duplicateSourceCommand':duplicate_proof,
             'duplicateBasis':'source batch and subject derivation, not date-only deduplication' if duplicate else None})

    # Preserve original recordedAt because it is the tie-breaker for events
    # with the same occurredAt. The cloud V1 payload omits it; source is the
    # preserved device fact, after matching all immutable cloud event fields.
    for r in db.execute('SELECT * FROM ZTRANSFERRECORD WHERE ZDELETEDAT IS NULL ORDER BY ZID'):
        sid=identity(r['ZID'])
        if ('transfer',sid) in source:
            entity,p=source[('transfer',sid)]
            correction=None
            if p['kind']=='correctTransfer':
                correction=read(ROOT/'corrected-transfer-command.json')[0]
                raw=base64.b64decode(correction['unsigned_command_base64'])
                assert digest(raw)==correction['content_digest'] and correction['status']=='accepted'
                current=json.loads(raw)
                assert current['affectedStreams'][0]['id'].lower()==sid
                fact=current['payload']['body']['transferSheep']
                assert fact['sheepID'].lower()==identity(r['ZSHEEPID'])
                assert fact['toPenID'].lower()==identity(r['ZTOPENID'])
                assert equal_date(fact['occurredAt'],millis(r['ZOCCURREDAT']))
            else:
                assert entity['deleted_at'] is None and p['kind']=='transferSheep',('transfer kind',sid,p['kind'])
                assert p['identifiers']['sheepID'].lower()==identity(r['ZSHEEPID'])
            assert (p['optionalIdentifiers'].get('toPenID') or '').lower()==(identity(r['ZTOPENID']) or '')
            assert equal_date(time_value(p['dates']['occurredAt']),millis(r['ZOCCURREDAT']))
            proof={'legacyEntity':entity,'currentCorrectionProjection':correction,
                   'basis':'same immutable cloud event; recover original local fromPenID/recordedAt'}
        else:
            entry=pending[sid]
            proof={'approvedPendingOperation':entry,'basis':'owner-approved transfer and preserved original recording order'}
        projection={'id':sid,'sheepID':identity(r['ZSHEEPID']),'occurredAt':millis(r['ZOCCURREDAT']),
                    'fromPenID':identity(r['ZFROMPENID']),'recordedAt':millis(r['ZRECORDEDAT'])}
        append('transfer',projection,{**proof,'preservedProjection':projection})

    save(OUT/'commands.json',commands);save(OUT/'approvals.json',approvals);save(OUT/'source-evidence.json',evidence)
    save(OUT/'expected-business.json',expected);save(OUT/'expected-sheep.json',read(OLD/'expected-sheep.json'))
    save(OUT/'summary.json',{'commands':len(commands),'events':head-34842,'targetHead':head,'businessRepairs':counts,
        'sourceVerified':True,'productionWritten':False,'retainedExtraCareBatch':'ab58f706-5f88-dcdb-7988-9cf05b224583'})
    for offset in range(0,len(commands),100):
        save(OUT/'unsigned'/f'batch-{offset:06d}.json',[{'unsigned_command_base64':base64.b64encode(canonical(c)).decode(),
            'content_digest':digest(canonical(c))} for c in commands[offset:offset+100]])
    subprocess.run(['node','tools/sign_esheep_cloud_v2_repair.mjs',str(OUT)],check=True)
    print(dict(counts),head,flush=True)


if __name__=='__main__':build()
