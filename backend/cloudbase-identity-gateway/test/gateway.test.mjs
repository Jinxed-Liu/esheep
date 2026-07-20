import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { createHash, generateKeyPairSync, randomBytes, randomUUID, sign } from "node:crypto";
import { Readable } from "node:stream";
import test from "node:test";
import gateway from "../index.js";
import collaboration from "../collaboration-service.js";

const { createHandler, stableAccountID } = gateway;
const { CollaborationService, DocumentStore, signCapability } = collaboration;
const appleSigningKeys = generateKeyPairSync("rsa", { modulusLength: 2048 });
const appleClientKeys = generateKeyPairSync("ec", { namedCurve: "P-256" });
const customLoginKeys = generateKeyPairSync("rsa", { modulusLength: 2048 });
const env = {
  CLOUDBASE_AUTH_BASE_URL: "https://auth.example/",
  CLOUDBASE_ENV_ID: "development-example",
  CLOUDBASE_CUSTOM_LOGIN_KEY_ID: "custom-key-id",
  CLOUDBASE_CUSTOM_LOGIN_PRIVATE_KEY: customLoginKeys.privateKey.export({ type: "pkcs1", format: "pem" }),
  APPLE_CLIENT_ID: "com.sheepfarm.next.dev",
  APPLE_TEAM_ID: "TEAMID1234",
  APPLE_KEY_ID: "APPLEKEY1",
  APPLE_PRIVATE_KEY: appleClientKeys.privateKey.export({ type: "pkcs8", format: "pem" }),
  APPLE_TOKEN_ENCRYPTION_KEY: randomBytes(32).toString("base64"),
  RATE_LIMIT_HASH_SALT: "test-rate-limit-salt",
};

function request(path, body, method = body === undefined ? "GET" : "POST", token) {
  const stream = Readable.from(body === undefined ? [] : [Buffer.from(JSON.stringify(body))]);
  stream.url = path;
  stream.method = method;
  stream.headers = { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) };
  return stream;
}

function response() {
  const target = new EventEmitter();
  target.status = 0;
  target.chunks = [];
  target.writeHead = (status) => { target.status = status; };
  target.end = (chunk) => { if (chunk) target.chunks.push(Buffer.from(chunk)); target.emit("done"); };
  target.destroy = (error) => target.emit("error", error);
  return target;
}

async function invoke(handler, path, body, method, token) {
  const res = response();
  const done = new Promise((resolve, reject) => { res.once("done", resolve); res.once("error", reject); });
  await handler(request(path, body, method, token), res);
  await done;
  const text = Buffer.concat(res.chunks).toString("utf8");
  return { status: res.status, json: text ? JSON.parse(text) : undefined };
}

function fakeService(overrides = {}) {
  return {
    health: async () => ({ status: "ok", environment: "cloudbase-development", version: "0.3.3", database: "cloudbase-document" }),
    ensureAccount: async (accountID, displayName) => ({ accountID, displayName: displayName || "eSheep+ 用户" }),
    consumeRateLimit: async () => ({ remaining: 1 }),
    recordAppleBinding: async () => undefined,
    appleCredential: async () => null,
    updateAccountDisplayName: async (accountID, displayName) => ({ accountID, displayName }),
    ...overrides,
  };
}

test("registration creates the native CloudBase collaboration account", async () => {
  const ensured = [];
  const service = fakeService({ ensureAccount: async (accountID, displayName) => { ensured.push({ accountID, displayName }); return { accountID, displayName }; } });
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), init });
    if (String(url).endsWith("/verification/verify")) return Response.json({ verification_token: "verified" });
    return Response.json({ sub: "cloudbase-subject", access_token: "access", refresh_token: "refresh", expires_in: 7200 });
  };
  const result = await invoke(createHandler({ fetchImpl, env, collaborationService: service }), "/identity/v1/auth/register", {
    email: "Owner@Example.com", verificationID: "verification-id", verificationCode: "123456", username: "owner01", password: "secure-owner-2026", displayName: "测试场主",
  });
  assert.equal(result.status, 201);
  assert.equal("brokerAvailable" in result.json, false);
  assert.equal(result.json.accountID, stableAccountID("cloudbase-subject"));
  assert.deepEqual(ensured, [{ accountID: stableAccountID("cloudbase-subject"), displayName: "测试场主" }]);
  assert.equal(calls.some((call) => call.url.includes("worker")), false);
});

test("email verification is normalized and returned without creating an account", async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), body: JSON.parse(init.body) });
    return Response.json({ verification_id: "verification-id", expires_in: 600 });
  };
  const result = await invoke(createHandler({ fetchImpl, env, collaborationService: fakeService() }), "/identity/v1/auth/verification", { email: " Owner@Example.COM " });
  assert.deepEqual(result, { status: 200, json: { verificationID: "verification-id", expiresIn: 600 } });
  assert.equal(calls[0].body.email, "owner@example.com");
});

