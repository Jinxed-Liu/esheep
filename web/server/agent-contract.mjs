// Safe to import in the edge gateway without the database projection runtime.
export const AGENT_CONSENT_VERSION = "2026-11-05-agent-v1";
export const AGENT_MODELS = { mimo: "mimo-v2.6-pro", openai: "gpt-5.4" };
// Only models compatible with this Responses text, vision and function-tool pipeline.
export const AGENT_MODEL_OPTIONS = {
  openai: ["gpt-5.4", "gpt-5.4-mini", "gpt-5.5", "gpt-6-luna", "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra"],
  mimo: [AGENT_MODELS.mimo],
};
