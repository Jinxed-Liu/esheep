const DAY_MILLISECONDS = 86_400_000;
const NUTRIENT_KEYS = [
  "dryMatter", "crudeProtein", "crudeFat", "crudeFiber", "ndf", "adf", "ash",
  "lignin", "peNDF", "starch", "sugar", "tdn", "de", "me", "rdp", "rup",
  "ndip", "adip", "solubleProtein", "mpe", "mpn", "digestibleProtein",
  "rumenNitrogenBalance", "lysine", "methionine",
];

const dateFormatterCache = new Map();

function formatterFor(timeZone) {
  const key = timeZone || "Asia/Shanghai";
  if (!dateFormatterCache.has(key)) {
    dateFormatterCache.set(key, new Intl.DateTimeFormat("en-CA", {
      timeZone: key,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }));
  }
  return dateFormatterCache.get(key);
}

export function validDate(value) {
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value;
  if (value == null || value === "") return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

export function normalizeID(value) {
  return String(value ?? "").trim().toLowerCase();
}

export function finiteNumber(value) {
  if (value == null || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function finiteInteger(value) {
  const number = finiteNumber(value);
  return number == null ? null : Math.trunc(number);
}

function dateParts(value, timeZone) {
  const date = validDate(value);
  if (!date) return null;
  const parts = formatterFor(timeZone).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const year = Number(values.year);
  const month = Number(values.month);
  const day = Number(values.day);
  return Number.isFinite(year) && Number.isFinite(month) && Number.isFinite(day)
    ? { year, month, day }
    : null;
}

export function farmDayKey(value, timeZone = "Asia/Shanghai") {
  const parts = dateParts(value, timeZone);
  if (!parts) return null;
  return `${String(parts.year).padStart(4, "0")}-${String(parts.month).padStart(2, "0")}-${String(parts.day).padStart(2, "0")}`;
}

function keyParts(key) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(key ?? ""));
  if (!match) return null;
  return { year: Number(match[1]), month: Number(match[2]), day: Number(match[3]) };
}

function keySerial(key) {
  const parts = keyParts(key);
  return parts ? Date.UTC(parts.year, parts.month - 1, parts.day) / DAY_MILLISECONDS : null;
}

export function addFarmDays(key, count) {
  const serial = keySerial(key);
  if (serial == null) return null;
  const date = new Date((serial + count) * DAY_MILLISECONDS);
  return `${String(date.getUTCFullYear()).padStart(4, "0")}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")}`;
}

export function calendarDayDistance(start, end, timeZone = "Asia/Shanghai") {
  const startSerial = keySerial(farmDayKey(start, timeZone));
  const endSerial = keySerial(farmDayKey(end, timeZone));
  return startSerial == null || endSerial == null ? 0 : endSerial - startSerial;
}

export function zonedStartOfDay(dayKey, timeZone = "Asia/Shanghai") {
  const parts = keyParts(dayKey);
  if (!parts) return null;
  const desired = Date.UTC(parts.year, parts.month - 1, parts.day);
  let guess = desired;
  // Convert a wall-clock midnight into an instant without assuming a fixed UTC offset.
  for (let index = 0; index < 4; index += 1) {
    const actual = dateParts(new Date(guess), timeZone);
    if (!actual) return null;
    const actualAsUTC = Date.UTC(actual.year, actual.month - 1, actual.day);
    const delta = desired - actualAsUTC;
    if (delta === 0) break;
    guess += delta;
  }
  // The day-only correction above can still be off by hours. Use full wall-clock
  // parts for one final fixed-point correction.
  const fullFormatter = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  });
  for (let index = 0; index < 4; index += 1) {
    const values = Object.fromEntries(fullFormatter.formatToParts(new Date(guess)).map((part) => [part.type, part.value]));
    const localAsUTC = Date.UTC(Number(values.year), Number(values.month) - 1, Number(values.day), Number(values.hour), Number(values.minute), Number(values.second));
    const delta = desired - localAsUTC;
    guess += delta;
    if (delta === 0) break;
  }
  return new Date(guess);
}

function monthKey(value, timeZone) {
  return farmDayKey(value, timeZone)?.slice(0, 7) ?? null;
}

function yearKey(value, timeZone) {
  return farmDayKey(value, timeZone)?.slice(0, 4) ?? null;
}

function monthNumber(value, timeZone) {
  return farmDayKey(value, timeZone)?.slice(5, 7) ?? null;
}

function average(values) {
  const usable = values.filter(Number.isFinite);
  return usable.length ? usable.reduce((sum, value) => sum + value, 0) / usable.length : null;
}

function normalizedSex(value) {
  const sex = String(value ?? "").trim().toLowerCase();
  if (["ewe", "female", "母", "母羊"].includes(sex)) return "ewe";
  if (["ram", "male", "公", "公羊"].includes(sex)) return "ram";
  return "unknown";
}

function isActiveStatus(value) {
  return ["active", "在场", "在群"].includes(String(value ?? "").trim().toLowerCase());
}

function normalizedEarTag(value) {
  return String(value ?? "").trim().toLocaleUpperCase("zh-CN").replace(/\s+/g, "");
}

function recordBoundary(records) {
  const dates = records.map((record) => validDate(record.at ?? record.occurredAt)).filter(Boolean).sort((left, right) => left - right);
  return {
    firstAt: dates[0]?.toISOString() ?? null,
    lastAt: dates.at(-1)?.toISOString() ?? null,
    sampleCount: records.length,
  };
}

function sourceSnapshot(source = {}) {
  return {
    sheep: source.sheep ?? [],
    pens: source.pens ?? [],
    weights: source.weights ?? source.weightRecords ?? [],
    weanings: source.weanings ?? source.weaningRecords ?? [],
    reproduction: source.reproduction ?? source.reproductionRecords ?? [],
    removals: source.removals ?? [],
    transfers: source.transfers ?? [],
    batches: source.batches ?? [],
    batchMemberships: source.batchMemberships ?? [],
    feeds: source.feeds ?? source.feedRecords ?? [],
    troughObservations: source.troughObservations ?? [],
    dailyPenCounts: source.dailyPenCounts ?? [],
  };
}

function compareAtRecordedID(left, right) {
  const occurredDifference = (validDate(left.at ?? left.occurredAt)?.getTime() ?? 0) - (validDate(right.at ?? right.occurredAt)?.getTime() ?? 0);
  if (occurredDifference !== 0) return occurredDifference;
  const recordedDifference = (validDate(left.recordedAt)?.getTime() ?? 0) - (validDate(right.recordedAt)?.getTime() ?? 0);
  if (recordedDifference !== 0) return recordedDifference;
  return normalizeID(left.id).localeCompare(normalizeID(right.id));
}

function transferIndex(snapshot) {
  const result = new Map();
  for (const transfer of snapshot.transfers) {
    const key = normalizeID(transfer.sheepID);
    const list = result.get(key) ?? [];
    list.push(transfer);
    result.set(key, list);
  }
  for (const list of result.values()) list.sort(compareAtRecordedID);
  return result;
}

function removalIndex(snapshot) {
  const result = new Map();
  for (const removal of snapshot.removals) {
    const key = normalizeID(removal.sheepID);
    const date = validDate(removal.at ?? removal.occurredAt);
    if (!date) continue;
    const existing = result.get(key);
    if (!existing || date < existing) result.set(key, date);
  }
  return result;
}

function penAt(sheep, instant, transfersBySheep, exclusive = false) {
  const date = validDate(instant);
  if (!date) return sheep.initialPenID ?? null;
  const transfers = transfersBySheep.get(normalizeID(sheep.id)) ?? [];
  let latest = null;
  for (const transfer of transfers) {
    const occurredAt = validDate(transfer.at ?? transfer.occurredAt);
    if (!occurredAt || (exclusive ? occurredAt >= date : occurredAt > date)) break;
    latest = transfer;
  }
  return latest?.toPenID ?? sheep.initialPenID ?? null;
}

function effectiveRemovalAt(sheep, removalsBySheep) {
  const profileRemoval = validDate(sheep.removedAt);
  const eventRemoval = removalsBySheep.get(normalizeID(sheep.id)) ?? null;
  if (profileRemoval && eventRemoval) return profileRemoval < eventRemoval ? profileRemoval : eventRemoval;
  return profileRemoval ?? eventRemoval;
}

function sheepPresentAt(sheep, instant, transfersBySheep, removalsBySheep) {
  const date = validDate(instant);
  const enteredAt = validDate(sheep.enteredAt);
  if (!date || !enteredAt || enteredAt > date) return false;
  const removedAt = effectiveRemovalAt(sheep, removalsBySheep);
  return !removedAt || removedAt > date;
}

function occupiedPenIDsDuringWholeDays(snapshot, start, end, timeZone) {
  const result = new Set();
  if (!(start < end)) return result;
  const transfersBySheep = transferIndex(snapshot);
  const removalsBySheep = removalIndex(snapshot);
  for (const sheep of snapshot.sheep) {
    const status = String(sheep.status ?? "active").toLowerCase();
    const isCurrentlyPresent = sheep.isCurrentlyPresent ?? !["removed", "deceased", "sold", "culled"].includes(status);
    const removedAt = effectiveRemovalAt(sheep, removalsBySheep);
    if (!isCurrentlyPresent && !removedAt) continue;
    const enteredAt = validDate(sheep.enteredAt);
    if (!enteredAt) continue;
    const segmentStart = new Date(Math.max(start.getTime(), enteredAt.getTime()));
    const segmentEnd = new Date(Math.min(end.getTime(), removedAt?.getTime() ?? Number.MAX_SAFE_INTEGER));
    if (!(segmentStart < segmentEnd)) continue;
    const transfers = transfersBySheep.get(normalizeID(sheep.id)) ?? [];
    let currentPenID = penAt(sheep, segmentStart, transfersBySheep);
    let currentStart = segmentStart;
    const groupedTransfers = new Map();
    for (const transfer of transfers) {
      const occurredAt = validDate(transfer.at ?? transfer.occurredAt);
      if (!occurredAt || occurredAt <= segmentStart || occurredAt >= segmentEnd) continue;
      const key = occurredAt.toISOString();
      const values = groupedTransfers.get(key) ?? [];
      values.push(transfer);
      groupedTransfers.set(key, values);
    }
    for (const [key, values] of [...groupedTransfers.entries()].sort(([left], [right]) => left.localeCompare(right))) {
      const transferAt = validDate(key);
      if (transferAt > currentStart && currentPenID) result.add(normalizeID(currentPenID));
      currentPenID = values.at(-1)?.toPenID ?? null;
      currentStart = transferAt;
    }
    if (segmentEnd > currentStart && currentPenID) result.add(normalizeID(currentPenID));
  }

  if (!snapshot.dailyPenCounts.length) return result;
  const startDay = farmDayKey(start, timeZone);
  const endDay = farmDayKey(end, timeZone);
  if (!startDay || !endDay || startDay >= endDay) return result;
  const latestByPenPurposeDay = new Map();
  for (const count of snapshot.dailyPenCounts) {
    const day = farmDayKey(count.date, timeZone);
    const penID = normalizeID(count.penID);
    if (!day || !penID) continue;
    const key = `${penID}|${count.purpose ?? ""}|${day}`;
    const existing = latestByPenPurposeDay.get(key);
    const existingAt = validDate(existing?.rebuiltAt ?? existing?.recordedAt)?.getTime() ?? 0;
    const candidateAt = validDate(count.rebuiltAt ?? count.recordedAt)?.getTime() ?? 0;
    if (!existing || candidateAt > existingAt || (candidateAt === existingAt && normalizeID(count.id) > normalizeID(existing.id))) {
      latestByPenPurposeDay.set(key, { ...count, day, penID });
    }
  }
  const groupedCounts = new Map();
  for (const count of latestByPenPurposeDay.values()) {
    const key = `${count.penID}|${count.purpose ?? ""}`;
    const values = groupedCounts.get(key) ?? [];
    values.push(count);
    groupedCounts.set(key, values);
  }
  for (const values of groupedCounts.values()) {
    values.sort((left, right) => left.day.localeCompare(right.day));
    const baseline = values.filter((count) => count.day <= startDay).at(-1);
    if ((finiteInteger(baseline?.count) ?? 0) > 0 || values.some((count) => count.day > startDay && count.day < endDay && (finiteInteger(count.count) ?? 0) > 0)) {
      result.add(values[0].penID);
    }
  }
  return result;
}

