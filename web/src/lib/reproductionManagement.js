import { farmDateText } from "./eventExport.js";

const addMonths = (day, months) => {
  const date = new Date(`${day}T12:00:00Z`), dayOfMonth = date.getUTCDate();
  date.setUTCDate(1);
  date.setUTCMonth(date.getUTCMonth() + months);
  const last = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 0)).getUTCDate();
  date.setUTCDate(Math.min(dayOfMonth, last));
  return date.toISOString().slice(0, 10);
};

// Review scope only; the absence of breeding evidence never creates a parity fact.
export function isPreBreedingLamb(sheep, records, settings, timeZone, now) {
  const purpose = String(sheep.purpose ?? "").trim();
  const lambPurpose = purpose.includes("哺乳") || purpose.includes("断奶") && purpose.includes("羔");
  if (!lambPurpose || records.some(r => r.deletedAt == null && r.occurredAt <= now)) return false;
  const observation = sheep.removedAt == null ? now : Math.min(sheep.removedAt, now);
  if (sheep.birthAt == null || sheep.birthAt > observation) return false;
  const months = settings?.minimumAgeMonths ?? 10;
  if (!(months > 0)) return false;
  return farmDateText(observation, timeZone, false) <= addMonths(farmDateText(sheep.birthAt, timeZone, false), months);
}

// Same denominator as ReproductionManagementEngine: a reliable postpartum
// date or strictly past the configured calendar-month maturity boundary.
export function isReproductionCheckEligible(sheep, records, state, settings, timeZone, now) {
  const facts = records.filter(r => r.deletedAt == null && r.occurredAt <= now);
  const births = facts.filter(r => r.kindRawValue === "lambing")
    .sort((a, b) => a.occurredAt - b.occurredAt || a.id.localeCompare(b.id));
  const evidence = facts.filter(r => ["parityBaseline", "lambing"].includes(r.kindRawValue) && r.parity != null && r.parity >= 0)
    .sort((a, b) => a.occurredAt - b.occurredAt || (a.updatedAt ?? 0) - (b.updatedAt ?? 0) || (a.createdAt ?? 0) - (b.createdAt ?? 0) || a.id.localeCompare(b.id));
  const lastBirth = births.at(-1), parity = state.completedParity;
  const conflict = parity === 0 && lastBirth != null || parity != null && lastBirth?.parity != null && lastBirth.parity > parity;
  const missingBirth = parity != null && parity > 0 && (!lastBirth || (lastBirth.parity != null
    ? parity > lastBirth.parity : (evidence.at(-1)?.occurredAt ?? -Infinity) > lastBirth.occurredAt));
  const sameDayBirths = births.length > 1 && farmDateText(births.at(-2).occurredAt, timeZone, false) === farmDateText(lastBirth.occurredAt, timeZone, false);
  const reliablePostpartum = lastBirth != null && !missingBirth && !conflict && !sameDayBirths;
  const validBirth = sheep.birthAt != null && sheep.birthAt <= now;
  const overAge = validBirth && farmDateText(now, timeZone, false) > addMonths(farmDateText(sheep.birthAt, timeZone, false), settings.minimumAgeMonths ?? 10);
  return reliablePostpartum || overAge;
}
