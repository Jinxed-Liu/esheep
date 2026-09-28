// Read-only compatibility check using the production Web checkpoint decoder.
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import path from 'node:path';
import { validateCheckpointManifest, decodeCheckpointChunk } from '../web/src/lib/cloudV2Checkpoint.js';
import { createV2Projection, finishV2Projection, webCheckpointModels } from '../web/src/lib/cloudV2Projection.js';
const candidate = process.argv[2];
if (!candidate) throw new Error('Usage: node tools/verify_web_checkpoint.mjs <candidate>');
const root = path.join(candidate, 'archive');
const raw = await fs.readFile(path.join(root, 'manifest.json'));
const manifest = JSON.parse(raw);
validateCheckpointManifest(manifest, { id: manifest.farmID, generation: manifest.farmGeneration });
const rows = [];
for (const descriptor of manifest.chunks) {
  const bytes = await fs.readFile(path.join(root, `${String(descriptor.index).padStart(5, '0')}.json.gz`));
  rows.push(...(await decodeCheckpointChunk(bytes, descriptor)).filter(row => webCheckpointModels.has(row.model)));
}
finishV2Projection(createV2Projection(rows, manifest));
await fs.writeFile(path.join(candidate, 'web-reconciliation.json'), JSON.stringify({
  passed: true, boundary: manifest.boundaryEventSequence,
  manifestSHA256: crypto.createHash('sha256').update(raw).digest('hex'),
}));
console.log('Web checkpoint compatibility passed');
