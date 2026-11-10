function requestError(value, fallback) {
  return Object.assign(new Error(typeof value?.error === "string" ? value.error : fallback), { code: value?.code, recovery: value?.recovery });
}
// Both providers use the shared server Agent and authoritative Supabase tools.
export const OPENAI_CONSENT_VERSION = "2026-11-05-agent-v1";
export async function getOpenAIStatus({ accessToken, farmID, provider = "openai", signal }) {
  const response = await fetch(`/api/assistant/agent/status?farm_id=${encodeURIComponent(farmID)}`, {
    headers: { authorization: `Bearer ${accessToken}` }, signal,
  });
  if (!response.ok) { let value; try { value = await response.json(); } catch {} throw requestError(value, "云端 Agent 暂时无法连接，请检查登录和网络。"); }
  const status = await response.json();
  return { ...status, model: status.models?.[provider] };
}

export async function streamOpenAITurn({ accessToken, apiKey, farmID, provider = "openai", prompt, history = [], attachments = [], clientTools = [], executeClientTool, signal, onEvent, fetchImpl = fetch }) {
  let modelRequests = 0, outputTokens = 0, toolCalls = 0;
  let input = history.filter(m => ["user", "assistant"].includes(m.role) && !m.error && !m.pending && m.text).slice(-30)
    .map(m => ({ role: m.role, content: m.text }));
  input.push({ role: "user", content: [{ type: "input_text", text: prompt || "请识别所附图片，并标明不确定内容。" },
    ...attachments.map(image => ({ type: "input_image", image_url: image.dataURL }))] });
  for (let step = 0; step < 6; step++) {
    if (modelRequests >= 8 || outputTokens > 24000 - 128) throw new Error("本轮已达到分析用量上限，已停止。已有草稿保留，请核对后继续。");
    const response = await fetchImpl(`/api/assistant/agent/turn?farm_id=${encodeURIComponent(farmID)}`, {
      method: "POST", signal,
      headers: { "content-type": "application/json", authorization: `Bearer ${accessToken}`, "x-assistant-api-key": apiKey, "x-agent-consent": OPENAI_CONSENT_VERSION },
      body: JSON.stringify({ provider, input, clientTools, limits: { modelRequests: 8 - modelRequests, outputTokens: 24000 - outputTokens, toolCalls: Math.max(0, 24 - toolCalls) } }),
    });
    if (!response.ok) { let value; try { value = await response.json(); } catch {} throw requestError(value, "云端 Agent 请求失败。"); }
    if (!response.body) throw new Error("服务器未返回回答流。");
    const reader = response.body.getReader(); const decoder = new TextDecoder(); let buffer = "", result; let size = 0;
    const consume = line => {
      if (!line.trim()) return;
      const event = JSON.parse(line);
      if (event.type === "usage") { modelRequests++; outputTokens += event.outputTokens ?? 0; }
      if (event.type === "evidence") toolCalls++;
      if (event.type === "error") throw requestError({ ...event, error: event.message }, "本轮未完成。");
      if (event.type === "result") result = event;
      else onEvent?.(event);
    };
    try {
      while (true) {
        const { value, done } = await reader.read(); buffer += decoder.decode(value, { stream: !done }); size += value?.length ?? 0;
        if (size > 18 * 1024 * 1024) throw new Error("回答超过接收上限。");
        let index; while ((index = buffer.indexOf("\n")) >= 0) { consume(buffer.slice(0, index)); buffer = buffer.slice(index + 1); }
        if (done) break;
      }
      consume(buffer);
    } finally { await reader.cancel().catch(() => {}); }
    if (!result) throw new Error("回答连接中断，本轮未完成。");
    if (!result.clientCalls?.length) {
      onEvent?.({ type: "assistant", itemID: crypto.randomUUID(), text: result.text, questions: result.questions, needsUserInput: result.needsUserInput });
      onEvent?.({ type: "done", model: result.model, needsUserInput: result.needsUserInput });
      return;
    }
    if (!Array.isArray(result.continuation) || !executeClientTool) throw new Error("当前客户端不能执行此工具。");
    input = result.continuation;
    for (const call of result.clientCalls) {
      if (signal?.aborted) throw new DOMException("已停止", "AbortError");
      if (toolCalls >= 24) throw new Error("本轮已达到工具调用上限，已停止。已有草稿保留。");
      toolCalls++;
      let output;
      try {
        if (!clientTools.some(tool => tool.name === call.name)) throw new Error("工具未授权。");
        output = await executeClientTool(call.name, JSON.parse(call.arguments));
      } catch (error) { output = { ok: false, error: error.message }; }
      input.push({ type: "function_call_output", call_id: call.call_id, output: JSON.stringify(output) });
    }
  }
  throw new Error("本轮已达到工具调用上限，已停止。请核对草稿后继续。");
}
