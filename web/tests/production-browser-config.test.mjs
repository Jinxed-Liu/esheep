import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";
const script = fileURLToPath(new URL("../scripts/verify-production-browser-config.mjs", import.meta.url));
function verify(code) {
 const root = mkdtempSync(path.join(tmpdir(), "esheep-production-config-"));
 try {
  mkdirSync(path.join(root, "dist/client/assets"), { recursive: true });
  writeFileSync(path.join(root, "dist/client/index.html"), '<script type="module" src="/assets/index-test.js"></script>');
  writeFileSync(path.join(root, "dist/client/assets/index-test.js"), code);
  return spawnSync(process.execPath, [script], { cwd: root, encoding: "utf8" });
 } finally { rmSync(root, { recursive: true, force: true }); }
}
test("deployment rejects a build without browser login configuration", () => {
 const result = verify('console.log("app")');
 assert.notEqual(result.status, 0);
 assert.match(result.stderr, /login configuration is missing/);
});
test("deployment rejects URL-only configuration", () => {
 const result = verify('const url="https://abcdefghijklmnopqrst.supabase.co"');
 assert.notEqual(result.status, 0);
});
test("configured entry bundle passes without printing the public client key", () => {
 const key = "sb_publishable_fixture_public_key";
 const result = verify(`const url="https://abcdefghijklmnopqrst.supabase.co"; const key="${key}"`);
 assert.equal(result.status, 0);
 assert.ok(!result.stdout.includes(key));
});
