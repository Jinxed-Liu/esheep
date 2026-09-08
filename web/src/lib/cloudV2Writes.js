import { browserIdentity, patchDraft, reserveSequences, listDrafts } from "./draftStore.js";

const encoder = new TextEncoder();
const base64 = (bytes) => btoa(Array.from(bytes, (byte) => String.fromCharCode(byte)).join(""));
export async function sha256(bytes) {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function signCommand(command, identity) {
  const bytes = encoder.encode(JSON.stringify(command));
  const digest = await sha256(bytes);
  const signingData = encoder.encode(["esheep-cloud-command-v2", command.farmID.toLowerCase(),
    command.farmGeneration, command.accountID.toLowerCase(), command.deviceID.toLowerCase(),
    command.deviceSequence, command.commandID.toLowerCase(), digest].join("\n"));
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, identity.privateKey, signingData));
  return { unsigned_command_base64: base64(bytes), content_digest: digest, device_signature_base64: base64(signature) };
}

export function commandEnvelope(spec, { accountID, farm, deviceID, sequence, bundleID, sourceRequestID }) {
  return {
    protocolVersion: 2, schemaVersion: 1, commandID: spec.commandID ?? crypto.randomUUID(),
    sourceRequestID, bundleID: bundleID ?? null, farmID: farm.id.toLowerCase(), farmGeneration: farm.generation,
    accountID: accountID.toLowerCase(), deviceID, deviceSequence: sequence,
    createdAt: Date.now(), occurredAt: spec.occurredAt, commandKind: spec.kind,
    payload: { kind: spec.kind, body: spec.body },
    affectedStreams: spec.streams.sort((a, b) => a.type.localeCompare(b.type) || a.id.localeCompare(b.id)),
    affectedFields: spec.fields ?? [], fieldChanges: spec.changes ?? [],
    prerequisiteCommandIDs: spec.prerequisites ?? [], requiredAssetIDs: [],
  };
}

export function interpretResults(commands, response) {
  if (!Array.isArray(response?.results)) throw new Error("云端未返回完整回执，结果待核对，请重试查询。");
  const resultByID = new Map(response.results.map((item) => [item.command_id?.toLowerCase(), item]));
  const receipts = commands.map((command) => resultByID.get(command.commandID.toLowerCase()));
  if (receipts.some((receipt) => !receipt)) throw new Error("部分命令缺少云端回执，结果待核对。");
  const effective = receipts.map((receipt) => receipt.type === "duplicate" ? receipt.original : receipt);
  if (effective.some((receipt) => !receipt?.type)) throw new Error("重复请求缺少原始回执，结果待核对。");
  const accepted = effective.every((receipt) => receipt.type === "accepted");
  return { status: accepted ? "accepted" : effective.some((r) => r.type === "needs_confirmation") ? "conflict" : "rejected", receipts };
}

// Serialize each browser account's submissions across tabs. An uncertain result
// always retries the same signed bytes: new IDs would create duplicate facts.
export async function submitDraft(client, accountID, farm, draft, buildSpecifications) {
  if (!navigator.locks) throw new Error("浏览器不支持多窗口安全提交，请更新浏览器。");
  return navigator.locks.request(`esheep-write:${accountID}`, async () => {
    draft = (await listDrafts(accountID, farm.id)).find((item) => item.id === draft.id);
    if (!draft) throw new Error("未找到原始草稿。");
    if (draft.status === "accepted") return draft;
    if (draft.status === "discarded") throw new Error("这份草稿已放弃。");
    const { data: auth, error: authError } = await client.auth.getUser();
    if (authError || !auth?.user) throw new Error("登录已过期，草稿已保留，请重新登录。");
    const { data: status, error: statusError } = await client.rpc("esheep_cloud_fetch_status_v2", { p_farm_id: farm.id });
    if (statusError) throw statusError;
    if (status.farm_generation !== draft.generation || draft.farmID !== farm.id.toLowerCase()) throw new Error("牧场版本已变更，请核对原草稿后重新录入。");
    if (!status.v2_ready || status.write_frozen) throw new Error("牧场暂不可写入，草稿已保留。");
    if (!draft.signed && Number.isSafeInteger(farm.revision) && status.cloud_head !== farm.revision) throw new Error("牧场已有新的云端记录，请先刷新资料再提交；草稿已保留。");
    if (draft.signed) {
      const previous = await client.rpc("esheep_cloud_query_command_status_v2", { p_farm_id: farm.id,
        p_command_ids: draft.commands.map((command) => command.commandID) });
      if (previous.error) throw previous.error;
      if (previous.data?.results?.length === draft.commands.length) {
        const results = previous.data.results.map((row) => ({ ...row.result, command_id: row.command_id }));
        return patchDraft(accountID, draft.id, { ...interpretResults(draft.commands, { results }), error: null });
      }
    }
    let prepared = draft;
    if (!draft.signed) {
      const specifications = await buildSpecifications();
      if (!specifications.length || specifications.length > 25) throw new Error("单次业务操作最多包含 25 个关联命令，请拆分批次。");
      const identity = await browserIdentity(accountID);
      const { error } = await client.rpc("register_device", { p_device_id: identity.id,
        p_public_key_jwk: identity.publicKeyJWK, p_display_name: "eSheep+ 网页", p_tmr_data_protocol_version: 1 });
      if (error) throw error;
      const first = await reserveSequences(accountID, specifications.length, status.device_sequence_floor ?? 0);
      const bundleID = specifications.length > 1 ? crypto.randomUUID() : null;
      const commands = specifications.map((spec, index) => commandEnvelope(spec, { accountID, farm,
        deviceID: identity.id, sequence: first + index, bundleID, sourceRequestID: index===0?draft.id:crypto.randomUUID() }));
      const signed = await Promise.all(commands.map((command) => signCommand(command, identity)));
      prepared = await patchDraft(accountID, draft.id, { commands, signed, status: "pending", error: null });
    }
    try {
      await patchDraft(accountID, draft.id, { status: "pending", error: null });
      const { data, error } = await client.functions.invoke("esheep-cloud-v2-writes", {
        body: { action: "submit_commands", farm_id: farm.id, farm_generation: draft.generation, commands: prepared.signed },
      });
      if (error) throw error;
      return await patchDraft(accountID, draft.id, { ...interpretResults(prepared.commands, data), error: null });
    } catch (error) {
      await patchDraft(accountID, draft.id, { status: "unknown", error: error.message || "结果待核对" });
      throw error;
    }
  });
}
