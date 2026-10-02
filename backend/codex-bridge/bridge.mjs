import { createServer } from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';
import { mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { BridgeError, readProtectedJSON, writeProtectedJSON } from './provider.mjs';
import { CodexRPC } from './rpc.mjs';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const permittedTools = new Set([
  'get_farm_overview', 'query_farm_data', 'calculate_farm_data', 'find_sheep',
  'match_sheep_ear_tags', 'get_farm_entities', 'create_farm_export', 'analyze_farm',
  'get_extended_farm_records', 'get_farm_action_schema', 'draft_reminder',
  'draft_calendar_event', 'draft_farm_command', 'draft_record_weaning',
  'draft_record_weanings', 'draft_record_weight', 'draft_record_weights',
  'draft_sell_sheep_batch', 'draft_add_note', 'draft_transfer_sheep',
]);
const hash = value => createHash('sha256').update(value).digest('hex');
const scopeKey = scope => hash(JSON.stringify(scope));
const requireValue = (condition, code, status) => { if (!condition) throw new BridgeError(code, status); };
const publicTurnError = error => ({
  usageLimitExceeded: 'chatgpt_usage_limit_exceeded',
  unauthorized: 'chatgpt_reauthorization_required',
  sessionBudgetExceeded: 'codex_session_budget_exceeded',
  contextWindowExceeded: 'codex_context_window_exceeded',
  rateLimitExceeded: 'codex_rate_limit_exceeded',
}[error?.codexErrorInfo] ?? 'codex_turn_error');

export function normalizeScope(value, grant) {
  requireValue(value && ['accountID', 'farmID', 'conversationID'].every(key => uuid.test(value[key])), 'invalid_scope');
  const scope = Object.fromEntries(['accountID', 'farmID', 'conversationID'].map(key => [key, value[key].toLowerCase()]));
  requireValue(scope.accountID === grant.accountID.toLowerCase() &&
    grant.farmIDs.some(id => id.toLowerCase() === scope.farmID), 'scope_not_authorized', 403);
  return scope;
}

export function validateTools(tools) {
  requireValue(Array.isArray(tools) && tools.length > 0 && tools.length <= 24, 'invalid_tools');
  const names = new Set();
  return tools.map(tool => {
    requireValue(permittedTools.has(tool.name) && !names.has(tool.name) &&
      typeof tool.description === 'string' && tool.description.length <= 4000 &&
      tool.inputSchema?.type === 'object', 'unauthorized_tool', 403);
    names.add(tool.name);
    return { type: 'function', name: tool.name, description: tool.description,
      inputSchema: tool.inputSchema, deferLoading: false };
  });
}

export class BridgeSessions {
  constructor({ dataDirectory, credentials, gates, binary = 'codex',
    rpcFactory = options => new CodexRPC(options), now = () => Date.now(), leaseMS = 30_000 }) {
    this.dataDirectory = dataDirectory; this.credentials = credentials; this.gates = gates;
    this.binary = binary; this.rpcFactory = rpcFactory; this.now = now; this.leaseMS = leaseMS;
    this.sessions = new Map(); this.opening = new Map();
    this.deletedScopes = new Set();
  }
  ensureEnabled() {
    requireValue(['partnerApproved', 'callbackApproved', 'privacyApproved', 'runtimeIsolationVerified']
      .every(key => this.gates[key] === true), 'codex_connection_not_approved', 503);
  }
  async open(grant, body) {
    this.ensureEnabled();
    const scope = normalizeScope(body.scope, grant);
    const tools = validateTools(body.tools);
    requireValue(typeof body.modelSlug === 'string' && typeof body.instructions === 'string' &&
      body.instructions.length <= 24_000, 'invalid_session');
    const id = scopeKey({ ...scope, registrationID: grant.registrationID });
    requireValue(!this.deletedScopes.has(id), 'conversation_deleted', 410);
    try {
      await readProtectedJSON(join(this.dataDirectory, '.deleted', `${id}.json`));
      this.deletedScopes.add(id); throw new BridgeError('conversation_deleted', 410);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (this.opening.has(id)) return this.opening.get(id);
    const existing = this.sessions.get(id);
    if (existing) {
      requireValue(existing.record.modelSlug === body.modelSlug &&
        existing.record.toolsHash === hash(JSON.stringify(tools)), 'thread_configuration_changed', 409);
      existing.expiresAt = this.now() + this.leaseMS;
      return this.describe(existing);
    }
    requireValue(this.sessions.size + this.opening.size < 2, 'host_capacity_reached', 429);
    const work = this.#open(id, scope, tools, grant, body);
    this.opening.set(id, work);
    try { return await work; } finally { this.opening.delete(id); }
  }
  async #open(id, scope, tools, grant, body) {
    const catalog = await this.credentials.models(grant.registrationID);
    requireValue(catalog.some(model => model.slug === body.modelSlug), 'model_not_in_account_catalog', 403);
    const directory = join(this.dataDirectory, id);
    const home = join(directory, 'codex-home');
    const cwd = join(directory, 'workspace');
    await mkdir(home, { recursive: true, mode: 0o700 });
    await mkdir(cwd, { recursive: true, mode: 0o700 });
    const recordPath = join(directory, 'thread.json');
    let record;
    try { record = await readProtectedJSON(recordPath); } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (record) {
      requireValue(JSON.stringify(record.scope) === JSON.stringify(scope) &&
        record.registrationID === grant.registrationID && record.modelSlug === body.modelSlug &&
        record.toolsHash === hash(JSON.stringify(tools)), 'thread_scope_or_configuration_mismatch', 403);
    }
    const credential = await this.credentials.get(grant.registrationID);
    const options = { binary: this.binary, home, cwd, accessToken: credential.accessToken };
    const rpc = this.rpcFactory(options);
    const session = { id, scope, grant, recordPath, record, rpc, options,
      events: [], sequence: 0, pendingTools: new Map(), expiresAt: this.now() + this.leaseMS,
      toolNames: new Set(tools.map(value => value.name)), persistTail: Promise.resolve(),
      tokenExpiresAt: credential.expiresAt, turnID: null, restarting: false, submitting: false };
    this.#attach(session, rpc);
    try {
      await rpc.initialize();
      const params = { model: body.modelSlug, cwd, approvalPolicy: 'on-request', sandbox: 'read-only',
        developerInstructions: body.instructions + '\nOnly authorized farm tools may be used. Drafts require confirmation in the eSheep app; never execute or approve business mutations.',
      };
      let result;
      if (record) result = await rpc.call('thread/resume', { ...params, threadId: record.threadID });
      else result = await rpc.call('thread/start', { ...params, dynamicTools: tools });
      requireValue(typeof result?.thread?.id === 'string', 'invalid_thread_response', 502);
      const modelList = await rpc.call('model/list', {});
      const model = modelList.data?.find(value => value.id === body.modelSlug || value.model === body.modelSlug);
      session.reasoningEfforts = (model?.supportedReasoningEfforts ?? [])
        .map(value => typeof value === 'string' ? value : value.reasoningEffort)
        .filter(value => typeof value === 'string');
      session.record = record ?? { scope, registrationID: grant.registrationID,
        threadID: result.thread.id, modelSlug: body.modelSlug, toolsHash: hash(JSON.stringify(tools)),
        requests: {}, toolReceipts: {} };
      requireValue(session.record.threadID === result.thread.id, 'unexpected_resumed_thread', 502);
      if (record) {
        // Reconcile terminal statuses from the official persisted thread, never replay writes.
        const persisted = await rpc.call('thread/read', { threadId: record.threadID, includeTurns: true });
        for (const request of Object.values(record.requests)) {
          const turn = persisted.thread?.turns?.find(value => value.id === request.turnID);
          if (turn && ['completed', 'failed', 'interrupted'].includes(turn.status)) request.status = turn.status;
        }
      }
      await this.#persist(session);
      requireValue(!this.deletedScopes.has(id), 'conversation_deleted', 410);
      this.sessions.set(id, session);
      return this.describe(session);
    } catch (error) { session.restarting = true; rpc.close(); throw error; }
  }
  describe(session) {
    return { sessionID: session.id, scope: session.scope, threadID: session.record.threadID,
      modelSlug: session.record.modelSlug, supportedReasoningEfforts: session.reasoningEfforts,
      accessVerified: Object.values(session.record.requests).some(value => value.status === 'completed') };
  }
  get(grant, id) {
    const session = this.sessions.get(id);
    requireValue(session && session.grant.id === grant.id &&
      session.grant.registrationID === grant.registrationID, 'session_not_authorized', 403);
    normalizeScope(session.scope, grant); session.expiresAt = this.now() + this.leaseMS;
    return session;
  }
  async #renew(session) {
    if (session.tokenExpiresAt > this.now() + 60_000) return;
    requireValue(!session.turnID && session.pendingTools.size === 0, 'token_refresh_waiting_for_turn', 409);
    session.restarting = true; session.rpc.close();
    try {
      const token = await this.credentials.get(session.grant.registrationID, { forceRefresh: true });
      session.options.accessToken = token.accessToken;
      session.rpc = this.rpcFactory(session.options); this.#attach(session, session.rpc);
      await session.rpc.initialize();
      const result = await session.rpc.call('thread/resume', { threadId: session.record.threadID,
        approvalPolicy: 'on-request', sandbox: 'read-only' });
      requireValue(result?.thread?.id === session.record.threadID, 'unexpected_resumed_thread', 502);
      session.tokenExpiresAt = token.expiresAt;
    } finally { session.restarting = false; }
  }
  async turn(session, body) {
    requireValue(Object.keys(body).every(key => ['requestID', 'text', 'effort'].includes(key)), 'unsupported_turn_fields');
    requireValue(uuid.test(body.requestID) && typeof body.text === 'string' &&
      body.text.trim().length > 0 && Buffer.byteLength(body.text) <= 200_000, 'invalid_turn');
    requireValue(body.effort == null || session.reasoningEfforts.includes(body.effort), 'unsupported_reasoning_effort');
    const requestID = body.requestID.toLowerCase();
    const digest = hash(JSON.stringify({ text: body.text, effort: body.effort ?? null }));
    const previous = session.record.requests[requestID];
    if (previous) {
      requireValue(previous.digest === digest, 'request_id_reused', 409);
      requireValue(previous.turnID, 'turn_status_uncertain', 409);
      return { turnID: previous.turnID, status: previous.status };
    }
    requireValue(!session.turnID && !session.submitting, 'turn_already_running', 409);
    requireValue(!Object.values(session.record.requests).some(value =>
      !['completed', 'failed', 'interrupted'].includes(value.status)), 'checkpoint_reconciliation_required', 409);
    requireValue(Object.keys(session.record.requests).length < 256, 'thread_request_limit', 409);
    session.submitting = true;
    try {
      await this.#renew(session);
      session.record.requests[requestID] = { digest, status: 'starting' };
      session.activeRequestID = requestID;
      await this.#persist(session);
      // A persisted starting record prevents an ambiguous timeout from sending a second turn.
      const result = await session.rpc.call('turn/start', { threadId: session.record.threadID,
        input: [{ type: 'text', text: body.text }], ...(body.effort ? { effort: body.effort } : {}) });
      requireValue(typeof result?.turn?.id === 'string', 'invalid_turn_response', 502);
      const request = session.record.requests[requestID];
      request.turnID = result.turn.id;
      if (request.status === 'starting') request.status = result.turn.status ?? 'inProgress';
      if (!['completed', 'failed', 'interrupted'].includes(request.status)) session.turnID = result.turn.id;
      await this.#persist(session);
      return { turnID: result.turn.id, status: request.status };
    } finally { session.submitting = false; }
  }
  events(session, after = 0) {
    requireValue(Number.isSafeInteger(after) && after >= 0 && after <= session.sequence, 'invalid_event_cursor');
    requireValue(!session.events.length || after >= session.events[0].sequence - 1, 'event_history_expired', 409);
    return { events: session.events.filter(event => event.sequence > after), cursor: session.sequence };
  }
  #event(session, kind, value = {}) {
    session.events.push({ sequence: ++session.sequence, kind, scope: session.scope,
      threadID: session.record?.threadID ?? null, ...value });
    if (session.events.length > 512) session.events.shift();
  }
  #persist(session) {
    const snapshot = JSON.parse(JSON.stringify(session.record));
    session.persistTail = session.persistTail.then(() => writeProtectedJSON(session.recordPath, snapshot));
    return session.persistTail;
  }
  #attach(session, rpc) {
    rpc.on('notification', value => {
      const params = value.params ?? {};
      if (params.threadId && params.threadId !== session.record?.threadID) return;
      if (value.method === 'turn/started' && params.turn?.id && session.activeRequestID) {
        session.turnID = params.turn.id;
        const request = session.record.requests[session.activeRequestID];
        if (request) { request.turnID = params.turn.id; request.status = params.turn.status ?? 'inProgress'; }
      }
      if (value.method === 'item/agentMessage/delta') this.#event(session, 'textDelta', {
        turnID: params.turnId, text: params.delta,
      });
      if (value.method === 'item/reasoning/summaryTextDelta') this.#event(session, 'reasoningSummaryDelta', {
        turnID: params.turnId, text: params.delta,
      });
      if (value.method === 'turn/completed') {
        const turn = params.turn;
        if (!turn || turn.id !== session.turnID) return;
        session.turnID = null;
        for (const request of Object.values(session.record.requests)) {
          if (request.turnID === turn.id) request.status = turn.status;
        }
        void this.#persist(session).catch(() => {
          this.#event(session, 'failed', { errorCode: 'checkpoint_write_failed' }); this.close(session);
        });
        this.#event(session, 'turnCompleted', { turnID: turn.id, status: turn.status,
          ...(turn.error ? { errorCode: publicTurnError(turn.error) } : {}) });
      }
      if (value.method === 'error') this.#event(session, 'failed', {
        turnID: params.turnId, errorCode: publicTurnError(params.error),
      });
    });
    rpc.on('request', value => {
      const params = value.params ?? {};
      if (value.method === 'item/commandExecution/requestApproval' ||
          value.method === 'item/fileChange/requestApproval') {
        rpc.respond(value.id, { decision: 'decline' });
        this.#event(session, 'blockedTool', { errorCode: 'runtime_tool_not_authorized' }); return;
      }
      if (value.method !== 'item/tool/call') { rpc.rejectRequest(value.id); return; }
      if (params.threadId !== session.record?.threadID || !session.toolNames.has(params.tool) ||
          !params.callId || !params.turnId || (session.turnID && params.turnId !== session.turnID)) {
        rpc.respond(value.id, { success: false, contentItems: [{ type: 'inputText', text: 'Unauthorized farm tool scope.' }] }); return;
      }
      const digest = hash(JSON.stringify({ tool: params.tool, arguments: params.arguments }));
      const receipt = session.record.toolReceipts[params.callId];
      if (receipt) {
        if (receipt.digest === digest) rpc.respond(value.id, receipt.result);
        else rpc.rejectRequest(value.id);
        return;
      }
      const previous = session.pendingTools.get(params.callId);
      if (previous) { rpc.rejectRequest(value.id); return; }
      session.pendingTools.set(params.callId, { rpcID: value.id, turnID: params.turnId, digest, rpc });
      this.#event(session, 'toolCall', { turnID: params.turnId, callID: params.callId,
        toolName: params.tool, argumentsJSON: JSON.stringify(params.arguments) });
    });
    rpc.on('closed', () => {
      if (session.restarting) return;
      this.#event(session, 'paused', { errorCode: 'codex_process_stopped' });
      this.sessions.delete(session.id);
    });
  }
  async toolResult(session, body) {
    requireValue(typeof body.callID === 'string' && typeof body.text === 'string' &&
      Buffer.byteLength(body.text) <= 100 * 1024 && typeof body.success === 'boolean', 'invalid_tool_result');
    const result = { success: body.success, contentItems: [{ type: 'inputText', text: body.text }] };
    if (session.record.toolReceipts[body.callID]) {
      requireValue(JSON.stringify(session.record.toolReceipts[body.callID].result) === JSON.stringify(result), 'tool_receipt_changed', 409);
      await session.persistTail;
      return { accepted: true };
    }
    const request = session.pendingTools.get(body.callID);
    requireValue(request, 'tool_call_not_pending', 409);
    session.record.toolReceipts[body.callID] = { digest: request.digest, result };
    await this.#persist(session);
    request.rpc.respond(request.rpcID, result); session.pendingTools.delete(body.callID);
    return { accepted: true };
  }
  async interrupt(session) {
    if (session.turnID) await session.rpc.call('turn/interrupt', {
      threadId: session.record.threadID, turnId: session.turnID,
    });
    // Kill the process as well: disconnect must prevent later autonomous tool rounds.
    this.close(session); return { paused: true };
  }
  close(session) {
    session.restarting = true; session.rpc.close(); session.pendingTools.clear();
    session.options.accessToken = ''; this.sessions.delete(session.id);
  }
  expireLeases() {
    for (const session of this.sessions.values()) if (session.expiresAt <= this.now()) this.close(session);
  }
  closeAll() { for (const session of [...this.sessions.values()]) this.close(session); }
  async removeConversation(grant, value) {
    const scope = normalizeScope(value, grant);
    const id = scopeKey({ ...scope, registrationID: grant.registrationID });
    this.deletedScopes.add(id);
    // Persist the tombstone first, so a delayed reconnect cannot revive deleted history.
    await writeProtectedJSON(join(this.dataDirectory, '.deleted', `${id}.json`), {
      scope, registrationID: grant.registrationID, deletedAt: this.now(),
    });
    if (this.opening.has(id)) await this.opening.get(id).catch(() => {});
    const session = this.sessions.get(id);
    if (session) {
      this.close(session);
      await session.persistTail.catch(() => {});
      if (session.rpc.exitPromise) await session.rpc.exitPromise;
    }
    await rm(join(this.dataDirectory, id), { recursive: true, force: true });
    return { removed: true };
  }
}

