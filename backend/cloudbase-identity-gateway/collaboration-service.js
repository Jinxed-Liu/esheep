const { createHash, createSign, randomBytes, randomUUID, timingSafeEqual } = require("node:crypto");
const { DocumentStore } = require("./collaboration-store");

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
const maximumAvatarBytes = 60 * 1024;
const maximumInsightCiphertextBytes = 3 * 1024 * 1024;
const insightTombstoneRetentionMilliseconds = 30 * 24 * 60 * 60 * 1000;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function requiredUUID(value, field) {
  const normalized = String(value || "").trim().toLowerCase();
  if (!uuidPattern.test(normalized)) throw new APIError(400, "invalid_insight_identifier", `${field} 无效。`);
  return normalized;
}

function validatedCiphertext(value, field = "ciphertextBase64") {
  const encoded = String(value || "").trim();
  if (!encoded || encoded.length > Math.ceil(maximumInsightCiphertextBytes / 3) * 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) {
    throw new APIError(400, "invalid_insight_ciphertext", `${field} 无效或超过 3 MB。`);
  }
  const data = Buffer.from(encoded, "base64");
  if (!data.length || data.length > maximumInsightCiphertextBytes || data.toString("base64") !== encoded) {
    throw new APIError(400, "invalid_insight_ciphertext", `${field} 无效或超过 3 MB。`);
  }
  return encoded;
}

function validatedRecoveryProof(value) {
  const encoded = String(value || "").trim();
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) {
    throw new APIError(400, "invalid_insight_recovery_proof", "洞察恢复凭证无效。");
  }
  const data = Buffer.from(encoded, "base64");
  if (data.length !== 32 || data.toString("base64") !== encoded) {
    throw new APIError(400, "invalid_insight_recovery_proof", "洞察恢复凭证无效。");
  }
  return data;
}

function ciphertextKeyVersion(value, field = "ciphertextBase64") {
  const encoded = validatedCiphertext(value, field);
  const data = Buffer.from(encoded, "base64");
  if (data.length < 5) {
    throw new APIError(400, "invalid_insight_ciphertext", `${field} 缺少密钥版本。`);
  }
  const version = data.readUInt32BE(0);
  if (!Number.isSafeInteger(version) || version < 1) {
    throw new APIError(400, "invalid_insight_key_version", `${field} 的密钥版本无效。`);
  }
  return version;
}

function validatedAvatar(input) {
  const dataBase64 = String(input?.dataBase64 || "").trim();
  const digest = String(input?.digest || "").trim().toLowerCase();
  const maximumBase64Length = Math.ceil(maximumAvatarBytes / 3) * 4;
  if (!dataBase64 || dataBase64.length > maximumBase64Length || !/^[A-Za-z0-9+/]+={0,2}$/.test(dataBase64)) {
    throw new APIError(400, "invalid_avatar", "头像数据无效或超过 60 KB。");
  }
  const data = Buffer.from(dataBase64, "base64");
  if (!data.length || data.length > maximumAvatarBytes || data.toString("base64") !== dataBase64) {
    throw new APIError(400, "invalid_avatar", "头像数据无效或超过 60 KB。");
  }
  if (data.length < 4 || data[0] !== 0xFF || data[1] !== 0xD8 || data[2] !== 0xFF || data[data.length - 2] !== 0xFF || data[data.length - 1] !== 0xD9) {
    throw new APIError(400, "invalid_avatar_format", "头像必须是有效的 JPEG 图片。");
  }
  const actualDigest = createHash("sha256").update(data).digest("hex");
  if (!/^[a-f0-9]{64}$/.test(digest) || digest !== actualDigest) {
    throw new APIError(400, "invalid_avatar_digest", "头像内容摘要不匹配。");
  }
  return { dataBase64, digest };
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return value.map(canonicalJSON);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalJSON(value[key])]));
  }
  return value;
}

const canonicalJSONString = (value) => JSON.stringify(canonicalJSON(value));

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

function normalizedShareParticipantID(value, required = false) {
  const participantID = String(value || "").trim();
  if (!participantID && !required) return null;
  if (!participantID || participantID.length > 512 || /[\u0000-\u001f\u007f]/.test(participantID)) {
    throw new APIError(400, "invalid_share_participant", "CloudKit 一次性参与者标识无效。");
  }
  return participantID;
}

