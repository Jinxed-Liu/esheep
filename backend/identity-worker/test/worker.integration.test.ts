import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "../src/index";
import { sha256, signAccessToken } from "../src/crypto";
import { appleNonceDigest } from "../src/apple";

async function call(path: string, init?: RequestInit): Promise<Response> {
  return worker.fetch(new Request(`https://identity.test${path}`, init), env);
}

async function seedAccount(label: string): Promise<{ accountID: string; token: string; sessionID: string }> {
  const accountID = crypto.randomUUID();
  const sessionID = crypto.randomUUID();
  const timestamp = Math.floor(Date.now() / 1000);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO accounts (id, apple_subject_hash, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)")
      .bind(accountID, `apple-${label}-${accountID}`, label, timestamp, timestamp),
    env.DB.prepare("INSERT INTO sessions (id, account_id, refresh_token_hash, expires_at, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?)")
      .bind(sessionID, accountID, await sha256(`unused-${sessionID}`), timestamp + 3600, timestamp, timestamp),
  ]);
  const token = await signAccessToken({ sub: accountID, sid: sessionID, iat: timestamp, exp: timestamp + 1800, iss: "esheep-next-identity", aud: "esheep-next-ios" }, env.SESSION_SIGNING_SECRET);
  return { accountID, token, sessionID };
}

function authenticatedJSON(token: string, method: string, value?: unknown): RequestInit {
  const init: RequestInit = {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
  };
  if (value !== undefined) init.body = JSON.stringify(value);
  return init;
}

