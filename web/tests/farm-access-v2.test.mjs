import assert from "node:assert/strict";
import test from "node:test";
import { listAccessibleFarms, redeemAccessibleFarmInvite } from "../src/lib/farmAccess.js";
import { withCheckpointCors } from "../../supabase/functions/esheep-cloud-checkpoints/cors.mjs";

const farmID = "00000000-0000-4000-8000-000000000001";
const v2Farm = { farm_id: farmID, farm_generation: 3, role: "owner", member_account_id: "account", initial_sync_ready: true };
const accessClient = (v2, legacy = { data: [] }) => ({
  rpc(name) { return Promise.resolve(name === "esheep_cloud_list_my_farms_v2" ? v2 : legacy); },
});

test("owner retains farm access when cutover makes the V1 list empty", async () => {
  const farms = await listAccessibleFarms(accessClient({ data: { farms: [v2Farm] } }));
  assert.equal(farms.length, 1);
  assert.equal(farms[0].provider, "esheep_cloud");
  assert.equal(farms[0].authority_generation, 3);
  assert.equal(farms[0].member_role, "owner");
});

test("only confirmed empty membership lists produce no-farm access", async () => {
  assert.deepEqual(await listAccessibleFarms(accessClient({ data: { farms: [] } })), []);
  await assert.rejects(listAccessibleFarms(accessClient({ error: new Error("permission lookup failed") })), /permission lookup failed/);
  await assert.rejects(listAccessibleFarms(accessClient({ data: null })), /权限响应不完整/);
});

test("a V2 farm that is still preparing is retained instead of treated as an uninvited account", async () => {
  const [farm] = await listAccessibleFarms(accessClient({ data: { farms: [{ ...v2Farm, initial_sync_ready: false }] } }));
  assert.equal(farm.farm_status, "preparing");
  assert.equal(farm.initial_sync_ready, false);
});

test("legacy farms still work and V2 wins a duplicate provider response", async () => {
  const legacyFarm = { farm_id: farmID.toUpperCase(), provider: "supabase", member_role: "owner" };
  const [old] = await listAccessibleFarms(accessClient({ data: { farms: [] } }, { data: [legacyFarm] }));
  assert.equal(old.provider, "supabase");
  const farms = await listAccessibleFarms(accessClient({ data: { farms: [v2Farm] } }, { data: [legacyFarm] }));
  assert.equal(farms.length, 1);
  assert.equal(farms[0].provider, "esheep_cloud");
});

test("invitation redemption chooses exactly one protocol and respects its return shape", async () => {
  const calls = [];
  const client = { async rpc(name, args) {
    calls.push({ name, args });
    return { data: name.endsWith("_v2") ? { farm_id: farmID } : [{ farm_id: farmID }] };
  } };
  assert.equal((await redeemAccessibleFarmInvite(client, "A".repeat(43))).farm_id, farmID);
  assert.equal(calls[0].name, "esheep_cloud_redeem_invite_v2");
  await redeemAccessibleFarmInvite(client, " legacy-code ");
  assert.equal(calls[1].name, "redeem_farm_invite");
  assert.equal(calls[1].args.p_code, "legacy-code");
});

test("an uncertain invitation result is not retried through another endpoint", async () => {
  let calls = 0;
  const client = { async rpc() { calls++; return { error: new Error("network interrupted") }; } };
  await assert.rejects(redeemAccessibleFarmInvite(client, "A".repeat(43)), /network interrupted/);
  assert.equal(calls, 1);
});

test("checkpoint preflight permits the Web without bypassing authentication", async () => {
  let calls = 0;
  const handler = withCheckpointCors(async () => { calls++; return new Response("unauthorized", { status: 401 }); });
  const origin = "https://staging.esheepplus.com";
  const preflight = await handler(new Request("https://example.com", { method: "OPTIONS", headers: { origin } }));
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("access-control-allow-origin"), origin);
  assert.equal(calls, 0);
  const failedAuth = await handler(new Request("https://example.com", { method: "POST", headers: { origin } }));
  assert.equal(failedAuth.status, 401);
  assert.equal(failedAuth.headers.get("access-control-allow-origin"), origin);
  assert.equal(calls, 1);
  const untrustedOrigin = await handler(new Request("https://example.com", { method: "POST", headers: { origin: "https://untrusted.example" } }));
  assert.equal(untrustedOrigin.status, 403);
  assert.equal(calls, 1);
  const native = await handler(new Request("https://example.com", { method: "POST" }));
  assert.equal(native.status, 401);
  assert.equal(calls, 2);
});