function weightCandidates(snapshot, timeZone) {
  const candidates = [];
  for (const record of snapshot.weights) {
    candidates.push({
      id: record.id,
      sheepID: record.sheepID,
      at: record.at ?? record.occurredAt,
      kilograms: finiteNumber(record.kilograms),
      source: "weighing",
      priority: 0,
    });
  }
  for (const record of snapshot.weanings) {
    candidates.push({
      id: `${record.id}:weight-sample-weaning`,
      sheepID: record.sheepID,
      at: record.at ?? record.occurredAt,
      kilograms: finiteNumber(record.weanWeight),
      source: "weaning",
      priority: 1,
    });
    if (record.birthAt && finiteNumber(record.birthWeight) != null) {
      candidates.push({
        id: `${record.id}:weight-sample-weaning-birth`,
        sheepID: record.sheepID,
        at: record.birthAt,
        kilograms: finiteNumber(record.birthWeight),
        source: "weaningBirth",
        priority: 3,
      });
    }
  }
  for (const record of snapshot.reproduction) {
    if (record.kind !== "lambing") continue;
    for (const [index, child] of (record.offspring ?? []).entries()) {
      if (!child.sheepID || finiteNumber(child.birthWeight) == null) continue;
      candidates.push({
        id: `${child.id ?? `${record.id}:${index}`}:weight-sample-lambing-birth`,
        sheepID: child.sheepID,
        at: record.at ?? record.occurredAt,
        kilograms: finiteNumber(child.birthWeight),
        source: "lambingBirth",
        priority: 2,
      });
    }
  }
  return candidates.filter((sample) => (
    sample.sheepID && validDate(sample.at) && Number.isFinite(sample.kilograms) && sample.kilograms > 0 && farmDayKey(sample.at, timeZone)
  ));
}

/** App's SheepWeightSampleBuilder.dailyCanonical semantics. */
export function dailyCanonicalWeightSamples(source, timeZone = "Asia/Shanghai") {
  const snapshot = sourceSnapshot(source);
  const grouped = new Map();
  for (const sample of weightCandidates(snapshot, timeZone)) {
    const day = farmDayKey(sample.at, timeZone);
    const key = `${normalizeID(sample.sheepID)}|${day}`;
    const current = grouped.get(key);
    const sampleAt = validDate(sample.at)?.getTime() ?? 0;
    const currentAt = validDate(current?.at)?.getTime() ?? 0;
    const preferred = !current ||
      sample.priority < current.priority ||
      (sample.priority === current.priority && sampleAt > currentAt) ||
      (sample.priority === current.priority && sampleAt === currentAt && normalizeID(sample.id) < normalizeID(current.id));
    if (preferred) grouped.set(key, { ...sample, day });
  }
  return [...grouped.values()].sort((left, right) => (
    (validDate(left.at)?.getTime() ?? 0) - (validDate(right.at)?.getTime() ?? 0) ||
    normalizeID(left.sheepID).localeCompare(normalizeID(right.sheepID)) ||
    normalizeID(left.id).localeCompare(normalizeID(right.id))
  ));
}

function weightCutoff(snapshot, now) {
  const dates = snapshot.weights.map((record) => validDate(record.at ?? record.occurredAt)).filter(Boolean);
  return dates.length ? new Date(Math.max(...dates.map((date) => date.getTime()))) : (validDate(now) ?? new Date());
}

function membershipContains(membership, instant) {
  const date = validDate(instant);
  const joinedAt = validDate(membership.joinedAt);
  const leftAt = validDate(membership.leftAt);
  return Boolean(date && joinedAt && joinedAt <= date && (!leftAt || date <= leftAt));
}

export function weightFilterOptions(source, { now = new Date(), timeZone = "Asia/Shanghai" } = {}) {
  const snapshot = sourceSnapshot(source);
  const cutoff = weightCutoff(snapshot, now);
  const transfersBySheep = transferIndex(snapshot);
  const removalsBySheep = removalIndex(snapshot);
  const occupiedPenIDs = new Set(snapshot.sheep.filter((sheep) => (
    sheepPresentAt(sheep, cutoff, transfersBySheep, removalsBySheep)
  )).map((sheep) => normalizeID(penAt(sheep, cutoff, transfersBySheep))).filter(Boolean));
  return {
    cutoff: cutoff.toISOString(),
    cutoffDay: farmDayKey(cutoff, timeZone),
    pens: snapshot.pens.filter((pen) => occupiedPenIDs.has(normalizeID(pen.id))),
    batches: snapshot.batches.filter((batch) => batch.source == null || batch.source === "manual"),
  };
}

export function calculateWeightAnalytics(source, {
  scope = "all",
  penID = null,
  batchID = null,
  cutoff = null,
  now = new Date(),
  timeZone = "Asia/Shanghai",
} = {}) {
  const snapshot = sourceSnapshot(source);
  const snapshotDate = validDate(cutoff) ?? weightCutoff(snapshot, now);
  const removed = new Set(snapshot.removals.filter((item) => {
    const date = validDate(item.at ?? item.occurredAt);
    return date && date <= snapshotDate;
  }).map((item) => normalizeID(item.sheepID)));
  const transfersBySheep = transferIndex(snapshot);
  let eligible = snapshot.sheep;
  let membershipsBySheep = null;
  if (batchID) {
    const memberships = snapshot.batchMemberships.filter((item) => (
      normalizeID(item.batchID) === normalizeID(batchID) && validDate(item.joinedAt) <= snapshotDate
    ));
    membershipsBySheep = new Map();
    for (const membership of memberships) {
      const key = normalizeID(membership.sheepID);
      const list = membershipsBySheep.get(key) ?? [];
      list.push(membership);
      membershipsBySheep.set(key, list);
    }
    eligible = eligible.filter((sheep) => membershipsBySheep.has(normalizeID(sheep.id)));
  } else if (penID) {
    eligible = eligible.filter((sheep) => normalizeID(penAt(sheep, snapshotDate, transfersBySheep)) === normalizeID(penID));
  }
  eligible = eligible.filter((sheep) => {
    const isRemoved = removed.has(normalizeID(sheep.id));
    if (scope === "inHerdOnly") return !isRemoved;
    if (scope === "removedOnly") return isRemoved;
    return true;
  });
  const eligibleIDs = new Set(eligible.map((sheep) => normalizeID(sheep.id)));
  const pointMap = new Map();
  for (const sample of dailyCanonicalWeightSamples(snapshot, timeZone)) {
    const sheepKey = normalizeID(sample.sheepID);
    const at = validDate(sample.at);
    if (!eligibleIDs.has(sheepKey) || !at || at > snapshotDate) continue;
    if (membershipsBySheep && !membershipsBySheep.get(sheepKey)?.some((membership) => membershipContains(membership, at))) continue;
    const list = pointMap.get(sheepKey) ?? [];
    list.push({ date: sample.day, at: zonedStartOfDay(sample.day, timeZone)?.toISOString() ?? sample.at, weight: sample.kilograms, source: sample.source });
    pointMap.set(sheepKey, list);
  }
  const weightsByDate = new Map();
  const adgByDate = new Map();
  const latestWeights = [];
  const latestADGs = [];
  const scatter = [];
  for (const [sheepID, pointsValue] of pointMap) {
    const points = pointsValue.sort((left, right) => left.date.localeCompare(right.date));
    const latest = points.at(-1);
    if (!latest) continue;
    latestWeights.push(latest.weight);
    for (const point of points) {
      const values = weightsByDate.get(point.date) ?? [];
      values.push(point.weight);
      weightsByDate.set(point.date, values);
    }
    for (let index = 1; index < points.length; index += 1) {
      const previous = points[index - 1];
      const current = points[index];
      const days = (keySerial(current.date) ?? 0) - (keySerial(previous.date) ?? 0);
      if (days <= 0) continue;
      const adg = (current.weight - previous.weight) / days;
      const values = adgByDate.get(current.date) ?? [];
      values.push(adg);
      adgByDate.set(current.date, values);
      scatter.push({ sheepID, date: current.date, baselineWeight: previous.weight, adg });
    }
    const first = points[0];
    const days = (keySerial(latest.date) ?? 0) - (keySerial(first.date) ?? 0);
    if (days > 0) latestADGs.push((latest.weight - first.weight) / days);
  }
  const trend = (map) => [...map.entries()].map(([date, values]) => ({
    date,
    value: average(values),
    sampleCount: values.length,
  })).sort((left, right) => left.date.localeCompare(right.date));
  const canonical = dailyCanonicalWeightSamples(snapshot, timeZone).filter((sample) => {
    const at = validDate(sample.at);
    return eligibleIDs.has(normalizeID(sample.sheepID)) && at && at <= snapshotDate &&
      (!membershipsBySheep || membershipsBySheep.get(normalizeID(sample.sheepID))?.some((membership) => membershipContains(membership, at)));
  });
  return {
    sheepIDs: eligible.map((sheep) => sheep.id).sort((left, right) => normalizeID(left).localeCompare(normalizeID(right))),
    canonicalSampleCount: canonical.length,
    sheepSampleCount: pointMap.size,
    latestAverageWeight: average(latestWeights),
    latestAverageADG: average(latestADGs),
    latestAverageWeightSampleCount: latestWeights.length,
    latestAverageADGSampleCount: latestADGs.length,
    weightTrend: trend(weightsByDate),
    adgTrend: trend(adgByDate),
    scatter,
    cutoff: snapshotDate.toISOString(),
    boundary: recordBoundary(canonical),
    // Compatibility aliases used by the overview and older tests.
    latestAverageKg: average(latestWeights),
    latestAverageSampleCount: latestWeights.length,
    averageADGKgPerDay: average(latestADGs),
    adgSampleCount: latestADGs.length,
    trend: trend(weightsByDate),
    intervalADGTrend: trend(adgByDate),
  };
}

function linearRegression(samples) {
  if (samples.length < 2) return null;
  const count = samples.length;
  const sumX = samples.reduce((sum, item) => sum + item[0], 0);
  const sumY = samples.reduce((sum, item) => sum + item[1], 0);
  const sumXY = samples.reduce((sum, item) => sum + item[0] * item[1], 0);
  const sumXX = samples.reduce((sum, item) => sum + item[0] * item[0], 0);
  const denominator = count * sumXX - sumX * sumX;
  if (Math.abs(denominator) <= 0.000001) return null;
  const slope = (count * sumXY - sumX * sumY) / denominator;
  return { slope, intercept: (sumY - slope * sumX) / count };
}

function solveLinearSystem(matrix) {
  if (!matrix.length || matrix.some((row) => row.length !== matrix.length + 1)) return null;
  const values = matrix.map((row) => [...row]);
  for (let pivot = 0; pivot < values.length; pivot += 1) {
    let bestRow = pivot;
    for (let row = pivot; row < values.length; row += 1) {
      if (Math.abs(values[row][pivot]) > Math.abs(values[bestRow][pivot])) bestRow = row;
    }
    if (Math.abs(values[bestRow][pivot]) <= 0.000001) return null;
    if (bestRow !== pivot) [values[pivot], values[bestRow]] = [values[bestRow], values[pivot]];
    const pivotValue = values[pivot][pivot];
    for (let column = pivot; column < values[pivot].length; column += 1) values[pivot][column] /= pivotValue;
    for (let row = 0; row < values.length; row += 1) {
      if (row === pivot) continue;
      const factor = values[row][pivot];
      for (let column = pivot; column < values[row].length; column += 1) values[row][column] -= factor * values[pivot][column];
    }
  }
  return values.map((row) => row.at(-1));
}

function polynomialRegression(points, degree) {
  if (degree < 2 || points.length < degree + 1) return null;
  const order = degree + 1;
  const matrix = Array.from({ length: order }, (_, row) => Array.from({ length: order + 1 }, (_, column) => {
    if (column === order) return points.reduce((sum, point) => sum + point.adg * point.baselineWeight ** row, 0);
    return points.reduce((sum, point) => sum + point.baselineWeight ** (row + column), 0);
  }));
  return solveLinearSystem(matrix);
}

export function calculateWeightTrendline(points, kind = "linear") {
  const requirements = { none: Infinity, linear: 2, logarithmic: 2, exponential: 2, quadratic: 3, cubic: 4, quartic: 5, quintic: 6, sextic: 7 };
  if ((points?.length ?? 0) < (requirements[kind] ?? Infinity)) return [];
  const sorted = [...points].sort((left, right) => left.baselineWeight - right.baselineWeight);
  const minimumX = sorted[0]?.baselineWeight;
  const maximumX = sorted.at(-1)?.baselineWeight;
  if (!(maximumX > minimumX)) return [];
  let model = null;
  if (kind === "linear") model = linearRegression(sorted.map((point) => [point.baselineWeight, point.adg]));
  if (kind === "logarithmic") model = linearRegression(sorted.filter((point) => point.baselineWeight > 0).map((point) => [Math.log(point.baselineWeight), point.adg]));
  if (kind === "exponential") {
    const linear = linearRegression(sorted.filter((point) => point.adg > 0).map((point) => [point.baselineWeight, Math.log(point.adg)]));
    model = linear ? { a: Math.exp(linear.intercept), b: linear.slope } : null;
  }
  const degrees = { quadratic: 2, cubic: 3, quartic: 4, quintic: 5, sextic: 6 };
  if (degrees[kind]) model = polynomialRegression(sorted, degrees[kind]);
  if (!model) return [];
  const result = [];
  for (let step = 0; step <= 24; step += 1) {
    const x = minimumX + (maximumX - minimumX) * step / 24;
    let y = null;
    if (kind === "linear") y = model.slope * x + model.intercept;
    else if (kind === "logarithmic") y = model.slope * Math.log(x) + model.intercept;
    else if (kind === "exponential") y = model.a * Math.exp(model.b * x);
    else y = model.reduce((sum, coefficient, index) => sum + coefficient * x ** index, 0);
    if (Number.isFinite(y)) result.push({ x, y });
  }
  return result;
}

function completeLambing(record) {
  return record.kind === "lambing" && finiteInteger(record.parity) != null && finiteInteger(record.birthDeadCount) != null &&
    Array.isArray(record.offspring) && record.offspring.length === finiteInteger(record.lambCount);
}

