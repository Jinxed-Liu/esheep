// Conversation transcripts are browser-local UI history, never a farm projection.
// Images are sent with a turn only; history keeps filenames, not image bytes or keys.
export const ASSISTANT_SESSION_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function assistantHistoryKey(accountID, farmID) {
  return `esheepplus.assistant.history.v1:${encodeURIComponent(accountID ?? "unknown")}:${encodeURIComponent(farmID ?? "unknown")}`;
}

export function historyMessages(messages) {
  return messages.filter((message) => message && message.id !== "intro" && ["user", "assistant"].includes(message.role)).map((message) => ({
    id: String(message.id), role: message.role, text: String(message.text ?? ""),
    ...(message.error ? { error: true } : {}),
    ...(message.pending ? { text: message.text || "上次回答未完成，请重新提问。", error: true } : {}),
    ...(message.attachments?.length ? { attachments: message.attachments.map(({ name }) => ({ name: String(name ?? "图片") })) } : {}),
  }));
}

export function readAssistantHistory(key, storage) {
  const empty = { conversations: [], activeID: null, error: "" };
  try {
    const raw = (storage ?? globalThis.localStorage)?.getItem(key);
    if (!raw) return empty;
    const value = JSON.parse(raw);
    if (value.version !== 1 || !Array.isArray(value.conversations)) throw new Error("invalid history");
    const conversations = value.conversations.filter((item) => typeof item.id === "string" && Array.isArray(item.messages))
      .map((item) => ({
        id: item.id, title: String(item.title || "新对话"),
        sessionID: ASSISTANT_SESSION_PATTERN.test(item.sessionID ?? "") ? item.sessionID : null,
        updatedAt: Number(item.updatedAt) || 0, draft: String(item.draft ?? ""),
        messages: historyMessages(item.messages.filter((message) => ["assistant", "user"].includes(message.role))),
      }));
    return { conversations, activeID: conversations.some((item) => item.id === value.activeID) ? value.activeID : null, error: "" };
  } catch {
    return { ...empty, error: "无法读取此浏览器的聊天记录，原记录未被覆盖。" };
  }
}

export function writeAssistantHistory(key, conversations, activeID, storage) {
  try {
    (storage ?? globalThis.localStorage).setItem(key, JSON.stringify({ version: 1, activeID, conversations: conversations.map((item) => ({
      id: item.id, title: item.title, sessionID: item.sessionID, updatedAt: item.updatedAt,
      draft: item.draft ?? "", messages: historyMessages(item.messages),
    })) }));
    return "";
  } catch {
    return "聊天记录暂时无法保存在此浏览器，请保留当前页面。";
  }
}

export function conversationTitle(messages) {
  return messages.find((message) => message.role === "user")?.text?.replace(/\s+/g, " ").trim().slice(0, 36) || "新对话";
}

export function conversationGroup(updatedAt, now = Date.now()) {
  const today = new Date(now); today.setHours(0, 0, 0, 0);
  return updatedAt >= today.getTime() ? "今天" : "最近";
}
