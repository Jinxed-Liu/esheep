import { APIError, Env } from "./types";
import { appleClientSecret, decodeBase64URL } from "./crypto";

const decoder = new TextDecoder();

interface AppleTokenHeader { alg: string; kid: string }
interface AppleTokenClaims {
  iss: string;
  aud: string | string[];
  exp: number;
  iat: number;
  sub: string;
  nonce?: string;
}

interface AppleJSONWebKey extends JsonWebKey { kid?: string }
interface AppleKeySet { keys: AppleJSONWebKey[] }

/// Sign in with Apple receives the SHA-256 nonce as lower-case hexadecimal.
/// `sha256` in crypto.ts intentionally returns Base64URL for local token and
/// credential storage, so it must not be used for this protocol field.
export async function appleNonceDigest(rawNonce: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(rawNonce)));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function verifyAppleIdentityToken(identityToken: string, rawNonce: string, env: Env): Promise<AppleTokenClaims> {
  const parts = identityToken.split(".");
  if (parts.length !== 3) throw new APIError(401, "invalid_apple_token", "Apple identity token 格式无效。");
  const [encodedHeader, encodedPayload, encodedSignature] = parts as [string, string, string];
  const header = JSON.parse(decoder.decode(decodeBase64URL(encodedHeader))) as AppleTokenHeader;
  const claims = JSON.parse(decoder.decode(decodeBase64URL(encodedPayload))) as AppleTokenClaims;
  if (header.alg !== "RS256") throw new APIError(401, "invalid_apple_algorithm", "Apple token 算法无效。");

  const response = await fetch("https://appleid.apple.com/auth/keys", { cf: { cacheTtl: 3600, cacheEverything: true } });
  if (!response.ok) throw new APIError(503, "apple_keys_unavailable", "暂时无法取得 Apple 公钥。");
  const keySet = await response.json<AppleKeySet>();
  const jwk = keySet.keys.find((key) => key.kid === header.kid);
  if (!jwk) throw new APIError(401, "unknown_apple_key", "Apple token 使用了未知密钥。");
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const signingBytes = new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`);
  const signingData = signingBytes.buffer.slice(signingBytes.byteOffset, signingBytes.byteOffset + signingBytes.byteLength) as ArrayBuffer;
  const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, decodeBase64URL(encodedSignature), signingData);
  if (!valid) throw new APIError(401, "invalid_apple_signature", "Apple token 签名无效。");

  const now = Math.floor(Date.now() / 1000);
  const audienceValid = Array.isArray(claims.aud) ? claims.aud.includes(env.APPLE_CLIENT_ID) : claims.aud === env.APPLE_CLIENT_ID;
  if (claims.iss !== env.APPLE_ISSUER || !audienceValid || claims.exp <= now || claims.iat > now + 60) {
    throw new APIError(401, "invalid_apple_claims", "Apple token 的签发者、受众或有效期无效。");
  }
  if (!claims.nonce || claims.nonce !== await appleNonceDigest(rawNonce)) {
    throw new APIError(401, "invalid_nonce", "Apple 登录 nonce 不匹配。");
  }
  return claims;
}

export async function exchangeAuthorizationCode(code: string, env: Env): Promise<string> {
  const body = new URLSearchParams({
    client_id: env.APPLE_CLIENT_ID,
    client_secret: await appleClientSecret(env),
    code,
    grant_type: "authorization_code",
  });
  const response = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  const payload = await response.json<{ refresh_token?: string; error?: string }>();
  if (!response.ok || !payload.refresh_token) {
    throw new APIError(401, "authorization_code_exchange_failed", payload.error ?? "Apple authorization code 交换失败。");
  }
  return payload.refresh_token;
}

export async function revokeAppleToken(refreshToken: string, env: Env): Promise<void> {
  const body = new URLSearchParams({
    client_id: env.APPLE_CLIENT_ID,
    client_secret: await appleClientSecret(env),
    token: refreshToken,
    token_type_hint: "refresh_token",
  });
  const response = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!response.ok) throw new APIError(502, "apple_revocation_failed", "Apple token 撤销失败。");
}
