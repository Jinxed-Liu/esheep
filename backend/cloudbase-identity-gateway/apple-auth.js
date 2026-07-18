const {
  createCipheriv,
  createDecipheriv,
  createHash,
  createPublicKey,
  randomBytes,
  sign,
  verify,
} = require("node:crypto");

const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys";
const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
const KEY_CACHE_TTL_MS = 6 * 60 * 60 * 1000;

let cachedAppleKeys;
let cachedAppleKeysAt = 0;

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function jsonPart(value) {
  return base64url(JSON.stringify(value));
}

function parseJWT(value) {
  const parts = String(value || "").split(".");
  if (parts.length !== 3) throw new Error("invalid_apple_identity_token");
  try {
    return {
      encodedHeader: parts[0],
      encodedPayload: parts[1],
      signature: Buffer.from(parts[2], "base64url"),
      header: JSON.parse(Buffer.from(parts[0], "base64url").toString("utf8")),
      payload: JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8")),
    };
  } catch {
    throw new Error("invalid_apple_identity_token");
  }
}

async function appleKeys(fetchImpl) {
  if (cachedAppleKeys && Date.now() - cachedAppleKeysAt < KEY_CACHE_TTL_MS) return cachedAppleKeys;
  const response = await fetchImpl(APPLE_KEYS_URL, { headers: { accept: "application/json" } });
  if (!response.ok) throw new Error("apple_keys_unavailable");
  const value = await response.json();
  if (!Array.isArray(value.keys)) throw new Error("apple_keys_unavailable");
  cachedAppleKeys = value.keys;
  cachedAppleKeysAt = Date.now();
  return cachedAppleKeys;
}

function requireAppleConfiguration(env) {
  for (const name of ["APPLE_CLIENT_ID", "APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY"]) {
    if (!env[name]) throw new Error(`missing_${name.toLowerCase()}`);
  }
}

async function verifyAppleIdentityToken(fetchImpl, env, identityToken, rawNonce) {
  requireAppleConfiguration(env);
  const token = parseJWT(identityToken);
  if (token.header.alg !== "RS256" || !token.header.kid) throw new Error("invalid_apple_identity_token");
  const key = (await appleKeys(fetchImpl)).find((item) => item.kid === token.header.kid && item.kty === "RSA");
  if (!key) throw new Error("apple_signing_key_not_found");
  const signed = Buffer.from(`${token.encodedHeader}.${token.encodedPayload}`);
  if (!verify("RSA-SHA256", signed, createPublicKey({ key, format: "jwk" }), token.signature)) {
    throw new Error("invalid_apple_identity_token");
  }
  const now = Math.floor(Date.now() / 1000);
  const audiences = Array.isArray(token.payload.aud) ? token.payload.aud : [token.payload.aud];
  const expectedNonce = createHash("sha256").update(String(rawNonce || "")).digest("hex");
  if (token.payload.iss !== APPLE_ISSUER ||
      !audiences.includes(env.APPLE_CLIENT_ID) ||
      !token.payload.sub ||
      Number(token.payload.exp || 0) <= now ||
      Number(token.payload.iat || 0) > now + 300 ||
      token.payload.nonce !== expectedNonce) {
    throw new Error("invalid_apple_identity_claims");
  }
  return token.payload;
}

function appleClientSecret(env, nowSeconds = Math.floor(Date.now() / 1000)) {
  requireAppleConfiguration(env);
  const header = jsonPart({ alg: "ES256", kid: env.APPLE_KEY_ID });
  const payload = jsonPart({
    iss: env.APPLE_TEAM_ID,
    iat: nowSeconds,
    exp: nowSeconds + 15 * 60,
    aud: APPLE_ISSUER,
    sub: env.APPLE_CLIENT_ID,
  });
  const content = `${header}.${payload}`;
  const signature = sign("sha256", Buffer.from(content), {
    key: String(env.APPLE_PRIVATE_KEY).replace(/\\n/g, "\n"),
    dsaEncoding: "ieee-p1363",
  });
  return `${content}.${base64url(signature)}`;
}

