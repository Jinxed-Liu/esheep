import { exchangeAuthorizationCode, revokeAppleToken, verifyAppleIdentityToken } from "./apple";
import { constantTimeEqual, decryptCredential, derivePasswordHash, encryptCredential, randomToken, sha256, signAccessToken, signES256JWS, verifyAccessToken } from "./crypto";
import { capabilitiesForRole, generateInviteCode, isInviteRole } from "./policy";
import { APIError, AuthContext, Env, FarmRole } from "./types";

const jsonHeaders = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };

const json = (body: unknown, status = 200): Response => new Response(JSON.stringify(body), { status, headers: jsonHeaders });
const now = (): number => Math.floor(Date.now() / 1000);
const uuid = (): string => crypto.randomUUID();
const serviceVersion = "0.2.1-development";
const passwordLockSeconds = 900;
const maximumPasswordAttempts = 5;

function normalizeUsername(value: string): string {
  return value.normalize("NFKC").trim().toLocaleLowerCase("en-US");
}

function validateUsername(value: string): string {
  const normalized = normalizeUsername(value);
  if (!/^[\p{L}\p{N}._-]{3,32}$/u.test(normalized)) {
    throw new APIError(400, "invalid_username", "账号名必须为 3 至 32 位，可使用文字、数字、点、下划线或连字符。");
  }
  return normalized;
}

function validatePassword(value: string): string {
  if (value.length < 10 || value.length > 128 || !/[\p{L}]/u.test(value) || !/[\p{N}]/u.test(value)) {
    throw new APIError(400, "weak_password", "密码必须为 10 至 128 位，并同时包含文字和数字。");
  }
  return value;
}

function passwordIterations(env: Env): number {
  const configured = Number(env.PASSWORD_PBKDF2_ITERATIONS || 1000);
  return Number.isSafeInteger(configured) && configured >= 1000 ? configured : 1000;
}
async function body<T>(request: Request): Promise<T> {
  try { return await request.json<T>(); }
  catch { throw new APIError(400, "invalid_json", "请求 JSON 无效。"); }
}

async function authenticate(request: Request, env: Env): Promise<AuthContext> {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) throw new APIError(401, "missing_access_token", "缺少 Access Token。");
  const claims = await verifyAccessToken(authorization.slice(7), env.SESSION_SIGNING_SECRET);
  const session = await env.DB.prepare("SELECT id FROM sessions WHERE id = ? AND account_id = ? AND revoked_at IS NULL AND expires_at > ?")
    .bind(claims.sid, claims.sub, now()).first<{ id: string }>();
  if (!session) throw new APIError(401, "revoked_session", "会话已撤销或过期。");
  return { accountID: claims.sub, sessionID: claims.sid };
}

async function issueSession(accountID: string, env: Env): Promise<Record<string, unknown>> {
  const issuedAt = now();
  const sessionID = uuid();
  const refreshToken = randomToken();
  const refreshExpiresAt = issuedAt + Number(env.REFRESH_TOKEN_TTL_SECONDS || 2592000);
  await env.DB.prepare("INSERT INTO sessions (id, account_id, refresh_token_hash, expires_at, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(sessionID, accountID, await sha256(refreshToken), refreshExpiresAt, issuedAt, issuedAt).run();
  const accessExpiresAt = issuedAt + Number(env.ACCESS_TOKEN_TTL_SECONDS || 1800);
  const accessToken = await signAccessToken({ sub: accountID, sid: sessionID, iat: issuedAt, exp: accessExpiresAt, iss: "esheep-next-identity", aud: "esheep-next-ios" }, env.SESSION_SIGNING_SECRET);
  return { accessToken, accessExpiresAt, refreshToken, refreshExpiresAt, accountID };
}

async function authApple(request: Request, env: Env): Promise<Response> {
  const input = await body<{ identityToken: string; authorizationCode: string; nonce: string; displayName?: string }>(request);
  if (!input.identityToken || !input.authorizationCode || !input.nonce) throw new APIError(400, "missing_apple_credential", "Apple 登录凭据不完整。");
  const claims = await verifyAppleIdentityToken(input.identityToken, input.nonce, env);
  const tokenFingerprint = await sha256(input.identityToken);
  const replay = await env.DB.prepare("SELECT id FROM security_audit_events WHERE fingerprint = ?").bind(tokenFingerprint).first();
  if (replay) throw new APIError(409, "apple_token_replay", "该 Apple 登录凭据已使用。");

  const appleSubjectHash = await sha256(claims.sub);
  let account = await env.DB.prepare("SELECT id, display_name FROM accounts WHERE apple_subject_hash = ? AND status = 'active'")
    .bind(appleSubjectHash).first<{ id: string; display_name: string }>();
  const timestamp = now();
  if (!account) {
    account = { id: uuid(), display_name: input.displayName?.trim() || "Apple 账户" };
    await env.DB.prepare("INSERT INTO accounts (id, apple_subject_hash, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)")
      .bind(account.id, appleSubjectHash, account.display_name, timestamp, timestamp).run();
  }

  const refreshToken = await exchangeAuthorizationCode(input.authorizationCode, env);
  const encrypted = await encryptCredential(refreshToken, env.CREDENTIAL_ENCRYPTION_KEY);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO apple_credentials (account_id, encrypted_refresh_token, encryption_iv, apple_user_hash, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(account_id) DO UPDATE SET encrypted_refresh_token = excluded.encrypted_refresh_token, encryption_iv = excluded.encryption_iv, updated_at = excluded.updated_at")
      .bind(account.id, encrypted.cipherText, encrypted.iv, appleSubjectHash, timestamp),
    env.DB.prepare("INSERT INTO security_audit_events (id, account_id, event_type, fingerprint, detail_json, created_at) VALUES (?, ?, 'apple_auth_success', ?, '{}', ?)")
      .bind(uuid(), account.id, tokenFingerprint, timestamp),
  ]);
  return json({ ...(await issueSession(account.id, env)), displayName: account.display_name });
}

