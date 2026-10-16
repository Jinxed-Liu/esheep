import assert from "node:assert/strict";
import test from "node:test";
import { gzipSync } from "node:zlib";
import schema from "../../tools/esheep_cloud_checkpoint_schema_v1.json" with { type: "json" };
import { createV2Projection, applyV2Event, finishV2Projection, decodeCheckpointValues } from "../src/lib/cloudV2Projection.js";
import { clearCloudV2Cache, decodeCheckpointChunk, loadCloudV2Projection, validateV2Event, sha256 } from "../src/lib/cloudV2Checkpoint.js";

const id = (number) => `00000000-0000-4000-8000-${String(number).padStart(12, "0")}`;
const farmID = id(1), sheepID = id(2), penA = id(3), penB = id(4);
const at = Date.UTC(2026, 8, 1);
const appleSeconds = (millis) => (millis - 978307200000) / 1000;
function record(model, overrides = {}) {
  const values = Object.fromEntries(Object.entries(schema[model].fields).map(([key, type]) => [key,
    type.endsWith("?") ? null : type === "UUID" ? farmID : type === "Date" ? appleSeconds(at) :
      type === "Bool" ? false : type === "Data" ? { json: {} } : type === "String" ? "" : 0,
  ]));
  return { model, values: { ...values, ...overrides } };
}
function source(extra = [], sheepOverrides = {}) {
  const records = [
    record("FarmRecord", { id: farmID, name: "测试牧场", timeZoneIdentifier: "Asia/Shanghai" }),
    record("PenRecord", { id: penA, name: "一舍", isActive: true }),
    record("PenRecord", { id: penB, name: "二舍", isActive: true }),
    record("SheepRecord", { id: sheepID, earTag: "A001", breed: "湖羊", sexRawValue: "ewe", statusRawValue: "active",
      initialPenID: penA, currentPenID: penA, purpose: "哺乳羔羊", legacyPenSnapshotIsAuthoritative: true,
      legacyStatusSnapshotIsAuthoritative: true, ...sheepOverrides }), ...extra,
  ];
  const modelCounts = {};
  for (const row of records) modelCounts[row.model] = (modelCounts[row.model] ?? 0) + 1;
  return { records, manifest: { farmID, farmGeneration: 3, boundaryEventSequence: 10, modelCounts } };
}
function projection(extra, sheep) { const { records, manifest } = source(extra, sheep); return createV2Projection(records, manifest); }
function event(number, kind, command, args, streams) {
  return {
    envelope: { event_sequence: number, command_id: id(number + 100), event_id: id(number + 200),
      event_kind: kind.startsWith("record.") ? "lifecycle" : ["weight.record", "weaning.record"].includes(kind) ? "append_fact" : "state_machine",
      stream_type: streams[0].type, stream_id: streams[0].id, source_command_digest: "a".repeat(64),
      actor_account_id: id(7), occurred_at_millis: at + 1000, received_at_millis: at + 2000 },
    body: { command_kind: kind, command_payload: { kind, body: { [command]: args } }, affected_streams: streams },
  };
}
function apply(p, data) { applyV2Event(p, data.envelope, data.body); }
function sheep(p) { return finishV2Projection(p, { now: at + 100000 }).rowsByType.get("sheep")[0]; }

test("checkpoint dates use Apple's reference epoch, preserving fractional seconds", () => {
  const row = record("WeightRecord", { occurredAt: 810000000.125, id: id(9), sheepID });
  const decoded = decodeCheckpointValues(row.model, row.values);
  assert.equal(new Date(decoded.occurredAt).toISOString(), "2026-09-02T00:00:00.125Z");
});

test("verified V2 farm projection retains location coordinates for the environment", () => {
  const { records, manifest } = source();
  records[0].values.latitude = 39.9042;
  records[0].values.longitude = 116.4074;
  records[0].values.locationDisplayName = "北京牧场";
  const farm = finishV2Projection(createV2Projection(records, manifest)).rowsByType.get("farm")[0];
  assert.equal(farm.payload_json.decimals.latitude, 39.9042);
  assert.equal(farm.payload_json.decimals.longitude, 116.4074);
  assert.equal(farm.payload_json.optionalStrings.locationDisplayName, "北京牧场");
});

