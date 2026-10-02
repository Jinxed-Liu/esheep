import { open, mkdir, rename, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { dirname } from 'node:path';

export class BridgeError extends Error {
  constructor(code, status = 400) { super(code); this.code = code; this.status = status; }
}

export async function readProtectedJSON(path) {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || (stat.mode & 0o077) !== 0 ||
        (process.getuid && stat.uid !== process.getuid())) {
      throw new BridgeError('credential_storage_not_private', 503);
    }
    return JSON.parse(await file.readFile('utf8'));
  } finally {
    await file.close();
  }
}

export async function writeProtectedJSON(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${crypto.randomUUID()}.tmp`;
  await writeFile(temporary, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
  await rename(temporary, path);
}

const planScopes = ['offline_access', 'resource.invoke', 'chatgpt.tokens.use.direct'];
export function validateRegistration(value, expectedID) {
  if (value.registrationID !== expectedID || !value.identityValidated || !value.clientID ||
      value.clientID === 'dynamic_agent_client' || !value.accessToken ||
      !value.refreshToken || !Number.isFinite(value.expiresAt) ||
      !planScopes.every(scope => value.scopes?.includes(scope))) {
    throw new BridgeError('chatgpt_plan_authorization_required', 503);
  }
  return value;
}

/** A registration is installed only after a separately approved OAuth flow validates identity. */
export class PlanCredentialStore {
  #pending = new Map();
  constructor(registrations, { fetcher = fetch, now = () => Date.now() } = {}) {
    this.registrations = registrations;
    this.fetcher = fetcher;
    this.now = now;
  }
  async get(registrationID, { forceRefresh = false } = {}) {
    if (this.#pending.has(registrationID)) return this.#pending.get(registrationID);
    const work = this.#load(registrationID, forceRefresh);
    this.#pending.set(registrationID, work);
    try { return await work; } finally { this.#pending.delete(registrationID); }
  }
  async #load(registrationID, forceRefresh) {
    const path = this.registrations[registrationID];
    if (!path) throw new BridgeError('registration_not_authorized', 403);
    let value = validateRegistration(await readProtectedJSON(path), registrationID);
    if (!forceRefresh && value.expiresAt > this.now() + 60_000) return value;
    const response = await this.fetcher('https://auth.openai.com/api/accounts/oauth/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'refresh_token', client_id: value.clientID,
        refresh_token: value.refreshToken, resource: 'https://api.openai.com/v1' }),
      signal: AbortSignal.timeout(15_000), redirect: 'error',
    });
    if (!response.ok) throw new BridgeError('chatgpt_reauthorization_required', 503);
    const replacement = await response.json();
    if (!replacement.access_token || !replacement.refresh_token || !Number.isFinite(replacement.expires_in)) {
      throw new BridgeError('invalid_token_refresh_response', 503);
    }
    value = { ...value, accessToken: replacement.access_token,
      refreshToken: replacement.refresh_token,
      expiresAt: this.now() + replacement.expires_in * 1000 };
    // Persist a rotating refresh token before another process may use it.
    await writeProtectedJSON(path, value);
    return value;
  }
  async models(registrationID) {
    const credentials = await this.get(registrationID);
    const response = await this.fetcher('https://api.openai.com/v1/models', {
      headers: { Authorization: `Bearer ${credentials.accessToken}` },
      signal: AbortSignal.timeout(15_000), redirect: 'error',
    });
    if (!response.ok) throw new BridgeError('model_catalog_unavailable', 503);
    const value = await response.json();
    if (!Array.isArray(value.models)) throw new BridgeError('invalid_model_catalog', 503);
    return value.models.filter(model => model.visibility === 'list' && typeof model.slug === 'string')
      .map(model => ({ slug: model.slug, displayName: model.display_name ?? model.slug }));
  }
}

export function appServerArguments() {
  const provider = 'model_providers.openai_chatgpt_plan';
  const settings = [
    'model_provider="openai_chatgpt_plan"',
    `${provider}.name="ChatGPT plan"`,
    `${provider}.base_url="https://api.openai.com/v1"`,
    `${provider}.env_key="ACCESS_TOKEN"`,
    `${provider}.wire_api="responses"`,
    `${provider}.requires_openai_auth=false`,
    `${provider}.supports_websockets=false`,
    'approval_policy="on-request"', 'sandbox_mode="read-only"', 'web_search="disabled"',
    'features.shell_tool=false', 'features.unified_exec=false', 'features.code_mode=false',
    'features.code_mode_host=false', 'features.multi_agent=false', 'features.plugins=false',
    'features.apps=false', 'features.hooks=false', 'features.browser_use=false',
    'features.computer_use=false', 'features.image_generation=false', 'features.view_image=false',
    'features.skill_search=false', 'features.workspace_dependencies=false',
  ];
  return ['app-server', '--listen', 'stdio://', ...settings.flatMap(value => ['-c', value])];
}
