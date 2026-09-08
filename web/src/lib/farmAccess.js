// Shared by the browser and assistant authorization. Membership discovery
// must follow the farm's authority provider; an empty V1 list is not proof
// that the account has no farm after a V2 cutover.
export async function listAccessibleFarms(client, { signal } = {}) {
  const query = (name) => {
    const request = client.rpc(name);
    return signal ? request.abortSignal(signal) : request;
  };
  const [v2, legacy] = await Promise.all([
    query("esheep_cloud_list_my_farms_v2"),
    query("list_my_active_farm_access"),
  ]);
  if (v2.error) throw v2.error;
  if (legacy.error) throw legacy.error;
  if (!Array.isArray(v2.data?.farms) || !Array.isArray(legacy.data)) {
    throw new Error("牧场权限响应不完整，请重试。");
  }
  const farms = new Map(legacy.data.map((row) => [row.farm_id.toLowerCase(), row]));
  for (const row of v2.data.farms) {
    if (!row.farm_id || !Number.isSafeInteger(row.farm_generation) || row.farm_generation < 0 ||
        !["owner", "administrator", "worker"].includes(row.role)) {
      throw new Error("牧场权限响应不完整，请重试。");
    }
    farms.set(row.farm_id.toLowerCase(), {
      farm_id: row.farm_id,
      member_role: row.role,
      member_app_account_id: row.member_account_id,
      provider: "esheep_cloud",
      farm_status: row.initial_sync_ready ? "active" : "preparing",
      authority_generation: row.farm_generation,
      initial_sync_ready: row.initial_sync_ready === true,
    });
  }
  return [...farms.values()];
}

export async function redeemAccessibleFarmInvite(client, code) {
  const normalizedCode = String(code ?? "").trim();
  if (!normalizedCode) throw new Error("请输入牧场邀请码。");
  // V2 codes are 32 random bytes encoded as unpadded Base64URL. Do not
  // submit the same invitation to two endpoints after an uncertain result.
  const isV2 = /^[A-Za-z0-9_-]{43}$/.test(normalizedCode);
  const { data, error } = await client.rpc(
    isV2 ? "esheep_cloud_redeem_invite_v2" : "redeem_farm_invite",
    { p_code: normalizedCode },
  );
  if (error) {
    if (/invite.*(invalid|expired|used)/i.test(error.message ?? "")) {
      throw new Error("邀请码无效、已使用或已过期，请联系场主重新生成。");
    }
    throw error;
  }
  const redemption = isV2 ? data : data?.[0];
  if (!redemption?.farm_id) throw new Error("邀请码已处理，但没有返回可访问的牧场。");
  return redemption;
}
