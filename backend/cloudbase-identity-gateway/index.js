const { createHash } = require("node:crypto");
const { EventEmitter } = require("node:events");
const { Readable } = require("node:stream");
const {
  decryptAppleRefreshToken,
  encryptAppleRefreshToken,
  exchangeAppleAuthorizationCode,
  revokeAppleRefreshToken,
  signInAppleWithCloudBase,
  verifyAppleIdentityToken,
} = require("./apple-auth");
const { APIError, createCloudBaseService } = require("./collaboration-service");

const jsonHeaders = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };

function jsonResponse(response, status, value) {
  response.writeHead(status, jsonHeaders);
  response.end(value === undefined ? undefined : JSON.stringify(value));
}

function normalizePath(pathname) {
  const index = pathname.indexOf("/v1/");
  return index >= 0 ? pathname.slice(index) : pathname;
}

async function readJSON(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  if (chunks.length === 0) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { throw new APIError(400, "invalid_json", "请求 JSON 无效。"); }
}

async function cloudBaseRequest(fetchImpl, baseURL, path, value, headers = {}, method = "POST") {
  const options = {
    method,
    headers: { "content-type": "application/json", accept: "application/json", ...headers },
  };
  if (value !== undefined) options.body = JSON.stringify(value);
  const response = await fetchImpl(new URL(path, baseURL), options);
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new APIError(response.status, data.error || data.code || "cloudbase_auth_failed", data.error_description || data.message || "腾讯云身份认证未完成。");
  return data;
}

function stableAccountID(subject) {
  const hex = createHash("sha256").update(`cloudbase:${subject}`).digest("hex").slice(0, 32).split("");
  hex[12] = "5";
  hex[16] = ((parseInt(hex[16], 16) & 3) | 8).toString(16);
  const value = hex.join("");
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
}

function shapeCloudBaseSession(token, account) {
  const issuedAt = Math.floor(Date.now() / 1000);
  return {
    accessToken: token.access_token,
    accessExpiresAt: issuedAt + Number(token.expires_in || 7200),
    refreshToken: token.refresh_token,
    refreshExpiresAt: issuedAt + Number(token.refresh_expires_in || 2592000),
    accountID: account.accountID,
    displayName: account.displayName || "eSheep+ 用户",
  };
}

function clientRateIdentity(request, env) {
  if (!env.RATE_LIMIT_HASH_SALT) throw new APIError(503, "rate_limit_not_configured", "身份服务安全配置不完整。");
  const source = request.headers["x-esheep-source-ip"] || request.headers["x-real-ip"] || request.headers["x-forwarded-for"] || "unknown";
  return createHash("sha256").update(`${env.RATE_LIMIT_HASH_SALT}:${String(source).split(",")[0].trim()}`).digest("hex");
}

function authorization(request) {
  return request.headers.authorization || request.headers.Authorization || "";
}

async function authenticate(fetchImpl, env, request, service) {
  const bearer = authorization(request);
  if (!bearer.startsWith("Bearer ")) throw new APIError(401, "missing_access_token", "缺少 Access Token。");
  const token = await cloudBaseRequest(fetchImpl, env.CLOUDBASE_AUTH_BASE_URL, "/auth/v1/token/introspect", undefined, { authorization: bearer }, "GET");
  if (!token.sub) throw new APIError(401, "revoked_session", "会话已撤销或过期。");
  const accountID = stableAccountID(token.sub);
  await service.ensureAccount(accountID);
  return { accountID, bearer };
}

