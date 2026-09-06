#!/usr/bin/env python3
"""Capture only SELECT evidence for the newly owner-authorized business scope."""
import pathlib
from repair_esheep_cloud_v2_history import FARM, remote_select, read, save, digest

ROOT=pathlib.Path('backups/cloud-v2-extended-repair-20260905')
TYPES=('pen','productionBatch','batchMembership','reproduction','transfer')


def main():
    ROOT.mkdir(mode=0o700,exist_ok=False)
    before=remote_select(f"select * from esheep_cloud.farm_state where farm_id='{FARM}'")
    assert len(before)==1 and before[0]['farm_generation']==3 and before[0]['event_head']==34842
    save(ROOT/'state-before.json',before)
    for kind in TYPES:
        count=remote_select(f"select count(*) n from public.farm_entities where farm_id='{FARM}' and entity_type='{kind}'")[0]['n']
        for offset in range(0,count,500):
            rows=remote_select(f"select * from public.farm_entities where farm_id='{FARM}' and entity_type='{kind}' order by entity_id limit 500 offset {offset}")
            save(ROOT/f'source/{kind}/page-{offset:06d}.json',rows)
        print(kind,count,flush=True)
    after=remote_select(f"select * from esheep_cloud.farm_state where farm_id='{FARM}'")
    assert before==after,'authority advanced; reconcile before using this capture'
    save(ROOT/'state-after.json',after)
    save(ROOT/'inventory.json',{str(p.relative_to(ROOT)):digest(p.read_bytes()) for p in sorted(ROOT.rglob('*.json'))})
    print('Read-only capture complete; source inventory sealed')


if __name__=='__main__':main()