async function registerPasswordAccount(request: Request, env: Env): Promise<Response> {
  const input = await body<{ username: string; password: string; displayName?: string }>(request);
  const username = validateUsername(input.username ?? "");
  const password = validatePassword(input.password ?? "");
  const displayName = input.displayName?.normalize("NFKC").trim() || username;
  if (displayName.length > 40) throw new APIError(400, "invalid_display_name", "显示名称不能超过 40 个字符。");
  const existing = await env.DB.prepare("SELECT account_id FROM password_credentials WHERE username_normalized = ?")
    .bind(username).first();
  if (existing) throw new APIError(409, "username_unavailable", "该账号名已被使用。");

  const timestamp = now();
  const accountID = uuid();
  const salt = randomToken(16);
  const iterations = passwordIterations(env);
  const passwordHash = await derivePasswordHash(password, salt, iterations);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO accounts (id, apple_subject_hash, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)")
      .bind(accountID, `password:${await sha256(username)}`, displayName, timestamp, timestamp),
    env.DB.prepare("INSERT INTO password_credentials (account_id, username_normalized, password_salt, password_hash, password_iterations, updated_at) VALUES (?, ?, ?, ?, ?, ?)")
      .bind(accountID, username, salt, passwordHash, iterations, timestamp),
    env.DB.prepare("INSERT INTO security_audit_events (id, account_id, event_type, detail_json, created_at) VALUES (?, ?, 'password_registration', '{}', ?)")
      .bind(uuid(), accountID, timestamp),
  ]);
  return json({ ...(await issueSession(accountID, env)), displayName }, 201);
}

