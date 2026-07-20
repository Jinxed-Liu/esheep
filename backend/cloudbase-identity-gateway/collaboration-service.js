const { createHash, createSign, randomBytes, randomUUID } = require("node:crypto");

class APIError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const now = () => Math.floor(Date.now() / 1000);
const hash = (value) => createHash("sha256").update(value).digest("hex");
const key = (type, id) => `${type}_${hash(String(id)).slice(0, 40)}`;
const canonicalFarmID = (value) => String(value || "").trim().toLowerCase();
const inviteAlphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";

function inviteCode() {
  return Array.from(randomBytes(8), (byte) => inviteAlphabet[byte % inviteAlphabet.length]).join("");
}

function capabilitiesForRole(role) {
  if (role === "owner") return ["readFarm", "recordProduction", "editHistoricalFacts", "manageCatalogs", "viewAnalytics", "deleteProtectedFacts", "manageMembers", "manageFarm", "exportFarm", "resolveConflicts", "recoverFarm"];
  if (role === "administrator") return ["readFarm", "recordProduction", "editHistoricalFacts", "manageCatalogs", "viewAnalytics"];
  return ["readFarm", "recordProduction"];
}

function requireInviteRole(role, code = "invalid_invite_role") {
  if (role !== "administrator" && role !== "worker") {
    throw new APIError(400, code, "角色必须为管理员或员工。");
  }
}

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function signCapability(claims, privateKey, keyID) {
  if (!privateKey || !keyID) throw new APIError(503, "capability_signer_unavailable", "协作能力证书签名服务尚未配置。");
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyID, typ: "esheep-capability+jwt" }));
  const payload = base64url(JSON.stringify(claims));
  const content = `${header}.${payload}`;
  const signature = createSign("SHA256").update(content).end().sign({ key: privateKey, dsaEncoding: "ieee-p1363" });
  return `${content}.${signature.toString("base64url")}`;
}

function normalizeDocument(result) {
  if (!result) return null;
  if (Array.isArray(result.data)) return result.data[0] || null;
  return result.data || null;
}

class DocumentStore {
  constructor(database, collectionName = "esheep_identity", transactionRoot = database) {
    this.database = database;
    this.transactionRoot = transactionRoot;
    this.collectionName = collectionName;
    this.collection = database.collection(collectionName);
  }

  async get(documentID) {
    try {
      return normalizeDocument(await this.collection.doc(documentID).get());
    } catch (error) {
      if (error?.code === "DOCUMENT_NOT_FOUND" || error?.code === "DATABASE_REQUEST_FAILED" && /not found/i.test(String(error?.message || ""))) {
        return null;
      }
      throw error;
    }
  }

  async set(documentID, value) {
    await this.collection.doc(documentID).set({ ...value, _documentID: documentID });
    return value;
  }

  async update(documentID, value) {
    await this.collection.doc(documentID).update(value);
  }

  async remove(documentID) {
    await this.collection.doc(documentID).remove();
  }

  async find(where, limit = 1000) {
    const result = await this.collection.where(where).limit(limit).get();
    return result.data || [];
  }

  async transaction(operation) {
    return this.transactionRoot.runTransaction(async (transaction) => operation(new DocumentStore(transaction, this.collectionName, this.transactionRoot)));
  }

  async increment(documentID, field, amount) {
    await this.collection.doc(documentID).update({ [field]: this.transactionRoot.command.inc(amount) });
  }
}

class CollaborationService {
  constructor({ store, env = process.env }) {
    this.store = store;
    this.env = env;
  }

  async health() {
    await this.store.find({ type: "service_probe" }, 1);
    return { status: "ok", environment: this.env.APP_ENVIRONMENT || "cloudbase-development", version: "0.3.3", database: "cloudbase-document" };
  }

  async consumeRateLimit(scope, identity, limit, windowSeconds) {
    const documentID = key("rate_limit", `${scope}:${identity}`);
    const timestamp = now();
    const operation = async (store) => {
      const current = await store.get(documentID);
      const active = current && Number(current.expiresAt || 0) > timestamp;
      const count = active ? Number(current.count || 0) + 1 : 1;
      const expiresAt = active ? Number(current.expiresAt) : timestamp + windowSeconds;
      if (count > limit) throw new APIError(429, "rate_limited", "请求过于频繁，请稍后再试。");
      await store.set(documentID, { type: "rate_limit", scope, identity, count, expiresAt, updatedAt: timestamp });
      return { remaining: Math.max(0, limit - count), expiresAt };
    };
    return this.store.transaction ? this.store.transaction(operation) : operation(this.store);
  }

