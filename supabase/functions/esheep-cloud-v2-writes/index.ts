import { createClient } from "npm:@supabase/supabase-js@2.112.3";

type SignedCommand = {
  unsigned_command_base64: string;
  content_digest: string;
  device_signature_base64: string;
};

type SubmitRequest = {
  action: "submit_commands";
  farm_id: string;
  farm_generation: number;
  commands: SignedCommand[];
};

type ResolutionRequest = {
  action: "resolve_attention";
  farm_id: string;
  farm_generation: number;
  attention_id: string;
  resolution_command_id: string;
  choice: "use_this_device" | "keep_cloud" | "abandon_operation" | "resubmit";
  expected_cloud_value_digest: string;
  account_id: string;
  device_id: string;
  device_sequence: number;
  device_signature_base64: string;
};

type ConfirmAssetRequest = {
  action: "confirm_asset";
  farm_id: string;
  farm_generation: number;
  asset_id: string;
  variant: "thumbnail" | "avatar" | "original";
};

type WriteRequest = SubmitRequest | ResolutionRequest | ConfirmAssetRequest;

type AssetVerificationTarget = {
  asset_id: string;
  variant: string;
  bucket: string;
  object_key: string;
  expected_sha256: string;
  expected_byte_count: number;
};

type DeviceRow = {
  device_id: string;
  user_id: string;
  public_key_jwk: JsonWebKey;
  status: string;
};

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const digestPattern = /^[0-9a-f]{64}$/;

const requiredEnvironment = (name: string): string => {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`missing_${name.toLowerCase()}`);
  return value;
};

const response = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });

const decodeBase64 = (value: string): Uint8Array => {
  const binary = atob(value.replaceAll(/\s/g, ""));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
};

const sha256Hex = async (value: Uint8Array): Promise<string> => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", value));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
};

const requireUUID = (value: unknown, field: string): string => {
  if (typeof value !== "string" || !uuidPattern.test(value)) {
    throw new Error(`invalid_${field}`);
  }
  return value.toLowerCase();
};

const requirePositiveInteger = (value: unknown, field: string): number => {
  if (!Number.isSafeInteger(value) || Number(value) < 1) {
    throw new Error(`invalid_${field}`);
  }
  return Number(value);
};

const requireNonnegativeInteger = (value: unknown, field: string): number => {
  if (!Number.isSafeInteger(value) || Number(value) < 0) {
    throw new Error(`invalid_${field}`);
  }
  return Number(value);
};

const verifyP256 = async (
  publicKeyJWK: JsonWebKey,
  signature: Uint8Array,
  signingData: Uint8Array,
): Promise<boolean> => {
  if (
    publicKeyJWK.kty !== "EC" || publicKeyJWK.crv !== "P-256" ||
    typeof publicKeyJWK.x !== "string" || typeof publicKeyJWK.y !== "string" ||
    signature.byteLength !== 64
  ) return false;
  const key = await crypto.subtle.importKey(
    "jwk",
    { ...publicKeyJWK, ext: true },
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  return await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    signature,
    signingData,
  );
};

const commandSigningData = (
  unsigned: Record<string, unknown>,
  digest: string,
): Uint8Array => {
  const values = [
    "esheep-cloud-command-v2",
    requireUUID(unsigned.farmID, "farm_id"),
    String(requireNonnegativeInteger(unsigned.farmGeneration, "farm_generation")),
    requireUUID(unsigned.accountID, "account_id"),
    requireUUID(unsigned.deviceID, "device_id"),
    String(requirePositiveInteger(unsigned.deviceSequence, "device_sequence")),
    requireUUID(unsigned.commandID, "command_id"),
    digest,
  ];
  return new TextEncoder().encode(values.join("\n"));
};

const resolutionSigningData = (request: ResolutionRequest): Uint8Array =>
  new TextEncoder().encode([
    "esheep-cloud-attention-resolution-v2",
    requireUUID(request.attention_id, "attention_id"),
    requireUUID(request.resolution_command_id, "resolution_command_id"),
    request.choice,
    request.expected_cloud_value_digest.toLowerCase(),
    String(requireNonnegativeInteger(request.farm_generation, "farm_generation")),
    requireUUID(request.account_id, "account_id"),
    requireUUID(request.device_id, "device_id"),
    String(requirePositiveInteger(request.device_sequence, "device_sequence")),
  ].join("\n"));