async function authPassword(request: Request, env: Env): Promise<Response> {
  const input = await body<{ username: string; password: string }>(request);
  const username = validateUsername(input.username ?? "");
  const password = input.password ?? "";
  const credential = await env.DB.prepare("SELECT p.account_id, p.password_salt, p.password_hash, p.password_iterations, p.failed_attempts, p.locked_until, a.display_name, a.status FROM password_credentials p JOIN accounts a ON a.id = p.account_id WHERE p.username_normalized = ?")
    .bind(username).first<{ account_id: string; password_salt: string; password_hash: string; password_iterations: number; failed_attempts: number; locked_until: number | null; display_name: string; status: string }>();
  if (!credential) throw new APIError(401, "invalid_username_or_password", "账号名或密码错误。");

  const timestamp = now();
  if (credential.locked_until && credential.locked_until > timestamp) {
    throw new APIError(429, "password_attempt_locked", "登录失败次数过多，请 15 分钟后重试。");
  }
  if (credential.status !== "active") throw new APIError(403, "account_unavailable", "该账号当前不可登录。");
  const candidateHash = await derivePasswordHash(password, credential.password_salt, credential.password_iterations);
  if (!constantTimeEqual(candidateHash, credential.password_hash)) {
    const priorFailures = credential.locked_until && credential.locked_until <= timestamp ? 0 : credential.failed_attempts;
    const failures = priorFailures + 1;
    const lockedUntil = failures >= maximumPasswordAttempts ? timestamp + passwordLockSeconds : null;
    await env.DB.batch([
      env.DB.prepare("UPDATE password_credentials SET failed_attempts = ?, locked_until = ?, updated_at = ? WHERE account_id = ?")
        .bind(failures, lockedUntil, timestamp, credential.account_id),
      env.DB.prepare("INSERT INTO security_audit_events (id, account_id, event_type, detail_json, created_at) VALUES (?, ?, 'password_auth_failed', '{}', ?)")
        .bind(uuid(), credential.account_id, timestamp),
    ]);
    if (lockedUntil) throw new APIError(429, "password_attempt_locked", "登录失败次数过多，请 15 分钟后重试。");
    throw new APIError(401, "invalid_username_or_password", "账号名或密码错误。");
  }
  await env.DB.batch([
    env.DB.prepare("UPDATE password_credentials SET failed_attempts = 0, locked_until = NULL, updated_at = ? WHERE account_id = ?")
      .bind(timestamp, credential.account_id),
    env.DB.prepare("INSERT INTO security_audit_events (id, account_id, event_type, detail_json, created_at) VALUES (?, ?, 'password_auth_success', '{}', ?)")
      .bind(uuid(), credential.account_id, timestamp),
  ]);
  return json({ ...(await issueSession(credential.account_id, env)), displayName: credential.display_name });
}

async function refreshSession(request: Request, env: Env): Promise<Response> {
  const input = await body<{ refreshToken: string }>(request);
  const tokenHash = await sha256(input.refreshToken ?? "");
  const session = await env.DB.prepare("SELECT id, account_id FROM sessions WHERE refresh_token_hash = ? AND revoked_at IS NULL AND expires_at > ?")
    .bind(tokenHash, now()).first<{ id: string; account_id: string }>();
  if (!session) throw new APIError(401, "invalid_refresh_token", "Session Refresh Token 无效或已过期。");
  await env.DB.prepare("UPDATE sessions SET revoked_at = ?, last_used_at = ? WHERE id = ?").bind(now(), now(), session.id).run();
  return json(await issueSession(session.account_id, env));
}

async function logoutSession(env: Env, auth: AuthContext): Promise<Response> {
  const timestamp = now();
  await env.DB.batch([
    env.DB.prepare("UPDATE sessions SET revoked_at = ?, last_used_at = ? WHERE id = ? AND account_id = ? AND revoked_at IS NULL")
      .bind(timestamp, timestamp, auth.sessionID, auth.accountID),
    env.DB.prepare("INSERT INTO security_audit_events (id, account_id, event_type, detail_json, created_at) VALUES (?, ?, 'session_logout', '{}', ?)")
      .bind(uuid(), auth.accountID, timestamp),
  ]);
  return new Response(null, { status: 204 });
}

async function registerDevice(request: Request, env: Env, auth: AuthContext): Promise<Response> {
  const input = await body<{ deviceID: string; publicKeyJWK: JsonWebKey; displayName?: string }>(request);
  if (!input.deviceID || !input.publicKeyJWK) throw new APIError(400, "invalid_device", "设备标识或公钥缺失。");
  const existing = await env.DB.prepare("SELECT account_id, public_key_jwk, status FROM devices WHERE id = ?")
    .bind(input.deviceID).first<{ account_id: string; public_key_jwk: string; status: string }>();
  if (existing && existing.account_id !== auth.accountID) {
    throw new APIError(409, "device_owned_by_another_account", "该设备已绑定其他账号。");
  }
  const publicKeyJWK = JSON.stringify(input.publicKeyJWK, Object.keys(input.publicKeyJWK).sort());
  if (existing) {
    let existingKey: string;
    try {
      const value = JSON.parse(existing.public_key_jwk) as JsonWebKey;
      existingKey = JSON.stringify(value, Object.keys(value).sort());
    } catch {
      throw new APIError(409, "device_key_mismatch", "该设备已有不同的注册公钥，请先撤销旧设备。");
    }
    if (existingKey !== publicKeyJWK) {
      throw new APIError(409, "device_key_mismatch", "该设备已有不同的注册公钥，请先撤销旧设备。");
    }
  }
  const timestamp = now();
  const statements = [
    env.DB.prepare("INSERT INTO devices (id, account_id, public_key_jwk, display_name, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET display_name = excluded.display_name, status = 'active', last_seen_at = excluded.last_seen_at")
      .bind(input.deviceID, auth.accountID, publicKeyJWK, input.displayName?.trim() || "Apple 设备", timestamp, timestamp),
  ];
  if (!existing || existing.status !== "active") {
    statements.push(
      env.DB.prepare("UPDATE farm_directories SET security_generation = security_generation + 1, updated_at = ? WHERE id IN (SELECT farm_id FROM memberships WHERE account_id = ? AND status = 'active')")
        .bind(timestamp, auth.accountID),
    );
  }
  await env.DB.batch(statements);
  return json({ deviceID: input.deviceID, registeredAt: timestamp }, 201);
}