function earliestWeaningGainBaseline(record, snapshot, sheepByID, timeZone) {
  const weaningAt = validDate(record.at ?? record.occurredAt);
  const birthAt = validDate(record.birthAt ?? sheepByID.get(normalizeID(record.sheepID))?.birthAt);
  if (!weaningAt) return null;
  const candidates = snapshot.weights.filter((sample) => {
    const at = validDate(sample.at ?? sample.occurredAt);
    const kg = finiteNumber(sample.kilograms);
    return normalizeID(sample.sheepID) === normalizeID(record.sheepID) && at && kg > 0 && at < weaningAt && (!birthAt || at >= birthAt);
  }).sort((left, right) => {
    const difference = (validDate(left.at ?? left.occurredAt)?.getTime() ?? 0) - (validDate(right.at ?? right.occurredAt)?.getTime() ?? 0);
    return difference || normalizeID(left.id).localeCompare(normalizeID(right.id));
  });
  const baseline = candidates[0];
  const weaningWeight = finiteNumber(record.weanWeight);
  const baselineWeight = finiteNumber(baseline?.kilograms);
  if (!baseline || !(weaningWeight > 0) || !(weaningWeight > baselineWeight)) return null;
  const days = calendarDayDistance(baseline.at ?? baseline.occurredAt, weaningAt, timeZone);
  if (days <= 0) return null;
  return {
    baseline,
    intervalDays: days,
    kilogramsPerDay: (weaningWeight - baselineWeight) / days,
    gramsPerDay: (weaningWeight - baselineWeight) / days * 1_000,
  };
}

function emptyLambMonth(month) {
  return {
    month,
    firstParity: 0,
    multiParity: 0,
    totalDams: 0,
    maleLambs: 0,
    femaleLambs: 0,
    totalLambs: 0,
    birthDead: 0,
    avgPerLamb: 0,
    deathRate: 0,
    multiPct: 0,
    disappeared: 0,
    culled: 0,
    sold: 0,
    inHerd: 0,
    maleWeightAverage: 0,
    maleWeightCount: 0,
    femaleWeightAverage: 0,
    femaleWeightCount: 0,
    maleADGAverage: 0,
    maleADGCount: 0,
    femaleADGAverage: 0,
    femaleADGCount: 0,
  };
}

function emptyWeaningMonth(month) {
  return {
    month,
    totalCount: 0,
    abnormalCount: 0,
    otherSexCount: 0,
    ageCount: 0,
    ageDays: 0,
    weightCount: 0,
    weightSum: 0,
    adgCount: 0,
    adgSum: 0,
    maleCount: 0,
    maleAgeCount: 0,
    maleAgeDays: 0,
    maleWeightCount: 0,
    maleWeightSum: 0,
    maleADGCount: 0,
    maleADGSum: 0,
    femaleCount: 0,
    femaleAgeCount: 0,
    femaleAgeDays: 0,
    femaleWeightCount: 0,
    femaleWeightSum: 0,
    femaleADGCount: 0,
    femaleADGSum: 0,
  };
}

export function lambFilterOptions(source, timeZone = "Asia/Shanghai") {
  const snapshot = sourceSnapshot(source);
  return [...new Set([
    ...snapshot.reproduction.filter((record) => record.kind === "lambing").map((record) => yearKey(record.at ?? record.occurredAt, timeZone)),
    ...snapshot.weanings.map((record) => yearKey(record.at ?? record.occurredAt, timeZone)),
  ].filter(Boolean))].sort((left, right) => right.localeCompare(left));
}

export function calculateLambAnalytics(source, {
  selectedYear = null,
  selectedWeaningMonth = "全部",
  timeZone = "Asia/Shanghai",
} = {}) {
  const snapshot = sourceSnapshot(source);
  const sheepByID = new Map(snapshot.sheep.map((sheep) => [normalizeID(sheep.id), sheep]));
  const yearLambings = snapshot.reproduction.filter((record) => record.kind === "lambing" && (!selectedYear || yearKey(record.at ?? record.occurredAt, timeZone) === selectedYear));
  const complete = yearLambings.filter(completeLambing);
  const latestWeaningBySheep = new Map();
  for (const record of snapshot.weanings) {
    const key = normalizeID(record.sheepID);
    const existing = latestWeaningBySheep.get(key);
    if (!existing || validDate(record.at ?? record.occurredAt) > validDate(existing.at ?? existing.occurredAt)) latestWeaningBySheep.set(key, record);
  }
  const months = new Map();
  const tagsByMonth = new Map();
  for (const lambing of complete) {
    const month = monthKey(lambing.at ?? lambing.occurredAt, timeZone);
    if (!month) continue;
    const stats = months.get(month) ?? emptyLambMonth(month);
    if (finiteInteger(lambing.parity) === 1) stats.firstParity += 1;
    else stats.multiParity += 1;
    stats.totalDams += 1;
    stats.totalLambs += finiteInteger(lambing.lambCount) ?? 0;
    stats.birthDead += finiteInteger(lambing.birthDeadCount) ?? 0;
    if ((finiteInteger(lambing.lambCount) ?? 0) >= 2) stats.multiPct += finiteInteger(lambing.lambCount) ?? 0;
    const tags = tagsByMonth.get(month) ?? new Set();
    for (const child of lambing.offspring ?? []) {
      tags.add(normalizedEarTag(child.earTag));
      const sex = normalizedSex(child.sex);
      if (sex === "ram") stats.maleLambs += 1;
      else if (sex === "ewe") stats.femaleLambs += 1;
      const birthWeight = finiteNumber(child.birthWeight);
      if (birthWeight > 0 && sex === "ram") {
        stats.maleWeightCount += 1;
        stats.maleWeightAverage += birthWeight;
      } else if (birthWeight > 0 && sex === "ewe") {
        stats.femaleWeightCount += 1;
        stats.femaleWeightAverage += birthWeight;
      }
      if (!child.sheepID) continue;
      const weaning = latestWeaningBySheep.get(normalizeID(child.sheepID));
      if (!weaning) continue;
      const fallbackBirth = weaning.birthAt ?? sheepByID.get(normalizeID(child.sheepID))?.birthAt ?? lambing.at ?? lambing.occurredAt;
      const gain = earliestWeaningGainBaseline({ ...weaning, birthAt: fallbackBirth }, snapshot, sheepByID, timeZone);
      if (!gain) continue;
      if (sex === "ram") {
        stats.maleADGCount += 1;
        stats.maleADGAverage += gain.gramsPerDay;
      } else if (sex === "ewe") {
        stats.femaleADGCount += 1;
        stats.femaleADGAverage += gain.gramsPerDay;
      }
    }
    tagsByMonth.set(month, tags);
    months.set(month, stats);
  }
  const activeTags = new Set(snapshot.sheep.filter((sheep) => isActiveStatus(sheep.status)).map((sheep) => normalizedEarTag(sheep.earTag)));
  const tagBySheepID = new Map(snapshot.sheep.map((sheep) => [normalizeID(sheep.id), normalizedEarTag(sheep.earTag)]));
  const removalsByTag = new Map();
  for (const removal of snapshot.removals) {
    const tag = tagBySheepID.get(normalizeID(removal.sheepID));
    if (!tag) continue;
    const counts = removalsByTag.get(tag) ?? { disappeared: 0, culled: 0, sold: 0 };
    if (removal.kind === "sold") counts.sold += 1;
    else if (["culled", "deceased"].includes(removal.kind)) counts.culled += 1;
    else if (removal.kind === "transferredOut") counts.disappeared += 1;
    removalsByTag.set(tag, counts);
  }
  for (const [month, stats] of months) {
    stats.multiPct = stats.totalLambs > 0 ? stats.multiPct / stats.totalLambs * 100 : 0;
    stats.avgPerLamb = stats.totalDams > 0 ? stats.totalLambs / stats.totalDams : 0;
    stats.deathRate = stats.totalLambs > 0 ? stats.birthDead / stats.totalLambs : 0;
    if (stats.maleWeightCount) stats.maleWeightAverage /= stats.maleWeightCount;
    if (stats.femaleWeightCount) stats.femaleWeightAverage /= stats.femaleWeightCount;
    if (stats.maleADGCount) stats.maleADGAverage /= stats.maleADGCount;
    if (stats.femaleADGCount) stats.femaleADGAverage /= stats.femaleADGCount;
    for (const tag of tagsByMonth.get(month) ?? []) {
      const counts = removalsByTag.get(tag);
      if (!counts) continue;
      stats.disappeared += counts.disappeared;
      stats.culled += counts.culled;
      stats.sold += counts.sold;
    }
    stats.inHerd = [...(tagsByMonth.get(month) ?? [])].filter((tag) => activeTags.has(tag)).length;
  }
  const lambMonths = [...months.values()].sort((left, right) => right.month.localeCompare(left.month));
  const totalLambs = lambMonths.reduce((sum, item) => sum + item.totalLambs, 0);
  const totalDead = lambMonths.reduce((sum, item) => sum + item.birthDead, 0);
  const totalCull = lambMonths.reduce((sum, item) => sum + item.culled + item.disappeared, 0);

  const weaningMonths = new Map();
  for (const record of snapshot.weanings) {
    if (selectedYear && yearKey(record.at ?? record.occurredAt, timeZone) !== selectedYear) continue;
    if (selectedWeaningMonth !== "全部" && monthNumber(record.at ?? record.occurredAt, timeZone) !== selectedWeaningMonth) continue;
    const month = monthKey(record.at ?? record.occurredAt, timeZone);
    if (!month) continue;
    const stats = weaningMonths.get(month) ?? emptyWeaningMonth(month);
    stats.totalCount += 1;
    const sex = normalizedSex(sheepByID.get(normalizeID(record.sheepID))?.sex);
    if (sex === "ram") stats.maleCount += 1;
    else if (sex === "ewe") stats.femaleCount += 1;
    else stats.otherSexCount += 1;
    const weight = finiteNumber(record.weanWeight);
    const validWeight = weight > 0;
    if (validWeight) {
      stats.weightCount += 1;
      stats.weightSum += weight;
      if (sex === "ram") { stats.maleWeightCount += 1; stats.maleWeightSum += weight; }
      if (sex === "ewe") { stats.femaleWeightCount += 1; stats.femaleWeightSum += weight; }
    }
    const birthAt = record.birthAt ?? sheepByID.get(normalizeID(record.sheepID))?.birthAt;
    const ageDays = birthAt ? calendarDayDistance(birthAt, record.at ?? record.occurredAt, timeZone) : 0;
    const validAge = ageDays > 0;
    if (validAge) {
      stats.ageCount += 1;
      stats.ageDays += ageDays;
      if (sex === "ram") { stats.maleAgeCount += 1; stats.maleAgeDays += ageDays; }
      if (sex === "ewe") { stats.femaleAgeCount += 1; stats.femaleAgeDays += ageDays; }
    }
    const gain = earliestWeaningGainBaseline({ ...record, birthAt }, snapshot, sheepByID, timeZone);
    if (validWeight && gain) {
      stats.adgCount += 1;
      stats.adgSum += gain.gramsPerDay;
      if (sex === "ram") { stats.maleADGCount += 1; stats.maleADGSum += gain.gramsPerDay; }
      if (sex === "ewe") { stats.femaleADGCount += 1; stats.femaleADGSum += gain.gramsPerDay; }
    }
    if (sex === "unknown" || !validWeight || !validAge || !gain) stats.abnormalCount += 1;
    weaningMonths.set(month, stats);
  }
  const normalizedWeaningMonths = [...weaningMonths.values()].sort((left, right) => left.month.localeCompare(right.month)).map((stats) => ({
    ...stats,
    averageAge: stats.ageCount ? stats.ageDays / stats.ageCount : 0,
    averageWeight: stats.weightCount ? stats.weightSum / stats.weightCount : 0,
    averageADG: stats.adgCount ? stats.adgSum / stats.adgCount : 0,
    maleAverageWeight: stats.maleWeightCount ? stats.maleWeightSum / stats.maleWeightCount : 0,
    femaleAverageWeight: stats.femaleWeightCount ? stats.femaleWeightSum / stats.femaleWeightCount : 0,
    maleAverageADG: stats.maleADGCount ? stats.maleADGSum / stats.maleADGCount : 0,
    femaleAverageADG: stats.femaleADGCount ? stats.femaleADGSum / stats.femaleADGCount : 0,
  }));
  const weaningTotal = normalizedWeaningMonths.reduce((sum, item) => sum + item.totalCount, 0);
  const weaningAbnormal = normalizedWeaningMonths.reduce((sum, item) => sum + item.abnormalCount, 0);
  const weaningWeightCount = normalizedWeaningMonths.reduce((sum, item) => sum + item.weightCount, 0);
  const weaningWeightSum = normalizedWeaningMonths.reduce((sum, item) => sum + item.weightSum, 0);
  const weaningADGCount = normalizedWeaningMonths.reduce((sum, item) => sum + item.adgCount, 0);
  const weaningADGSum = normalizedWeaningMonths.reduce((sum, item) => sum + item.adgSum, 0);
  return {
    lambStats: {
      months: lambMonths,
      totalLambs,
      mortalityRate: totalLambs > 0 ? totalDead / totalLambs : 0,
      deathCullRate: totalLambs > totalDead ? totalCull / (totalLambs - totalDead) : 0,
    },
    weaning: {
      months: normalizedWeaningMonths,
      total: weaningTotal,
      abnormalCount: weaningAbnormal,
      averageADG: weaningADGCount ? weaningADGSum / weaningADGCount : 0,
      adgCount: weaningADGCount,
    },
    incompleteLambingCount: yearLambings.length - complete.length,
    allLambingCount: yearLambings.length,
    completeLambingCount: complete.length,
    boundary: recordBoundary([...yearLambings, ...snapshot.weanings.filter((record) => !selectedYear || yearKey(record.at ?? record.occurredAt, timeZone) === selectedYear)]),
    // Compatibility aliases.
    totalBorn: totalLambs,
    liveBorn: totalLambs - totalDead,
    deadBorn: totalDead,
    mortalityRate: totalLambs > 0 ? totalDead / totalLambs : null,
    weaningCount: weaningTotal,
    averageWeaningWeightKg: weaningWeightCount ? weaningWeightSum / weaningWeightCount : null,
    weaningWeightSampleCount: weaningWeightCount,
    averageWeaningADGKgPerDay: weaningADGCount ? weaningADGSum / weaningADGCount / 1_000 : null,
    weaningADGSampleCount: weaningADGCount,
  };
}