async function route({ request, pathname, fetchImpl, env, service }) {
  if (request.method === "GET" && pathname === "/v1/health") return [200, await service.health()];
  if (request.method === "POST" && pathname === "/v1/auth/apple") {
    await service.consumeRateLimit("apple_login", clientRateIdentity(request, env), 10, 15 * 60);
    const input = await readJSON(request);
    try {
      const claims = await verifyAppleIdentityToken(fetchImpl, env, input.identityToken, input.nonce);
      const refreshToken = await exchangeAppleAuthorizationCode(fetchImpl, env, input.authorizationCode);
      const token = await signInAppleWithCloudBase(fetchImpl, env, claims.sub);
      const account = await service.ensureAccount(stableAccountID(token.sub), String(input.displayName || "").trim());
      await service.recordAppleBinding(
        account.accountID,
        createHash("sha256").update(claims.sub).digest("hex"),
        encryptAppleRefreshToken(env, refreshToken)
      );
      return [200, shapeCloudBaseSession(token, account)];
    } catch (error) {
      if (error instanceof APIError) throw error;
      console.error("Apple CloudBase authentication failed", error?.message || error);
      throw new APIError(401, "apple_authentication_failed", "Apple 账户验证失败，请重试。");
    }
  }
  if (request.method === "POST" && pathname === "/v1/auth/verification") {
    await service.consumeRateLimit("email_verification", clientRateIdentity(request, env), 5, 15 * 60);
    const input = await readJSON(request);
    const email = String(input.email || "").trim().toLowerCase();
    if (!/^\S+@\S+\.\S+$/.test(email)) throw new APIError(400, "invalid_email", "请输入有效的邮箱地址。");
    const result = await cloudBaseRequest(fetchImpl, env.CLOUDBASE_AUTH_BASE_URL, "/auth/v1/verification", { email, target: "ANY" }, input.captchaToken ? { "x-captcha-token": String(input.captchaToken) } : {});
    return [200, { verificationID: result.verification_id, expiresIn: result.expires_in }];
  }
  if (request.method === "POST" && pathname === "/v1/auth/register") {
    await service.consumeRateLimit("registration", clientRateIdentity(request, env), 8, 15 * 60);
    const input = await readJSON(request);
    const email = String(input.email || "").trim().toLowerCase();
    const verified = await cloudBaseRequest(fetchImpl, env.CLOUDBASE_AUTH_BASE_URL, "/auth/v1/verification/verify", { verification_id: input.verificationID, verification_code: input.verificationCode });
    const token = await cloudBaseRequest(fetchImpl, env.CLOUDBASE_AUTH_BASE_URL, "/auth/v1/signup", { email, verification_token: verified.verification_token, username: input.username, password: input.password });
    const account = await service.ensureAccount(stableAccountID(token.sub), String(input.displayName || "").trim());
    return [201, shapeCloudBaseSession(token, account)];
  }
  if (request.method === "POST" && pathname === "/v1/auth/password") {
    await service.consumeRateLimit("password_login", clientRateIdentity(request, env), 10, 15 * 60);
    const input = await readJSON(request);
    const token = await cloudBaseRequest(fetchImpl, env.CLOUDBASE_AUTH_BASE_URL, "/auth/v1/signin", { username: input.username, password: input.password });
    const account = await service.ensureAccount(stableAccountID(token.sub));
    return [200, shapeCloudBaseSession(token, account)];
  }
  if (request.method === "POST" && pathname === "/v1/auth/refresh") {
    const input = await readJSON(request);
    const token = await cloudBaseRequest(fetchImpl, env.CLOUDBASE_AUTH_BASE_URL, "/auth/v1/token", { grant_type: "refresh_token", refresh_token: input.refreshToken });
    const account = await service.ensureAccount(stableAccountID(token.sub));
    return [200, shapeCloudBaseSession(token, account)];
  }

  const auth = await authenticate(fetchImpl, env, request, service);
  if (request.method === "POST" && pathname === "/v1/auth/logout") {
    await cloudBaseRequest(fetchImpl, env.CLOUDBASE_AUTH_BASE_URL, "/auth/v1/logout", {}, { authorization: auth.bearer }).catch(() => undefined);
    return [204];
  }
  if (request.method === "POST" && pathname === "/v1/devices/register") return [200, await service.registerDevice(auth.accountID, await readJSON(request))];
  const device = pathname.match(/^\/v1\/devices\/([^/]+)$/);
  if (request.method === "DELETE" && device) { await service.revokeDevice(auth.accountID, device[1]); return [204]; }
  if (request.method === "POST" && pathname === "/v1/farms/register") return [201, await service.registerFarm(auth.accountID, await readJSON(request))];
  const activateFarm = pathname.match(/^\/v1\/farms\/([^/]+)\/activate$/);
  if (request.method === "POST" && activateFarm) return [200, await service.activateFarm(auth.accountID, activateFarm[1])];
  if (request.method === "POST" && pathname === "/v1/invites") return [201, await service.createInvite(auth.accountID, await readJSON(request))];
  if (request.method === "POST" && pathname === "/v1/invites/redeem") return [200, await service.redeemInvite(auth.accountID, await readJSON(request))];
  const invite = pathname.match(/^\/v1\/invites\/([^/]+)\/confirm$/);
  if (request.method === "POST" && invite) return [200, await service.confirmInvite(auth.accountID, invite[1], await readJSON(request))];
  const member = pathname.match(/^\/v1\/members\/([^/]+)$/);
  if (request.method === "PATCH" && member) return [200, await service.changeMemberRole(auth.accountID, member[1], await readJSON(request))];
  if (request.method === "DELETE" && member) { await service.removeMember(auth.accountID, member[1], await readJSON(request)); return [204]; }
  if (request.method === "POST" && pathname === "/v1/capabilities/issue") return [200, await service.issueCapability(auth.accountID, await readJSON(request))];
  const snapshot = pathname.match(/^\/v1\/farms\/([^/]+)\/security-snapshot$/);
  if (request.method === "GET" && snapshot) return [200, await service.securitySnapshot(auth.accountID, snapshot[1])];
  if (request.method === "GET" && pathname === "/v1/account/status") return [200, await service.accountStatus(auth.accountID)];
  if (request.method === "POST" && pathname === "/v1/account/delete") {
    const credential = await service.appleCredential(auth.accountID);
    if (credential?.encryptedRefreshToken) {
      try {
        const refreshToken = decryptAppleRefreshToken(env, credential.encryptedRefreshToken);
        await revokeAppleRefreshToken(fetchImpl, env, refreshToken);
      } catch (error) {
        console.error("Apple token revocation failed", error?.message || error);
        throw new APIError(503, "apple_revocation_failed", "Apple 登录授权撤销失败，账户尚未删除，请稍后重试。");
      }
    }
    const result = await service.deleteAccount(auth.accountID);
    await cloudBaseRequest(fetchImpl, env.CLOUDBASE_AUTH_BASE_URL, "/auth/v1/user/me", undefined, { authorization: auth.bearer }, "DELETE");
    return [200, result];
  }
  throw new APIError(404, "route_not_found", "接口不存在。");
}

