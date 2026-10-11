import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { gzipSync, brotliCompressSync } from "node:zlib";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import test from "node:test";
import { proxyCloudRequest } from "../worker/cloud-proxy.js";

const env = { SUPABASE_URL: "https://fixture.supabase.co" };
const request = (signal) => new Request("https://app.example.test/api/cloud/storage/v1/object/fixture/download", {
  signal, headers: { "x-esheep-cloud-host": "fixture.supabase.co" },
});
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test("proxy preserves streaming bytes and cleans the deadline and abort listener at EOF", async () => {
  const controller = new AbortController();
  let outbound;
  const response = await proxyCloudRequest(request(controller.signal), env, {
    timeoutMs: 20,
    fetchImpl: async (input) => {
      outbound = input;
      return new Response(new ReadableStream({ start(output) {
        output.enqueue(new Uint8Array([0, 31]));
        output.enqueue(new Uint8Array([139, 255]));
        output.close();
      } }));
    },
  });
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), new Uint8Array([0, 31, 139, 255]));
  controller.abort();
  await pause(35);
  assert.equal(outbound.signal.aborted, false);
});

test("proxy cancels an upstream body when the original request aborts after headers", async () => {
  const controller = new AbortController();
  let outbound, canceled;
  const response = await proxyCloudRequest(request(controller.signal), env, {
    fetchImpl: async (input) => {
      outbound = input;
      return new Response(new ReadableStream({ cancel(reason) { canceled = reason; } }));
    },
  });
  const reading = response.arrayBuffer();
  controller.abort(new Error("fixture download canceled"));
  await assert.rejects(reading, { message: "fixture download canceled" });
  assert.equal(outbound.signal.aborted, true);
  assert.equal(canceled.message, "fixture download canceled");
});

test("proxy bounds a stalled download after headers and terminates its body", async () => {
  let outbound, canceled = false;
  const response = await proxyCloudRequest(request(), env, {
    timeoutMs: 20,
    fetchImpl: async (input) => {
      outbound = input;
      return new Response(new ReadableStream({ cancel() { canceled = true; } }));
    },
  });
  assert.equal(response.status, 200);
  // Headers are already sent; failure must terminate the body, not fabricate a 504.
  await assert.rejects(response.arrayBuffer(), { name: "AbortError" });
  assert.equal(outbound.signal.aborted, true);
  assert.equal(canceled, true);
});

test("progressing downloads may exceed the header timeout while each chunk resets the idle deadline", async () => {
  let outbound, chunk = 0;
  const response = await proxyCloudRequest(request(), env, {
    timeoutMs: 100,
    fetchImpl: async (input) => {
      outbound = input;
      return new Response(new ReadableStream({ async pull(output) {
        await pause(40);
        if (chunk === 5) output.close();
        else output.enqueue(new Uint8Array([chunk++]));
      } }));
    },
  });
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), new Uint8Array([0, 1, 2, 3, 4]));
  assert.equal(outbound.signal.aborted, false);
});

test("canceling the forwarded response body aborts upstream fetch", async () => {
  let outbound, canceled = false;
  const response = await proxyCloudRequest(request(), env, {
    fetchImpl: async (input) => {
      outbound = input;
      return new Response(new ReadableStream({ cancel() { canceled = true; } }));
    },
  });
  await response.body.cancel("fixture reader stopped");
  assert.equal(outbound.signal.aborted, true);
  assert.equal(canceled, true);
});

test("upstream body errors propagate and clean their deadline", async () => {
  let outbound;
  const response = await proxyCloudRequest(request(), env, {
    timeoutMs: 20,
    fetchImpl: async (input) => {
      outbound = input;
      return new Response(new ReadableStream({ start(output) { output.error(new Error("fixture body disconnected")); } }));
    },
  });
  await assert.rejects(response.arrayBuffer(), { message: "fixture body disconnected" });
  await pause(35);
  assert.equal(outbound.signal.aborted, false);
});

test("bodyless responses clean their deadline immediately", async () => {
  let outbound;
  const response = await proxyCloudRequest(request(), env, {
    timeoutMs: 20,
    fetchImpl: async (input) => { outbound = input; return new Response(null, { status: 204 }); },
  });
  assert.equal(response.status, 204);
  await pause(35);
  assert.equal(outbound.signal.aborted, false);
});

