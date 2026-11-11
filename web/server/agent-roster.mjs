import { addFarmDays } from "../src/lib/appAnalytics.js";

export function rosterFilters(args = {}) {
  const { day = "", opening = false, penName = "", sex = "all", breed = "" } = args;
  if (Object.keys(args).some(k => !["day", "opening", "penName", "sex", "breed"].includes(k)) ||
      typeof day !== "string" || (day && (!/^\d{4}-\d{2}-\d{2}$/.test(day) || addFarmDays(day, 0) !== day)) ||
      typeof opening !== "boolean" || !["all", "ram", "ewe"].includes(sex) ||
      typeof penName !== "string" || typeof breed !== "string") {
    throw new Error("请核对名册的日期、圈舍和羊群范围。");
  }
  return { day, opening, penName: penName.trim(), breed: breed.trim(), sex };
}

export function dailyRosterEvidence(projection, farm, boundary, filters, { includeMembers = false } = {}) {
  const basis = filters.opening ? "期初" : boundary.current ? "当前" : "日末";
  const label = boundary.day + " " + basis;
  const evidence = { query_kind: "daily_herd_roster", farm_id: farm.id, farm_generation: farm.generation, day: boundary.day, basis,
    time_zone: boundary.zone, filters_applied: filters, cloud_head: projection?.revision ?? null };
  if (boundary.unavailable) return { ...evidence, count: null, text: boundary.unavailable === "future"
    ? `${boundary.day} 的在群名册尚未形成。` : `${label}缺少可核验的在群名册。` };
  const sheep = projection.models.SheepRecord ?? [];
  const pens = (projection.models.PenRecord ?? []).filter(p => p.deletedAt == null);
  const farmRecord = (projection.models.FarmRecord ?? []).find(f => f.id === farm.id.toLowerCase() && f.deletedAt == null);
  if (!farmRecord || farmRecord.timeZoneIdentifier !== boundary.zone ||
      (!boundary.current && projection.revision !== boundary.head)) throw new Error("名册版本或牧场时区校验失败。");
  const penIDs = new Set(pens.filter(p => p.name === filters.penName).map(p => p.id));
  if (filters.penName && penIDs.size !== 1) return { ...evidence, count: null, text: `${label}名册中无法唯一找到“${filters.penName}”。请核对圈舍名称。` };
  const members = sheep.filter(s => s.deletedAt == null && s.statusRawValue === "active" && !s.isHistoricalArchive &&
    (!filters.penName || penIDs.has(s.currentPenID)) && (filters.sex === "all" || s.sexRawValue === filters.sex) &&
    (!filters.breed || s.breed === filters.breed));
  const count = members.length;
  const group = [filters.penName, filters.breed, { ram: "公羊", ewe: "母羊" }[filters.sex]].filter(Boolean).join(" ");
  return { ...evidence, count, ...(includeMembers ? { memberIDs: members.map(s => s.id) } : {}), text: `${label}在群名册${group ? "（" + group + "）" : ""}共 ${count} 只。` };
}
