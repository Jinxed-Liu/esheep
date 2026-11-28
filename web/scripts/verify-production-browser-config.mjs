import { readFile } from "node:fs/promises";
import path from "node:path";

// Check the actual generated entry bundle, not an env file that might have
// been omitted from an isolated release checkout. Never print key values.
const root = path.resolve("dist/client");
const html = await readFile(path.join(root, "index.html"), "utf8");
const entries = [...html.matchAll(/<script\b[^>]*\bsrc="(\/assets\/[^"\s]+\.js)"/g)].map((m) => m[1]);
if (!entries.length) throw new Error("Production entry bundle is missing.");
const manifest = JSON.parse(await readFile(path.join(root, ".vite/manifest.json"), "utf8"));
const seen = new Set();
const files = new Set();
function visit(name) {
  if (seen.has(name)) return;
  seen.add(name);
  const chunk = manifest[name];
  if (!chunk || !/^assets\/[\w.-]+\.js$/.test(chunk.file)) throw new Error("Invalid production chunk graph.");
  files.add(chunk.file);
  for (const next of [...(chunk.imports ?? []), ...(chunk.dynamicImports ?? [])]) visit(next);
}
for (const entry of entries) {
  const main = Object.keys(manifest).find((key) => manifest[key].isEntry && "/" + manifest[key].file === entry);
  if (!main) throw new Error("Production entry is missing from build manifest.");
  visit(main);
}
const code = (await Promise.all([...files].map((file) => readFile(path.join(root, file), "utf8")))).join("\n");
const expected = [
  "https://rnqrvthbunrzqtprquqx.supabase.co",
  "https://api.esheepplus.com",
  "/api/backend-status",
  "sb_publishable_bePHSQqefqMacwUKZqH1VA_rcXU_CGw",
  "sb_publishable_mCtOQIg_1QFyu4bUv1giBK_Fp8VsNyK"
];
if (!expected.every((value) => code.includes(value))) {
  throw new Error("Production browser login configuration is missing; deployment stopped.");
}
console.log("Both production origins, pinned public keys and status endpoint are present.");
