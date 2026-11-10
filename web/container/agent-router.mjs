import { agentFailure, containerFailure, errorBody } from "../server/agent-errors.mjs";
import { AGENT_CONSENT_VERSION, AGENT_MODELS, AGENT_MODEL_OPTIONS } from "../server/agent-contract.mjs";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const json = (body, status = 200) => Response.json(body, { status, headers: { "cache-control": "no-store" } });

export async function hasAgentCheckpoint({ request, farmID, membership, env, fetchImpl = fetch }) {
  // V2 readiness alone does not guarantee the verified business checkpoint
  // required by this reader. Keep this small metadata read under the caller JWT.
  const response = await fetchImpl(new URL("/rest/v1/rpc/esheep_cloud_checkpoint_manifest_v1", env.SUPABASE_URL), {
    method: "POST", redirect: "manual", signal: AbortSignal.any([request.signal, AbortSignal.timeout(10_000)]),
    headers: { "content-type": "application/json", apikey: env.SUPABASE_PUBLISHABLE_KEY, authorization: request.headers.get("authorization") },
    body: JSON.stringify({ p_farm_id: farmID, p_farm_generation: membership.authority_generation, p_checkpoint_id: null }),
  });
  if (!response.ok) throw Object.assign(new Error("Checkpoint availability lookup failed"), { status: response.status });
  const { manifest } = await response.json();
  return Boolean(manifest && uuid.test(manifest.checkpointID) &&
    String(manifest.farmID).toLowerCase() === farmID.toLowerCase() &&
    manifest.farmGeneration === membership.authority_generation &&
    Number.isSafeInteger(manifest.boundaryEventSequence) && manifest.boundaryEventSequence >= 0);
}

// Keep large checkpoint decoding, projection and model loops in Node. The edge
// authenticates before a billable container start and streams the body unchanged.
export function createAgentRouter({ verifyAccess, verifyCheckpoint = hasAgentCheckpoint }) {
  return async (request, env) => {
    try {
      const url = new URL(request.url);
      const status = request.method === "GET" && url.pathname === "/api/assistant/agent/status";
      const turn = request.method === "POST" && url.pathname === "/api/assistant/agent/turn";
      if (!status && !turn) return json({ error: "未找到助手接口。" }, 404);
      if (!/^Bearer\s+\S+$/i.test(request.headers.get("authorization") || "")) return json(errorBody(agentFailure("AGENT_AUTH_REQUIRED", 401, "请重新登录。", "login")), 401);
      const farmID = url.searchParams.get("farm_id") || "";
      if (!uuid.test(farmID)) return json({ error: "牧场标识无效。" }, 400);
      if (!env.SUPABASE_URL || !env.SUPABASE_PUBLISHABLE_KEY || !env.HARNESS_CONTAINER) return json({ configured: false, ...errorBody(agentFailure("AGENT_NOT_CONFIGURED", 503, "牧场助手服务尚未配置。", "deployment")) }, 503);
      const { userID, membership } = await verifyAccess({ request, farmID, config: {
        supabaseURL: env.SUPABASE_URL, supabasePublishableKey: env.SUPABASE_PUBLISHABLE_KEY,
      } });
      if (membership?.provider !== "esheep_cloud" || membership.initial_sync_ready !== true) {
        return json({ configured: false, ...errorBody(agentFailure("AGENT_FARM_NOT_READY", 503, "此牧场的 Cloud V2 数据尚未准备完成，请待云端初始化完成后重新检查。", "farm")) }, 503);
      }
      if (env.AGENT_RUNTIME_VERIFIED !== "true") return json({ configured: false, ...errorBody(agentFailure("AGENT_NOT_VERIFIED", 503, "云端 Agent 新版本尚未部署并完成验证。", "deployment")) }, 503);
      if (!await verifyCheckpoint({ request, farmID, membership, env })) {
        return json({ configured: false, ...errorBody(agentFailure("AGENT_FARM_NOT_READY", 503, "此牧场尚无可供助手读取的已验证资料，请联系管理员完成云端检查点后重新检查。", "farm")) }, 503);
      }
      if (status) return json({ configured: true, availability: "ready", credentialStatus: "checked_on_request", execution: "farm-agent-responses", models: AGENT_MODELS, modelOptions: AGENT_MODEL_OPTIONS,
        consentVersion: AGENT_CONSENT_VERSION, capabilities: ["supabase_authorized_read", "questions", "image", "client_drafts"] });
      if (request.headers.get("x-agent-consent") !== AGENT_CONSENT_VERSION) return json({ error: "请先同意牧场 Agent 数据处理说明。" }, 403);
      if (!/^(sk-|tp-)[A-Za-z0-9_-]{9,508}$/.test(request.headers.get("x-assistant-api-key") || "")) return json({ error: "请输入所选服务的个人 API Key。" }, 400);
      if (Number(request.headers.get("content-length")) > 18 * 1024 * 1024) return json({ error: "请求超过 18 MB，请减少附件。" }, 413);
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${userID}\n${farmID.toLowerCase()}`));
      const scope = [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, "0")).join("");
      const response = await env.HARNESS_CONTAINER.getByName(`farm-agent-${scope}`).fetch(request);
      if (response.status === 429 || response.status >= 500) {
        const failure = containerFailure({ status: response.status, message: (await response.text()).slice(0, 2048) });
        return json(errorBody(failure), failure.status);
      }
      return response;
    } catch (error) {
      const failure = containerFailure(error);
      return json(errorBody(failure), failure.status);
    }
  };
}
