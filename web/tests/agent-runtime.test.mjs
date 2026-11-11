import assert from "node:assert/strict";
import test from "node:test";
import { runFarmAgent, responsesTurn, validatedQuestions } from "../server/agent-runtime.mjs";
import { createAgentAPI } from "../server/agent-api.mjs";
import { AssistantAuthorizationError } from "../server/auth.mjs";

const call = (name, args, id = crypto.randomUUID()) => ({ type: "function_call", name, arguments: JSON.stringify(args), call_id: id });
const turn = output => ({ status: "completed", output, usage: { output_tokens: 10 } });
const text = value => ({ type: "message", role: "assistant", content: [{ type: "output_text", text: value }] });
const snapshot = { schemaVersion: "esheepnext-farm-assistant/v1", capturedAt: "2026-11-05T00:00:00Z", farm: { id: "farm", timeZoneIdentifier: "Asia/Shanghai" }, source: { kind: "supabase-authorized-server-read" }, analyticsSource: { sheep: [] }, activeSheep: [] };
const options = { provider: "openai", apiKey: "sk-test-not-a-real-key", input: [{ role: "user", content: "分析死淘率" }], emit() {}, loadSnapshot: async () => snapshot, reviewAnswer: async () => ({ verdict: "accept" }) };

test("asking a question ends the turn before other tools run", async () => {
  let calls = 0, reads = 0;
  const result = await runFarmAgent({ ...options, loadSnapshot: async () => { reads++; return snapshot; }, modelTurn: async () => {
    calls++; return turn([call("query_cloud_farm", { kind: "available_data", filtersJSON: "{}" }), call("ask_user_question", { questions: [{ title: "分析哪个时间段？", options: ["今年", "上个月"] }] })]);
  } });
  assert.equal(calls, 1); assert.equal(reads, 0); assert.equal(result.needsUserInput, true);
  assert.match(result.text, /分析哪个时间段/);
});

test("identical queries with reordered arguments stop after two executions", async () => {
  let calls = 0, reads = 0;
  const result = await runFarmAgent({ ...options, loadSnapshot: async () => { reads++; return snapshot; }, modelTurn: async () => {
    calls++; return turn([call("query_cloud_farm", calls % 2 ? { kind: "available_data", filtersJSON: "{}" } : { filtersJSON: "{}", kind: "available_data" })]);
  } });
  assert.equal(calls, 3); assert.equal(reads, 1); assert.equal(result.exchanges.length, 2);
  assert.equal(result.needsUserInput, true);
});

test("cloud evidence is executed server-side and carried to the next model request", async () => {
  let calls = 0;
  const result = await runFarmAgent({ ...options, modelTurn: async ({ input }) => {
    if (++calls === 1) return turn([call("query_cloud_farm", { kind: "sheep_search", filtersJSON: "{}" })]);
    const evidence = JSON.parse(input.find(i => i.type === "function_call_output").output);
    assert.equal(evidence.result.totalMatches, 0); assert.equal(evidence.ok, true);
    return turn([text("当前云端档案未找到匹配，请核对耳号和牧场。")]);
  } });
  assert.equal(result.exchanges[0].call.name, "query_cloud_farm"); assert.equal(result.exchanges[0].succeeded, true);
});

test("native write tools yield to the client and are never executed on the server", async () => {
  const result = await runFarmAgent({ ...options, clientTools: [{ type: "function", name: "draft_record_weight" }],
    modelTurn: async () => turn([call("draft_record_weight", { sheepID: "sheep", kilograms: 40 })]) });
  assert.equal(result.clientCalls.length, 1); assert.equal(result.continuation.at(-1).name, "draft_record_weight");
  assert.equal(result.exchanges.length, 0);
});

test("question validation rejects empty or oversized questions", () => {
  assert.throws(() => validatedQuestions({ questions: [] }));
  assert.throws(() => validatedQuestions({ questions: [{ title: "", options: [] }] }));
});

test("metric missing information stops without spending another model call", async () => {
  let calls = 0;
  const result = await runFarmAgent({ ...options, modelTurn: async () => { calls++; return turn([call("query_cloud_farm", { kind: "mortality_summary", filtersJSON: "{}" })]); } });
  assert.equal(calls, 1); assert.equal(result.needsUserInput, true); assert.match(result.text, /哪天/);
  assert.equal(result.exchanges[0].succeeded, false);
});

