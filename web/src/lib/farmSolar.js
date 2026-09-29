// NOAA's fractional-year approximation. All instants are UTC; the IANA zone
// selects the farm's calendar day and formats the resulting solar events.
const radians = (degrees) => degrees * Math.PI / 180;
const degrees = (value) => value * 180 / Math.PI;
const clamp = (value, lower = 0, upper = 1) => Math.max(lower, Math.min(upper, value));

export function validFarmLocation(latitude, longitude, timeZone) {
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude) ||
      Math.abs(latitude) > 90 || Math.abs(longitude) > 180 || !timeZone) return false;
  try { new Intl.DateTimeFormat("en", { timeZone }).format(new Date()); return true; }
  catch { return false; }
}

export function farmLocalDate(instant, timeZone) {
  if (!timeZone) return null;
  try {
    const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
      timeZone, year: "numeric", month: "2-digit", day: "2-digit",
    }).formatToParts(instant).map(({ type, value }) => [type, value]));
    return `${parts.year}-${parts.month}-${parts.day}`;
  } catch { return null; }
}

function solarTerms(year, month, day) {
  const dayOfYear = Math.floor((Date.UTC(year, month - 1, day) - Date.UTC(year, 0, 1)) / 86_400_000) + 1;
  const yearLength = (Date.UTC(year + 1, 0, 1) - Date.UTC(year, 0, 1)) / 86_400_000;
  const gamma = 2 * Math.PI / yearLength * (dayOfYear - 1 + 0.5);
  const equation = 229.18 * (0.000075 + 0.001868 * Math.cos(gamma) - 0.032077 * Math.sin(gamma)
    - 0.014615 * Math.cos(2 * gamma) - 0.040849 * Math.sin(2 * gamma));
  const declination = 0.006918 - 0.399912 * Math.cos(gamma) + 0.070257 * Math.sin(gamma)
    - 0.006758 * Math.cos(2 * gamma) + 0.000907 * Math.sin(2 * gamma)
    - 0.002697 * Math.cos(3 * gamma) + 0.00148 * Math.sin(3 * gamma);
  return { equation, declination };
}

function hourAngle(latitude, declination, zenith) {
  const latitudeRad = radians(latitude);
  const cosine = (Math.cos(radians(zenith)) - Math.sin(latitudeRad) * Math.sin(declination)) /
    (Math.cos(latitudeRad) * Math.cos(declination));
  if (cosine < -1) return { angle: null, polar: "day" };
  if (cosine > 1) return { angle: null, polar: "night" };
  return { angle: degrees(Math.acos(clamp(cosine, -1, 1))), polar: null };
}

export function calculateSolarEvents(localDate, latitude, longitude) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(localDate ?? "") || !Number.isFinite(latitude) ||
      !Number.isFinite(longitude) || Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return null;
  const [year, month, day] = localDate.split("-").map(Number);
  const { equation, declination } = solarTerms(year, month, day);
  const noonMinutes = 720 - 4 * longitude - equation;
  const horizon = hourAngle(latitude, declination, 90.833);
  const civil = hourAngle(latitude, declination, 96);
  const start = Date.UTC(year, month - 1, day);
  const instant = (minutes) => new Date(start + Math.round(minutes * 60_000)).toISOString();
  return {
    localDate, latitude, longitude, source: "calculated", polar: horizon.polar,
    dawnAt: civil.angle == null ? null : instant(noonMinutes - 4 * civil.angle),
    sunriseAt: horizon.angle == null ? null : instant(noonMinutes - 4 * horizon.angle),
    solarNoonAt: instant(noonMinutes),
    sunsetAt: horizon.angle == null ? null : instant(noonMinutes + 4 * horizon.angle),
    duskAt: civil.angle == null ? null : instant(noonMinutes + 4 * civil.angle),
  };
}

export function selectSolarEvents(snapshot, localDate, latitude, longitude) {
  const provider = snapshot?.solar;
  if (provider?.localDate === localDate && provider.source === "provider" &&
      (provider.polar || (provider.sunriseAt && provider.sunsetAt)) &&
      [provider.sunriseAt, provider.sunsetAt].every((value) => value == null || Number.isFinite(Date.parse(value)))) {
    return provider;
  }
  return calculateSolarEvents(localDate, latitude, longitude);
}

