#!/usr/bin/env python3
"""Validate/stage/activate a verified checkpoint from a protected worker.

Default is validation only. Staging never changes the active pointer. Activation
requires the controlled release-window evidence; credentials remain server-side.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import urllib.error
import urllib.request


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--candidate',type=Path,required=True)
    p.add_argument('--project',required=True)
    p.add_argument('--release-info-plist',type=Path,required=True)
    action=p.add_mutually_exclusive_group();action.add_argument('--stage',action='store_true');action.add_argument('--activate',action='store_true')
    p.add_argument('--release-gate',type=Path)
    p.add_argument('--owner-release-without-new-tests',action='store_true',help='Explicit owner-directed internal release; retains candidate integrity checks and records skipped acceptance.')
    a=p.parse_args()
    assert re.fullmatch('[a-z]{20}',a.project)
    info=plistlib.loads(a.release_info_plist.read_bytes())
    base=f'https://{a.project}.supabase.co'
    assert info['CFBundleIdentifier']=='com.sheepfarm.ios' and info['SUPABASE_URL'].rstrip('/')==base, 'Release artifact targets another project or bundle'
    root=a.candidate.resolve();manifest_bytes=(root/'archive/manifest.json').read_bytes();manifest=json.loads(manifest_bytes)
    digest=lambda b:hashlib.sha256(b).hexdigest()
    proof_bytes=(root/'independent-reconciliation.json').read_bytes();proof=json.loads(proof_bytes)
    assert proof['passed'] and proof['manifestSHA256']==digest(manifest_bytes)
    assert proof['boundary']==manifest['boundaryEventSequence'] and proof['historicalProtocolReceipts']==0
    assert proof['compressedBytes']<=20_000_000 and proof['databaseLogicalBytes']<=40_000_000
    assert manifest['formatVersion']==1
    source=json.loads((root/'cloud-source-proof.json').read_bytes())
    assert source['project']==a.project and source['farmID'].lower()==manifest['farmID'].lower()
    assert source['generation']==manifest['farmGeneration'] and source['head']==manifest['boundaryEventSequence']
    approved_bytes=(root/'approved-history-reconciliation.json').read_bytes()
    approved=json.loads(approved_bytes)
    assert approved['passed'] and approved['manifestSHA256']==digest(manifest_bytes)
    assert approved['sourceInventorySHA256']==source['sourceInventorySHA256'] and approved['boundary']==source['head']
    history_bytes=(root/'purpose-history-reconciliation.json').read_bytes()
    history=json.loads(history_bytes)
    assert history['passed'] and history['manifestSHA256']==digest(manifest_bytes)
    assert history['sourceInventorySHA256']==source['sourceInventorySHA256'] and history['boundary']==source['head']
    parts=[]
    for index,chunk in enumerate(manifest['chunks']):
        key=f"{manifest['farmID'].lower()}/{manifest['checkpointID'].lower()}/{index:05d}.json.gz"
        assert chunk['index']==index and chunk['objectKey']==key
        assert chunk.get('modelNames') and chunk['modelNames']==sorted(set(chunk['modelNames']))
        assert set(chunk['modelNames']).issubset(manifest['modelCounts'])
        data=(root/'archive'/f'{index:05d}.json.gz').read_bytes()
        assert len(data)==chunk['compressedBytes'] and len(data)<=8*1024*1024 and digest(data)==chunk['compressedSHA256']
        parts.append((key,data))
    if not (a.stage or a.activate):
        print(json.dumps(dict(validated=True,checkpoint=manifest['checkpointID'],networkMutations=False)));return
    if a.activate and not a.owner_release_without_new_tests:
        assert a.release_gate is not None, 'Controlled release gate required'
        gate=json.loads(a.release_gate.read_bytes())
        assert gate['checkpointManifestSHA256']==digest(manifest_bytes) and gate['project']==a.project
        assert gate.get('acceptanceDeviceUDID')=='00008150-000128C93640401C', 'Expected user-selected iPhone Air'
        for key in ['isolatedHTTPPassed','clientRegressionPassed','historySourcesReconciled','physicalReleasePerformancePassed',
                    'sameBoundarySizeComparisonPassed','recoveryMatrixPassed','latestAirBackupVerified','releaseWindowOpen']:
            assert gate.get(key) is True,f'Missing release evidence: {key}'
    key=os.environ['ESHEEP_CHECKPOINT_PUBLISH_KEY']
    def request(path,data,mime):
        req=urllib.request.Request(base+path,data=data,method='POST',headers={'authorization':'Bearer '+key,'apikey':key,'content-type':mime,'x-upsert':'false'})
        with urllib.request.urlopen(req,timeout=180) as result:return result.read()
    for name,data in parts:
        path='/storage/v1/object/esheep-cloud-checkpoints/'+name
        try:
            request(path,data,'application/gzip')
        except urllib.error.HTTPError as error:
            # A staged candidate may already exist when activation resumes.
            # Never overwrite: only the exact immutable bytes are reusable.
            if error.code not in (400,409):
                raise
        req=urllib.request.Request(base+path,headers={'authorization':'Bearer '+key,'apikey':key})
        with urllib.request.urlopen(req,timeout=180) as result:
            remote=result.read(len(data)+1)
        assert len(remote)==len(data) and digest(remote)==digest(data), 'Stored checkpoint differs from verified candidate'
    if a.activate:
        payload=dict(p_manifest=manifest,p_manifest_sha256=digest(manifest_bytes),p_reconciliation_sha256=digest(json.dumps({'independent':digest(proof_bytes),'approvedHistory':digest(approved_bytes),'purposeHistory':digest(history_bytes)},sort_keys=True,separators=(',',':')).encode()))
        request('/rest/v1/rpc/esheep_cloud_publish_checkpoint_v1',json.dumps(payload,separators=(',',':')).encode(),'application/json')
    print(json.dumps(dict(staged=True,activated=a.activate,checkpoint=manifest['checkpointID'],ownerDirectedWithoutNewTests=a.owner_release_without_new_tests)))

if __name__=='__main__':main()