test("checkpoint field versions replay from JSON and Base64 envelopes without invalid characters", () => {
  const entries = [{ field: "breed", version: 2, valueDigest: "a".repeat(64) }];
  for (const fieldVersionsData of [
    { json: structuredClone(entries) },
    { base64: Buffer.from(JSON.stringify(entries)).toString("base64") },
    Buffer.from(JSON.stringify(entries)).toString("base64"),
  ]) {
    const p = projection([record("ESheepCloudStreamState", {
      id: id(80), streamType: "sheepProfile", streamID: sheepID, fieldVersionsData,
    })]);
    applyV2Event(p, {
      event_kind: "fields_patched", stream_type: "sheepProfile", stream_id: sheepID,
      event_id: id(81), received_at_millis: at + 2000,
    }, { changes: [{ field: "breed", field_version: 3, value_digest: "b".repeat(64),
      value: { type: "string", value: "新湖羊" } }] });
    assert.equal(p.models.get("SheepRecord").get(sheepID).breed, "新湖羊");
    assert.deepEqual(p.models.get("ESheepCloudStreamState").get(id(80)).fieldVersionsData.json,
      [{ field: "breed", version: 3, valueDigest: "b".repeat(64), value: { type: "string", value: "新湖羊" } }]);
  }
});

test("malformed checkpoint field versions fail as integrity errors", () => {
  const p = projection([record("ESheepCloudStreamState", {
    id: id(80), streamType: "sheepProfile", streamID: sheepID, fieldVersionsData: { base64: "not base64!" },
  })]);
  assert.throws(() => applyV2Event(p, {
    event_kind: "fields_patched", stream_type: "sheepProfile", stream_id: sheepID,
    event_id: id(81), received_at_millis: at + 2000,
  }, { changes: [{ field: "breed", field_version: 3, value_digest: "b".repeat(64),
    value: { type: "string", value: "新湖羊" } }] }), (error) => error.code === "CLOUD_V2_INTEGRITY");
});

test("foreign farms, missing rows and duplicates cannot activate a workspace", () => {
  const { records, manifest } = source();
  assert.throws(() => createV2Projection(records.slice(1), manifest), /数量不匹配/);
  assert.throws(() => createV2Projection([...records, records[1]], manifest), /重复记录/);
  const foreign = structuredClone(records); foreign[1].values.farmID = id(99);
  assert.throws(() => createV2Projection(foreign, manifest), /牧场标识不匹配/);
});

test("multi-stream transfer is applied once and uses the transfer ID rather than the sheep lane", () => {
  const p = projection();
  const change = event(11, "transfer.record", "transferSheep", { sheepID, toPenID: penB, occurredAt: at + 1000, note: "断奶调舍" },
    [{ type: "sheepLocation", id: sheepID }, { type: "transfer", id: id(50) }]);
  apply(p, change);
  applyV2Event(p, { ...change.envelope, event_sequence: 12, stream_type: "transfer", stream_id: id(50) }, change.body);
  const out = finishV2Projection(p, { now: at + 100000 });
  assert.equal(out.rowsByType.get("transfer").length, 1);
  assert.equal(out.rowsByType.get("transfer")[0].entity_id, id(50));
  assert.equal(out.rowsByType.get("sheep")[0].v2State.penID, penB);
  assert.equal(out.operationRows.length, 1);
});

test("backdated transfers do not override a later business-time transfer", () => {
  const p = projection([record("TransferRecord", { id: id(60), sheepID, toPenID: penB, occurredAt: appleSeconds(at + 5000) })]);
  apply(p, event(11, "transfer.record", "transferSheep", { sheepID, toPenID: penA, occurredAt: at + 1000, note: "补录" }, [{ type: "transfer", id: id(50) }]));
  assert.equal(sheep(p).v2State.penID, penB);
});

