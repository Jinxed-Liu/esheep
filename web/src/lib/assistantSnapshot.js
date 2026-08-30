export const ASSISTANT_SNAPSHOT_SCHEMA = "esheepnext-farm-assistant/v1";
const MAX_EVENT_ROWS = 2_000;

function jsonSafe(value) {
  return value == null ? value : JSON.parse(JSON.stringify(value));
}

function compactActiveSheep(sheep = []) {
  return sheep.map((item) => ({
    id: item.id,
    earTag: item.earTag,
    breed: item.breed,
    purpose: item.purpose,
    sex: item.sexRaw ?? item.sex,
    status: item.status,
    penID: item.penID ?? item.currentPenID,
    pen: item.pen,
    birthAt: item.birthAt,
    enteredAt: item.enteredAt,
    latestWeight: item.latestWeight,
    latestWeightAt: item.latestWeightAt,
    profileIncomplete: Boolean(item.profileIncomplete),
  }));
}

export function buildAssistantSnapshot(workspace) {
  if (!workspace || workspace.mode !== "cloud" || !workspace.farm?.id) {
    throw new Error("Codex 助手只读取已登录的云端牧场，演示工作区不会生成牧场结论。");
  }
  const events = Array.isArray(workspace.events) ? workspace.events : [];
  const analyticsSource = workspace.analyticsSource ?? {};
  const capturedAt = workspace.lastSyncedAt ?? new Date().toISOString();
  return jsonSafe({
    schemaVersion: ASSISTANT_SNAPSHOT_SCHEMA,
    capturedAt,
    source: {
      kind: "supabase-rls-browser-projection",
      description: "登录用户经 Supabase RLS 读取后，按 eSheepNext App 基线、操作与当前投影语义重建的只读快照。",
      automaticDecision: false,
    },
    farm: {
      id: workspace.farm.id,
      name: workspace.farm.name,
      role: workspace.farm.role,
      roleName: workspace.farm.roleName,
      provider: workspace.farm.provider,
      generation: workspace.farm.generation,
      revision: workspace.farm.revision,
      timeZoneIdentifier: workspace.farm.timeZoneIdentifier || "Asia/Shanghai",
    },
    metrics: workspace.metrics ?? {},
    projectionCoverage: workspace.projectionCoverage ?? null,
    dataAvailability: {
      activeSheep: workspace.sheep?.length ?? 0,
      pens: workspace.pens?.length ?? 0,
      events: events.length,
      includedEvents: Math.min(events.length, MAX_EVENT_ROWS),
      weights: analyticsSource.weights?.length ?? 0,
      weanings: analyticsSource.weanings?.length ?? 0,
      reproduction: analyticsSource.reproduction?.length ?? 0,
      removals: analyticsSource.removals?.length ?? 0,
      transfers: analyticsSource.transfers?.length ?? 0,
      feeds: analyticsSource.feeds?.length ?? 0,
      eventsTruncated: events.length > MAX_EVENT_ROWS,
    },
    activeSheep: compactActiveSheep(workspace.sheep ?? []),
    pens: workspace.pens ?? [],
    events: events.slice(0, MAX_EVENT_ROWS),
    analyticsSource,
  });
}
