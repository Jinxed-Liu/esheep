const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_BYTES = 24 * 1_048_576;

function json(body, status = 200) {
  return Response.json(body, { status, headers: { "cache-control": "no-store" } });
}

async function boundedJSON(request) {
  if (Number(request.headers.get("content-length")) > MAX_BYTES) throw { status: 413, code: "REQUEST_TOO_LARGE" };
  if (!request.body) throw { status: 400, code: "EMPTY_REQUEST_BODY" };
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BYTES) { await reader.cancel(); throw { status: 413, code: "REQUEST_TOO_LARGE" }; }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  try { return JSON.parse(new TextDecoder().decode(bytes)); }
  catch { throw { status: 400, code: "INVALID_JSON" }; }
}

export function createContainerRouter({ verifyAccess, validateKey }) {
  return async (request, env) => {
    try {
      const url = new URL(request.url);
      if (request.method === "POST" && url.pathname === "/api/assistant/runtime-check" &&
          env.HARNESS_DIAGNOSTICS_TOKEN && request.headers.get("x-harness-diagnostics-token") === env.HARNESS_DIAGNOSTICS_TOKEN) {
        return json(await env.HARNESS_CONTAINER.getByName("runtime-verification-v1").runtimeCheck());
      }
      if (request.method === "GET" && url.pathname === "/api/assistant/status") {
        return json({ configured: Boolean(env.SUPABASE_URL && env.SUPABASE_PUBLISHABLE_KEY && env.HARNESS_RUNTIME_VERIFIED === "true"),
          execution: "codex-harness", provider: "mimo", model: "mimo-v2.6-pro",
          requiresUserAPIKey: true, capabilities: ["thread_resume", "farm_query_tools", "image_input", "user_api_key"],
          sessionStorage: "ephemeral", idleMinutes: 10 });
      }
      if (env.HARNESS_RUNTIME_VERIFIED !== "true") return json({ error: "助手运行环境正在验证，请稍后使用。", code: "HARNESS_NOT_READY" }, 503);
      // Reject unauthenticated traffic before paying for a container start.
      if (!/^Bearer\s+\S+$/i.test(request.headers.get("authorization") || "")) return json({ error: "请重新登录。", code: "MISSING_BEARER_TOKEN" }, 401);
      const isTurn = request.method === "POST" && url.pathname === "/api/assistant/turn";
      const deletion = request.method === "DELETE" && /^\/api\/assistant\/sessions\/([^/]+)$/.exec(url.pathname);
      if (!isTurn && !deletion) return json({ code: "NOT_FOUND" }, 404);
      const body = isTurn ? await boundedJSON(request) : null;
      const farmID = String(isTurn ? body?.farmID || "" : url.searchParams.get("farm_id") || "").trim();
      const newSession = isTurn && !body?.sessionID;
      const sessionID = String(newSession ? crypto.randomUUID() : isTurn ? body?.sessionID : deletion[1]).toLowerCase();
      if (!UUID.test(sessionID) || !UUID.test(farmID)) return json({ error: "会话或牧场标识无效。", code: "INVALID_SCOPE" }, 400);
      if (isTurn) {
        validateKey(request.headers.get("x-mimo-api-key"));
        if (body?.snapshot?.schemaVersion !== "esheepnext-farm-assistant/v1" || body.snapshot?.farm?.id !== farmID) return json({ error: "牧场快照不一致。", code: "SNAPSHOT_SCOPE_MISMATCH" }, 400);
      }
      const { userID } = await verifyAccess({ request, farmID, config: {
        supabaseURL: env.SUPABASE_URL, supabasePublishableKey: env.SUPABASE_PUBLISHABLE_KEY,
      } });
      // A separate VM per verified account + farm + session. Browser identifiers
      // alone never select a shared process or authorize access to another VM.
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${userID}\n${farmID}\n${sessionID}`));
      const name = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
      const headers = new Headers(request.headers);
      headers.delete("content-length");
      headers.set("x-esheep-session-create", newSession ? "1" : "0");
      const forwarded = new Request(request.url, {
        method: request.method, headers, body: isTurn ? JSON.stringify({ ...body, sessionID }) : undefined,
        signal: request.signal,
      });
      return await env.HARNESS_CONTAINER.getByName(name).fetch(forwarded);
    } catch (error) {
      const known = [400, 401, 403, 413, 502, 503].includes(error?.status);
      return json({ error: known && error.message ? error.message : "助手容器暂时无法连接，请稍后重试。",
        code: known ? error.code || "HARNESS_ERROR" : "HARNESS_CONTAINER_UNAVAILABLE" }, known ? error.status : 503);
    }
  };
}