test("failed factual review gets only one repair before stopping", async () => {
  let calls = 0, reviews = 0;
  const result = await runFarmAgent({ ...options, modelTurn: async () => { calls++; return turn([text("没有查数的确定结论")]); },
    reviewAnswer: async () => { reviews++; return { verdict: "reject", reason: "缺少云端统计证据" }; } });
  assert.equal(calls, 2); assert.equal(reviews, 2); assert.equal(result.needsUserInput, true);
  assert.match(result.text, /缺少云端统计证据/);
});

test("review turns an unqualified answer into a question", async () => {
  const result = await runFarmAgent({ ...options, modelTurn: async () => turn([text("默认按今年分析")]),
    reviewAnswer: async () => ({ verdict: "needs_input", reason: "未确认日期", questions: [{ title: "分析什么时间范围？", options: [] }] }) });
  assert.equal(result.needsUserInput, true); assert.match(result.text, /分析什么时间范围/);
});

test("a repeated native draft call does not generate another draft", async () => {
  const previous = call("draft_record_weight", { sheepID: "a", kilograms: 40 }, "prior");
  const result = await runFarmAgent({ ...options, input: [...options.input, previous, { type: "function_call_output", call_id: "prior", output: '{"status":"awaiting_confirmation"}' }],
    clientTools: [{ name: "draft_record_weight", type: "function" }],
    modelTurn: async () => turn([call("draft_record_weight", { sheepID: "a", kilograms: 40 })]) });
  assert.equal(result.clientCalls, undefined); assert.match(result.exchanges[0].output, /不能重复/);
});

test("Responses billing routes are fixed and OpenAI does not store responses", async () => {
  for (const [provider, key, host] of [["openai", "sk-test-key", "api.openai.com"], ["mimo", "tp-test-key", "token-plan-cn.xiaomimimo.com"]]) {
    await responsesTurn({ provider, apiKey: key, input: [], tools: [], instructions: "test", fetchImpl: async (url, init) => {
      assert.equal(new URL(url).host, host); assert.equal(init.redirect, "error");
      const body = JSON.parse(init.body); if (provider === "openai") { assert.equal(body.store, false); assert.deepEqual(body.include, ["reasoning.encrypted_content"]); }
      return new Response(`data: ${JSON.stringify({ type: "response.completed", response: turn([text("完成")]) })}\n\n`);
    } });
  }
});

test("incomplete model streams never produce a final answer", async () => {
  await assert.rejects(responsesTurn({ provider: "openai", apiKey: "sk-test-key", input: [], tools: [], instructions: "", fetchImpl: async () => new Response('data: {"type":"response.output_text.delta","delta":"假结论"}\n\n') }), /连接中断/);
});
test("server tool budget stops before executing an oversized batch", async () => {
  const result = await runFarmAgent({ ...options, toolLimit: 1, modelTurn: async () => turn([
    call("query_cloud_farm", { kind: "available_data", filtersJSON: "{}" }),
    call("query_cloud_farm", { kind: "sheep_search", filtersJSON: "{}" }),
  ]) });
  assert.equal(result.exchanges.length, 1);
  assert.equal(result.needsUserInput, true);
  assert.match(result.text, /工具调用预算/);
});
test("model and final review share the remaining output allowance", async () => {
  const caps = [];
  await runFarmAgent({ ...options, outputLimit: 300, modelTurn: async ({ maxOutputTokens }) => {
    caps.push(maxOutputTokens); return turn([text("解释")]);
  }, reviewAnswer: async ({ maxOutputTokens }) => { caps.push(maxOutputTokens); return { verdict: "accept", outputTokens: 10 }; } });
  assert.deepEqual(caps, [300, 290]);
});

test("farm authorization rejects a foreign farm before reading data or calling a model", async () => {
  let model = 0, reads = 0;
  const api = createAgentAPI({ environment: { SUPABASE_URL: "https://test.supabase.co", SUPABASE_PUBLISHABLE_KEY: "test" },
    authVerifier: async () => { throw new AssistantAuthorizationError("无此牧场权限", 403); },
    snapshotLoader: async () => { reads++; return snapshot; }, modelTurn: async () => { model++; return turn([text("错误")]); } });
  const response = await api(new Request("https://test/api/assistant/agent/turn?farm_id=00000000-0000-4000-8000-000000000001", { method: "POST", body: "{}" }));
  assert.equal(response.status, 403); assert.equal(reads, 0); assert.equal(model, 0);
});

