import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const required = [
  "APPLE_CLIENT_ID",
  "APPLE_TEAM_ID",
  "APPLE_KEY_ID",
  "APPLE_PRIVATE_KEY",
  "SESSION_SIGNING_SECRET",
  "CREDENTIAL_ENCRYPTION_KEY",
  "CAPABILITY_SIGNING_PRIVATE_KEY",
  "CAPABILITY_SIGNING_KEY_ID",
];

const configText = readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8");
if (configText.includes("REPLACE_WITH_D1_DATABASE_ID")) {
  throw new Error("Development D1 database_id 尚未配置，拒绝部署。");
}

const npx = process.platform === "win32" ? "npx.cmd" : "npx";
const output = execFileSync(npx, ["wrangler", "secret", "list", "--format", "json"], { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
const listed = JSON.parse(output);
const names = new Set(listed.map((item) => item.name));
const missing = required.filter((name) => !names.has(name));
if (missing.length > 0) {
  throw new Error(`缺少 Workers Secrets，拒绝部署：${missing.join(", ")}`);
}

console.log("Development D1 与必需 Secrets 配置检查通过。");
