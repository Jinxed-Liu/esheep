import { activeBackend, isCloudRoute } from "./backend-status.js";
import { proxyCloudRequest } from "./cloud-proxy.js";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.hostname === "app.esheepplus.com" && env.ASSETS && !env.BACKEND_STATUS && url.pathname.startsWith("/api/")) {
      return Response.json({ error: "暂时无法确认云端状态。" }, { status: 503, headers: { "cache-control": "no-store" } });
    }
    if (isCloudRoute(url.pathname)) return proxyCloudRequest(request, env);
    if (url.pathname.startsWith("/api/assistant/") || url.pathname.startsWith("/api/weather/")) {
      try {
        const state = await activeBackend(env);
        if (state === "mini" && env.MINI_CODEX_HARNESS?.fetch) return env.MINI_CODEX_HARNESS.fetch(request);
        if (state !== "hosted") return Response.json({ error: "牧场服务维护中。", code: "BACKEND_UNAVAILABLE" },
          { status: 503, headers: { "cache-control": "no-store" } });
        if (env.CODEX_HARNESS?.fetch) return env.CODEX_HARNESS.fetch(request);
        if (env.CODEX_HARNESS_URL) {
          const base = new URL(env.CODEX_HARNESS_URL);
          if (base.protocol !== "https:" && !["localhost", "127.0.0.1"].includes(base.hostname)) {
            throw new Error("Insecure harness URL");
          }
          const target = new URL(`${url.pathname}${url.search}`, base);
          return fetch(new Request(target, request));
        }
      } catch {
        return new Response(JSON.stringify({ error: "服务端连接失败。", code: "SERVICE_PROXY_FAILED" }), {
          status: 502,
          headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
        });
      }
      return new Response(JSON.stringify({ error: "服务端尚未绑定到网页运行环境。", code: "HARNESS_NOT_BOUND" }), {
        status: 503,
        headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
      });
    }

    const response = await env.ASSETS.fetch(request);
    const acceptsHtml = request.headers.get("accept")?.includes("text/html");

    if (response.status !== 404 || !acceptsHtml || !["GET", "HEAD"].includes(request.method)) {
      return response;
    }

    const indexUrl = new URL(request.url);
    indexUrl.pathname = "/index.html";
    indexUrl.search = "";
    return env.ASSETS.fetch(new Request(indexUrl, request));
  },
};
