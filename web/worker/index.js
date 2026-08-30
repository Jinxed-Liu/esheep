export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/api/assistant/")) {
      try {
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
        return new Response(JSON.stringify({ error: "Codex harness 代理连接失败。", code: "HARNESS_PROXY_FAILED" }), {
          status: 502,
          headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
        });
      }
      return new Response(JSON.stringify({ error: "Codex harness 尚未绑定到网页运行环境。", code: "HARNESS_NOT_BOUND" }), {
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