function solarElevation(instant, latitude, longitude) {
  const year = instant.getUTCFullYear();
  const month = instant.getUTCMonth() + 1;
  const day = instant.getUTCDate();
  const { equation, declination } = solarTerms(year, month, day);
  const minutes = instant.getUTCHours() * 60 + instant.getUTCMinutes() + instant.getUTCSeconds() / 60;
  const solarMinutes = ((minutes + equation + 4 * longitude) % 1440 + 1440) % 1440;
  const hourAngle = radians(solarMinutes / 4 - 180);
  const latitudeRad = radians(latitude);
  return degrees(Math.asin(Math.sin(latitudeRad) * Math.sin(declination) +
    Math.cos(latitudeRad) * Math.cos(declination) * Math.cos(hourAngle)));
}

function highLatitudeEnvironment(now, solar, condition, cloudCover) {
  const { latitude, longitude } = solar;
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
    return { phase: "unknown", light: 0.7, warmth: 0, condition: "unknown", cloudCover: null };
  }
  const elevation = solarElevation(now, latitude, longitude);
  const rising = solarElevation(new Date(+now + 10 * 60_000), latitude, longitude) > elevation;
  if (elevation < -6) return { phase: "night", light: 0.08, warmth: 0, condition, cloudCover };
  if (elevation < 0) return { phase: rising ? "dawn" : "twilight",
    light: 0.08 + 0.29 * clamp((elevation + 6) / 6), warmth: 0.15, condition, cloudCover };
  const phase = elevation >= 30 ? "noon" : rising ? "morning" : "afternoon";
  return { phase, light: 0.37 + 0.63 * clamp(elevation / 30), warmth: 0, condition, cloudCover };
}

export function resolveFarmEnvironment(now, solar, condition = "unknown", cloudCover = null) {
  if (!solar) return { phase: "unknown", light: 0.7, warmth: 0, condition: "unknown", cloudCover: null };
  if (solar.polar) return highLatitudeEnvironment(now, solar, condition, cloudCover);
  const time = +now;
  const dawn = Date.parse(solar.dawnAt ?? "");
  const sunrise = Date.parse(solar.sunriseAt ?? "");
  const noon = Date.parse(solar.solarNoonAt ?? "");
  const sunset = Date.parse(solar.sunsetAt ?? "");
  const dusk = Date.parse(solar.duskAt ?? "");
  if (![dawn, sunrise, noon, sunset, dusk].every(Number.isFinite) ||
      !(dawn <= sunrise && sunrise < noon && noon < sunset && sunset <= dusk)) {
    return highLatitudeEnvironment(now, solar, condition, cloudCover);
  }
  const daylight = sunset - sunrise;
  const morningEnd = sunrise + Math.min(75 * 60_000, daylight * 0.18);
  const noonBand = Math.min(45 * 60_000, daylight * 0.1);
  const eveningStart = sunset - Math.min(90 * 60_000, daylight * 0.2);
  let phase; let light; let warmth = 0;
  if (time < dawn || time >= dusk) { phase = "night"; light = 0.08; }
  else if (time < sunrise) { phase = "dawn"; light = 0.08 + 0.29 * clamp((time - dawn) / (sunrise - dawn)); warmth = 0.9 * clamp((time - dawn) / (sunrise - dawn)); }
  else if (time < morningEnd) { phase = "earlyMorning"; light = 0.37 + 0.5 * clamp((time - sunrise) / (morningEnd - sunrise)); warmth = 0.9 * (1 - clamp((time - sunrise) / (morningEnd - sunrise))); }
  else if (time < noon - noonBand) { phase = "morning"; light = 0.87 + 0.13 * clamp((time - morningEnd) / (noon - noonBand - morningEnd)); }
  else if (time < noon + noonBand) { phase = "noon"; light = 1; }
  else if (time < eveningStart) { phase = "afternoon"; light = 1 - 0.12 * clamp((time - noon - noonBand) / (eveningStart - noon - noonBand)); }
  else if (time < sunset) { phase = "evening"; light = 0.88 - 0.51 * clamp((time - eveningStart) / (sunset - eveningStart)); warmth = 0.9 * clamp((time - eveningStart) / (sunset - eveningStart)); }
  else { phase = "twilight"; light = 0.37 - 0.29 * clamp((time - sunset) / (dusk - sunset)); warmth = 0.9 * (1 - clamp((time - sunset) / (dusk - sunset))); }
  return { phase, light, warmth: warmth * (1 - 0.65 * clamp(cloudCover ?? 0)), condition, cloudCover };
}
