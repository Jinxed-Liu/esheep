import { createClient } from "@supabase/supabase-js";

export class AssistantAuthorizationError extends Error {
  constructor(message, status = 401, code = "UNAUTHORIZED") {
    super(message);
    this.name = "AssistantAuthorizationError";
    this.status = status;
    this.code = code;
  }
}

export function bearerToken(request) {
  const authorization = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(authorization.trim());
  if (!match?.[1]) throw new AssistantAuthorizationError("请重新登录后再使用助手。", 401, "MISSING_BEARER_TOKEN");
  return match[1].trim();
}

export async function verifyFarmAccess({ request, farmID, config }) {
  const accessToken = bearerToken(request);
  if (!farmID) throw new AssistantAuthorizationError("缺少牧场标识。", 400, "MISSING_FARM_ID");

  const client = createClient(config.supabaseURL, config.supabasePublishableKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
  const { data: userData, error: userError } = await client.auth.getUser(accessToken);
  if (userError || !userData.user) {
    throw new AssistantAuthorizationError("登录状态已失效，请重新登录。", 401, "INVALID_SESSION");
  }

  const { data: accessRows, error: accessError } = await client.rpc("list_my_active_farm_access");
  if (accessError) {
    throw new AssistantAuthorizationError("暂时无法核对牧场权限。", 502, "FARM_ACCESS_LOOKUP_FAILED");
  }
  const membership = (accessRows ?? []).find((row) => String(row.farm_id) === String(farmID));
  if (!membership) {
    throw new AssistantAuthorizationError("当前账号无权访问这个牧场。", 403, "FARM_ACCESS_DENIED");
  }
  return { userID: userData.user.id, membership };
}
