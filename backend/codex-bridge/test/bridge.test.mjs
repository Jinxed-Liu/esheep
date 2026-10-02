import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { mkdtemp, chmod, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { appServerArguments, PlanCredentialStore, readProtectedJSON, writeProtectedJSON } from '../provider.mjs';
import { BridgeSessions, authenticate, createBridgeServer, normalizeScope, validateTools } from '../bridge.mjs';
import { CodexRPC } from '../rpc.mjs';

const scope = { accountID: '11111111-1111-4111-8111-111111111111',
  farmID: '22222222-2222-4222-8222-222222222222', conversationID: '33333333-3333-4333-8333-333333333333' };
const token = 'test-bridge-token-never-real-credentials-0123456789';
const digest = value => createHash('sha256').update(value).digest('hex');
const grant = { id: 'test-grant', accountID: scope.accountID, farmIDs: [scope.farmID],
  registrationID: 'test-registration', tokenSHA256: digest(token) };
const tools = [{ name: 'query_farm_data', description: 'Read current farm only.', inputSchema: { type: 'object', properties: {} } },
  { name: 'draft_record_weight', description: 'Prepare a proposed card; do not execute.', inputSchema: { type: 'object', properties: {} } }];
const gates = { partnerApproved: true, callbackApproved: true, privacyApproved: true, runtimeIsolationVerified: true };
const body = { scope, tools, modelSlug: 'fixture-model', instructions: 'Farm context.' };
const requestID = '44444444-4444-4444-8444-444444444444';

class FakeRPC extends EventEmitter {
  constructor() { super(); this.calls = []; this.responses = []; this.turns = []; }
  async initialize() { this.calls.push(['initialize']); return {}; }
  async call(method, params) {
    this.calls.push([method, params]);
    if (method === 'thread/start' || method === 'thread/resume') return { thread: { id: 'fixture-thread' } };
    if (method === 'model/list') return { data: [{ id: 'fixture-model', supportedReasoningEfforts: [{ reasoningEffort: 'low' }, { reasoningEffort: 'medium' }, { reasoningEffort: 'high' }] }] };
    if (method === 'turn/start') { const turn = { id: `turn-${this.turns.length}`, status: 'inProgress' }; this.turns.push(turn); return { turn }; }
    if (method === 'thread/read') return { thread: { turns: this.turns } };
    return {};
  }
  respond(id, result) { this.responses.push({ id, result }); }
  rejectRequest(id) { this.responses.push({ id, rejected: true }); }
  close() { this.closed = true; this.emit('closed'); }
}

async function fixture(t, overrides = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'esheep-codex-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const rpcs = []; let now = 1_000_000;
  const credentials = { models: async () => [{ slug: 'fixture-model', displayName: 'Fixture model' }],
    get: async () => ({ accessToken: 'fixture-plan-token', expiresAt: now + 600_000 }) };
  const sessions = new BridgeSessions({ dataDirectory: directory, credentials, gates,
    rpcFactory: () => { const rpc = new FakeRPC(); rpcs.push(rpc); return rpc; },
    now: () => now, ...overrides });
  t.after(() => sessions.closeAll());
  return { sessions, rpcs, advance: milliseconds => { now += milliseconds; }, directory };
}

test('bridge bearer grant binds both account and allowed farm; arbitrary account/farm rejected', () => {
  assert.equal(authenticate({ headers: { authorization: `Bearer ${token}` } }, [grant]), grant);
  assert.throws(() => authenticate({ headers: { authorization: 'Bearer wrong-token-with-at-least-thirty-two-bytes' } }, [grant]), /authentication_required/);
  assert.deepEqual(normalizeScope(scope, grant), scope);
  assert.throws(() => normalizeScope({ ...scope, farmID: scope.conversationID }, grant), /scope_not_authorized/);
  assert.throws(() => normalizeScope({ ...scope, accountID: scope.conversationID }, grant), /scope_not_authorized/);
});

test('every production release gate blocks before a host process or model call', async t => {
  for (const key of Object.keys(gates)) {
    const { sessions, rpcs } = await fixture(t, { gates: { ...gates, [key]: false } });
    await assert.rejects(sessions.open(grant, body), /codex_connection_not_approved/);
    assert.equal(rpcs.length, 0);
  }
});

test('tool allowlist rejects shell, apply_patch, execute-draft, hidden tool search and duplicates', () => {
  for (const name of ['exec_command', 'apply_patch', 'execute_draft', 'tool_search', 'write_farm_database']) {
    assert.throws(() => validateTools([{ ...tools[0], name }]), /unauthorized_tool/);
  }
  assert.throws(() => validateTools([tools[0], tools[0]]), /unauthorized_tool/);
});

test('host uses genuine stdio provider configuration with public Responses and no forbidden output budgets', () => {
  const args = appServerArguments().join(' ');
  assert.match(args, /api.openai.com\/v1/);
  assert.match(args, /requires_openai_auth=false/);
  assert.match(args, /supports_websockets=false/);
  assert.match(args, /features.shell_tool=false/);
  assert.match(args, /features.unified_exec=false/);
  assert.match(args, /features.multi_agent=false/);
  assert.doesNotMatch(args, /backend-api|max_output_tokens|previous_response_id|chatgptAuthTokens/);
});

test('same scoped conversation opens once and retries stable turn without submitting twice', async t => {
  const { sessions, rpcs } = await fixture(t);
  const [first, second] = await Promise.all([sessions.open(grant, body), sessions.open(grant, body)]);
  assert.deepEqual(first, second); assert.equal(rpcs.length, 1);
  assert.equal(first.accessVerified, false);
  const session = sessions.get(grant, first.sessionID);
  const turn = { requestID, text: 'Analyze weights.', effort: 'medium' };
  assert.deepEqual(await sessions.turn(session, turn), await sessions.turn(session, turn));
  assert.equal(rpcs[0].calls.filter(value => value[0] === 'turn/start').length, 1);
  await assert.rejects(sessions.turn(session, { ...turn, text: 'Different request.' }), /request_id_reused/);
  await assert.rejects(sessions.turn(session, { ...turn, requestID: scope.conversationID }), /turn_already_running/);
});

test('turn honors actual advertised effort and accepts explicit text input only', async t => {
  const { sessions, rpcs } = await fixture(t);
  const thread = await sessions.open(grant, body);
  const session = sessions.get(grant, thread.sessionID);
  await assert.rejects(sessions.turn(session, { requestID, text: 'test', effort: 'ultra' }), /unsupported_reasoning_effort/);
  await assert.rejects(sessions.turn(session, { requestID, text: 'test', audio: 'unsupported' }), /unsupported_turn_fields/);
  await sessions.turn(session, { requestID, text: 'test', effort: 'high' });
  const params = rpcs[0].calls.find(value => value[0] === 'turn/start')[1];
  assert.deepEqual(params.input, [{ type: 'text', text: 'test' }]);
  assert.equal(params.effort, 'high');
  assert.equal(Object.hasOwn(params, 'max_output_tokens'), false);
});

test('runtime shell and file approvals are declined, unknown RPCs never approved', async t => {
  const { sessions, rpcs } = await fixture(t);
  await sessions.open(grant, body);
  for (const method of ['item/commandExecution/requestApproval', 'item/fileChange/requestApproval', 'account/login/start']) {
    rpcs[0].emit('request', { id: method, method, params: {} });
  }
  assert.deepEqual(rpcs[0].responses.slice(0, 2).map(value => value.result), [{ decision: 'decline' }, { decision: 'decline' }]);
  assert.equal(rpcs[0].responses[2].rejected, true);
});

test('native tools receive scoped requests; a returned draft receipt does not approve or execute it', async t => {
  const { sessions, rpcs } = await fixture(t);
  const thread = await sessions.open(grant, body); const session = sessions.get(grant, thread.sessionID);
  await sessions.turn(session, { requestID, text: 'Draft a weight.', effort: 'medium' });
  const request = { id: 91, method: 'item/tool/call', params: { threadId: thread.threadID,
    turnId: session.turnID, callId: 'draft-1', tool: 'draft_record_weight', arguments: { kilograms: '55' } } };
  rpcs[0].emit('request', request);
  const event = sessions.events(session).events.find(value => value.kind === 'toolCall');
  assert.deepEqual(event.scope, scope); assert.equal(event.toolName, 'draft_record_weight');
  assert.equal(rpcs[0].responses.length, 0);
  await sessions.toolResult(session, { callID: 'draft-1', text: '{"draft_status":"proposed"}', success: true });
  assert.deepEqual(rpcs[0].responses[0].result, { success: true, contentItems: [{ type: 'inputText', text: '{"draft_status":"proposed"}' }] });
  assert.equal(rpcs[0].calls.some(value => /approve|execute/.test(value[0])), false);
  rpcs[0].emit('request', { ...request, id: 92 });
  assert.equal(rpcs[0].responses.length, 2);
  rpcs[0].emit('request', { ...request, id: 93, params: { ...request.params, arguments: { kilograms: '99' } } });
  assert.equal(rpcs[0].responses[2].rejected, true);
  await assert.rejects(sessions.toolResult(session, { callID: 'draft-1', text: 'approved', success: true }), /tool_receipt_changed/);
});

test('cross-thread and unregistered native tool requests fail without reaching iOS', async t => {
  const { sessions, rpcs } = await fixture(t);
  const thread = await sessions.open(grant, body); const session = sessions.get(grant, thread.sessionID);
  for (const params of [{ threadId: 'other-thread', tool: 'query_farm_data' }, { threadId: thread.threadID, tool: 'draft_transfer_sheep' }]) {
    rpcs[0].emit('request', { id: 4, method: 'item/tool/call', params: { ...params, callId: 'c', turnId: 't', arguments: {} } });
  }
  assert.equal(sessions.events(session).events.length, 0);
  assert.ok(rpcs[0].responses.every(value => value.result.success === false));
});

test('failed and interrupted turns never grant model access; completed does', async t => {
  for (const status of ['failed', 'interrupted', 'completed']) {
    const { sessions, rpcs } = await fixture(t);
    const thread = await sessions.open(grant, body); const session = sessions.get(grant, thread.sessionID);
    await sessions.turn(session, { requestID, text: 'test' });
    rpcs[0].emit('notification', { method: 'turn/completed', params: { threadId: thread.threadID, turn: { id: session.turnID, status } } });
    assert.equal(sessions.describe(session).accessVerified, status === 'completed');
    await session.persistTail;
  }
});

test('official structured usage-limit errors pause accurately without exposing raw provider text', async t => {
  const { sessions, rpcs } = await fixture(t);
  const thread = await sessions.open(grant, body); const session = sessions.get(grant, thread.sessionID);
  rpcs[0].emit('notification', { method: 'error', params: { threadId: thread.threadID,
    turnId: 'fixture-turn', error: { codexErrorInfo: 'usageLimitExceeded', message: 'sensitive-fixture-raw-provider-message' } } });
  const event = sessions.events(session).events[0];
  assert.equal(event.errorCode, 'chatgpt_usage_limit_exceeded');
  assert.equal(JSON.stringify(event).includes('sensitive-fixture'), false);
});

test('lease expiry kills the genuine process rather than letting disconnected tools continue', async t => {
  const { sessions, rpcs, advance } = await fixture(t);
  const thread = await sessions.open(grant, body);
  advance(31_000); sessions.expireLeases();
  assert.equal(rpcs[0].closed, true);
  assert.throws(() => sessions.get(grant, thread.sessionID), /session_not_authorized/);
});

test('conversation deletion removes scoped host history and tombstone prevents resurrection', async t => {
  const { sessions, rpcs, directory } = await fixture(t);
  const thread = await sessions.open(grant, body);
  assert.deepEqual(await sessions.removeConversation(grant, scope), { removed: true });
  assert.equal(rpcs[0].closed, true);
  await assert.rejects(readFile(join(directory, thread.sessionID, 'thread.json')), /ENOENT/);
  await assert.rejects(sessions.open(grant, body), /conversation_deleted/);
  await assert.rejects(sessions.removeConversation(grant, { ...scope, farmID: scope.conversationID }), /scope_not_authorized/);
});

test('token refresh restarts process and resumes exactly the same scoped thread', async t => {
  let requests = 0;
  const { sessions, rpcs } = await fixture(t, { credentials: {
    models: async () => [{ slug: 'fixture-model' }], get: async (_, options) => {
      requests++; return { accessToken: options?.forceRefresh ? 'renewed-fixture' : 'original-fixture',
        expiresAt: options?.forceRefresh ? 2_000_000 : 1_000_001 };
    },
  } });
  const thread = await sessions.open(grant, body); const session = sessions.get(grant, thread.sessionID);
  await sessions.turn(session, { requestID, text: 'test' });
  assert.equal(rpcs.length, 2); assert.equal(rpcs[0].closed, true); assert.equal(requests, 2);
  assert.equal(rpcs[1].calls.find(value => value[0] === 'thread/resume')[1].threadId, thread.threadID);
  assert.equal(rpcs[1].calls.filter(value => value[0] === 'thread/start').length, 0);
});

test('persisted thread is account/farm/registration bound and uncertain turns cannot be resubmitted', async t => {
  const { sessions, directory } = await fixture(t);
  const thread = await sessions.open(grant, body); const session = sessions.get(grant, thread.sessionID);
  session.record.requests[requestID] = { digest: 'unknown', status: 'starting' };
  await writeProtectedJSON(session.recordPath, session.record); sessions.close(session);
  const reopened = await sessions.open(grant, body);
  await assert.rejects(sessions.turn(sessions.get(grant, reopened.sessionID), { requestID: scope.conversationID, text: 'retry' }), /checkpoint_reconciliation_required/);
  sessions.closeAll();
  const path = join(directory, thread.sessionID, 'thread.json');
  const record = JSON.parse(await readFile(path, 'utf8')); record.scope.farmID = scope.conversationID;
  await writeProtectedJSON(path, record);
  await assert.rejects(sessions.open(grant, body), /thread_scope_or_configuration_mismatch/);
});

test('HTTP bridge rejects unauthenticated requests, browser origins, arbitrary RPC and foreign session', async t => {
  const { sessions } = await fixture(t);
  const server = createBridgeServer({ sessions, grants: [grant] });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  assert.equal((await fetch(`${base}/v1/models`)).status, 401);
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  assert.equal((await fetch(`${base}/v1/models`, { headers: { ...headers, Origin: 'https://evil.example' } })).status, 403);
  assert.equal((await fetch(`${base}/command/exec`, { method: 'POST', headers, body: '{}' })).status, 404);
  const response = await fetch(`${base}/v1/sessions`, { method: 'POST', headers, body: JSON.stringify(body) });
  assert.equal(response.status, 200);
  const thread = await response.json();
  assert.equal((await fetch(`${base}/v1/sessions/${'a'.repeat(64)}/events`, { headers })).status, 403);
  const events = await fetch(`${base}/v1/sessions/${thread.sessionID}/events`, { headers });
  assert.equal(events.headers.get('cache-control'), 'no-store');
});

test('OAuth refresh is serialized, retains issued client and scopes, rotates private credentials', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'esheep-oauth-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'registration.json');
  await writeProtectedJSON(path, { registrationID: grant.registrationID, identityValidated: true,
    clientID: 'issued-client', accessToken: 'expired-fixture', refreshToken: 'refresh-fixture',
    expiresAt: 0, scopes: ['offline_access', 'resource.invoke', 'chatgpt.tokens.use.direct'] });
  let calls = 0;
  const store = new PlanCredentialStore({ [grant.registrationID]: path }, { now: () => 100_000,
    fetcher: async (url, options) => {
      calls++; assert.equal(url, 'https://auth.openai.com/api/accounts/oauth/token');
      assert.equal(options.body.get('client_id'), 'issued-client');
      assert.equal(options.body.get('resource'), 'https://api.openai.com/v1');
      assert.equal(options.body.has('scope'), false);
      return Response.json({ access_token: 'new-access-fixture', refresh_token: 'new-refresh-fixture', expires_in: 3600 });
    },
  });
  const [first, second] = await Promise.all([store.get(grant.registrationID), store.get(grant.registrationID)]);
  assert.deepEqual(first, second); assert.equal(calls, 1);
  assert.equal((await readProtectedJSON(path)).refreshToken, 'new-refresh-fixture');
  await chmod(path, 0o644);
  await assert.rejects(readProtectedJSON(path), /credential_storage_not_private/);
});

