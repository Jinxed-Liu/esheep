#!/usr/bin/env python3
"""Independent SQLite-level comparison of a private replay and checkpoint import.

Read-only, all registered transmitted models, every stored scalar column;
SwiftData row bookkeeping is excluded. No cleanup or publication is performed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import zlib


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('candidate', type=Path)
    args = parser.parse_args()
    root = args.candidate.resolve()
    registry = json.loads((Path(__file__).resolve().parent / 'esheep_cloud_checkpoint_schema_v1.json').read_text())
    manifest = json.loads((root / 'archive/manifest.json').read_text())
    def open_db(name):
        path = root / name
        connection = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)
        connection.execute('pragma query_only=on')
        assert connection.execute('pragma quick_check').fetchone() == ('ok',)
        return connection
    baseline, imported = open_db('baseline.store'), open_db('imported.store')
    result = []
    for model, definition in sorted(registry.items()):
        if definition['disposition'] != 'transfer':
            continue
        table = 'Z' + model.upper()
        columns = lambda db: sorted(r[1] for r in db.execute(f'pragma table_info({table})') if r[1] not in ('Z_PK', 'Z_ENT', 'Z_OPT'))
        left, right = columns(baseline), columns(imported)
        assert left == right and 'ZID' in left, model
        query = f"select {','.join(left)} from {table} order by ZID"
        a, b = baseline.execute(query), imported.execute(query)
        count = 0
        while True:
            x, y = a.fetchone(), b.fetchone()
            assert x == y, f'{model}: field mismatch at row {count}'
            if x is None:
                break
            count += 1
        assert count == manifest['modelCounts'][model], model
        result.append(dict(model=model, count=count, columns=len(left), passed=True))
    assert imported.execute('select count(*) from ZESHEEPCLOUDEVENTRECEIPT').fetchone()[0] == 0
    compressed = sum(c['compressedBytes'] for c in manifest['chunks'])
    for c in manifest['chunks']:
        data = (root/'archive'/f"{c['index']:05d}.json.gz").read_bytes()
        assert len(data) == c['compressedBytes'] and hashlib.sha256(data).hexdigest() == c['compressedSHA256']
        assert 0 < c['uncompressedBytes'] <= 8*1024*1024
        inflater=zlib.decompressobj(31)
        raw=inflater.decompress(data, c['uncompressedBytes']+1)
        assert inflater.eof and not inflater.unused_data and not inflater.unconsumed_tail
        assert len(raw)==c['uncompressedBytes'] and hashlib.sha256(raw).hexdigest()==c['contentSHA256']
        rows=json.loads(raw)
        assert len(rows)==c['recordCount']
        assert c.get('modelNames')==sorted({row['model'] for row in rows}), 'Missing or incorrect model shard index'
    baseline.close(); imported.close()
    files = [p for p in root.glob('imported.store*') if p.is_file()]
    report = dict(passed=True, boundary=manifest['boundaryEventSequence'], models=result,
                  compressedBytes=compressed, databaseLogicalBytes=sum(p.stat().st_size for p in files),
                  databaseAllocatedBytes=sum(p.stat().st_blocks*512 for p in files),
                  historicalProtocolReceipts=0, realNetworkMeasurement=False,
                  deviceAcceptance=False, manifestSHA256=hashlib.sha256((root/'archive/manifest.json').read_bytes()).hexdigest())
    (root/'independent-reconciliation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({k:v for k,v in report.items() if k!='models'}))

if __name__ == '__main__': main()
