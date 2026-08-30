import { FarmAssistantHarness, HarnessExecutionError } from "./harness.mjs";
import { AssistantAuthorizationError, verifyFarmAccess } from "./auth.mjs";
import { HarnessConfigurationError, MiMoAPIKeyError, inspectHarnessEnvironment, loadHarnessConfig, validateMiMoAPIKey } from "./config.mjs";

function jsonResponse(payload, status = 200, headers = {}) {
  return new Response(`${JSON.stringify(payload)}\n`, {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers },
  });
}

function publicError(error) {
  if (error instanceof AssistantAuthorizationError || error instanceof HarnessConfigurationError || error instanceof MiMoAPIKeyError || error instanceof HarnessExecutionError) {
    return { status: error.status ?? 500, code: error.code ?? "ASSISTANT_ERROR", message: error.message };
  }
  return { status: 500, code: "ASSISTANT_ERROR", message: "Codex 助手暂时不可用。" };
}

async function readJSONBody(request, maximumBytes) {
  const declaredLength = Number.parseInt(request.headers.get("content-length") ?? "0", 10);
  if (declaredLength > maximumBytes) throw new HarnessExecutionError("请求内容过大。", 413, "REQUEST_TOO_LARGE");
  if (!request.body) throw new HarnessExecutionError("请求内容为空。", 400, "EMPTY_REQUEST_BODY");
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel();
      throw new HarnessExecutionError("请求内容过大。", 413, "REQUEST_TOO_LARGE");
    }
    chunks.push(value);
  }
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder().decode(merged));
  } catch {
    throw new HarnessExecutionError("请求 JSON 格式无效。", 400, "INVALID_JSON");
  }
}

export function createAssistantAPI({
  environment = process.env,
  authVerifier = verifyFarmAccess,
  harness = null,
  codexFactory,
} = {}) {
  const inspection = inspectHarnessEnvironment(environment);
  let config = null;
  let activeHarness = harness;
  if (inspection.configured) {
    config = loadHarnessConfig(environment);
    activeHarness ??= new FarmAssistantHarness({ config, codexFactory, environment });
  }

  return async function assistantAPI(request) {
    const url = new URL(request.url);
    const pathname = url.pathname;
    if (request.method === "GET" && pathname === "/api/assistant/status") {
      return jsonResponse({
        ...inspection,
        execution: "codex-harness",
        capabilities: ["thread_resume", "farm_query_tools", "image_input", "user_api_key"],
      });
    }
    if (!pathname.startsWith("/api/assistant/")) return null;
    if (!inspection.configured || !config || !activeHarness) {
      const error = new HarnessConfigurationError("Codex harness 尚未完成服务端配置。", inspection.missing);
      return jsonResponse({ error: error.message, code: error.code, missing: error.missing }, error.status);
    }

    try {
      if (request.method === "POST" && pathname === "/api/assistant/turn") {
        const body = await readJSONBody(request, config.maximumBodyBytes);
        const farmID = String(body?.farmID ?? "").trim();
        const prompt = String(body?.prompt ?? "").trim();
        const attachments = Array.isArray(body?.attachments) ? body.attachments : [];
        if (!prompt && !attachments.length) throw new HarnessExecutionError("请输入问题或添加图片。", 400, "EMPTY_PROMPT");
        if (prompt.length > config.maximumPromptCharacters) {
          throw new HarnessExecutionError(`问题不能超过 ${config.maximumPromptCharacters} 个字符。`, 400, "PROMPT_TOO_LONG");
        }
        if (body?.snapshot?.schemaVersion !== "esheepnext-farm-assistant/v1" || String(body.snapshot?.farm?.id ?? "") !== farmID) {
          throw new HarnessExecutionError("牧场快照与当前牧场不一致。", 400, "SNAPSHOT_SCOPE_MISMATCH");
        }
        const authorization = await authVerifier({ request, farmID, config });
        const mimoAPIKey = validateMiMoAPIKey(request.headers.get("x-mimo-api-key"));
        const iterator = activeHarness.runTurn({
          sessionID: body.sessionID,
          userID: authorization.userID,
          farmID,
          prompt,
          snapshot: body.snapshot,
          attachments,
          mimoAPIKey,
          signal: request.signal,
        })[Symbol.asyncIterator]();
        const first = await iterator.next();
        const encoder = new TextEncoder();
        const stream = new ReadableStream({
          async start(controller) {
            const send = (event) => controller.enqueue(encoder.encode(`${JSON.stringify(event)}\n`));
            try {
              if (!first.done) send(first.value);
              while (true) {
                const next = await iterator.next();
                if (next.done) break;
                send(next.value);
              }
            } catch (error) {
              const safe = publicError(error);
              send({ type: "error", code: safe.code, message: safe.message });
            } finally {
              controller.close();
            }
          },
          async cancel() {
            await iterator.return?.();
          },
        });
        return new Response(stream, {
          status: 200,
          headers: {
            "Content-Type": "application/x-ndjson; charset=utf-8",
            "Cache-Control": "no-store, no-transform",
            "X-Accel-Buffering": "no",
          },
        });
      }

      const sessionMatch = /^\/api\/assistant\/sessions\/([^/]+)$/.exec(pathname);
      if (request.method === "DELETE" && sessionMatch) {
        const farmID = String(url.searchParams.get("farm_id") ?? "").trim();
        const authorization = await authVerifier({ request, farmID, config });
        const deleted = await activeHarness.deleteSession({
          sessionID: decodeURIComponent(sessionMatch[1]),
          userID: authorization.userID,
          farmID,
        });
        return jsonResponse({ deleted }, deleted ? 200 : 404);
      }
      return jsonResponse({ error: "未找到助手接口。", code: "NOT_FOUND" }, 404);
    } catch (error) {
      const safe = publicError(error);
      return jsonResponse({ error: safe.message, code: safe.code }, safe.status);
    }
  };
}