test("revoking an erroneous removal restores presence and the native pen timeline", () => {
  const p = projection();
  apply(p, event(11, "removal.record", "removeSheep", { sheepID, kind: "sold", reason: "售卖", occurredAt: at + 1000 },
    [{ type: "removal", id: id(50) }, { type: "sheepPresence", id: sheepID }]));
  assert.equal(sheep(p).v2State.status, "removed");
  apply(p, event(13, "record.revoke", "tombstone", { entityType: "removal", entityID: id(50), reason: "录入错误" }, [{ type: "removal", id: id(50) }]));
  const restored = sheep(p);
  assert.equal(restored.v2State.status, "active");
  assert.equal(restored.v2State.penID, penA);
});

test("production batch tombstone hides and restores only the batch", () => {
  const batchID = id(70), membershipID = id(71);
  const p = projection([
    record("ProductionBatchRecord", { id: batchID, name: "试验批次" }),
    record("BatchMembershipRecord", { id: membershipID, batchID, sheepID }),
  ]);
  apply(p, event(11, "record.revoke", "tombstone",
    { entityType: "productionBatch", entityID: batchID, reason: "误建批次" },
    [{ type: "productionBatch", id: batchID }]));
  assert.equal(finishV2Projection(p).rowsByType.get("productionBatch").length, 0);
  assert.equal(p.models.get("BatchMembershipRecord").get(membershipID).deletedAt, null);
  apply(p, event(12, "record.restore", "restore", { tombstoneID: id(111) },
    [{ type: "productionBatch", id: batchID }]));
  assert.equal(finishV2Projection(p).rowsByType.get("productionBatch").length, 1);
});

test("first active removal wins, matching FarmSheepStateResolver", () => {
  const p = projection([
    record("RemovalRecord", { id: id(50), sheepID, kindRawValue: "sold", occurredAt: appleSeconds(at + 1000) }),
    record("RemovalRecord", { id: id(51), sheepID, kindRawValue: "deceased", occurredAt: appleSeconds(at + 2000) }),
  ], { legacyStatusSnapshotIsAuthoritative: false });
  assert.equal(sheep(p).v2State.status, "removed");
  assert.equal(sheep(p).v2State.removedAt, new Date(at + 1000).toISOString());
});

test("weaning updates a lamb's lifecycle but does not change an adult imported purpose", () => {
  const change = event(11, "weaning.record", "recordWeaning", { sheepID, weanWeightText: "18.5", occurredAt: at + 1000, note: "" }, [{ type: "weaning", id: id(50) }]);
  const lamb = projection(); apply(lamb, change);
  assert.equal(sheep(lamb).payload_json.strings.purpose, "断奶羔羊");
  const adult = projection([], { purpose: "繁殖母羊" }); apply(adult, change);
  assert.equal(sheep(adult).payload_json.strings.purpose, "繁殖母羊");
});

test("revoke weaning returns a lamb to suckling without deleting its audit fact", () => {
  const p = projection();
  apply(p, event(11, "weaning.record", "recordWeaning", { sheepID, weanWeightText: "18.5", occurredAt: at + 1000, note: "" }, [{ type: "weaning", id: id(50) }]));
  assert.equal(sheep(p).payload_json.strings.purpose, "断奶羔羊");
  apply(p, event(12, "record.revoke", "tombstone", { entityType: "weaning", entityID: id(50), reason: "录入错误" }, [{ type: "weaning", id: id(50) }]));
  assert.equal(sheep(p).payload_json.strings.purpose, "哺乳羔羊");
  assert.equal(p.models.get("WeaningRecord").size, 1);
});

test("unassigned sheep keep a null current pen instead of inheriting a historical transfer", () => {
  const p = projection([record("TransferRecord", { id: id(60), sheepID, toPenID: penB })], { currentPenID: null });
  assert.equal(sheep(p).v2State.penID, null);
});