export function defaultReproductionFilter({ now = new Date(), timeZone = "Asia/Shanghai" } = {}) {
  const endDate = farmDayKey(now, timeZone);
  const parts = keyParts(endDate);
  const startDate = parts ? `${String(parts.year - 1).padStart(4, "0")}-${String(parts.month).padStart(2, "0")}-${String(parts.day).padStart(2, "0")}` : endDate;
  // Match Calendar.date(byAdding: .year): clamp leap-day rollover.
  const normalizedStart = keyParts(startDate) && new Date(`${startDate}T00:00:00Z`).getUTCDate() === parts?.day
    ? startDate
    : `${String((parts?.year ?? 1971) - 1).padStart(4, "0")}-${String(parts?.month ?? 1).padStart(2, "0")}-${String(Math.min(parts?.day ?? 1, 28)).padStart(2, "0")}`;
  return { startDate: normalizedStart, endDate, penScope: "all", penID: null, breed: null };
}

function normalizeReproductionFilter(filter, defaults) {
  let startDate = keyParts(filter?.startDate) ? filter.startDate : defaults.startDate;
  let endDate = keyParts(filter?.endDate) ? filter.endDate : defaults.endDate;
  if (startDate > endDate) [startDate, endDate] = [endDate, startDate];
  const breed = String(filter?.breed ?? "").trim() || null;
  const penScope = ["all", "pen", "unassigned"].includes(filter?.penScope) ? filter.penScope : "all";
  return { startDate, endDate, penScope, penID: penScope === "pen" ? filter?.penID ?? null : null, breed };
}

function reproductionCohort(snapshot, filter, timeZone) {
  const cutoffKey = addFarmDays(filter.endDate, 1);
  const cutoffExclusive = zonedStartOfDay(cutoffKey, timeZone);
  const removalsBySheep = removalIndex(snapshot);
  const transfersBySheep = transferIndex(snapshot);
  return snapshot.sheep.filter((ewe) => {
    if (normalizedSex(ewe.sex) !== "ewe") return false;
    const enteredAt = validDate(ewe.enteredAt);
    if (!enteredAt || enteredAt >= cutoffExclusive) return false;
    const removedAt = effectiveRemovalAt(ewe, removalsBySheep);
    if (removedAt) {
      if (removedAt < cutoffExclusive) return false;
    } else if (!isActiveStatus(ewe.status)) {
      return false;
    }
    if (filter.breed && ewe.breed !== filter.breed) return false;
    const historicalPen = penAt(ewe, cutoffExclusive, transfersBySheep, true);
    if (filter.penScope === "pen" && normalizeID(historicalPen) !== normalizeID(filter.penID)) return false;
    if (filter.penScope === "unassigned" && historicalPen != null) return false;
    return true;
  });
}

export function reproductionFilterOptions(source, {
  endDate,
  now = new Date(),
  timeZone = "Asia/Shanghai",
} = {}) {
  const snapshot = sourceSnapshot(source);
  const defaults = defaultReproductionFilter({ now, timeZone });
  const filter = normalizeReproductionFilter({ ...defaults, endDate: endDate ?? defaults.endDate }, defaults);
  const cohort = reproductionCohort(snapshot, { ...filter, penScope: "all", penID: null, breed: null }, timeZone);
  const cutoffExclusive = zonedStartOfDay(addFarmDays(filter.endDate, 1), timeZone);
  const transfersBySheep = transferIndex(snapshot);
  const penIDs = new Set();
  let includesUnassigned = false;
  for (const ewe of cohort) {
    const penID = penAt(ewe, cutoffExclusive, transfersBySheep, true);
    if (penID == null) includesUnassigned = true;
    else penIDs.add(normalizeID(penID));
  }
  const pensByID = new Map(snapshot.pens.map((pen) => [normalizeID(pen.id), pen]));
  const breeds = [...new Set(cohort.map((ewe) => String(ewe.breed ?? "").trim()).filter((breed) => breed && breed.toLowerCase() !== "nan"))]
    .sort((left, right) => left.localeCompare(right, "zh-CN"));
  return {
    pens: [...penIDs].map((id) => pensByID.get(id) ?? { id, name: "历史羊舍" }).sort((left, right) => String(left.name).localeCompare(String(right.name), "zh-CN")),
    includesUnassigned,
    breeds,
  };
}

function historyDateKeys(startDate, endDate) {
  const days = Math.max(0, (keySerial(endDate) ?? 0) - (keySerial(startDate) ?? 0));
  const step = Math.max(1, Math.ceil(Math.max(1, days) / 299));
  const result = [];
  let key = startDate;
  while (key <= endDate) {
    result.push(key);
    key = addFarmDays(key, step);
  }
  if (result.at(-1) !== endDate) result.push(endDate);
  return result;
}

export function calculateReproductionAnalytics(source, {
  filter = null,
  now = new Date(),
  timeZone = "Asia/Shanghai",
} = {}) {
  const snapshot = sourceSnapshot(source);
  const defaults = defaultReproductionFilter({ now, timeZone });
  const normalizedFilter = normalizeReproductionFilter(filter ?? defaults, defaults);
  const rangeStart = zonedStartOfDay(normalizedFilter.startDate, timeZone);
  const rangeEndExclusive = zonedStartOfDay(addFarmDays(normalizedFilter.endDate, 1), timeZone);
  const cohort = reproductionCohort(snapshot, normalizedFilter, timeZone);
  const cohortIDs = new Set(cohort.map((ewe) => normalizeID(ewe.id)));
  const cohortLambings = snapshot.reproduction.filter((record) => {
    const at = validDate(record.at ?? record.occurredAt);
    return record.kind === "lambing" && cohortIDs.has(normalizeID(record.eweID)) && at && at >= rangeStart && at < rangeEndExclusive;
  });
  const records = cohortLambings.filter(completeLambing);
  const totalBorn = records.reduce((sum, record) => sum + (finiteInteger(record.lambCount) ?? 0), 0);
  const totalDead = records.reduce((sum, record) => sum + (finiteInteger(record.birthDeadCount) ?? 0), 0);
  const children = records.flatMap((record) => record.offspring ?? []);
  const maleCount = children.filter((child) => normalizedSex(child.sex) === "ram").length;
  const femaleCount = children.filter((child) => normalizedSex(child.sex) === "ewe").length;
  const birthWeights = children.map((child) => finiteNumber(child.birthWeight)).filter((weight) => weight > 0);
  const monthlyGroups = new Map();
  for (const record of records) {
    const month = monthKey(record.at ?? record.occurredAt, timeZone);
    if (!month) continue;
    const group = monthlyGroups.get(month) ?? [];
    group.push(record);
    monthlyGroups.set(month, group);
  }
  const monthly = [...monthlyGroups.entries()].map(([month, group]) => {
    const lambs = group.flatMap((record) => record.offspring ?? []);
    return {
      month,
      lambings: group.length,
      total: lambs.length,
      male: lambs.filter((child) => normalizedSex(child.sex) === "ram").length,
      female: lambs.filter((child) => normalizedSex(child.sex) === "ewe").length,
    };
  }).sort((left, right) => left.month.localeCompare(right.month));

  const byDam = new Map();
  for (const record of snapshot.reproduction) {
    if (record.kind !== "lambing" || !cohortIDs.has(normalizeID(record.eweID))) continue;
    const at = validDate(record.at ?? record.occurredAt);
    if (!at) continue;
    const key = normalizeID(record.eweID);
    const dates = byDam.get(key) ?? [];
    dates.push(at);
    byDam.set(key, dates);
  }
  for (const dates of byDam.values()) dates.sort((left, right) => left - right);
  const intervals = new Map();
  for (const [eweID, dates] of byDam) {
    const values = [];
    for (let index = 1; index < dates.length; index += 1) {
      const days = calendarDayDistance(dates[index - 1], dates[index], timeZone);
      if (days > 0 && days < 1_000) values.push({ at: dates[index], days });
    }
    intervals.set(eweID, values);
  }
  const historyKeys = historyDateKeys(normalizedFilter.startDate, normalizedFilter.endDate);
  const intervalPoints = [];
  const postpartumPoints = [];
  for (const dateKey of historyKeys) {
    const date = zonedStartOfDay(dateKey, timeZone);
    const cutoffExclusive = zonedStartOfDay(addFarmDays(dateKey, 1), timeZone);
    const intervalValues = [];
    const postpartumValues = [];
    for (const ewe of cohort) {
      const enteredAt = validDate(ewe.enteredAt);
      const birthAt = validDate(ewe.birthAt);
      if (!enteredAt || enteredAt >= cutoffExclusive || (birthAt && birthAt >= cutoffExclusive)) continue;
      const latestInterval = (intervals.get(normalizeID(ewe.id)) ?? []).filter((item) => item.at < cutoffExclusive).at(-1);
      if (latestInterval) intervalValues.push(latestInterval.days);
      const latestBirth = (byDam.get(normalizeID(ewe.id)) ?? []).filter((birth) => birth < cutoffExclusive).at(-1);
      if (latestBirth) {
        const days = calendarDayDistance(latestBirth, date, timeZone);
        if (days >= 0 && days < 1_000) postpartumValues.push(days);
      }
    }
    if (intervalValues.length) intervalPoints.push({ date: dateKey, average: average(intervalValues), count: intervalValues.length });
    if (postpartumValues.length) postpartumPoints.push({ date: dateKey, average: average(postpartumValues), count: postpartumValues.length });
  }
  const monthlyPointGroups = new Map();
  for (const point of intervalPoints) {
    const month = point.date.slice(0, 7);
    const group = monthlyPointGroups.get(month) ?? [];
    group.push(point);
    monthlyPointGroups.set(month, group);
  }
  const qualifiedRates = [...monthlyPointGroups.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([month, points]) => {
    const point = [...points].sort((left, right) => Math.abs(Number(left.date.slice(8)) - 15) - Math.abs(Number(right.date.slice(8)) - 15))[0];
    const cutoffExclusive = zonedStartOfDay(addFarmDays(point.date, 1), timeZone);
    let qualified = 0;
    let unqualified = 0;
    for (const ewe of cohort) {
      const enteredAt = validDate(ewe.enteredAt);
      const birthAt = validDate(ewe.birthAt);
      if (!enteredAt || enteredAt >= cutoffExclusive || (birthAt && birthAt >= cutoffExclusive)) continue;
      const latest = (intervals.get(normalizeID(ewe.id)) ?? []).filter((item) => item.at < cutoffExclusive).at(-1);
      if (!latest) continue;
      if (latest.days >= 150 && latest.days <= 240) qualified += 1;
      else unqualified += 1;
    }
    const total = qualified + unqualified;
    return total ? { month, qualified: qualified * 100 / total, unqualified: unqualified * 100 / total, sampleCount: total } : null;
  }).filter(Boolean);
  const breedGroups = new Map();
  for (const ewe of cohort) {
    const breed = String(ewe.breed ?? "").trim();
    if (!breed || breed.toLowerCase() === "nan") continue;
    const group = breedGroups.get(breed) ?? [];
    group.push(ewe);
    breedGroups.set(breed, group);
  }
  const breedRows = [...breedGroups.entries()].map(([breed, ewes]) => {
    const eweIDs = new Set(ewes.map((ewe) => normalizeID(ewe.id)));
    const lambings = records.filter((record) => eweIDs.has(normalizeID(record.eweID)));
    const lambTotal = lambings.reduce((sum, record) => sum + (record.offspring ?? []).length, 0);
    return { breed, sheepCount: ewes.length, lambingCount: lambings.length, averageLambs: lambings.length ? lambTotal / lambings.length : 0 };
  }).sort((left, right) => right.lambingCount - left.lambingCount || right.sheepCount - left.sheepCount);
  return {
    filter: normalizedFilter,
    overview: {
      averageTotal: records.length ? totalBorn / records.length : 0,
      averageMale: records.length ? maleCount / records.length : 0,
      averageFemale: records.length ? femaleCount / records.length : 0,
      mortalityRate: totalBorn > 0 ? totalDead / totalBorn : 0,
      averageBirthWeight: birthWeights.length ? average(birthWeights) : 0,
    },
    monthly,
    maleCount,
    femaleCount,
    intervalPoints,
    postpartumPoints,
    qualifiedRates,
    breedRows,
    incompleteLambingCount: cohortLambings.length - records.length,
    cohortCount: cohort.length,
    recordCount: snapshot.reproduction.length,
    completeLambingCount: records.length,
    boundary: recordBoundary(cohortLambings),
    recent: [...snapshot.reproduction].sort((left, right) => (validDate(right.at ?? right.occurredAt)?.getTime() ?? 0) - (validDate(left.at ?? left.occurredAt)?.getTime() ?? 0)).slice(0, 8),
    averageLitterSize: records.length ? totalBorn / records.length : null,
    litterSampleCount: records.length,
    averageLambingIntervalDays: intervalPoints.at(-1)?.average ?? null,
    lambingIntervalSampleCount: intervalPoints.at(-1)?.count ?? 0,
    averagePostpartumDays: postpartumPoints.at(-1)?.average ?? null,
    postpartumSampleCount: postpartumPoints.at(-1)?.count ?? 0,
  };
}

