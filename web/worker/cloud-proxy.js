const prefix = "/api/cloud";
const requestHeaders = [
  "accept", "accept-profile", "apikey", "authorization", "content-type",
  "content-profile", "prefer", "range", "range-unit", "x-client-info",
  "x-supabase-api-version", "x-upsert",
];

function failure(status, code, message) {
  return Response.json({ code, error: code, message, msg: message }, {
    status, headers: { "cache-control": "no-store" },
  });
}

export async function proxyCloudRequest(request, environment, { fetchImpl = globalThis.fetch, timeoutMs = 20000 } = {}) {
  const address = new URL(request.url);
  if (!address.pathname.startsWith(`${prefix}/`)) return null;
  // A fixed deployment binding; no caller-controlled target or service key.
  // Supabase continues to authenticate the original user token.
  let upstream;
  try {
    upstream = new URL(environment.SUPABASE_URL ?? environment.VITE_SUPABASE_URL);
    if (upstream.protocol !== "https:" || upstream.username || upstream.password ||
        upstream.pathname !== "/" || upstream.search || upstream.hash) throw new Error("Invalid upstream");
  } catch {
    return failure(503, "CLOUD_PROXY_NOT_CONFIGURED", "云端连接尚未配置，请联系管理员。");
  }
  if (request.headers.get("x-esheep-cloud-host") !== upstream.host) {
    return failure(409, "CLOUD_PROXY_PROJECT_MISMATCH", "网页云端配置已变化，请刷新页面后重试。");
  }
  const origin = request.headers.get("origin");
  if ((origin && origin !== address.origin) || request.headers.get("sec-fetch-site") === "cross-site") {
    return failure(403, "CLOUD_PROXY_ORIGIN_DENIED", "请从本站打开网页后重试。");
  }
  const path = address.pathname.slice(prefix.length);
  if (!/^\/(auth|rest|storage|functions)\/v1(?:\/|$)/.test(path) ||
      !["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].includes(request.method)) {
    return failure(404, "CLOUD_PROXY_PATH_DENIED", "云端接口不存在。");
  }
  const target = new URL(upstream);
  target.pathname = path;
  target.search = address.search;
  const headers = new Headers();
  for (const name of requestHeaders) {
    const value = request.headers.get(name);
    if (value !== null) headers.set(name, value);
  }
  const controller = new AbortController();
  const onAbort = () => controller.abort(request.signal.reason);
  if (request.signal.aborted) onAbort();
  else request.signal.addEventListener("abort", onAbort, { once: true });
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const body = ["GET", "HEAD"].includes(request.method) ? undefined : request.body;
    const upstreamRequest = new Request(target, {
      method: request.method, headers, body,
      ...(body ? { duplex: "half" } : {}),
      redirect: "manual", signal: controller.signal, cache: "no-store",
    });
    const response = await fetchImpl(upstreamRequest);
    // Never follow an upstream redirect with credentials or switch the browser
    // back to a direct cloud connection.
    if (response.status >= 300 && response.status < 400) {
      await response.body?.cancel();
      return failure(502, "CLOUD_PROXY_REDIRECT_DENIED", "云端连接地址异常，请联系管理员。");
    }
    const responseHeaders = new Headers(response.headers);
    responseHeaders.set("cache-control", "no-store");
    responseHeaders.set("x-esheep-cloud-transport", "same-origin");
    responseHeaders.delete("set-cookie");
    for (const name of [...responseHeaders.keys()]) {
      if (name.startsWith("access-control-")) responseHeaders.delete(name);
    }
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers: responseHeaders });
  } catch {
    return controller.signal.aborted
      ? failure(504, "CLOUD_PROXY_TIMEOUT", "云端连接超时，请稍后重试。")
      : failure(502, "CLOUD_PROXY_FAILED", "暂时无法连接云端服务，请稍后重试。");
  } finally {
    clearTimeout(timer);
    request.signal.removeEventListener("abort", onAbort);
  }
}
