import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { farmLocalDate, resolveFarmEnvironment, selectSolarEvents, validFarmLocation } from "./farmSolar.js";

const responseCache = new Map();
const preferenceKey = "esheep-web-weather-effects";
const themeKey = "esheep-web-content-theme";

function storedChoice(key, allowed, fallback) {
  try {
    const value = localStorage.getItem(key);
    return allowed.includes(value) ? value : fallback;
  } catch { return fallback; }
}

export function useEnvironmentPreferences() {
  const [effectMode, setEffectMode] = useState(() => storedChoice(preferenceKey, ["auto", "static", "off"], "auto"));
  const [contentTheme, setContentTheme] = useState(() => storedChoice(themeKey, ["system", "light", "dark"], "system"));
  const [systemDark, setSystemDark] = useState(() => typeof window !== "undefined" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  useEffect(() => {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const update = () => setSystemDark(media.matches);
    media.addEventListener?.("change", update);
    return () => media.removeEventListener?.("change", update);
  }, []);
  const changeEffectMode = useCallback((next) => {
    if (!["auto", "static", "off"].includes(next)) return;
    setEffectMode(next);
    try { localStorage.setItem(preferenceKey, next); } catch { /* storage may be disabled */ }
  }, []);
  const changeContentTheme = useCallback((next) => {
    if (!["system", "light", "dark"].includes(next)) return;
    setContentTheme(next);
    try { localStorage.setItem(themeKey, next); } catch { /* storage may be disabled */ }
  }, []);
  return { effectMode, changeEffectMode, contentTheme, changeContentTheme,
    resolvedTheme: contentTheme === "system" ? (systemDark ? "dark" : "light") : contentTheme };
}

function currentWeather(snapshot, now) {
  if (!snapshot?.current) return null;
  const observed = Date.parse(snapshot.observedAt ?? "");
  const hardExpiry = Date.parse(snapshot.providerHardExpiresAt ?? "");
  if (!Number.isFinite(observed) || +now - observed > 60 * 60_000 ||
      (Number.isFinite(hardExpiry) && +now >= hardExpiry)) return null;
  return snapshot.current;
}

export function useFarmEnvironment(farm, userID, enabled) {
  const [now, setNow] = useState(() => new Date());
  const [record, setRecord] = useState(null);
  const [detailRecord, setDetailRecord] = useState(null);
  const [error, setError] = useState("");
  const requests = useRef(new Set());
  const nextAttempt = useRef(0);
  const key = enabled && farm?.id && userID
    ? [userID, farm.id, farm.latitude, farm.longitude, farm.timeZoneIdentifier, farm.locationUpdatedAt].join("|")
    : null;
  const snapshot = record?.key === key ? record.data : null;
  const detail = detailRecord?.key === key && Date.parse(detailRecord.data.expiresAt ?? "") > +now
    ? detailRecord.data : null;

  const fetchWeather = useCallback(async (includeDetail = false) => {
    if (!key || !farm?.id || (typeof document !== "undefined" && document.hidden)) return null;
    const controller = new AbortController();
    requests.current.add(controller);
    nextAttempt.current = Date.now() + 5 * 60_000;
    try {
      const { getAssistantAccessToken } = await import("./supabase.js");
      const token = await getAssistantAccessToken();
      if (controller.signal.aborted) return null;
      const path = `/api/weather/farm?farm_id=${encodeURIComponent(farm.id)}${includeDetail ? "&detail=1" : ""}`;
      const response = await fetch(path, { headers: { authorization: `Bearer ${token}` }, signal: controller.signal });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error || "天气暂不可用。");
      if (controller.signal.aborted || body.farmID?.toLowerCase() !== farm.id.toLowerCase()) return null;
      if (includeDetail) setDetailRecord({ key, data: body });
      else {
        responseCache.set(key, body);
        setRecord({ key, data: body });
      }
      setError("");
      return body;
    } catch (cause) {
      if (!controller.signal.aborted) setError(cause.message || "天气暂不可用。");
      return null;
    } finally { requests.current.delete(controller); }
  }, [key, farm?.id]);

  useEffect(() => {
    for (const controller of requests.current) controller.abort();
    requests.current.clear();
    setError("");
    setDetailRecord(null);
    if (!key) {
      setRecord(null);
      responseCache.clear();
      return undefined;
    }
    const cached = responseCache.get(key);
    setRecord(cached ? { key, data: cached } : null);
    nextAttempt.current = 0;
    void fetchWeather();
    return () => { for (const controller of requests.current) controller.abort(); };
  }, [key, fetchWeather]);

  useEffect(() => {
    if (!key) return undefined;
    const update = () => {
      if (document.hidden) return;
      setNow(new Date());
      const latest = responseCache.get(key);
      const expiry = Date.parse(latest?.expiresAt ?? "");
      if (Date.now() >= nextAttempt.current && (!latest?.current || !Number.isFinite(expiry) || expiry <= Date.now())) {
        void fetchWeather();
      }
    };
    const timer = window.setInterval(update, 60_000);
    document.addEventListener("visibilitychange", update);
    return () => { window.clearInterval(timer); document.removeEventListener("visibilitychange", update); };
  }, [key, fetchWeather]);

  const location = snapshot?.location ?? farm ?? null;
  const latitude = Number(location?.latitude);
  const longitude = Number(location?.longitude);
  const timeZone = snapshot?.location?.timeZone ?? (farm?.hasAuthoritativeTimeZone ? farm.timeZoneIdentifier : null);
  const hasLocation = location?.latitude != null && location?.longitude != null &&
    validFarmLocation(latitude, longitude, timeZone);
  const localDate = timeZone ? farmLocalDate(now, timeZone) : null;
  const solar = hasLocation ? selectSolarEvents(snapshot, localDate, latitude, longitude) : null;
  const weather = currentWeather(snapshot, now);
  const scene = useMemo(() => resolveFarmEnvironment(now, solar, weather?.condition ?? "unknown", weather?.cloudCover),
    [now, solar?.localDate, solar?.source, solar?.sunriseAt, solar?.sunsetAt, weather?.condition, weather?.cloudCover]);
  const loadDetail = useCallback(() => fetchWeather(true), [fetchWeather]);
  return { now, timeZone, location, hasLocation, localDate, solar, weather, scene,
    snapshot, detail, error, loadDetail, refresh: () => fetchWeather(false) };
}