function normalizedCloudKitUserRecordName(value) {
  const recordName = String(value || "").trim();
  if (!recordName) return null;
  if (recordName.length > 512 || /[\u0000-\u001f\u007f]/.test(recordName)) {
    throw new APIError(400, "invalid_cloudkit_user", "CloudKit 用户标识无效。");
  }
  return recordName;
}

function normalizedCloudShareURL(value) {
  const rawURL = String(value || "").trim();
  if (!rawURL) return null;
  if (rawURL.length > 2048) {
    throw new APIError(400, "invalid_cloud_share_url", "CloudKit 共享链接无效。");
  }
  let parsed;
  try {
    parsed = new URL(rawURL);
  } catch {
    throw new APIError(400, "invalid_cloud_share_url", "CloudKit 共享链接无效。");
  }
  if (parsed.protocol !== "https:" ||
      parsed.hostname.toLowerCase() !== "www.icloud.com" ||
      !parsed.pathname.startsWith("/share/") ||
      parsed.username ||
      parsed.password ||
      parsed.port) {
    throw new APIError(400, "invalid_cloud_share_url", "CloudKit 共享链接无效。");
  }
  return parsed.toString();
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

class CollaborationService {
  constructor({ store, env = process.env }) {
    this.store = store;
    this.env = env;
  }

  async health() {
    await this.store.find({ type: "service_probe" }, 1);
    return { status: "ok", environment: this.env.APP_ENVIRONMENT || "cloudbase-development", version: "0.4.6", database: "cloudbase-document" };
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

  async accountAvatar(accountID, includeData = false) {
    const account = await this.store.get(key("account", accountID));
    if (!account || account.status === "deleted") throw new APIError(403, "account_unavailable", "该账号当前不可用。");
    const hasAvatar = typeof account.avatarDataBase64 === "string" &&
      account.avatarDataBase64.length > 0 &&
      typeof account.avatarDigest === "string" &&
      account.avatarDigest.length > 0;
    const result = {
      accountID,
      revision: Number.isSafeInteger(account.avatarRevision) ? account.avatarRevision : null,
      digest: hasAvatar ? account.avatarDigest : null,
      hasAvatar,
    };
    if (includeData) result.dataBase64 = hasAvatar ? account.avatarDataBase64 : null;
    return result;
  }

  async updateAccountAvatar(accountID, input) {
    const avatar = validatedAvatar(input);
    const operation = async (store) => {
      const documentID = key("account", accountID);
      const current = await store.get(documentID);
      if (!current || current.status === "deleted") throw new APIError(403, "account_unavailable", "该账号当前不可用。");
      const revision = Math.max(Date.now(), Number(current.avatarRevision || 0) + 1);
      await store.update(documentID, {
        avatarDataBase64: avatar.dataBase64,
        avatarDigest: avatar.digest,
        avatarRevision: revision,
        updatedAt: now(),
      });
      return { accountID, revision, digest: avatar.digest, hasAvatar: true };
    };
    return this.store.transaction ? this.store.transaction(operation) : operation(this.store);
  }

  async removeAccountAvatar(accountID) {
    const operation = async (store) => {
      const documentID = key("account", accountID);
      const current = await store.get(documentID);
      if (!current || current.status === "deleted") throw new APIError(403, "account_unavailable", "该账号当前不可用。");
      const revision = Math.max(Date.now(), Number(current.avatarRevision || 0) + 1);
      await store.update(documentID, {
        avatarDataBase64: null,
        avatarDigest: null,
        avatarRevision: revision,
        updatedAt: now(),
      });
      return { accountID, revision, digest: null, hasAvatar: false };
    };
    return this.store.transaction ? this.store.transaction(operation) : operation(this.store);
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
    const publicKeyJWK = canonicalJSONString(input.publicKeyJWK);
    if (current?.publicKeyJWK) {
      let currentKey;
      try {
        currentKey = canonicalJSONString(JSON.parse(current.publicKeyJWK));
      } catch {
        throw new APIError(409, "device_key_mismatch", "该设备已有不同的注册公钥，请先撤销旧设备。" );
      }
      if (currentKey !== publicKeyJWK) throw new APIError(409, "device_key_mismatch", "该设备已有不同的注册公钥，请先撤销旧设备。");
    }
    const trustSetChanged = !current || current.status !== "active";
    const timestamp = now();
    await this.store.set(documentID, { type: "device", deviceID: input.deviceID, accountID, publicKeyJWK, displayName: String(input.displayName || "设备").slice(0, 80), status: "active", registeredAt: current?.registeredAt || timestamp, updatedAt: timestamp });
    if (trustSetChanged) {
      const memberships = await this.store.find({ type: "membership", accountID, status: "active" });
      await Promise.all(memberships.map((item) => this.bumpGeneration(item.farmID, timestamp)));
    }
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

  async requestInsightDevice(accountID, input) {
    const deviceID = requiredUUID(input?.deviceID, "deviceID");
    if (!input.publicKeyJWK || typeof input.publicKeyJWK !== "object") {
      throw new APIError(400, "invalid_insight_device_key", "洞察设备公钥无效。");
    }
    const documentID = key("insight_device", `${accountID}:${deviceID}`);
    const current = await this.store.get(documentID);
    const publicKeyJWK = canonicalJSONString(input.publicKeyJWK);
    if (current?.publicKeyJWK && current.publicKeyJWK !== publicKeyJWK) {
      throw new APIError(409, "insight_device_key_mismatch", "该洞察设备已有不同公钥。");
    }
    const timestamp = now();
    const activeDevices = await this.store.find({ type: "insight_device", accountID, status: "active" });
    const status = activeDevices.length === 0 ? "active" : current?.status === "active" ? "active" : "pending";
    await this.store.set(documentID, {
      type: "insight_device",
      accountID,
      deviceID,
      publicKeyJWK,
      displayName: String(input.displayName || "设备").slice(0, 80),
      status,
      requestedAt: current?.requestedAt || timestamp,
      approvedAt: status === "active" ? current?.approvedAt || timestamp : null,
      revokedAt: null,
      updatedAt: timestamp,
    });
    const keyState = await this.store.get(key("insight_key_state", accountID));
    return {
      deviceID,
      status,
      requestedAt: current?.requestedAt || timestamp,
      keyVersion: Number(keyState?.keyVersion || 1),
    };
  }

  async insightDeviceRequests(accountID) {
    const values = await this.store.find({ type: "insight_device", accountID });
    return {
      devices: values.map((item) => ({
        deviceID: item.deviceID,
        displayName: item.displayName,
        publicKeyJWK: JSON.parse(item.publicKeyJWK),
        status: item.status,
        requestedAt: item.requestedAt,
        approvedAt: item.approvedAt || null,
        revokedAt: item.revokedAt || null,
      })),
    };
  }

  async approveInsightDevice(accountID, deviceID, input) {
    deviceID = requiredUUID(deviceID, "deviceID");
    const approverDeviceID = requiredUUID(input?.approverDeviceID, "approverDeviceID");
    const approver = await this.store.get(key("insight_device", `${accountID}:${approverDeviceID}`));
    if (approver?.status !== "active") {
      throw new APIError(403, "trusted_insight_device_required", "必须由已授权洞察设备批准。");
    }
    const documentID = key("insight_device", `${accountID}:${deviceID}`);
    const target = await this.store.get(documentID);
    if (!target || target.status !== "pending") {
      throw new APIError(404, "pending_insight_device_not_found", "未找到待批准的洞察设备。");
    }
    const sealedEnvelopeBase64 = validatedCiphertext(input?.sealedEnvelopeBase64, "sealedEnvelopeBase64");
    const keyVersion = Number(input?.keyVersion);
    if (!Number.isSafeInteger(keyVersion) || keyVersion < 1) {
      throw new APIError(400, "invalid_insight_key_version", "洞察密钥版本无效。");
    }
    const keyStateDocumentID = key("insight_key_state", accountID);
    const keyState = await this.store.get(keyStateDocumentID);
    if (keyState && Number(keyState.keyVersion) !== keyVersion) {
      throw new APIError(409, "stale_insight_key_version", "洞察密钥版本已变化，请刷新设备状态后重试。");
    }
    const timestamp = now();
    await this.store.set(key("insight_envelope", `${accountID}:${deviceID}:${keyVersion}`), {
      type: "insight_envelope",
      accountID,
      targetDeviceID: deviceID,
      keyVersion,
      sealedEnvelopeBase64,
      approvedByDeviceID: approverDeviceID,
      createdAt: timestamp,
      updatedAt: timestamp,
    });
    if (!keyState) {
      await this.store.set(keyStateDocumentID, {
        type: "insight_key_state",
        accountID,
        keyVersion,
        rotatedByDeviceID: approverDeviceID,
        updatedAt: timestamp,
      });
    }
    await this.store.update(documentID, { status: "active", approvedAt: timestamp, updatedAt: timestamp });
    return { deviceID, status: "active", keyVersion, approvedAt: timestamp };
  }

  async recoverInsightDevice(accountID, deviceID, input) {
    deviceID = requiredUUID(deviceID, "deviceID");
    const keyVersion = Number(input?.keyVersion);
    if (!Number.isSafeInteger(keyVersion) || keyVersion < 1) {
      throw new APIError(400, "invalid_insight_key_version", "洞察密钥版本无效。");
    }
    const recoveryProof = validatedRecoveryProof(input?.recoveryProofBase64);
    const sealedEnvelopeBase64 = validatedCiphertext(
      input?.sealedEnvelopeBase64,
      "sealedEnvelopeBase64"
    );
    const operation = async (store) => {
      const deviceDocumentID = key("insight_device", `${accountID}:${deviceID}`);
      const target = await store.get(deviceDocumentID);
      if (!target || target.status !== "pending") {
        throw new APIError(404, "pending_insight_device_not_found", "未找到待恢复的洞察设备。");
      }
      const recoveryDocumentID = key("insight_recovery", accountID);
      const recovery = await store.get(recoveryDocumentID);
      if (!recovery) {
        throw new APIError(404, "insight_recovery_not_found", "洞察恢复包不存在或已使用。");
      }
      const keyState = await store.get(key("insight_key_state", accountID));
      const currentKeyVersion = Number(keyState?.keyVersion || 1);
      if (keyVersion !== currentKeyVersion || Number(recovery.keyVersion) !== keyVersion) {
        throw new APIError(409, "stale_insight_recovery", "洞察恢复包已经失效，请在已授权设备上重新生成。");
      }
      const expectedDigest = String(recovery.proofDigest || "").trim().toLowerCase();
      const actualDigest = createHash("sha256").update(recoveryProof).digest();
      const expectedDigestBytes = /^[a-f0-9]{64}$/.test(expectedDigest)
        ? Buffer.from(expectedDigest, "hex")
        : Buffer.alloc(0);
      if (
        expectedDigestBytes.length !== actualDigest.length ||
        !timingSafeEqual(expectedDigestBytes, actualDigest)
      ) {
        throw new APIError(403, "invalid_insight_recovery_proof", "洞察恢复凭证无效。");
      }
      const timestamp = now();
      await store.set(
        key("insight_envelope", `${accountID}:${deviceID}:${keyVersion}`),
        {
          type: "insight_envelope",
          accountID,
          targetDeviceID: deviceID,
          keyVersion,
          sealedEnvelopeBase64,
          approvedByDeviceID: "recovery",
          createdAt: timestamp,
          updatedAt: timestamp,
        }
      );
      await store.update(deviceDocumentID, {
        status: "active",
        approvedAt: timestamp,
        updatedAt: timestamp,
      });
      await store.remove(recoveryDocumentID);
      return {
        deviceID,
        status: "active",
        keyVersion,
        approvedAt: timestamp,
        recoveryConsumed: true,
      };
    };
    return this.store.transaction ? this.store.transaction(operation) : operation(this.store);
  }

  async insightKeyEnvelopes(accountID, deviceID) {
    deviceID = requiredUUID(deviceID, "deviceID");
    const device = await this.store.get(key("insight_device", `${accountID}:${deviceID}`));
    if (!device || device.status === "revoked") {
      throw new APIError(404, "insight_device_not_found", "洞察设备不存在或已撤销。");
    }
    const values = await this.store.find({ type: "insight_envelope", accountID, targetDeviceID: deviceID });
    return {
      envelopes: values
        .sort((a, b) => Number(a.keyVersion) - Number(b.keyVersion))
        .map((item) => ({
          targetDeviceID: item.targetDeviceID,
          keyVersion: item.keyVersion,
          sealedEnvelopeBase64: item.sealedEnvelopeBase64,
          createdAt: item.createdAt,
        })),
    };
  }

  async revokeInsightDevice(accountID, deviceID, input) {
    deviceID = requiredUUID(deviceID, "deviceID");
    const requesterDeviceID = requiredUUID(input?.requesterDeviceID, "requesterDeviceID");
    if (requesterDeviceID === deviceID) {
      throw new APIError(400, "cannot_revoke_current_insight_device", "不能在当前设备上撤销自身。");
    }
    const requestedKeyVersion = Number(input?.keyVersion);
    const envelopes = Array.isArray(input?.envelopes) ? input.envelopes : [];
    const operation = async (store) => {
      const documentID = key("insight_device", `${accountID}:${deviceID}`);
      const requester = await store.get(key("insight_device", `${accountID}:${requesterDeviceID}`));
      const device = await store.get(documentID);
      if (requester?.status !== "active") {
        throw new APIError(403, "trusted_insight_device_required", "必须由已授权洞察设备发起撤销。");
      }
      if (!device || device.status !== "active") {
        throw new APIError(404, "active_insight_device_not_found", "未找到可撤销的洞察设备。");
      }
      const activeDevices = await store.find({ type: "insight_device", accountID, status: "active" });
      const remainingDevices = activeDevices.filter((item) => item.deviceID !== deviceID);
      if (!remainingDevices.length) {
        throw new APIError(409, "last_insight_device", "至少需要保留一台已授权洞察设备。");
      }
      const keyStateDocumentID = key("insight_key_state", accountID);
      const keyState = await store.get(keyStateDocumentID);
      const currentKeyVersion = Number(keyState?.keyVersion || 1);
      if (!Number.isSafeInteger(requestedKeyVersion) || requestedKeyVersion !== currentKeyVersion + 1) {
        throw new APIError(409, "invalid_insight_key_rotation", "撤销设备必须将个人主密钥版本递增一次。");
      }
      if (envelopes.length !== remainingDevices.length || envelopes.length > 20) {
        throw new APIError(400, "incomplete_insight_key_envelopes", "必须为每台保留设备提供新密钥信封。");
      }
      const remainingIDs = new Set(remainingDevices.map((item) => item.deviceID));
      const seenIDs = new Set();
      const validatedEnvelopes = envelopes.map((value) => {
        const targetDeviceID = requiredUUID(value?.targetDeviceID, "targetDeviceID");
        if (!remainingIDs.has(targetDeviceID) || seenIDs.has(targetDeviceID)) {
          throw new APIError(400, "invalid_insight_key_envelope_target", "新密钥信封的目标设备无效。");
        }
        seenIDs.add(targetDeviceID);
        return {
          targetDeviceID,
          sealedEnvelopeBase64: validatedCiphertext(value?.sealedEnvelopeBase64, "sealedEnvelopeBase64"),
        };
      });
      const timestamp = now();
      await store.update(documentID, {
        status: "revoked",
        revokedAt: timestamp,
        updatedAt: timestamp,
      });
      for (const envelope of validatedEnvelopes) {
        await store.set(
          key("insight_envelope", `${accountID}:${envelope.targetDeviceID}:${requestedKeyVersion}`),
          {
            type: "insight_envelope",
            accountID,
            targetDeviceID: envelope.targetDeviceID,
            keyVersion: requestedKeyVersion,
            sealedEnvelopeBase64: envelope.sealedEnvelopeBase64,
            approvedByDeviceID: requesterDeviceID,
            createdAt: timestamp,
            updatedAt: timestamp,
          }
        );
      }
      await store.set(keyStateDocumentID, {
        type: "insight_key_state",
        accountID,
        keyVersion: requestedKeyVersion,
        rotatedByDeviceID: requesterDeviceID,
        updatedAt: timestamp,
      });
      await store.remove(key("insight_recovery", accountID)).catch(() => undefined);
      return {
        deviceID,
        status: "revoked",
        requiresKeyRotation: false,
        recoveryReset: true,
        keyVersion: requestedKeyVersion,
        revokedAt: timestamp,
      };
    };
    return this.store.transaction ? this.store.transaction(operation) : operation(this.store);
  }

  async syncInsightRecords(accountID, input) {
    const deviceID = requiredUUID(input?.deviceID, "deviceID");
    const device = await this.store.get(key("insight_device", `${accountID}:${deviceID}`));
    if (device?.status !== "active") {
      throw new APIError(403, "active_insight_device_required", "当前设备未获准同步洞察密文。");
    }
    const cursor = Math.max(0, Number(input?.cursor || 0));
    const outgoing = Array.isArray(input?.records) ? input.records : [];
    if (outgoing.length > 200) throw new APIError(400, "too_many_insight_records", "单次最多同步 200 条洞察密文。");
    const keyStateDocumentID = key("insight_key_state", accountID);
    let keyState = await this.store.get(keyStateDocumentID);
    let currentKeyVersion = Number(keyState?.keyVersion || 1);
    let clock = await this.store.get(key("insight_clock", accountID));
    let nextClock = Math.max(Date.now() * 1000, Number(clock?.cursor || 0) + 1);
    for (const value of outgoing) {
      const recordID = requiredUUID(value.recordID, "recordID");
      const recordKind = String(value.recordKind || "");
      if (!["conversation", "message", "attachment", "action_draft", "receipt", "vault"].includes(recordKind)) {
        throw new APIError(400, "invalid_insight_record_kind", "洞察记录类型无效。");
      }
      const revision = Number(value.revision);
      if (!Number.isSafeInteger(revision) || revision < 1) {
        throw new APIError(400, "invalid_insight_revision", "洞察记录版本无效。");
      }
      const ciphertextBase64 = validatedCiphertext(value.ciphertextBase64);
      const conversationID = value.conversationID == null
        ? null
        : requiredUUID(value.conversationID, "conversationID");
      const recordKeyVersion = ciphertextKeyVersion(ciphertextBase64);
      if (!keyState && currentKeyVersion === 1 && recordKeyVersion !== 1) {
        currentKeyVersion = recordKeyVersion;
      }
      if (recordKeyVersion !== currentKeyVersion) {
        throw new APIError(409, "stale_insight_key_version", "洞察密文使用了已过期的个人主密钥。");
      }
      const documentID = key("insight_record", `${accountID}:${recordID}`);
      const current = await this.store.get(documentID);
      if (current && Number(current.revision) > revision) continue;
      const timestamp = nextClock++;
      await this.store.set(documentID, {
        type: "insight_record",
        accountID,
        recordID,
        recordKind,
        conversationID,
        revision,
        ciphertextBase64,
        deletedAt: value.deletedAt == null ? null : Number(value.deletedAt),
        createdAt: current?.createdAt || timestamp,
        updatedAt: timestamp,
      });
    }
    if (!keyState && outgoing.length) {
      keyState = {
        type: "insight_key_state",
        accountID,
        keyVersion: currentKeyVersion,
        rotatedByDeviceID: deviceID,
        updatedAt: now(),
      };
      await this.store.set(keyStateDocumentID, keyState);
    }
    if (outgoing.length) {
      await this.store.set(key("insight_clock", accountID), {
        type: "insight_clock",
        accountID,
        cursor: nextClock - 1,
        updatedAt: now(),
      });
    }
    await this.purgeExpiredInsightTombstones(accountID);
    const all = await this.store.find({ type: "insight_record", accountID }, 1000);
    const changes = all
      .filter((item) => Number(item.updatedAt || 0) > cursor)
      .sort((a, b) => Number(a.updatedAt) - Number(b.updatedAt))
      .slice(0, 200);
    const nextCursor = changes.reduce((value, item) => Math.max(value, Number(item.updatedAt || 0)), cursor);
    return {
      cursor: nextCursor,
      keyVersion: currentKeyVersion,
      hasMore: all.some((item) => Number(item.updatedAt || 0) > nextCursor),
      records: changes.map((item) => ({
        recordID: item.recordID,
        recordKind: item.recordKind,
        conversationID: item.conversationID || null,
        revision: item.revision,
        ciphertextBase64: item.ciphertextBase64,
        deletedAt: item.deletedAt,
        updatedAt: item.updatedAt,
      })),
    };
  }

  async purgeExpiredInsightTombstones(accountID) {
    const all = await this.store.find({ type: "insight_record", accountID }, 1000);
    const cutoff = Date.now() - insightTombstoneRetentionMilliseconds;
    const expiredConversations = all.filter((item) =>
      item.recordKind === "conversation" &&
      item.deletedAt != null &&
      Number(item.deletedAt) <= cutoff
    );
    const expiredConversationIDs = new Set(expiredConversations.map((item) => item.recordID));
    const expired = all.filter((item) =>
      expiredConversationIDs.has(item.recordID) ||
      expiredConversationIDs.has(item.conversationID) ||
      item.deletedAt != null && Number(item.deletedAt) <= cutoff
    );
    await Promise.all(expired.map((item) =>
      this.store.remove(item._documentID).catch(() => undefined)
    ));
  }

  async updateInsightRecovery(accountID, input) {
    const deviceID = requiredUUID(input?.deviceID, "deviceID");
    const ciphertextBase64 = validatedCiphertext(input?.ciphertextBase64);
    const keyVersion = Number(input?.keyVersion);
    if (!Number.isSafeInteger(keyVersion) || keyVersion < 1) {
      throw new APIError(400, "invalid_insight_key_version", "洞察恢复包密钥版本无效。");
    }
    const proofDigest = String(input?.proofDigest || "").trim().toLowerCase();
    if (!/^[a-f0-9]{64}$/.test(proofDigest)) {
      throw new APIError(400, "invalid_insight_recovery_digest", "洞察恢复凭证摘要无效。");
    }
    const operation = async (store) => {
      const device = await store.get(key("insight_device", `${accountID}:${deviceID}`));
      if (device?.status !== "active") {
        throw new APIError(403, "trusted_insight_device_required", "必须由已授权洞察设备生成恢复包。");
      }
      const keyState = await store.get(key("insight_key_state", accountID));
      if (Number(keyState?.keyVersion || 1) !== keyVersion) {
        throw new APIError(409, "stale_insight_key_version", "洞察密钥版本已变化，请重新生成恢复码。");
      }
      const timestamp = now();
      await store.set(key("insight_recovery", accountID), {
        type: "insight_recovery",
        accountID,
        keyVersion,
        ciphertextBase64,
        proofDigest,
        createdByDeviceID: deviceID,
        updatedAt: timestamp,
      });
      return { keyVersion, updatedAt: timestamp };
    };
    return this.store.transaction ? this.store.transaction(operation) : operation(this.store);
  }

  async insightRecovery(accountID) {
    const value = await this.store.get(key("insight_recovery", accountID));
    if (!value) return { recovery: null };
    return {
      recovery: {
        keyVersion: value.keyVersion,
        ciphertextBase64: value.ciphertextBase64,
        updatedAt: value.updatedAt,
      },
    };
  }

  async removeInsightRecovery(accountID) {
    await this.store.remove(key("insight_recovery", accountID)).catch(() => undefined);
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
    const shareParticipantID = normalizedShareParticipantID(input.shareParticipantID);
    const shareURL = normalizedCloudShareURL(input.shareURL);
    const inviteID = randomUUID();
    const timestamp = now();
    await this.store.set(key("invite", inviteID), {
      type: "invite",
      inviteID,
      farmID,
      createdByAccountID: accountID,
      role: input.role,
      codeHash: hash(code),
      shareParticipantID,
      shareParticipantIDHash: shareParticipantID ? hash(shareParticipantID) : null,
      shareURL,
      expiresAt: timestamp + 86400,
      usedAt: null,
      createdAt: timestamp,
    });
    return { inviteID, code, role: input.role, expiresAt: timestamp + 86400, shareParticipantID };
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
    const shareParticipantID = normalizedShareParticipantID(input.shareParticipantID);
    const cloudKitUserRecordName = normalizedCloudKitUserRecordName(input.cloudKitUserRecordName);
    let committedResponse;
    const lookup = shareParticipantID
      ? { type: "invite", shareParticipantIDHash: hash(shareParticipantID) }
      : { type: "invite", codeHash: hash(normalized) };
    try {
      const matchedInvite = (await this.store.find(lookup, 2))[0];
      const inviteID = String(matchedInvite?.inviteID || "").trim();
      const farmID = String(matchedInvite?.farmID || "").trim();
      const role = matchedInvite?.role;
      if (!matchedInvite) {
        throw new APIError(400, "invalid_invite", "邀请码无效、已使用或已过期。");
      }
      if (!inviteID || !farmID || !role) {
        throw new APIError(500, "invite_record_incomplete", "邀请记录不完整，请让场主重新生成邀请。");
      }
      const inviteDocumentID = key("invite", inviteID);
      const operation = async (store) => {
        const transactionInvite = await store.get(inviteDocumentID);
        if (!transactionInvite || transactionInvite.expiresAt <= now()) {
          throw new APIError(400, "invalid_invite", "邀请码无效、已使用或已过期。");
        }
        const invite = {
          ...matchedInvite,
          ...transactionInvite,
          inviteID,
          farmID,
          role,
        };
      if (invite.usedAt) {
        if (invite.redeemedByAccountID !== accountID) {
          throw new APIError(400, "invalid_invite", "邀请码无效、已使用或已过期。");
        }
        committedResponse = {
          inviteID,
          farmID,
          role,
          membershipStatus: "pendingShareConfirmation",
        };
        if (invite.shareURL) committedResponse.shareURL = invite.shareURL;
        return committedResponse;
      }
      if (!invite.shareParticipantID && !cloudKitUserRecordName) {
        throw new APIError(400, "missing_cloudkit_user", "请先登录 iCloud，再提交加入申请。");
      }
      const timestamp = now();
      const memberKey = key("membership", `${farmID}:${accountID}`);
      const existing = await store.get(memberKey);
      if (existing?.status === "active") throw new APIError(409, "membership_already_active", "当前账号已经是该牧场成员。");
      await store.update(inviteDocumentID, {
        redeemedByAccountID: accountID,
        redeemedCloudKitUserRecordName: cloudKitUserRecordName,
        redeemedAt: timestamp,
        usedAt: timestamp,
      });
      await store.set(memberKey, { type: "membership", membershipID: existing?.membershipID || randomUUID(), farmID, accountID, role, status: "pending", shareParticipantRecordName: null, createdAt: existing?.createdAt || timestamp, updatedAt: timestamp });
      committedResponse = {
        inviteID,
        farmID,
        role,
        membershipStatus: "pendingShareConfirmation",
      };
      if (invite.shareURL) committedResponse.shareURL = invite.shareURL;
      return committedResponse;
      };
      const transactionResponse = this.store.transaction
        ? await this.store.transaction(operation)
        : await operation(this.store);
      if (committedResponse) return committedResponse;
      if (
        transactionResponse &&
        typeof transactionResponse === "object" &&
        typeof transactionResponse.inviteID === "string"
      ) {
        return transactionResponse;
      }
      throw new APIError(500, "invite_redeem_response_missing", "邀请码已处理，但服务未返回加入结果，请重试。");
    } catch (error) {
      if (error.code === "invalid_invite") await this.recordInviteFailure(accountID);
      throw error;
    }
  }

  async pendingInvites(accountID, farmID) {
    farmID = canonicalFarmID(farmID);
    await this.requireOwner(farmID, accountID);
    const timestamp = now();
    const invites = await this.store.find({ type: "invite", farmID });
    return invites
      .filter((invite) =>
        invite.redeemedByAccountID &&
        !invite.confirmedAt &&
        invite.expiresAt > timestamp &&
        (invite.shareParticipantID || invite.redeemedCloudKitUserRecordName)
      )
      .map((invite) => ({
        inviteID: invite.inviteID,
        farmID: invite.farmID,
        role: invite.role,
        shareParticipantID: invite.shareParticipantID || null,
        cloudKitUserRecordName: invite.redeemedCloudKitUserRecordName || null,
        expiresAt: invite.expiresAt,
      }));
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
    await this.store.update(key("invite", invite.inviteID), { confirmedAt: timestamp });
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
    return {
      accountID,
      displayName: account?.displayName,
      status: account?.status || "active",
      features: { mimoInsights: true },
      memberships: visible.map((item) => ({ farm_id: item.farmID, ownerAccountID: item.farm.ownerAccountID, role: item.role, status: item.status, cloudZoneName: item.farm.cloudZoneName, shareRecordName: item.farm.shareRecordName || null })),
    };
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
    const insightTypes = ["insight_device", "insight_envelope", "insight_record", "insight_recovery", "insight_clock", "insight_key_state"];
    const insightRecords = (await Promise.all(
      insightTypes.map((type) => this.store.find({ type, accountID }, 1000))
    )).flat();
    await Promise.all(insightRecords.map((item) => this.store.remove(item._documentID)));
    await this.store.update(key("account", accountID), {
      status: "deleted",
      displayName: "已删除账户",
      avatarDataBase64: null,
      avatarDigest: null,
      avatarRevision: Date.now(),
      updatedAt: timestamp,
    });
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
