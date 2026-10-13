import assert from "node:assert/strict";
import { createServer } from "node:http";
import { gzipSync, deflateSync, brotliCompressSync } from "node:zlib";
import test from "node:test";
import { createNodeCloudFetch } from "../server/cloud-fetch.mjs";
import { handleNodeRequest } from "../server/node-adapter.mjs";
import { proxyCloudRequest } from "../worker/cloud-proxy.js";

test("Node cloud proxy forwards decoded gzip, deflate, and Brotli responses with truthful headers", async () => {
  const fixture = JSON.stringify({ access_token: "fixture-access", note: "牧场🌿" });
  const encoders = { gzip: gzipSync, deflate: deflateSync, br: brotliCompressSync };
  const upstream = createServer((input, output) => {
    const coding = new URL(input.url, "http://fixture").searchParams.get("coding");
    const bytes = encoders[coding](fixture);
    output.writeHead(200, { "content-type": "application/json", "content-encoding": coding, "content-length": bytes.byteLength });
    output.end(bytes);
  });
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  const fetchUpstream = createNodeCloudFetch((input) => {
    const target = `http://127.0.0.1:${upstream.address().port}/${new URL(input.url).search}`;
    return fetch(new Request(target, input));
  });
  const proxy = createServer((input, output) => {
    void handleNodeRequest(input, output, (request) => proxyCloudRequest(request, { SUPABASE_URL: "https://fixture.supabase.co" }, { fetchImpl: fetchUpstream }));
  });
  await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));
  try {
    for (const coding of Object.keys(encoders)) {
      const response = await fetch(`http://127.0.0.1:${proxy.address().port}/api/cloud/auth/v1/token?coding=${coding}`, {
        method: "POST", body: "fixture credentials", headers: { "x-esheep-cloud-host": "fixture.supabase.co" },
      });
      assert.equal(response.status, 200);
      assert.equal(response.headers.get("content-encoding"), null);
      assert.equal(response.headers.get("content-length"), null);
      assert.equal(response.headers.get("cache-control"), "no-store");
      assert.equal(await response.text(), fixture);
    }
  } finally {
    proxy.closeAllConnections();
    upstream.closeAllConnections();
    await Promise.all([new Promise((resolve) => proxy.close(resolve)), new Promise((resolve) => upstream.close(resolve))]);
  }
});

test("Node encoding normalization preserves gzip file bytes and HEAD metadata", async () => {
  const bytes = gzipSync("fixture checkpoint bytes");
  const server = createServer((input, output) => {
    output.writeHead(200, {
      "content-type": "application/gzip", "content-length": bytes.byteLength,
      ...(input.method === "HEAD" ? { "content-encoding": "gzip" } : {}),
    });
    output.end(input.method === "HEAD" ? undefined : bytes);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const fetchUpstream = createNodeCloudFetch();
  const url = `http://127.0.0.1:${server.address().port}/fixture`;
  try {
    const file = await fetchUpstream(url);
    assert.equal(file.headers.get("content-encoding"), null);
    assert.equal(file.headers.get("content-length"), String(bytes.byteLength));
    assert.deepEqual(new Uint8Array(await file.arrayBuffer()), new Uint8Array(bytes));
    const head = await fetchUpstream(url, { method: "HEAD" });
    assert.equal(head.body, null);
    assert.equal(head.headers.get("content-encoding"), "gzip");
    assert.equal(head.headers.get("content-length"), String(bytes.byteLength));
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});
