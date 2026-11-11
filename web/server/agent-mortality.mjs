import { zonedStartOfDay, addFarmDays, farmDayKey } from "../src/lib/appAnalytics.js";

export class MetricClarification extends Error {
  constructor(message, fields) { super(message); this.code = "NEEDS_USER_INPUT"; this.fields = fields; }
}

export function requireMetricPeriod(request, timeZone, now) {
  const fields = ["startDate", "endDate"].filter(key => !/^\d{4}-\d{2}-\d{2}$/.test(request[key] ?? ""));
  if (fields.length) throw new MetricClarification("请先向用户确认分析的开始日期和结束日期。", fields);
  const start = zonedStartOfDay(request.startDate, timeZone);
  const end = zonedStartOfDay(addFarmDays(request.endDate, 1), timeZone);
  if (farmDayKey(start, timeZone) !== request.startDate || farmDayKey(new Date(end - 1), timeZone) !== request.endDate || start >= end || start > now) throw new Error("分析日期无效，开始日须不晚于结束日及当前日期。");
  return { start: +start, end: Math.min(+end, +now + 1) };
}

// Swift imports use distantPast for an unknown business date. It is a finite
// JavaScript timestamp; null also converts to the Unix epoch if left unchecked.
function businessTime(value) {
  if (value == null || value === "") return NaN;
  const at = new Date(value);
  return at.getUTCFullYear() > 1 ? +at : NaN;
}

export function mortalityRequest(snapshot, request) {
  const { month, year, ...filters } = request;
  if (month !== undefined || year !== undefined) {
    if (!Number.isInteger(month) || month < 1 || month > 12 ||
        (year !== undefined && (!Number.isInteger(year) || year < 1000 || year > 9999)) ||
        filters.startDate !== undefined || filters.endDate !== undefined) {
      throw new Error("请提供一个有效月份或一段明确日期。");
    }
    const today = farmDayKey(new Date(snapshot.capturedAt), snapshot.farm.timeZoneIdentifier);
    const localYear = year ?? (Number(today.slice(0, 4)) - (month > Number(today.slice(5, 7)) ? 1 : 0));
    filters.startDate = localYear + "-" + String(month).padStart(2, "0") + "-01";
    const next = month === 12 ? (localYear + 1) + "-01-01" : localYear + "-" + String(month + 1).padStart(2, "0") + "-01";
    filters.endDate = addFarmDays(next, -1);
  }
  return { sex: "all", denominator: "opening_cohort", ...filters };
}

function matchingRosterIDs(snapshot, request, roster) {
  const farm = snapshot.farm;
  const filters = roster?.filters_applied;
  if (!Array.isArray(roster?.memberIDs) || roster.basis !== "期初" || roster.day !== request.startDate ||
      roster.farm_id !== farm.id || roster.farm_generation !== farm.generation || roster.time_zone !== farm.timeZoneIdentifier ||
      !Number.isSafeInteger(roster.cloud_head) || !Number.isSafeInteger(farm.revision) || roster.cloud_head > farm.revision ||
      !filters?.opening || filters.day !== request.startDate || filters.penName ||
      filters.sex !== request.sex || filters.breed !== (request.breed ?? "") ||
      roster.memberIDs.some(id => typeof id !== "string" || !id.trim())) return null;
  const ids = new Set(roster.memberIDs.map(id => id.toLowerCase()));
  return ids.size === roster.count && ids.size === roster.memberIDs.length ? ids : null;
}

