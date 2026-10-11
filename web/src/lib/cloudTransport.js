export const CLOUD_PROXY_PREFIX = "/api/cloud";

async function uploadBlob(request) {
  request.signal.throwIfAborted();
  if (request.body === null) return undefined;
  const reader = request.body.getReader();
  const cancel = () => { void reader.cancel(request.signal.reason).catch(() => {}); };
  request.signal.addEventListener("abort", cancel, { once: true });
  try {
    const chunks = [];
    while (true) {
      request.signal.throwIfAborted();
      const { done, value } = await reader.read();
      request.signal.throwIfAborted();
      if (done) break;
      chunks.push(value);
    }
    return new Blob(chunks, { type: request.headers.get("content-type") ?? "" });
  } finally {
    request.signal.removeEventListener("abort", cancel);
    reader.releaseLock();
  }
}

// Keep the canonical URL in the SDK so session keys and OAuth stay compatible.
export function createCloudFetch({ supabaseURL, siteOrigin, fetchImpl = globalThis.fetch }) {
  const upstream = new URL(supabaseURL);
  const site = new URL(siteOrigin);
  return async (input, init) => {
    const request = new Request(input, init);
    const address = new URL(request.url);
    if (address.origin !== upstream.origin || !/^\/(auth|rest|storage|functions)\/v1(?:\/|$)/.test(address.pathname)) {
      return fetchImpl(request);
    }
    const target = new URL(`${CLOUD_PROXY_PREFIX}${address.pathname}${address.search}`, site);
    const headers = new Headers(request.headers);
    headers.set("x-esheep-cloud-host", upstream.host);
    try {
      // Passing a Request as RequestInit exposes its body as a ReadableStream.
      // Safari rejects those uploads. A Blob preserves the encoded bytes and
      // multipart boundary while supporting URL and Request inputs alike.
      const body = await uploadBlob(request);
      const proxied = new Request(target, {
        method: request.method, headers, body, signal: request.signal,
        credentials: "omit", cache: "no-store", redirect: request.redirect,
        mode: request.mode, referrer: request.referrer,
        referrerPolicy: request.referrerPolicy, integrity: request.integrity,
      });
      return await fetchImpl(proxied);
    } catch (error) {
      if (request.signal.aborted || error?.name === "AbortError") throw error;
      const failure = new Error("无法连接云端服务，请检查网络后重试。", { cause: error });
      failure.code = "CLOUD_NETWORK_FAILED";
      throw failure;
    }
  };
}

export function cloudConnectionErrorMessage(error) {
  if (error?.code === "CLOUD_NETWORK_FAILED" || /^(?:TypeError:\s*)?(?:Load failed|Failed to fetch|NetworkError(?: when attempting to fetch resource)?\.?)$/i.test(String(error?.message ?? "").trim())) {
    return "无法连接云端服务，请检查网络后重试。";
  }
  return error?.message;
}
