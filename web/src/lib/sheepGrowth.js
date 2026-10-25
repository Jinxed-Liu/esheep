import { dailyCanonicalWeightSamples } from "./appAnalytics.js";
import { farmDateText } from "./eventExport.js";
const key = value => String(value ?? "").replaceAll("-", "").toLowerCase();
const dayNumber = (value, timeZone) => Date.parse(`${farmDateText(value, timeZone, false)}T00:00:00Z`) / 86400000;

export function buildSheepGrowth(source, sheepID, { timeZone = "Asia/Shanghai", asOf = Date.now(), dateFrom = null, dateTo = null } = {}) {
  const matches = id => key(id) === key(sheepID);
  const subset = { ...source,
    weights: (source?.weights ?? []).filter(r => matches(r.sheepID)),
    weanings: (source?.weanings ?? []).filter(r => matches(r.sheepID)),
    reproduction: (source?.reproduction ?? []).filter(r => (r.offspring ?? []).some(child => matches(child.sheepID))),
  };
  const timeline = dailyCanonicalWeightSamples(subset, timeZone, { cutoff: new Date(asOf) }).filter(r => matches(r.sheepID));
  const allIntervals = [];
  for (let i = 1; i < timeline.length; i++) {
    const start = timeline[i - 1], end = timeline[i], days = dayNumber(end.at, timeZone) - dayNumber(start.at, timeZone);
    if (days <= 0) continue;
    const gain = end.kilograms - start.kilograms;
    allIntervals.push({ id: end.id, start, end, intervalDays: days, totalGainKilograms: gain, kilogramsPerDay: gain / days, gramsPerDay: gain / days * 1000 });
  }
  const within = point => (!dateFrom || point.day >= dateFrom) && (!dateTo || point.day <= dateTo);
  const points = timeline.filter(within), intervals = allIntervals.filter(r => within(r.start) && within(r.end));
  const observationDays = intervals.reduce((sum, r) => sum + r.intervalDays, 0);
  const totalGainKilograms = intervals.reduce((sum, r) => sum + r.totalGainKilograms, 0);
  return { points, intervals, timeline, allIntervals, latest: timeline.at(-1) ?? null, latestInterval: allIntervals.at(-1) ?? null,
    observationDays, totalGainKilograms, meanGramsPerDay: observationDays ? totalGainKilograms / observationDays * 1000 : null };
}
