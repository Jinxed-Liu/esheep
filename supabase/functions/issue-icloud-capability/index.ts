import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

const KEY_ID = "development-2026-08-supabase-v1";
const ISSUER = "esheep-next-identity";
const AUDIENCE = "esheep-next-cloud-operation";
const DEFAULT_TTL_SECONDS = 7 * 24 * 60 * 60;
const REUSE_REMAINING_SECONDS = 24 * 60 * 60;

type FarmRole = "owner" | "administrator" | "worker";

interface IssueRequest {
  farmID: string;
  ownerAppAccountID: string;
  deviceID: string;
  zoneName: string;
  zoneOwnerName: string;
  observedSecurityGeneration: number;
}

interface RegistryRow {
  farm_id: string;
  owner_user_id: string;
  provider: string;
  status: string;
  authority_generation: number;
}

interface MemberRow {
  farm_id: string;
  user_id: string;
  app_account_id: string;
  role: FarmRole;
  status: string;
}

interface DeviceRow {
  device_id: string;
  user_id: string;
  public_key_jwk: Record<string, unknown>;
  status: string;
}

interface CertificateRow {
  certificate_id: string;
  certificate_jws: string;
  role: FarmRole;
  capabilities: string[];
  issued_at: string;
  expires_at: string;
}

const CAPABILITIES: Record<FarmRole, string[]> = {
  owner: [
    "readFarm",
    "recordProduction",
    "editHistoricalFacts",
    "manageCatalogs",
    "viewAnalytics",
    "deleteProtectedFacts",
    "manageMembers",
    "manageFarm",
    "editFarmLocation",
    "exportFarm",
    "resolveConflicts",
    "recoverFarm",
  ],
  administrator: [
    "readFarm",
    "recordProduction",
    "editHistoricalFacts",
    "manageCatalogs",
    "viewAnalytics",
    "editFarmLocation",
  ],
  worker: ["readFarm", "recordProduction"],
};

function errorResponse(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message } }, { status });
}