async function revokeDevice(env: Env, auth: AuthContext, deviceID: string): Promise<Response> {
  const device = await env.DB.prepare("SELECT id FROM devices WHERE id = ? AND account_id = ? AND status = 'active'")
    .bind(deviceID, auth.accountID).first<{ id: string }>();
  if (!device) throw new APIError(404, "active_device_not_found", "未找到当前账号的有效设备。");
  const timestamp = now();
  await env.DB.batch([
    env.DB.prepare("UPDATE devices SET status = 'revoked', last_seen_at = ? WHERE id = ? AND account_id = ? AND status = 'active'")
      .bind(timestamp, deviceID, auth.accountID),
    env.DB.prepare("UPDATE capability_certificates SET revoked_at = ? WHERE device_id = ? AND account_id = ? AND revoked_at IS NULL")
      .bind(timestamp, deviceID, auth.accountID),
    env.DB.prepare("UPDATE farm_directories SET security_generation = security_generation + 1, updated_at = ? WHERE id IN (SELECT farm_id FROM memberships WHERE account_id = ? AND status = 'active')")
      .bind(timestamp, auth.accountID),
  ]);
  return new Response(null, { status: 204 });
}

async function registerFarm(request: Request, env: Env, auth: AuthContext): Promise<Response> {
  const input = await body<{ farmID: string; zoneName: string; shareRecordName?: string }>(request);
  if (!input.farmID || input.zoneName.toLowerCase() !== `farm_${input.farmID.toLowerCase()}`) throw new APIError(400, "invalid_farm_zone", "牧场 Zone 名称无效。");
  const timestamp = now();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO farm_directories (id, owner_account_id, cloud_zone_name, share_record_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET share_record_name = COALESCE(excluded.share_record_name, share_record_name), updated_at = excluded.updated_at")
      .bind(input.farmID, auth.accountID, input.zoneName, input.shareRecordName ?? null, timestamp, timestamp),
    env.DB.prepare("INSERT INTO memberships (id, farm_id, account_id, role, status, created_at, updated_at) VALUES (?, ?, ?, 'owner', 'active', ?, ?) ON CONFLICT(farm_id, account_id) DO UPDATE SET role = 'owner', status = 'active', updated_at = excluded.updated_at")
      .bind(uuid(), input.farmID, auth.accountID, timestamp, timestamp),
    env.DB.prepare("UPDATE farm_directories SET security_generation = MAX(security_generation, 1), updated_at = ? WHERE id = ?")
      .bind(timestamp, input.farmID),
  ]);
  return json({ farmID: input.farmID, status: "active" }, 201);
}

async function requireOwner(farmID: string, accountID: string, env: Env): Promise<void> {
  const membership = await env.DB.prepare("SELECT role FROM memberships WHERE farm_id = ? AND account_id = ? AND status = 'active'")
    .bind(farmID, accountID).first<{ role: FarmRole }>();
  if (membership?.role !== "owner") throw new APIError(403, "owner_required", "仅牧场主可执行此操作。");
}

