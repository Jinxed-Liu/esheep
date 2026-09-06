#!/usr/bin/env python3
"""Attach sealed, previously approved recording metadata to a private cloud capture.

Only the three historically nondeterministic recordedAt fields are admitted.
No phone store is read and no cloud write is performed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import uuid


def main():
    p=argparse.ArgumentParser();p.add_argument('--cloud-source',type=Path,required=True);p.add_argument('--approved-source',type=Path,required=True)
    a=p.parse_args();root=a.cloud_source.resolve();approved=a.approved_source.resolve()
    inventory=json.loads((root/'inventory.json').read_bytes())
    for name,sha in inventory.items():
        assert Path(name).name==name and hashlib.sha256((root/name).read_bytes()).hexdigest()==sha
    source=json.loads((root/'source.json').read_bytes())
    proof=json.loads((approved/'semantic-reconciliation.json').read_bytes())
    assert proof['passed'] and proof['tableCount']==46
    audit_path=approved/'post-repair-field-audit.json';audit_bytes=audit_path.read_bytes();audit_sha=hashlib.sha256(audit_bytes).hexdigest()
    assert any(Path(k).name==audit_path.name and value==audit_sha for k,value in proof['sourceHashes'].items())
    audit=json.loads(audit_bytes); entries=[]
    command_bytes=(approved/'commands.json').read_bytes()
    command_sha=hashlib.sha256(command_bytes).hexdigest()
    assert any(Path(k).name=='commands.json' and value==command_sha for k,value in proof['sourceHashes'].items())
    commands=json.loads(command_bytes)
    assert all(uuid.UUID(c['farmID'])==uuid.UUID(source['farmID']) and c['farmGeneration']==source['generation'] for c in commands)
    approved_ids={c['commandID'].lower() for c in commands}
    event_positions={}
    for name in inventory:
        if name.startswith('events-'):
            for event in json.loads((root/name).read_bytes()):
                event_positions[event['command_id'].lower()]=event['event_sequence']
    assert approved_ids <= event_positions.keys(), 'Approval commands are absent from this immutable cloud prefix'
    approved_boundary=max(event_positions[c] for c in approved_ids)
    models={'ZWEIGHTRECORD':'WeightRecord','ZREMOVALRECORD':'RemovalRecord','ZWEANINGRECORD':'WeaningRecord'}
    for row in audit['differences']:
        if row['field']=='ZRECORDEDAT' and row['table'] in models:
            assert isinstance(row['replay'],(float,int)) and uuid.UUID(row['id'])
            entries.append(dict(model=models[row['table']],id=row['id'],recordedAtReferenceSeconds=row['replay']))
    assert len({(x['model'],x['id']) for x in entries})==len(entries)
    value=dict(farmID=source['farmID'],farmGeneration=source['generation'],approvedBoundaryEventSequence=approved_boundary,approvalSHA256=hashlib.sha256((approved/'semantic-reconciliation.json').read_bytes()).hexdigest(),auditSHA256=audit_sha,entries=entries)
    name='approved-recording-metadata.json';assert name not in inventory,'Never replace an attached approval'
    data=json.dumps(value,ensure_ascii=False,separators=(',',':')).encode();(root/name).write_bytes(data);(root/name).chmod(0o600)
    inventory[name]=hashlib.sha256(data).hexdigest();(root/'inventory.json').write_text(json.dumps(inventory,sort_keys=True))
    print(json.dumps(dict(approvedMetadataRecords=len(entries),auditSHA256=audit_sha,cloudMutated=False)))

if __name__=='__main__':main()
