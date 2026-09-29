import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import test from "node:test";
import { calculateSolarEvents, farmLocalDate, resolveFarmEnvironment, selectSolarEvents } from "../src/lib/farmSolar.js";
import { createWeatherAPI, weatherKind, weatherKitToken } from "../server/weather-api.mjs";

const farmID = "00000000-0000-4000-8000-000000000001";
const location = { farmID, generation: 3, latitude: 39.9042, longitude: 116.4074,
  timeZone: "Asia/Shanghai", locationDisplayName: "北京牧场", locationRevision: "2026-09-29T01:00:00Z" };

test("WeatherKit cloud codes keep partly cloudy distinct from overcast", () => {
  assert.equal(weatherKind("PartlyCloudy"), "cloudy");
  assert.equal(weatherKind("MostlyClear"), "cloudy");
  assert.equal(weatherKind("MostlyCloudy"), "overcast");
  assert.equal(weatherKind("Cloudy"), "overcast");
  assert.equal(weatherKind("Windy"), "wind");
  assert.equal(weatherKind("Breezy"), "wind");
});

test("solar events follow longitude, farm-local date, and polar availability", () => {
  const east = calculateSolarEvents("2026-09-29", 39.9042, 116.4074);
  const west = calculateSolarEvents("2026-09-29", 39.9042, 86.4074);
  assert.ok(Date.parse(west.sunriseAt) - Date.parse(east.sunriseAt) > 100 * 60_000);
  assert.equal(farmLocalDate(new Date("2026-09-28T16:30:00Z"), "Asia/Shanghai"), "2026-09-29");
  assert.equal(farmLocalDate(new Date("2026-09-28T16:30:00Z"), "America/New_York"), "2026-09-28");
  assert.equal(calculateSolarEvents("2026-06-21", 78.2, 15.6).polar, "day");
  assert.equal(calculateSolarEvents("2026-12-21", 78.2, 15.6).polar, "night");
  const polarDay = calculateSolarEvents("2026-06-21", 78.2, 15.6);
  assert.notEqual(resolveFarmEnvironment(new Date(polarDay.solarNoonAt), polarDay).phase, "night");
  const beforeDST = calculateSolarEvents("2026-03-07", 40.7128, -74.006);
  const afterDST = calculateSolarEvents("2026-03-08", 40.7128, -74.006);
  const nyHour = (instant) => new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", hour: "numeric", hour12: false }).format(new Date(instant));
  assert.equal(nyHour(beforeDST.sunriseAt), "06");
  assert.equal(nyHour(afterDST.sunriseAt), "07");
  assert.equal(resolveFarmEnvironment(new Date(east.solarNoonAt), east).phase, "noon");
  assert.equal(selectSolarEvents({ solar: { ...east, source: "provider", localDate: "2026-09-28" } },
    "2026-09-29", 39.9042, 116.4074).source, "calculated");
  assert.equal(selectSolarEvents({ solar: { ...east, source: "provider", sunriseAt: null } },
    "2026-09-29", 39.9042, 116.4074).source, "calculated");
});

