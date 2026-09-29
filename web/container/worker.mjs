import { Container } from "@cloudflare/containers";
import { env } from "cloudflare:workers";
import { verifyFarmAccess } from "../server/auth.mjs";
import { validateMiMoAPIKey } from "../server/config.mjs";
import { createContainerRouter } from "./router.mjs";
import { createWeatherAPI } from "../server/weather-api.mjs";

const weatherAPI = createWeatherAPI();

export class HarnessContainer extends Container {
  defaultPort = 8080;
  sleepAfter = "10m";
  envVars = {
    SUPABASE_URL: env.SUPABASE_URL,
    SUPABASE_PUBLISHABLE_KEY: env.SUPABASE_PUBLISHABLE_KEY,
  };
  activeRequests = 0;
  async runtimeCheck() {
    await this.startAndWaitForPorts();
    const process = await this.ctx.container.exec(["node", "/app/server/runtime-check.mjs"]);
    const result = await process.output();
    const decoder = new TextDecoder();
    return { exitCode: result.exitCode, stdout: decoder.decode(result.stdout), stderr: decoder.decode(result.stderr) };
  }
  async fetch(request) {
    this.activeRequests += 1;
    try {
      const response = await super.fetch(request);
      if (!response.body) { this.activeRequests -= 1; return response; }
      const reader = response.body.getReader();
      let finished = false;
      const finish = () => {
        if (!finished) { finished = true; this.activeRequests -= 1; this.renewActivityTimeout(); }
      };
      const body = new ReadableStream({
        async pull(controller) {
          try {
            const item = await reader.read();
            if (item.done) { finish(); controller.close(); }
            else controller.enqueue(item.value);
          } catch (error) { finish(); controller.error(error); }
        },
        async cancel(reason) { finish(); await reader.cancel(reason); },
      });
      return new Response(body, response);
    } catch (error) { this.activeRequests -= 1; throw error; }
  }
  async onActivityExpired() {
    if (this.activeRequests) { this.renewActivityTimeout(); return; }
    await super.onActivityExpired();
  }
}

const assistantRouter = createContainerRouter({ verifyAccess: verifyFarmAccess, validateKey: validateMiMoAPIKey });
export default { fetch(request, runtimeEnv) {
  return new URL(request.url).pathname.startsWith("/api/weather/")
    ? weatherAPI(request, runtimeEnv)
    : assistantRouter(request, runtimeEnv);
} };
