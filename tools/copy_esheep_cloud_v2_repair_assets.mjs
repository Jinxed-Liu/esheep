// Additive copies for the owner-authorized generation 2 -> 3 history repair.
// Sources and existing objects are never overwritten or deleted.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
const require = createRequire(import.meta.url);
const { createClient } = require('../web/node_modules/@supabase/supabase-js');
const farm = '8b0fa55e-2a34-4398-ae77-7d7d3701c5dd';
const project = 'rnqrvthbunrzqtprquqx';

async function main() {
  const root = process.argv[2];
  if (!root) throw new Error('repair directory required');
  const gate = JSON.parse(fs.readFileSync(path.join(root, 'client-release-gate.json')));
  if (gate.testFailures !== 0 || !gate.fullReplayPassed) throw new Error('client gate not satisfied');
  const snapshot = JSON.parse(fs.readFileSync(path.join(root, 'validated-snapshot.json')));
  if (gate.snapshotID.toLowerCase() !== snapshot.snapshot_id || snapshot.farm_generation !== 3) throw new Error('gate snapshot mismatch');
  const metadata = JSON.parse(fs.readFileSync(path.join(root, 'source/metadata.json')));
  const keys = JSON.parse(execFileSync('supabase', ['projects','api-keys','--project-ref',project,'-o','json'], { encoding:'utf8', stdio:['ignore','pipe','pipe'] }));
  const key = keys.find(k => k.name === 'service_role')?.api_key;
  if (!key) throw new Error('service credential unavailable');
  const client = createClient(`https://${project}.supabase.co`, key, { auth: { persistSession:false, autoRefreshToken:false } });
  const bucket = client.storage.from('esheep-cloud-assets');
  const evidence = [];
  for (const asset of metadata['esheep_cloud.assets']) {
    if (asset.farm_id !== farm || asset.farm_generation !== 2) throw new Error('source asset scope mismatch');
    for (const variant of ['thumbnail','avatar','original']) {
      const source = asset[`${variant}_path`];
      if (!source.startsWith(`${farm}/2/${asset.asset_id}/`)) throw new Error('unexpected source path');
      const destination = source.replace(`${farm}/2/`, `${farm}/3/`);
      const copied = await bucket.copy(source, destination);
      // An interrupted attempt may have copied the object already. Verify
      // exact bytes even then, and never use upsert to mask a disagreement.
      const { data, error } = await bucket.download(destination);
      if (error || !data) throw new Error(`asset verification download failed for ${asset.asset_id}/${variant}`);
      const bytes = Buffer.from(await data.arrayBuffer());
      const hash = crypto.createHash('sha256').update(bytes).digest('hex');
      if (hash !== asset[`${variant}_sha256`] || bytes.length !== asset[`${variant}_byte_count`]) throw new Error(`asset digest mismatch for ${asset.asset_id}/${variant}`);
      evidence.push({ assetID:asset.asset_id, variant, source, destination, sha256:hash, bytes:bytes.length, copied:!copied.error, verified:true });
      console.log(`Verified asset variant ${evidence.length}/81`);
    }
  }
  if (evidence.length !== 81) throw new Error('asset variant count mismatch');
  fs.writeFileSync(path.join(root,'asset-copy-evidence.json'), JSON.stringify(evidence,null,2), { flag:'wx', mode:0o600 });
}
main().catch(error => { console.error(error.message); process.exitCode=1; });
