import { activeBackend, miniOrigin } from "./backend-status.js";

const methods = new Map([
  ["/api/assistant/agent/status", "GET"],
  ["/api/assistant/agent/turn", "POST"],
]);

// The agent has a more specific Cloudflare route than the main website.
export async function forwardAgent(request, env, fetchImpl = fetch) {
  const source = new URL(request.url);
  if (source.origin !== "https://app.esheepplus.com" || methods.get(source.pathname) !== request.method) {
    return new Response(null, { status: 404 });
  }
  const state = env.BACKEND_STATUS ? await activeBackend(env) : null;
  if (state !== "hosted" && state !== "mini") {
    return Response.json({ error: "服务维护中。", code: "BACKEND_UNAVAILABLE" },
      { status: 503, headers: { "cache-control": "no-store" } });
  }
  const headers = new Headers();
  for (const name of ["authorization", "content-type", "accept", "x-agent-consent", "x-assistant-api-key"]) {
    if (request.headers.has(name)) headers.set(name, request.headers.get(name));
  }
  const target = new URL(source.pathname + source.search, state === "mini" ? miniOrigin : "https://mini.esheepplus.com");
  const response = await fetchImpl(target, {
    method: request.method, headers, body: request.body, redirect: "manual", signal: request.signal,
  });
  return response.status >= 300 && response.status < 400 ? new Response(null, { status: 502 }) : response;
}

export default { fetch: (request, env) => forwardAgent(request, env) };
