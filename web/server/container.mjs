import http from "node:http";
import { createAssistantAPI } from "./api.mjs";
import { handleNodeRequest } from "./node-adapter.mjs";
import { createWeatherAPI } from "./weather-api.mjs";

// API-only image: never load dotenv files, frontend assets, or developer credentials.
const assistantAPI = createAssistantAPI({ environment: process.env });
const weatherAPI = createWeatherAPI({ environment: process.env });
const server = http.createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/health") {
      response.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
      response.end('{"ready":true}');
      return;
    }
    if (await handleNodeRequest(request, response, (request.url ?? "").startsWith("/api/weather/") ? weatherAPI : assistantAPI)) return;
    response.writeHead(404);
    response.end();
  } catch {
    if (!response.headersSent) response.writeHead(500);
    response.end();
  }
});
server.listen(Number(process.env.PORT || 8080), process.env.HOST || "0.0.0.0");
process.once("SIGTERM", () => server.close());