async function createInvite(request: Request, env: Env, auth: AuthContext): Promise<Response> {
  const input = await body<{ farmID: string; role: unknown }>(request);
  if (!isInviteRole(input.role)) throw new APIError(400, "invalid_invite_role", "邀请角色必须为管理员或员工。");
  await requireOwner(input.farmID, auth.accountID, env);
  const code = generateInviteCode();
  const inviteID = uuid();
  const timestamp = now();
  await env.DB.prepare("INSERT INTO invites (id, farm_id, created_by_account_id, role, code_hash, expires_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
    .bind(inviteID, input.farmID, auth.accountID, input.role, await sha256(code), timestamp + 86400, timestamp).run();
  return json({ inviteID, code, role: input.role, expiresAt: timestamp + 86400 }, 201);
}

async function redeemInvite(request: Request, env: Env, auth: AuthContext): Promise<Response> {
  const recentFailures = await env.DB.prepare("SELECT COUNT(*) AS count FROM security_audit_events WHERE account_id = ? AND event_type = 'invite_redeem_failed' AND created_at > ?")
    .bind(auth.accountID, now() - 900).first<{ count: number }>();
  if ((recentFailures?.count ?? 0) >= 5) throw new APIError(429, "invite_attempt_locked", "邀请码连续错误次数过多，请 15 分钟后重试。");
  const input = await body<{ code: string }>(request);
  const normalized = (input.code ?? "").trim().toUpperCase();
  const invite = await env.DB.prepare("SELECT id, farm_id, role, expires_at, used_at FROM invites WHERE code_hash = ?")
    .bind(await sha256(normalized)).first<{ id: string; farm_id: string; role: FarmRole; expires_at: number; used_at: number | null }>();
  if (!invite || invite.used_at || invite.expires_at <= now()) {
    await env.DB.prepare("INSERT INTO security_audit_events (id, account_id, event_type, detail_json, created_at) VALUES (?, ?, 'invite_redeem_failed', '{}', ?)")
      .bind(uuid(), auth.accountID, now()).run();
    throw new APIError(400, "invalid_invite", "邀请码无效、已使用或已过期。");
  }
  const timestamp = now();
  const membershipID = uuid();
  await env.DB.batch([
    env.DB.prepare("UPDATE invites SET redeemed_by_account_id = ?, redeemed_at = ?, used_at = ? WHERE id = ? AND used_at IS NULL")
      .bind(auth.accountID, timestamp, timestamp, invite.id),
    env.DB.prepare("INSERT INTO memberships (id, farm_id, account_id, role, status, created_at, updated_at) VALUES (?, ?, ?, ?, 'pending', ?, ?) ON CONFLICT(farm_id, account_id) DO UPDATE SET role = excluded.role, status = 'pending', updated_at = excluded.updated_at")
      .bind(membershipID, invite.farm_id, auth.accountID, invite.role, timestamp, timestamp),
  ]);
  return json({ inviteID: invite.id, farmID: invite.farm_id, role: invite.role, membershipStatus: "pendingShareConfirmation" });
}

async function confirmInvite(request: Request, env: Env, auth: AuthContext, inviteID: string): Promise<Response> {
  const input = await body<{ shareParticipantRecordName: string }>(request);
  const invite = await env.DB.prepare("SELECT farm_id, redeemed_by_account_id FROM invites WHERE id = ? AND redeemed_at IS NOT NULL")
    .bind(inviteID).first<{ farm_id: string; redeemed_by_account_id: string }>();
  if (!invite) throw new APIError(404, "invite_not_found", "未找到待确认邀请。");
  await requireOwner(invite.farm_id, auth.accountID, env);
  if (!input.shareParticipantRecordName) throw new APIError(400, "missing_share_participant", "缺少 CKShare 参与者标识。");
  const pending = await env.DB.prepare("SELECT id FROM memberships WHERE farm_id = ? AND account_id = ? AND status = 'pending'")
    .bind(invite.farm_id, invite.redeemed_by_account_id).first<{ id: string }>();
  if (!pending) throw new APIError(409, "membership_not_pending", "该邀请已确认或成员状态已变化。");
  const timestamp = now();
  await env.DB.batch([
    env.DB.prepare("UPDATE memberships SET status = 'active', share_participant_record_name = ?, updated_at = ? WHERE farm_id = ? AND account_id = ?")
      .bind(input.shareParticipantRecordName, timestamp, invite.farm_id, invite.redeemed_by_account_id),
    env.DB.prepare("UPDATE invites SET confirmed_at = ? WHERE id = ?").bind(timestamp, inviteID),
    env.DB.prepare("UPDATE farm_directories SET security_generation = security_generation + 1, updated_at = ? WHERE id = ?")
      .bind(timestamp, invite.farm_id),
  ]);
  return json({ inviteID, membershipStatus: "active" });
}

async function changeMemberRole(request: Request, env: Env, auth: AuthContext, memberID: string): Promise<Response> {
  const input = await body<{ farmID: string; role: unknown }>(request);
  if (!isInviteRole(input.role)) throw new APIError(400, "invalid_member_role", "成员角色必须为管理员或员工。");
  await requireOwner(input.farmID, auth.accountID, env);
  const member = await env.DB.prepare("SELECT account_id, role FROM memberships WHERE id = ? AND farm_id = ? AND status = 'active'")
    .bind(memberID, input.farmID).first<{ account_id: string; role: FarmRole }>();
  if (!member || member.role === "owner") throw new APIError(404, "active_member_not_found", "未找到可修改角色的有效成员。");
  if (member.role === input.role) return json({ memberID, role: input.role, unchanged: true });
  const timestamp = now();
  await env.DB.batch([
    env.DB.prepare("UPDATE memberships SET role = ?, updated_at = ? WHERE id = ? AND farm_id = ? AND role != 'owner'").bind(input.role, timestamp, memberID, input.farmID),
    env.DB.prepare("UPDATE capability_certificates SET revoked_at = ? WHERE farm_id = ? AND account_id = ? AND revoked_at IS NULL")
      .bind(timestamp, input.farmID, member.account_id),
    env.DB.prepare("UPDATE farm_directories SET security_generation = security_generation + 1, updated_at = ? WHERE id = ?")
      .bind(timestamp, input.farmID),
  ]);
  return json({ memberID, role: input.role });
}

async function removeMember(request: Request, env: Env, auth: AuthContext, memberID: string): Promise<Response> {
  const input = await body<{ farmID: string }>(request);
  const member = await env.DB.prepare("SELECT account_id, role FROM memberships WHERE id = ? AND farm_id = ? AND status = 'active'").bind(memberID, input.farmID).first<{ account_id: string; role: FarmRole }>();
  if (!member || member.role === "owner") throw new APIError(400, "member_not_removable", "无法移除该成员。");
  if (member.account_id !== auth.accountID) await requireOwner(input.farmID, auth.accountID, env);
  const timestamp = now();
  await env.DB.batch([
    env.DB.prepare("UPDATE memberships SET status = 'revoked', updated_at = ? WHERE id = ?").bind(timestamp, memberID),
    env.DB.prepare("UPDATE capability_certificates SET revoked_at = ? WHERE farm_id = ? AND account_id = ? AND revoked_at IS NULL").bind(timestamp, input.farmID, member.account_id),
    env.DB.prepare("UPDATE farm_directories SET security_generation = security_generation + 1, updated_at = ? WHERE id = ?")
      .bind(timestamp, input.farmID),
  ]);
  return new Response(null, { status: 204 });
}

async function issueCapability(request: Request, env: Env, auth: AuthContext): Promise<Response> {
  const input = await body<{ farmID: string; deviceID: string }>(request);
  const membership = await env.DB.prepare("SELECT role FROM memberships WHERE farm_id = ? AND account_id = ? AND status = 'active'")
    .bind(input.farmID, auth.accountID).first<{ role: FarmRole }>();
  if (!membership) throw new APIError(403, "inactive_membership", "当前账号不是该牧场的有效成员。");
  const device = await env.DB.prepare("SELECT id FROM devices WHERE id = ? AND account_id = ? AND status = 'active'")
    .bind(input.deviceID, auth.accountID).first();
  if (!device) throw new APIError(403, "unregistered_device", "当前设备尚未注册或已撤销。");
  const issuedAt = now();
  const expiresAt = issuedAt + Number(env.CAPABILITY_TTL_SECONDS || 604800);
  const certificateID = uuid();
  const capabilities = capabilitiesForRole(membership.role);
  const claims = { certificateID, accountID: auth.accountID, farmID: input.farmID, deviceID: input.deviceID, role: membership.role, capabilities, iat: issuedAt, exp: expiresAt, iss: "esheep-next-identity", aud: "esheep-next-cloud-operation" };
  const certificate = await signES256JWS(claims, env, "esheep-capability+jwt");
  await env.DB.prepare("INSERT INTO capability_certificates (id, account_id, farm_id, device_id, role, capabilities_json, certificate_jws, issued_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
    .bind(certificateID, auth.accountID, input.farmID, input.deviceID, membership.role, JSON.stringify(capabilities), certificate, issuedAt, expiresAt).run();
  return json({ certificateID, certificate, role: membership.role, capabilities, issuedAt, expiresAt });
}

async function accountStatus(env: Env, auth: AuthContext): Promise<Response> {
  const account = await env.DB.prepare("SELECT display_name, status FROM accounts WHERE id = ?").bind(auth.accountID).first<{ display_name: string; status: string }>();
  const memberships = await env.DB.prepare("SELECT farm_id, role, status FROM memberships WHERE account_id = ?").bind(auth.accountID).all();
  return json({ accountID: auth.accountID, displayName: account?.display_name, status: account?.status, memberships: memberships.results });
}

async function farmSecuritySnapshot(farmID: string, env: Env, auth: AuthContext): Promise<Response> {
  const membership = await env.DB.prepare("SELECT role, status FROM memberships WHERE farm_id = ? AND account_id = ? AND status = 'active'")
    .bind(farmID, auth.accountID).first();
  if (!membership) throw new APIError(403, "inactive_membership", "当前账号不是该牧场的有效成员。");
  const members = await env.DB.prepare("SELECT m.id AS membershipID, m.account_id AS accountID, a.display_name AS displayName, m.role, m.status, m.share_participant_record_name AS shareParticipantRecordName FROM memberships m JOIN accounts a ON a.id = m.account_id WHERE m.farm_id = ?")
    .bind(farmID).all();
  const devices = await env.DB.prepare("SELECT d.id AS deviceID, d.account_id AS accountID, d.public_key_jwk AS publicKeyJWK FROM devices d JOIN memberships m ON m.account_id = d.account_id WHERE m.farm_id = ? AND m.status = 'active' AND d.status = 'active'")
    .bind(farmID).all();
  const revokedCertificates = await env.DB.prepare("SELECT id AS certificateID, revoked_at AS revokedAt FROM capability_certificates WHERE farm_id = ? AND revoked_at IS NOT NULL")
    .bind(farmID).all();
  const directory = await env.DB.prepare("SELECT security_generation AS generation FROM farm_directories WHERE id = ? AND status = 'active'")
    .bind(farmID).first<{ generation: number }>();
  if (!directory) throw new APIError(404, "farm_not_found", "牧场目录不存在。");
  return json({ farmID, generation: directory.generation, issuedAt: now(), members: members.results, devices: devices.results, revokedCertificates: revokedCertificates.results });
}

async function health(env: Env): Promise<Response> {
  const result = await env.DB.prepare("SELECT 1 AS ok").first<{ ok: number }>();
  if (result?.ok !== 1) throw new APIError(503, "d1_unavailable", "Development D1 当前不可用。");
  return json({ status: "ok", environment: "development", version: serviceVersion, database: "reachable" });
}

async function deleteAccount(env: Env, auth: AuthContext): Promise<Response> {
  const owned = await env.DB.prepare("SELECT COUNT(*) AS count FROM farm_directories WHERE owner_account_id = ? AND status = 'active'").bind(auth.accountID).first<{ count: number }>();
  if ((owned?.count ?? 0) > 0) throw new APIError(409, "owned_farms_exist", "删除账号前必须先删除自有云端牧场。");
  const activeMemberships = await env.DB.prepare("SELECT COUNT(*) AS count FROM memberships WHERE account_id = ? AND status = 'active'").bind(auth.accountID).first<{ count: number }>();
  if ((activeMemberships?.count ?? 0) > 0) throw new APIError(409, "active_memberships_exist", "删除账号前必须先退出全部共享牧场。");
  const credential = await env.DB.prepare("SELECT encrypted_refresh_token, encryption_iv FROM apple_credentials WHERE account_id = ?")
    .bind(auth.accountID).first<{ encrypted_refresh_token: string; encryption_iv: string }>();
  const passwordCredential = await env.DB.prepare("SELECT account_id FROM password_credentials WHERE account_id = ?")
    .bind(auth.accountID).first();
  if (!credential && !passwordCredential) throw new APIError(409, "account_credential_missing", "缺少可删除的账号凭据。");
  const jobID = uuid();
  const timestamp = now();
  await env.DB.prepare("INSERT INTO deletion_jobs (id, account_id, status, created_at) VALUES (?, ?, 'processing', ?)").bind(jobID, auth.accountID, timestamp).run();
  try {
    if (credential) {
      const refreshToken = await decryptCredential(credential.encrypted_refresh_token, credential.encryption_iv, env.CREDENTIAL_ENCRYPTION_KEY);
      await revokeAppleToken(refreshToken, env);
    }
    await env.DB.batch([
      env.DB.prepare("UPDATE sessions SET revoked_at = ? WHERE account_id = ? AND revoked_at IS NULL").bind(timestamp, auth.accountID),
      env.DB.prepare("UPDATE devices SET status = 'revoked' WHERE account_id = ?").bind(auth.accountID),
      env.DB.prepare("UPDATE memberships SET status = 'revoked', updated_at = ? WHERE account_id = ?").bind(timestamp, auth.accountID),
      env.DB.prepare("DELETE FROM invites WHERE created_by_account_id = ? OR redeemed_by_account_id = ?").bind(auth.accountID, auth.accountID),
      env.DB.prepare("DELETE FROM apple_credentials WHERE account_id = ?").bind(auth.accountID),
      env.DB.prepare("DELETE FROM password_credentials WHERE account_id = ?").bind(auth.accountID),
      env.DB.prepare("UPDATE accounts SET status = 'deleted', display_name = '已删除账户', updated_at = ? WHERE id = ?").bind(timestamp, auth.accountID),
      env.DB.prepare("UPDATE deletion_jobs SET status = 'completed', completed_at = ? WHERE id = ?").bind(timestamp, jobID),
    ]);
    return json({ deletionJobID: jobID, status: "completed" });
  } catch (error) {
    await env.DB.prepare("UPDATE deletion_jobs SET status = 'failed', error_code = ? WHERE id = ?").bind(error instanceof APIError ? error.code : "unknown", jobID).run();
    throw error;
  }
}

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/v1/health") return health(env);
  if (request.method === "POST" && url.pathname === "/v1/auth/apple") return authApple(request, env);
  if (request.method === "POST" && url.pathname === "/v1/auth/register") return registerPasswordAccount(request, env);
  if (request.method === "POST" && url.pathname === "/v1/auth/password") return authPassword(request, env);
  if (request.method === "POST" && url.pathname === "/v1/auth/refresh") return refreshSession(request, env);
  const auth = await authenticate(request, env);
  if (request.method === "POST" && url.pathname === "/v1/auth/logout") return logoutSession(env, auth);
  if (request.method === "POST" && url.pathname === "/v1/devices/register") return registerDevice(request, env, auth);
  const device = url.pathname.match(/^\/v1\/devices\/([^/]+)$/);
  if (request.method === "DELETE" && device?.[1]) return revokeDevice(env, auth, device[1]);
  if (request.method === "POST" && url.pathname === "/v1/farms/register") return registerFarm(request, env, auth);
  if (request.method === "POST" && url.pathname === "/v1/invites") return createInvite(request, env, auth);
  if (request.method === "POST" && url.pathname === "/v1/invites/redeem") return redeemInvite(request, env, auth);
  const inviteConfirm = url.pathname.match(/^\/v1\/invites\/([^/]+)\/confirm$/);
  if (request.method === "POST" && inviteConfirm?.[1]) return confirmInvite(request, env, auth, inviteConfirm[1]);
  const member = url.pathname.match(/^\/v1\/members\/([^/]+)$/);
  if (request.method === "PATCH" && member?.[1]) return changeMemberRole(request, env, auth, member[1]);
  if (request.method === "DELETE" && member?.[1]) return removeMember(request, env, auth, member[1]);
  if (request.method === "POST" && url.pathname === "/v1/capabilities/issue") return issueCapability(request, env, auth);
  const securitySnapshot = url.pathname.match(/^\/v1\/farms\/([^/]+)\/security-snapshot$/);
  if (request.method === "GET" && securitySnapshot?.[1]) return farmSecuritySnapshot(securitySnapshot[1], env, auth);
  if (request.method === "POST" && url.pathname === "/v1/account/delete") return deleteAccount(env, auth);
  if (request.method === "GET" && url.pathname === "/v1/account/status") return accountStatus(env, auth);
  throw new APIError(404, "route_not_found", "接口不存在。");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      if (request.method === "OPTIONS") return new Response(null, { status: 204 });
      return await route(request, env);
    } catch (error) {
      if (error instanceof APIError) return json({ error: { code: error.code, message: error.message } }, error.status);
      console.error(error);
      return json({ error: { code: "internal_error", message: "身份服务发生内部错误。" } }, 500);
    }
  },
} satisfies ExportedHandler<Env>;