describe("Development Worker and D1 integration", () => {
  beforeEach(async () => {
    await env.DB.exec("DELETE FROM security_audit_events; DELETE FROM capability_certificates; DELETE FROM invites; DELETE FROM memberships; DELETE FROM farm_directories; DELETE FROM devices; DELETE FROM sessions; DELETE FROM apple_credentials; DELETE FROM accounts;");
  });

  it("uses the lower-case hexadecimal nonce digest required by Sign in with Apple", async () => {
    await expect(appleNonceDigest("eSheepNext-apple-nonce")).resolves.toBe(
      "a2f0cf34065527e259b94f8970fde7cc759092e965eb9a8b8c7c0cc2d96d9087",
    );
  });

  it("reports health only after a real D1 query", async () => {
    const response = await call("/v1/health");
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({ status: "ok", environment: "development", database: "reachable" });
  });

  it("registers a cross-platform account and signs in with normalized credentials", async () => {
    const registration = await call("/v1/auth/register", authenticatedJSON("", "POST", {
      username: "FarmOwner01",
      password: "secure-farm-2026",
      displayName: "测试场主",
    }));
    expect(registration.status).toBe(201);
    const registered = await registration.json<{ accountID: string; accessToken: string; displayName: string }>();
    expect(registered.displayName).toBe("测试场主");
    expect(registered.accessToken).not.toBe("");

    const login = await call("/v1/auth/password", authenticatedJSON("", "POST", {
      username: "farmowner01",
      password: "secure-farm-2026",
    }));
    expect(login.status).toBe(200);
    await expect(login.json()).resolves.toMatchObject({ accountID: registered.accountID, displayName: "测试场主" });
  });

  it("rejects duplicate usernames after Unicode and case normalization", async () => {
    const first = await call("/v1/auth/register", authenticatedJSON("", "POST", {
      username: "Owner.Name",
      password: "secure-farm-2026",
      displayName: "场主一",
    }));
    expect(first.status).toBe(201);
    const duplicate = await call("/v1/auth/register", authenticatedJSON("", "POST", {
      username: "owner.name",
      password: "another-farm-2026",
      displayName: "场主二",
    }));
    expect(duplicate.status).toBe(409);
  });

  it("locks password authentication after five failures", async () => {
    const registration = await call("/v1/auth/register", authenticatedJSON("", "POST", {
      username: "locked-owner",
      password: "secure-farm-2026",
      displayName: "锁定测试",
    }));
    expect(registration.status).toBe(201);
    for (let index = 0; index < 4; index += 1) {
      const response = await call("/v1/auth/password", authenticatedJSON("", "POST", {
        username: "locked-owner",
        password: "incorrect-2026",
      }));
      expect(response.status).toBe(401);
    }
    const locked = await call("/v1/auth/password", authenticatedJSON("", "POST", {
      username: "locked-owner",
      password: "incorrect-2026",
    }));
    expect(locked.status).toBe(429);
  });

  it("rotates a refresh session and rejects reuse of the old token", async () => {
    const accountID = crypto.randomUUID();
    const sessionID = crypto.randomUUID();
    const refreshToken = `refresh-${crypto.randomUUID()}`;
    const timestamp = Math.floor(Date.now() / 1000);
    await env.DB.batch([
      env.DB.prepare("INSERT INTO accounts (id, apple_subject_hash, display_name, created_at, updated_at) VALUES (?, ?, '轮换测试', ?, ?)").bind(accountID, `apple-${accountID}`, timestamp, timestamp),
      env.DB.prepare("INSERT INTO sessions (id, account_id, refresh_token_hash, expires_at, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?)").bind(sessionID, accountID, await sha256(refreshToken), timestamp + 3600, timestamp, timestamp),
    ]);
    const first = await call("/v1/auth/refresh", authenticatedJSON("", "POST", { refreshToken }));
    expect(first.status).toBe(200);
    const rotated = await first.json<{ refreshToken: string }>();
    expect(rotated.refreshToken).not.toBe(refreshToken);
    const replay = await call("/v1/auth/refresh", authenticatedJSON("", "POST", { refreshToken }));
    expect(replay.status).toBe(401);
  });

  it("revokes the current server session on logout", async () => {
    const account = await seedAccount("退出测试");
    const logout = await call("/v1/auth/logout", authenticatedJSON(account.token, "POST"));
    expect(logout.status).toBe(204);
    const session = await env.DB.prepare("SELECT revoked_at AS revokedAt FROM sessions WHERE id = ?")
      .bind(account.sessionID).first<{ revokedAt: number | null }>();
    expect(session?.revokedAt).toBeTypeOf("number");
    const reused = await call("/v1/account/status", authenticatedJSON(account.token, "GET"));
    expect(reused.status).toBe(401);
  });

  it("increments security generation only for a real role change", async () => {
    const owner = await seedAccount("场主");
    const member = await seedAccount("成员");
    const farmID = crypto.randomUUID();
    const register = await call("/v1/farms/register", authenticatedJSON(owner.token, "POST", { farmID, zoneName: `Farm_${farmID}`, shareRecordName: "cloudkit.zoneshare" }));
    expect(register.status).toBe(201);
    const timestamp = Math.floor(Date.now() / 1000);
    const memberID = crypto.randomUUID();
    await env.DB.prepare("INSERT INTO memberships (id, farm_id, account_id, role, status, created_at, updated_at) VALUES (?, ?, ?, 'worker', 'active', ?, ?)")
      .bind(memberID, farmID, member.accountID, timestamp, timestamp).run();
    const before = await env.DB.prepare("SELECT security_generation AS generation FROM farm_directories WHERE id = ?").bind(farmID).first<{ generation: number }>();
    const unchanged = await call(`/v1/members/${memberID}`, authenticatedJSON(owner.token, "PATCH", { farmID, role: "worker" }));
    expect(unchanged.status).toBe(200);
    const same = await env.DB.prepare("SELECT security_generation AS generation FROM farm_directories WHERE id = ?").bind(farmID).first<{ generation: number }>();
    expect(same?.generation).toBe(before?.generation);
    const changed = await call(`/v1/members/${memberID}`, authenticatedJSON(owner.token, "PATCH", { farmID, role: "administrator" }));
    expect(changed.status).toBe(200);
    const after = await env.DB.prepare("SELECT security_generation AS generation FROM farm_directories WHERE id = ?").bind(farmID).first<{ generation: number }>();
    expect(after?.generation).toBe((before?.generation ?? 0) + 1);
  });

  it("locks invite redemption after five failures in fifteen minutes", async () => {
    const member = await seedAccount("邀请码测试");
    for (let index = 0; index < 5; index += 1) {
      const response = await call("/v1/invites/redeem", authenticatedJSON(member.token, "POST", { code: "ABCDEFGH" }));
      expect(response.status).toBe(400);
    }
    const locked = await call("/v1/invites/redeem", authenticatedJSON(member.token, "POST", { code: "ABCDEFGH" }));
    expect(locked.status).toBe(429);
    await expect(locked.json()).resolves.toMatchObject({ error: { code: "invite_attempt_locked" } });
  });
});
