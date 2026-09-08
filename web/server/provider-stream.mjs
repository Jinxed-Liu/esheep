import http from "node:http";
import { once } from "node:events";

// Codex exec's JSON protocol emits completed agent messages. Tap only public
// output_text SSE events while transparently forwarding the same MiMo response
// to Codex; reasoning, credentials, and tool arguments never enter the UI feed.
export function createPublicTextTap(onText) {
  let buffer = "";
  const messages = new Map();
  const accept = (block) => {
    const data = block.split("\n").filter(line => line.startsWith("data:")).map(line => line.slice(5).trimStart()).join("\n");
    if (!data || data === "[DONE]") return;
    let event;
    try { event = JSON.parse(data); } catch { return; }
    const item = event.item;
    if (event.type === "response.output_item.added" && item?.type === "message" && item.role === "assistant" && item.channel !== "analysis") {
      messages.set(item.id, { text: "", visible: true });
    }
    if (event.type === "response.output_text.delta" && messages.has(event.item_id)) {
      const message = messages.get(event.item_id);
      message.text += typeof event.delta === "string" ? event.delta : "";
      onText({ itemID: event.item_id, text: message.text });
    }
  };
  return (text, done = false) => {
    buffer += text.replace(/\r\n/g, "\n");
    let end;
    while ((end = buffer.indexOf("\n\n")) !== -1) {
      accept(buffer.slice(0, end)); buffer = buffer.slice(end + 2);
    }
    if (done && buffer.trim()) { accept(buffer); buffer = ""; }
  };
}

export async function startProviderStream({ baseURL, apiKey, onText, signal, fetchImpl = fetch }) {
  const upstream = new URL(baseURL.replace(/\/+$/, "") + "/");
  const requests = new Set();
  const server = http.createServer(async (request, response) => {
    const controller = new AbortController();
    requests.add(controller);
    const cancel = () => controller.abort();
    signal?.addEventListener("abort", cancel, { once: true });
    response.once("close", () => { if (!response.writableEnded) cancel(); });
    try {
      if (request.method !== "POST" || request.url?.split("?")[0] !== "/v1/responses" ||
          request.headers.authorization !== `Bearer ${apiKey}`) {
        response.writeHead(403); response.end(); return;
      }
      const chunks = [];
      let bytes = 0;
      for await (const chunk of request) {
        bytes += chunk.length;
        if (bytes > 32 * 1_048_576) { response.writeHead(413); response.end(); return; }
        chunks.push(chunk);
      }
      const headers = { authorization: `Bearer ${apiKey}`, "content-type": "application/json", accept: "text/event-stream" };
      const result = await fetchImpl(new URL("responses", upstream), {
        method: "POST", headers, body: Buffer.concat(chunks), signal: controller.signal,
      });
      response.writeHead(result.status, { "content-type": result.headers.get("content-type") || "application/json", "cache-control": "no-store" });
      response.flushHeaders();
      if (!result.body) { response.end(); return; }
      const reader = result.body.getReader();
      const decoder = new TextDecoder();
      const tap = createPublicTextTap(onText);
      while (true) {
        const { done, value } = await reader.read();
        if (result.ok) tap(decoder.decode(value, { stream: !done }), done);
        if (done) break;
        if (!response.write(value)) await Promise.race([once(response, "drain"), once(response, "close")]);
        if (response.destroyed) { await reader.cancel(); break; }
      }
      response.end();
    } catch {
      if (!response.headersSent) response.writeHead(502, { "content-type": "application/json" });
      response.end('{"error":{"message":"Provider connection interrupted"}}');
    } finally { signal?.removeEventListener("abort", cancel); requests.delete(controller); }
  });
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
  return {
    baseURL: `http://127.0.0.1:${server.address().port}/v1`,
    async close() {
      for (const controller of requests) controller.abort();
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    },
  };
}
