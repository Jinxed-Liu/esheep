#!/usr/bin/env python3
"""Capture a verified parent checkpoint and its immutable cloud tail, read-only.

No phone or local business store is accepted as input. Raw material remains in
the explicitly selected private output directory; stdout contains counts only.
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import uuid
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from checkpoint_worker_api import service_key, source_call


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--project', required=True)
    parser.add_argument('--farm', required=True, type=uuid.UUID)
    parser.add_argument('--output', required=True, type=pathlib.Path)
    args = parser.parse_args()
    assert re.fullmatch('[a-z]{20}', args.project)
    farm = str(args.farm)
    root = args.output
    root.mkdir(parents=True, exist_ok=False)
    root.chmod(0o700)

    def save(name, value):
        path = root / name
        path.write_text(json.dumps(value, ensure_ascii=False, separators=(',', ':')))
        path.chmod(0o600)

    # One MVCC statement seals all mutable metadata at the same H. Event
    # bodies are immutable and can then be paged through H while new writes
    # continue; no farm lock or latest-head-equality requirement is needed.
    sealed = source_call(args.project, 'seal', farm_id=farm)
    state = sealed['state']
    assert state['v2_ready'] and not state['write_frozen']
    generation, head = state['farm_generation'], state['event_head']
    save('source.json', dict(project=args.project, farmID=farm, generation=generation, head=head))
    save('profile.json', sealed['profile'])
    for category in ('streams', 'assets'):
        rows = sealed[category]
        for offset in range(0, len(rows), 500):
            save(f'{category}-{offset//500:05d}.json', rows[offset:offset+500])
        print(f'Sealed {len(rows)} {category} at boundary {head}', flush=True)
    parent = sealed['parent']
    assert parent is not None, 'A verified cloud parent is required; new farms need the bootstrap pipeline'
    manifest = parent['manifest']
    assert manifest['farmID'].lower() == farm and manifest['farmGeneration'] == generation
    assert manifest['boundaryEventSequence'] < head, 'No newer events to compact'
    manifest_raw = json.dumps(manifest, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
    assert hashlib.sha256(manifest_raw).hexdigest() == parent['manifestSHA256']
    save('parent.json', parent)
    (root/'parent-manifest.json').write_bytes(manifest_raw)
    secret = service_key(args.project)
    def download(c):
        index=c['index']
        expected=f"{farm}/{manifest['checkpointID'].lower()}/{index:05d}.json.gz"
        assert c['objectKey']==expected and 0<c['compressedBytes']<=8*1024*1024
        req=urllib.request.Request(f'https://{args.project}.supabase.co/storage/v1/object/esheep-cloud-checkpoints/'+expected,
            headers={'authorization':'Bearer '+secret,'apikey':secret})
        with urllib.request.urlopen(req,timeout=90) as response:
            data=response.read(c['compressedBytes']+1)
        assert len(data)==c['compressedBytes'] and hashlib.sha256(data).hexdigest()==c['compressedSHA256']
        path=root/f'parent-{index:05d}.gz';path.write_bytes(data);path.chmod(0o600)
    with ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(download,manifest['chunks']))
    del secret,sealed
    pages = 0
    after = manifest['boundaryEventSequence']
    # Use the same snapshot record shape consumed by the production reducer.
    while after < head:
        events = source_call(args.project, 'events', farm_id=farm, generation=generation, after=after, through=head)
        assert events
        assert [r['event_sequence'] for r in events] == list(range(after+1, after+1+len(events)))
        save(f'events-{pages:05d}.json', events)
        after = events[-1]['event_sequence']
        pages += 1
        print(f'Captured {after}/{head} events', flush=True)
    final = source_call(args.project, 'state', farm_id=farm)
    assert final['farm_generation'] == generation and final['event_head'] >= head, 'Cloud generation or immutable prefix changed'
    save('inventory.json', {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.iterdir()) if p.is_file()})
    print('Read-only source capture verified', flush=True)


if __name__ == '__main__':
    main()
