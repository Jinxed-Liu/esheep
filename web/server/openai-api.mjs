export const OPENAI_MODEL = "gpt-5.4";
export const OPENAI_CONSENT_VERSION = "2026-11-05";

export class OpenAIRequestError extends Error {
  constructor(message, status = 400, code = "OPENAI_INVALID_REQUEST") {
    super(message); this.status = status; this.code = code;
  }
}

export function validateOpenAIKey(value) {
  const key = String(value ?? "").trim();
  if (!/^sk-[A-Za-z0-9_-]{9,508}$/.test(key)) {
    throw new OpenAIRequestError("请输入你自己的 OpenAI API Key（sk- 开头）。", 400, "OPENAI_KEY_REQUIRED");
  }
  return key;
}

// Only ordinary Responses inference and local function tools are accepted.
// No stored response IDs, hosted tools, remote URLs, or caller-selected endpoint.
export function openAIPayload(body) {
  if (!Array.isArray(body.input) || !body.input.length || body.input.length > 200) throw new OpenAIRequestError("对话上下文过长或为空，请新建对话。");
  let images = 0;
  let textBytes = 0;
  const count = (value) => { textBytes += new TextEncoder().encode(String(value ?? "")).length; return value; };
  const input = body.input.map((item) => {
    if (item.type === "function_call") {
      if (typeof item.name !== "string" || typeof item.call_id !== "string" || typeof item.arguments !== "string") throw new OpenAIRequestError("工具调用格式无效。");
      return { type: item.type, name: item.name, call_id: item.call_id, arguments: count(item.arguments) };
    }
    if (item.type === "function_call_output") {
      if (typeof item.call_id !== "string" || typeof item.output !== "string") throw new OpenAIRequestError("工具结果格式无效。");
      return { type: item.type, call_id: item.call_id, output: count(item.output) };
    }
    if (item.type === "reasoning") {
      if (typeof item.id !== "string" || typeof item.encrypted_content !== "string") throw new OpenAIRequestError("推理上下文无效，请新建对话。");
      return { type: "reasoning", id: item.id, encrypted_content: count(item.encrypted_content), summary: [] };
    }
    if (!["user", "assistant"].includes(item.role)) throw new OpenAIRequestError("消息角色无效。");
    const content = typeof item.content === "string" ? [{ type: item.role === "assistant" ? "output_text" : "input_text", text: item.content }] : item.content;
    if (!Array.isArray(content)) throw new OpenAIRequestError("消息内容无效。");
    return { role: item.role, content: content.map((part) => {
      if (["input_text", "output_text"].includes(part.type) && typeof part.text === "string") return { type: item.role === "assistant" ? "output_text" : "input_text", text: count(part.text) };
      if (part.type === "input_image" && item.role === "user" && /^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/]+=*$/.test(part.image_url ?? "")) {
        images += 1; return { type: "input_image", image_url: part.image_url, detail: "auto" };
      }
      throw new OpenAIRequestError("仅支持文字和主动添加的 JPEG、PNG、WebP 图片。");
    }) };
  });
  const tools = body.tools ?? [];
  if (!Array.isArray(tools) || tools.length > 64 || tools.some((tool) => tool.type !== "function" || !/^[a-zA-Z0-9_-]{1,64}$/.test(tool.name ?? ""))) throw new OpenAIRequestError("工具定义无效。");
  count(body.instructions); count(JSON.stringify(tools));
  if (images > 4 || textBytes > 4_000_000) throw new OpenAIRequestError("上下文超过本次请求上限，请新建对话或减少附件。", 413);
  return {
    model: OPENAI_MODEL, store: false, stream: true,
    instructions: typeof body.instructions === "string" ? body.instructions : "",
    input, tools: tools.map(({ name, description, parameters }) => ({ type: "function", name, description, parameters, strict: false })),
    max_output_tokens: Math.min(8192, Math.max(128, Number(body.max_output_tokens) || 4096)),
    reasoning: { effort: ["none", "low", "medium", "high"].includes(body.reasoning?.effort) ? body.reasoning.effort : "medium", summary: "auto" },
  };
}

