import { createClient } from "@supabase/supabase-js";
import { bearerToken, verifyFarmAccess } from "./auth.mjs";
import { calculateSolarEvents, farmLocalDate, validFarmLocation } from "../src/lib/farmSolar.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const FRESH_MILLISECONDS = 15 * 60_000;
const MAX_STALE_MILLISECONDS = 60 * 60_000;
const WEATHERKIT_ORIGIN = "https://weatherkit.apple.com";

function json(value, status = 200) {
  return Response.json(value, { status, headers: { "cache-control": "no-store" } });
}

function numberOrNull(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function safeURL(value, origin = undefined) {
  try {
    const url = new URL(value, origin);
    return url.protocol === "https:" ? url.href : null;
  } catch { return null; }
}

function base64URL(bytes) {
  const binary = Array.from(bytes, (byte) => String.fromCharCode(byte)).join("");
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

export async function weatherKitToken(environment, now = Date.now()) {
  const team = environment.WEATHERKIT_TEAM_ID;
  const service = environment.WEATHERKIT_SERVICE_ID;
  const keyID = environment.WEATHERKIT_KEY_ID;
  const pem = String(environment.WEATHERKIT_PRIVATE_KEY ?? "").replace(/\\n/g, "\n");
  if (!team || !service || !keyID || !pem) return null;
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----|\s/g, "")), (character) => character.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const encoder = new TextEncoder();
  const head = base64URL(encoder.encode(JSON.stringify({ alg: "ES256", kid: keyID, id: `${team}.${service}` })));
  const payload = base64URL(encoder.encode(JSON.stringify({ iss: team, iat: Math.floor(now / 1000), exp: Math.floor(now / 1000) + 3600, sub: service })));
  const signingInput = `${head}.${payload}`;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(signingInput));
  return `${signingInput}.${base64URL(new Uint8Array(signature))}`;
}

export function weatherKind(code) {
  const text = String(code ?? "").toLowerCase();
  if (/thunder/.test(text)) return "thunder";
  if (/sleet|freezingrain|mixed/.test(text)) return "sleet";
  if (/snow|blizzard|flurr/.test(text)) return "snow";
  if (/rain|drizzle|showers/.test(text)) return "rain";
  if (/fog|haze|smoke|mist/.test(text)) return "fog";
  if (/breezy|windy/.test(text)) return "wind";
  if (/partlycloudy|mostlyclear/.test(text)) return "cloudy";
  if (/mostlycloudy|overcast|cloudy/.test(text)) return "overcast";
  if (/clear|sunny/.test(text)) return "clear";
  return "unknown";
}

async function resolveLocation(request, farmID, config) {
  const token = bearerToken(request);
  const client = createClient(config.supabaseURL, config.supabasePublishableKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data, error } = await client.rpc("esheep_cloud_weather_location_v1", { p_farm_id: farmID });
  if (error) throw { status: 503, code: "LOCATION_LOOKUP_UNAVAILABLE", message: "暂时无法读取牧场位置。" };
  return data;
}