test("password login and refresh both return the compatible CloudBase session shape", async () => {
  const fetchImpl = async (url, init) => {
    const value = String(url);
    if (value.endsWith("/auth/v1/signin")) {
      assert.deepEqual(JSON.parse(init.body), { username: "owner01", password: "secure-owner-2026" });
      return Response.json({ sub: "password-subject", access_token: "access-1", refresh_token: "refresh-1", expires_in: 7200 });
    }
    if (value.endsWith("/auth/v1/token")) {
      assert.deepEqual(JSON.parse(init.body), { grant_type: "refresh_token", refresh_token: "refresh-1" });
      return Response.json({ sub: "password-subject", access_token: "access-2", refresh_token: "refresh-2", expires_in: 7200 });
    }
    throw new Error(`unexpected URL ${value}`);
  };
  const handler = createHandler({ fetchImpl, env, collaborationService: fakeService() });
  const login = await invoke(handler, "/identity/v1/auth/password", { username: "owner01", password: "secure-owner-2026" });
  const refresh = await invoke(handler, "/identity/v1/auth/refresh", { refreshToken: "refresh-1" });
  assert.equal(login.status, 200);
  assert.equal(login.json.accessToken, "access-1");
  assert.equal(refresh.status, 200);
  assert.equal(refresh.json.accessToken, "access-2");
  assert.equal(login.json.accountID, refresh.json.accountID);
});

test("logout introspects then revokes the current CloudBase session", async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push(String(url));
    if (String(url).endsWith("/auth/v1/token/introspect")) return Response.json({ sub: "logout-subject" });
    if (String(url).endsWith("/auth/v1/logout")) {
      assert.equal(init.headers.authorization, "Bearer access-token");
      return new Response(null, { status: 204 });
    }
    throw new Error(`unexpected URL ${url}`);
  };
  const result = await invoke(createHandler({ fetchImpl, env, collaborationService: fakeService() }), "/identity/v1/auth/logout", undefined, "POST", "access-token");
  assert.equal(result.status, 204);
  assert.equal(calls.length, 2);
});

test("document store treats a missing CloudBase document as an empty lookup", async () => {
  const database = {
    collection() {
      return {
        doc() {
          return {
            async get() {
              const error = new Error("Document not found");
              error.code = "DOCUMENT_NOT_FOUND";
              throw error;
            },
          };
        },
      };
    },
  };

  const store = new DocumentStore(database);
  assert.equal(await store.get("new-rate-limit-record"), null);
});

test("protected collaboration routes introspect the CloudBase access token", async () => {
  const accountID = stableAccountID("subject-1");
  const service = fakeService({ accountStatus: async (received) => ({ accountID: received, status: "active", memberships: [] }) });
  const fetchImpl = async (url, init) => {
    assert.ok(String(url).endsWith("/auth/v1/token/introspect"));
    assert.equal(init.headers.authorization, "Bearer access-token");
    return Response.json({ sub: "subject-1", token_type: "Bearer" });
  };
  const result = await invoke(createHandler({ fetchImpl, env, collaborationService: service }), "/identity/v1/account/status", undefined, "GET", "access-token");
  assert.deepEqual(result, { status: 200, json: { accountID, status: "active", memberships: [] } });
});

test("account profile update requires the current session and returns the normalized name", async () => {
  const accountID = stableAccountID("profile-subject");
  const updates = [];
  const service = fakeService({
    updateAccountDisplayName: async (...value) => {
      updates.push(value);
      return { accountID: value[0], displayName: "北山牧场" };
    },
  });
  const fetchImpl = async (url, init) => {
    assert.ok(String(url).endsWith("/auth/v1/token/introspect"));
    assert.equal(init.headers.authorization, "Bearer access-token");
    return Response.json({ sub: "profile-subject" });
  };
  const result = await invoke(createHandler({ fetchImpl, env, collaborationService: service }), "/identity/v1/account/profile", { displayName: "  北山牧场  " }, "PATCH", "access-token");
  assert.deepEqual(result, { status: 200, json: { accountID, displayName: "北山牧场" } });
  assert.deepEqual(updates, [[accountID, "  北山牧场  "]]);
});

function appleIdentityToken(rawNonce, subject = "apple-user-1") {
  const header = Buffer.from(JSON.stringify({ alg: "RS256", kid: "apple-test-key" })).toString("base64url");
  const payload = Buffer.from(JSON.stringify({
    iss: "https://appleid.apple.com",
    aud: env.APPLE_CLIENT_ID,
    sub: subject,
    iat: Math.floor(Date.now() / 1000),
    exp: Math.floor(Date.now() / 1000) + 600,
    nonce: createHash("sha256").update(rawNonce).digest("hex"),
  })).toString("base64url");
  const content = `${header}.${payload}`;
  const signature = sign("RSA-SHA256", Buffer.from(content), appleSigningKeys.privateKey).toString("base64url");
  return `${content}.${signature}`;
}