test("unknown commands fail visibly instead of presenting stale data as current", () => {
  const p = projection();
  const change = event(11, "future.command", "future", {}, [{ type: "sheepProfile", id: sheepID }]);
  assert.throws(() => apply(p, change), (error) => error.code === "CLOUD_V2_UPDATE_REQUIRED");
});

test("checkpoint digest validation rejects corruption and declared size mismatch", async () => {
  const raw = Buffer.from(JSON.stringify([record("FarmRecord", { id: farmID })]));
  const bytes = gzipSync(raw);
  const descriptor = { compressedBytes: bytes.length, uncompressedBytes: raw.length,
    compressedSHA256: await sha256(bytes), contentSHA256: await sha256(raw), recordCount: 1, modelNames: ["FarmRecord"] };
  assert.equal((await decodeCheckpointChunk(bytes, descriptor)).length, 1);
  const corrupt = Buffer.from(bytes); corrupt[corrupt.length - 1] ^= 1;
  await assert.rejects(decodeCheckpointChunk(corrupt, descriptor));
  await assert.rejects(decodeCheckpointChunk(bytes, { ...descriptor, uncompressedBytes: raw.length - 1 }));
});

test("reopening a farm reuses verified checkpoint bytes and downloads a damaged local chunk again", async () => {
  const { records, manifest: base } = source();
  const raw = Buffer.from(JSON.stringify(records));
  const bytes = gzipSync(raw);
  const checkpointID = id(90);
  const descriptor = {
    index: 0, objectKey: `${farmID}/${checkpointID}/00000.json.gz`,
    compressedBytes: bytes.length, uncompressedBytes: raw.length,
    compressedSHA256: await sha256(bytes), contentSHA256: await sha256(raw),
    recordCount: records.length, modelNames: Object.keys(base.modelCounts),
  };
  const manifest = { ...base, formatVersion: 1, minimumClientCapability: 1, checkpointID,
    boundaryEventDigest: "a".repeat(64), receiptChainDigest: "b".repeat(64), businessDigest: "c".repeat(64),
    chunks: [descriptor] };
  const farm = { id: farmID, generation: 3 };
  const storageOrigin = "https://storage.example";
  const ticket = { manifest, downloads: [{ index: 0,
    url: `${storageOrigin}/storage/v1/object/sign/esheep-cloud-checkpoints/${descriptor.objectKey}` }] };
  const client = {
    rpc: () => ({ then: (resolve) => resolve({ data: { farm_id: farmID, farm_generation: 3, v2_ready: true, cloud_head: 10 } }) }),
    functions: { invoke: async () => ({ data: ticket, error: null }) },
  };
  const saved = new Map();
  const persistentCache = {
    read: async (scope, item) => saved.get(`${scope}:${item.index}`) ?? null,
    write: async (scope, item, value) => { saved.set(`${scope}:${item.index}`, value); },
  };
  let downloads = 0;
  const fetchImpl = async () => { downloads += 1; return new Response(bytes); };
  const options = { accountID: id(91), storageOrigin, persistentCache, fetchImpl };
  await loadCloudV2Projection(client, farm, options);
  assert.equal(downloads, 1);
  await clearCloudV2Cache();
  const reopened = await loadCloudV2Projection(client, farm, options);
  assert.equal(reopened.rowsByType.get("sheep").length, 1);
  assert.equal(downloads, 1);
  await clearCloudV2Cache();
  const [key] = saved.keys();
  saved.set(key, Uint8Array.of(0, 0, 0));
  await loadCloudV2Projection(client, farm, options);
  assert.equal(downloads, 2);
});

test("event validation rejects missing sequence numbers and foreign authority", async () => {
  await assert.rejects(validateV2Event({ event_sequence: 12 }, { id: farmID, generation: 3 }, 11));
  await assert.rejects(validateV2Event({ farm_id: id(99), event_sequence: 11 }, { id: farmID, generation: 3 }, 11));
});

