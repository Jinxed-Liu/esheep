import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { CodexRPC } from '../rpc.mjs';

const directory = await mkdtemp(join(tmpdir(), 'esheep-codex-smoke-'));
const home = join(directory, 'home'); const cwd = join(directory, 'workspace');
await mkdir(home, { mode: 0o700 }); await mkdir(cwd, { mode: 0o700 });
const rpc = new CodexRPC({ binary: process.env.ESHEEP_CODEX_BINARY ?? 'codex', home, cwd,
  accessToken: 'smoke-fixture-no-inference-no-user-login' });
try {
  const initialized = await rpc.initialize();
  assert.ok(initialized);
  const { config } = await rpc.call('config/read', {});
  const provider = config.model_providers.openai_chatgpt_plan;
  assert.equal(config.model_provider, 'openai_chatgpt_plan');
  assert.equal(provider.base_url, 'https://api.openai.com/v1');
  assert.equal(provider.requires_openai_auth, false);
  assert.equal(provider.supports_websockets, false);
  assert.equal(config.features.shell_tool, false);
  assert.equal(config.features.unified_exec, false);
  assert.equal(config.features.multi_agent, false);
  process.stdout.write(JSON.stringify({ actualAppServerInitialized: true,
    publicResponsesProviderConfigured: true, shellDisabled: true, multiAgentDisabled: true,
    userLoginAttempted: false, inferenceAttempted: false }) + '\n');
} finally { rpc.close(); await rm(directory, { recursive: true, force: true }); }
