import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { appServerArguments, BridgeError } from './provider.mjs';

/** Only this internal adapter speaks raw JSON-RPC. HTTP clients cannot send RPC methods. */
export class CodexRPC extends EventEmitter {
  #nextID = 1;
  #pending = new Map();
  #buffer = '';
  #closed = false;
  #killTimer;
  constructor({ binary = 'codex', home, cwd, accessToken, spawnProcess = spawn }) {
    super();
    this.child = spawnProcess(binary, appServerArguments(), {
      cwd,
      // Never inherit host/provider credentials, proxy settings, or a first-party Codex login.
      env: { PATH: process.env.PATH, HOME: home, CODEX_HOME: home, ACCESS_TOKEN: accessToken },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.child.stdout.setEncoding('utf8');
    this.child.stdout.on('data', chunk => this.#consume(chunk));
    // Do not forward raw stderr: SDK errors may contain token or prompt material.
    this.child.stderr.resume();
    this.exitPromise = new Promise(resolve => { this.child.once('exit', resolve); this.child.once('error', resolve); });
    this.child.on('error', () => this.#shutdown('codex_process_unavailable'));
    this.child.on('exit', () => { clearTimeout(this.#killTimer); this.#shutdown('codex_process_stopped'); });
  }
  async initialize() {
    const result = await this.call('initialize', { clientInfo: {
      name: 'esheep', title: 'eSheep', version: '0.1.0',
    }, capabilities: { experimentalApi: true } });
    this.notify('initialized', {});
    return result;
  }
  call(method, params, timeout = 30_000) {
    if (this.#closed) return Promise.reject(new BridgeError('codex_process_stopped', 503));
    const id = this.#nextID++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id); reject(new BridgeError('codex_rpc_timeout', 504));
      }, timeout);
      this.#pending.set(id, { resolve, reject, timer });
      this.#write({ id, method, params });
    });
  }
  notify(method, params) { this.#write({ method, params }); }
  respond(id, result) { this.#write({ id, result }); }
  rejectRequest(id) { this.#write({ id, error: { code: -32601, message: 'Unauthorized bridge method' } }); }
  #write(message) {
    if (!this.#closed) this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }
  #consume(chunk) {
    if (this.#closed) return;
    this.#buffer += chunk;
    if (Buffer.byteLength(this.#buffer) > 2 * 1024 * 1024) {
      this.close(); return;
    }
    let end;
    while ((end = this.#buffer.indexOf('\n')) >= 0) {
      const line = this.#buffer.slice(0, end); this.#buffer = this.#buffer.slice(end + 1);
      if (!line.trim()) continue;
      let value;
      try { value = JSON.parse(line); } catch { this.close(); return; }
      if (value.method) this.emit(value.id === undefined ? 'notification' : 'request', value);
      else {
        const pending = this.#pending.get(value.id);
        if (!pending) continue;
        clearTimeout(pending.timer); this.#pending.delete(value.id);
        if (value.error) pending.reject(new BridgeError('codex_rpc_rejected', 502));
        else pending.resolve(value.result);
      }
    }
  }
  #shutdown(code) {
    if (this.#closed) return;
    this.#closed = true;
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer); pending.reject(new BridgeError(code, 503));
    }
    this.#pending.clear(); this.emit('closed', code);
  }
  close() {
    if (this.#closed) return;
    this.child.kill('SIGTERM');
    this.#killTimer = setTimeout(() => this.child.kill('SIGKILL'), 2000);
    this.#killTimer.unref();
    this.#shutdown('codex_process_stopped');
  }
}
