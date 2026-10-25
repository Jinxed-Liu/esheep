import { createV2Projection, applyV2Event, finishV2Projection, webCheckpointModels } from "./cloudV2Projection.js";
import { applyExtendedV2Event } from "./cloudV2BusinessReplay.js";
import { concurrentRead } from "./concurrentRead.js";
import { browserCheckpointChunkCache } from "./checkpointChunkCache.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const maxChunkBytes = 8 * 1024 * 1024;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const digestPattern = /^[0-9a-f]{64}$/;
const checkpointCache = new Map();
// Continue only a fully verified in-memory projection. Every reuse still checks
// current cloud authority and validates every new event before publication.
const verifiedProjections = new Map();
let cacheEpoch = 0;
const sameID = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();

export class CloudV2ReadError extends Error {
  constructor(message = "牧场资料核对未通过，请刷新重试。", code = "CLOUD_V2_INTEGRITY") {
    super(message);
    this.name = "CloudV2ReadError";
    this.code = code;
  }
}

function requireValue(condition, message) {
  if (!condition) throw new CloudV2ReadError(message);
}

export async function sha256(value) {
  const bytes = typeof value === "string" ? encoder.encode(value) : value;
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function validateCheckpointManifest(manifest, farm) {
  requireValue(manifest?.formatVersion === 1 && Number.isInteger(manifest.minimumClientCapability) && manifest.minimumClientCapability >= 1 && manifest.minimumClientCapability <= 2,
    "这份牧场资料需要更新网页版后才能读取。");
  requireValue(uuid.test(manifest.checkpointID) && sameID(manifest.farmID, farm.id) &&
    manifest.farmGeneration === farm.generation && Number.isSafeInteger(manifest.boundaryEventSequence) &&
    manifest.boundaryEventSequence >= 0 && Array.isArray(manifest.chunks) && manifest.chunks.length <= 10000 &&
    manifest.modelCounts && Object.values(manifest.modelCounts).every((count) => Number.isSafeInteger(count) && count >= 0));
  requireValue([manifest.boundaryEventDigest, manifest.receiptChainDigest, manifest.businessDigest].every((digest) => digestPattern.test(digest)));
  const prefix = `${farm.id.toLowerCase()}/${manifest.checkpointID.toLowerCase()}/`;
  let totalBytes = 0;
  for (const [index, chunk] of manifest.chunks.entries()) {
    requireValue(chunk.index === index && chunk.objectKey === `${prefix}${String(index).padStart(5, "0")}.json.gz` &&
      [chunk.compressedBytes, chunk.uncompressedBytes].every((size) => Number.isSafeInteger(size) && size > 0 && size <= maxChunkBytes) &&
      Number.isSafeInteger(chunk.recordCount) && chunk.recordCount > 0 &&
      digestPattern.test(chunk.compressedSHA256) && digestPattern.test(chunk.contentSHA256));
    if (chunk.modelNames != null) {
      requireValue(Array.isArray(chunk.modelNames) && chunk.modelNames.length > 0 &&
        new Set(chunk.modelNames).size === chunk.modelNames.length &&
        chunk.modelNames.every((name) => Object.hasOwn(manifest.modelCounts, name)));
    }
    if (needsChunk(chunk)) totalBytes += chunk.uncompressedBytes;
  }
  requireValue(totalBytes <= 256 * 1024 * 1024, "牧场资料超过当前网页版的接收上限，请联系管理员。");
}

function needsChunk(chunk) {
  return !chunk.modelNames || chunk.modelNames.some((name) => webCheckpointModels.has(name));
}

async function readBounded(stream, expected, signal) {
  requireValue(stream && expected > 0 && expected <= maxChunkBytes);
  const reader = stream.getReader();
  const bytes = new Uint8Array(expected);
  let offset = 0;
  try {
    while (true) {
      signal?.throwIfAborted();
      const { value, done } = await reader.read();
      if (done) break;
      requireValue(offset + value.byteLength <= expected);
      bytes.set(value, offset);
      offset += value.byteLength;
    }
    requireValue(offset === expected);
    return bytes;
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

export async function decodeCheckpointChunk(bytes, descriptor, signal) {
  requireValue(bytes.byteLength === descriptor.compressedBytes &&
    await sha256(bytes) === descriptor.compressedSHA256);
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  const raw = await readBounded(stream, descriptor.uncompressedBytes, signal);
  requireValue(await sha256(raw) === descriptor.contentSHA256);
  const rows = JSON.parse(decoder.decode(raw));
  requireValue(Array.isArray(rows) && rows.length === descriptor.recordCount);
  if (descriptor.modelNames) {
    const names = new Set(rows.map((row) => row.model));
    requireValue(names.size === descriptor.modelNames.length && descriptor.modelNames.every((name) => names.has(name)));
  }
  return rows;
}

export async function validateV2Event(event, farm, expectedSequence) {
  requireValue(event.protocol_version === 2 && event.schema_version === 1 &&
    sameID(event.farm_id, farm.id) && event.farm_generation === farm.generation &&
    event.event_sequence === expectedSequence &&
    [event.event_id, event.command_id, event.stream_id, event.actor_account_id, event.source_device_id].every((id) => uuid.test(id)) &&
    [event.event_body_digest, event.before_digest, event.after_digest, event.source_command_digest, event.event_digest].every((value) => digestPattern.test(value)) &&
    Number.isSafeInteger(event.source_device_sequence) && event.source_device_sequence > 0 &&
    Number.isSafeInteger(event.occurred_at_millis) && Number.isSafeInteger(event.received_at_millis) &&
    Array.isArray(event.affected_fields) && event.affected_fields.every((field) => typeof field === "string"));
  requireValue(typeof event.event_body_canonical === "string" &&
    await sha256(event.event_body_canonical) === event.event_body_digest);
  const canonical = [
    "esheep-cloud-event-v2", farm.id.toLowerCase(), farm.generation, event.event_sequence,
    event.event_id.toLowerCase(), event.command_id.toLowerCase(), event.stream_type, event.stream_id.toLowerCase(),
    [...event.affected_fields].sort().join(","), event.event_body_digest, event.before_digest, event.after_digest,
    event.actor_account_id.toLowerCase(), event.source_device_id.toLowerCase(), event.source_device_sequence,
    event.occurred_at_millis, event.received_at_millis, event.source_command_digest,
  ].join("\n");
  requireValue(await sha256(canonical) === event.event_digest);
  return JSON.parse(event.event_body_canonical);
}

async function rpc(client, name, params, signal) {
  let query = client.rpc(name, params);
  if (signal) query = query.abortSignal(signal);
  const { data, error } = await query;
  if (error) throw error;
  return data;
}

async function checkpointTicket(client, farm, signal, checkpointID) {
  const { data, error } = await client.functions.invoke("esheep-cloud-checkpoints", {
    body: { farm_id: farm.id, farm_generation: farm.generation,
      ...(checkpointID ? { checkpoint_id: checkpointID } : {}) }, signal,
  });
  if (error) throw new CloudV2ReadError("暂时无法下载牧场资料，请刷新重试。", "CLOUD_V2_DOWNLOAD_FAILED");
  return data;
}

async function checkpointSource(client, farm, signal, persistentCache, scopePrefix) {
  // This hint only selects a network path. The manifest and permission always
  // come from the authenticated cloud, and every cached byte is checked again.
  if (await persistentCache.hasScope?.(scopePrefix)) {
    return rpc(client, "esheep_cloud_checkpoint_manifest_v1", {
      p_farm_id: farm.id, p_farm_generation: farm.generation, p_checkpoint_id: null,
    }, signal);
  }
  return checkpointTicket(client, farm, signal);
}

function validateDownloads(ticket, manifest) {
  requireValue(Array.isArray(ticket?.downloads) && ticket.downloads.length === manifest.chunks.length &&
    ticket.downloads.every((download, index) => download.index === index));
}

export async function loadCloudV2Projection(client, farm, { accountID, storageOrigin, signal, onProgress = () => {}, fetchImpl = fetch, persistentCache = browserCheckpointChunkCache } = {}) {
  const epoch = cacheEpoch;
  const verifiedKey = `${storageOrigin}:${accountID}:${farm.id.toLowerCase()}:${farm.generation}`;
  const verified = verifiedProjections.get(verifiedKey);
  onProgress("正在确认牧场最新版本…");
  // These independent reads both enforce current membership. Overlap them so
  // first-time downloads do not wait for another control-plane round trip.
  const [status, initialSource] = await Promise.all([
    rpc(client, "esheep_cloud_fetch_status_v2", { p_farm_id: farm.id }, signal),
    verified ? null : checkpointSource(client, farm, signal, persistentCache, `${verifiedKey}:`),
  ]);
  requireValue(status?.farm_generation === farm.generation && sameID(status.farm_id, farm.id), "牧场云同步版本已变化，请刷新重试。");
  requireValue(status.v2_ready === true, "牧场正在准备云端资料，请稍后重试。");
  const targetHead = status.cloud_head;
  requireValue(Number.isSafeInteger(targetHead) && targetHead >= 0);
  const pullEvents = (after) => rpc(client, "esheep_cloud_pull_events_v2", {
    p_farm_id: farm.id, p_farm_generation: farm.generation, p_after_event_sequence: after, p_limit: 1000,
  }, signal);
  let firstPage;
  const prefetchEvents = (after) => {
    if (after >= targetHead) return;
    // The authorized immutable boundary is enough to start this independent
    // read. Consume it only after every checkpoint byte/model is verified.
    // Capture failures immediately, including when checkpoint validation fails.
    firstPage = { after, result: pullEvents(after).then(page => ({ page }), error => ({ error })) };
  };
  let projection, manifest, persistentScope, cursor;
  if (verified && verified.revision <= targetHead) {
    prefetchEvents(verified.revision);
    projection = structuredClone(verified.projection);
    manifest = projection.manifest;
    persistentScope = verified.persistentScope;
    cursor = verified.revision;
  } else {
    const source = verified
      ? await checkpointSource(client, farm, signal, persistentCache, `${verifiedKey}:`)
      : initialSource;
    requireValue(source?.manifest, "牧场尚无可供网页版读取的已验证资料，请联系管理员。当前成员权限仍然有效。");
    manifest = source.manifest;
    validateCheckpointManifest(manifest, farm);
    requireValue(manifest.boundaryEventSequence <= targetHead, "牧场资料刚刚更新，请刷新重试。");
    if (source.downloads) validateDownloads(source, manifest);
    prefetchEvents(manifest.boundaryEventSequence);
    const cacheKey = `${accountID}:${farm.id.toLowerCase()}:${farm.generation}:${manifest.checkpointID.toLowerCase()}`;
    const manifestFingerprint = await sha256(JSON.stringify(manifest));
    let ticketPromise = source.downloads ? Promise.resolve(source) : null;
    const downloads = () => ticketPromise ??= checkpointTicket(client, farm, signal, manifest.checkpointID).then(async (ticket) => {
      // Repair missing/corrupt chunks from this exact immutable checkpoint,
      // never mix a newly published checkpoint into the in-progress receive.
      requireValue(ticket?.manifest && await sha256(JSON.stringify(ticket.manifest)) === manifestFingerprint);
      validateDownloads(ticket, manifest);
      return ticket;
    });
    persistentScope = `${storageOrigin}:${cacheKey}:${manifestFingerprint}`;
    let cached = checkpointCache.get(cacheKey);
    if (cached) requireValue(cached.fingerprint === manifestFingerprint);
    if (!cached) {
      const rows = [];
      const descriptors = manifest.chunks.filter(needsChunk);
      // Six bounded slots overlap network waits without the old batch barrier.
      let completed = 0;
      onProgress(`正在读取牧场资料：0 / ${descriptors.length}`);
      const pages = await concurrentRead(descriptors, async (descriptor, readSignal) => {
          let bytes = await persistentCache.read(persistentScope, descriptor);
          if (bytes) {
            try {
              const records = (await decodeCheckpointChunk(bytes, descriptor, readSignal))
                .filter((row) => webCheckpointModels.has(row.model));
              onProgress(`正在核对本地牧场资料：${++completed} / ${descriptors.length}`);
              return records;
            } catch (error) {
              if (readSignal?.aborted) throw error;
              // A damaged local copy is replaced by the signed cloud copy below.
              bytes = null;
            }
          }
          const ticket = await downloads();
          const address = new URL(ticket.downloads[descriptor.index].url);
          requireValue(address.protocol === "https:" && address.origin === storageOrigin &&
            decodeURIComponent(address.pathname) === `/storage/v1/object/sign/esheep-cloud-checkpoints/${descriptor.objectKey}`);
          const response = await fetchImpl(address, { signal: readSignal, credentials: "omit", cache: "no-store" });
          if (!response.ok) throw new CloudV2ReadError("牧场资料下载失败，请刷新重试。", "CLOUD_V2_DOWNLOAD_FAILED");
          bytes = await readBounded(response.body, descriptor.compressedBytes, readSignal);
          const records = (await decodeCheckpointChunk(bytes, descriptor, readSignal))
            .filter((row) => webCheckpointModels.has(row.model));
          await persistentCache.write(persistentScope, descriptor, bytes);
          onProgress(`正在下载并核对牧场资料：${++completed} / ${descriptors.length}`);
          return records;
      }, { signal });
      for (const page of pages) rows.push(...page);
      // Checks selected model counts, duplicate identities and farm ownership.
      onProgress("正在整理牧场资料…");
      projection = createV2Projection(rows, manifest);
      cached = { fingerprint: manifestFingerprint, rows };
      checkpointCache.clear();
      checkpointCache.set(cacheKey, cached);
    }
    projection ??= createV2Projection(cached.rows, manifest);
    cursor = manifest.boundaryEventSequence;
  }
  const startingCursor = cursor;
  try {
    while (cursor < targetHead) {
      signal?.throwIfAborted();
      onProgress(`正在同步近期更新：${cursor - startingCursor} / ${targetHead - startingCursor}`);
      const prefetched = firstPage?.after === cursor ? await firstPage.result : null;
      firstPage = null;
      if (prefetched?.error) throw prefetched.error;
      const page = prefetched ? prefetched.page : await pullEvents(cursor);
      requireValue(Array.isArray(page?.events) && page.events.length > 0 && page.events.length <= 1000 &&
        Number.isSafeInteger(page.cloud_head) && page.cloud_head >= targetHead);
      for (const event of page.events) {
        if (cursor === targetHead) break;
        const body = await validateV2Event(event, farm, cursor + 1);
        if (!await applyExtendedV2Event(projection, event, body)) applyV2Event(projection, event, body);
        cursor = event.event_sequence;
      }
    }
    // Recheck permission and generation after the download. Never publish a
    // partially loaded or changed-authority workspace to the UI.
    onProgress("正在完成校验，即将打开牧场…");
    const finalStatus = await rpc(client, "esheep_cloud_fetch_status_v2", { p_farm_id: farm.id }, signal);
    requireValue(sameID(finalStatus.farm_id, farm.id) && finalStatus.farm_generation === farm.generation && finalStatus.cloud_head >= targetHead && finalStatus.v2_ready === true,
      "牧场云同步版本已变化，请刷新重试。");
    applyFarmIdentity(projection, finalStatus.farm_identity, farm);
    signal?.throwIfAborted();
    const verifiedProjection = structuredClone(projection);
    const result = { ...finishV2Projection(projection), manifest, revision: targetHead };
    if (!verified) await persistentCache.prune?.(`${storageOrigin}:${accountID}:${farm.id.toLowerCase()}:${farm.generation}:`, persistentScope);
    signal?.throwIfAborted();
    // A signed-out or superseded read cannot repopulate the private session cache.
    const latest = verifiedProjections.get(verifiedKey);
    if (epoch === cacheEpoch && (!latest || latest.revision <= targetHead)) {
      verifiedProjections.delete(verifiedKey);
      verifiedProjections.set(verifiedKey, { projection: verifiedProjection, manifest: verifiedProjection.manifest, persistentScope, revision: targetHead });
      while (verifiedProjections.size > 2) verifiedProjections.delete(verifiedProjections.keys().next().value);
    }
    return result;
  } catch (error) {
    if (verifiedProjections.get(verifiedKey) === verified) verifiedProjections.delete(verifiedKey);
    throw error;
  }
}

// Live identity is authenticated control-plane data. Apply it only after
// checkpoint/event verification; cached immutable rows remain unchanged.
export function applyFarmIdentity(projection, identity, farm) {
  if (identity == null) return;
  requireValue(sameID(identity.farmID, farm.id) && identity.farmGeneration === farm.generation &&
    Number.isSafeInteger(identity.revision) && identity.revision >= 0 &&
    typeof identity.name === "string" && identity.name.trim().length > 0 &&
    [...identity.name].length <= 80 && !/[\u0000-\u001f\u007f-\u009f]/u.test(identity.name));
  const row = projection.models.get("FarmRecord")?.get(farm.id.toLowerCase());
  requireValue(row && sameID(row.id, identity.farmID));
  if (identity.revision < (projection.farmNameRevision ?? -1)) return;
  requireValue(identity.revision !== projection.farmNameRevision || row.name === identity.name);
  row.name = identity.name;
  projection.farmNameRevision = identity.revision;
}

export async function clearCloudV2Cache() {
  cacheEpoch++;
  verifiedProjections.clear();
  checkpointCache.clear();
  await browserCheckpointChunkCache.clear();
}
