export const hostedOrigin = "https://rnqrvthbunrzqtprquqx.supabase.co";
export const miniOrigin = "https://api.esheepplus.com";

export function backendState(environment) {
  // Existing standalone deployments have a pinned upstream and start on hosted.
  const state = environment.ESHEEP_BACKEND_STATE ?? "hosted";
  return ["hosted", "maintenance", "mini"].includes(state) ? state : null;
}

export function backendStatusResponse(request, environment) {
  const headers = { "cache-control": "no-store", "content-type": "application/json; charset=utf-8" };
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response(null, { status: 405, headers: { ...headers, allow: "GET, HEAD" } });
  }
  const state = backendState(environment);
  return new Response(request.method === "HEAD" ? null : JSON.stringify({ state }), {
    headers, status: state ? 200 : 503,
  });
}

export function isCloudRoute(rawPath) {
  const path = rawPath?.split("?")[0];
  return path === "/api/backend-status" || path?.startsWith("/api/cloud/");
}


export async function activeBackend(environment) {
  if (!environment.BACKEND_STATUS) return backendState(environment);
  try {
    const result = await environment.BACKEND_STATUS.fetch("https://app.esheepplus.com/api/backend-status");
    if (!result.ok) return null;
    const { state } = await result.json();
    return ["hosted", "maintenance", "mini"].includes(state) ? state : null;
  } catch {
    return null;
  }
}