function historicalCohort(snapshot, request, start, end, inPeriod, time, removals, issues) {
  const source = snapshot.analyticsSource;
  const sheep = source.sheep ?? [];
  const histories = new Map();
  for (const row of [...removals.map(r => ({ ...r, removal: true })), ...(source.transfers ?? [])]) {
    const list = histories.get(row.sheepID) ?? []; list.push(row); histories.set(row.sheepID, list);
  }
  for (const list of histories.values()) list.sort((a, b) => time(a) - time(b) || String(a.id).localeCompare(String(b.id)));
  function presentAt(s, at) {
    if (s.isHistoricalArchive) return false;
    const history = histories.get(s.id) ?? [];
    const events = history.filter(r => time(r) <= at);
    const exit = events.find(r => r.removal);
    const recordedExit = businessTime(s.removedAt);
    if (exit || recordedExit <= at) {
      const exitAt = Math.min(exit ? time(exit) : Infinity, Number.isFinite(recordedExit) ? recordedExit : Infinity);
      if (events.some(r => !r.removal && time(r) >= exitAt)) {
        issues.push({ sheepID: s.id, reason: "离群同一时刻或之后仍有圈舍记录，需核对原始记录" });
      }
      return false;
    }
    const entry = businessTime(s.enteredAt);
    if (!Number.isFinite(entry)) {
      issues.push({ sheepID: s.id, reason: "入群日期缺失或为占位日期" });
      return false;
    }
    if (entry > at) return false;
    if (s.legacyStatusSnapshotIsAuthoritative && s.status !== "active" &&
        !history.some(r => r.removal) && !Number.isFinite(recordedExit)) {
      issues.push({ sheepID: s.id, reason: "历史状态缺少可重建的离场事实" });
      return false;
    }
    return true;
  }
  const candidates = sheep.filter(s => (request.sex === "all" || s.sex === request.sex) && (!request.breed || s.breed === request.breed));
  const cohort = candidates.filter(s => {
    if (request.denominator === "registered_birth_cohort") { const birth = businessTime(s.birthAt); return s.birthAt != null && birth >= start && birth < end; }
    const opening = presentAt(s, start - 1);
    const entered = businessTime(s.enteredAt);
    return opening || (!s.isHistoricalArchive && entered >= start && entered < end) ||
      (histories.get(s.id) ?? []).some(r => !r.removal && inPeriod(r) && presentAt(s, time(r)));
  });
  const cohortIDs = new Set(cohort.map(s => s.id));
  const selected = removals.filter(r => inPeriod(r) && cohortIDs.has(r.sheepID));
  const sheepByID = new Map(sheep.map(s => [s.id, s]));
  for (const row of selected.filter(r => ["deceased", "culled"].includes(r.kind))) {
    if (!presentAt(sheepByID.get(row.sheepID), time(row) - 1)) {
      issues.push({ sheepID: row.sheepID, reason: "死亡或淘汰发生前无法确认仍在场，需核对此前离场和返场记录" });
    }
  }
  const knownIDs = new Set(sheep.map(s => s.id));
  const missing = removals.filter(r => inPeriod(r) && !knownIDs.has(r.sheepID));
  if (missing.length) issues.push({ reason: "期间离场记录关联不到羊只档案", count: missing.length });
  return { selected, denominator: cohort.length, missing };
}

export function mortalityAnalysis(snapshot, input, openingRoster) {
  const request = mortalityRequest(snapshot, input);
  const { start, end } = requireMetricPeriod(request, snapshot.farm.timeZoneIdentifier, new Date(snapshot.capturedAt));
  if (!["opening_cohort", "period_exposed", "registered_birth_cohort"].includes(request.denominator) ||
      !["all", "ewe", "ram"].includes(request.sex) || (request.breed !== undefined && typeof request.breed !== "string")) {
    throw new Error("不支持所选羊群或死淘率分母。");
  }
  const time = row => businessTime(row.at ?? row.occurredAt);
  const inPeriod = row => time(row) >= start && time(row) < end;
  const removals = (snapshot.analyticsSource.removals ?? []).filter(row => row.deletedAt == null);
  const issues = [];
  let selected, denominator, missing;
  if (request.denominator === "opening_cohort") {
    const ids = matchingRosterIDs(snapshot, request, openingRoster);
    if (!ids) return {
      denominatorBasis: request.denominator, denominator: null, deathCount: null, cullCount: null,
      deathAndCullCount: null, deathAndCullRate: null, issues: [{ reason: "无法核验指定日期和范围的期初名册" }],
      issueCounts: { "无法核验指定日期和范围的期初名册": 1 },
    };
    denominator = ids.size;
    const period = removals.filter(inPeriod);
    selected = period.filter(r => typeof r.sheepID === "string" && ids.has(r.sheepID.toLowerCase()))
      .map(r => ({ ...r, sheepID: r.sheepID.toLowerCase() }));
    missing = period.filter(r => !r.sheepID && !["sold", "transferredOut"].includes(r.kind));
    if (missing.length) issues.push({ reason: "期间离场记录缺少羊只 ID", count: missing.length });
    const firstExit = new Map();
    for (const row of selected.filter(r => ["sold", "transferredOut"].includes(r.kind))) {
      firstExit.set(row.sheepID, Math.min(firstExit.get(row.sheepID) ?? Infinity, time(row)));
    }
    for (const row of selected.filter(r => ["culled", "deceased"].includes(r.kind))) {
      if (firstExit.get(row.sheepID) <= time(row)) issues.push({ sheepID: row.sheepID, reason: "死亡或淘汰前已有同期出售或转出，需核对此前离场记录" });
    }
  } else {
    ({ selected, denominator, missing } = historicalCohort(snapshot, request, start, end, inPeriod, time, removals, issues));
  }
  const groups = Object.fromEntries(["deceased", "culled", "sold", "transferredOut", "removed"].map(kind => [kind, new Set(selected.filter(r => r.kind === kind).map(r => r.sheepID))]));
  if (groups.removed.size || selected.some(r => !Object.hasOwn(groups, r.kind))) issues.push({ reason: "存在未明确分类的离场，需核对死亡/淘汰分类" });
  if ([...groups.deceased].some(id => groups.culled.has(id))) issues.push({ reason: "同一羊只同时有死亡与淘汰记录" });
  const uniqueIssues = [...new Map(issues.map(i => [JSON.stringify(i), i])).values()];
  const issueCounts = {};
  for (const issue of uniqueIssues) issueCounts[issue.reason] = (issueCounts[issue.reason] ?? 0) + (issue.count ?? 1);
  const rate = count => denominator > 0 && !uniqueIssues.length ? count / denominator : null;
  const combined = new Set([...groups.deceased, ...groups.culled]);
  return {
    metric: "death_and_cull_incidence",
    ...(openingRoster?.archive_source ? { openingRosterArchive: openingRoster.archive_source }
      : request.denominator === "opening_cohort" ? { openingRosterHead: openingRoster.cloud_head } : {}),
    denominatorBasis: request.denominator, denominator,
    scopeDescription: request.denominator === "opening_cohort" ? "期初在场队列在观察期内的死淘比例" : request.denominator === "period_exposed" ? "期间曾在场羊只的死淘比例" : "期内有出生日期档案的羔羊截至分析结束日的死淘比例；不是产羔事件出生总数",
    deathCount: groups.deceased.size, cullCount: groups.culled.size, deathAndCullCount: combined.size,
    soldCount: groups.sold.size, transferredOutCount: groups.transferredOut.size,
    deathRate: rate(groups.deceased.size), cullRate: rate(groups.culled.size), deathAndCullRate: rate(combined.size),
    rateUnit: "proportion", formula: "所选队列期间死亡/淘汰去重头数 ÷ 所选队列头数；出售和转出不计入死淘",
    issueCounts, issues: uniqueIssues.slice(0, 20), issueDetailTruncated: uniqueIssues.length > 20, missingLinkedRemovalCount: missing.length,
    coverage: "依据当前云端可重建档案与业务记录；没有记录不代表实际未发生。不能将档案样本外推为全牧场。",
    rows: selected.slice(0, 100).map(r => ({ id: r.id, sheepID: r.sheepID, kind: r.kind, at: r.at ?? r.occurredAt })),
    recordsTruncated: selected.length > 100,
  };
}

