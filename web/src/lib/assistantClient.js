const API_ROOT = "/api/assistant";

export class AssistantRequestError extends Error {
  constructor(message, { status = 0, code = "ASSISTANT_REQUEST_FAILED" } = {}) {
    super(message);
    this.name = "AssistantRequestError";
    this.status = status;
    this.code = code;
  }
}

async function responseError(response) {
  let payload = null;
  try {
    payload = await response.json();
  } catch {
    // A reverse proxy can return an HTML/plain-text failure. Keep the UI error generic.
  }
  return new AssistantRequestError(
    payload?.error ?? (response.status === 401 ? "登录状态已失效，请重新登录。" : "Codex 助手暂时不可用。"),
    { status: response.status, code: payload?.code },
  );
}

export async function getAssistantStatus({ signal } = {}) {
  const response = await fetch(`${API_ROOT}/status`, {
    headers: { Accept: "application/json" },
    signal,
  });
  if (!response.ok) throw await responseError(response);
  return response.json();
}

export async function streamAssistantTurn({ accessToken, mimoAPIKey, farmID, prompt, sessionID, snapshot, attachments = [], signal, onEvent }) {
  const response = await fetch(`${API_ROOT}/turn`, {
    method: "POST",
    headers: {
      Accept: "application/x-ndjson",
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      "X-MiMo-API-Key": mimoAPIKey,
    },
    body: JSON.stringify({ farmID, prompt, sessionID: sessionID || null, snapshot, attachments }),
    signal,
  });
  if (!response.ok) throw await responseError(response);
  if (!response.body) throw new AssistantRequestError("服务器没有返回可读取的回答流。");

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  const emitLine = (line) => {
    if (!line.trim()) return;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      throw new AssistantRequestError("Codex 助手返回了无法解析的数据流。");
    }
    onEvent?.(event);
    if (event.type === "error") {
      throw new AssistantRequestError(event.message || "Codex 助手未能完成本次回答。", { code: event.code });
    }
  };

  while (true) {
    const { done, value } = await reader.read();
    buffer += decoder.decode(value, { stream: !done });
    let newline = buffer.indexOf("\n");
    while (newline >= 0) {
      emitLine(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      newline = buffer.indexOf("\n");
    }
    if (done) break;
  }
  emitLine(buffer);
}

export async function deleteAssistantSession({ accessToken, farmID, sessionID, signal }) {
  if (!sessionID) return;
  const query = new URLSearchParams({ farm_id: farmID });
  const response = await fetch(`${API_ROOT}/sessions/${encodeURIComponent(sessionID)}?${query}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${accessToken}`, Accept: "application/json" },
    signal,
  });
  if (!response.ok && response.status !== 404) throw await responseError(response);
}
