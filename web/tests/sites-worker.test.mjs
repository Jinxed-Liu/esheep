import assert from "node:assert/strict";
import { access } from "node:fs/promises";
import test from "node:test";
import worker from "../worker/index.js";

test("serves existing static assets without a fallback", async () => {
  const calls = [];
  const response = await worker.fetch(new Request("https://example.test/assets/app.js"), {
    ASSETS: {
      fetch: async (request) => {
        calls.push(new URL(request.url).pathname);
        return new Response("asset", { status: 200 });
      },
    },
  });

  assert.equal(response.status, 200);
  assert.deepEqual(calls, ["/assets/app.js"]);
});

test("falls back to index.html for an unknown app route", async () => {
  const calls = [];
  const response = await worker.fetch(
    new Request("https://example.test/flow/step-two?source=share", {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async (request) => {
          const url = new URL(request.url);
          calls.push(url.pathname + url.search);
          return new Response(url.pathname === "/index.html" ? "app" : "missing", {
            status: url.pathname === "/index.html" ? 200 : 404,
          });
        },
      },
    },
  );

  assert.equal(response.status, 200);
  assert.deepEqual(calls, ["/flow/step-two?source=share", "/index.html"]);
});

test("does not turn missing API or write requests into the app shell", async () => {
  for (const request of [
    new Request("https://example.test/api/missing", { headers: { accept: "application/json" } }),
    new Request("https://example.test/flow", { method: "POST", headers: { accept: "text/html" } }),
  ]) {
    let calls = 0;
    const response = await worker.fetch(request, {
      ASSETS: {
        fetch: async () => {
          calls += 1;
          return new Response("missing", { status: 404 });
        },
      },
    });

    assert.equal(response.status, 404);
    assert.equal(calls, 1);
  }
});

test("proxies assistant requests to a bound Codex harness service", async () => {
  const calls = [];
  const request = new Request("https://example.test/api/assistant/status", {
    headers: { authorization: "Bearer test-token" },
  });
  const response = await worker.fetch(request, {
    CODEX_HARNESS: {
      fetch: async (proxiedRequest) => {
        calls.push({
          pathname: new URL(proxiedRequest.url).pathname,
          authorization: proxiedRequest.headers.get("authorization"),
        });
        return Response.json({ configured: true, model: "mimo-v2.5-pro", multimodalModel: "mimo-v2.5" });
      },
    },
  });

  assert.equal(response.status, 200);
  assert.deepEqual(calls, [{ pathname: "/api/assistant/status", authorization: "Bearer test-token" }]);
  assert.deepEqual(await response.json(), { configured: true, model: "mimo-v2.5-pro", multimodalModel: "mimo-v2.5" });
});

test("returns an explicit unavailable response when the harness is not bound", async () => {
  const response = await worker.fetch(new Request("https://example.test/api/assistant/status"), {});
  assert.equal(response.status, 503);
  assert.equal((await response.json()).code, "HARNESS_NOT_BOUND");
});

test("emits the files required by Sites packaging", async () => {
  await access(new URL("../dist/client/index.html", import.meta.url));
  await access(new URL("../dist/server/index.js", import.meta.url));
  await access(new URL("../dist/.openai/hosting.json", import.meta.url));
});
