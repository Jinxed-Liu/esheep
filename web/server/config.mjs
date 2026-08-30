import os from "node:os";
import path from "node:path";

export const MIMO_MODEL = "mimo-v2.5-pro";
export const MIMO_MULTIMODAL_MODEL = "mimo-v2.5";
export const MIMO_PAYGO_BASE_URL = "https://api.xiaomimimo.com/v1";
export const MIMO_TOKEN_PLAN_BASE_URL = "https://token-plan-cn.xiaomimimo.com/v1";

export class HarnessConfigurationError extends Error {
  constructor(message, missing = []) {
    super(message);
    this.name = "HarnessConfigurationError";
    this.status = 503;
    this.code = "HARNESS_NOT_CONFIGURED";
    this.missing = missing;
  }
}

export class MiMoAPIKeyError extends Error {
  constructor(message, code) {
    super(message);
    this.name = "MiMoAPIKeyError";
    this.status = 400;
    this.code = code;
  }
}

function positiveInteger(value, fallback) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function optionalString(value) {
  const normalized = String(value ?? "").trim();
  return normalized || null;
}

export function resolveMiMoBaseURL(apiKey, explicitBaseURL = null) {
  const override = optionalString(explicitBaseURL);
  if (override) {
    const parsed = new URL(override);
    const localHTTP = parsed.protocol === "http:" && ["localhost", "127.0.0.1"].includes(parsed.hostname);
    if (parsed.protocol !== "https:" && !localHTTP) {
      throw new HarnessConfigurationError("MIMO_API_BASE_URL 必须使用 HTTPS。", ["MIMO_API_BASE_URL"]);
    }
    return override.replace(/\/+$/, "");
  }
  return String(apiKey ?? "").trim().startsWith("tp-")
    ? MIMO_TOKEN_PLAN_BASE_URL
    : MIMO_PAYGO_BASE_URL;
}

export function validateMiMoAPIKey(value) {
  const normalized = String(value ?? "").trim();
  if (!normalized) {
    throw new MiMoAPIKeyError("请先填写你自己的 MiMo API Key。", "MISSING_USER_MIMO_API_KEY");
  }
  if (normalized.length < 12 || normalized.length > 512 || (!normalized.startsWith("sk-") && !normalized.startsWith("tp-"))) {
    throw new MiMoAPIKeyError("MiMo API Key 格式无效，请检查后重试。", "INVALID_USER_MIMO_API_KEY");
  }
  return normalized;
}

export function inspectHarnessEnvironment(environment = process.env) {
  const supabaseURL = optionalString(environment.SUPABASE_URL ?? environment.VITE_SUPABASE_URL);
  const supabasePublishableKey = optionalString(
    environment.SUPABASE_PUBLISHABLE_KEY ?? environment.VITE_SUPABASE_PUBLISHABLE_KEY,
  );
  const missing = [];
  if (!supabaseURL) missing.push("SUPABASE_URL");
  if (!supabasePublishableKey) missing.push("SUPABASE_PUBLISHABLE_KEY");
  return {
    configured: missing.length === 0,
    missing,
    model: MIMO_MODEL,
    multimodalModel: MIMO_MULTIMODAL_MODEL,
    provider: "mimo",
    requiresUserAPIKey: true,
  };
}

export function loadHarnessConfig(environment = process.env) {
  const inspection = inspectHarnessEnvironment(environment);
  if (!inspection.configured) {
    throw new HarnessConfigurationError(`Codex harness 缺少服务端配置：${inspection.missing.join("、")}`, inspection.missing);
  }

  return {
    model: MIMO_MODEL,
    multimodalModel: MIMO_MULTIMODAL_MODEL,
    provider: "mimo",
    mimoBaseURLOverride: optionalString(environment.MIMO_API_BASE_URL),
    supabaseURL: optionalString(environment.SUPABASE_URL ?? environment.VITE_SUPABASE_URL),
    supabasePublishableKey: optionalString(
      environment.SUPABASE_PUBLISHABLE_KEY ?? environment.VITE_SUPABASE_PUBLISHABLE_KEY,
    ),
    stateRoot: path.resolve(optionalString(environment.CODEX_HARNESS_STATE_DIR) ?? path.join(os.tmpdir(), "esheepnext-codex-harness")),
    sessionTTLMilliseconds: positiveInteger(environment.CODEX_HARNESS_SESSION_TTL_MINUTES, 12 * 60) * 60_000,
    maximumBodyBytes: positiveInteger(environment.CODEX_HARNESS_MAX_BODY_MIB, 24) * 1_048_576,
    maximumPromptCharacters: positiveInteger(environment.CODEX_HARNESS_MAX_PROMPT_CHARACTERS, 8_000),
  };
}

export function buildTurnConfig(config, userAPIKey) {
  const mimoAPIKey = validateMiMoAPIKey(userAPIKey);
  return {
    ...config,
    mimoAPIKey,
    mimoBaseURL: resolveMiMoBaseURL(mimoAPIKey, config.mimoBaseURLOverride),
  };
}

export function buildCodexOptions(config, codexHome, environment = process.env) {
  const childEnvironment = {};
  for (const key of ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"]) {
    if (typeof environment[key] === "string" && environment[key]) childEnvironment[key] = environment[key];
  }
  childEnvironment.CODEX_HOME = codexHome;
  childEnvironment.MIMO_API_KEY = config.mimoAPIKey;

  return {
    env: childEnvironment,
    config: {
      model_provider: "mimo",
      model_providers: {
        mimo: {
          name: "MiMo",
          base_url: config.mimoBaseURL,
          env_key: "MIMO_API_KEY",
          wire_api: "responses",
          requires_openai_auth: false,
          supports_websockets: false,
          request_max_retries: 2,
          stream_max_retries: 2,
        },
      },
      model_reasoning_summary: "none",
      model_supports_reasoning_summaries: false,
      hide_agent_reasoning: true,
      show_raw_agent_reasoning: false,
      web_search: "disabled",
    },
  };
}

export function buildThreadOptions(config, workingDirectory, { multimodal = false } = {}) {
  return {
    model: multimodal ? config.multimodalModel : config.model,
    threadSource: "esheepnext_web_farm_assistant",
    sandboxMode: "read-only",
    workingDirectory,
    skipGitRepoCheck: true,
    networkAccessEnabled: false,
    webSearchMode: "disabled",
    webSearchEnabled: false,
    approvalPolicy: "never",
  };
}
