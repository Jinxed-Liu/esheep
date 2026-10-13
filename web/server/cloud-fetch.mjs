import * as zlib from "node:zlib";

// Node fetch decodes supported HTTP content encodings but retains wire headers.
// Normalize those headers before node-adapter streams decoded bytes to a browser.
// Cloudflare has different response encoding semantics; keep this Node-only.
export function createNodeCloudFetch(fetchImpl = globalThis.fetch) {
  const supported = new Set(["gzip", "x-gzip", "deflate", "br"]);
  if (typeof zlib.createZstdDecompress === "function") supported.add("zstd");
  return async (input, init) => {
    const response = await fetchImpl(input, init);
    const encoding = response.headers.get("content-encoding");
    if (!response.body || !encoding || !encoding.toLowerCase().split(",").every((value) => supported.has(value.trim()))) return response;
    const headers = new Headers(response.headers);
    headers.delete("content-encoding");
    headers.delete("content-length");
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
  };
}

export const nodeCloudFetch = createNodeCloudFetch();