async function incrementalFixture() {
  await clearCloudV2Cache();
  const { records, manifest: base } = source();
  const raw = Buffer.from(JSON.stringify(records)), bytes = gzipSync(raw), checkpointID = id(90);
  const descriptor = { index: 0, objectKey: `${farmID}/${checkpointID}/00000.json.gz`,
    compressedBytes: bytes.length, uncompressedBytes: raw.length, compressedSHA256: await sha256(bytes),
    contentSHA256: await sha256(raw), recordCount: records.length, modelNames: Object.keys(base.modelCounts) };
  const manifest = { ...base, formatVersion: 1, minimumClientCapability: 1, checkpointID,
    boundaryEventDigest: "a".repeat(64), receiptChainDigest: "b".repeat(64), businessDigest: "c".repeat(64), chunks: [descriptor] };
  const state = { head: 10, generation: 3, tickets: 0, checks: 0, reads: [], events: [], denyFinal: false, beforeFinal: null };
  const storageOrigin = "https://storage.example";
  const client = {
    rpc: async (name, args) => {
      if (name === "esheep_cloud_fetch_status_v2") {
        state.checks++;
        if (state.checks % 2 === 0) {
          await state.beforeFinal?.();
          if (state.denyFinal) return { error: new Error("membership revoked") };
        }
        return { data: { farm_id: farmID, farm_generation: state.generation, v2_ready: true, cloud_head: state.head } };
      }
      state.reads.push(args.p_after_event_sequence);
      return { data: { cloud_head: state.head, events: state.events.filter(e => e.event_sequence > args.p_after_event_sequence) } };
    },
    functions: { invoke: async () => { state.tickets++; return { data: { manifest, downloads: [{ index: 0,
      url: `${storageOrigin}/storage/v1/object/sign/esheep-cloud-checkpoints/${descriptor.objectKey}` }] } }; } },
  };
  const options = { accountID: id(91), storageOrigin, fetchImpl: async () => new Response(bytes),
    persistentCache: { read: async () => null, write: async () => {} } };
  const read = (overrides = {}) => loadCloudV2Projection(client, { id: farmID, generation: 3 }, { ...options, ...overrides });
  async function addEvent(sequence, active) {
    const e = { protocol_version: 2, schema_version: 1, farm_id: farmID, farm_generation: 3,
      event_sequence: sequence, event_id: id(sequence + 200), command_id: id(sequence + 100),
      event_kind: "fields_patched", stream_type: "pen", stream_id: penB, affected_fields: ["isActive"],
      actor_account_id: id(7), source_device_id: id(8), source_device_sequence: sequence,
      occurred_at_millis: at + sequence * 1000, received_at_millis: at + sequence * 1000,
      before_digest: "a".repeat(64), after_digest: "b".repeat(64), source_command_digest: "c".repeat(64),
      event_body_canonical: JSON.stringify({ changes: [{ field: "isActive", field_version: sequence - 10,
        value_digest: "d".repeat(64), value: { type: "boolean", value: active } }] }) };
    e.event_body_digest = await sha256(e.event_body_canonical);
    e.event_digest = await sha256(["esheep-cloud-event-v2", farmID, 3, sequence, e.event_id, e.command_id,
      e.stream_type, e.stream_id, "isActive", e.event_body_digest, e.before_digest, e.after_digest,
      e.actor_account_id, e.source_device_id, sequence, e.occurred_at_millis, e.received_at_millis,
      e.source_command_digest].join("\n"));
    state.events.push(e); state.head = sequence;
  }
  return { state, read, addEvent, client, options, manifest, bytes };
}

