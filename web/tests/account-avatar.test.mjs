import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { readAccountAvatar, uploadAccountAvatar } from "../src/lib/accountAvatar.js";

const userID = "11111111-1111-4111-8111-111111111111";
const jpeg = new Blob([new Uint8Array([0xff, 0xd8, 0xff, 0xd9])], { type: "image/jpeg" });
const digest = createHash("sha256").update(Buffer.from([0xff, 0xd8, 0xff, 0xd9])).digest("hex");

function client(initial = { avatar_digest: digest, avatar_revision: 3 }) {
  const calls = [];
  let profile = initial;
  const query = {
    select(columns) { calls.push(["select", columns]); return this; },
    eq(column, value) { calls.push(["eq", column, value]); return this; },
    async single() { return { data: profile, error: null }; },
    update(values) { calls.push(["update", values]); profile = values; return this; },
  };
  return {
    calls,
    from(table) { assert.equal(table, "profiles"); return query; },
    storage: { from(bucket) {
      assert.equal(bucket, "account-avatars");
      return {
        async download(path, options) { calls.push(["download", path, options]); return { data: jpeg, error: null }; },
        async upload(path, blob, options) { calls.push(["upload", path, blob, options]); return { error: null }; },
      };
    } },
  };
}

test("private avatar is downloaded only for a changed revision and validated by digest", async () => {
  const remote = client();
  const current = await readAccountAvatar(remote, userID);
  assert.equal(current.digest, digest);
  assert.equal(current.blob, jpeg);
  assert.deepEqual(remote.calls.find(([kind]) => kind === "download").slice(1),
    [`${userID}/avatar.jpg`, { cacheNonce: "3" }]);
  const unchanged = await readAccountAvatar(remote, userID, current);
  assert.equal(unchanged.unchanged, true);
  assert.equal(remote.calls.filter(([kind]) => kind === "download").length, 1);
  await assert.rejects(readAccountAvatar(client({ avatar_digest: "0".repeat(64), avatar_revision: 4 }), userID),
    /校验失败/);
});

test("upload writes the same private object and profile revision used by the App", async () => {
  const remote = client();
  const result = await uploadAccountAvatar(remote, userID, jpeg);
  assert.equal(result.avatar_digest, digest);
  assert.equal(result.avatar_revision, 4);
  assert.equal(remote.calls.find(([kind]) => kind === "upload")[1], `${userID}/avatar.jpg`);
  assert.equal(remote.calls.find(([kind]) => kind === "upload")[3].upsert, true);
  assert.equal(remote.calls.find(([kind]) => kind === "update")[1].avatar_revision, 4);
});

test("no-avatar metadata clears a formerly displayed photo", async () => {
  const result = await readAccountAvatar(client({ avatar_digest: null, avatar_revision: 5 }), userID,
    { digest, revision: 3 });
  assert.equal(result.blob, null);
  assert.equal(result.revision, 5);
});
