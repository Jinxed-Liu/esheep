import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadEnv } from "vite";
import { createAssistantAPI } from "./api.mjs";
import { handleNodeRequest } from "./node-adapter.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const clientRoot = path.join(root, "dist", "client");
const environment = { ...loadEnv("production", root, ""), ...process.env };
const assistantAPI = createAssistantAPI({ environment });
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
    if ((request.url ?? "").startsWith("/api/assistant/")) {
      await handleNodeRequest(request, response, assistantAPI);
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
    response.setHeader("Cache-Control", filePath.endsWith("index.html") ? "no-cache" : "public, max-age=31536000, immutable");
    if (request.method === "HEAD") response.end();
    else createReadStream(filePath).pipe(response);
  } catch {
    response.statusCode = 500;
    response.end("Server error");
  }
});

server.listen(port, host, () => {
  process.stdout.write(`eSheepNext Web + Codex harness: http://127.0.0.1:${port}\n`);
});