function createHandler({ fetchImpl = fetch, env = process.env, collaborationService } = {}) {
  let service = collaborationService;
  return async function handler(request, response) {
    try {
      if (!env.CLOUDBASE_AUTH_BASE_URL) throw new APIError(503, "gateway_not_configured", "大陆身份网关尚未完成配置。");
      service ||= createCloudBaseService(env);
      const url = new URL(request.url, "http://localhost");
      const result = await route({ request, pathname: normalizePath(url.pathname), fetchImpl, env, service });
      jsonResponse(response, result[0], result[1]);
    } catch (error) {
      if (!error.status || Number(error.status) >= 500) console.error(error);
      jsonResponse(response, Number(error.status) || 500, { error: { code: error.code || "gateway_error", message: error.message || "大陆身份网关发生内部错误。" } });
    }
  };
}

async function main(event) {
  const rawBody = event?.body ? Buffer.from(event.body, event.isBase64Encoded ? "base64" : "utf8") : undefined;
  const request = Readable.from(rawBody ? [rawBody] : []);
  request.url = event?.path || event?.requestContext?.path || "/";
  request.method = event?.httpMethod || event?.requestContext?.httpMethod || "GET";
  request.headers = Object.fromEntries(Object.entries(event?.headers || {}).map(([name, value]) => [name.toLowerCase(), value]));
  const sourceIP = event?.requestContext?.identity?.sourceIp || event?.requestContext?.http?.sourceIp;
  if (sourceIP) request.headers["x-esheep-source-ip"] = sourceIP;
  const response = new EventEmitter();
  response.statusCode = 200;
  response.headers = {};
  response.chunks = [];
  response.writeHead = (statusCode, headers = {}) => { response.statusCode = statusCode; response.headers = headers; };
  const completed = new Promise((resolve, reject) => {
    response.end = (chunk) => { if (chunk) response.chunks.push(Buffer.from(chunk)); resolve(); };
    response.destroy = reject;
  });
  await createHandler()(request, response);
  await completed;
  return { statusCode: response.statusCode, headers: response.headers, body: Buffer.concat(response.chunks).toString("utf8"), isBase64Encoded: false };
}

module.exports = { clientRateIdentity, createHandler, main, shapeCloudBaseSession, stableAccountID };
