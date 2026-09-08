import { createClient } from "@supabase/supabase-js";
import { listAccessibleFarms } from "../src/lib/farmAccess.js";

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
  // All three requests use the same bearer token and are independent. Do not
  // serialize the membership lookup behind the user lookup across regions.
  const [userResult, accessResult] = await Promise.allSettled([
    client.auth.getUser(accessToken), listAccessibleFarms(client),
  ]);
  const { data: userData, error: userError } = userResult.status === "fulfilled"
    ? userResult.value : { data: null, error: userResult.reason };
  if (userError || !userData?.user) {
    throw new AssistantAuthorizationError("登录状态已失效，请重新登录。", 401, "INVALID_SESSION");
  }

  if (accessResult.status !== "fulfilled") {
    throw new AssistantAuthorizationError("暂时无法核对牧场权限。", 502, "FARM_ACCESS_LOOKUP_FAILED");
  }
  const accessRows = accessResult.value;
  const membership = accessRows.find((row) => String(row.farm_id).toLowerCase() === String(farmID).toLowerCase());
  if (!membership) {
    throw new AssistantAuthorizationError("当前账号无权访问这个牧场。", 403, "FARM_ACCESS_DENIED");
  }
  return { userID: userData.user.id, membership };
}