function normalizeWeather(raw, location, detail, now, attribution) {
  const zone = location.timeZone;
  const localDate = farmLocalDate(new Date(now), zone);
  const current = raw.currentWeather;
  const metadata = current?.metadata ?? {};
  const day = raw.forecastDaily?.days?.find((candidate) => farmLocalDate(new Date(candidate.forecastStart), zone) === localDate);
  const computed = calculateSolarEvents(localDate, location.latitude, location.longitude);
  const providerSolar = day && ["sunrise", "sunset", "solarNoon", "sunriseCivil", "sunsetCivil"].every(
    (key) => day[key] == null || Number.isFinite(Date.parse(day[key]))) &&
    (computed?.polar || (day.sunrise && day.sunset))
    ? {
        localDate, latitude: location.latitude, longitude: location.longitude,
        source: "provider", polar: computed?.polar ?? null,
        dawnAt: day.sunriseCivil ?? computed?.dawnAt ?? null,
        sunriseAt: day.sunrise ?? null,
        solarNoonAt: day.solarNoon ?? computed?.solarNoonAt ?? null,
        sunsetAt: day.sunset ?? null,
        duskAt: day.sunsetCivil ?? computed?.duskAt ?? null,
      }
    : computed;
  const observedAt = metadata.reportedTime ?? metadata.readTime ?? current?.asOf ?? null;
  const hardExpires = Number.isFinite(Date.parse(metadata.expireTime ?? "")) ? metadata.expireTime : null;
  const expiresAt = new Date(Math.min(now + FRESH_MILLISECONDS, hardExpires ? Date.parse(hardExpires) : Infinity)).toISOString();
  const hourly = detail ? (raw.forecastHourly?.hours ?? []).slice(0, 24).map((hour) => ({
    at: hour.forecastStart, condition: weatherKind(hour.conditionCode), temperatureC: numberOrNull(hour.temperature),
    precipitationChance: numberOrNull(hour.precipitationChance),
  })) : [];
  const daily = detail ? (raw.forecastDaily?.days ?? []).slice(0, 7).map((forecast) => ({
    at: forecast.forecastStart, condition: weatherKind(forecast.conditionCode),
    minC: numberOrNull(forecast.temperatureMin), maxC: numberOrNull(forecast.temperatureMax),
    precipitationChance: numberOrNull(forecast.precipitationChance),
  })) : [];
  return {
    farmID: location.farmID, locationRevision: location.locationRevision, location,
    localDate, fetchedAt: new Date(now).toISOString(), observedAt, expiresAt,
    providerHardExpiresAt: hardExpires, source: "WeatherKit", stale: false,
    current: current && !metadata.temporarilyUnavailable ? {
      condition: weatherKind(current.conditionCode), conditionCode: current.conditionCode ?? null,
      temperatureC: numberOrNull(current.temperature), feelsLikeC: numberOrNull(current.temperatureApparent),
      cloudCover: numberOrNull(current.cloudCover),
      precipitationIntensity: numberOrNull(current.precipitationIntensity),
      windSpeedMps: numberOrNull(current.windSpeed) == null ? null : current.windSpeed / 3.6,
      windDirectionDeg: numberOrNull(current.windDirection), humidity: numberOrNull(current.humidity),
      visibilityM: numberOrNull(current.visibility),
    } : null,
    solar: providerSolar,
    hourly, daily,
    availability: { current: Boolean(current && !metadata.temporarilyUnavailable), hourly: detail && Boolean(raw.forecastHourly),
      daily: detail && Boolean(raw.forecastDaily), alerts: false },
    attribution: {
      serviceName: attribution?.serviceName ?? "Apple Weather",
      logoURL: safeURL(attribution?.["logoLight@2x"] ?? attribution?.["logoLight@1x"], WEATHERKIT_ORIGIN),
      legalURL: safeURL(metadata.attributionURL) ?? "https://weatherkit.apple.com/legal-attribution.html",
    },
  };
}

