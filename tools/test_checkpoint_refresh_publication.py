import json
from pathlib import Path
import tempfile
import unittest
from publish_esheep_checkpoint_refresh import validate, sha


class RefreshPublicationTests(unittest.TestCase):
    def test_parent_source_and_independent_proof_must_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root/'source'; candidate = root/'candidate'
            source.mkdir(); (candidate/'archive').mkdir(parents=True)
            farm = '11111111-1111-4111-8111-111111111111'
            parent_id = '22222222-2222-4222-8222-222222222222'
            checkpoint = '33333333-3333-4333-8333-333333333333'
            project = 'a'*20; data = b'fixture'
            parent_manifest = dict(farmID=farm, farmGeneration=3, checkpointID=parent_id,boundaryEventSequence=1)
            def save(path, value):
                raw=json.dumps(value,sort_keys=True).encode();path.write_bytes(raw);return sha(raw)
            parent_hash=save(source/'parent-manifest.json',parent_manifest)
            save(source/'parent.json',dict(manifest=parent_manifest,manifestSHA256=parent_hash))
            save(source/'source.json',dict(project=project,farmID=farm,generation=3,head=2))
            save(source/'profile.json',{})
            inventory_hash=save(source/'inventory.json',{p.name:sha(p.read_bytes()) for p in source.iterdir()})
            manifest=dict(farmID=farm,farmGeneration=3,checkpointID=checkpoint,boundaryEventSequence=2,
                formatVersion=1,minimumClientCapability=1,modelCounts={'FarmRecord':1},chunks=[dict(index=0,
                objectKey=f'{farm}/{checkpoint}/00000.json.gz',modelNames=['FarmRecord'],compressedBytes=len(data),compressedSHA256=sha(data))])
            digest=save(candidate/'archive/manifest.json',manifest)
            (candidate/'archive/00000.json.gz').write_bytes(data)
            lineage=dict(passed=True,parentBoundary=1,boundary=2,parentCheckpointID=parent_id,
                parentManifestSHA256=parent_hash,manifestSHA256=digest,sourceInventorySHA256=inventory_hash)
            proof=dict(passed=True,boundary=2,manifestSHA256=digest,historicalProtocolReceipts=0,
                compressedBytes=len(data),databaseLogicalBytes=1024)
            save(candidate/'independent-reconciliation.json',proof)
            save(candidate/'web-reconciliation.json',dict(passed=True,boundary=2,manifestSHA256=digest))
            path=candidate/'refresh-lineage.json';save(path,lineage)
            validate(candidate,source,project)
            for change in ({'passed':False},{'parentBoundary':2},{'parentManifestSHA256':'f'*64},
                           {'manifestSHA256':'f'*64},{'sourceInventorySHA256':'f'*64},{'boundary':3}):
                save(path,dict(lineage,**change))
                with self.assertRaises(AssertionError): validate(candidate,source,project)
            save(path,lineage)
            for change in ({'passed':False},{'historicalProtocolReceipts':1},{'manifestSHA256':'f'*64}):
                save(candidate/'independent-reconciliation.json',dict(proof,**change))
                with self.assertRaises(AssertionError): validate(candidate,source,project)
            save(candidate/'independent-reconciliation.json',proof)
            (source/'profile.json').write_text('{"changed":true}')
            with self.assertRaises(AssertionError): validate(candidate,source,project)


if __name__ == '__main__':
    unittest.main()
