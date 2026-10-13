import { readFile } from "node:fs/promises";
import path from "node:path";

// Check the actual generated entry bundle, not an env file that might have
// been omitted from an isolated release checkout. Never print key values.
const root = path.resolve("dist/client");
const html = await readFile(path.join(root, "index.html"), "utf8");
const entries = [...html.matchAll(/<script\b[^>]*\bsrc="(\/assets\/[^"\s]+\.js)"/g)].map((m) => m[1]);
if (!entries.length) throw new Error("Production entry bundle is missing.");
const sources = await Promise.all(entries.map((entry) => readFile(path.join(root, entry), "utf8")));
const code = sources.join("\n");
if (!/https:\/\/[a-z]{20}\.supabase\.co/.test(code) || !/sb_publishable_[A-Za-z0-9_-]+/.test(code)) {
  throw new Error("Production browser login configuration is missing; deployment stopped.");
}
console.log("Production entry bundle contains Supabase URL and public client key.");