// Mortality values and withheld rates must survive to the UI without a model
// recalculating the fraction or turning an unresolved roster into a census.
export function renderMortalityEvidence(evidence) {
  const { result, filters_applied: f, time_zone: zone, completeness } = evidence;
  if (f.denominator === "opening_cohort") {
    const group = [f.breed, { ewe: "母羊", ram: "公羊" }[f.sex]].filter(Boolean).join(" ");
    const lastDay = farmDayKey(new Date(evidence.as_of), zone);
    const period = f.startDate + " 至 " + (f.endDate > lastDay ? lastDay + "（截至查询时）" : f.endDate);
    const lines = [period + (group ? "，" + group : "") + "。"];
    if (result.denominator == null) return lines.concat("未能核验期初在群名册，本期死淘率无法核定。").join("\n");
    lines.push(`期初在群名册 ${result.denominator} 只，其中死亡 ${result.deathCount} 只、淘汰 ${result.cullCount} 只，合计 ${result.deathAndCullCount} 只。`);
    if (result.deathAndCullRate !== null) {
      lines.push(`死淘率为 ${result.deathAndCullCount} ÷ ${result.denominator} = ${(100 * result.deathAndCullRate).toFixed(2)}%。`);
    } else {
      lines.push(result.denominator === 0 ? "期初名册为 0 只，本期死淘率无法核定。" : "本期死淘率无法核定。");
      lines.push(...Object.entries(result.issueCounts).map(([reason, n]) => `待核对：${reason}（${n}）。`));
    }
    if (result.openingRosterArchive) lines.push("期初按开始日零点前已登记的云端名册核对。");
    return lines.join("\n");
  }
  const basis = { period_exposed: "期间曾在场档案", registered_birth_cohort: "期间登记出生档案" }[f.denominator];
  const scope = [{ all: "全部性别", ewe: "母羊", ram: "公羊" }[f.sex], f.breed].filter(Boolean).join("，");
  const pending = Object.entries(result.issueCounts);
  const counted = `按档案可纳入 ${result.denominator} 只，其中期间登记死亡 ${result.deathCount} 只、淘汰 ${result.cullCount} 只，死淘去重 ${result.deathAndCullCount} 只。出售 ${result.soldCount} 只、转出 ${result.transferredOutCount} 只另列。`;
  const rate = result.deathAndCullRate === null
    ? "本期死淘率无法核定。" : `上述档案队列的死淘比例为 ${(100 * result.deathAndCullRate).toFixed(2)}%。`;
  return [`${f.startDate} 至 ${f.endDate}（${zone}），${scope}，按${basis}逐只核对。`,
    rate, counted, ...pending.map(([reason, count]) => `待核对：${reason}（${count}）。`),
    result.coverage,
    `云端版本 ${completeness.projection?.verifiedCloudHead ?? "未提供"}。`].join("\n");
}
