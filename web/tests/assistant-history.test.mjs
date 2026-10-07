import assert from "node:assert/strict";
import test from "node:test";
import { assistantHistoryKey, conversationTitle, historyMessages, readAssistantHistory, writeAssistantHistory } from "../src/lib/assistantHistory.js";

function memoryStorage() {
  const values = new Map();
  return { getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) };
}
const sessionID = "12345678-1234-4123-8123-123456789abc";
test("conversation history survives reopening with per-conversation context and draft", () => {
  const storage = memoryStorage();
  const key = assistantHistoryKey("account", "farm");
  const conversations = [{ id: "first", title: "体重分析", sessionID, updatedAt: 100, draft: "待发送的问题", messages: [{ id: "u", role: "user", text: "查体重" }, { id: "a", role: "assistant", text: "已有记录" }] }, { id: "second", title: "另一对话", sessionID: null, updatedAt: 200, messages: [] }];
  assert.equal(writeAssistantHistory(key, conversations, "first", storage), "");
  const restored = readAssistantHistory(key, storage);
  assert.equal(restored.activeID, "first");
  assert.equal(restored.conversations[0].sessionID, sessionID);
  assert.equal(restored.conversations[0].draft, "待发送的问题");
  assert.deepEqual(restored.conversations[0].messages, conversations[0].messages);
  assert.equal(restored.conversations.length, 2);
  writeAssistantHistory(key, conversations, "unsent-new-chat", storage);
  assert.equal(readAssistantHistory(key, storage).activeID, null);
  assert.equal(readAssistantHistory(assistantHistoryKey("other", "farm"), storage).conversations.length, 0);
  assert.equal(readAssistantHistory(assistantHistoryKey("account", "other"), storage).conversations.length, 0);
  assert.notEqual(assistantHistoryKey("a:b", "c"), assistantHistoryKey("a", "b:c"));
});
test("history stores only transcript fields and image names, with interrupted responses readable", () => {
  const stored = historyMessages([{ id: "u", role: "user", text: "图片分析", apiKey: "secret", attachments: [{ id: "image", name: "羊.png", dataURL: "data:image/png;base64,private", mimeType: "image/png" }] }, { id: "a", role: "assistant", text: "", pending: true }]);
  assert.deepEqual(stored[0].attachments, [{ name: "羊.png" }]);
  assert.equal(stored[0].apiKey, undefined);
  assert.equal(stored[1].pending, undefined);
  assert.match(stored[1].text, /未完成/);
  assert.equal(stored[1].error, true);
});
test("invalid history and quota failures are reported without overwriting stored data", () => {
  const storage = memoryStorage(); storage.setItem("history", "broken-json");
  assert.match(readAssistantHistory("history", storage).error, /原记录未被覆盖/);
  assert.equal(storage.getItem("history"), "broken-json");
  assert.match(writeAssistantHistory("history", [], null, { setItem() { throw new Error("quota"); } }), /无法保存/);
});
test("untrusted session IDs are rejected, titles follow the first question", () => {
  const storage = memoryStorage();
  storage.setItem("history", JSON.stringify({ version: 1, activeID: "x", conversations: [{ id: "x", sessionID: "invalid", messages: [{ id: "u", role: "user", text: "查体重" }, { id: "x", role: "tool", text: "private" }] }] }));
  const restored = readAssistantHistory("history", storage);
  assert.equal(restored.conversations[0].sessionID, null);
  assert.equal(restored.conversations[0].messages.length, 1);
  assert.equal(conversationTitle([{ role: "user", text: "  近七日\n体重分析  " }]), "近七日 体重分析");
});