export function createWeatherAPI({ environment = null, authVerifier = verifyFarmAccess,
  locationResolver = resolveLocation, fetcher = fetch, clock = () => Date.now() } = {}) {
  const cache = new Map();
  const pending = new Map();
  const retryAfter = new Map();
  let attributionCache = null;
  return async function weatherAPI(request, runtimeEnvironment = environment ?? process.env) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/api/weather/")) return null;
    if (url.pathname !== "/api/weather/farm" || request.method !== "GET") return json({ code: "NOT_FOUND" }, 404);
    const farmID = url.searchParams.get("farm_id") ?? "";
    const detail = url.searchParams.get("detail") === "1";
    if (!UUID.test(farmID)) return json({ error: "牧场标识无效。", code: "INVALID_FARM_ID" }, 400);
    const config = {
      supabaseURL: runtimeEnvironment.SUPABASE_URL ?? runtimeEnvironment.VITE_SUPABASE_URL,
      supabasePublishableKey: runtimeEnvironment.SUPABASE_PUBLISHABLE_KEY ?? runtimeEnvironment.VITE_SUPABASE_PUBLISHABLE_KEY,
    };
    if (!config.supabaseURL || !config.supabasePublishableKey) return json({ error: "牧场权限服务未配置。", code: "ACCESS_NOT_CONFIGURED" }, 503);
    try {
      await authVerifier({ request, farmID, config });
      const location = await locationResolver(request, farmID, config);
      if (!location) return json({ error: "当前牧场尚不支持服务端天气位置读取。", code: "LOCATION_UNAVAILABLE" }, 422);
      const latitude = numberOrNull(location.latitude);
      const longitude = numberOrNull(location.longitude);
      if (!validFarmLocation(latitude, longitude, location.timeZone)) {
        return json({ error: "请先设置有效的牧场位置和时区。", code: "LOCATION_NOT_SET" }, 422);
      }
      const normalizedLocation = { ...location, farmID, latitude, longitude };
      const now = clock();
      const localDate = farmLocalDate(new Date(now), location.timeZone);
      const key = [farmID, location.generation, location.locationRevision, latitude, longitude,
        location.timeZone, detail, localDate].join(":");
      const cached = cache.get(key);
      if (cached && Date.parse(cached.expiresAt) > now) return json(cached);
      const unavailable = (at) => {
        const observed = Date.parse(cached?.observedAt ?? "");
        const hardExpires = Date.parse(cached?.providerHardExpiresAt ?? "");
        if (cached && Number.isFinite(observed) && at - observed <= MAX_STALE_MILLISECONDS &&
            Number.isFinite(hardExpires) && at < hardExpires) {
          return json({ ...cached, stale: true, expiresAt: new Date(at + 60_000).toISOString() });
        }
        return json({ farmID, location: normalizedLocation, localDate,
          solar: calculateSolarEvents(localDate, latitude, longitude), current: null,
          error: "天气暂不可用。", code: "WEATHER_UNAVAILABLE" }, 503);
      };
      const token = await weatherKitToken(runtimeEnvironment, now);
      if (!token) return json({ farmID, location: normalizedLocation, localDate,
        solar: calculateSolarEvents(localDate, latitude, longitude), current: null,
        error: "天气服务尚未配置。", code: "WEATHER_NOT_CONFIGURED" });
      if ((retryAfter.get(key) ?? 0) > now) return unavailable(now);
      if (!pending.has(key)) pending.set(key, (async () => {
        const base = `${WEATHERKIT_ORIGIN}/api/v1/weather/zh-CN/${latitude}/${longitude}`;
        const weatherURL = new URL(base);
        weatherURL.searchParams.set("timezone", location.timeZone);
        weatherURL.searchParams.set("dataSets", detail ? "currentWeather,forecastDaily,forecastHourly" : "currentWeather,forecastDaily");
        const signal = AbortSignal.timeout(12_000);
        const attributionPromise = attributionCache && attributionCache.expiresAt > now
          ? Promise.resolve(attributionCache.data)
          : fetcher(`${WEATHERKIT_ORIGIN}/attribution/zh-CN`, { headers: { authorization: `Bearer ${token}` }, signal })
            .then(async (response) => {
              if (!response.ok) throw new Error("WeatherKit attribution unavailable");
              const data = await response.json();
              attributionCache = { data, expiresAt: now + 24 * 60 * 60_000 };
              return data;
            });
        const [weatherResponse, attribution] = await Promise.all([
          fetcher(weatherURL, { headers: { authorization: `Bearer ${token}` }, signal }), attributionPromise,
        ]);
        if (!weatherResponse.ok) throw new Error(`WeatherKit HTTP ${weatherResponse.status}`);
        const payload = normalizeWeather(await weatherResponse.json(), normalizedLocation, detail, clock(), attribution);
        const validatedAt = clock();
        const observed = Date.parse(payload.observedAt ?? "");
        const hardExpires = Date.parse(payload.providerHardExpiresAt ?? "");
        if (!payload.current || !Number.isFinite(observed) || validatedAt - observed > MAX_STALE_MILLISECONDS ||
            !Number.isFinite(hardExpires) || hardExpires <= validatedAt ||
            !payload.attribution.logoURL) throw new Error("WeatherKit data incomplete or expired");
        cache.set(key, payload);
        if (cache.size > 256) cache.delete(cache.keys().next().value);
        retryAfter.delete(key);
        return payload;
      })().finally(() => pending.delete(key)));
      try { return json(await pending.get(key)); }
      catch {
        const failedAt = clock();
        retryAfter.set(key, failedAt + 60_000);
        if (retryAfter.size > 256) retryAfter.delete(retryAfter.keys().next().value);
        return unavailable(failedAt);
      }
    } catch (error) {
      const status = [400, 401, 403, 422, 502, 503].includes(error?.status) ? error.status : 503;
      return json({ error: error?.message && status !== 503 ? error.message : "暂时无法核对牧场天气。",
        code: error?.code ?? "WEATHER_UNAVAILABLE" }, status);
    }
  };
}