test("reopening verifies the cloud manifest and cached bytes without requesting signed download links", async () => {
  const fixture = await incrementalFixture();
  const { state, read, addEvent, client, options, manifest, bytes } = fixture;
  const originalRPC = client.rpc;
  let manifests = 0;
  client.rpc = async (name, args) => {
    if (name !== "esheep_cloud_checkpoint_manifest_v1") return originalRPC(name, args);
    manifests++;
    assert.deepEqual(args, { p_farm_id: farmID, p_farm_generation: 3, p_checkpoint_id: null });
    return { data: { manifest } };
  };
  options.persistentCache = {
    hasScope: async prefix => { assert.equal(prefix, `https://storage.example:${id(91)}:${farmID}:3:`); return true; },
    read: async () => bytes,
  };
  options.fetchImpl = async () => { throw new Error("cached bytes must not be downloaded again"); };
  await addEvent(11, false);
  const result = await read();
  assert.equal(result.models.PenRecord.find(p => p.id === penB).isActive, false);
  assert.deepEqual(state.reads, [10]);
  assert.equal(state.checks, 2);
  assert.equal(manifests, 1);
  assert.equal(state.tickets, 0);
});

test("a corrupt saved chunk requests the exact checkpoint ticket and validates replacement bytes", async () => {
  const { read, client, options, manifest, bytes } = await incrementalFixture();
  const originalRPC = client.rpc, originalInvoke = client.functions.invoke;
  client.rpc = (name, args) => name === "esheep_cloud_checkpoint_manifest_v1"
    ? Promise.resolve({ data: { manifest } }) : originalRPC(name, args);
  let tickets = 0, downloads = 0, repaired = null;
  client.functions.invoke = async (name, args) => {
    tickets++; assert.equal(args.body.checkpoint_id, manifest.checkpointID);
    return originalInvoke(name, args);
  };
  options.persistentCache = { hasScope: async () => true, read: async () => Uint8Array.of(1, 2, 3),
    write: async (_scope, _descriptor, value) => { repaired = value; } };
  options.fetchImpl = async () => { downloads++; return new Response(bytes); };
  assert.equal((await read()).rowsByType.get("sheep").length, 1);
  assert.equal(tickets, 1); assert.equal(downloads, 1);
  assert.deepEqual(Buffer.from(repaired), bytes);
});

test("saved files cannot bypass manifest authorization, integrity or final membership checks", async () => {
  for (const failure of ["permission", "manifest", "final"]) {
    const { read, client, options, manifest, bytes, state } = await incrementalFixture();
    const originalRPC = client.rpc;
    client.rpc = async (name, args) => {
      if (name !== "esheep_cloud_checkpoint_manifest_v1") return originalRPC(name, args);
      if (failure === "permission") return { error: new Error("checkpoint_read_denied") };
      return { data: { manifest: failure === "manifest" ? { ...manifest, farmID: id(999) } : manifest } };
    };
    options.persistentCache = { hasScope: async () => true, read: async () => bytes };
    state.denyFinal = failure === "final";
    await assert.rejects(read(), error => /denied|revoked/.test(error.message) || error.code === "CLOUD_V2_INTEGRITY");
    assert.equal(state.tickets, 0);
  }
});

test("missing cached files cannot mix a different ticket manifest into the current receive", async () => {
  const { read, client, options, manifest } = await incrementalFixture();
  const originalRPC = client.rpc, originalInvoke = client.functions.invoke;
  client.rpc = (name, args) => name === "esheep_cloud_checkpoint_manifest_v1"
    ? Promise.resolve({ data: { manifest } }) : originalRPC(name, args);
  options.persistentCache = { hasScope: async () => true, read: async () => null };
  client.functions.invoke = async (...args) => {
    const result = await originalInvoke(...args);
    return { data: { ...result.data, manifest: { ...manifest, checkpointID: id(999) } } };
  };
  options.fetchImpl = async () => { throw new Error("must reject before downloading"); };
  await assert.rejects(read(), error => error.code === "CLOUD_V2_INTEGRITY");
});

test("first receive overlaps authorized status and ticket requests without a metadata detour", { timeout: 1000 }, async () => {
  const { read, client, state } = await incrementalFixture();
  const originalRPC = client.rpc, originalInvoke = client.functions.invoke;
  let releaseStatus, first = true;
  client.rpc = (name, args) => {
    assert.notEqual(name, "esheep_cloud_checkpoint_manifest_v1");
    if (first && name === "esheep_cloud_fetch_status_v2") {
      first = false;
      return new Promise(resolve => { releaseStatus = () => resolve(originalRPC(name, args)); });
    }
    return originalRPC(name, args);
  };
  client.functions.invoke = async (...args) => { releaseStatus(); return originalInvoke(...args); };
  assert.equal((await read()).rowsByType.get("sheep").length, 1);
  assert.equal(state.tickets, 1); assert.equal(state.checks, 2);
});

