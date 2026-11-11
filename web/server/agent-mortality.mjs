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

// Incidence proportions for explicitly selected populations, not a guessed
// herd denominator. A birth-date profile cohort is never labelled all born lambs.
export function mortalityAnalysis(snapshot, request) {
  const now = new Date(snapshot.capturedAt);
  const { start, end } = requireMetricPeriod(request, snapshot.farm.timeZoneIdentifier, now);
  const bases = ["opening_cohort", "period_exposed", "registered_birth_cohort"];
  if (!bases.includes(request.denominator) || !["all", "ewe", "ram"].includes(request.sex)) {
    throw new MetricClarification("请确认统计对象（全群/母羊/公羊）和分母：期初在场队列、期间曾在场羊只，或期内有出生日期档案的羔羊队列。", ["sex", "denominator"]);
  }
  const source = snapshot.analyticsSource;
  const sheep = source.sheep ?? [];
  const knownIDs = new Set(sheep.map(s => s.id));
  const removals = source.removals ?? [];
  const inPeriod = row => { const at = +new Date(row.at ?? row.occurredAt); return at >= start && at < end; };
  const issues = [];
  const time = row => +new Date(row.at ?? row.occurredAt);
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
    if (request.denominator === "opening_cohort") return opening;
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
  const missing = removals.filter(r => inPeriod(r) && !knownIDs.has(r.sheepID));
  if (missing.length) issues.push({ reason: "期间离场记录关联不到羊只档案", count: missing.length });
  const groups = Object.fromEntries(["deceased", "culled", "sold", "transferredOut", "removed"].map(kind => [kind, new Set(selected.filter(r => r.kind === kind).map(r => r.sheepID))]));
  if (groups.removed.size || selected.some(r => !Object.hasOwn(groups, r.kind))) issues.push({ reason: "存在未明确分类的离场，需核对死亡/淘汰分类" });
  if ([...groups.deceased].some(id => groups.culled.has(id))) issues.push({ reason: "同一羊只同时有死亡与淘汰记录" });
  const denominator = cohort.length;
  const uniqueIssues = [...new Map(issues.map(i => [JSON.stringify(i), i])).values()];
  const issueCounts = {};
  for (const issue of uniqueIssues) issueCounts[issue.reason] = (issueCounts[issue.reason] ?? 0) + (issue.count ?? 1);
  const rate = count => denominator > 0 && !uniqueIssues.length ? count / denominator : null;
  const combined = new Set([...groups.deceased, ...groups.culled]);
  return {
    metric: "death_and_cull_incidence", denominatorBasis: request.denominator, denominator,
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
  const basis = { opening_cohort: "期初在场档案", period_exposed: "期间曾在场档案", registered_birth_cohort: "期间登记出生档案" }[f.denominator];
  const scope = [{ all: "全部性别", ewe: "母羊", ram: "公羊" }[f.sex], f.breed].filter(Boolean).join("，");
  const pending = Object.entries(result.issueCounts);
  const counted = `按档案可纳入 ${result.denominator} 只，其中期间登记死亡 ${result.deathCount} 只、淘汰 ${result.cullCount} 只，死淘去重 ${result.deathAndCullCount} 只。出售 ${result.soldCount} 只、转出 ${result.transferredOutCount} 只另列。`;
  const rate = result.deathAndCullRate === null
    ? "本期死淘率无法核定。" : `上述档案队列的死淘比例为 ${(100 * result.deathAndCullRate).toFixed(2)}%。`;
  return [`${f.startDate} 至 ${f.endDate}（${zone}），${scope}，按${basis}逐只核对。`,
    rate, counted, ...pending.map(([reason, count]) => `待核对：${reason}（${count}）。`),
    f.denominator === "opening_cohort" ? "期初取开始日零点前一刻，逐只核对入群日期、离群日期和转舍记录。此名单由业务档案重建，现场盘点数须以当日盘点记录核对。" : result.coverage,
    `云端版本 ${completeness.projection?.verifiedCloudHead ?? "未提供"}。`].join("\n");
}