  async ensureAccount(accountID, displayName) {
    const documentID = key("account", accountID);
    const current = await this.store.get(documentID);
    if (current?.status === "deleted") throw new APIError(403, "account_unavailable", "该账号当前不可登录。");
    if (!current) {
      await this.store.set(documentID, { type: "account", accountID, displayName: displayName || "eSheep+ 用户", status: "active", createdAt: now(), updatedAt: now() });
    }
    return { ...current, accountID, displayName: current?.displayName || displayName || "eSheep+ 用户", status: current?.status || "active" };
  }

  async updateAccountDisplayName(accountID, rawDisplayName) {
    const displayName = String(rawDisplayName || "").normalize("NFKC").trim();
    if (!displayName) throw new APIError(400, "invalid_display_name", "显示名称不能为空。");
    if ([...displayName].length > 40) throw new APIError(400, "invalid_display_name", "显示名称不能超过 40 个字符。");
    const documentID = key("account", accountID);
    const current = await this.store.get(documentID);
    if (!current || current.status === "deleted") throw new APIError(403, "account_unavailable", "该账号当前不可用。");
    await this.store.update(documentID, { displayName, updatedAt: now() });
    return { accountID, displayName };
  }

  async recordAppleBinding(accountID, subjectHash, encryptedRefreshToken) {
    const timestamp = now();
    const documentID = key("apple_credential", accountID);
    const existing = (await this.store.find({ type: "apple_credential", subjectHash }, 2))[0];
    if (existing && existing.accountID !== accountID) {
      throw new APIError(409, "apple_account_already_bound", "该 Apple 账户已绑定其他账号。");
    }
    const current = await this.store.get(documentID);
    await this.store.set(documentID, {
      type: "apple_credential",
      accountID,
      subjectHash,
      encryptedRefreshToken: encryptedRefreshToken || current?.encryptedRefreshToken || null,
      createdAt: current?.createdAt || timestamp,
      updatedAt: timestamp,
    });
  }

  async appleCredential(accountID) {
    return this.store.get(key("apple_credential", accountID));
  }

  async account(accountID) {
    return this.store.get(key("account", accountID));
  }

  async membership(farmID, accountID) {
    return this.store.get(key("membership", `${canonicalFarmID(farmID)}:${accountID}`));
  }

  async requireOwner(farmID, accountID) {
    const membership = await this.membership(farmID, accountID);
    if (membership?.status !== "active" || membership.role !== "owner") throw new APIError(403, "owner_required", "仅牧场主可执行此操作。");
    return membership;
  }

  async registerDevice(accountID, input) {
    if (!input.deviceID || !input.publicKeyJWK || typeof input.publicKeyJWK !== "object") throw new APIError(400, "invalid_device", "设备注册信息无效。");
    const documentID = key("device", input.deviceID);
    const current = await this.store.get(documentID);
    if (current && current.accountID !== accountID) throw new APIError(409, "device_owned_by_another_account", "该设备已绑定其他账号。");
    const timestamp = now();
    await this.store.set(documentID, { type: "device", deviceID: input.deviceID, accountID, publicKeyJWK: JSON.stringify(input.publicKeyJWK), displayName: String(input.displayName || "设备").slice(0, 80), status: "active", registeredAt: current?.registeredAt || timestamp, updatedAt: timestamp });
    return { deviceID: input.deviceID, registeredAt: current?.registeredAt || timestamp };
  }

  async revokeDevice(accountID, deviceID) {
    const documentID = key("device", deviceID);
    const device = await this.store.get(documentID);
    if (!device || device.accountID !== accountID || device.status !== "active") throw new APIError(404, "active_device_not_found", "未找到可撤销的有效设备。");
    const timestamp = now();
    await this.store.update(documentID, { status: "revoked", revokedAt: timestamp, updatedAt: timestamp });
    const certificates = await this.store.find({ type: "capability", deviceID, accountID, revokedAt: null });
    await Promise.all(certificates.map((item) => this.store.update(item._documentID, { revokedAt: timestamp })));
    const memberships = await this.store.find({ type: "membership", accountID, status: "active" });
    await Promise.all(memberships.map((item) => this.bumpGeneration(item.farmID, timestamp)));
  }