const authenticatedUser = async (request: Request, url: string, anonymousKey: string) => {
  const authorization = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(authorization);
  if (!match) throw new Error("authentication_required");
  const client = createClient(url, anonymousKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: authorization } },
  });
  const { data, error } = await client.auth.getUser(match[1]);
  if (error || !data.user) throw new Error("authentication_required");
  return data.user;
};

const activeDevice = async (
  admin: ReturnType<typeof createClient>,
  userID: string,
  deviceID: string,
): Promise<DeviceRow> => {
  const { data, error } = await admin
    .from("devices")
    .select("device_id,user_id,public_key_jwk,status")
    .eq("device_id", deviceID)
    .eq("user_id", userID)
    .eq("status", "active")
    .maybeSingle();
  if (error || !data) throw new Error("device_identity_mismatch");
  return data as DeviceRow;
};

const submitCommands = async (
  admin: ReturnType<typeof createClient>,
  userID: string,
  request: SubmitRequest,
): Promise<unknown> => {
  const farmID = requireUUID(request.farm_id, "farm_id");
  const farmGeneration = requireNonnegativeInteger(request.farm_generation, "farm_generation");
  if (!Array.isArray(request.commands) || request.commands.length < 1 || request.commands.length > 25) {
    throw new Error("invalid_command_batch");
  }

  const devices = new Map<string, DeviceRow>();
  for (const signed of request.commands) {
    if (
      typeof signed?.unsigned_command_base64 !== "string" ||
      typeof signed?.content_digest !== "string" ||
      typeof signed?.device_signature_base64 !== "string"
    ) throw new Error("invalid_signed_command");
    const unsignedBytes = decodeBase64(signed.unsigned_command_base64);
    const digest = signed.content_digest.toLowerCase();
    if (!digestPattern.test(digest) || await sha256Hex(unsignedBytes) !== digest) {
      throw new Error("command_digest_mismatch");
    }
    let unsigned: Record<string, unknown>;
    try {
      unsigned = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(unsignedBytes));
    } catch {
      throw new Error("invalid_unsigned_command");
    }
    if (
      requireUUID(unsigned.farmID, "farm_id") !== farmID ||
      requireNonnegativeInteger(unsigned.farmGeneration, "farm_generation") !== farmGeneration
    ) throw new Error("command_scope_mismatch");
    const deviceID = requireUUID(unsigned.deviceID, "device_id");
    let device = devices.get(deviceID);
    if (!device) {
      device = await activeDevice(admin, userID, deviceID);
      devices.set(deviceID, device);
    }
    const signature = decodeBase64(signed.device_signature_base64);
    if (!await verifyP256(device.public_key_jwk, signature, commandSigningData(unsigned, digest))) {
      throw new Error("device_signature_invalid");
    }
  }

  const { data, error } = await admin.rpc("esheep_cloud_submit_verified_commands_v2", {
    p_user_id: userID,
    p_farm_id: farmID,
    p_farm_generation: farmGeneration,
    p_commands: request.commands,
  });
  if (error) throw new Error(`transaction_${error.code ?? "failed"}`);
  return data;
};

const resolveAttention = async (
  admin: ReturnType<typeof createClient>,
  userID: string,
  request: ResolutionRequest,
): Promise<unknown> => {
  const deviceID = requireUUID(request.device_id, "device_id");
  if (!digestPattern.test(request.expected_cloud_value_digest.toLowerCase())) {
    throw new Error("invalid_cloud_value_digest");
  }
  const device = await activeDevice(admin, userID, deviceID);
  if (!await verifyP256(
    device.public_key_jwk,
    decodeBase64(request.device_signature_base64),
    resolutionSigningData(request),
  )) throw new Error("device_signature_invalid");

  const { data, error } = await admin.rpc("esheep_cloud_resolve_verified_attention_v2", {
    p_user_id: userID,
    p_farm_id: requireUUID(request.farm_id, "farm_id"),
    p_farm_generation: requireNonnegativeInteger(request.farm_generation, "farm_generation"),
    p_attention_id: requireUUID(request.attention_id, "attention_id"),
    p_resolution_command_id: requireUUID(request.resolution_command_id, "resolution_command_id"),
    p_choice: request.choice,
    p_expected_cloud_value_digest: request.expected_cloud_value_digest.toLowerCase(),
    p_account_id: requireUUID(request.account_id, "account_id"),
    p_device_id: deviceID,
    p_device_sequence: requirePositiveInteger(request.device_sequence, "device_sequence"),
    p_device_signature_base64: request.device_signature_base64,
  });
  if (error) throw new Error(`transaction_${error.code ?? "failed"}`);
  return data;
};

