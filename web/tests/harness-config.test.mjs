import assert from "node:assert/strict";
import test from "node:test";
import {
  MIMO_MULTIMODAL_MODEL,
  MIMO_MODEL,
  MIMO_PAYGO_BASE_URL,
  MIMO_TOKEN_PLAN_BASE_URL,
  buildCodexOptions,
  buildThreadOptions,
  buildTurnConfig,
  inspectHarnessEnvironment,
  loadHarnessConfig,
  resolveMiMoBaseURL,
  validateMiMoAPIKey,
} from "../server/config.mjs";

const baseEnvironment = {
  SUPABASE_URL: "https://project.supabase.co",
  SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test",
};
const userAPIKey = "sk-test-not-a-real-key";

test("locks text and multimodal turns to the two requested MiMo models", () => {
  const config = loadHarnessConfig(baseEnvironment);
  assert.equal(config.model, MIMO_MODEL);
  assert.equal(config.multimodalModel, MIMO_MULTIMODAL_MODEL);
  assert.equal(buildThreadOptions(config, "/tmp/session").model, "mimo-v2.5-pro");
  assert.equal(buildThreadOptions(config, "/tmp/session", { multimodal: true }).model, "mimo-v2.5");
});

test("uses the matching MiMo endpoint for pay-go and token-plan keys", () => {
  assert.equal(resolveMiMoBaseURL("sk-example"), MIMO_PAYGO_BASE_URL);
  assert.equal(resolveMiMoBaseURL("tp-example"), MIMO_TOKEN_PLAN_BASE_URL);
});

test("passes the MiMo key only through the child environment", () => {
  const baseConfig = loadHarnessConfig(baseEnvironment);
  const config = buildTurnConfig(baseConfig, userAPIKey);
  const options = buildCodexOptions(config, "/private/session/codex-home", { PATH: "/usr/bin", HOME: "/Users/test" });
  assert.equal(options.env.MIMO_API_KEY, userAPIKey);
  assert.equal(options.env.CODEX_HOME, "/private/session/codex-home");
  assert.equal(options.config.model_provider, "mimo");
  assert.equal(options.config.model_providers.mimo.wire_api, "responses");
  assert.equal(JSON.stringify(options.config).includes(userAPIKey), false);
  assert.equal(JSON.stringify(baseConfig).includes(userAPIKey), false);
});

test("reports every missing server-side prerequisite without throwing", () => {
  assert.deepEqual(inspectHarnessEnvironment({}).missing, ["SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY"]);
  assert.equal(inspectHarnessEnvironment(baseEnvironment).requiresUserAPIKey, true);
});

test("validates each user's MiMo key before building a turn", () => {
  assert.equal(validateMiMoAPIKey(`  ${userAPIKey}  `), userAPIKey);
  assert.equal(buildTurnConfig(loadHarnessConfig(baseEnvironment), "tp-test-not-a-real-key").mimoBaseURL, MIMO_TOKEN_PLAN_BASE_URL);
  assert.throws(() => validateMiMoAPIKey(""), { code: "MISSING_USER_MIMO_API_KEY" });
  assert.throws(() => validateMiMoAPIKey("shared-server-key"), { code: "INVALID_USER_MIMO_API_KEY" });
});
