import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { decodeCompactCheckpoint } from "../src/lib/lzfse.js";
import { loadCloudV2Projection } from "../src/lib/cloudV2Checkpoint.js";
import { dailyRosterEvidence } from "./agent-roster.mjs";

const hash = data => createHash("sha256").update(data).digest("hex");
const lower = id => id.toLowerCase();
function verify(ok) {
  if (!ok) throw new Error("旧名册与云端登记记录未能逐只核对。");
}
function payload(base64, digest) {
  const raw = Buffer.from(base64, "base64");
  verify(hash(raw) === digest);
  return JSON.parse(raw);
}
function profile(id, body) {
  return { id, sexRawValue: body.strings.sex, breed: body.strings.breed,
    isHistoricalArchive: Number(body.integers.isHistoricalArchive ?? 0) === 1,
    authoritative: Number(body.integers.legacyStatusSnapshotIsAuthoritative ?? 0) === 1,
    statusRawValue: body.strings.legacyStatusRawValue || "active" };
}
function members(sheep, removals) {
  const removed = new Set(), later = new Set();
  for (const [id, postBaseline] of removals.values()) {
    removed.add(id);
    if (postBaseline) later.add(id);
  }
  return [...sheep.values()].filter(s => !s.isHistoricalArchive &&
    (s.authoritative ? s.statusRawValue === "active" && !later.has(s.id) : !removed.has(s.id)))
    .map(s => ({ ...s, statusRawValue: "active" }));
}

export function replayLegacyRoster(archive, journal, source) {
  verify(lower(archive.manifest.farmID) === lower(source.farm) && archive.manifest.authorityGeneration === source.sourceGeneration &&
    archive.projections.length === archive.manifest.projectionCount && journal.length === source.finalRevision);
  const sheep = new Map(), removals = new Map();
  for (const row of archive.projections) {
    if (row.deletedAt || !["sheep","removal"].includes(row.entityType)) continue;
    const id = lower(row.entityID), body = payload(row.payload, row.payloadDigest);
    if (row.entityType === "sheep") { verify(!sheep.has(id)); sheep.set(id, profile(id, body)); }
    else { verify(!removals.has(id)); removals.set(id,[lower(body.identifiers.sheepID),false]); }
  }
  const cutoff = Date.parse(source.cutoff);
  verify(Number.isFinite(cutoff));
  let opening, revision = 0, previous = -Infinity;
  for (const row of journal) {
    const at = Date.parse(row.server_received_at);
    verify(row.revision === ++revision && Number.isFinite(at) && at >= previous);
    previous = at;
    if (at >= cutoff && !opening) opening = { records: members(sheep, removals), revision: revision - 1 };
    if (!["sheep","removal","reproduction"].includes(row.entity_type)) continue;
    const id = lower(row.entity_id), body = payload(row.payload_base64, row.payload_digest);
    if (row.entity_type === "reproduction") {
      // Lamb profiles have separate addSheep operations. Unknown lifecycle operations fail closed.
      verify(body.kind === "care" && Object.keys(body.careCommand ?? {}).every(k => k === "recordLambing"));
      continue;
    }
    if (body.kind === "tombstoneEntity") {
      verify(lower(body.identifiers.entityID) === id && body.strings.entityType === row.entity_type);
      (row.entity_type === "sheep" ? sheep : removals).delete(id);
    } else if (row.entity_type === "removal") {
      verify(body.kind === "removeSheep" && !row.deleted_at);
      removals.set(id, [lower(body.identifiers.sheepID),true]);
    } else if (body.kind === "addSheep") {
      verify(!sheep.has(id) && !row.deleted_at);
      sheep.set(id, profile(id, body));
    } else if (body.kind === "updateSheepProfile") {
      const item = sheep.get(id);
      verify(item && !row.deleted_at && body.strings.legacyStatusRawValue == null &&
        body.integers.isHistoricalArchive == null && body.integers.legacyStatusSnapshotIsAuthoritative == null);
      if (body.strings.sex != null) item.sexRawValue = body.strings.sex;
      if (body.strings.breed != null) item.breed = body.strings.breed;
    } else {
      verify(!row.deleted_at && body.kind === "care" && Object.keys(body.careCommand ?? {}).length === 1 &&
        Object.keys(body.careCommand).every(k => ["setSheepPurpose","setBreedingRam","updateSheepPedigree"].includes(k)));
    }
  }
  const final = members(sheep, removals);
  return { opening: opening ?? {records: final,revision}, final };
}

export function verifyLegacyWitness(final, projection) {
  const ids = new Set(final.map(row => row.id));
  const live = (projection.models.SheepRecord ?? []).filter(s => s.statusRawValue === "active" && !s.isHistoricalArchive && s.deletedAt == null);
  verify(live.length === ids.size && live.every(s => ids.delete(lower(s.id))) && ids.size === 0);
}

export async function readLegacyRoster(client, farm, options, filters, memberOptions) {
  if (filters.penName) return null; // Pen timelines need a separate cross-migration reconciliation.
  const {data: source,error} = await client.rpc("esheep_cloud_legacy_roster_source_v1",{
    p_farm_id:farm.id,p_farm_generation:farm.generation,p_day:filters.day,p_opening:filters.opening,
  }).abortSignal(options.signal);
  if (error) throw error;
  if (!source) return null;
  verify(lower(source.farm) === lower(farm.id) && source.sourceGeneration < farm.generation &&
    source.path.startsWith(lower(farm.id) + "/") && Number.isSafeInteger(source.finalRevision));
  const download = await client.storage.from("farm-checkpoints").download(source.path);
  if (download.error) throw download.error;
  verify(download.data.size === source.bytes && hash(Buffer.from(await download.data.arrayBuffer())) === source.digest);
  const decoder = () => readFile(new URL("../public/lzfse.wasm",import.meta.url)).then(bytes => WebAssembly.instantiate(bytes,{}));
  options.signal?.throwIfAborted();
  const archive = await decodeCompactCheckpoint(download.data,decoder);
  const journal = [];
  while (journal.length < source.finalRevision) {
    const {data,error} = await client.from("farm_operations")
      .select("revision,entity_id,entity_type,server_received_at,deleted_at,payload_base64,payload_digest")
      .eq("farm_id",farm.id).eq("authority_generation",source.sourceGeneration).eq("is_staged",false)
      .gt("revision",journal.length).lte("revision",source.finalRevision).order("revision").limit(500).abortSignal(options.signal);
    if (error) throw error;
    verify(data?.length > 0 && data[0].revision === journal.length+1);
    journal.push(...data);
  }
  const { opening, final } = replayLegacyRoster(archive,journal,source);
  const witness = await loadCloudV2Projection(client,farm,{...options,historicalBoundary:source.anchor});
  verifyLegacyWitness(final,witness);
  const boundary = {day:filters.day, zone:source.zone, head:witness.revision};
  const result = dailyRosterEvidence({revision:witness.revision,models:{
    FarmRecord:witness.models.FarmRecord, SheepRecord:opening.records,
  }},farm,boundary,filters,memberOptions);
  return {...result, archive_source:{generation:source.sourceGeneration,checkpoint:source.checkpoint,
    revision:opening.revision,witness_head:witness.revision}};
}