const confirmAsset = async (
  admin: ReturnType<typeof createClient>,
  userID: string,
  request: ConfirmAssetRequest,
): Promise<unknown> => {
  const farmID = requireUUID(request.farm_id, "farm_id");
  const farmGeneration = requireNonnegativeInteger(request.farm_generation, "farm_generation");
  const assetID = requireUUID(request.asset_id, "asset_id");
  if (!["thumbnail", "avatar", "original"].includes(request.variant)) {
    throw new Error("invalid_asset_variant");
  }
  const { data: targetData, error: targetError } = await admin.rpc(
    "esheep_cloud_asset_verification_target_v2",
    {
      p_user_id: userID,
      p_farm_id: farmID,
      p_farm_generation: farmGeneration,
      p_asset_id: assetID,
      p_variant: request.variant,
    },
  );
  if (targetError || !targetData) {
    throw new Error(`transaction_${targetError?.code ?? "asset_target_failed"}`);
  }
  const target = targetData as AssetVerificationTarget;
  if (
    requireUUID(target.asset_id, "target_asset_id") !== assetID ||
    target.variant !== request.variant ||
    target.bucket !== "esheep-cloud-assets" ||
    typeof target.object_key !== "string" || target.object_key.length < 1 ||
    typeof target.expected_sha256 !== "string" ||
    !digestPattern.test(target.expected_sha256) ||
    requirePositiveInteger(target.expected_byte_count, "expected_byte_count") > 52_428_800
  ) throw new Error("invalid_asset_verification_target");

  const { data: object, error: downloadError } = await admin.storage
    .from(target.bucket)
    .download(target.object_key);
  if (downloadError || !object) throw new Error("asset_object_unavailable");
  const bytes = new Uint8Array(await object.arrayBuffer());
  const actualDigest = await sha256Hex(bytes);
  if (
    bytes.byteLength !== target.expected_byte_count ||
    actualDigest !== target.expected_sha256
  ) throw new Error("asset_content_verification_failed");

  const { data, error } = await admin.rpc("esheep_cloud_confirm_verified_asset_v2", {
    p_user_id: userID,
    p_farm_id: farmID,
    p_farm_generation: farmGeneration,
    p_asset_id: assetID,
    p_variant: request.variant,
    p_actual_sha256: actualDigest,
    p_actual_byte_count: bytes.byteLength,
  });
  if (error) throw new Error(`transaction_${error.code ?? "asset_confirmation_failed"}`);
  return data;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return response(405, { error: "method_not_allowed" });
  try {
    const url = requiredEnvironment("SUPABASE_URL");
    const user = await authenticatedUser(
      request,
      url,
      requiredEnvironment("SUPABASE_ANON_KEY"),
    );
    const admin = createClient(url, requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const body = await request.json() as WriteRequest;
    const result = body.action === "submit_commands"
      ? await submitCommands(admin, user.id, body)
      : body.action === "resolve_attention"
      ? await resolveAttention(admin, user.id, body)
      : body.action === "confirm_asset"
      ? await confirmAsset(admin, user.id, body)
      : (() => { throw new Error("unsupported_action"); })();
    return response(200, result);
  } catch (error) {
    const code = error instanceof Error ? error.message : "write_verification_failed";
    const status = code === "authentication_required" ? 401
      : code.includes("signature") || code.includes("identity") ? 403
      : code.startsWith("transaction_") ? 409
      : 400;
    return response(status, { error: code });
  }
});