  async registerFarm(accountID, input) {
    const farmID = canonicalFarmID(input.farmID);
    if (!farmID || String(input.zoneName || "").toLowerCase() !== `farm_${farmID}`) throw new APIError(400, "invalid_farm_zone", "牧场 Zone 名称无效。");
    const requestedStatus = input.status || "active";
    if (requestedStatus !== "provisioning" && requestedStatus !== "active") throw new APIError(400, "invalid_farm_status", "牧场登记状态无效。");
    const farmKey = key("farm", farmID);
    const existing = await this.store.get(farmKey);
    if (existing && existing.ownerAccountID !== accountID) throw new APIError(409, "farm_already_registered", "该牧场已由其他账号登记。");
    const timestamp = now();
    const status = existing?.status === "active" ? "active" : requestedStatus;
    await this.store.set(farmKey, { type: "farm", farmID, ownerAccountID: accountID, cloudZoneName: input.zoneName, shareRecordName: input.shareRecordName || existing?.shareRecordName || null, securityGeneration: Math.max(existing?.securityGeneration || 0, 1), status, createdAt: existing?.createdAt || timestamp, updatedAt: timestamp });
    const memberKey = key("membership", `${farmID}:${accountID}`);
    const member = await this.store.get(memberKey);
    await this.store.set(memberKey, { type: "membership", membershipID: member?.membershipID || randomUUID(), farmID, accountID, role: "owner", status: "active", shareParticipantRecordName: member?.shareParticipantRecordName || null, createdAt: member?.createdAt || timestamp, updatedAt: timestamp });
    return { farmID, status };
  }

  async activateFarm(accountID, farmID) {
    farmID = canonicalFarmID(farmID);
    const farmKey = key("farm", farmID);
    const farm = await this.store.get(farmKey);
    if (!farm || farm.ownerAccountID !== accountID) throw new APIError(404, "farm_not_found", "牧场目录不存在。");
    await this.requireOwner(farmID, accountID);
    if (farm.status !== "active") await this.store.update(farmKey, { status: "active", activatedAt: now(), updatedAt: now() });
    return { farmID, status: "active" };
  }

  async bumpGeneration(farmID, timestamp = now()) {
    farmID = canonicalFarmID(farmID);
    const documentID = key("farm", farmID);
    const farm = await this.store.get(documentID);
    if (!farm) return;
    if (this.store.increment) {
      await this.store.increment(documentID, "securityGeneration", 1);
      await this.store.update(documentID, { updatedAt: timestamp });
    } else {
      await this.store.update(documentID, { securityGeneration: Number(farm.securityGeneration || 0) + 1, updatedAt: timestamp });
    }
  }

  async createInvite(accountID, input) {
    requireInviteRole(input.role);
    const farmID = canonicalFarmID(input.farmID);
    await this.requireOwner(farmID, accountID);
    const code = inviteCode();
    const inviteID = randomUUID();
    const timestamp = now();
    await this.store.set(key("invite", inviteID), { type: "invite", inviteID, farmID, createdByAccountID: accountID, role: input.role, codeHash: hash(code), expiresAt: timestamp + 86400, usedAt: null, createdAt: timestamp });
    return { inviteID, code, role: input.role, expiresAt: timestamp + 86400 };
  }

  async recordInviteFailure(accountID) {
    const timestamp = now();
    const auditID = randomUUID();
    await this.store.set(key("audit", auditID), { type: "audit", auditID, accountID, eventType: "invite_redeem_failed", createdAt: timestamp });
  }

  async redeemInvite(accountID, input) {
    const failures = await this.store.find({ type: "audit", accountID, eventType: "invite_redeem_failed" });
    if (failures.filter((item) => item.createdAt > now() - 900).length >= 5) throw new APIError(429, "invite_attempt_locked", "邀请码连续错误次数过多，请 15 分钟后重试。");
    const normalized = String(input.code || "").trim().toUpperCase();
    const operation = async (store) => {
      const invite = (await store.find({ type: "invite", codeHash: hash(normalized) }, 2))[0];
      if (!invite || invite.usedAt || invite.expiresAt <= now()) throw new APIError(400, "invalid_invite", "邀请码无效、已使用或已过期。");
      const timestamp = now();
      const memberKey = key("membership", `${invite.farmID}:${accountID}`);
      const existing = await store.get(memberKey);
      if (existing?.status === "active") throw new APIError(409, "membership_already_active", "当前账号已经是该牧场成员。");
      await store.update(invite._documentID, { redeemedByAccountID: accountID, redeemedAt: timestamp, usedAt: timestamp });
      await store.set(memberKey, { type: "membership", membershipID: existing?.membershipID || randomUUID(), farmID: invite.farmID, accountID, role: invite.role, status: "pending", shareParticipantRecordName: null, createdAt: existing?.createdAt || timestamp, updatedAt: timestamp });
      return { inviteID: invite.inviteID, farmID: invite.farmID, role: invite.role, membershipStatus: "pendingShareConfirmation" };
    };
    try {
      return this.store.transaction ? await this.store.transaction(operation) : await operation(this.store);
    } catch (error) {
      if (error.code === "invalid_invite") await this.recordInviteFailure(accountID);
      throw error;
    }
  }

