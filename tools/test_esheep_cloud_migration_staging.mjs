import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

// Exercise the generator without invoking main(), reading an Air backup, or
// overwriting its historical output directory. Filesystem writes are captured.
const source = fs.readFileSync(new URL('./esheep_cloud_v2_real_migrate.mjs', import.meta.url), 'utf8');
const generator = source.slice(source.indexOf('function writeBatches(commands) {'), source.indexOf('\nfunction main() {'));
const quote = source.slice(source.indexOf('function sqlString(value) {'), source.indexOf('\nfunction sqlJSON(value) {'));

function generate(commands) {
  const writes = [];
  vm.runInNewContext(`${quote}\n${generator}\nwriteBatches(commands);`, {
    commands, path, BATCH_DIR: '/captured',
    FARM_ID: '00000000-0000-0000-0000-000000000001',
    OWNER_USER_ID: '00000000-0000-0000-0000-000000000002', GENERATION: 2,
    fs: { mkdirSync() {}, writeFileSync(file, sql) { writes.push({ file, sql }); } }
  });
  return writes;
}

test('migration preserves signed envelopes and order across its 100-command batches', () => {
  const commands = Array.from({ length: 205 }, (_, index) => ({
    unsignedCommandBase64: `body-${index}-O'Brien`,
    deviceSignatureBase64: `signature-${index}`, contentDigest: `digest-${index}`
  }));
  const writes = generate(commands);
  assert.equal(writes.length, 3);
  const decoded = writes.flatMap(({ sql }) => {
    const match = sql.match(/jsonb_array_elements\('((?:''|[^'])*)'::jsonb\)/);
    assert.ok(match);
    assert.match(sql, /order by ordinal/);
    assert.match(sql, /^begin;/);
    assert.match(sql, /commit;\s*$/);
    assert.match(sql, /process_command_v2/);
    assert.match(sql, /not in \('accepted','duplicate'\)/);
    return JSON.parse(match[1].replaceAll("''", "'"));
  });
  assert.deepEqual(decoded, commands.map(command => ({
    unsigned_command_base64: command.unsignedCommandBase64,
    device_signature_base64: command.deviceSignatureBase64,
    content_digest: command.contentDigest
  })));
});

test('a large migration envelope stays outside procedural query text', () => {
  const marker = 'large-migration-envelope-' + 'x'.repeat(1_000_000);
  const [{ sql }] = generate([{ unsignedCommandBase64: marker,
    deviceSignatureBase64: 'signature', contentDigest: 'digest' }]);
  const procedural = sql.match(/do \$\$[\s\S]*?end \$\$;/)[0];
  assert.ok(Buffer.byteLength(procedural) < 2048);
  assert.ok(!procedural.includes(marker));
  assert.match(sql, /insert into pg_temp\.esheep_migration_command_input/);
  assert.match(sql, /on commit drop/);
});