test("WeatherKit developer token has Apple's four claims and a valid ES256 signature", async () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const token = await weatherKitToken({ WEATHERKIT_TEAM_ID: "ABCDEFGHIJ", WEATHERKIT_SERVICE_ID: "com.example.weather",
    WEATHERKIT_KEY_ID: "KLMNOPQRST", WEATHERKIT_PRIVATE_KEY: privateKey.export({ format: "pem", type: "pkcs8" }) },
  Date.UTC(2026, 8, 29));
  const [header, payload, signature] = token.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url")), { alg: "ES256", kid: "KLMNOPQRST", id: "ABCDEFGHIJ.com.example.weather" });
  assert.deepEqual(Object.keys(JSON.parse(Buffer.from(payload, "base64url"))).sort(), ["exp", "iat", "iss", "sub"]);
  assert.equal(verify("sha256", Buffer.from(`${header}.${payload}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url")), true);
});

test("weather endpoint authorizes every cache hit and uses the trusted location", async () => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  let authorized = true; let authorizations = 0; let weatherCalls = 0; let locationCalls = 0; let providerAvailable = true;
  let now = Date.UTC(2026, 8, 29, 4);
  const environment = { SUPABASE_URL: "https://example.supabase.co", SUPABASE_PUBLISHABLE_KEY: "sb_publishable_example",
    WEATHERKIT_TEAM_ID: "ABCDEFGHIJ", WEATHERKIT_SERVICE_ID: "com.example.weather", WEATHERKIT_KEY_ID: "KLMNOPQRST",
    WEATHERKIT_PRIVATE_KEY: privateKey.export({ format: "pem", type: "pkcs8" }) };
  const api = createWeatherAPI({ environment, clock: () => now,
    authVerifier: async () => { authorizations += 1; if (!authorized) throw { status: 403, code: "FARM_ACCESS_DENIED", message: "禁止访问" }; },
    locationResolver: async () => { locationCalls += 1; return location; },
    fetcher: async (url) => {
      if (String(url).includes("/attribution/")) return Response.json({ serviceName: "Apple Weather", "logoLight@2x": "/logo.png", "logoDark@2x": "/logo-dark.png" });
      weatherCalls += 1;
      if (!providerAvailable) throw new Error("weather provider offline");
      return Response.json({ currentWeather: { conditionCode: "Rain", temperature: 12, temperatureApparent: 10,
        cloudCover: 0.8, windSpeed: 18, metadata: { readTime: new Date(now).toISOString(),
          expireTime: new Date(now + 30 * 60_000).toISOString(), attributionURL: "https://weatherkit.apple.com/legal-attribution.html" } },
        forecastDaily: { days: [{ forecastStart: "2026-09-29T00:00:00+08:00", sunrise: "2026-09-28T22:00:00Z",
          solarNoon: "2026-09-29T04:00:00Z", sunset: "2026-09-29T10:00:00Z",
          sunriseCivil: "2026-09-28T21:30:00Z", sunsetCivil: "2026-09-29T10:30:00Z" }] } });
    } });
  const request = () => new Request(`https://example.test/api/weather/farm?farm_id=${farmID}`, { headers: { authorization: "Bearer member" } });
  const first = await api(request());
  assert.equal(first.status, 200);
  const body = await first.json();
  assert.equal(body.current.condition, "rain");
  assert.equal(body.current.windSpeedMps, 5);
  assert.equal(body.solar.source, "provider");
  assert.equal(body.location.latitude, location.latitude);
  assert.equal(body.attribution.logoURL, "https://weatherkit.apple.com/logo.png");
  assert.equal(body.attribution.logoDarkURL, "https://weatherkit.apple.com/logo-dark.png");
  assert.equal((await api(request())).status, 200);
  assert.equal(weatherCalls, 1);
  authorized = false;
  assert.equal((await api(request())).status, 403);
  assert.equal(authorizations, 3);
  assert.equal(locationCalls, 2);
  authorized = true;
  providerAvailable = false;
  now += 16 * 60_000;
  const stale = await api(request());
  assert.equal(stale.status, 200);
  assert.equal((await stale.json()).stale, true);
  now += 20 * 60_000;
  assert.equal((await api(request())).status, 503);
});

test("unconfigured WeatherKit returns calculated sun times without invented weather", async () => {
  const api = createWeatherAPI({ environment: { SUPABASE_URL: "https://example.supabase.co", SUPABASE_PUBLISHABLE_KEY: "sb_publishable_example" },
    authVerifier: async () => {}, locationResolver: async () => location,
    clock: () => Date.UTC(2026, 8, 29, 4), fetcher: async () => { throw new Error("must not fetch"); } });
  const response = await api(new Request(`https://example.test/api/weather/farm?farm_id=${farmID}`));
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.current, null);
  assert.equal(body.solar.source, "calculated");
  assert.equal(body.code, "WEATHER_NOT_CONFIGURED");
});

test("an expired provider observation cannot become current rain", async () => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const now = Date.UTC(2026, 8, 29, 4);
  let providerCalls = 0;
  const api = createWeatherAPI({ environment: { SUPABASE_URL: "https://example.supabase.co",
    SUPABASE_PUBLISHABLE_KEY: "sb_publishable_example", WEATHERKIT_TEAM_ID: "ABCDEFGHIJ",
    WEATHERKIT_SERVICE_ID: "com.example.weather", WEATHERKIT_KEY_ID: "KLMNOPQRST",
    WEATHERKIT_PRIVATE_KEY: privateKey.export({ format: "pem", type: "pkcs8" }) },
  clock: () => now, authVerifier: async () => {}, locationResolver: async () => location,
  fetcher: async (url) => {
    if (String(url).includes("/attribution/")) {
      return Response.json({ serviceName: "Apple Weather", "logoLight@2x": "/logo.png" });
    }
    providerCalls += 1;
    return Response.json({ currentWeather: { conditionCode: "Rain", temperature: 12,
      metadata: { readTime: new Date(now - 2 * 60 * 60_000).toISOString(),
        expireTime: new Date(now - 60_000).toISOString() } }, forecastDaily: { days: [] } });
  } });
  const request = () => new Request(`https://example.test/api/weather/farm?farm_id=${farmID}`);
  const response = await api(request());
  assert.equal(response.status, 503);
  assert.equal((await response.json()).code, "WEATHER_UNAVAILABLE");
  assert.equal((await api(request())).status, 503);
  assert.equal(providerCalls, 1);
});
