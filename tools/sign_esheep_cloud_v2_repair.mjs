// Sign owner-authorized repair commands with a new, dedicated P-256 key.
// Private key stays inside the protected local evidence directory.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const root = process.argv[2];
if (!root) throw new Error('repair directory required');
const keyPath = path.join(root, 'repair-private.pem');
let privateKey;
if (fs.existsSync(keyPath)) {
  privateKey = crypto.createPrivateKey(fs.readFileSync(keyPath));
} else {
  ({ privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' }));
  fs.writeFileSync(keyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }), { flag: 'wx', mode: 0o600 });
}
const publicKey = crypto.createPublicKey(privateKey);
fs.writeFileSync(path.join(root, 'repair-public.json'), JSON.stringify(publicKey.export({ format: 'jwk' })), { flag: 'wx', mode: 0o600 });
for (const file of fs.readdirSync(path.join(root, 'unsigned')).sort()) {
  const rows = JSON.parse(fs.readFileSync(path.join(root, 'unsigned', file), 'utf8'));
  const signed = rows.map(row => {
    const data = Buffer.from(row.unsigned_command_base64, 'base64');
    const signature = crypto.sign('sha256', data, { key: privateKey, dsaEncoding: 'ieee-p1363' });
    if (!crypto.verify('sha256', data, { key: publicKey, dsaEncoding: 'ieee-p1363' }, signature)) throw new Error('signature verification failed');
    return { ...row, device_signature_base64: signature.toString('base64') };
  });
  fs.mkdirSync(path.join(root, 'signed'), { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(root, 'signed', file), JSON.stringify(signed), { flag: 'wx', mode: 0o600 });
}
console.log('Repair signatures verified; private key retained locally.');
