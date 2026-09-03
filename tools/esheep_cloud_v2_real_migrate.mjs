#!/usr/bin/env node

/*
 * Real Air -> eSheep Cloud V2 migration helper.
 *
 * This file deliberately has no network writes.  It reads the backed-up Air
 * store, creates verifiable photo variants, and emits a plan plus SQL files.
 * The caller performs the separately logged database/storage writes only
 * after inspecting the generated plan.
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const ROOT = '/Users/jinxliu/Documents/Codex/eSheepNext';
const AIR_STORE = '/tmp/esheep-v2-device-backups-20260903/air/Library/Application Support/eSheepNext.store';
const AIR_APP_SUPPORT = '/tmp/esheep-v2-device-backups-20260903/air/Library/Application Support/eSheepNext';
const DRAFTS = '/tmp/esheep-v2-air-typed-drafts.json';
const FARM_ID = '8b0fa55e-2a34-4398-ae77-7d7d3701c5dd';
const OWNER_USER_ID = 'fa0cfb7d-8b35-430e-8fd9-5a6768518699';
const OWNER_ACCOUNT_ID = '5d741fd3-9339-5597-a68c-d8b768e1527c';
const GENERATION = 2;
const DEVICE_ID = 'b1e5f000-0000-4000-8000-000000000002';
const OUTPUT_DIR = '/tmp/esheep-v2-real-migration-20260904';
const ASSET_DIR = path.join(OUTPUT_DIR, 'assets');
const PLAN_PATH = path.join(OUTPUT_DIR, 'migration-plan.json');
const SEED_SQL_PATH = path.join(OUTPUT_DIR, 'seed.sql');
const CONFIRM_SQL_PATH = path.join(OUTPUT_DIR, 'confirm-assets.sql');
const BATCH_DIR = path.join(OUTPUT_DIR, 'command-batches');
const HISTORICAL_ARCHIVE_PATCH_FIELD = 'isHistoricalArchive';

// The owner confirmed these are newly added avatar photos whose avatar
// relation was lost. They have no legacy avatar value to choose between, so
// migration restores the relation from the Air photo asset and does not emit
// an attention item.
const NEW_AVATAR_REPAIR_EAR_TAGS = Object.freeze(['DH054', '256', '172545', '8062', 'A058']);

function die(message) {
  throw new Error(message);
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function sqliteJSON(sql) {
  const raw = execFileSync('sqlite3', ['-json', AIR_STORE, sql], { encoding: 'utf8' });
  return raw.trim() ? JSON.parse(raw) : [];
}

function sha256(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function sha256File(file) {
  return sha256(fs.readFileSync(file));
}

function b64(data) {
  return Buffer.from(data).toString('base64');
}

function fromB64(text) {
  return Buffer.from(text, 'base64');
}

function sqlString(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function sqlJSON(value) {
  return `${sqlString(JSON.stringify(value))}::jsonb`;
}

function uuidFromHex(hex) {
  const value = String(hex || '').replaceAll('-', '').toLowerCase();
  if (!/^[0-9a-f]{32}$/.test(value)) return null;
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
}

function uuidFromHash(input) {
  const bytes = Buffer.from(sha256(input), 'hex').subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return uuidFromHex(hex);
}

function stableJSON(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(',')}]`;
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(',')}}`;
}

function valueDigest(value) {
  const type = value?.type;
  let canonical;
  switch (type) {
    case 'null':
      canonical = 'null';
      break;
    case 'string':
      canonical = `string:${Buffer.byteLength(String(value.value ?? ''), 'utf8')}:${String(value.value ?? '')}`;
      break;
    case 'integer':
      canonical = `integer:${BigInt(value.value).toString()}`;
      break;
    case 'decimal':
      canonical = `decimal:${String(value.value ?? '')}`;
      break;
    case 'boolean':
      canonical = `boolean:${value.value ? 'true' : 'false'}`;
      break;
    case 'date':
      canonical = `date:${Math.round(Number(value.value))}`;
      break;
    case 'identifier':
      canonical = `identifier:${String(value.value).toLowerCase()}`;
      break;
    case 'strings':
      canonical = `strings:${(value.value || []).map((item) => `${Buffer.byteLength(item, 'utf8')}:${item}`).join('|')}`;
      break;
    case 'identifiers':
      canonical = `identifiers:${(value.value || []).map((item) => String(item).toLowerCase()).join('|')}`;
      break;
    default:
      die(`unknown field value type: ${type}`);
  }
  return sha256(canonical);
}

function dateFromCoreDataSeconds(value) {
  if (value === null || value === undefined || value === '') return null;
  const seconds = Number(value);
  if (!Number.isFinite(seconds)) die(`invalid Core Data date: ${value}`);
  return new Date((seconds + 978307200) * 1000).toISOString();
}

function millisFromCoreDataSeconds(value) {
  if (value === null || value === undefined || value === '') return null;
  const seconds = Number(value);
  if (!Number.isFinite(seconds)) die(`invalid Core Data date: ${value}`);
  return Math.round((seconds + 978307200) * 1000);
}

function dimensions(file) {
  const text = execFileSync('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', file], { encoding: 'utf8' });
  const width = Number(text.match(/pixelWidth:\s*(\d+)/)?.[1]);
  const height = Number(text.match(/pixelHeight:\s*(\d+)/)?.[1]);
  if (!Number.isInteger(width) || width <= 0 || !Number.isInteger(height) || height <= 0) {
    die(`could not read image dimensions: ${file}\n${text}`);
  }
  return { width, height };
}

function convertJPEG(source, destination, maxDimension) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  execFileSync('sips', ['-s', 'format', 'jpeg', '-Z', String(maxDimension), source, '--out', destination], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (!fs.existsSync(destination) || fs.statSync(destination).size <= 0) {
    die(`sips produced no bytes: ${destination}`);
  }
}

function localPhotoPath(relativePath) {
  if (!relativePath) return null;
  const normalized = String(relativePath).replace(/^\/+/, '');
  const candidate = path.resolve(AIR_APP_SUPPORT, normalized);
  const root = path.resolve(AIR_APP_SUPPORT) + path.sep;
  if (!candidate.startsWith(root)) die(`photo path escapes Air Application Support: ${relativePath}`);
  return candidate;
}

function buildPhotoAssets() {
  const rows = sqliteJSON(`
    select photo.hexID as id, photo.hexSheepID as sheep, photo.mime,
      photo.content, photo.source, photo.sourceWidth, photo.sourceHeight,
      photo.cloudWidth, photo.cloudHeight, photo.captured, photo.deleted,
      photo.relativePath, photo.earTag, sheep.ZEARTAG as sheepEarTag
    from (
      select hex(ZID) as hexID, hex(ZSHEEPID) as hexSheepID,
        ZMIMETYPE as mime, ZSHA256 as content, ZSOURCESHA256 as source,
        ZSOURCEPIXELWIDTH as sourceWidth, ZSOURCEPIXELHEIGHT as sourceHeight,
        ZCLOUDPIXELWIDTH as cloudWidth, ZCLOUDPIXELHEIGHT as cloudHeight,
        ZCAPTUREDAT as captured, ZDELETEDAT as deleted,
        ZRELATIVEPATH as relativePath, ZORIGINALEARTAG as earTag,
        ZSHEEPID as rawSheepID, ZFARMID as rawFarmID, Z_PK
      from ZPHOTOASSETRECORD
      where ZDELETEDAT is null and coalesce(ZRELATIVEPATH, '') <> ''
    ) photo
    left join ZSHEEPRECORD sheep
      on sheep.ZID = photo.rawSheepID and sheep.ZFARMID = photo.rawFarmID
    order by photo.Z_PK
  `);
  if (rows.length !== 27) die(`Air active photo count changed: expected 27, got ${rows.length}`);
  const seen = new Set();
  const assets = [];
  for (const row of rows) {
    const assetID = uuidFromHex(row.id);
    const sheepID = uuidFromHex(row.sheep);
    if (!assetID) die(`invalid photo asset ID: ${row.id}`);
    if (seen.has(assetID)) die(`duplicate photo asset ID: ${assetID}`);
    seen.add(assetID);
    const sourcePath = localPhotoPath(row.relativePath);
    if (!sourcePath || !fs.existsSync(sourcePath)) die(`Air photo missing: ${sourcePath}`);
    const actualContent = sha256File(sourcePath);
    if (actualContent !== String(row.content).toLowerCase()) {
      die(`Air photo hash mismatch for ${assetID}: db=${row.content} file=${actualContent}`);
    }
    const mimeType = String(row.mime || '').toLowerCase();
    if (!['image/heic', 'image/jpeg'].includes(mimeType)) die(`unsupported photo MIME for ${assetID}: ${mimeType}`);
    const sourceDimensions = dimensions(sourcePath);
    const thumbnailPath = path.join(ASSET_DIR, `${assetID}/thumbnail.jpg`);
    const avatarPath = path.join(ASSET_DIR, `${assetID}/avatar.jpg`);
    const originalPath = path.join(ASSET_DIR, `${assetID}/original.bin`);
    convertJPEG(sourcePath, thumbnailPath, 1024);
    convertJPEG(sourcePath, avatarPath, 512);
    fs.mkdirSync(path.dirname(originalPath), { recursive: true });
    fs.copyFileSync(sourcePath, originalPath);
    const cloudDimensions = dimensions(thumbnailPath);
    const capturedAtMillis = millisFromCoreDataSeconds(row.captured);
    const metadata = {
      mimeType,
      sourceSHA256: String(row.source || row.content).toLowerCase(),
      sourcePixelWidth: String(Number(row.sourceWidth) > 0 ? Number(row.sourceWidth) : sourceDimensions.width),
      sourcePixelHeight: String(Number(row.sourceHeight) > 0 ? Number(row.sourceHeight) : sourceDimensions.height),
      cloudPixelWidth: String(Number(row.cloudWidth) > 0 ? Number(row.cloudWidth) : cloudDimensions.width),
      cloudPixelHeight: String(Number(row.cloudHeight) > 0 ? Number(row.cloudHeight) : cloudDimensions.height)
    };
    if (capturedAtMillis !== null) {
      metadata.capturedAt = String(capturedAtMillis);
      metadata.capturedAtMillis = String(capturedAtMillis);
    }
    if (!/^[0-9a-f]{64}$/.test(metadata.sourceSHA256)) die(`invalid source hash for ${assetID}`);
    const thumbnailSHA256 = sha256File(thumbnailPath);
    const avatarSHA256 = sha256File(avatarPath);
    const originalSHA256 = sha256File(originalPath);
    if (originalSHA256 !== actualContent) die(`original copy changed for ${assetID}`);
    assets.push({
      assetID,
      sheepID,
      mimeType,
      capturedAtMillis,
      metadata,
      metadataDigest: sha256(Buffer.from(stableJSON(metadata), 'utf8')),
      contentSHA256: actualContent,
      thumbnailSHA256,
      avatarSHA256,
      originalSHA256,
      thumbnailByteCount: fs.statSync(thumbnailPath).size,
      avatarByteCount: fs.statSync(avatarPath).size,
      originalByteCount: fs.statSync(originalPath).size,
      sourcePath,
      thumbnailPath,
      avatarPath,
      originalPath,
      storagePaths: {
        thumbnail: `${FARM_ID}/${GENERATION}/${assetID}/${thumbnailSHA256}/thumbnail.jpg`,
        avatar: `${FARM_ID}/${GENERATION}/${assetID}/${avatarSHA256}/avatar.jpg`,
        original: `${FARM_ID}/${GENERATION}/${assetID}/${originalSHA256}/original.bin`
      },
      legacyEarTag: row.earTag || null,
      sheepEarTag: row.sheepEarTag || null
    });
  }
  return assets;
}

function makeUnsigned({ commandID, sourceRequestID, occurredAtMillis, kind, payload, streams, fields, changes, requiredAssetIDs }) {
  return {
    protocolVersion: 2,
    schemaVersion: 1,
    commandID,
    sourceRequestID,
    farmID: FARM_ID,
    farmGeneration: GENERATION,
    accountID: OWNER_ACCOUNT_ID,
    deviceID: DEVICE_ID,
    deviceSequence: 0,
    createdAt: 0,
    occurredAt: occurredAtMillis,
    commandKind: kind,
    payload,
    affectedStreams: streams,
    affectedFields: fields,
    fieldChanges: changes,
    prerequisiteCommandIDs: [],
    requiredAssetIDs
  };
}

function draftPayload(draft) {
  return JSON.parse(fromB64(draft.payloadBase64).toString('utf8'));
}

function draftArray(draft, key) {
  return JSON.parse(fromB64(draft[key]).toString('utf8'));
}

function buildCommands(drafts, assets) {
  const allDrafts = [...drafts.baseline, ...drafts.special];
  const commands = [];
  const fieldState = new Map();
  const nullDigest = valueDigest({ type: 'null' });
  const sourceCreatedAt = Date.now();

  const appendDraft = (draft, ordinal, extension = {}) => {
    const kind = draft.kind;
    const payload = draftPayload(draft);
    const streams = draftArray(draft, 'affectedStreamsBase64');
    let changes = draftArray(draft, 'fieldChangesBase64');
    if (!Array.isArray(changes)) changes = [];
    const requiredAssetIDs = draftArray(draft, 'requiredAssetIDsBase64');
    const fields = [];
    if (changes.length > 0) {
      if (streams.length !== 1) die(`field patch has multiple streams: ${kind}`);
      const stream = streams[0];
      const stateKey = `${stream.type}:${String(stream.id).toLowerCase()}`;
      const state = fieldState.get(stateKey) || new Map();
      for (const change of changes) {
        const current = state.get(change.field) || { version: 0, digest: nullDigest };
        fields.push({
          stream,
          field: change.field,
          observedVersion: current.version,
          baseValueDigest: current.digest
        });
        const desiredValue = change.mutation.action === 'clear'
          ? { type: 'null' }
          : change.mutation.value;
        state.set(change.field, {
          version: current.version + 1,
          digest: valueDigest(desiredValue)
        });
      }
      fieldState.set(stateKey, state);
    }
    if (extension.legacyOffspringSexRawValues && Object.keys(extension.legacyOffspringSexRawValues).length > 0) {
      const body = payload.body;
      const caseKey = Object.keys(body)[0];
      if (caseKey && body[caseKey] && typeof body[caseKey] === 'object') {
        body[caseKey].legacyOffspringSexRawValues = extension.legacyOffspringSexRawValues;
      }
    }
    const commandID = uuidFromHash(`air-v2-command:${ordinal}:${kind}:${draft.entityID}`);
    const sourceRequestID = uuidFromHash(`air-v2-source-request:${ordinal}:${kind}:${draft.entityID}`);
    const occurredAtMillis = Number.isFinite(Number(draft.occurredAtMillis)) && Number(draft.occurredAtMillis) > 0
      ? Math.round(Number(draft.occurredAtMillis))
      : sourceCreatedAt;
    const unsigned = makeUnsigned({
      commandID,
      sourceRequestID,
      occurredAtMillis,
      kind,
      payload,
      streams,
      fields,
      changes,
      requiredAssetIDs
    });
    unsigned.deviceSequence = ordinal;
    unsigned.createdAt = sourceCreatedAt;
    const unsignedBytes = Buffer.from(stableJSON(unsigned), 'utf8');
    const contentDigest = sha256(unsignedBytes);
    const signature = Buffer.concat([
      crypto.createHash('sha256').update(unsignedBytes).digest(),
      crypto.createHash('sha256').update(Buffer.concat([unsignedBytes, Buffer.from('eSheep-Air-V2-migration', 'utf8')])).digest()
    ]);
    commands.push({
      ordinal,
      kind,
      entityType: draft.entityType,
      entityID: draft.entityID,
      commandID,
      sourceRequestID,
      occurredAtMillis,
      unsigned,
      unsignedCommandBase64: unsignedBytes.toString('base64'),
      contentDigest,
      deviceSignatureBase64: signature.toString('base64'),
      requiredAssetIDs,
      sourceRevision: draft.sourceRevision,
      replayOrder: draft.replayOrder,
      legacyOffspringSexRawValues: draft.legacyOffspringSexRawValues || {}
    });
  };

  for (const draft of allDrafts) {
    appendDraft(draft, commands.length + 1, {
      legacyOffspringSexRawValues: draft.legacyOffspringSexRawValues
    });
  }

  const activeAssetIDs = new Set(assets.map((asset) => asset.assetID));
  const activeAvatarRows = sqliteJSON(`
    select hex(ZSHEEPID) as sheep, hex(ZPHOTOASSETID) as photo, ZUPDATEDAT as updated
    from ZSHEEPAVATARRECORD
    order by ZUPDATEDAT desc
  `);
  const avatarBySheep = new Map();
  for (const row of activeAvatarRows) {
    const sheepID = uuidFromHex(row.sheep);
    const photoID = uuidFromHex(row.photo);
    if (sheepID && !avatarBySheep.has(sheepID) && photoID && activeAssetIDs.has(photoID)) {
      avatarBySheep.set(sheepID, { photoID, updatedMillis: millisFromCoreDataSeconds(row.updated) });
    }
  }

  const repairTagSQL = NEW_AVATAR_REPAIR_EAR_TAGS
    .map((tag) => `'${tag.replaceAll("'", "''")}'`)
    .join(',');
  const repairRows = sqliteJSON(`
    select trim(sheep.ZEARTAG) as earTag, hex(sheep.ZID) as sheep,
      hex(photo.ZID) as photo, photo.ZCREATEDAT as created
    from ZSHEEPRECORD sheep
    join ZPHOTOASSETRECORD photo
      on photo.ZSHEEPID = sheep.ZID and photo.ZFARMID = sheep.ZFARMID
      and photo.ZDELETEDAT is null and coalesce(photo.ZRELATIVEPATH, '') <> ''
    where upper(trim(sheep.ZEARTAG)) in (${repairTagSQL})
    order by upper(trim(sheep.ZEARTAG)), photo.ZCREATEDAT, photo.Z_PK
  `);
  if (repairRows.length !== NEW_AVATAR_REPAIR_EAR_TAGS.length) {
    die(`new avatar repair asset count changed: expected ${NEW_AVATAR_REPAIR_EAR_TAGS.length}, got ${repairRows.length}`);
  }
  const assetsByID = new Map(assets.map((asset) => [asset.assetID.toLowerCase(), asset]));
  const repairsByTag = new Map();
  const newAvatarRepairs = [];
  for (const row of repairRows) {
    const earTag = String(row.earTag || '').trim();
    const normalizedTag = earTag.toUpperCase();
    if (repairsByTag.has(normalizedTag)) die(`multiple active new avatar photos for ${earTag}`);
    const sheepID = uuidFromHex(row.sheep);
    const photoID = uuidFromHex(row.photo);
    const asset = photoID ? assetsByID.get(photoID.toLowerCase()) : null;
    if (!sheepID || !photoID || !asset || asset.sheepID?.toLowerCase() !== sheepID.toLowerCase()) {
      die(`new avatar repair does not resolve to an active Air asset: ${earTag}`);
    }
    if (avatarBySheep.has(sheepID)) die(`new avatar repair already has a legacy avatar: ${earTag}`);
    const repair = {
      earTag,
      sheepID,
      photoID,
      updatedMillis: millisFromCoreDataSeconds(row.created),
      reason: 'new_avatar_without_legacy_avatar_record'
    };
    repairsByTag.set(normalizedTag, repair);
    newAvatarRepairs.push(repair);
    avatarBySheep.set(sheepID, repair);
  }
  for (const expectedTag of NEW_AVATAR_REPAIR_EAR_TAGS) {
    if (!repairsByTag.has(expectedTag.toUpperCase())) die(`missing new avatar repair tag: ${expectedTag}`);
  }

  // Photo registrations must follow sheep.add so the server can prove that a
  // sheep-linked asset has a valid sheep stream.  Avatar selections follow
  // registration because they require a verified asset variant.
  for (const asset of assets) {
    const payload = {
      kind: 'photoAsset.register',
      body: {
        register: {
          assetID: asset.assetID,
          sheepID: asset.sheepID,
          capturedAt: asset.capturedAtMillis,
          mimeType: asset.mimeType,
          contentSHA256: asset.contentSHA256,
          metadata: asset.metadata,
          metadataDigest: asset.metadataDigest,
          thumbnailSHA256: asset.thumbnailSHA256,
          avatarSHA256: asset.avatarSHA256,
          originalSHA256: asset.originalSHA256,
          thumbnailByteCount: asset.thumbnailByteCount,
          avatarByteCount: asset.avatarByteCount,
          originalByteCount: asset.originalByteCount
        }
      }
    };
    const ordinal = commands.length + 1;
    const commandID = uuidFromHash(`air-v2-photo-register:${ordinal}:${asset.assetID}`);
    const sourceRequestID = uuidFromHash(`air-v2-photo-source-request:${ordinal}:${asset.assetID}`);
    const occurredAtMillis = asset.capturedAtMillis ?? sourceCreatedAt;
    const unsigned = makeUnsigned({
      commandID,
      sourceRequestID,
      occurredAtMillis,
      kind: 'photoAsset.register',
      payload,
      streams: [{ type: 'photoAsset', id: asset.assetID }],
      fields: [],
      changes: [],
      requiredAssetIDs: [asset.assetID]
    });
    unsigned.deviceSequence = ordinal;
    unsigned.createdAt = sourceCreatedAt;
    const unsignedBytes = Buffer.from(stableJSON(unsigned), 'utf8');
    const contentDigest = sha256(unsignedBytes);
    const signature = Buffer.concat([
      crypto.createHash('sha256').update(unsignedBytes).digest(),
      crypto.createHash('sha256').update(Buffer.concat([unsignedBytes, Buffer.from('eSheep-Air-V2-migration', 'utf8')])).digest()
    ]);
    commands.push({
      ordinal,
      kind: 'photoAsset.register',
      entityType: 'photoAsset',
      entityID: asset.assetID,
      commandID,
      sourceRequestID,
      occurredAtMillis,
      unsigned,
      unsignedCommandBase64: unsignedBytes.toString('base64'),
      contentDigest,
      deviceSignatureBase64: signature.toString('base64'),
      requiredAssetIDs: [asset.assetID],
      sourceRevision: 0,
      replayOrder: 200
    });
  }

  for (const [sheepID, avatar] of avatarBySheep) {
    const assetID = avatar.photoID;
    const payload = {
      kind: 'sheepAvatar.set',
      body: { setAvatar: { sheepID, photoAssetID: assetID } }
    };
    const streams = [{ type: 'sheepAvatar', id: sheepID }];
    const current = fieldState.get(`sheepAvatar:${sheepID}`)?.get('avatar') || { version: 0, digest: nullDigest };
    const changes = [{
      field: 'avatar',
      mutation: { action: 'set', value: { type: 'identifier', value: assetID } }
    }];
    const fields = [{
      stream: streams[0],
      field: 'avatar',
      observedVersion: current.version,
      baseValueDigest: current.digest
    }];
    const ordinal = commands.length + 1;
    const commandID = uuidFromHash(`air-v2-avatar:${ordinal}:${sheepID}:${assetID}`);
    const sourceRequestID = uuidFromHash(`air-v2-avatar-source-request:${ordinal}:${sheepID}:${assetID}`);
    const occurredAtMillis = avatar.updatedMillis ?? sourceCreatedAt;
    const unsigned = makeUnsigned({
      commandID,
      sourceRequestID,
      occurredAtMillis,
      kind: 'sheepAvatar.set',
      payload,
      streams,
      fields,
      changes,
      requiredAssetIDs: [assetID]
    });
    unsigned.deviceSequence = ordinal;
    unsigned.createdAt = sourceCreatedAt;
    const unsignedBytes = Buffer.from(stableJSON(unsigned), 'utf8');
    const contentDigest = sha256(unsignedBytes);
    const signature = Buffer.concat([
      crypto.createHash('sha256').update(unsignedBytes).digest(),
      crypto.createHash('sha256').update(Buffer.concat([unsignedBytes, Buffer.from('eSheep-Air-V2-migration', 'utf8')])).digest()
    ]);
    commands.push({
      ordinal,
      kind: 'sheepAvatar.set',
      entityType: 'sheepAvatar',
      entityID: sheepID,
      commandID,
      sourceRequestID,
      occurredAtMillis,
      unsigned,
      unsignedCommandBase64: unsignedBytes.toString('base64'),
      contentDigest,
      deviceSignatureBase64: signature.toString('base64'),
      requiredAssetIDs: [assetID],
      sourceRevision: 0,
      replayOrder: 210,
      avatarRepairReason: avatar.reason || null,
      avatarRepairEarTag: avatar.earTag || null
    });
  }

  const archiveRows = sqliteJSON(`
    select trim(ZEARTAG) as earTag, hex(ZID) as sheep,
      ZCREATEDAT as created, ZLEGACYSOURCEKEY as sourceKey,
      ZDELETEDAT as deleted
    from ZSHEEPRECORD
    where ZISHISTORICALARCHIVE = 1
    order by Z_PK
  `);
  const archiveActiveRows = archiveRows.filter((row) => row.deleted === null || row.deleted === undefined || row.deleted === '');
  const archiveDeletedRows = archiveRows.length - archiveActiveRows.length;
  if (archiveRows.length !== 467 || archiveActiveRows.length !== 460 || archiveDeletedRows !== 7) {
    die(`historical archive row counts changed: total=${archiveRows.length}, active=${archiveActiveRows.length}, deleted=${archiveDeletedRows}`);
  }
  const sheepAdds = new Map(
    commands
      .filter((command) => command.kind === 'sheep.add')
      .map((command) => [String(command.entityID).toLowerCase(), command])
  );
  const historicalArchivePatches = [];
  for (const row of archiveActiveRows) {
    const sheepID = uuidFromHex(row.sheep);
    if (!sheepID) die(`invalid historical archive sheep ID: ${row.sheep}`);
    const sheepAdd = sheepAdds.get(sheepID.toLowerCase());
    if (!sheepAdd) die(`historical archive sheep is missing a sheep.add command: ${sheepID}`);
    const stateKey = `sheepProfile:${sheepID.toLowerCase()}`;
    const state = fieldState.get(stateKey) || new Map();
    const current = state.get(HISTORICAL_ARCHIVE_PATCH_FIELD) || { version: 0, digest: nullDigest };
    const desiredValue = { type: 'boolean', value: true };
    const desiredDigest = valueDigest(desiredValue);
    if (current.digest === desiredDigest) die(`historical archive flag already represented in source drafts: ${sheepID}`);
    const streams = [{ type: 'sheepProfile', id: sheepID }];
    const fields = [{
      stream: streams[0],
      field: HISTORICAL_ARCHIVE_PATCH_FIELD,
      observedVersion: current.version,
      baseValueDigest: current.digest
    }];
    const changes = [{
      field: HISTORICAL_ARCHIVE_PATCH_FIELD,
      mutation: { action: 'set', value: desiredValue }
    }];
    const payload = {
      kind: 'sheep.patchProfile',
      body: {
        patchProfile: {
          sheepID,
          fields: changes
        }
      }
    };
    const ordinal = commands.length + 1;
    const commandID = uuidFromHash(`air-v2-historical-archive-profile:${ordinal}:${sheepID}`);
    const sourceRequestID = uuidFromHash(`air-v2-historical-archive-profile-source-request:${ordinal}:${sheepID}`);
    const occurredAtMillis = millisFromCoreDataSeconds(row.created) ?? sourceCreatedAt;
    const unsigned = makeUnsigned({
      commandID,
      sourceRequestID,
      occurredAtMillis,
      kind: 'sheep.patchProfile',
      payload,
      streams,
      fields,
      changes,
      requiredAssetIDs: []
    });
    unsigned.deviceSequence = ordinal;
    unsigned.createdAt = sourceCreatedAt;
    const unsignedBytes = Buffer.from(stableJSON(unsigned), 'utf8');
    const contentDigest = sha256(unsignedBytes);
    const signature = Buffer.concat([
      crypto.createHash('sha256').update(unsignedBytes).digest(),
      crypto.createHash('sha256').update(Buffer.concat([unsignedBytes, Buffer.from('eSheep-Air-V2-migration', 'utf8')])).digest()
    ]);
    const patch = {
      ordinal,
      kind: 'sheep.patchProfile',
      entityType: 'sheepProfile',
      entityID: sheepID,
      commandID,
      sourceRequestID,
      occurredAtMillis,
      unsigned,
      unsignedCommandBase64: unsignedBytes.toString('base64'),
      contentDigest,
      deviceSignatureBase64: signature.toString('base64'),
      requiredAssetIDs: [],
      sourceRevision: 0,
      replayOrder: 220,
      historicalArchive: {
        earTag: row.earTag || null,
        sourceKey: row.sourceKey || null,
        sheepAddCommandID: sheepAdd.commandID,
        field: HISTORICAL_ARCHIVE_PATCH_FIELD
      }
    };
    commands.push(patch);
    historicalArchivePatches.push(patch.historicalArchive);
    state.set(HISTORICAL_ARCHIVE_PATCH_FIELD, {
      version: current.version + 1,
      digest: desiredDigest
    });
    fieldState.set(stateKey, state);
  }
  return {
    commands,
    avatarCount: avatarBySheep.size,
    repairAvatarCount: newAvatarRepairs.length,
    newAvatarRepairs,
    historicalArchiveRowCount: archiveRows.length,
    historicalArchiveActiveRowCount: archiveActiveRows.length,
    historicalArchiveDeletedRowCount: archiveDeletedRows,
    historicalArchivePatchCount: historicalArchivePatches.length,
    historicalArchivePatches,
    createdAtMillis: sourceCreatedAt
  };
}

function makeDeviceJWK() {
  const { publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return publicKey.export({ format: 'jwk' });
}

function buildSeedSQL({ farm, assets, sourceManifestDigest, deviceJWK, commandCount, firstCommandID }) {
  const createdAt = dateFromCoreDataSeconds(farm.created);
  const updatedAt = dateFromCoreDataSeconds(farm.updated) || createdAt;
  const locationUpdatedAt = dateFromCoreDataSeconds(farm.locationUpdated);
  if (!createdAt || !updatedAt) die('Air farm dates are missing');
  const lines = [
    '-- Generated from the backed-up iPhone Air store. No V1 rows are modified.',
    'begin;',
    "select set_config('request.jwt.claim.role','service_role',true);",
    `do $$ begin
      if exists (select 1 from esheep_cloud.commands where farm_id = ${sqlString(FARM_ID)}::uuid)
         or exists (select 1 from esheep_cloud.events where farm_id = ${sqlString(FARM_ID)}::uuid)
         or exists (select 1 from esheep_cloud.assets where farm_id = ${sqlString(FARM_ID)}::uuid)
         or exists (select 1 from esheep_cloud.streams where farm_id = ${sqlString(FARM_ID)}::uuid)
      then raise exception using message = 'real_migration_target_not_empty'; end if;
    end $$;`,
    `insert into public.devices (device_id,user_id,public_key_jwk,display_name,status,registered_at,revoked_at,tmr_data_protocol_version)
      values (${sqlString(DEVICE_ID)}::uuid,${sqlString(OWNER_USER_ID)}::uuid,${sqlJSON(deviceJWK)},'Air V2 Migration','active',now(),null,2)
      on conflict (device_id) do update set user_id=excluded.user_id,public_key_jwk=excluded.public_key_jwk,display_name=excluded.display_name,status='active',revoked_at=null,tmr_data_protocol_version=2;`,
    `select esheep_cloud.upsert_farm_profile_v2(
      ${sqlString(FARM_ID)}::uuid,${GENERATION},${sqlString(OWNER_ACCOUNT_ID)}::uuid,
      ${sqlString(farm.name)},${sqlString(createdAt)}::timestamptz,${sqlString(updatedAt)}::timestamptz,
      ${farm.loc == null ? 'null' : sqlString(farm.loc)},
      ${farm.lat == null ? 'null' : Number(farm.lat)},
      ${farm.lon == null ? 'null' : Number(farm.lon)},
      ${farm.address == null ? 'null' : sqlString(farm.address)},
      ${sqlString(farm.tz || 'Asia/Shanghai')},
      ${farm.source == null ? 'null' : sqlString(farm.source)},
      ${farm.accuracy == null ? 'null' : Number(farm.accuracy)},
      ${locationUpdatedAt == null ? 'null' : `${sqlString(locationUpdatedAt)}::timestamptz`}
    ) as farm_profile_digest;`,
    `insert into esheep_cloud.farm_state (farm_id,farm_generation,status,v2_ready,write_frozen,event_head,v1_final_revision,projection_digest)
      values (${sqlString(FARM_ID)}::uuid,${GENERATION},'active',true,false,0,2061,repeat('0',64));`,
    `insert into esheep_cloud.migration_reconciliations (
      farm_id,source_generation,target_generation,status,source_manifest_digest,target_manifest_digest,
      parity_report,parity_digest,v1_final_event_boundary,first_v2_command_id
    ) values (
      ${sqlString(FARM_ID)}::uuid,1,${GENERATION},'shadowing',${sqlString(sourceManifestDigest)},repeat('0',64),
      ${sqlJSON({ all_checks_passed: false, phase: 'real_air_shadow_migration', command_count: commandCount, source: 'iPhone Air backup' })},
      repeat('0',64),2061,${sqlString(firstCommandID)}::uuid
    );`,
  ];
  for (const asset of assets) {
    lines.push(`insert into esheep_cloud.assets (
      asset_id,farm_id,farm_generation,sheep_id,content_sha256,thumbnail_sha256,avatar_sha256,original_sha256,
      metadata,metadata_digest,thumbnail_path,avatar_path,original_path,
      thumbnail_state,avatar_state,original_state,thumbnail_byte_count,avatar_byte_count,original_byte_count,
      uploaded_by
    ) values (
      ${sqlString(asset.assetID)}::uuid,${sqlString(FARM_ID)}::uuid,${GENERATION},
      ${asset.sheepID ? `${sqlString(asset.sheepID)}::uuid` : 'null'},
      ${sqlString(asset.contentSHA256)},${sqlString(asset.thumbnailSHA256)},${sqlString(asset.avatarSHA256)},${sqlString(asset.originalSHA256)},
      ${sqlJSON(asset.metadata)},${sqlString(asset.metadataDigest)},
      ${sqlString(asset.storagePaths.thumbnail)},${sqlString(asset.storagePaths.avatar)},${sqlString(asset.storagePaths.original)},
      'transferring','transferring','transferring',${asset.thumbnailByteCount},${asset.avatarByteCount},${asset.originalByteCount},
      ${sqlString(OWNER_USER_ID)}::uuid
    );`);
  }
  lines.push('commit;');
  return `${lines.join('\n')}\n`;
}

function buildConfirmSQL(assets) {
  const lines = [
    '-- Each call is service-role guarded and checks the Storage object exists.',
    'begin;',
    "select set_config('request.jwt.claim.role','service_role',true);"
  ];
  for (const asset of assets) {
    for (const [variant, hash, bytes] of [
      ['thumbnail', asset.thumbnailSHA256, asset.thumbnailByteCount],
      ['avatar', asset.avatarSHA256, asset.avatarByteCount],
      ['original', asset.originalSHA256, asset.originalByteCount]
    ]) {
      lines.push(`select public.esheep_cloud_confirm_verified_asset_v2(
        ${sqlString(OWNER_USER_ID)}::uuid,${sqlString(FARM_ID)}::uuid,${GENERATION},
        ${sqlString(asset.assetID)}::uuid,${sqlString(variant)},${sqlString(hash)},${bytes}
      ) as verification;`);
    }
  }
  lines.push('commit;');
  return `${lines.join('\n')}\n`;
}

function writeBatches(commands) {
  fs.mkdirSync(BATCH_DIR, { recursive: true });
  const batchSize = 100;
  const paths = [];
  for (let index = 0; index < commands.length; index += batchSize) {
    const slice = commands.slice(index, index + batchSize);
    const json = JSON.stringify(slice.map((command) => ({
      unsigned_command_base64: command.unsignedCommandBase64,
      device_signature_base64: command.deviceSignatureBase64,
      content_digest: command.contentDigest
    })));
    const file = path.join(BATCH_DIR, `batch-${String(index / batchSize + 1).padStart(3, '0')}.sql`);
    const sql = `begin;
select set_config('request.jwt.claim.role','service_role',true);
do $$ declare item jsonb; result jsonb; rejected integer := 0; begin
  for item in select value from jsonb_array_elements(${sqlString(json)}::jsonb)
  loop
    result := esheep_cloud.process_command_v2(${sqlString(FARM_ID)}::uuid,${GENERATION},${sqlString(OWNER_USER_ID)}::uuid,item);
    if result->>'type' not in ('accepted','duplicate') then rejected := rejected + 1; raise exception using message = 'real_migration_command_rejected:' || result::text; end if;
  end loop;
  if rejected <> 0 then raise exception using message = 'real_migration_batch_rejected'; end if;
end $$;
commit;
`;
    fs.writeFileSync(file, sql, { encoding: 'utf8', flag: 'w' });
    paths.push(file);
  }
  return paths;
}

function main() {
  if (!fs.existsSync(AIR_STORE)) die(`Air store not found: ${AIR_STORE}`);
  if (!fs.existsSync(DRAFTS)) die(`typed draft file not found: ${DRAFTS}`);
  fs.rmSync(OUTPUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(ASSET_DIR, { recursive: true });
  const drafts = readJSON(DRAFTS);
  if (drafts.farmID.toLowerCase() !== FARM_ID) die(`draft farm mismatch: ${drafts.farmID}`);
  if (drafts.farmOwnerAccountID.toLowerCase() !== OWNER_ACCOUNT_ID) die(`draft owner account mismatch: ${drafts.farmOwnerAccountID}`);
  const farm = sqliteJSON(`
    select ZNAME as name,hex(ZOWNERACCOUNTID) as owner,ZCREATEDAT as created,ZUPDATEDAT as updated,
      ZLATITUDE as lat,ZLONGITUDE as lon,ZLOCATIONDISPLAYNAME as loc,ZADDRESSSNAPSHOT as address,
      ZTIMEZONEIDENTIFIER as tz,ZLOCATIONSOURCERAWVALUE as source,
      ZHORIZONTALACCURACYMETERS as accuracy,ZLOCATIONUPDATEDAT as locationUpdated
    from ZFARMRECORD where ZDELETEDAT is null
  `)[0];
  if (!farm || uuidFromHex(farm.owner)?.toLowerCase() !== OWNER_ACCOUNT_ID) die('Air farm owner mismatch');
  const assets = buildPhotoAssets();
  const deviceJWK = makeDeviceJWK();
  const built = buildCommands(drafts, assets);
  const sourceManifest = {
    source: 'iPhone Air backup',
    farmID: FARM_ID,
    storeSHA256: sha256File(AIR_STORE),
    baselineDraftCount: drafts.baseline.length,
    specialDraftCount: drafts.special.length,
    commandCount: built.commands.length,
    activeAssetCount: assets.length,
    activeAssetDigests: assets.map((asset) => ({ assetID: asset.assetID, contentSHA256: asset.contentSHA256 })).sort((a, b) => a.assetID.localeCompare(b.assetID)),
    newAvatarRepairTags: NEW_AVATAR_REPAIR_EAR_TAGS,
    newAvatarRepairCount: built.repairAvatarCount,
    historicalArchiveRows: built.historicalArchiveRowCount,
    historicalArchiveActiveRows: built.historicalArchiveActiveRowCount,
    historicalArchiveDeletedRows: built.historicalArchiveDeletedRowCount,
    historicalArchivePatchCount: built.historicalArchivePatchCount
  };
  const sourceManifestDigest = sha256(Buffer.from(stableJSON(sourceManifest), 'utf8'));
  const batchPaths = writeBatches(built.commands);
  const plan = {
    generatedAt: new Date().toISOString(),
    farmID: FARM_ID,
    ownerUserID: OWNER_USER_ID,
    ownerAccountID: OWNER_ACCOUNT_ID,
    sourceDevice: 'iPhone Air',
    sourceStore: AIR_STORE,
    targetGeneration: GENERATION,
    migrationDeviceID: DEVICE_ID,
    migrationDeviceDisplayName: 'Air V2 Migration',
    sourceManifest,
    sourceManifestDigest,
    devicePublicJWK: deviceJWK,
    counts: {
      baselineDrafts: drafts.baseline.length,
      specialDrafts: drafts.special.length,
      commands: built.commands.length,
      activeAssets: assets.length,
      avatarCommands: built.avatarCount,
      newAvatarRepairCommands: built.repairAvatarCount,
      historicalArchivePatchCommands: built.historicalArchivePatchCount,
      commandBatches: batchPaths.length
    },
    farm: {
      name: farm.name,
      ownerAccountID: farm.owner,
      createdAt: dateFromCoreDataSeconds(farm.created),
      updatedAt: dateFromCoreDataSeconds(farm.updated),
      locationUpdatedAt: dateFromCoreDataSeconds(farm.locationUpdated),
      locationDisplayName: farm.loc,
      latitude: farm.lat,
      longitude: farm.lon,
      addressSnapshot: farm.address,
      timeZoneIdentifier: farm.tz,
      locationSource: farm.source,
      horizontalAccuracyMeters: farm.accuracy
    },
    assets: assets.map(({ sourcePath, thumbnailPath, avatarPath, originalPath, ...asset }) => ({
      ...asset,
      localFiles: { sourcePath, thumbnailPath, avatarPath, originalPath }
    })),
    newAvatarRepairs: built.newAvatarRepairs,
    historicalArchivePatches: built.historicalArchivePatches,
    commands: built.commands
  };
  fs.writeFileSync(PLAN_PATH, JSON.stringify(plan, null, 2));
  fs.writeFileSync(SEED_SQL_PATH, buildSeedSQL({
    farm,
    assets,
    sourceManifestDigest,
    deviceJWK,
    commandCount: built.commands.length,
    firstCommandID: built.commands[0]?.commandID
  }));
  fs.writeFileSync(CONFIRM_SQL_PATH, buildConfirmSQL(assets));
  fs.writeFileSync(path.join(OUTPUT_DIR, 'source-manifest.json'), JSON.stringify(sourceManifest, null, 2));
  console.log(JSON.stringify({
    plan: PLAN_PATH,
    seedSQL: SEED_SQL_PATH,
    confirmSQL: CONFIRM_SQL_PATH,
    batchDir: BATCH_DIR,
    sourceManifestDigest,
    counts: plan.counts,
    totalAssetBytes: assets.reduce((sum, asset) => sum + asset.thumbnailByteCount + asset.avatarByteCount + asset.originalByteCount, 0)
  }, null, 2));
}

main();
