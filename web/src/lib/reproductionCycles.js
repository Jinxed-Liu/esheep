// Pure projection, mirrored by ReproductionCycleResolver.swift and shared fixtures.
// Cycle IDs are the preceding closure's immutable record ID, or the ewe ID for
// the initial cycle. No state is written by reading this module.
export const pregnancyNames = { pregnant: "检胎已孕", open: "检胎空怀", recheck: "待复检", unexamined: "本轮未检胎", uncertain: "结果待核实" };
export function classifyPregnancy(value) {
  const text = String(value ?? "").trim().toLowerCase();
  if (["已孕", "怀孕", "孕", "妊娠", "阳性", "pregnant", "positive"].includes(text)) return "pregnant";
  if (["空怀", "未孕", "未怀孕", "阴性", "不孕", "open", "negative"].includes(text)) return "open";
  if (["复检", "待复检", "疑似", "疑似怀孕", "待定", "recheck"].includes(text)) return "recheck";
  return "uncertain";
}
const order = (a, b) => a.occurredAt - b.occurredAt || a.id.localeCompare(b.id);
export function resolveReproductionState(eweID, input, asOf = Date.now()) {
  const facts = input.filter(r => r.eweID === eweID && r.deletedAt == null && r.occurredAt <= asOf).sort(order);
  const closures = facts.filter(r => ["lambing", "abortion"].includes(r.kindRawValue));
  const boundary = closures.at(-1);
  const births = facts.filter(r => r.kindRawValue === "lambing"), lastBirth = births.at(-1);
  const parityFacts = facts.filter(r => ["parityBaseline", "lambing"].includes(r.kindRawValue) && Number.isInteger(r.parity) && r.parity >= 0);
  const latestParity = parityFacts.at(-1), parity = latestParity?.parity ?? null;
  const issues = [], associations = [], roundByRecord = new Map(), roundRoots = new Map();
  if (parity == null) issues.push("缺少可确认的胎次，不能判定为未产羔");
  if (latestParity && parityFacts.some(r => r.occurredAt === latestParity.occurredAt && r.parity !== parity)) issues.push("同一时间的胎次事实冲突");
  const missingBirth = (parity ?? 0) > 0 && (!lastBirth || parity > (lastBirth.parity ?? 0));
  if (missingBirth) issues.push("已产羔，缺少对应的最近产羔日期");
  if (parity != null && lastBirth && (parity < lastBirth.parity || parity === 0)) issues.push("胎次确认与产羔记录冲突");
  const parityConflict=issues.includes("同一时间的胎次事实冲突")||issues.includes("胎次确认与产羔记录冲突");
  const cycleAnchor = !parityConflict && missingBirth && (latestParity?.occurredAt??-Infinity)>(boundary?.occurredAt??-Infinity) ? latestParity : boundary, cycleID = boundary?.id ?? eweID;
  const cycleFacts = facts.filter(r => r.kindRawValue !== "parityBaseline" && (!cycleAnchor || r.occurredAt >= cycleAnchor.occurredAt && r.id !== cycleAnchor.id));
  if (boundary && cycleFacts.some(r => r.occurredAt === boundary.occurredAt)) issues.push("繁殖事件同时发生，先后关系待核实");
  const breedings = cycleFacts.filter(r => r.kindRawValue === "breeding");
  let latestRound = null;
  for (const item of breedings) {
    let reason = "按本轮事实时间线确定归属", roundID = null;
    if (item.reproductionCycleID && item.reproductionCycleID !== cycleID) reason = "明确周期与产羔／流产时间线冲突";
    else if (item.breedingIntentRawValue === "supplement") {
      const prior = breedings.find(r => r.id === item.relatedBreedingRecordID) ?? roundRoots.get(item.relatedBreedingRecordID);
      if (prior && prior.occurredAt < item.occurredAt && roundByRecord.has(prior.id)) { roundID = roundByRecord.get(prior.id); reason = "明确关联本轮补配"; }
      else reason = "补配缺少有效的本轮配种关联";
    } else if (item.breedingIntentRawValue === "newRound") { roundID = item.breedingRoundID ?? item.id; reason = "明确开始新一轮配种"; }
    else if (breedings.length === 1 || breedings.some(r => r.breedingIntentRawValue === "supplement" && r.relatedBreedingRecordID === item.id)) roundID = item.breedingRoundID ?? item.id;
    else reason = "多条历史配种未区分补配与重新配种";
    if (item.breedingRoundID && item.breedingRoundID !== roundID) { roundID = null; reason = "明确轮次与配种关联冲突"; }
    if (roundID) { roundByRecord.set(item.id, roundID); roundByRecord.set(roundID, roundID); if (!roundRoots.has(roundID)) roundRoots.set(roundID, item); latestRound = roundID; }
    else issues.push(reason);
    associations.push({ recordID: item.id, cycleID: roundID ? cycleID : null, roundID, inferred: !item.reproductionCycleID, reason });
  }
  if (new Set(breedings.map(r => r.occurredAt)).size !== breedings.length) issues.push("同一时间存在多条配种，先后关系待核实");
  const breeding = roundRoots.get(latestRound) ?? null, checks = cycleFacts.filter(r => r.kindRawValue === "pregnancyCheck"), effectiveChecks = [];
  if(missingBirth&&!checks.length&&facts.some(r=>r.kindRawValue==="pregnancyCheck"))issues.push("胎次或最近产羔日期不足，孕检归属待核实");
  for (const item of checks) {
    let reason = "按本轮胎次及唯一时间线推导", valid = true, roundID = null;
    if (item.reproductionCycleID && item.reproductionCycleID !== cycleID) { valid = false; reason = "孕检关联周期已经结束或与日期冲突"; }
    if (item.relatedBreedingRecordID) {
      const linked = breedings.find(r => r.id === item.relatedBreedingRecordID) ?? roundRoots.get(item.relatedBreedingRecordID);
      if (linked && linked.occurredAt < item.occurredAt && roundByRecord.has(linked.id)) roundID = roundByRecord.get(linked.id);
      else { valid = false; reason = "孕检关联配种不属于该时间点的有效周期"; }
    } else if (item.breedingRoundID) {
      roundID = item.breedingRoundID;
      if (!(roundRoots.get(roundID)?.occurredAt < item.occurredAt)) { valid = false; reason = "孕检轮次不存在或晚于检查时间"; }
    } else {
      const prior = breedings.filter(r => r.occurredAt < item.occurredAt), roots = new Set(prior.map(r => roundByRecord.get(r.id)).filter(Boolean));
      if (roots.size === 1 && prior.every(r => roundByRecord.has(r.id))) roundID = [...roots][0];
      else if (prior.length) { valid = false; reason = "孕检可对应多个配种轮次，归属待核实"; }
      else if (breedings.length) { valid = false; reason = "孕检与配种先后关系待核实"; }
    }
    if (item.breedingRoundID && item.breedingRoundID !== roundID) { valid = false; reason = "孕检轮次与明确关联配种冲突"; }
    if (parity == null || missingBirth && latestParity && item.occurredAt <= latestParity.occurredAt) { valid = false; reason = "胎次或最近产羔日期不足，孕检归属待核实"; }
    if (boundary?.occurredAt === item.occurredAt) { valid = false; reason = "孕检与周期结束同时发生，先后待核实"; }
    if (valid && (roundID === latestRound || latestRound == null)) effectiveChecks.push(item);
    if (!valid) issues.push(reason);
    associations.push({ recordID: item.id, cycleID: valid ? cycleID : null, roundID: valid ? roundID : null, inferred: !item.reproductionCycleID, reason });
  }
  for (const breeding of breedings) { const previous = checks.findLast(r => r.occurredAt < breeding.occurredAt); if (previous && classifyPregnancy(previous.result) === "pregnant") issues.push("已孕后存在配种记录，须核实妊娠结果及轮次"); }
  const check = effectiveChecks.at(-1) ?? null;
  let pregnancy = check ? classifyPregnancy(check.result) : "unexamined";
  if (check) {
    if (new Set(effectiveChecks.filter(r => r.occurredAt === check.occurredAt).map(r => classifyPregnancy(r.result))).size > 1) issues.push("同一时间的孕检结果冲突");
    if (pregnancy === "uncertain") issues.push(`检胎结果无法确认：${check.result || "未填写"}`);
  }
  if (issues.some(r => r !== "已产羔，缺少对应的最近产羔日期")) pregnancy = "uncertain";
  let previous = null;
  const history = closures.map(closure => {
    const value = { id: previous?.id ?? eweID, endedAt: closure.occurredAt, outcome: closure.kindRawValue, targetParity: closure.kindRawValue === "lambing" ? closure.parity : null,
      recordIDs: facts.filter(r => r.kindRawValue !== "parityBaseline" && r.occurredAt <= closure.occurredAt && (!previous || r.occurredAt > previous.occurredAt)).map(r => r.id) };
    previous = closure; return value;
  });
  return { eweID, asOf, cycleID, completedParity: parityConflict ? null : parity, targetParity: parityConflict || parity == null ? null : parity + 1, lastLambingAt: missingBirth ? null : lastBirth?.occurredAt ?? null,
    breedingRoundID: latestRound, breeding, check, pregnancy, displayState: pregnancy === "unexamined" && breeding ? "已配待检" : pregnancyNames[pregnancy], issues: [...new Set(issues)].sort(), associations, history };
}

