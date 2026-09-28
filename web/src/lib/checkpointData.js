// Checkpoint Data fields use a tagged JSON or Base64 envelope. Earlier v1
// candidates used a bare Base64 string; keep reading those as well.
export function decodeCheckpointData(value) {
  if (value && typeof value === "object" && !Array.isArray(value) &&
      Object.keys(value).length === 1 && Object.hasOwn(value, "json")) {
    return value.json;
  }
  const base64 = typeof value === "string" ? value :
    value && typeof value === "object" && !Array.isArray(value) &&
      Object.keys(value).length === 1 ? value.base64 : null;
  if (typeof base64 !== "string") {
    const error = new Error("牧场资料核对未通过，请刷新重试。数据字段格式不正确。");
    error.code = "CLOUD_V2_INTEGRITY";
    throw error;
  }
  try {
    const bytes = Uint8Array.from(atob(base64.replace(/\s/g, "")), (character) => character.charCodeAt(0));
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    const error = new Error("牧场资料核对未通过，请刷新重试。数据字段无法解码。");
    error.code = "CLOUD_V2_INTEGRITY";
    throw error;
  }
}