function decodedJSON(value, fallback = {}) {
  if (value && typeof value === "object") return value;
  if (typeof value !== "string" || !value.trim()) return fallback;
  try {
    const result = JSON.parse(value);
    return result && typeof result === "object" ? result : fallback;
  } catch {
    return fallback;
  }
}

function nutrientNumber(object, keys) {
  for (const key of keys) {
    const value = finiteNumber(object?.[key]);
    if (value != null) return value;
  }
  return null;
}

export function decodeFeedNutrients(value, dryMatterText = null) {
  const object = decodedJSON(value, {});
  const nutrients = {
    dryMatter: nutrientNumber(object, ["dryMatter", "dm", "DM"]),
    crudeProtein: nutrientNumber(object, ["crudeProtein", "cp", "CP"]),
    crudeFat: nutrientNumber(object, ["crudeFat", "ee", "EE", "fat"]),
    crudeFiber: nutrientNumber(object, ["crudeFiber", "cf", "CF", "fiber"]),
    ndf: nutrientNumber(object, ["ndf", "NDF"]),
    adf: nutrientNumber(object, ["adf", "ADF"]),
    ash: nutrientNumber(object, ["ash", "Ash", "ASH"]),
    lignin: nutrientNumber(object, ["lignin"]),
    peNDF: nutrientNumber(object, ["peNDF"]),
    starch: nutrientNumber(object, ["starch", "Starch"]),
    sugar: nutrientNumber(object, ["sugar", "Sugar"]),
    tdn: nutrientNumber(object, ["tdn", "TDN"]),
    de: nutrientNumber(object, ["de", "DE"]),
    me: nutrientNumber(object, ["me", "ME"]),
    rdp: nutrientNumber(object, ["rdp", "RDP"]),
    rup: nutrientNumber(object, ["rup", "RUP"]),
    ndip: nutrientNumber(object, ["ndip", "NDIP"]),
    adip: nutrientNumber(object, ["adip", "ADIP"]),
    solubleProtein: nutrientNumber(object, ["solubleProtein"]),
    mpe: nutrientNumber(object, ["mpe"]),
    mpn: nutrientNumber(object, ["mpn"]),
    digestibleProtein: nutrientNumber(object, ["digestibleProtein"]),
    rumenNitrogenBalance: nutrientNumber(object, ["rumenNitrogenBalance"]),
    lysine: nutrientNumber(object, ["lysine"]),
    methionine: nutrientNumber(object, ["methionine"]),
    extra: object.extra && typeof object.extra === "object"
      ? Object.fromEntries(Object.entries(object.extra).map(([key, item]) => [key, finiteNumber(item)]).filter(([, item]) => item != null))
      : null,
  };
  if (nutrients.dryMatter == null) nutrients.dryMatter = finiteNumber(dryMatterText);
  return nutrients;
}

function fillEnergyValues(nutrients) {
  const result = { ...nutrients };
  const inferred = new Set();
  const missing = (value) => value == null || value <= 0.05;
  const positive = (value) => value != null && value > 0 ? value : null;
  const tdnToDE = 0.04409;
  const meToDERatio = 0.82;
  if (missing(result.tdn) && result.de != null) { result.tdn = result.de / tdnToDE; inferred.add("tdn"); }
  if (missing(result.de) && positive(result.tdn) != null) { result.de = result.tdn * tdnToDE; inferred.add("de"); }
  if (missing(result.me) && positive(result.de) != null) { result.me = result.de * meToDERatio; inferred.add("me"); }
  if (missing(result.de) && positive(result.me) != null) { result.de = result.me / meToDERatio; inferred.add("de"); }
  if (missing(result.tdn) && positive(result.de) != null) { result.tdn = result.de / tdnToDE; inferred.add("tdn"); }
  return { nutrients: result, inferred };
}

function nutritionSummary(components) {
  const usable = components.map((component) => ({
    ...component,
    freshKilograms: Math.max(0, finiteNumber(component.freshKilograms) ?? 0),
    nutrients: component.nutrients ?? decodeFeedNutrients(null),
  }));
  const asFedKilograms = usable.reduce((sum, component) => sum + component.freshKilograms, 0);
  const dmValues = usable.flatMap((component) => component.nutrients.dryMatter == null ? [] : [{
    kilograms: component.freshKilograms * component.nutrients.dryMatter / 100,
    component,
  }]);
  const dryMatterKilograms = dmValues.length === usable.length ? dmValues.reduce((sum, item) => sum + item.kilograms, 0) : null;
  const costValues = usable.flatMap((component) => component.pricePerKilogram == null ? [] : [component.freshKilograms * component.pricePerKilogram]);
  const cost = costValues.length === usable.length ? costValues.reduce((sum, value) => sum + value, 0) : null;
  const denominator = dmValues.reduce((sum, item) => sum + item.kilograms, 0);
  const nutrients = Object.fromEntries(NUTRIENT_KEYS.map((key) => [key, null]));
  nutrients.dryMatter = asFedKilograms > 0 && dryMatterKilograms != null ? dryMatterKilograms / asFedKilograms * 100 : null;
  nutrients.extra = null;
  const coverage = {};
  for (const key of NUTRIENT_KEYS.slice(1)) {
    const filled = usable.map((component) => ({ component, ...fillEnergyValues(component.nutrients) }));
    const known = [];
    for (const item of filled) {
      const dm = item.component.nutrients.dryMatter;
      const value = item.nutrients[key];
      if (dm == null || value == null) continue;
      const componentDM = item.component.freshKilograms * dm / 100;
      known.push({
        contribution: componentDM * value,
        dryMatter: componentDM,
        name: item.component.name,
        inferred: item.inferred.has(key),
      });
    }
    const coveredDM = known.reduce((sum, item) => sum + item.dryMatter, 0);
    const ratio = denominator > 0 ? Math.min(1, coveredDM / denominator) : 0;
    const missingIngredientNames = usable.filter((component) => (
      component.nutrients.dryMatter == null || fillEnergyValues(component.nutrients).nutrients[key] == null
    )).map((component) => component.name);
    nutrients[key] = denominator > 0 && ratio >= 0.999999
      ? known.reduce((sum, item) => sum + item.contribution, 0) / denominator
      : null;
    coverage[key] = { coverage: ratio, missingIngredientNames, inferred: known.some((item) => item.inferred), isComplete: ratio >= 0.999999 };
  }
  const extraKeys = new Set(usable.flatMap((component) => Object.keys(component.nutrients.extra ?? {})));
  const extra = {};
  const extraCoverage = {};
  for (const key of extraKeys) {
    const known = usable.flatMap((component) => {
      const dm = component.nutrients.dryMatter;
      const value = component.nutrients.extra?.[key];
      if (dm == null || value == null) return [];
      const componentDM = component.freshKilograms * dm / 100;
      return [{ contribution: componentDM * value, dryMatter: componentDM, name: component.name }];
    });
    const coveredDM = known.reduce((sum, item) => sum + item.dryMatter, 0);
    const ratio = denominator > 0 ? Math.min(1, coveredDM / denominator) : 0;
    if (denominator > 0 && ratio >= 0.999999) extra[key] = known.reduce((sum, item) => sum + item.contribution, 0) / denominator;
    extraCoverage[key] = {
      coverage: ratio,
      missingIngredientNames: usable.filter((component) => component.nutrients.dryMatter == null || component.nutrients.extra?.[key] == null).map((component) => component.name),
      inferred: false,
      isComplete: ratio >= 0.999999,
    };
  }
  nutrients.extra = Object.keys(extra).length ? extra : null;
  return {
    asFedKilograms,
    dryMatterKilograms,
    cost,
    nutrients,
    coverage,
    extraCoverage,
    dryMatterPercent: asFedKilograms > 0 && dryMatterKilograms != null ? dryMatterKilograms / asFedKilograms * 100 : null,
    meMJ: dryMatterKilograms != null && nutrients.me != null && coverage.me?.isComplete ? dryMatterKilograms * nutrients.me * 4.184 : null,
    crudeProteinKilograms: dryMatterKilograms != null && nutrients.crudeProtein != null && coverage.crudeProtein?.isComplete ? dryMatterKilograms * nutrients.crudeProtein / 100 : null,
    ndfKilograms: dryMatterKilograms != null && nutrients.ndf != null && coverage.ndf?.isComplete ? dryMatterKilograms * nutrients.ndf / 100 : null,
    adfKilograms: dryMatterKilograms != null && nutrients.adf != null && coverage.adf?.isComplete ? dryMatterKilograms * nutrients.adf / 100 : null,
  };
}

function componentKey(value) {
  const nutrients = JSON.stringify(value.nutrients ?? {}, Object.keys(value.nutrients ?? {}).sort());
  return `${normalizeID(value.ingredientID) || "unknown"}|${normalizeID(value.ingredientBatchID) || "none"}|${value.name}|${nutrients}|${value.pricePerKilogram ?? "nil"}`;
}

function mergeComponents(values) {
  const grouped = new Map();
  for (const value of values) {
    const freshKilograms = finiteNumber(value.freshKilograms) ?? 0;
    if (freshKilograms <= 0.000001) continue;
    const normalized = { ...value, freshKilograms };
    const key = componentKey(normalized);
    const existing = grouped.get(key);
    if (existing) existing.freshKilograms += freshKilograms;
    else grouped.set(key, normalized);
  }
  return [...grouped.values()];
}

function feedLineComponent(line) {
  return {
    ingredientID: line.ingredientID ?? null,
    ingredientBatchID: line.ingredientBatchID ?? null,
    name: line.ingredientName ?? line.name ?? "未知原料",
    freshKilograms: Math.max(0, finiteNumber(line.freshKilograms ?? line.kilograms) ?? 0),
    pricePerKilogram: finiteNumber(line.pricePerKilogram),
    nutrients: line.nutrients ?? decodeFeedNutrients(line.nutrientSnapshotJSON, line.dryMatterTextSnapshot),
  };
}

function compositionComponent(item) {
  return {
    ingredientID: item.ingredientID ?? null,
    ingredientBatchID: item.ingredientBatchID ?? null,
    name: item.ingredientNameSnapshot ?? item.ingredientName ?? "未知原料",
    freshKilograms: Math.max(0, finiteNumber(item.freshKilograms ?? item.kilogramsText) ?? 0),
    pricePerKilogram: null,
    nutrients: item.nutrients ?? decodeFeedNutrients(item.nutrientSnapshotJSON, item.dryMatterTextSnapshot),
  };
}

function componentsForRemainder(quantity, explicit, available) {
  if (explicit?.length) return explicit.map(compositionComponent);
  const total = available.reduce((sum, item) => sum + Math.max(0, item.freshKilograms), 0);
  if (!(quantity > 0) || !(total > 0)) return [];
  return available.map((item) => ({ ...item, freshKilograms: quantity * Math.max(0, item.freshKilograms) / total }));
}

function subtractComponents(residual, available) {
  for (const item of residual) {
    if (!(item.freshKilograms > 0)) continue;
    let remaining = item.freshKilograms;
    const matching = available.filter((candidate) => {
      if (item.ingredientBatchID) return normalizeID(candidate.ingredientBatchID) === normalizeID(item.ingredientBatchID);
      if (item.ingredientID) return normalizeID(candidate.ingredientID) === normalizeID(item.ingredientID);
      return candidate.name === item.name;
    });
    for (const candidate of matching) {
      if (remaining <= 0) break;
      const deduction = Math.min(remaining, Math.max(0, candidate.freshKilograms));
      candidate.freshKilograms -= deduction;
      remaining -= deduction;
    }
    if (remaining > 0.000001) return false;
  }
  for (let index = available.length - 1; index >= 0; index -= 1) {
    if (available[index].freshKilograms <= 0.000001) available.splice(index, 1);
  }
  return true;
}

function mergeIntervals(values) {
  const ordered = values.filter(({ start, end }) => start < end).sort((left, right) => left.start - right.start);
  if (!ordered.length) return [];
  const result = [];
  let current = { ...ordered[0] };
  for (const value of ordered.slice(1)) {
    if (value.start <= current.end) current.end = new Date(Math.max(current.end, value.end));
    else { result.push(current); current = { ...value }; }
  }
  result.push(current);
  return result;
}

