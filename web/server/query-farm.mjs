import { readFile } from "node:fs/promises";
import path from "node:path";
import * as analytics from "./app-analytics.mjs";
import { createFarmQueryEngine } from "./farm-query-core.mjs";

function parseValue(value) {
  const candidate = String(value ?? "");
  if (candidate === "true") return true;
  if (candidate === "false") return false;
  if (/^-?\d+(?:\.\d+)?$/.test(candidate)) return Number(candidate);
  if (candidate.includes(",")) return candidate.split(",").map((item) => item.trim()).filter(Boolean);
  return candidate;
}

function parseRequest(argumentsList) {
  const [kind, ...options] = argumentsList;
  const request = { kind };
  for (const option of options) {
    const separator = option.indexOf("=");
    if (separator <= 0) throw new Error(`参数必须使用 key=value：${option}`);
    request[option.slice(0, separator)] = parseValue(option.slice(separator + 1));
  }
  return request;
}

try {
  const snapshotPath = path.join(process.cwd(), "farm-snapshot.json");
  const snapshot = JSON.parse(await readFile(snapshotPath, "utf8"));
  const runFarmQuery = createFarmQueryEngine(analytics);
  const result = runFarmQuery(snapshot, parseRequest(process.argv.slice(2)));
  process.stdout.write(`${JSON.stringify(result)}\n`);
} catch (error) {
  process.stdout.write(`${JSON.stringify({ ok: false, error: error instanceof Error ? error.message : "牧场查询失败。" })}\n`);
  process.exitCode = 1;
}