test("Apple sign-in verifies Apple and returns a native CloudBase session", async () => {
  const bindings = [];
  const service = fakeService({ recordAppleBinding: async (...value) => bindings.push(value) });
  const fetchImpl = async (url) => {
    const value = String(url);
    if (value === "https://appleid.apple.com/auth/keys") {
      return Response.json({ keys: [{ ...appleSigningKeys.publicKey.export({ format: "jwk" }), kid: "apple-test-key", alg: "RS256" }] });
    }
    if (value === "https://appleid.apple.com/auth/token") return Response.json({ refresh_token: "apple-refresh-token" });
    if (value.endsWith("/auth/v1/signin/custom")) {
      return Response.json({ sub: "cloudbase-apple-subject", access_token: "access", refresh_token: "refresh", expires_in: 7200 });
    }
    throw new Error(`unexpected URL ${value}`);
  };
  const rawNonce = "nonce-1";
  const result = await invoke(createHandler({ fetchImpl, env, collaborationService: service }), "/identity/v1/auth/apple", {
    identityToken: appleIdentityToken(rawNonce), authorizationCode: "authorization-code", nonce: rawNonce, displayName: "Apple 场主",
  });
  assert.equal(result.status, 200);
  assert.equal(result.json.accountID, stableAccountID("cloudbase-apple-subject"));
  assert.equal(bindings.length, 1);
  assert.equal(bindings[0][0], stableAccountID("cloudbase-apple-subject"));
  assert.ok(bindings[0][2].ciphertext);
});

test("Apple sign-in without a name does not send a fallback that can overwrite the account", async () => {
  const ensured = [];
  const service = fakeService({
    ensureAccount: async (accountID, displayName) => {
      ensured.push({ accountID, displayName });
      return { accountID, displayName: "已修改名称" };
    },
  });
  const fetchImpl = async (url) => {
    const value = String(url);
    if (value === "https://appleid.apple.com/auth/keys") return Response.json({ keys: [{ ...appleSigningKeys.publicKey.export({ format: "jwk" }), kid: "apple-test-key", alg: "RS256" }] });
    if (value === "https://appleid.apple.com/auth/token") return Response.json({ refresh_token: "apple-refresh-token" });
    if (value.endsWith("/auth/v1/signin/custom")) return Response.json({ sub: "cloudbase-apple-subject", access_token: "access", refresh_token: "refresh", expires_in: 7200 });
    throw new Error(`unexpected URL ${value}`);
  };
  const rawNonce = "nonce-without-name";
  const result = await invoke(createHandler({ fetchImpl, env, collaborationService: service }), "/identity/v1/auth/apple", {
    identityToken: appleIdentityToken(rawNonce), authorizationCode: "authorization-code", nonce: rawNonce,
  });
  assert.equal(result.status, 200);
  assert.equal(result.json.displayName, "已修改名称");
  assert.deepEqual(ensured, [{ accountID: stableAccountID("cloudbase-apple-subject"), displayName: "" }]);
});

test("Apple sign-in rejects a nonce mismatch without creating an account", async () => {
  const fetchImpl = async (url) => {
    if (String(url) === "https://appleid.apple.com/auth/keys") {
      return Response.json({ keys: [{ ...appleSigningKeys.publicKey.export({ format: "jwk" }), kid: "apple-test-key", alg: "RS256" }] });
    }
    throw new Error("must not exchange invalid identity");
  };
  const result = await invoke(createHandler({ fetchImpl, env, collaborationService: fakeService() }), "/identity/v1/auth/apple", {
    identityToken: appleIdentityToken("expected"), authorizationCode: "authorization-code", nonce: "wrong",
  });
  assert.equal(result.status, 401);
  assert.equal(result.json.error.code, "apple_authentication_failed");
});

class MemoryStore {
  constructor() { this.documents = new Map(); }
  async get(id) { return this.documents.get(id) || null; }
  async set(id, value) { this.documents.set(id, { ...value, _documentID: id }); return value; }
  async update(id, value) { this.documents.set(id, { ...this.documents.get(id), ...value }); }
  async remove(id) { this.documents.delete(id); }
  async find(where, limit = 1000) {
    return [...this.documents.values()].filter((item) => Object.entries(where).every(([name, value]) => item[name] === value)).slice(0, limit);
  }
  async transaction(operation) { return operation(this); }
}

test("identity rate limits fail closed after the configured request count", async () => {
  const service = new CollaborationService({ store: new MemoryStore(), env: {} });
  await service.consumeRateLimit("password_login", "client-1", 2, 900);
  await service.consumeRateLimit("password_login", "client-1", 2, 900);
  await assert.rejects(service.consumeRateLimit("password_login", "client-1", 2, 900), (error) => error.code === "rate_limited");
});

