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
    const entry = +new Date(s.enteredAt);
    if (!Number.isFinite(entry)) { issues.push({ sheepID: s.id, reason: "缺少入场日期" }); return false; }
    if (entry > at || s.isHistoricalArchive) return false;
    const history = histories.get(s.id) ?? [];
    if (s.legacyStatusSnapshotIsAuthoritative && !history.length && s.status !== "active") {
      issues.push({ sheepID: s.id, reason: "历史状态缺少可重建的离场事实" }); return false;
    }
    const last = history.filter(r => time(r) <= at).at(-1);
    if (last) return last.removal !== true;
    return s.removedAt == null || +new Date(s.removedAt) > at;
  }
  const candidates = sheep.filter(s => (request.sex === "all" || s.sex === request.sex) && (!request.breed || s.breed === request.breed));
  const cohort = candidates.filter(s => {
    if (request.denominator === "registered_birth_cohort") { const birth = +new Date(s.birthAt); return s.birthAt != null && birth >= start && birth < end; }
    const opening = presentAt(s, start - 1);
    if (request.denominator === "opening_cohort") return opening;
    const entered = +new Date(s.enteredAt);
    return opening || (!s.isHistoricalArchive && entered >= start && entered < end) ||
      (histories.get(s.id) ?? []).some(r => !r.removal && inPeriod(r));
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
  const rate = count => denominator > 0 && !uniqueIssues.length ? count / denominator : null;
  const combined = new Set([...groups.deceased, ...groups.culled]);
  return {
    metric: "death_and_cull_incidence", denominatorBasis: request.denominator, denominator,
    scopeDescription: request.denominator === "opening_cohort" ? "期初在场队列在观察期内的死淘比例" : request.denominator === "period_exposed" ? "期间曾在场羊只的死淘比例" : "期内有出生日期档案的羔羊截至分析结束日的死淘比例；不是产羔事件出生总数",
    deathCount: groups.deceased.size, cullCount: groups.culled.size, deathAndCullCount: combined.size,
    soldCount: groups.sold.size, transferredOutCount: groups.transferredOut.size,
    deathRate: rate(groups.deceased.size), cullRate: rate(groups.culled.size), deathAndCullRate: rate(combined.size),
    rateUnit: "proportion", formula: "所选队列期间死亡/淘汰去重头数 ÷ 所选队列头数；出售和转出不计入死淘",
    issues: uniqueIssues, missingLinkedRemovalCount: missing.length,
    coverage: "依据当前云端可重建档案与业务记录；没有记录不代表实际未发生。不能将档案样本外推为全牧场。",
    rows: selected.slice(0, 100).map(r => ({ id: r.id, sheepID: r.sheepID, kind: r.kind, at: r.at ?? r.occurredAt })),
    recordsTruncated: selected.length > 100,
  };
}
