const webOrigins = new Set([
  "https://staging.esheepplus.com",
  "https://app.esheepplus.com",
]);

export function checkpointCorsHeaders(origin) {
  if (!origin || !webOrigins.has(origin)) return null;
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
    "access-control-expose-headers": "x-esheep-service-version",
    "access-control-max-age": "600",
    vary: "Origin",
  };
}

export function withCheckpointCors(handler) {
  return async (request) => {
    const origin = request.headers.get("origin");
    const cors = checkpointCorsHeaders(origin);
    if (origin && !cors) return new Response(null, { status: 403, headers: { vary: "Origin" } });
    if (request.method === "OPTIONS") {
      return new Response(null, { status: cors ? 204 : 403, headers: cors ?? {} });
    }
    const response = await handler(request);
    for (const [name, value] of Object.entries(cors ?? {})) response.headers.set(name, value);
    return response;
  };
}