async function exchangeAppleAuthorizationCode(fetchImpl, env, authorizationCode) {
  if (!authorizationCode) throw new Error("missing_apple_authorization_code");
  const body = new URLSearchParams({
    client_id: env.APPLE_CLIENT_ID,
    client_secret: appleClientSecret(env),
    code: authorizationCode,
    grant_type: "authorization_code",
  });
  const response = await fetchImpl(APPLE_TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body,
  });
  const value = await response.json().catch(() => ({}));
  if (!response.ok || value.error) throw new Error(value.error || "apple_authorization_code_exchange_failed");
  return value.refresh_token || null;
}

function createCloudBaseCustomTicket(env, uid, nowMilliseconds = Date.now()) {
  for (const name of ["CLOUDBASE_ENV_ID", "CLOUDBASE_CUSTOM_LOGIN_KEY_ID", "CLOUDBASE_CUSTOM_LOGIN_PRIVATE_KEY"]) {
    if (!env[name]) throw new Error(`missing_${name.toLowerCase()}`);
  }
  if (!/^[a-zA-Z0-9_\-#@~=*(){}[\]:.,<>+]{4,32}$/.test(uid)) throw new Error("invalid_custom_login_uid");
  const header = jsonPart({ alg: "RS256", typ: "JWT" });
  const payload = jsonPart({
    alg: "RS256",
    env: env.CLOUDBASE_ENV_ID,
    iat: nowMilliseconds,
    exp: nowMilliseconds + 10 * 60 * 1000,
    uid,
    refresh: 60 * 60 * 1000,
    expire: nowMilliseconds + 30 * 24 * 60 * 60 * 1000,
  });
  const content = `${header}.${payload}`;
  const signature = sign("RSA-SHA256", Buffer.from(content), String(env.CLOUDBASE_CUSTOM_LOGIN_PRIVATE_KEY).replace(/\\n/g, "\n"));
  return `${env.CLOUDBASE_CUSTOM_LOGIN_KEY_ID}/@@/${content}.${base64url(signature)}`;
}

async function signInAppleWithCloudBase(fetchImpl, env, appleSubject) {
  const uid = `apple_${createHash("sha256").update(appleSubject).digest("hex").slice(0, 24)}`;
  const ticket = createCloudBaseCustomTicket(env, uid);
  const response = await fetchImpl(new URL("/auth/v1/signin/custom", env.CLOUDBASE_AUTH_BASE_URL), {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({ provider_id: "custom", ticket }),
  });
  const value = await response.json().catch(() => ({}));
  if (!response.ok || !value.access_token || !value.sub) throw new Error(value.error || "cloudbase_apple_signin_failed");
  return value;
}

function encryptionKey(env) {
  const key = Buffer.from(String(env.APPLE_TOKEN_ENCRYPTION_KEY || ""), "base64");
  if (key.length !== 32) throw new Error("invalid_apple_token_encryption_key");
  return key;
}

function encryptAppleRefreshToken(env, refreshToken) {
  if (!refreshToken) return null;
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", encryptionKey(env), iv);
  const ciphertext = Buffer.concat([cipher.update(refreshToken, "utf8"), cipher.final()]);
  return {
    ciphertext: ciphertext.toString("base64"),
    iv: iv.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
  };
}

function decryptAppleRefreshToken(env, encrypted) {
  if (!encrypted) return null;
  const decipher = createDecipheriv("aes-256-gcm", encryptionKey(env), Buffer.from(encrypted.iv, "base64"));
  decipher.setAuthTag(Buffer.from(encrypted.tag, "base64"));
  return Buffer.concat([
    decipher.update(Buffer.from(encrypted.ciphertext, "base64")),
    decipher.final(),
  ]).toString("utf8");
}

async function revokeAppleRefreshToken(fetchImpl, env, refreshToken) {
  if (!refreshToken) return;
  const body = new URLSearchParams({
    client_id: env.APPLE_CLIENT_ID,
    client_secret: appleClientSecret(env),
    token: refreshToken,
    token_type_hint: "refresh_token",
  });
  const response = await fetchImpl(APPLE_REVOKE_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!response.ok) throw new Error("apple_token_revocation_failed");
}

module.exports = {
  appleClientSecret,
  createCloudBaseCustomTicket,
  decryptAppleRefreshToken,
  encryptAppleRefreshToken,
  exchangeAppleAuthorizationCode,
  revokeAppleRefreshToken,
  signInAppleWithCloudBase,
  verifyAppleIdentityToken,
};