function normalizedFeeder(value) {
  const text = String(value ?? "").trim();
  return text ? text.toLocaleLowerCase("zh-CN") : "圈舍整体";
}

function feedStage(sheep) {
  const purpose = String(sheep.purpose ?? sheep.stage ?? "").trim();
  const sex = normalizedSex(sheep.sex);
  if (purpose.includes("哺乳")) return "lactatingLamb";
  if (purpose.includes("断奶") && purpose.includes("羔")) return "weanedLamb";
  if (purpose.includes("后备")) return "replacement";
  if (purpose.includes("育成")) return "growing";
  if (purpose.includes("育肥")) return "fattening";
  if (purpose.includes("种公") || (sex === "ram" && sheep.isBreedingRam)) return "breedingRam";
  if (purpose.includes("繁殖") && (purpose.includes("母") || sex === "ewe")) return "breedingEwe";
  return "unknown";
}

function makePresenceIndex(snapshot, { timeZone }) {
  const transfersBySheep = transferIndex(snapshot);
  const removalsBySheep = removalIndex(snapshot);
  const countsByPen = new Map();
  for (const count of snapshot.dailyPenCounts) {
    const key = normalizeID(count.penID);
    const list = countsByPen.get(key) ?? [];
    list.push(count);
    countsByPen.set(key, list);
  }
  function sheepInPen(penID, instant) {
    return snapshot.sheep.filter((sheep) => (
      sheepPresentAt(sheep, instant, transfersBySheep, removalsBySheep) && normalizeID(penAt(sheep, instant, transfersBySheep)) === normalizeID(penID)
    ));
  }
  function identitySheepDays(penID, start, end, excluded) {
    let total = 0;
    const stageDays = new Map();
    let hasIdentityEvidence = false;
    for (const sheep of snapshot.sheep) {
      if (excluded.has(normalizeID(sheep.id))) continue;
      const boundaries = new Set([start.getTime(), end.getTime()]);
      const enteredAt = validDate(sheep.enteredAt);
      const removedAt = effectiveRemovalAt(sheep, removalsBySheep);
      if (enteredAt > start && enteredAt < end) boundaries.add(enteredAt.getTime());
      if (removedAt > start && removedAt < end) boundaries.add(removedAt.getTime());
      for (const transfer of transfersBySheep.get(normalizeID(sheep.id)) ?? []) {
        const at = validDate(transfer.at ?? transfer.occurredAt);
        if (at > start && at < end) boundaries.add(at.getTime());
      }
      const ordered = [...boundaries].sort((left, right) => left - right).map((value) => new Date(value));
      for (let index = 1; index < ordered.length; index += 1) {
        const segmentStart = ordered[index - 1];
        const segmentEnd = ordered[index];
        if (!(segmentStart < segmentEnd) || !sheepPresentAt(sheep, segmentStart, transfersBySheep, removalsBySheep) || normalizeID(penAt(sheep, segmentStart, transfersBySheep)) !== normalizeID(penID)) continue;
        const days = (segmentEnd - segmentStart) / DAY_MILLISECONDS;
        total += days;
        const stage = feedStage(sheep);
        stageDays.set(stage, (stageDays.get(stage) ?? 0) + days);
        hasIdentityEvidence = true;
      }
    }
    return { total, stageDays, hasIdentityEvidence };
  }
  function snapshotCount(penID, dayKey) {
    const rows = countsByPen.get(normalizeID(penID)) ?? [];
    const purposes = new Set(rows.map((row) => row.purpose));
    if (!purposes.size) return null;
    let found = false;
    let total = 0;
    for (const purpose of purposes) {
      const candidate = rows.filter((row) => row.purpose === purpose && farmDayKey(row.date, timeZone) <= dayKey)
        .sort((left, right) => farmDayKey(left.date, timeZone).localeCompare(farmDayKey(right.date, timeZone))).at(-1);
      if (candidate) { found = true; total += finiteInteger(candidate.count) ?? 0; }
    }
    return found ? total : null;
  }
  function sheepDays(penID, start, end, excludedIDs = new Set()) {
    if (!(start < end)) return { total: 0, stageDays: new Map(), evidence: new Set(), conflicts: [] };
    const excluded = new Set([...excludedIDs].map(normalizeID));
    let dayKey = farmDayKey(start, timeZone);
    let total = 0;
    const stageDays = new Map();
    const evidence = new Set();
    const conflicts = [];
    while (zonedStartOfDay(dayKey, timeZone) < end) {
      const nextKey = addFarmDays(dayKey, 1);
      const day = zonedStartOfDay(dayKey, timeZone);
      const nextDay = zonedStartOfDay(nextKey, timeZone);
      const segmentStart = new Date(Math.max(day, start));
      const segmentEnd = new Date(Math.min(nextDay, end));
      if (segmentStart < segmentEnd) {
        const exact = identitySheepDays(penID, segmentStart, segmentEnd, excluded);
        const snapshotValue = snapshotCount(penID, dayKey);
        if (snapshotValue != null) {
          const endOfDay = new Date(nextDay.getTime() - 1);
          const endSheep = sheepInPen(penID, endOfDay);
          const identityEnd = endSheep.filter((sheep) => !excluded.has(normalizeID(sheep.id))).length;
          const excludedEnd = endSheep.filter((sheep) => excluded.has(normalizeID(sheep.id))).length;
          const authoritativeEnd = Math.max(0, snapshotValue - excludedEnd);
          if (identityEnd === authoritativeEnd) total += exact.total;
          else {
            const duration = (segmentEnd - segmentStart) / DAY_MILLISECONDS;
            total += Math.max(0, exact.total + (authoritativeEnd - identityEnd) * duration);
            evidence.add("conflict");
            evidence.add("historicalHeadCount");
            conflicts.push(`${dayKey} 快照人数${authoritativeEnd}与事件人数${identityEnd}不一致`);
          }
          for (const [stage, value] of exact.stageDays) stageDays.set(stage, (stageDays.get(stage) ?? 0) + value);
        } else if (exact.hasIdentityEvidence) {
          total += exact.total;
          for (const [stage, value] of exact.stageDays) stageDays.set(stage, (stageDays.get(stage) ?? 0) + value);
        } else {
          evidence.add("historicalHeadCount");
        }
      }
      dayKey = nextKey;
    }
    return { total, stageDays, evidence, conflicts };
  }
  return { sheepInPen, sheepDays };
}

function limitedSlices(snapshot, input, feeds) {
  const observations = snapshot.troughObservations.filter((item) => {
    const at = validDate(item.observedAt ?? item.at);
    return at && at >= input.start && at < input.end;
  });
  const grouped = new Map();
  for (const feed of feeds) {
    const day = farmDayKey(feed.at ?? feed.occurredAt, input.timeZone);
    const key = `${normalizeID(feed.penID)}|${day}`;
    const group = grouped.get(key) ?? { penID: feed.penID, day, feeds: [] };
    group.feeds.push(feed);
    grouped.set(key, group);
  }
  const result = [];
  for (const group of [...grouped.values()].sort((left, right) => left.day.localeCompare(right.day) || normalizeID(left.penID).localeCompare(normalizeID(right.penID)))) {
    const dayStart = zonedStartOfDay(group.day, input.timeZone);
    const nextDay = zonedStartOfDay(addFarmDays(group.day, 1), input.timeZone);
    let components = group.feeds.flatMap((feed) => (feed.lines ?? []).map(feedLineComponent));
    const feedIDs = new Set(group.feeds.map((feed) => normalizeID(feed.id)));
    let matched = observations.filter((observation) => {
      const at = validDate(observation.observedAt ?? observation.at);
      return normalizeID(observation.penID) === normalizeID(group.penID) && at >= dayStart && at < nextDay && observation.relatedFeedRecordID && feedIDs.has(normalizeID(observation.relatedFeedRecordID));
    });
    if (!matched.length) {
      const feederNames = new Set(group.feeds.map((feed) => normalizedFeeder(feed.feederName)));
      matched = observations.filter((observation) => {
        const at = validDate(observation.observedAt ?? observation.at);
        return normalizeID(observation.penID) === normalizeID(group.penID) && !observation.relatedFeedRecordID && at >= dayStart && at < nextDay && feederNames.has(normalizedFeeder(observation.feederName));
      });
      if (matched.length > 1) matched = [matched.sort((left, right) => validDate(right.observedAt ?? right.at) - validDate(left.observedAt ?? left.at))[0]];
    }
    const evidence = new Set();
    const conflicts = [];
    let remainders = [];
    if (matched.length) {
      evidence.add("measured");
      remainders = matched.map((observation) => {
        if (observation.measurementMethod !== "weighed" && observation.measurementMethod !== "实称") evidence.add("estimated");
        return { quantity: finiteNumber(observation.actualRemainingKilograms) ?? 0, composition: observation.composition ?? [] };
      });
    } else {
      evidence.add("estimated");
      remainders = group.feeds.filter((feed) => finiteNumber(feed.legacyRemainingKilograms) != null).map((feed) => ({
        quantity: finiteNumber(feed.legacyRemainingKilograms),
        composition: feed.legacyRemainingComposition ?? [],
      }));
    }
    for (const remainder of remainders) {
      const totalAvailable = components.reduce((sum, component) => sum + component.freshKilograms, 0);
      if (remainder.quantity > totalAvailable + 0.000001) {
        conflicts.push(`${group.day} 盘槽剩余量大于投料量`);
        evidence.add("conflict");
        continue;
      }
      const residual = componentsForRemainder(remainder.quantity, remainder.composition, components);
      if (!subtractComponents(residual, components)) {
        conflicts.push(`${group.day} 剩料组成与投料组成不一致`);
        evidence.add("conflict");
      }
    }
    if (evidence.has("conflict")) components = [];
    result.push({
      penID: group.penID,
      start: new Date(Math.max(input.start, dayStart)),
      end: new Date(Math.min(input.end, nextDay)),
      reportDate: group.day,
      components: mergeComponents(components),
      excludedSheepIDs: new Set(group.feeds.flatMap((feed) => feed.excludedSheepIDs ?? []).map(normalizeID)),
      historicalHeadCount: Math.max(...group.feeds.map((feed) => finiteInteger(feed.historicalHeadCountSnapshot)).filter((value) => value != null), -Infinity),
      evidence,
      conflicts,
    });
  }
  for (const slice of result) if (slice.historicalHeadCount === -Infinity) slice.historicalHeadCount = null;
  return result;
}

function openingComponents(observation, remainingAfterDiscard) {
  if (observation.composition?.length && finiteNumber(observation.actualRemainingKilograms) > 0) {
    const factor = remainingAfterDiscard / finiteNumber(observation.actualRemainingKilograms);
    return observation.composition.map((item) => {
      const component = compositionComponent(item);
      component.freshKilograms = Math.max(0, component.freshKilograms * factor);
      return component;
    });
  }
  return remainingAfterDiscard > 0 ? [{
    ingredientID: null,
    ingredientBatchID: null,
    name: "未记录料槽原料组成",
    freshKilograms: remainingAfterDiscard,
    pricePerKilogram: null,
    nutrients: decodeFeedNutrients(null),
  }] : [];
}