export function entryAssociation({ eweID, recordID, kind, occurredAt, records, relatedID, intent, expectedCycleID, expectedRoundID, excludingID, requiresExplicitRound = false }) {
  const facts = records.filter(r => r.id !== excludingID && r.deletedAt == null), state = resolveReproductionState(eweID, facts, occurredAt);
  if (expectedCycleID && expectedCycleID !== state.cycleID) throw new Error("繁殖周期已变更，请重新核对胎次和关联");
  let roundID = null;
  if (relatedID) {
    const related = facts.find(r => r.id === relatedID && r.eweID === eweID && r.kindRawValue === "breeding");
    if (!related || related.occurredAt >= occurredAt || facts.some(r => r.eweID === eweID && ["lambing", "abortion"].includes(r.kindRawValue) && r.occurredAt >= related.occurredAt && r.occurredAt <= occurredAt)) throw new Error("关联配种不属于该发生时间的有效周期");
    roundID = related.breedingRoundID ?? related.id;
  }
  if (kind === "breeding") {
    if (intent === "supplement" && !roundID) throw new Error("本轮补配必须选择关联配种");
    if (intent === "newRound") { if (relatedID) throw new Error("新一轮配种不能关联上一轮配种"); roundID = expectedRoundID ?? recordID; }
    if (!intent) roundID = expectedRoundID ?? null;
  } else if (!roundID) { const roots = new Set(state.associations.map(r => r.roundID).filter(Boolean)); if (roots.size === 1) roundID = [...roots][0]; else if(roots.size>1&&requiresExplicitRound)throw new Error("存在多个配种轮次，请明确选择关联配种"); }
  if (expectedRoundID && expectedRoundID !== roundID) throw new Error("配种轮次已变更，请重新核对关联");
  return { reproductionCycleID: state.cycleID, breedingRoundID: roundID };
}