test('model catalog uses same OAuth registration and visibility=list, never bundled entitlement', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'esheep-model-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'registration.json');
  await writeProtectedJSON(path, { registrationID: grant.registrationID, identityValidated: true,
    clientID: 'issued-client', accessToken: 'catalog-fixture', refreshToken: 'refresh-fixture',
    expiresAt: Date.now() + 600_000, scopes: ['offline_access', 'resource.invoke', 'chatgpt.tokens.use.direct'] });
  const store = new PlanCredentialStore({ [grant.registrationID]: path }, { fetcher: async (url, options) => {
    assert.equal(url, 'https://api.openai.com/v1/models');
    assert.equal(options.headers.Authorization, 'Bearer catalog-fixture');
    return Response.json({ models: [{ visibility: 'list', slug: 'visible', display_name: 'Visible' }, { visibility: 'hidden', slug: 'hidden' }] });
  } });
  assert.deepEqual(await store.models(grant.registrationID), [{ slug: 'visible', displayName: 'Visible' }]);
});

test('stdio adapter decodes fragmented NDJSON, resolves replies, denies malformed lines and hides inherited secrets', async t => {
  const child = new EventEmitter(); child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
  child.kill = () => {};
  let options; let input = '';
  child.stdin.on('data', chunk => { input += chunk.toString(); });
  const rpc = new CodexRPC({ home: '/fixture', cwd: '/fixture', accessToken: 'fixture-access',
    spawnProcess: (_, __, value) => { options = value; return child; } });
  t.after(() => rpc.close());
  const initializing = rpc.initialize();
  await new Promise(resolve => setImmediate(resolve));
  const request = JSON.parse(input.trim());
  assert.equal(request.params.clientInfo.name, 'esheep');
  assert.deepEqual(Object.keys(options.env).sort(), ['ACCESS_TOKEN', 'CODEX_HOME', 'HOME', 'PATH']);
  child.stdout.write(`{"id":${request.id},"res`); child.stdout.write('ult":{"ready":true}}\n');
  assert.deepEqual(await initializing, { ready: true });
  child.stdout.write('invalid-json\n');
  await assert.rejects(rpc.call('model/list', {}), /codex_process_stopped/);
});
