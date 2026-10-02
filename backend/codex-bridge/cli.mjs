import { resolve } from 'node:path';
import { mkdir, lstat, open, unlink } from 'node:fs/promises';
import { readProtectedJSON, PlanCredentialStore } from './provider.mjs';
import { BridgeSessions, createBridgeServer } from './bridge.mjs';

const configPath = process.env.ESHEEP_CODEX_BRIDGE_CONFIG;
if (!configPath) throw new Error('ESHEEP_CODEX_BRIDGE_CONFIG must name a protected configuration file.');
const config = await readProtectedJSON(resolve(configPath));
// This implementation never exposes cleartext credentials remotely. A reviewed TLS/session
// gateway is a separate deployment requirement; binding 0.0.0.0 is deliberately unsupported.
if (config.host && config.host !== '127.0.0.1' && config.host !== '::1') {
  throw new Error('Only explicit loopback hosts are supported.');
}
if (!Number.isInteger(config.port) || config.port < 1024 || config.port > 65535) {
  throw new Error('A local port between 1024 and 65535 is required.');
}
if (!Array.isArray(config.grants) || !config.dataDirectory) throw new Error('Missing scoped bridge configuration.');
const dataDirectory = resolve(config.dataDirectory);
await mkdir(dataDirectory, { recursive: true, mode: 0o700 });
const directoryInfo = await lstat(dataDirectory);
if (!directoryInfo.isDirectory() || directoryInfo.isSymbolicLink() || (directoryInfo.mode & 0o077) !== 0 ||
    (process.getuid && directoryInfo.uid !== process.getuid())) throw new Error('Runtime directory must be private and owned by this user.');
// A single host owns these rotating registrations. Stale locks require operator reconciliation;
// silently deleting a lock could let two hosts race one rotating refresh token.
const lockPath = resolve(dataDirectory, '.bridge.lock');
const lock = await open(lockPath, 'wx', 0o600);
await lock.writeFile(String(process.pid));
const credentials = new PlanCredentialStore(config.registrations ?? {});
const sessions = new BridgeSessions({ dataDirectory, credentials,
  gates: config.gates ?? {}, binary: config.codexBinary ?? 'codex' });
const server = createBridgeServer({ sessions, grants: config.grants });
const leaseTimer = setInterval(() => sessions.expireLeases(), 5000);
leaseTimer.unref();
server.listen(config.port, config.host ?? '127.0.0.1', () => {
  process.stdout.write('eSheep Codex bridge listening on configured loopback endpoint.\n');
});
let stopping = false;
const stop = () => {
  if (stopping) return;
  stopping = true; clearInterval(leaseTimer); sessions.closeAll();
  server.close(async () => { await lock.close(); await unlink(lockPath); });
};
process.once('SIGTERM', stop); process.once('SIGINT', stop);
