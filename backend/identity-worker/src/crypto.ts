import { APIError, AccessClaims, Env } from "./types";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function base64URL(data: ArrayBuffer | Uint8Array): string {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

export function decodeBase64URL(value: string): ArrayBuffer {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}

const arrayBuffer = (bytes: Uint8Array): ArrayBuffer => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;

export async function sha256(value: string | Uint8Array): Promise<string> {
  const data = typeof value === "string" ? encoder.encode(value) : value;
  return base64URL(await crypto.subtle.digest("SHA-256", arrayBuffer(data)));
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", arrayBuffer(encoder.encode(secret)), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

export async function signAccessToken(claims: AccessClaims, secret: string): Promise<string> {
  const header = base64URL(encoder.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const payload = base64URL(encoder.encode(JSON.stringify(claims)));
  const input = `${header}.${payload}`;
  const signature = await crypto.subtle.sign("HMAC", await hmacKey(secret), arrayBuffer(encoder.encode(input)));
  return `${input}.${base64URL(signature)}`;
}

export async function verifyAccessToken(token: string, secret: string): Promise<AccessClaims> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new APIError(401, "invalid_access_token", "Access token 格式无效。");
  const [header, payload, signature] = parts as [string, string, string];
  const valid = await crypto.subtle.verify("HMAC", await hmacKey(secret), decodeBase64URL(signature), arrayBuffer(encoder.encode(`${header}.${payload}`)));
  if (!valid) throw new APIError(401, "invalid_access_token", "Access token 签名无效。");
  const claims = JSON.parse(decoder.decode(decodeBase64URL(payload))) as AccessClaims;
  const now = Math.floor(Date.now() / 1000);
  if (claims.exp <= now || claims.iss !== "esheep-next-identity" || claims.aud !== "esheep-next-ios") {
    throw new APIError(401, "expired_access_token", "Access token 已过期或受众无效。");
  }
  return claims;
}

export function randomToken(byteCount = 32): string {
  const bytes = new Uint8Array(byteCount);
  crypto.getRandomValues(bytes);
  return base64URL(bytes);
}

export async function derivePasswordHash(password: string, salt: string, iterations: number): Promise<string> {
  const material = await crypto.subtle.importKey(
    "raw",
    arrayBuffer(encoder.encode(password)),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: decodeBase64URL(salt), iterations },
    material,
    256,
  );
  return base64URL(bits);
}

export function constantTimeEqual(left: string, right: string): boolean {
  const leftBytes = encoder.encode(left);
  const rightBytes = encoder.encode(right);
  let difference = leftBytes.length ^ rightBytes.length;
  const length = Math.max(leftBytes.length, rightBytes.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }
  return difference === 0;
}

export async function encryptCredential(plainText: string, base64Key: string): Promise<{ cipherText: string; iv: string }> {
  const keyBytes = Uint8Array.from(atob(base64Key), (character) => character.charCodeAt(0));
  if (keyBytes.byteLength !== 32) throw new APIError(500, "invalid_encryption_key", "凭据加密密钥必须为 32 字节。");
  const key = await crypto.subtle.importKey("raw", arrayBuffer(keyBytes), "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv: arrayBuffer(iv) }, key, arrayBuffer(encoder.encode(plainText)));
  return { cipherText: base64URL(encrypted), iv: base64URL(iv) };
}

export async function decryptCredential(cipherText: string, iv: string, base64Key: string): Promise<string> {
  const keyBytes = Uint8Array.from(atob(base64Key), (character) => character.charCodeAt(0));
  const key = await crypto.subtle.importKey("raw", arrayBuffer(keyBytes), "AES-GCM", false, ["decrypt"]);
  const decrypted = await crypto.subtle.decrypt({ name: "AES-GCM", iv: decodeBase64URL(iv) }, key, decodeBase64URL(cipherText));
  return decoder.decode(decrypted);
}

function pemBody(pem: string): ArrayBuffer {
  const normalized = pem.replace(/\\n/g, "\n");
  const body = normalized.replace(/-----BEGIN [^-]+-----/g, "").replace(/-----END [^-]+-----/g, "").replace(/\s/g, "");
  return arrayBuffer(Uint8Array.from(atob(body), (character) => character.charCodeAt(0)));
}

export async function signES256JWS(payloadObject: unknown, env: Env, typ = "JWT"): Promise<string> {
  const header = base64URL(encoder.encode(JSON.stringify({ alg: "ES256", kid: env.CAPABILITY_SIGNING_KEY_ID, typ })));
  const payload = base64URL(encoder.encode(JSON.stringify(payloadObject)));
  const key = await crypto.subtle.importKey("pkcs8", pemBody(env.CAPABILITY_SIGNING_PRIVATE_KEY), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, arrayBuffer(encoder.encode(`${header}.${payload}`)));
  return `${header}.${payload}.${base64URL(signature)}`;
}

export async function appleClientSecret(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = base64URL(encoder.encode(JSON.stringify({ alg: "ES256", kid: env.APPLE_KEY_ID, typ: "JWT" })));
  const payload = base64URL(encoder.encode(JSON.stringify({
    iss: env.APPLE_TEAM_ID,
    iat: now,
    exp: now + 300,
    aud: "https://appleid.apple.com",
    sub: env.APPLE_CLIENT_ID,
  })));
  const key = await crypto.subtle.importKey("pkcs8", pemBody(env.APPLE_PRIVATE_KEY), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, arrayBuffer(encoder.encode(`${header}.${payload}`)));
  return `${header}.${payload}.${base64URL(signature)}`;
}