  async confirmInvite(accountID, inviteID, input) {
    const invite = await this.store.get(key("invite", inviteID));
    if (!invite?.redeemedByAccountID) throw new APIError(404, "invite_not_found", "未找到待确认邀请。");
    await this.requireOwner(invite.farmID, accountID);
    if (!input.shareParticipantRecordName) throw new APIError(400, "missing_share_participant", "缺少 CKShare 参与者标识。");
    const memberKey = key("membership", `${invite.farmID}:${invite.redeemedByAccountID}`);
    const membership = await this.store.get(memberKey);
    if (membership?.status !== "pending") throw new APIError(409, "membership_not_pending", "该邀请已确认或成员状态已变化。");
    const timestamp = now();
    await this.store.update(memberKey, { status: "active", shareParticipantRecordName: input.shareParticipantRecordName, updatedAt: timestamp });
    await this.store.update(invite._documentID, { confirmedAt: timestamp });
    await this.bumpGeneration(invite.farmID, timestamp);
    return { inviteID, membershipStatus: "active" };
  }

  async memberByID(memberID, farmID) {
    return (await this.store.find({ type: "membership", membershipID: memberID, farmID: canonicalFarmID(farmID) }, 2))[0] || null;
  }

  async revokeCertificates(farmID, accountID, timestamp) {
    const certificates = await this.store.find({ type: "capability", farmID, accountID, revokedAt: null });
    await Promise.all(certificates.map((item) => this.store.update(item._documentID, { revokedAt: timestamp })));
  }

  async changeMemberRole(accountID, memberID, input) {
    requireInviteRole(input.role, "invalid_member_role");
    await this.requireOwner(input.farmID, accountID);
    const member = await this.memberByID(memberID, input.farmID);
    if (!member || member.status !== "active" || member.role === "owner") throw new APIError(404, "active_member_not_found", "未找到可修改角色的有效成员。");
    if (member.role === input.role) return { memberID, role: input.role, unchanged: true };
    const timestamp = now();
    await this.store.update(member._documentID, { role: input.role, updatedAt: timestamp });
    await this.revokeCertificates(input.farmID, member.accountID, timestamp);
    await this.bumpGeneration(input.farmID, timestamp);
    return { memberID, role: input.role };
  }

  async removeMember(accountID, memberID, input) {
    const member = await this.memberByID(memberID, input.farmID);
    if (!member || member.status !== "active" || member.role === "owner") throw new APIError(400, "member_not_removable", "无法移除该成员。");
    if (member.accountID !== accountID) await this.requireOwner(input.farmID, accountID);
    const timestamp = now();
    await this.store.update(member._documentID, { status: "revoked", updatedAt: timestamp });
    await this.revokeCertificates(input.farmID, member.accountID, timestamp);
    await this.bumpGeneration(input.farmID, timestamp);
  }

  async issueCapability(accountID, input) {
    const farmID = canonicalFarmID(input.farmID);
    const membership = await this.membership(farmID, accountID);
    if (membership?.status !== "active") throw new APIError(403, "inactive_membership", "当前账号不是该牧场的有效成员。");
    const device = await this.store.get(key("device", input.deviceID));
    if (device?.accountID !== accountID || device.status !== "active") throw new APIError(403, "unregistered_device", "当前设备尚未注册或已撤销。");
    const issuedAt = now();
    const expiresAt = issuedAt + Number(this.env.CAPABILITY_TTL_SECONDS || 604800);
    const certificateID = randomUUID();
    const capabilities = capabilitiesForRole(membership.role);
    const claims = { certificateID, accountID, farmID, deviceID: input.deviceID, role: membership.role, capabilities, iat: issuedAt, exp: expiresAt, iss: "esheep-next-identity", aud: "esheep-next-cloud-operation" };
    const certificate = signCapability(claims, String(this.env.CAPABILITY_SIGNING_PRIVATE_KEY || "").replace(/\\n/g, "\n"), this.env.CAPABILITY_SIGNING_KEY_ID);
    await this.store.set(key("capability", certificateID), { type: "capability", certificateID, accountID, farmID, deviceID: input.deviceID, role: membership.role, capabilities, certificate, issuedAt, expiresAt, revokedAt: null });
    return { certificateID, certificate, role: membership.role, capabilities, issuedAt, expiresAt };
  }

