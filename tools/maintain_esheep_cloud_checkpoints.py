#!/usr/bin/env python3
"""Protected checkpoint retention. Default audits; --execute retires/purges only checkpoint shards.

Never reads or deletes cloud events, legacy snapshots, photos, or mobile files.
Interrupted removals remain claimed and can safely resume with the same IDs.
"""
import argparse
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request
import urllib.parse
import uuid


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--project', required=True)
    p.add_argument('--farm', required=True, type=uuid.UUID)
    p.add_argument('--generation', required=True, type=int)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--execute', action='store_true')
    p.add_argument('--local-test-config', type=Path, help='Disposable localhost stack status JSON only')
    a = p.parse_args()
    assert re.fullmatch('[a-z]{20}', a.project) and a.generation >= 0
    os.umask(0o077)
    if a.local_test_config:
        configuration = json.loads(a.local_test_config.read_bytes())
        base = configuration['API_URL'].rstrip('/')
        parsed = urllib.parse.urlparse(base)
        assert parsed.scheme == 'http' and parsed.hostname in ('localhost', '127.0.0.1')
        assert '/esheep-checkpoint/' in os.environ.get('DOCKER_HOST', '')
        key = configuration['SERVICE_ROLE_KEY']
    else:
        key = os.environ['ESHEEP_CHECKPOINT_PUBLISH_KEY']
        base = f'https://{a.project}.supabase.co'
    headers = {'authorization': 'Bearer ' + key, 'apikey': key, 'content-type': 'application/json'}
    def request(path, body, method='POST'):
        data = json.dumps(body, separators=(',', ':')).encode()
        req = urllib.request.Request(base + path, data=data, method=method, headers=headers)
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.load(response)
    def rpc(name, body):
        return request('/rest/v1/rpc/' + name, body)
    identity = dict(p_farm_id=str(a.farm), p_farm_generation=a.generation)
    plan = rpc('esheep_cloud_checkpoint_retention_v1', {**identity, 'p_apply': a.execute})
    report = dict(executed=a.execute, plan=plan, purged=[], completed=False)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    def save():
        a.output.write_text(json.dumps(report, indent=2) + '\n')
        a.output.chmod(0o600)
    save()
    if a.execute:
        for raw_id in plan['eligible_to_purge']:
            checkpoint = str(uuid.UUID(raw_id))
            claim = rpc('esheep_cloud_claim_checkpoint_purge_v1', {**identity, 'p_checkpoint_id': checkpoint})
            manifest = claim.get('manifest')
            if manifest is None:
                continue  # Pinned or not eligible after the audit; no files touched.
            assert uuid.UUID(manifest['farmID']) == a.farm and manifest['farmGeneration'] == a.generation
            assert str(uuid.UUID(manifest['checkpointID'])) == checkpoint and manifest['formatVersion'] == 1
            keys = []
            for index, chunk in enumerate(manifest['chunks']):
                expected = f'{a.farm}/{checkpoint}/{index:05d}.json.gz'
                assert chunk['index'] == index and chunk['objectKey'] == expected
                keys.append(expected)
            assert 0 < len(keys) <= 10000
            for offset in range(0, len(keys), 100):
                request('/storage/v1/object/esheep-cloud-checkpoints', {'prefixes': keys[offset:offset+100]}, 'DELETE')
            for name in keys:
                req = urllib.request.Request(base + '/storage/v1/object/esheep-cloud-checkpoints/' + name, headers=headers)
                try:
                    with urllib.request.urlopen(req, timeout=30) as response:
                        response.read(1)
                    raise RuntimeError('Claimed checkpoint object still exists')
                except urllib.error.HTTPError as error:
                    if error.code == 404:
                        continue
                    if error.code == 400:
                        missing = json.loads(error.read())
                        if str(missing.get('statusCode')) == '404':
                            continue
                    raise
            # Use the publisher's exact original manifest hash, not a Python
            # re-encoding of Swift JSON (number spelling can differ).
            finalized = rpc('esheep_cloud_finish_checkpoint_purge_v1',
                            {'p_checkpoint_id': checkpoint, 'p_manifest_sha256': claim['manifest_sha256']})
            assert finalized is True
            report['purged'].append(checkpoint)
            save()
    report['completed'] = True
    save()
    print(json.dumps({'executed': a.execute, 'retirementCandidates': len(plan['eligible_to_retire']),
                      'purgedCount': len(report['purged'])}))


if __name__ == '__main__':
    main()
