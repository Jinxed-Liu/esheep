#!/usr/bin/env python3
"""Independently bind offline purpose facts to distinct immutable cloud commands."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import uuid


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--candidate', required=True, type=Path)
    p.add_argument('--cloud-source', required=True, type=Path)
    a = p.parse_args()
    root = a.cloud_source.resolve(); candidate = a.candidate.resolve()
    inventory_bytes = (root / 'inventory.json').read_bytes()
    inventory = json.loads(inventory_bytes)
    for name, digest in inventory.items():
        assert Path(name).name == name
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
    source = json.loads((root / 'source.json').read_bytes())
    manifest_bytes = (candidate / 'archive/manifest.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    assert manifest['boundaryEventSequence'] == source['head']
    assert uuid.UUID(manifest['farmID']) == uuid.UUID(source['farmID'])
    expected = {}; event_count = 0
    for name in sorted(inventory):
        if not name.startswith('events-'): continue
        for event in json.loads((root / name).read_bytes()):
            body = json.loads(event['event_body_canonical'])
            if body.get('command_kind') != 'care.sheep.setPurpose': continue
            event_count += 1
            command = str(uuid.UUID(event['command_id']))
            payload = body['command_payload']['body']['setSheepPurpose']
            if command in expected:
                assert expected[command][1] == payload
            else:
                expected[command] = (event, payload)
    db = sqlite3.connect((candidate / 'imported.store').as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    rows = db.execute('select * from ZDOMAINOPERATION').fetchall()
    assert len(rows) == len(expected), 'Purpose history count differs from distinct cloud commands'
    seen = set()
    for row in rows:
        command = str(uuid.UUID(bytes=row['ZID'])); assert command not in seen; seen.add(command)
        event, payload = expected[command]
        assert row['ZFARMID'] == uuid.UUID(source['farmID']).bytes
        assert row['ZENTITYID'] == uuid.UUID(payload['sheepID']).bytes
        assert row['ZACCOUNTID'] == uuid.UUID(event['actor_account_id']).bytes
        assert row['ZMODIFIEDBYDEVICEID'] == uuid.UUID(event['source_device_id']).bytes
        assert row['ZKINDRAWVALUE'] == 'care'
        assert row['ZBASEREVISION'] == payload['expectedRevision']
        assert row['ZRESULTINGREVISION'] == payload['expectedRevision'] + 1
        assert abs(row['ZOCCURREDAT'] - (event['occurred_at_millis'] / 1000 - 978307200)) < 0.001
        assert abs(row['ZCREATEDAT'] - (event['received_at_millis'] / 1000 - 978307200)) < 0.001
        stored = json.loads(row['ZPAYLOAD'])
        stored_purpose = stored['careCommand']['setSheepPurpose']
        assert uuid.UUID(stored_purpose['sheepID']) == uuid.UUID(payload['sheepID'])
        for field in ('purpose', 'reason', 'expectedRevision'):
            assert stored_purpose[field] == payload[field]
        assert hashlib.sha256(row['ZPAYLOAD']).hexdigest() == row['ZPAYLOADDIGEST']
        assert not row['ZCAPABILITYCERTIFICATE'] and row['ZOPERATIONSIGNATURE'] is None
    assert seen == set(expected)
    report = dict(passed=True, boundary=source['head'], purposeEvents=event_count,
        distinctPurposeCommands=len(expected), offlinePurposeFacts=len(rows),
        sourceInventorySHA256=hashlib.sha256(inventory_bytes).hexdigest(),
        manifestSHA256=hashlib.sha256(manifest_bytes).hexdigest(),
        scope='Original IDs, subject, purpose, reason, actor, device, revision and event times; previous purpose is preserved from the independently compared replay projection')
    (candidate / 'purpose-history-reconciliation.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__': main()