function freeChoiceSlices(snapshot, input, feeds) {
  const result = { slices: [], incompleteCountByPen: new Map(), incompletePenIDs: new Set() };
  const freeFeedIDs = new Set(feeds.map((feed) => normalizeID(feed.id)));
  const observations = snapshot.troughObservations.filter((observation) => {
    const at = validDate(observation.observedAt ?? observation.at);
    return at && at <= input.end && (!observation.relatedFeedRecordID || freeFeedIDs.has(normalizeID(observation.relatedFeedRecordID)));
  });
  const keys = new Map();
  for (const item of [...feeds, ...observations]) {
    const key = `${normalizeID(item.penID)}|${normalizedFeeder(item.feederName)}`;
    if (!keys.has(key)) keys.set(key, { penID: item.penID, feeder: normalizedFeeder(item.feederName) });
  }
  for (const key of keys.values()) {
    const groupFeeds = feeds.filter((feed) => normalizeID(feed.penID) === normalizeID(key.penID) && normalizedFeeder(feed.feederName) === key.feeder)
      .sort((left, right) => validDate(left.at ?? left.occurredAt) - validDate(right.at ?? right.occurredAt));
    const groupObservations = observations.filter((observation) => normalizeID(observation.penID) === normalizeID(key.penID) && normalizedFeeder(observation.feederName) === key.feeder)
      .sort((left, right) => validDate(left.observedAt ?? left.at) - validDate(right.observedAt ?? right.at) || normalizeID(left.id).localeCompare(normalizeID(right.id)));
    if (groupObservations.length >= 2) {
      for (let index = 1; index < groupObservations.length; index += 1) {
        const opening = groupObservations[index - 1];
        const closing = groupObservations[index];
        const openingAt = validDate(opening.observedAt ?? opening.at);
        const closingAt = validDate(closing.observedAt ?? closing.at);
        if (!(openingAt >= input.start && openingAt < closingAt && closingAt <= input.end)) continue;
        const intervalFeeds = groupFeeds.filter((feed) => {
          const at = validDate(feed.at ?? feed.occurredAt);
          return at > openingAt && at <= closingAt;
        });
        const openingAvailable = Math.max(0, (finiteNumber(opening.actualRemainingKilograms) ?? 0) - (finiteNumber(opening.discardedKilograms) ?? 0));
        let components = openingComponents(opening, openingAvailable);
        components.push(...intervalFeeds.flatMap((feed) => (feed.lines ?? []).map(feedLineComponent)));
        const totalAvailable = components.reduce((sum, component) => sum + component.freshKilograms, 0);
        const evidence = new Set(["measured"]);
        if (!["weighed", "实称"].includes(opening.measurementMethod) || !["weighed", "实称"].includes(closing.measurementMethod)) evidence.add("estimated");
        const conflicts = [];
        const closingRemaining = finiteNumber(closing.actualRemainingKilograms) ?? 0;
        if (closingRemaining > totalAvailable + 0.000001) {
          evidence.add("conflict");
          conflicts.push(`${key.feeder} 闭合区间出现负消耗`);
          components = [];
        } else {
          const residual = componentsForRemainder(closingRemaining, closing.composition ?? [], components);
          if (!subtractComponents(residual, components)) {
            evidence.add("conflict");
            conflicts.push(`${key.feeder} 盘槽组成超过区间可用量`);
            components = [];
          }
        }
        result.slices.push({
          penID: key.penID,
          start: openingAt,
          end: closingAt,
          reportDate: farmDayKey(new Date(closingAt.getTime() - 1), input.timeZone),
          components: mergeComponents(components),
          excludedSheepIDs: new Set(intervalFeeds.flatMap((feed) => feed.excludedSheepIDs ?? []).map(normalizeID)),
          historicalHeadCount: Math.max(...intervalFeeds.map((feed) => finiteInteger(feed.historicalHeadCountSnapshot)).filter((value) => value != null), -Infinity),
          evidence,
          conflicts,
        });
        const added = result.slices.at(-1);
        if (added.historicalHeadCount === -Infinity) added.historicalHeadCount = null;
      }
      const last = groupObservations.at(-1);
      const lastAt = validDate(last.observedAt ?? last.at);
      if (lastAt < input.end && groupFeeds.some((feed) => validDate(feed.at ?? feed.occurredAt) > lastAt)) {
        result.incompleteCountByPen.set(normalizeID(key.penID), (result.incompleteCountByPen.get(normalizeID(key.penID)) ?? 0) + 1);
        result.incompletePenIDs.add(normalizeID(key.penID));
      }
    } else if (!groupObservations.length && groupFeeds.length) {
      const byDay = new Map();
      for (const feed of groupFeeds) {
        const day = farmDayKey(feed.at ?? feed.occurredAt, input.timeZone);
        const dayFeeds = byDay.get(day) ?? [];
        dayFeeds.push(feed);
        byDay.set(day, dayFeeds);
      }
      for (const [day, dayFeeds] of byDay) {
        const dayStart = zonedStartOfDay(day, input.timeZone);
        const nextDay = zonedStartOfDay(addFarmDays(day, 1), input.timeZone);
        const historical = Math.max(...dayFeeds.map((feed) => finiteInteger(feed.historicalHeadCountSnapshot)).filter((value) => value != null), -Infinity);
        result.slices.push({
          penID: key.penID,
          start: new Date(Math.max(dayStart, input.start)),
          end: new Date(Math.min(nextDay, input.end)),
          reportDate: day,
          components: mergeComponents(dayFeeds.flatMap((feed) => (feed.lines ?? []).map(feedLineComponent))),
          excludedSheepIDs: new Set(dayFeeds.flatMap((feed) => feed.excludedSheepIDs ?? []).map(normalizeID)),
          historicalHeadCount: historical === -Infinity ? null : historical,
          evidence: new Set(["estimated"]),
          conflicts: [],
        });
      }
    } else if (groupObservations.length === 1) {
      const boundary = validDate(groupObservations[0].observedAt ?? groupObservations[0].at);
      if (groupFeeds.some((feed) => {
        const at = validDate(feed.at ?? feed.occurredAt);
        return at > boundary && at < input.end;
      })) {
        result.incompleteCountByPen.set(normalizeID(key.penID), (result.incompleteCountByPen.get(normalizeID(key.penID)) ?? 0) + 1);
        result.incompletePenIDs.add(normalizeID(key.penID));
      }
    }
  }
  return result;
}

function mpSupply(summary) {
  if (summary.dryMatterKilograms == null || summary.crudeProteinKilograms == null || summary.meMJ == null) {
    return { grams: null, estimated: false, blockedReason: "干物质、粗蛋白或ME覆盖不足" };
  }
  const dm = summary.dryMatterKilograms;
  const cpG = summary.crudeProteinKilograms * 1_000;
  const hasFractions = summary.coverage.rdp?.isComplete && summary.coverage.rup?.isComplete && summary.coverage.adip?.isComplete;
  let rdpG;
  let rupG;
  let adipG;
  let estimated;
  if (hasFractions && summary.nutrients.rdp != null && summary.nutrients.rup != null && summary.nutrients.adip != null) {
    rdpG = dm * summary.nutrients.rdp * 10;
    rupG = dm * summary.nutrients.rup * 10;
    adipG = dm * summary.nutrients.adip * 10;
    estimated = false;
  } else {
    rdpG = cpG * 0.65;
    rupG = cpG * 0.35;
    adipG = 0;
    estimated = true;
  }
  const digestibleRUP = Math.max(0, rupG - adipG) * 0.8;
  const microbialMP = Math.min(rdpG * 0.64, Math.max(0, summary.meMJ) * 6.4);
  return { grams: digestibleRUP + microbialMP, estimated, blockedReason: null };
}

function observedADG(sheepIDs, weights) {
  const grouped = new Map();
  for (const record of weights) {
    const key = normalizeID(record.sheepID);
    if (!sheepIDs.has(key)) continue;
    const list = grouped.get(key) ?? [];
    list.push(record);
    grouped.set(key, list);
  }
  const values = [];
  for (const records of grouped.values()) {
    const ordered = records.sort((left, right) => validDate(left.at ?? left.occurredAt) - validDate(right.at ?? right.occurredAt));
    const first = ordered[0];
    const last = ordered.at(-1);
    const days = (validDate(last.at ?? last.occurredAt) - validDate(first.at ?? first.occurredAt)) / DAY_MILLISECONDS;
    if (days < 7) continue;
    const value = ((finiteNumber(last.kilograms) ?? 0) - (finiteNumber(first.kilograms) ?? 0)) / days;
    if (value >= 0.05 && value <= 0.85) values.push(value);
  }
  return { value: average(values), count: values.length };
}

function growthResult(penID, stageDays, nutrition, input, presence, hasSheepDayConflict) {
  const totalStageDays = [...stageDays.values()].reduce((sum, value) => sum + value, 0);
  const dominant = [...stageDays.entries()].sort((left, right) => right[1] - left[1])[0] ?? null;
  const stage = dominant?.[0] ?? null;
  const dominantStageRatio = dominant && totalStageDays > 0 ? dominant[1] / totalStageDays : null;
  const endInstant = new Date(input.end.getTime() - 1);
  const stageSheep = presence.sheepInPen(penID, endInstant).filter((sheep) => !stage || feedStage(sheep) === stage);
  const lookback = zonedStartOfDay(addFarmDays(farmDayKey(input.end, input.timeZone), -60), input.timeZone);
  const recentWeights = input.snapshot.weights.filter((record) => {
    const at = validDate(record.at ?? record.occurredAt);
    return at && at >= lookback && at < input.end && finiteNumber(record.kilograms) > 0;
  });
  const latestBySheep = new Map();
  for (const record of recentWeights) {
    const key = normalizeID(record.sheepID);
    const existing = latestBySheep.get(key);
    if (!existing || validDate(record.at ?? record.occurredAt) > validDate(existing.at ?? existing.occurredAt)) latestBySheep.set(key, record);
  }
  const weightValues = stageSheep.flatMap((sheep) => {
    const value = finiteNumber(latestBySheep.get(normalizeID(sheep.id))?.kilograms);
    return value == null ? [] : [value];
  });
  const requiredWeightSampleCount = Math.max(Math.ceil(stageSheep.length * 0.5), Math.min(3, stageSheep.length));
  const weightCoverage = stageSheep.length ? weightValues.length / stageSheep.length : 0;
  const averageWeightKilograms = average(weightValues);
  const observed = observedADG(new Set(stageSheep.map((sheep) => normalizeID(sheep.id))), recentWeights);
  const blocked = (reason, modelDescription = "ME + MP") => ({
    stage,
    dominantStageRatio,
    averageWeightKilograms,
    weightCoverage,
    weightSampleCount: weightValues.length,
    requiredWeightSampleCount,
    maintenanceMEPerDay: null,
    maintenanceMPGramsPerDay: null,
    maintenanceMEGap: null,
    maintenanceMPGapGrams: null,
    nutritionPotentialADGKg: null,
    observedADGKg: observed.value,
    observedSampleCount: observed.count,
    calibratedExpectedADGKg: null,
    limitingFactor: null,
    blockedReason: reason,
    modelDescription,
  });
  if (hasSheepDayConflict) return blocked("羊天快照与事件时间线冲突");
  if (!stage || dominantStageRatio < 0.8) return blocked("混群圈舍没有达到80%的单一生长阶段");
  if (stage === "lactatingLamb") return blocked("哺乳羔羊无法从圈舍饲料中分离母乳贡献", "不单独预测");
  if (stage === "unknown") return blocked("生产阶段未分类");
  if (weightValues.length < requiredWeightSampleCount || weightCoverage < 0.5 || averageWeightKilograms == null) return blocked("结束日前60天体重覆盖不足");
  const me = nutrition.meMJPerSheepDay;
  const mp = nutrition.metabolizableProteinGramsPerSheepDay;
  if (me == null || mp == null) return blocked(nutrition.mpBlockedReason ?? "ME或MP覆盖不足");
  const metabolicWeight = averageWeightKilograms ** 0.75;
  const maintenanceMEPerDay = 0.42 * metabolicWeight;
  const maintenanceMPGramsPerDay = 3.8 * metabolicWeight;
  const maintenanceMEGap = me - maintenanceMEPerDay;
  const maintenanceMPGapGrams = mp - maintenanceMPGramsPerDay;
  const shared = {
    stage,
    dominantStageRatio,
    averageWeightKilograms,
    weightCoverage,
    weightSampleCount: weightValues.length,
    requiredWeightSampleCount,
    maintenanceMEPerDay,
    maintenanceMPGramsPerDay,
    maintenanceMEGap,
    maintenanceMPGapGrams,
    observedADGKg: observed.value,
    observedSampleCount: observed.count,
  };
  if (["breedingEwe", "breedingRam"].includes(stage)) {
    return {
      ...shared,
      nutritionPotentialADGKg: null,
      calibratedExpectedADGKg: null,
      limitingFactor: Math.min(maintenanceMEGap, maintenanceMPGapGrams) < 0
        ? (maintenanceMEGap <= maintenanceMPGapGrams ? "维持能量不足" : "维持代谢蛋白不足")
        : "满足维持需求",
      blockedReason: null,
      modelDescription: "维持需要与营养差额",
    };
  }
  if (!["weanedLamb", "growing", "replacement", "fattening"].includes(stage)) return blocked("该阶段不使用生长预测模型");
  const gainMEPerKg = Math.min(Math.max(12.8 + Math.max(0, averageWeightKilograms - 25) * 0.065, 14), 17.5);
  const gainMPPerKg = Math.min(Math.max(250 + Math.max(0, averageWeightKilograms - 30) * 1.2, 250), 295);
  const physiologicalMax = averageWeightKilograms < 28 ? 0.48 : 0.6;
  const energyPotential = Math.max(0, maintenanceMEGap / gainMEPerKg);
  const proteinPotential = Math.max(0, maintenanceMPGapGrams / gainMPPerKg);
  const nutritionPotentialADGKg = Math.min(energyPotential, proteinPotential, physiologicalMax);
  const calibratedExpectedADGKg = observed.value == null
    ? nutritionPotentialADGKg
    : Math.min(physiologicalMax, Math.max(0, observed.value) * 0.65 + nutritionPotentialADGKg * 0.35);
  const suffix = nutrition.mpEstimated ? "（MP为估算模型）" : "";
  return {
    ...shared,
    nutritionPotentialADGKg,
    calibratedExpectedADGKg,
    limitingFactor: `${energyPotential <= proteinPotential ? "能量限制" : "代谢蛋白限制"}${suffix}`,
    blockedReason: null,
    modelDescription: nutrition.mpEstimated ? "ME + MP（仅CP时采用Plus兼容估算）" : "ME + MP",
  };
}