test("warm refresh reads only new events, retains authority checks and does not share mutable UI models", async () => {
  const { state, read, addEvent } = await incrementalFixture();
  const first = await read();
  first.models.PenRecord.find(p => p.id === penB).name = "UI-only mutation";
  await addEvent(11, false);
  const updated = await read();
  assert.equal(updated.revision, 11);
  assert.equal(updated.models.PenRecord.find(p => p.id === penB).isActive, false);
  assert.equal(updated.models.PenRecord.find(p => p.id === penB).name, "二舍");
  await addEvent(12, true);
  assert.equal((await read()).models.PenRecord.find(p => p.id === penB).isActive, true);
  await read();
  assert.equal(state.tickets, 1, "warm reads must not request the full checkpoint again");
  assert.deepEqual(state.reads, [10, 11], "already verified event history must not be replayed");
  assert.equal(state.checks, 8, "every read must recheck authority before and after replay");
});

test("event-tail fetch overlaps checkpoint receive but is applied only after verification", {timeout:1000}, async () => {
  const {read,client,options,bytes,addEvent,state} = await incrementalFixture();
  await addEvent(11,false);
  let unlock;
  const tailStarted = new Promise(resolve=>{unlock=resolve;});
  options.fetchImpl = async()=>{await tailStarted;return new Response(bytes);};
  const originalRPC = client.rpc;
  client.rpc = (name,args)=>{
    if(name==='esheep_cloud_pull_events_v2') unlock();
    return originalRPC(name,args);
  };
  const result = await read();
  assert.equal(result.models.PenRecord.find(p=>p.id===penB).isActive,false);
  assert.deepEqual(state.reads,[10]);
  assert.equal(state.checks,2);
});

test("failed checkpoint verification cannot publish prefetched events or leak rejected promises", async () => {
  const {read,client,options,addEvent} = await incrementalFixture();
  await addEvent(11,false);
  const originalRPC = client.rpc;
  client.rpc = (name,args)=>name==='esheep_cloud_pull_events_v2'
    ? Promise.resolve({error:new Error('tail denied')}) : originalRPC(name,args);
  options.fetchImpl = async()=>new Response(Uint8Array.of(1,2,3));
  await assert.rejects(read(),error=>error.code==='CLOUD_V2_INTEGRITY');
});

test("incremental reuse rejects corrupted events and a permission change without publishing partial state", async () => {
  const { state, read, addEvent } = await incrementalFixture();
  await read(); await addEvent(11, false);
  state.events[0].event_body_canonical += " ";
  await assert.rejects(read(), error => error.code === "CLOUD_V2_INTEGRITY");
  state.events[0].event_body_canonical = state.events[0].event_body_canonical.trimEnd();
  state.checks = 0; state.denyFinal = true;
  await assert.rejects(read(), /membership revoked/);
  state.denyFinal = false; state.checks = 0;
  const result = await read();
  assert.equal(result.models.PenRecord.find(p => p.id === penB).isActive, false);
  assert.equal(state.tickets, 3, "failed validation cannot commit a reusable projection");
});

test("incremental projection reuse is scoped to account and cannot be repopulated after sign-out", async () => {
  const { state, read } = await incrementalFixture();
  await read(); await read({ accountID: id(92) });
  assert.equal(state.tickets, 2);
  state.beforeFinal = async () => { state.beforeFinal = null; await clearCloudV2Cache(); };
  await read();
  await read();
  assert.equal(state.tickets, 3, "an in-flight read must not undo clearCloudV2Cache");
  state.generation = 4;
  await assert.rejects(read(), /版本已变化/);
});
