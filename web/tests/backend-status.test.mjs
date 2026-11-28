import assert from "node:assert/strict";
import test from "node:test";
import worker from "../worker/index.js";
import { proxyCloudRequest } from "../worker/cloud-proxy.js";
import { backendStatusResponse, miniOrigin, hostedOrigin } from "../worker/backend-status.js";
import { forwardAgent } from "../worker/production-agent.js";
const endpoint = "https://app.esheepplus.com/api/backend-status";
test("the separate agent route follows the active backend and pauses for maintenance", async () => {
  const request = new Request("https://app.esheepplus.com/api/assistant/agent/status");
  for (const [state, origin] of [["hosted", "https://mini.esheepplus.com"], ["mini", miniOrigin], ["maintenance", null]]) {
    const environment = { BACKEND_STATUS: { fetch: () => Response.json({ state }) } };
    const result = await forwardAgent(request, environment, async target => {
      assert.ok(origin);
      assert.equal(target.origin, origin);
      return new Response(null, { status: 204 });
    });
    assert.equal(result.status, origin ? 204 : 503);
  }
  assert.equal((await forwardAgent(request, {}, () => assert.fail())).status, 503);
});
for (const state of ["hosted", "maintenance", "mini"]) {
  test("read-only state " + state, async () => {
    const env = { ESHEEP_BACKEND_STATE:state };
    const response = await worker.fetch(new Request(endpoint), env);
    assert.deepEqual(await response.json(),{state});
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.equal((await worker.fetch(new Request(endpoint,{method:"POST"}),env)).status,405);
    assert.equal(await (await worker.fetch(new Request(endpoint,{method:"HEAD"}),env)).text(),"");
  });
}
test("maintenance and stale callers cannot reach an upstream", async () => {
  const url = "https://app.esheepplus.com/api/cloud/rest/v1/animals";
  for (const [state, host, expected] of [["maintenance",hostedOrigin,503],["bad",hostedOrigin,503],["mini",hostedOrigin,409],["hosted",miniOrigin,409]]) {
    const response = await proxyCloudRequest(new Request(url,{method:"POST",headers:{"x-esheep-cloud-host": new URL(host).host}}),
      { SUPABASE_URL:hostedOrigin, BACKEND_STATUS:{fetch:()=>backendStatusResponse(new Request(endpoint),{ESHEEP_BACKEND_STATE:state})}},
      {fetchImpl:()=>assert.fail("unexpected forward")});
    assert.equal(response.status,expected);
  }
});