function penFeedResult(penID, name, slices, extraIncompleteCount, input, presence) {
  const usable = slices.filter((slice) => !slice.evidence.has("conflict") && slice.start < slice.end);
  const merged = mergeIntervals(usable.map((slice) => ({ start: slice.start, end: slice.end })));
  let sheepDays = 0;
  const sheepDayEvidence = new Set();
  const sheepDayConflicts = [];
  const stageDays = new Map();
  for (const interval of merged) {
    const overlapping = usable.filter((slice) => slice.start < interval.end && slice.end > interval.start);
    const excluded = new Set(overlapping.flatMap((slice) => [...slice.excludedSheepIDs]));
    const calculation = presence.sheepDays(penID, interval.start, interval.end, excluded);
    if (calculation.total > 0) sheepDays += calculation.total;
    else {
      const historical = Math.max(...overlapping.map((slice) => slice.historicalHeadCount).filter((value) => value != null), -Infinity);
      if (historical !== -Infinity) {
        sheepDays += historical * (interval.end - interval.start) / DAY_MILLISECONDS;
        sheepDayEvidence.add("historicalHeadCount");
      }
    }
    for (const value of calculation.evidence) sheepDayEvidence.add(value);
    sheepDayConflicts.push(...calculation.conflicts);
    for (const [stage, value] of calculation.stageDays) stageDays.set(stage, (stageDays.get(stage) ?? 0) + value);
  }
  const components = mergeComponents(usable.flatMap((slice) => slice.components));
  const freshKilograms = components.reduce((sum, component) => sum + component.freshKilograms, 0);
  const summary = nutritionSummary(components);
  const mp = mpSupply(summary);
  const divisor = sheepDays > 0 ? sheepDays : null;
  const nutrition = {
    summary,
    freshKilogramsPerSheepDay: divisor ? freshKilograms / divisor : null,
    dryMatterKilogramsPerSheepDay: divisor && summary.dryMatterKilograms != null ? summary.dryMatterKilograms / divisor : null,
    meMJPerSheepDay: divisor && summary.meMJ != null ? summary.meMJ / divisor : null,
    crudeProteinGramsPerSheepDay: divisor && summary.crudeProteinKilograms != null ? summary.crudeProteinKilograms * 1_000 / divisor : null,
    metabolizableProteinGramsPerSheepDay: divisor && mp.grams != null ? mp.grams / divisor : null,
    ndfGramsPerSheepDay: divisor && summary.ndfKilograms != null ? summary.ndfKilograms * 1_000 / divisor : null,
    adfGramsPerSheepDay: divisor && summary.adfKilograms != null ? summary.adfKilograms * 1_000 / divisor : null,
    mpEstimated: mp.estimated,
    mpBlockedReason: mp.blockedReason,
  };
  const ingredientsByKey = new Map();
  for (const component of components) {
    const key = `${normalizeID(component.ingredientID) || "unknown"}|${normalizeID(component.ingredientBatchID) || "none"}|${component.name}`;
    const values = ingredientsByKey.get(key) ?? [];
    values.push(component);
    ingredientsByKey.set(key, values);
  }
  const ingredients = [...ingredientsByKey.entries()].map(([id, values]) => {
    const valuesMerged = mergeComponents(values);
    const total = valuesMerged.reduce((sum, component) => sum + component.freshKilograms, 0);
    return {
      id,
      ingredientID: values[0]?.ingredientID ?? null,
      ingredientBatchID: values[0]?.ingredientBatchID ?? null,
      name: values[0]?.name ?? "未知原料",
      freshKilograms: total,
      freshKilogramsPerSheepDay: divisor ? total / divisor : null,
      nutrition: nutritionSummary(valuesMerged),
    };
  }).sort((left, right) => left.name.localeCompare(right.name, "zh-CN"));
  const dailyGroups = new Map();
  for (const slice of usable) {
    const values = dailyGroups.get(slice.reportDate) ?? [];
    values.push(slice);
    dailyGroups.set(slice.reportDate, values);
  }
  const dailyTrend = [...dailyGroups.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([date, values]) => {
    const dailyComponents = mergeComponents(values.flatMap((slice) => slice.components));
    const dailyFresh = dailyComponents.reduce((sum, component) => sum + component.freshKilograms, 0);
    const dailySummary = nutritionSummary(dailyComponents);
    const intervals = mergeIntervals(values.map((slice) => ({ start: slice.start, end: slice.end })));
    let days = 0;
    for (const interval of intervals) {
      const excluded = new Set(values.filter((slice) => slice.start < interval.end && slice.end > interval.start).flatMap((slice) => [...slice.excludedSheepIDs]));
      const calculation = presence.sheepDays(penID, interval.start, interval.end, excluded);
      if (calculation.total > 0) days += calculation.total;
      else {
        const historical = Math.max(...values.map((slice) => slice.historicalHeadCount).filter((value) => value != null), -Infinity);
        if (historical !== -Infinity) days += historical * (interval.end - interval.start) / DAY_MILLISECONDS;
      }
    }
    return {
      date,
      freshKilograms: dailyFresh,
      sheepDays: days,
      dmiKilogramsPerSheepDay: days > 0 && dailySummary.dryMatterKilograms != null ? dailySummary.dryMatterKilograms / days : null,
      meMJPerSheepDay: days > 0 && dailySummary.meMJ != null ? dailySummary.meMJ / days : null,
      evidence: new Set(values.flatMap((slice) => [...slice.evidence])),
    };
  });
  const evidence = new Set([...sheepDayEvidence, ...slices.flatMap((slice) => [...slice.evidence])]);
  const conflicts = [...new Set([...slices.flatMap((slice) => slice.conflicts), ...sheepDayConflicts])].sort();
  return {
    id: penID,
    name,
    freshKilograms,
    sheepDays,
    ingredients,
    nutrition,
    growth: growthResult(penID, stageDays, nutrition, input, presence, sheepDayConflicts.length > 0),
    dailyTrend,
    evidence,
    conflicts,
    completeIntervalCount: slices.filter((slice) => !slice.evidence.has("conflict")).length,
    incompleteIntervalCount: extraIncompleteCount + slices.filter((slice) => slice.evidence.has("conflict")).length,
  };
}

export function defaultFeedRange({ now = new Date(), timeZone = "Asia/Shanghai", days = 7 } = {}) {
  const endDateExclusive = farmDayKey(now, timeZone);
  return {
    startDate: addFarmDays(endDateExclusive, -days),
    endDateExclusive,
    inclusiveEndDate: addFarmDays(endDateExclusive, -1),
  };
}

export function feedFilterOptions(source, {
  startDate,
  endDateExclusive,
  now = new Date(),
  timeZone = "Asia/Shanghai",
} = {}) {
  const snapshot = sourceSnapshot(source);
  const defaults = defaultFeedRange({ now, timeZone });
  const start = zonedStartOfDay(startDate ?? defaults.startDate, timeZone);
  const end = zonedStartOfDay(endDateExclusive ?? defaults.endDateExclusive, timeZone);
  const occupiedPenIDs = occupiedPenIDsDuringWholeDays(snapshot, start, end, timeZone);
  return snapshot.pens.filter((pen) => occupiedPenIDs.has(normalizeID(pen.id)));
}

export function calculateFeedIntakeAnalytics(source, {
  startDate = null,
  endDateExclusive = null,
  selectedPenIDs = [],
  now = new Date(),
  timeZone = "Asia/Shanghai",
} = {}) {
  const snapshot = sourceSnapshot(source);
  const defaults = defaultFeedRange({ now, timeZone });
  const resolvedStart = keyParts(startDate) ? startDate : defaults.startDate;
  const resolvedEnd = keyParts(endDateExclusive) ? endDateExclusive : defaults.endDateExclusive;
  const startKey = resolvedStart <= resolvedEnd ? resolvedStart : resolvedEnd;
  const endKey = resolvedStart <= resolvedEnd ? resolvedEnd : resolvedStart;
  const start = zonedStartOfDay(startKey, timeZone);
  const end = zonedStartOfDay(endKey, timeZone);
  const selected = new Set(selectedPenIDs.map(normalizeID));
  const pens = snapshot.pens.filter((pen) => !selected.size || selected.has(normalizeID(pen.id)));
  const penIDs = new Set(pens.map((pen) => normalizeID(pen.id)));
  const feeds = snapshot.feeds.filter((feed) => {
    const at = validDate(feed.at ?? feed.occurredAt);
    return at && at >= start && at < end && penIDs.has(normalizeID(feed.penID));
  });
  const input = { start, end, timeZone, snapshot: { ...snapshot, pens } };
  if (!(start < end)) {
    return {
      start: start?.toISOString() ?? null,
      end: end?.toISOString() ?? null,
      startDate: startKey,
      endDateExclusive: endKey,
      overview: { totalFreshKilograms: 0, feedingSheepDays: 0, effectivePenCount: 0, recordCompleteness: 0, measuredRatio: 0, estimatedRatio: 0, conflictCount: 0 },
      pens: [],
      recordCount: 0,
    };
  }
  const presence = makePresenceIndex(input.snapshot, { timeZone });
  let slices = limitedSlices(input.snapshot, input, feeds.filter((feed) => feed.mode === "limited"));
  const free = freeChoiceSlices(input.snapshot, input, feeds.filter((feed) => feed.mode === "freeChoice"));
  slices = [...slices, ...free.slices];
  const resultPenIDs = new Set([...slices.map((slice) => normalizeID(slice.penID)), ...free.incompletePenIDs]);
  const penNameByID = new Map(pens.map((pen) => [normalizeID(pen.id), pen.name]));
  const rawPenIDByNormalized = new Map(pens.map((pen) => [normalizeID(pen.id), pen.id]));
  for (const slice of slices) if (!rawPenIDByNormalized.has(normalizeID(slice.penID))) rawPenIDByNormalized.set(normalizeID(slice.penID), slice.penID);
  const penResults = [...resultPenIDs].map((normalizedPenID) => penFeedResult(
    rawPenIDByNormalized.get(normalizedPenID) ?? normalizedPenID,
    penNameByID.get(normalizedPenID) ?? "未知圈舍",
    slices.filter((slice) => normalizeID(slice.penID) === normalizedPenID),
    free.incompleteCountByPen.get(normalizedPenID) ?? 0,
    input,
    presence,
  )).sort((left, right) => left.name.localeCompare(right.name, "zh-CN"));
  const complete = penResults.reduce((sum, pen) => sum + pen.completeIntervalCount, 0);
  const incomplete = penResults.reduce((sum, pen) => sum + pen.incompleteIntervalCount, 0);
  const measuredKg = slices.filter((slice) => slice.evidence.has("measured") && !slice.evidence.has("estimated"))
    .reduce((sum, slice) => sum + slice.components.reduce((subtotal, component) => subtotal + Math.max(0, component.freshKilograms), 0), 0);
  const estimatedKg = slices.filter((slice) => slice.evidence.has("estimated"))
    .reduce((sum, slice) => sum + slice.components.reduce((subtotal, component) => subtotal + Math.max(0, component.freshKilograms), 0), 0);
  const classifiedKg = measuredKg + estimatedKg;
  const overview = {
    totalFreshKilograms: penResults.reduce((sum, pen) => sum + pen.freshKilograms, 0),
    feedingSheepDays: penResults.reduce((sum, pen) => sum + pen.sheepDays, 0),
    effectivePenCount: penResults.filter((pen) => pen.freshKilograms > 0).length,
    recordCompleteness: complete + incomplete > 0 ? complete / (complete + incomplete) : 0,
    measuredRatio: classifiedKg > 0 ? measuredKg / classifiedKg : 0,
    estimatedRatio: classifiedKg > 0 ? estimatedKg / classifiedKg : 0,
    conflictCount: penResults.reduce((sum, pen) => sum + pen.conflicts.length, 0),
  };
  const todayKey = farmDayKey(now, timeZone);
  const todayFeeds = snapshot.feeds.filter((feed) => farmDayKey(feed.at ?? feed.occurredAt, timeZone) === todayKey);
  return {
    start: start.toISOString(),
    end: end.toISOString(),
    startDate: startKey,
    endDateExclusive: endKey,
    inclusiveEndDate: addFarmDays(endKey, -1),
    overview,
    pens: penResults,
    recordCount: feeds.length,
    todayFeedCount: todayFeeds.length,
    todayKilograms: todayFeeds.reduce((sum, feed) => sum + (feed.lines ?? []).reduce((subtotal, line) => subtotal + (finiteNumber(line.freshKilograms ?? line.kilograms) ?? 0), 0), 0),
    boundary: recordBoundary(feeds),
  };
}

export function buildDefaultAppAnalytics(source, {
  now = new Date(),
  timeZone = "Asia/Shanghai",
} = {}) {
  const snapshot = sourceSnapshot(source);
  const weightOptions = weightFilterOptions(snapshot, { now, timeZone });
  const reproductionFilter = defaultReproductionFilter({ now, timeZone });
  const feedRange = defaultFeedRange({ now, timeZone });
  return {
    weight: calculateWeightAnalytics(snapshot, { cutoff: weightOptions.cutoff, now, timeZone }),
    lamb: calculateLambAnalytics(snapshot, { selectedYear: null, timeZone }),
    reproduction: calculateReproductionAnalytics(snapshot, { filter: reproductionFilter, now, timeZone }),
    feed: calculateFeedIntakeAnalytics(snapshot, { ...feedRange, now, timeZone }),
    options: {
      weight: weightOptions,
      lambYears: lambFilterOptions(snapshot, timeZone),
      reproduction: reproductionFilterOptions(snapshot, { endDate: reproductionFilter.endDate, now, timeZone }),
      feed: { ...feedRange, pens: feedFilterOptions(snapshot, { ...feedRange, now, timeZone }) },
    },
  };
}