  async accountStatus(accountID) {
    const account = await this.account(accountID);
    const memberships = await this.store.find({ type: "membership", accountID });
    const visible = [];
    for (const item of memberships) {
      const farm = await this.store.get(key("farm", item.farmID));
      if (farm?.status === "active") visible.push({ ...item, farm });
    }
    return { accountID, displayName: account?.displayName, status: account?.status || "active", memberships: visible.map((item) => ({ farm_id: item.farmID, ownerAccountID: item.farm.ownerAccountID, role: item.role, status: item.status, cloudZoneName: item.farm.cloudZoneName, shareRecordName: item.farm.shareRecordName || null })) };
  }

  async securitySnapshot(accountID, farmID) {
    farmID = canonicalFarmID(farmID);
    const requester = await this.membership(farmID, accountID);
    if (requester?.status !== "active") throw new APIError(403, "inactive_membership", "当前账号不是该牧场的有效成员。");
    const farm = await this.store.get(key("farm", farmID));
    if (!farm || (farm.status !== "active" && !(farm.status === "provisioning" && requester.role === "owner"))) throw new APIError(404, "farm_not_found", "牧场目录不存在。");
    const memberships = await this.store.find({ type: "membership", farmID });
    const activeAccountIDs = new Set(memberships.filter((item) => item.status === "active").map((item) => item.accountID));
    const accounts = await Promise.all(memberships.map((item) => this.account(item.accountID)));
    const devices = (await this.store.find({ type: "device", status: "active" })).filter((item) => activeAccountIDs.has(item.accountID));
    const revoked = (await this.store.find({ type: "capability", farmID })).filter((item) => item.revokedAt != null);
    return {
      farmID,
      generation: Number(farm.securityGeneration || 0),
      issuedAt: now(),
      members: memberships.map((item, index) => ({ membershipID: item.membershipID, accountID: item.accountID, displayName: accounts[index]?.displayName || "eSheep+ 用户", role: item.role, status: item.status, shareParticipantRecordName: item.shareParticipantRecordName || null })),
      devices: devices.map((item) => ({ deviceID: item.deviceID, accountID: item.accountID, publicKeyJWK: item.publicKeyJWK })),
      revokedCertificates: revoked.map((item) => ({ certificateID: item.certificateID, revokedAt: item.revokedAt })),
    };
  }

  async deleteAccount(accountID) {
    const farms = await this.store.find({ type: "farm", ownerAccountID: accountID, status: "active" });
    if (farms.length) throw new APIError(409, "owned_farms_exist", "删除账号前必须先删除自有云端牧场。");
    const memberships = await this.store.find({ type: "membership", accountID, status: "active" });
    if (memberships.length) throw new APIError(409, "active_memberships_exist", "删除账号前必须先退出全部共享牧场。");
    const timestamp = now();
    const jobID = randomUUID();
    const devices = await this.store.find({ type: "device", accountID });
    await Promise.all(devices.map((item) => this.store.update(item._documentID, { status: "revoked", revokedAt: timestamp, updatedAt: timestamp })));
    const invites = await this.store.find({ type: "invite" });
    await Promise.all(invites.filter((item) => item.createdByAccountID === accountID || item.redeemedByAccountID === accountID).map((item) => this.store.remove(item._documentID)));
    await this.store.remove(key("apple_credential", accountID)).catch(() => undefined);
    await this.store.update(key("account", accountID), { status: "deleted", displayName: "已删除账户", updatedAt: timestamp });
    await this.store.set(key("deletion", jobID), { type: "deletion", deletionJobID: jobID, accountID, status: "completed", createdAt: timestamp, completedAt: timestamp });
    return { deletionJobID: jobID, status: "completed" };
  }
}

function createCloudBaseService(env = process.env) {
  const cloudbase = require("@cloudbase/node-sdk");
  const app = cloudbase.init({ env: cloudbase.SYMBOL_DEFAULT_ENV });
  return new CollaborationService({ store: new DocumentStore(app.database(), env.CLOUDBASE_IDENTITY_COLLECTION || "esheep_identity"), env });
}

module.exports = { APIError, CollaborationService, DocumentStore, capabilitiesForRole, createCloudBaseService, signCapability };