test("account display name is explicit, normalized, and never replaced by later login metadata", async () => {
  const service = new CollaborationService({ store: new MemoryStore(), env: {} });
  const accountID = randomUUID();
  await service.ensureAccount(accountID, "Apple 初始名称");
  const updated = await service.updateAccountDisplayName(accountID, "  北山牧场  ");
  const afterLogin = await service.ensureAccount(accountID, "Apple 后续名称");
  assert.deepEqual(updated, { accountID, displayName: "北山牧场" });
  assert.equal(afterLogin.displayName, "北山牧场");
  await assert.rejects(service.updateAccountDisplayName(accountID, "   "), (error) => error.code === "invalid_display_name");
  await assert.rejects(service.updateAccountDisplayName(accountID, "羊".repeat(41)), (error) => error.code === "invalid_display_name");
});

test("invite remains pending until owner confirmation and generation changes only on confirmation", async () => {
  const store = new MemoryStore();
  const service = new CollaborationService({ store, env: {} });
  const owner = "11111111-1111-5111-8111-111111111111";
  const worker = "22222222-2222-5222-8222-222222222222";
  const farmID = "33333333-3333-5333-8333-333333333333";
  await service.ensureAccount(owner, "场主");
  await service.ensureAccount(worker, "员工");
  await service.registerFarm(owner, { farmID, zoneName: `farm_${farmID}` });
  const invite = await service.createInvite(owner, { farmID, role: "worker" });
  const redeemed = await service.redeemInvite(worker, { code: invite.code });
  assert.equal(redeemed.membershipStatus, "pendingShareConfirmation");
  assert.equal((await service.securitySnapshot(owner, farmID)).generation, 1);
  await service.confirmInvite(owner, invite.inviteID, { shareParticipantRecordName: "participant-1" });
  const snapshot = await service.securitySnapshot(owner, farmID);
  assert.equal(snapshot.generation, 2);
  assert.equal(snapshot.members.find((item) => item.accountID === worker).status, "active");
});

test("provisioning farms issue owner capabilities but stay hidden until activation", async () => {
  const store = new MemoryStore();
  const service = new CollaborationService({ store, env: {} });
  const owner = "11111111-1111-5111-8111-111111111111";
  const farmID = "44444444-4444-5444-8444-444444444444";
  await service.ensureAccount(owner, "迁移场主");
  const registered = await service.registerFarm(owner, { farmID, zoneName: `farm_${farmID}`, status: "provisioning" });
  assert.equal(registered.status, "provisioning");
  assert.deepEqual((await service.accountStatus(owner)).memberships, []);
  const snapshot = await service.securitySnapshot(owner, farmID);
  assert.equal(snapshot.members.find((item) => item.accountID === owner).role, "owner");
  assert.equal((await service.activateFarm(owner, farmID)).status, "active");
  assert.equal((await service.accountStatus(owner)).memberships[0].farm_id, farmID);
  assert.equal((await service.activateFarm(owner, farmID)).status, "active");
});

test("farm identity is canonical across uppercase JSON and lowercase URL paths", async () => {
  const owner = randomUUID();
  const deviceID = randomUUID();
  const lowercaseFarmID = randomUUID();
  const uppercaseFarmID = lowercaseFarmID.toUpperCase();
  const { privateKey } = generateKeyPairSync("ec", {
    namedCurve: "P-256",
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
    publicKeyEncoding: { type: "spki", format: "pem" },
  });
  const service = new CollaborationService({ store: new MemoryStore(), env: {
    CAPABILITY_SIGNING_PRIVATE_KEY: privateKey,
    CAPABILITY_SIGNING_KEY_ID: "test-key",
  } });

  await service.registerDevice(owner, { deviceID, publicKeyJWK: { kty: "EC" }, displayName: "iPhone" });
  await service.registerFarm(owner, {
    farmID: uppercaseFarmID,
    zoneName: `Farm_${lowercaseFarmID}`,
    status: "provisioning",
  });

  assert.equal((await service.issueCapability(owner, { farmID: uppercaseFarmID, deviceID })).role, "owner");
  assert.equal((await service.securitySnapshot(owner, lowercaseFarmID)).farmID, lowercaseFarmID);
  assert.equal((await service.activateFarm(owner, lowercaseFarmID)).farmID, lowercaseFarmID);
});

test("capability certificate is an ES256 JWS with a 64-byte P1363 signature", () => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256", privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
  const certificate = signCapability({ sub: "account" }, privateKey, "development-2026-07");
  const [header, , signature] = certificate.split(".");
  assert.equal(JSON.parse(Buffer.from(header, "base64url")).alg, "ES256");
  assert.equal(Buffer.from(signature, "base64url").length, 64);
});