function isUUID(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function encodeBase64URL(data: Uint8Array): string {
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function utf8(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

function bufferCopy(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}

function pemToDER(pem: string): ArrayBuffer {
  const base64 = pem
    .replaceAll("\\n", "\n")
    .replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const binary = atob(base64);
  return bufferCopy(Uint8Array.from(binary, (character) => character.charCodeAt(0)));
}

async function signingKey(): Promise<CryptoKey> {
  const pem = Deno.env.get("ESHEEP_CAPABILITY_SIGNING_PRIVATE_KEY_PEM");
  if (!pem) throw new Error("capability_signing_key_missing");
  return await crypto.subtle.importKey(
    "pkcs8",
    pemToDER(pem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

async function sha256Hex(value: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bufferCopy(utf8(value))));
  return Array.from(digest).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function createCertificate(
  request: IssueRequest,
  accountID: string,
  role: FarmRole,
  nowSeconds: number,
  expiresAtSeconds: number,
): Promise<{ certificateID: string; certificate: string; capabilities: string[] }> {
  const certificateID = crypto.randomUUID();
  const capabilities = CAPABILITIES[role];
  const header = encodeBase64URL(utf8(JSON.stringify({
    alg: "ES256",
    kid: KEY_ID,
    typ: "esheep-capability+jwt",
  })));
  const payload = encodeBase64URL(utf8(JSON.stringify({
    certificateID,
    accountID,
    farmID: request.farmID,
    deviceID: request.deviceID,
    role,
    capabilities,
    iat: nowSeconds,
    exp: expiresAtSeconds,
    iss: ISSUER,
    aud: AUDIENCE,
  })));
  const signingInput = `${header}.${payload}`;
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    await signingKey(),
    bufferCopy(utf8(signingInput)),
  ));
  if (signature.byteLength !== 64) throw new Error("unexpected_es256_signature_format");
  return {
    certificateID,
    certificate: `${signingInput}.${encodeBase64URL(signature)}`,
    capabilities,
  };
}

export default {
  fetch: withSupabase<any>({ auth: "user" }, async (request, context) => {
    if (request.method !== "POST") {
      return errorResponse(405, "method_not_allowed", "POST is required.");
    }

    let body: IssueRequest;
    try {
      body = await request.json() as IssueRequest;
    } catch {
      return errorResponse(400, "invalid_request", "A JSON request body is required.");
    }
    if (!isUUID(body.farmID) || !isUUID(body.ownerAppAccountID) || !isUUID(body.deviceID) ||
        typeof body.zoneName !== "string" || typeof body.zoneOwnerName !== "string" ||
        !Number.isInteger(body.observedSecurityGeneration) || body.observedSecurityGeneration < 0 ||
        body.observedSecurityGeneration > 1_000_000) {
      return errorResponse(400, "invalid_request", "Farm, account, device and CloudKit zone fields are required.");
    }
    body.farmID = body.farmID.toLowerCase();
    body.ownerAppAccountID = body.ownerAppAccountID.toLowerCase();
    body.deviceID = body.deviceID.toLowerCase();

    const { data: authData, error: authError } = await context.supabase.auth.getUser();
    const user = authData.user;
    if (authError || !user) return errorResponse(401, "authentication_required", "A valid Supabase session is required.");

    const { error: registrationError } = await context.supabase.rpc("register_owned_icloud_farm", {
      p_farm_id: body.farmID,
      p_owner_app_account_id: body.ownerAppAccountID,
      p_device_id: body.deviceID,
      p_zone_name: body.zoneName,
      p_zone_owner_name: body.zoneOwnerName,
      p_observed_security_generation: body.observedSecurityGeneration,
    });
    if (registrationError) {
      return errorResponse(403, registrationError.message, "The CloudKit farm registration was rejected.");
    }

    const [{ data: registryData, error: registryError }, { data: memberData, error: memberError }, { data: deviceData, error: deviceError }] = await Promise.all([
      context.supabase.from("farm_registry")
        .select("farm_id,owner_user_id,provider,status,authority_generation")
        .eq("farm_id", body.farmID).single(),
      context.supabase.from("farm_members")
        .select("farm_id,user_id,app_account_id,role,status")
        .eq("farm_id", body.farmID).eq("user_id", user.id).single(),
      context.supabase.from("devices")
        .select("device_id,user_id,public_key_jwk,status")
        .eq("device_id", body.deviceID).eq("user_id", user.id).single(),
    ]);
    if (registryError || memberError || deviceError) {
      return errorResponse(403, "control_plane_access_denied", "The farm, membership or device is unavailable.");
    }
    const registry = registryData as RegistryRow;
    const member = memberData as MemberRow;
    const device = deviceData as DeviceRow;
    if (registry.owner_user_id !== user.id || registry.provider !== "icloud" || registry.status !== "active" ||
        member.status !== "active" || member.role !== "owner" || member.app_account_id !== body.ownerAppAccountID ||
        device.status !== "active") {
      return errorResponse(403, "control_plane_access_denied", "Active owner and device access is required.");
    }

    const nowSeconds = Math.floor(Date.now() / 1000);
    const { data: existingData, error: existingError } = await context.supabaseAdmin
      .from("icloud_capability_certificates")
      .select("certificate_id,certificate_jws,role,capabilities,issued_at,expires_at")
      .eq("farm_id", body.farmID)
      .eq("user_id", user.id)
      .eq("device_id", body.deviceID)
      .eq("key_id", KEY_ID)
      .is("revoked_at", null)
      .order("expires_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (existingError) return errorResponse(500, "certificate_lookup_failed", "The certificate store is unavailable.");

    let certificateRow = existingData as CertificateRow | null;
    if (!certificateRow || Math.floor(new Date(certificateRow.expires_at).getTime() / 1000) - nowSeconds <= REUSE_REMAINING_SECONDS) {
      const expiresAtSeconds = nowSeconds + DEFAULT_TTL_SECONDS;
      const issued = await createCertificate(body, body.ownerAppAccountID, member.role, nowSeconds, expiresAtSeconds);
      const { error: revokeError } = await context.supabaseAdmin
        .from("icloud_capability_certificates")
        .update({ revoked_at: new Date(nowSeconds * 1000).toISOString() })
        .eq("farm_id", body.farmID)
        .eq("user_id", user.id)
        .eq("device_id", body.deviceID)
        .is("revoked_at", null);
      if (revokeError) return errorResponse(500, "certificate_rotation_failed", "The prior certificate could not be revoked.");
      const insert = {
        certificate_id: issued.certificateID,
        farm_id: body.farmID,
        user_id: user.id,
        app_account_id: body.ownerAppAccountID,
        device_id: body.deviceID,
        role: member.role,
        capabilities: issued.capabilities,
        certificate_jws: issued.certificate,
        certificate_digest: await sha256Hex(issued.certificate),
        key_id: KEY_ID,
        issued_at: new Date(nowSeconds * 1000).toISOString(),
        expires_at: new Date(expiresAtSeconds * 1000).toISOString(),
      };
      const { data, error } = await context.supabaseAdmin
        .from("icloud_capability_certificates")
        .insert(insert)
        .select("certificate_id,certificate_jws,role,capabilities,issued_at,expires_at")
        .single();
      if (error) return errorResponse(500, "certificate_insert_failed", "The certificate could not be stored.");
      certificateRow = data as CertificateRow;
    }

    const { data: membersData, error: membersError } = await context.supabaseAdmin
      .from("farm_members")
      .select("farm_id,user_id,app_account_id,role,status")
      .eq("farm_id", body.farmID);
    if (membersError) return errorResponse(500, "snapshot_members_failed", "Farm members could not be loaded.");
    const members = (membersData ?? []) as MemberRow[];
    const memberUserIDs = [...new Set(members.map((row) => row.user_id))];

    const [{ data: profilesData, error: profilesError }, { data: devicesData, error: devicesError }, { data: revokedData, error: revokedError }] = await Promise.all([
      context.supabaseAdmin.from("profiles").select("user_id,display_name").in("user_id", memberUserIDs),
      context.supabaseAdmin.from("devices").select("device_id,user_id,public_key_jwk,status").in("user_id", memberUserIDs).eq("status", "active"),
      context.supabaseAdmin.from("icloud_capability_certificates").select("certificate_id,revoked_at").eq("farm_id", body.farmID).not("revoked_at", "is", null),
    ]);
    if (profilesError || devicesError || revokedError) {
      return errorResponse(500, "snapshot_trust_failed", "The farm trust snapshot could not be loaded.");
    }
    const displayNames = new Map((profilesData ?? []).map((row) => [row.user_id as string, (row.display_name as string | null) ?? ""]));

    return Response.json({
      certificateID: certificateRow.certificate_id,
      certificate: certificateRow.certificate_jws,
      role: certificateRow.role,
      capabilities: certificateRow.capabilities,
      issuedAt: Math.floor(new Date(certificateRow.issued_at).getTime() / 1000),
      expiresAt: Math.floor(new Date(certificateRow.expires_at).getTime() / 1000),
      securitySnapshot: {
        farmID: body.farmID,
        generation: registry.authority_generation,
        issuedAt: nowSeconds,
        members: members.map((row) => ({
          membershipID: `${body.farmID}:${row.user_id}`,
          accountID: row.app_account_id,
          displayName: displayNames.get(row.user_id) ?? "",
          role: row.role,
          status: row.status,
          shareParticipantRecordName: null,
        })),
        devices: ((devicesData ?? []) as DeviceRow[]).map((row) => ({
          deviceID: row.device_id,
          accountID: members.find((memberRow) => memberRow.user_id === row.user_id)?.app_account_id,
          publicKeyJWK: JSON.stringify(row.public_key_jwk),
        })).filter((row) => row.accountID != null),
        revokedCertificates: (revokedData ?? []).map((row) => ({
          certificateID: row.certificate_id,
          revokedAt: Math.floor(new Date(row.revoked_at).getTime() / 1000),
        })),
      },
    });
  }),
};
