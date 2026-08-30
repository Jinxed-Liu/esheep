import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { FarmAssistantHarness } from "../server/harness.mjs";
import { loadHarnessConfig } from "../server/config.mjs";

function fakeCodexFactory(calls) {
  return (options) => {
    calls.push({ type: "codex", options });
    const makeThread = (method, threadID, threadOptions) => ({
      async runStreamed(input) {
        calls.push({ type: method, threadID, threadOptions, input });
        return {
          events: (async function* events() {
            yield { type: "thread.started", thread_id: threadID ?? "thread-test" };
            yield { type: "item.completed", item: { id: `answer-${calls.length}`, type: "agent_message", text: "测试回答" } };
            yield { type: "turn.completed", usage: { input_tokens: 1, cached_input_tokens: 0, cache_write_input_tokens: 0, output_tokens: 1, reasoning_output_tokens: 0 } };
          }()),
        };
      },
    });
    return {
      startThread: (threadOptions) => makeThread("start", null, threadOptions),
      resumeThread: (threadID, threadOptions) => makeThread("resume", threadID, threadOptions),
    };
  };
}

const snapshot = {
  schemaVersion: "esheepnext-farm-assistant/v1",
  capturedAt: "2026-08-31T00:00:00Z",
  source: { description: "test" },
  farm: { id: "farm-1", name: "测试牧场", timeZoneIdentifier: "Asia/Shanghai" },
  metrics: {}, dataAvailability: {}, projectionCoverage: {}, activeSheep: [], pens: [], events: [],
  analyticsSource: { sheep: [], pens: [], weights: [], weanings: [], reproduction: [], removals: [], transfers: [], batches: [], batchMemberships: [], feeds: [], troughObservations: [], dailyPenCounts: [] },
};

test("resumes one Codex thread while switching image turns to mimo-v2.5", async (context) => {
  const stateRoot = await mkdtemp(path.join(os.tmpdir(), "esheepnext-harness-test-"));
  context.after(() => rm(stateRoot, { recursive: true, force: true }));
  const secret = "sk-test-never-persist";
  const config = loadHarnessConfig({
    SUPABASE_URL: "https://project.supabase.co",
    SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test",
    CODEX_HARNESS_STATE_DIR: stateRoot,
  });
  const calls = [];
  const harness = new FarmAssistantHarness({ config, codexFactory: fakeCodexFactory(calls), environment: { PATH: "/usr/bin", HOME: "/Users/test" } });

  const textEvents = [];
  for await (const event of harness.runTurn({ userID: "user-1", farmID: "farm-1", prompt: "概览", snapshot, mimoAPIKey: secret })) textEvents.push(event);
  const sessionID = textEvents.find((event) => event.type === "session").sessionID;
  assert.equal(textEvents.find((event) => event.type === "session").model, "mimo-v2.5-pro");

  const tinyPNG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).toString("base64");
  const imageEvents = [];
  for await (const event of harness.runTurn({
    sessionID,
    userID: "user-1",
    farmID: "farm-1",
    prompt: "看图",
    snapshot,
    mimoAPIKey: secret,
    attachments: [{ mimeType: "image/png", dataURL: `data:image/png;base64,${tinyPNG}` }],
  })) imageEvents.push(event);
  assert.equal(imageEvents.find((event) => event.type === "session").model, "mimo-v2.5");

  const turnCalls = calls.filter((call) => ["start", "resume"].includes(call.type));
  assert.equal(turnCalls[0].threadOptions.model, "mimo-v2.5-pro");
  assert.match(turnCalls[0].input, /默认先给结果并在 1–3 句内结束/);
  assert.equal(turnCalls[1].type, "resume");
  assert.equal(turnCalls[1].threadOptions.model, "mimo-v2.5");
  assert.equal(turnCalls[1].input.some((item) => item.type === "local_image"), true);

  const sessionDirectory = path.join(stateRoot, sessionID);
  const persisted = await Promise.all(["session.json", "farm-snapshot.json", "AGENTS.md"].map((name) => readFile(path.join(sessionDirectory, name), "utf8")));
  assert.equal(persisted.join("\n").includes(secret), false);
  assert.equal(await harness.deleteSession({ sessionID, userID: "user-1", farmID: "farm-1" }), true);
});
