import { activeBackend, hostedOrigin, isCloudRoute, miniOrigin } from "../worker/backend-status.js";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadEnv } from "vite";
import { createAssistantAPI } from "./api.mjs";
import { handleNodeRequest } from "./node-adapter.mjs";
import { createWeatherAPI } from "./weather-api.mjs";
import { proxyCloudRequest } from "../worker/cloud-proxy.js";
import { nodeCloudFetch } from "./cloud-fetch.mjs";
import { staticAssetCacheControl } from "./static-asset-cache.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const clientRoot = path.join(root, "dist", "client");
const environment = { ...loadEnv("production", root, ""), ...process.env };
const serviceOrigin = environment.SUPABASE_URL ?? environment.VITE_SUPABASE_URL;
if ([hostedOrigin, miniOrigin].includes(serviceOrigin)) {
  environment.BACKEND_STATUS = { fetch: async (input) => fetch("https://app.esheepplus.com/api/backend-status", {
    method: input instanceof Request ? input.method : "GET",
    redirect: "error", cache: "no-store", signal: AbortSignal.timeout(6000),
  }) };
}
const assistantAPI = createAssistantAPI({ environment });
const weatherAPI = createWeatherAPI({ environment });
const port = Number.parseInt(environment.PORT ?? "4173", 10);
const host = environment.HOST ?? "0.0.0.0";
const mimeTypes = new Map([
  [".css", "text/css; charset=utf-8"], [".html", "text/html; charset=utf-8"], [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"], [".png", "image/png"], [".jpg", "image/jpeg"], [".jpeg", "image/jpeg"],
  [".svg", "image/svg+xml"], [".webp", "image/webp"], [".woff2", "font/woff2"],
]);

async function existingFile(urlPath) {
  const decoded = decodeURIComponent(urlPath);
  const candidate = path.resolve(clientRoot, `.${decoded}`);
  if (candidate !== clientRoot && !candidate.startsWith(`${clientRoot}${path.sep}`)) return null;
  try {
    const information = await stat(candidate);
    return information.isFile() ? candidate : null;
  } catch {
    return null;
  }
}

const server = http.createServer(async (request, response) => {
  try {
    if (isCloudRoute(request.url)) {
      await handleNodeRequest(request, response, (cloudRequest) => proxyCloudRequest(cloudRequest, environment, { fetchImpl: nodeCloudFetch }));
      return;
    }
    if ((request.url ?? "").startsWith("/api/assistant/") || (request.url ?? "").startsWith("/api/weather/")) {
      if (environment.BACKEND_STATUS) {
        const active = await activeBackend(environment);
        if ((active === "hosted" ? hostedOrigin : active === "mini" ? miniOrigin : null) !== serviceOrigin) {
          response.writeHead(503, { "cache-control": "no-store", "content-type": "application/json" });
          response.end(JSON.stringify({ error: "牧场服务维护中。" }));
          return;
        }
      }
      await handleNodeRequest(request, response, (request.url ?? "").startsWith("/api/weather/") ? weatherAPI : assistantAPI);
      return;
    }
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "127.0.0.1"}`);
    let filePath = ["GET", "HEAD"].includes(request.method ?? "GET") ? await existingFile(url.pathname) : null;
    if (!filePath && (url.pathname === "/" || request.headers.accept?.includes("text/html")) && ["GET", "HEAD"].includes(request.method ?? "GET")) {
      filePath = path.join(clientRoot, "index.html");
    }
    if (!filePath) {
      response.statusCode = 404;
      response.end("Not found");
      return;
    }
    response.statusCode = 200;
    response.setHeader("Content-Type", mimeTypes.get(path.extname(filePath).toLowerCase()) ?? "application/octet-stream");
    response.setHeader("Cache-Control", staticAssetCacheControl(`/${path.relative(clientRoot, filePath)}`));
    if (request.method === "HEAD") response.end();
    else createReadStream(filePath).pipe(response);
  } catch {
    response.statusCode = 500;
    response.end("Server error");
  }
});

server.listen(port, host, () => {
  process.stdout.write(`eSheep+ Web + Codex harness: http://127.0.0.1:${port}\n`);
});
