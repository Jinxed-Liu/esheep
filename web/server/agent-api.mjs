import { verifyFarmAccess, AssistantAuthorizationError } from "./auth.mjs";
import { validateOpenAIKey, OpenAIRequestError, openAIPayload } from "./openai-api.mjs";
import { loadAgentCloudSnapshot } from "./agent-cloud.mjs";
import { AGENT_CONSENT_VERSION, AGENT_MODELS, runFarmAgent } from "./agent-runtime.mjs";

import { AGENT_MODEL_OPTIONS } from "./agent-contract.mjs";

const json = (body, status = 200) => Response.json(body, { status, headers: { "cache-control": "no-store" } });
async function readJSON(request) {
  if (!request.body) throw new OpenAIRequestError("请求为空。");
  const reader = request.body.getReader(); const chunks = []; let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read(); if (done) break;
      size += value.length; if (size > 18 * 1024 * 1024) throw new OpenAIRequestError("请求超过 18 MB，请减少附件。", 413);
      chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => {}); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const c of chunks) { bytes.set(c, offset); offset += c.length; }
  try { return JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new OpenAIRequestError("请求 JSON 无效。"); }
}

export function validateAgentBody(body) {
  if (!body || !["openai", "mimo"].includes(body.provider)) throw new OpenAIRequestError("请选择 MiMo 或 OpenAI。");
  // Explicitly accept MiMo's text reasoning envelope, never arbitrary inputs
  // or hosted/network tools. OpenAI encrypted state remains provider-specific.
  if (!Array.isArray(body.input) || body.input.some(item => !item || typeof item !== "object")) throw new OpenAIRequestError("对话上下文格式无效。");
  const model = body.model === undefined ? AGENT_MODELS[body.provider] : body.model;
  if (!AGENT_MODEL_OPTIONS[body.provider].includes(model)) throw new OpenAIRequestError("此服务不支持所选模型，请在助手设置中重新选择。");
  const input = body.input.map(item => {
    if (item.type === "reasoning" && body.provider === "mimo") return { role: "assistant", content: "[模型工具调用上下文]" };
    return item;
  });
  const tools = body.clientTools ?? [];
  if (!Array.isArray(tools) || tools.some(t => !t || !/^(draft_[a-z_]+|get_farm_action_schema|create_farm_export|prepare_record)$/.test(t.name ?? ""))) throw new OpenAIRequestError("客户端只能提供草稿、导出和操作结构工具。");
  const payload = openAIPayload({ input, tools, instructions: body.instructions ?? "" });
  if (body.provider === "mimo") {
    for (const [index, item] of body.input.entries()) if (item.type === "reasoning") {
      if (typeof item.id !== "string" || !Array.isArray(item.content) || item.content.some(p => p.type !== "reasoning_text" || typeof p.text !== "string") || JSON.stringify(item).length > 100000) throw new OpenAIRequestError("MiMo 推理上下文格式无效。");
      payload.input[index] = { type: "reasoning", id: item.id, content: item.content, status: "completed" };
    }
  }
  const roundLimit = Math.min(8, Math.max(1, Math.floor(Number(body.limits?.modelRequests) || 8)));
  const outputLimit = Math.min(24000, Math.max(128, Math.floor(Number(body.limits?.outputTokens) || 24000)));
  const requestedTools = Number(body.limits?.toolCalls ?? 24);
  const toolLimit = Number.isFinite(requestedTools) ? Math.min(24, Math.max(0, Math.floor(requestedTools))) : 24;
  return { provider: body.provider, model, input: payload.input, clientTools: payload.tools, instructions: payload.instructions, roundLimit, outputLimit, toolLimit,
    additionalReviews: Math.min(2, Math.max(0, Math.floor(Number(body.limits?.additionalReviews) || 0))), thinkingEnabled: body.thinkingEnabled !== false };
}

export function createAgentAPI({ environment = {}, authVerifier = verifyFarmAccess, snapshotLoader = loadAgentCloudSnapshot, modelTurn, reviewAnswer } = {}) {
  return async (request, runtimeEnv = environment) => {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/api/assistant/agent/")) return null;
    try {
      const config = { supabaseURL: runtimeEnv.SUPABASE_URL || runtimeEnv.VITE_SUPABASE_URL,
        supabasePublishableKey: runtimeEnv.SUPABASE_PUBLISHABLE_KEY || runtimeEnv.VITE_SUPABASE_PUBLISHABLE_KEY };
      if (!config.supabaseURL || !config.supabasePublishableKey) return json({ error: "牧场助手服务尚未配置。" }, 503);
      const farmID = url.searchParams.get("farm_id") ?? "";
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(farmID)) throw new OpenAIRequestError("牧场标识无效。");
      const authorization = await authVerifier({ request, farmID, config });
      if (request.method === "GET" && url.pathname.endsWith("/status")) return json({ configured: true, execution: "farm-agent-responses", models: AGENT_MODELS, modelOptions: AGENT_MODEL_OPTIONS, consentVersion: AGENT_CONSENT_VERSION, capabilities: ["supabase_authorized_read", "questions", "image", "client_drafts"] });
      if (request.method !== "POST" || !url.pathname.endsWith("/turn")) return json({ error: "未找到接口。" }, 404);
      if (request.headers.get("x-agent-consent") !== AGENT_CONSENT_VERSION) return json({ error: "请先同意牧场 Agent 数据处理说明。" }, 403);
      const body = validateAgentBody(await readJSON(request));
      const key = String(request.headers.get("x-assistant-api-key") ?? "").trim();
      if (body.provider === "openai") validateOpenAIKey(key);
      else if (!/^(sk-|tp-)[A-Za-z0-9_-]{9,508}$/.test(key)) throw new OpenAIRequestError("请输入自己的 MiMo API Key。");
      const abort = new AbortController();
      const signal = AbortSignal.any([request.signal, abort.signal, AbortSignal.timeout(240_000)]);
      const encoder = new TextEncoder();
      let cancelled = false;
      const stream = new ReadableStream({
        async start(controller) {
          let closed = false;
          const emit = event => { if (!closed && !signal.aborted) controller.enqueue(encoder.encode(JSON.stringify(event) + "\n")); };
          const heartbeat = setInterval(() => emit({ type: "heartbeat" }), 15000);
          try {
            const result = await runFarmAgent({ ...body, apiKey: key, signal, emit, ...(modelTurn ? { modelTurn } : {}), ...(reviewAnswer ? { reviewAnswer } : {}),
              loadSnapshot: () => snapshotLoader({ request, authorization, config, signal, onProgress: message => emit({ type: "status", message }) }) });
            signal.throwIfAborted();
            emit({ type: "result", ...result, model: body.model });
          } catch (error) {
            emit({ type: "error", code: error.code ?? "AGENT_TURN_FAILED", recovery: error.recovery ?? "retry", message: error instanceof Error ? error.message : "牧场助手未完成本次任务。" });
          } finally { clearInterval(heartbeat); closed = true; if (!cancelled) controller.close(); }
        },
        cancel() { cancelled = true; abort.abort(); },
      });
      return new Response(stream, { headers: { "content-type": "application/x-ndjson; charset=utf-8", "cache-control": "no-store, no-transform", "x-accel-buffering": "no" } });
    } catch (error) {
      const known = error instanceof AssistantAuthorizationError || error instanceof OpenAIRequestError;
      return json({ error: known ? error.message : "牧场助手连接失败，请稍后重试。" }, known ? error.status : 502);
    }
  };
}
