#!/usr/bin/env python3
"""Publish a refresh of an already verified cloud checkpoint.

Bootstrap publications continue to use the original historical approval gate.
Refreshes instead require verified cloud-parent lineage, sealed tail replay and
an independent complete SQLite round trip. This does not accept device stores.
Default is local validation only. --activate rechecks the parent in production,
verifies every uploaded byte and then atomically publishes an immutable version.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request
import uuid
from checkpoint_worker_api import service_key, source_call


def sha(data):
    return hashlib.sha256(data).hexdigest()


def validate(candidate, source, project):
    raw = (candidate/'archive/manifest.json').read_bytes()
    manifest = json.loads(raw)
    lineage_raw = (candidate/'refresh-lineage.json').read_bytes()
    lineage = json.loads(lineage_raw)
    independent_raw = (candidate/'independent-reconciliation.json').read_bytes()
    independent = json.loads(independent_raw)
    web_raw = (candidate/'web-reconciliation.json').read_bytes()
    web = json.loads(web_raw)
    identity = json.loads((source/'source.json').read_bytes())
    inventory_raw = (source/'inventory.json').read_bytes()
    inventory = json.loads(inventory_raw)
    for name, digest in inventory.items():
        assert Path(name).name == name and name not in ('.','..')
        assert sha((source/name).read_bytes()) == digest
    assert all(name in inventory for name in ('source.json','parent.json','parent-manifest.json','profile.json'))
    parent = json.loads((source/'parent.json').read_bytes())
    assert sha((source/'parent-manifest.json').read_bytes()) == parent['manifestSHA256']
    assert json.loads((source/'parent-manifest.json').read_bytes()) == parent['manifest']
    assert identity['project'] == project
    assert identity['farmID'].lower() == manifest['farmID'].lower() == parent['manifest']['farmID'].lower()
    assert identity['generation'] == manifest['farmGeneration'] == parent['manifest']['farmGeneration']
    assert lineage['passed'] is True and independent['passed'] is True
    assert lineage['manifestSHA256'] == independent['manifestSHA256'] == sha(raw)
    assert web['passed'] is True and web['manifestSHA256'] == sha(raw)
    assert web['boundary'] == manifest['boundaryEventSequence']
    assert lineage['sourceInventorySHA256'] == sha(inventory_raw)
    assert lineage['boundary'] == independent['boundary'] == manifest['boundaryEventSequence'] == identity['head']
    assert lineage['parentBoundary'] == parent['manifest']['boundaryEventSequence'] < lineage['boundary']
    assert lineage['parentCheckpointID'].lower() == parent['manifest']['checkpointID'].lower()
    assert lineage['parentManifestSHA256'] == parent['manifestSHA256']
    assert manifest['formatVersion'] == 1 and manifest['minimumClientCapability'] == 1
    assert independent['historicalProtocolReceipts'] == 0
    assert independent['compressedBytes'] <= 20_000_000 and independent['databaseLogicalBytes'] <= 40_000_000
    assert independent['compressedBytes'] == sum(c['compressedBytes'] for c in manifest['chunks'])
    parts = []
    for index, chunk in enumerate(manifest['chunks']):
        expected = f"{str(uuid.UUID(manifest['farmID']))}/{str(uuid.UUID(manifest['checkpointID']))}/{index:05d}.json.gz"
        assert chunk['index'] == index and chunk['objectKey'] == expected
        assert chunk['modelNames'] == sorted(set(chunk['modelNames'])) and chunk['modelNames']
        assert set(chunk['modelNames']).issubset(manifest['modelCounts'])
        data = (candidate/'archive'/f'{index:05d}.json.gz').read_bytes()
        assert len(data) == chunk['compressedBytes'] and 0 < len(data) <= 8*1024*1024
        assert sha(data) == chunk['compressedSHA256']
        parts.append((expected, data))
    return manifest, parent, parts, sha(raw), sha(lineage_raw + b'\n' + independent_raw + b'\n' + web_raw)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--candidate', type=Path, required=True)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--project', required=True)
    p.add_argument('--activate', action='store_true')
    a = p.parse_args()
    assert re.fullmatch('[a-z]{20}', a.project)
    manifest, parent, parts, digest, proof_digest = validate(a.candidate, a.source, a.project)
    if not a.activate:
        print(json.dumps({'validated': True, 'networkMutations': False})); return
    parent_id = str(uuid.UUID(parent['manifest']['checkpointID']))
    cloud_parent = source_call(a.project, 'parent', checkpoint_id=parent_id)
    assert cloud_parent and cloud_parent['status']=='verified' and cloud_parent['manifest_sha256']==parent['manifestSHA256']
    secret = service_key(a.project)
    base = f'https://{a.project}.supabase.co'
    def request(path, data=None, mime='application/json'):
        req = urllib.request.Request(base+path, data=data,
            headers={'authorization':'Bearer '+secret,'apikey':secret,'content-type':mime,'x-upsert':'false'})
        with urllib.request.urlopen(req,timeout=180) as response:
            return response.read()
    def upload(part):
        name, data = part
        path = '/storage/v1/object/esheep-cloud-checkpoints/'+name
        try:
            request(path,data,'application/gzip')
        except urllib.error.HTTPError as error:
            if error.code not in (400,409): raise
        assert request(path) == data, 'Stored immutable chunk differs from verified candidate'
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(upload,parts))
    payload = dict(p_manifest=manifest,p_manifest_sha256=digest,p_reconciliation_sha256=proof_digest)
    response = request('/rest/v1/rpc/esheep_cloud_publish_checkpoint_v1',json.dumps(payload).encode())
    assert str(uuid.UUID(json.loads(response))) == str(uuid.UUID(manifest['checkpointID']))
    (a.candidate/'publication.json').write_text(json.dumps(dict(published=True,
        manifestSHA256=digest,reconciliationSHA256=proof_digest,parentCheckpointID=parent_id)))
    print(json.dumps({'published':True,'boundary':manifest['boundaryEventSequence'],'chunks':len(parts)}))


if __name__ == '__main__':
    main()
