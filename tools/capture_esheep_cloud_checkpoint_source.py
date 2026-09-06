#!/usr/bin/env python3
"""Capture an immutable, bounded cloud projection source using SELECT only.

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

    def query(sql):
        assert sql.lstrip().lower().startswith('select ')
        result = subprocess.run(['supabase', 'db', 'query', '--project-ref', args.project,
                                 '--linked', sql, '-o', 'json'], capture_output=True, check=True, timeout=180)
        return json.loads(result.stdout)['rows']

    def save(name, value):
        path = root / name
        path.write_text(json.dumps(value, ensure_ascii=False, separators=(',', ':')))
        path.chmod(0o600)

    # One MVCC statement seals all mutable metadata at the same H. Event
    # bodies are immutable and can then be paged through H while new writes
    # continue; no farm lock or latest-head-equality requirement is needed.
    sealed = query(f"""select jsonb_build_object(
      'state',jsonb_build_object('farm_generation',s.farm_generation,'event_head',s.event_head,
        'status',s.status,'v2_ready',s.v2_ready,'write_frozen',s.write_frozen),
      'profile',esheep_cloud.farm_profile_json_v2(p),
      'streams',coalesce((select jsonb_agg(jsonb_build_object('record_kind','stream',
        'stream_type',t.stream_type,'stream_id',t.stream_id,'stream_version',t.stream_version,
        'field_versions',t.field_versions,'content_digest',t.content_digest,'last_event_sequence',t.last_event_sequence)
        order by t.stream_type,t.stream_id) from esheep_cloud.streams t
        where t.farm_id=s.farm_id and t.farm_generation=s.farm_generation),'[]'::jsonb),
      'assets',coalesce((select jsonb_agg(to_jsonb(t)-'farm_id'-'farm_generation'||jsonb_build_object('record_kind','asset')
        order by t.asset_id) from esheep_cloud.assets t
        where t.farm_id=s.farm_id and t.farm_generation=s.farm_generation),'[]'::jsonb)) sealed
      from esheep_cloud.farm_state s join esheep_cloud.farm_profiles p
        on p.farm_id=s.farm_id and p.farm_generation=s.farm_generation where s.farm_id='{farm}'""")[0]['sealed']
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
    del sealed
    pages = 0
    after = 0
    # Use the same snapshot record shape consumed by the production reducer.
    while after < head:
        rows = query(f"""select jsonb_build_object(
          'record_kind','event','event_sequence',event_sequence,'event_id',event_id,
          'command_id',command_id,'source_command_digest',source_command_digest,
          'stream_type',stream_type,'stream_id',stream_id,'event_kind',event_kind,
          'event_body_canonical',esheep_cloud.canonical_json_text(event_body),
          'event_body_digest',event_body_digest,'affected_fields',affected_fields,
          'before_digest',before_digest,'after_digest',after_digest,
          'actor_account_id',actor_account_id,'source_device_id',source_device_id,
          'source_device_sequence',source_device_sequence,
          'occurred_at_millis',round(extract(epoch from occurred_at)*1000)::bigint,
          'received_at_millis',round(extract(epoch from received_at)*1000)::bigint,
          'event_digest',event_digest) body
          from esheep_cloud.events where farm_id='{farm}' and farm_generation={generation}
          and event_sequence>{after} and event_sequence<={head} order by event_sequence limit 500""")
        assert rows
        events = [r['body'] for r in rows]
        assert [r['event_sequence'] for r in events] == list(range(after+1, after+1+len(events)))
        save(f'events-{pages:05d}.json', events)
        after = events[-1]['event_sequence']
        pages += 1
        print(f'Captured {after}/{head} events', flush=True)
    final = query(f"select farm_generation,event_head from esheep_cloud.farm_state where farm_id='{farm}'")[0]
    assert final['farm_generation'] == generation and final['event_head'] >= head, 'Cloud generation or immutable prefix changed'
    save('inventory.json', {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.glob('*.json'))})
    print('Read-only source capture verified', flush=True)


if __name__ == '__main__':
    main()