export function authenticate(request, grants) {
  const bearer = request.headers.authorization?.match(/^Bearer ([^\s]+)$/)?.[1];
  requireValue(bearer && bearer.length >= 32 && bearer.length <= 1024, 'authentication_required', 401);
  const digest = Buffer.from(hash(bearer), 'hex');
  const grant = grants.find(candidate => /^[0-9a-f]{64}$/i.test(candidate.tokenSHA256) &&
    timingSafeEqual(digest, Buffer.from(candidate.tokenSHA256, 'hex')));
  requireValue(grant, 'authentication_required', 401);
  return grant;
}

async function readBody(request) {
  let total = 0; const chunks = [];
  for await (const chunk of request) {
    total += chunk.length;
    requireValue(total <= 512 * 1024, 'request_too_large', 413); chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new BridgeError('invalid_json'); }
}

export function createBridgeServer({ sessions, grants }) {
  return createServer(async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('Content-Type', 'application/json');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    try {
      // No browser origins/CORS and no cookie-based ambient authorization.
      requireValue(!request.headers.origin, 'browser_origin_not_allowed', 403);
      const grant = authenticate(request, grants);
      const url = new URL(request.url, 'http://127.0.0.1');
      let result;
      if (request.method === 'GET' && url.pathname === '/v1/models') {
        sessions.ensureEnabled(); result = { models: await sessions.credentials.models(grant.registrationID) };
      } else if (request.method === 'POST' && url.pathname === '/v1/sessions') {
        result = await sessions.open(grant, await readBody(request));
      } else if (request.method === 'POST' && url.pathname === '/v1/conversations/remove') {
        result = await sessions.removeConversation(grant, (await readBody(request)).scope);
      } else {
        const match = url.pathname.match(/^\/v1\/sessions\/([0-9a-f]{64})\/(events|turn|tool-result|interrupt|close)$/);
        requireValue(match, 'endpoint_not_found', 404);
        const session = sessions.get(grant, match[1]);
        if (request.method === 'GET' && match[2] === 'events') {
          result = sessions.events(session, Number(url.searchParams.get('after') ?? 0));
        } else {
          requireValue(request.method === 'POST', 'method_not_allowed', 405);
          if (match[2] === 'turn') result = await sessions.turn(session, await readBody(request));
          else if (match[2] === 'tool-result') result = await sessions.toolResult(session, await readBody(request));
          else if (match[2] === 'interrupt') result = await sessions.interrupt(session);
          else if (match[2] === 'close') { sessions.close(session); result = { closed: true }; }
          else throw new BridgeError('method_not_allowed', 405);
        }
      }
      response.end(JSON.stringify(result));
    } catch (error) {
      response.statusCode = error instanceof BridgeError ? error.status : 503;
      // Do not send raw exception/child stderr/provider response bodies to clients.
      response.end(JSON.stringify({ error: { code: error instanceof BridgeError ? error.code : 'bridge_unavailable' } }));
    }
  });
}
