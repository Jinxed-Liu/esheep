import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer as createViteServer, loadEnv } from "vite";
import { createAssistantAPI } from "./api.mjs";
import { handleNodeRequest } from "./node-adapter.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const environment = { ...loadEnv("development", root, ""), ...process.env };
const assistantAPI = createAssistantAPI({ environment });
const vite = await createViteServer({
  root,
  appType: "spa",
  server: { middlewareMode: true },
});
const port = Number.parseInt(environment.PORT ?? "5173", 10);
const host = environment.HOST ?? "0.0.0.0";

const server = http.createServer(async (request, response) => {
  try {
    if ((request.url ?? "").startsWith("/api/assistant/")) {
      await handleNodeRequest(request, response, assistantAPI);
      return;
    }
    vite.middlewares(request, response, (error) => {
      if (error) {
        vite.ssrFixStacktrace(error);
        response.statusCode = 500;
        response.end("Development server error");
      }
    });
  } catch (error) {
    vite.ssrFixStacktrace(error);
    response.statusCode = 500;
    response.end("Development server error");
  }
});

server.listen(port, host, () => {
  process.stdout.write(`eSheep+ Web + Codex harness: http://127.0.0.1:${port}\n`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, async () => {
    await vite.close();
    server.close(() => process.exit(0));
  });
}
