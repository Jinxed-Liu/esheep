import { createClient } from "@supabase/supabase-js";
import { farmDayKey } from "../src/lib/appAnalytics.js";
import { readLegacyRoster } from "./agent-legacy-roster.mjs";
import { dailyRosterEvidence } from "./agent-roster.mjs";
import { bearerToken } from "./auth.mjs";
import { loadCloudV2Projection } from "../src/lib/cloudV2Checkpoint.js";
import { projectionToWeightRecord, projectionToWeaningRecord, projectionToReproductionRecord } from "../src/lib/farmReadModels.js";
import { nativeEventSnapshots } from "../src/lib/nativeEventSnapshots.js";

const noDiskCache = { read: async () => null, write: async () => {}, readManifest: async () => null, writeManifest: async () => {} };
const iso = value => value == null ? null : new Date(value).toISOString();

// This reader uses the caller's JWT, never a service-role credential. The same
// checkpoint hashes, generation checks and ordered event replay used by Web
// are applied before any facts become available to the model.
function agentCloudReader({ request, authorization, config, signal, onProgress, fetchImpl = fetch }) {
  const access = authorization.membership;
  if (access.provider !== "esheep_cloud") throw new Error("此牧场尚未启用可核验的 Cloud V2 读取，请先完成云端迁移。");
  const client = createClient(config.supabaseURL, config.supabasePublishableKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { headers: { Authorization: `Bearer ${bearerToken(request)}` }, fetch: fetchImpl },
  });
  const farm = { id: access.farm_id, generation: access.authority_generation, role: access.member_role, provider: access.provider };
  const options = {
    accountID: authorization.userID, storageOrigin: new URL(config.supabaseURL).origin,
    signal, onProgress, fetchImpl, persistentCache: noDiskCache,
  };
  return { client, farm, options };
}

export async function loadAgentCloudSnapshot(context) {
  const { client, farm, options } = agentCloudReader(context);
  return snapshotFromCloudProjection(await loadCloudV2Projection(client, farm, options), farm);
}

export async function loadAgentDailyRoster(context, filters, memberOptions) {
  const { client, farm, options } = agentCloudReader(context);
  const { data: boundary, error } = await client.rpc("esheep_cloud_daily_roster_boundary_v1", {
    p_farm_id: farm.id, p_farm_generation: farm.generation, p_day: filters.day || null, p_opening: filters.opening,
  }).abortSignal(context.signal);
  if (error || !boundary?.day) throw new Error("无法读取该日在群名册，请重新核对牧场连接。");
  if (boundary.unavailable === "no_roster") {
    const archived = await readLegacyRoster(client, farm, options, filters, memberOptions);
    if (archived) return archived;
  }
  const projection = boundary.unavailable ? null : await loadCloudV2Projection(client, farm, {
    ...options, historicalBoundary: boundary.current ? undefined : boundary,
  });
  if (boundary.current && farmDayKey(new Date(), boundary.zone) !== boundary.day) {
    throw new Error("查询期间牧场日期已变化，请重新读取当日名册。");
  }
  return dailyRosterEvidence(projection, farm, boundary, filters, memberOptions);
}

export async function snapshotFromCloudProjection(projection, farm, now = new Date()) {
  const live = name => (projection.models[name] ?? []).filter(row => row.deletedAt == null);
  const farmRecord = live("FarmRecord")[0];
  if (!farmRecord || farmRecord.id.toLowerCase() !== farm.id.toLowerCase() || !farmRecord.timeZoneIdentifier) throw new Error("牧场身份或时区缺失，无法生成分析。");
  const sheep = live("SheepRecord").map(row => ({
    id: row.id, earTag: row.earTag, legacyEarTag: row.legacyEarTag, breed: row.breed, purpose: row.purpose,
    sex: row.sexRawValue, status: row.statusRawValue, isHistoricalArchive: row.isHistoricalArchive,
    legacyStatusSnapshotIsAuthoritative: row.legacyStatusSnapshotIsAuthoritative,
    initialPenID: row.initialPenID, currentPenID: row.currentPenID, penID: row.currentPenID,
    birthAt: iso(row.birthAt), enteredAt: iso(row.enteredAt), removedAt: iso(row.removedAt),
    isBreedingRam: row.isBreedingRam, revision: row.revision,
  }));
  const activeSheep = sheep.filter(row => row.status === "active" && !row.isHistoricalArchive);
  const pens = live("PenRecord").map(row => ({ id: row.id, name: row.name, headCount: activeSheep.filter(s => s.currentPenID === row.id).length }));
  const penNames = new Map(pens.map(pen => [pen.id, pen.name]));
  for (const row of sheep) row.pen = penNames.get(row.currentPenID) ?? null;
  const convert = (kind, fn) => (projection.rowsByType.get(kind) ?? []).map(row => fn(row, row.payload_json)).filter(Boolean);
  const timed = name => live(name).map(row => ({ ...row, at: iso(row.occurredAt), occurredAt: iso(row.occurredAt), recordedAt: iso(row.recordedAt), kind: row.kindRawValue }));
  const analyticsSource = {
    sheep, pens, weights: convert("weight", projectionToWeightRecord),
    weanings: convert("weaning", projectionToWeaningRecord), reproduction: convert("reproduction", projectionToReproductionRecord),
    removals: timed("RemovalRecord"), transfers: timed("TransferRecord"),
    batches: live("ProductionBatchRecord").map(row => ({ ...row, startedAt: iso(row.startedAt), source: row.sourceRawValue })),
    batchMemberships: live("BatchMembershipRecord").map(row => ({ ...row, joinedAt: iso(row.joinedAt), leftAt: iso(row.leftAt) })),
    // Do not fabricate an empty feeding dataset. The capability is explicitly
    // disabled until the full nutrient/remaining-feed projection is available.
    feeds: [], troughObservations: [], dailyPenCounts: [],
  };
  const events = await nativeEventSnapshots(projection.models, { timeZone: farmRecord.timeZoneIdentifier });
  return {
    schemaVersion: "esheepnext-farm-assistant/v1", capturedAt: now.toISOString(),
    farm: { ...farm, name: farmRecord.displayName ?? farmRecord.name, timeZoneIdentifier: farmRecord.timeZoneIdentifier, revision: projection.revision },
    source: { kind: "supabase-authorized-server-read", description: "Supabase Cloud V2；当前用户授权读取、校验检查点与事件链后重建；未上传手机待同步记录。" },
    projectionCoverage: { verifiedCloudHead: projection.revision, checkpointID: projection.manifest.checkpointID, feedingAvailable: false },
    dataAvailability: { allSheep: sheep.length, activeSheep: activeSheep.length, pens: pens.length, events: events.length,
      includedEvents: events.length, eventsTruncated: false, weights: analyticsSource.weights.length,
      weanings: analyticsSource.weanings.length, reproduction: analyticsSource.reproduction.length,
      removals: analyticsSource.removals.length, transfers: analyticsSource.transfers.length },
    metrics: { activeSheep: activeSheep.length, activePens: pens.filter(p => p.headCount > 0).length },
    activeSheep, pens, events, analyticsSource, recordModels: projection.models,
  };
}