test("API ignores a supplied snapshot and sends only scoped server evidence", async () => {
  let modelCalls = 0, reads = 0;
  const api = createAgentAPI({ environment: { SUPABASE_URL: "https://test.supabase.co", SUPABASE_PUBLISHABLE_KEY: "test" },
    authVerifier: async () => ({ userID: "user", membership: { farm_id: "farm" } }),
    reviewAnswer: async () => ({ verdict: "accept" }),
    snapshotLoader: async ({ authorization }) => { reads++; assert.equal(authorization.userID, "user"); return snapshot; },
    modelTurn: async ({ input }) => { assert.ok(!JSON.stringify(input).includes("FAKE_FARM_FACT")); return ++modelCalls === 1 ? turn([call("query_cloud_farm", { kind: "available_data", filtersJSON: "{}" })]) : turn([text("已核对")]); } });
  const response = await api(new Request("https://test/api/assistant/agent/turn?farm_id=00000000-0000-4000-8000-000000000001", { method: "POST",
    headers: { "x-agent-consent": "2026-11-05-agent-v1", "x-assistant-api-key": "sk-test-not-a-real-key" },
    body: JSON.stringify({ provider: "openai", input: [{ role: "user", content: "核对" }], snapshot: { fake: "FAKE_FARM_FACT" } }) }));
  assert.equal(response.status, 200); const events = (await response.text()).trim().split("\n").map(JSON.parse);
  assert.equal(events.at(-1).type, "result"); assert.equal(reads, 1);
});
test("a withheld mortality rate reaches the user without another inference or arithmetic", async () => {
  const fixture = { ...snapshot, analyticsSource: { sheep: [{ id: "legacy", enteredAt: null }] } };
  let calls = 0;
  const result = await runFarmAgent({ ...options, loadSnapshot: async () => fixture, loadRoster: async () => ({count:null}),
    modelTurn: async () => { calls++; return turn([call("query_cloud_farm", { kind: "mortality_summary", filtersJSON: JSON.stringify({ startDate: "2026-10-01", endDate: "2026-10-31", sex: "all", denominator: "opening_cohort" }) })]); },
    reviewAnswer: () => { throw new Error("withheld metric must not be rewritten"); } });
  assert.equal(calls, 1);
  assert.match(result.text, /死淘率无法核定/);
  assert.doesNotMatch(result.text, /%/);
});
test("the selected OpenAI model reaches inference and review; unsupported choices fail", async () => {
  const { validateAgentBody } = await import("../server/agent-api.mjs");
  const body = { provider: "openai", model: "gpt-5.4-mini", input: options.input };
  assert.equal(validateAgentBody(body).model, body.model);
  assert.throws(() => validateAgentBody({ ...body, provider: "mimo" }), /不支持所选模型/);
  assert.equal(validateAgentBody({ ...body, model: undefined }).model, "gpt-5.4");
  const models = [];
  await runFarmAgent({ ...options, ...validateAgentBody(body),
    modelTurn: async args => { models.push(args.model); return turn([text("完成")]); },
    reviewAnswer: async args => { models.push(args.model); return { verdict: "accept" }; } });
  assert.deepEqual(models, [body.model, body.model]);
  await responsesTurn({ ...body, apiKey: "sk-test-not-a-real-key", tools: [], fetchImpl: async (_, init) => {
    assert.equal(JSON.parse(init.body).model, body.model);
    return new Response('data: '+JSON.stringify({type:"response.completed",response:turn([text("好")])})+'\n\n');
  } });
});

test("month-only mortality uses one authorized opening book and returns the exact computed fraction in one turn", async () => {
  const s = {...snapshot, farm:{...snapshot.farm,generation:2,revision:10}, analyticsSource:{
    sheep:[], removals:["A","outside"].map(sheepID => ({ sheepID, kind:"deceased", at:"2026-10-15T00:00:00Z" })) }};
  let reads=0, calls=0;
  const result = await runFarmAgent({...options, loadSnapshot:async()=>s,
    loadRoster:async(filters,options)=>{
      assert.equal(++reads,1); assert.equal(options.includeMembers,true);
      assert.deepEqual(filters,{day:"2026-10-01",opening:true,sex:"all",breed:"",penName:""});
      return {farm_id:"farm",farm_generation:2,day:filters.day,basis:"期初",time_zone:s.farm.timeZoneIdentifier,
        cloud_head:8,filters_applied:filters,count:3,memberIDs:["a","b","private-unaffected-id"]};
    },
    modelTurn:async()=>{ assert.equal(++calls,1); return turn([call("query_cloud_farm",{kind:"mortality_summary",filtersJSON:'{"month":10}'})]); },
    reviewAnswer:()=>assert.fail("computed metric was sent for rewriting"),
  });
  assert.match(result.text,/1 ÷ 3 = 33.33%/);
  assert.ok(!JSON.stringify(result.exchanges).includes("private-unaffected-id"));
});