test("private responses discard CDN cache policies that can override no-store", async () => {
  const response = await proxyCloudRequest(request(), env, {
    fetchImpl: async () => new Response("private fixture", { headers: {
      "cache-control": "public, max-age=3600", "cdn-cache-control": "public, s-maxage=3600",
      "cloudflare-cdn-cache-control": "public, max-age=3600", "surrogate-control": "max-age=3600",
    } }),
  });
  assert.equal(await response.text(), "private fixture");
  assert.equal(response.headers.get("cache-control"), "no-store");
  for (const name of ["cdn-cache-control", "cloudflare-cdn-cache-control", "surrogate-control"]) assert.equal(response.headers.get(name), null);
});

test("post-header cancellation closes a real local HTTP upstream download", async () => {
  let upstreamClosed;
  const closed = new Promise((resolve) => { upstreamClosed = resolve; });
  const server = createServer((_input, output) => {
    output.writeHead(200, { "content-type": "application/octet-stream" });
    output.write("fixture first chunk");
    output.once("close", upstreamClosed);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const controller = new AbortController();
  try {
    const response = await proxyCloudRequest(request(controller.signal), env, {
      fetchImpl: (input) => fetch(`http://127.0.0.1:${server.address().port}/fixture`, { signal: input.signal }),
    });
    const reader = response.body.getReader();
    assert.equal(new TextDecoder().decode((await reader.read()).value), "fixture first chunk");
    controller.abort();
    await assert.rejects(reader.read(), { name: "AbortError" });
    await Promise.race([closed, pause(1000).then(() => { throw new Error("upstream download was not closed"); })]);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});

test("local workerd preserves compressed HTTP responses, gzip file bytes, and streamed deadlines", async () => {
  const [source, config] = await Promise.all([
    readFile(new URL("../worker/cloud-proxy.js", import.meta.url), "utf8"),
    readFile(new URL("../wrangler.jsonc", import.meta.url), "utf8"),
  ]);
  const data = { fixture: "compressed cloud response", padding: "牧场🌿abc0123456789".repeat(1000) };
  const json = JSON.stringify(data), gzip = gzipSync(json, { level: 9 }), brotli = brotliCompressSync(json);
  const server = createServer((input, output) => {
    const isFile = input.url === "/gzip-file", isBrotli = input.url === "/brotli-json";
    const bytes = isBrotli ? brotli : gzip;
    output.writeHead(200, {
      "content-type": isFile ? "application/gzip" : "application/json",
      "content-length": bytes.byteLength,
      ...(!isFile ? { "content-encoding": isBrotli ? "br" : "gzip" } : {}),
    });
    output.end(bytes);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const fixtureWorker = `import { proxyCloudRequest } from "./cloud-proxy.js";
    export default { async fetch(input, env) {
      const path = new URL(input.url).pathname;
      const request = new Request("https://app.example.test/api/cloud/storage/v1/object/fixture", {
        headers: { "x-esheep-cloud-host": "fixture.supabase.co" },
      });
      const stalled = path === "/stalled";
      const response = await proxyCloudRequest(request, { SUPABASE_URL: "https://fixture.supabase.co" }, {
        timeoutMs: stalled ? 15 : 2000,
        fetchImpl: stalled ? async () => new Response(new ReadableStream({})) : () => fetch(env.FIXTURE_URL + path),
      });
      if (!stalled) return response;
      try { await response.text(); return new Response("unexpected success", { status: 500 }); }
      catch (error) { return Response.json({ error: error.name }); }
    } };`;
  const mf = new Miniflare(convertV4MiniflareOptions({
    modulesRoot: "/",
    modules: [
      { type: "ESModule", path: "/fixture-worker.mjs", contents: fixtureWorker },
      { type: "ESModule", path: "/cloud-proxy.js", contents: source },
    ],
    compatibilityDate: JSON.parse(config).compatibility_date,
    bindings: { FIXTURE_URL: `http://127.0.0.1:${server.address().port}` },
  }));
  try {
    for (const path of ["/gzip-json", "/brotli-json"]) {
      const response = await mf.dispatchFetch(`https://app.example.test${path}`);
      assert.equal(response.status, 200);
      assert.deepEqual(await response.json(), data);
    }
    const file = await mf.dispatchFetch("https://app.example.test/gzip-file");
    assert.deepEqual(new Uint8Array(await file.arrayBuffer()), new Uint8Array(gzip));
    const stalled = await mf.dispatchFetch("https://app.example.test/stalled");
    assert.deepEqual(await stalled.json(), { error: "AbortError" });
  } finally {
    await mf.dispose();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});
