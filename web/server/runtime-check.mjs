// Operator-only, fixed synthetic checks. Never reads a user session or model key.
import { spawnSync } from "node:child_process";
import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import http from "node:http";
import { Codex } from "@openai/codex-sdk";
import { buildCodexOptions, buildThreadOptions } from "./config.mjs";

const root = "/state/runtime-verification";
await mkdir(path.join(root, "home"), { recursive: true });
await writeFile(path.join(root, "fixture.txt"), "synthetic-runtime-fixture");
const childEnv = { PATH: process.env.PATH, HOME: "/home/node", CODEX_HOME: path.join(root, "home") };
const sandbox = (command) => {
  const result = spawnSync("/app/node_modules/.bin/codex", ["sandbox", "-c", 'sandbox_mode="read-only"', "--", "sh", "-c", command],
    { cwd: root, env: childEnv, encoding: "utf8", timeout: 20_000, maxBuffer: 100_000 });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr, error: result.error?.message };
};
const read = sandbox("cat fixture.txt");
const write = sandbox("touch /state/runtime-verification/forbidden-write");
const network = sandbox("node -e 'fetch(\"http://1.1.1.1\", {signal: AbortSignal.timeout(2000)}).then(()=>process.exit(0)).catch(()=>process.exit(9))'");
const result = { architecture: process.arch, node: process.version, read, write, network };
result.sandboxPassed = read.status === 0 && read.stdout?.includes("synthetic-runtime-fixture") &&
  write.status !== 0 && network.status === 9;

if (result.sandboxPassed) {
  const server = http.createServer(async (request, response) => {
    for await (const chunk of request) void chunk;
    const message = { id: "msg_runtime_check", type: "message", role: "assistant", status: "completed",
      content: [{ type: "output_text", text: "RUNTIME_CHECK_OK", annotations: [] }] };
    const completed = { id: "resp_runtime_check", object: "response", created_at: Math.floor(Date.now() / 1000),
      status: "completed", output: [message], usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } };
    response.writeHead(200, { "content-type": "text/event-stream" });
    for (const event of [
      { type: "response.created", response: { ...completed, status: "in_progress", output: [] } },
      { type: "response.output_item.added", output_index: 0, item: { ...message, status: "in_progress", content: [] } },
      { type: "response.output_text.delta", output_index: 0, content_index: 0, item_id: message.id, delta: "RUNTIME_CHECK_OK" },
      { type: "response.output_item.done", output_index: 0, item: message },
      { type: "response.completed", response: completed },
    ]) response.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
    response.end();
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  try {
    const config = { model: "mimo-v2.6-pro", mimoAPIKey: "sk-synthetic-runtime-check",
      mimoBaseURL: `http://127.0.0.1:${server.address().port}/v1` };
    const codex = new Codex(buildCodexOptions(config, path.join(root, "home"), childEnv));
    const thread = codex.startThread(buildThreadOptions(config, root));
    const output = await thread.run("Reply with the runtime verification marker.", { signal: AbortSignal.timeout(30_000) });
    result.sdkPassed = output.finalResponse?.includes("RUNTIME_CHECK_OK") === true;
  } catch (error) { result.sdkPassed = false; result.sdkError = error.message; }
  finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}
await rm(root, { recursive: true, force: true });
process.stdout.write(JSON.stringify(result));
process.exitCode = result.sandboxPassed && result.sdkPassed ? 0 : 1;
