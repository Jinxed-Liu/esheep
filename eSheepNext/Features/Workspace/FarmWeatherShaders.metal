#include <metal_stdlib>
using namespace metal;

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float2 hash22(float2 p) {
    float n = hash21(p);
    return float2(n, hash21(p + n + 37.17));
}

static float noise2(float2 p) {
    float2 cell = floor(p);
    float2 local = fract(p);
    float2 curve = local * local * (3.0 - 2.0 * local);
    return mix(
        mix(hash21(cell), hash21(cell + float2(1.0, 0.0)), curve.x),
        mix(hash21(cell + float2(0.0, 1.0)), hash21(cell + 1.0), curve.x),
        curve.y
    );
}

static float fbm4(float2 p) {
    float value = 0.0;
    float amplitude = 0.53;
    for (int octave = 0; octave < 4; octave++) {
        value += noise2(p) * amplitude;
        p = p * 2.07 + float2(9.2, 5.7);
        amplitude *= 0.48;
    }
    return value;
}

static float gaussianBand(float value, float center, float width) {
    float normalized = (value - center) / max(width, 0.001);
    return exp(-normalized * normalized);
}

static float weatherModeWeight(float mode, float center) {
    return saturate(1.0 - abs(mode - center));
}

static float cloudField(float2 p, float time, float scale, float speed, float seed) {
    float2 q = p * scale + float2(-time * speed, seed);
    float warp = noise2(q * 0.47 + float2(seed * 1.7, 4.1));
    float body = fbm4(q + float2(warp * 0.82, warp * 0.24));
    float detail = noise2(q * 2.35 - float2(time * speed * 0.31, seed * 2.1));
    return body * 0.86 + detail * 0.14;
}

static float cloudMask(float field, float coverage, float softness) {
    return smoothstep(coverage - softness, coverage + softness, field);
}

static float starField(float2 uv, float time) {
    float2 grid = floor(uv * float2(126.0, 82.0));
    float seed = hash21(grid);
    float2 local = fract(uv * float2(126.0, 82.0)) - 0.5;
    float radius = mix(0.085, 0.19, hash21(grid + 11.4));
    float point = 1.0 - smoothstep(radius * 0.25, radius, length(local));
    float exists = step(0.978, seed);
    float twinkle = 0.58 + 0.42 * sin(time * mix(0.7, 2.0, seed) + seed * 37.0);
    return point * exists * twinkle * (1.0 - smoothstep(0.04, 0.78, uv.y));
}

static float cirrusField(float2 uv, float time) {
    float2 p = float2(uv.x * 2.2 - time * 0.006, uv.y * 8.0);
    p.x += sin(uv.y * 10.0 + time * 0.018) * 0.18;
    float veil = fbm4(p);
    float strands = fbm4(float2(p.x * 1.7, p.y * 0.52 + 17.0));
    return smoothstep(0.61, 0.79, veil * 0.68 + strands * 0.32);
}

struct RainSample {
    float core;
    float halo;
};

static RainSample rainLayer(
    float2 uv,
    float time,
    float columns,
    float rows,
    float screenSpeed,
    float slant,
    float length,
    float width,
    float density,
    float seed,
    float depthBlur
) {
    float gust = sin(time * 0.37 + seed) * 0.016;
    gust += (noise2(float2(time * 0.055, seed * 0.31)) - 0.5) * 0.10;
    float shearedX = uv.x + (uv.y - 0.5) * (slant + gust);
    shearedX += sin(uv.y * 9.0 + time * 0.41 + seed) * 0.004;

    float column = floor(shearedX * columns);
    float columnRandom = hash21(float2(column, seed * 11.7));
    float fallSpeed = screenSpeed * mix(0.78, 1.24, columnRandom);
    float rowPosition = (uv.y - time * fallSpeed) * rows;
    float row = floor(rowPosition);
    float rowOffset = mix(-6.0, 6.0, hash21(float2(row, seed * 43.1)));
    float2 gridPosition = float2(shearedX * columns + rowOffset, rowPosition);
    float2 cell = floor(gridPosition);
    float2 local = fract(gridPosition);
    float spawn = hash21(cell + float2(seed * 17.3, seed * 31.7));
    float2 variation = hash22(cell + float2(seed * 7.1, 19.4));
    float opacity = hash21(cell + float2(5.3, seed * 53.1));

    float rainBand = noise2(float2(uv.x * 2.3 - time * 0.045, uv.y * 1.15 + seed * 2.7));
    float localDensity = density * mix(0.72, 1.18, rainBand);
    float exists = smoothstep(1.0 - localDensity, 1.0 - localDensity + 0.08, spawn);

    float dropLength = length * mix(0.62, 1.18, variation.y);
    float head = mix(0.68, 0.96, hash21(cell + float2(seed * 3.7, 71.2)));
    float tail = head - dropLength;
    float body = smoothstep(tail - 0.035, tail + 0.035, local.y);
    body *= 1.0 - smoothstep(head - 0.025, head + 0.045, local.y);

    float progress = saturate((local.y - tail) / max(dropLength, 0.001));
    float taperedWidth = width * mix(0.24, 1.0, pow(progress, 0.58));
    float centerX = mix(0.16, 0.84, variation.x);
    centerX += sin(time * 1.7 + cell.y * 0.73 + seed) * 0.012 * depthBlur;
    float distanceX = local.x - centerX;
    float core = exp(-pow(distanceX / max(taperedWidth, 0.001), 2.0)) * body;
    float haloWidth = taperedWidth * mix(2.5, 4.4, depthBlur);
    float halo = exp(-pow(distanceX / max(haloWidth, 0.001), 2.0)) * body;
    float headSpark = exp(-pow((local.y - head) / 0.032, 2.0)) * core;

    RainSample result;
    result.core = exists * (core * mix(0.34, 1.0, opacity) + headSpark * 0.16);
    result.halo = exists * halo * mix(0.28, 0.72, opacity);
    return result;
}

struct SnowSample {
    float core;
    float glow;
};

static SnowSample snowLayer(
    float2 uv,
    float time,
    float columns,
    float rows,
    float screenSpeed,
    float radius,
    float density,
    float sway,
    float seed,
    float crystalAmount
) {
    float column = floor(uv.x * columns);
    float columnRandom = hash21(float2(column, seed * 7.3));
    float speedVariation = mix(0.76, 1.28, columnRandom);
    float coherentWind = sin(time * mix(0.31, 0.52, columnRandom) + column * 0.73 + seed);
    coherentWind += (noise2(float2(time * 0.065, seed)) - 0.5) * 1.1;
    float warpedX = uv.x + coherentWind * sway;
    float2 gridPosition = float2(warpedX * columns, (uv.y - time * screenSpeed * speedVariation) * rows);
    float2 cell = floor(gridPosition);
    float2 local = fract(gridPosition);
    float2 center = mix(float2(0.18), float2(0.82), hash22(cell + seed * 13.7));
    float spawn = hash21(cell + float2(seed * 5.7, 31.1));
    float size = radius * mix(0.60, 1.30, hash21(cell + 73.4));
    float2 delta = local - center;
    float distance = length(delta);
    float angle = atan2(delta.y, delta.x) + time * mix(-0.35, 0.42, hash21(cell + 9.3));
    float disc = 1.0 - smoothstep(size * 0.30, size, distance);
    float spokeDistance = abs(sin(angle * 3.0));
    float spokes = (1.0 - smoothstep(0.07, 0.30, spokeDistance));
    spokes *= 1.0 - smoothstep(size * 0.20, size * 1.12, distance);
    float flake = max(disc, spokes * crystalAmount);
    float glow = exp(-pow(distance / max(size * 2.15, 0.001), 2.0));

    float snowBand = noise2(float2(uv.x * 1.8 + time * 0.018, uv.y * 1.25 + seed));
    float localDensity = density * mix(0.72, 1.16, snowBand);
    float exists = smoothstep(1.0 - localDensity, 1.0 - localDensity + 0.075, spawn);
    float shimmer = 0.76 + 0.24 * sin(time * 1.4 + hash21(cell + 33.0) * 17.0);

    SnowSample result;
    result.core = exists * flake * shimmer;
    result.glow = exists * glow * mix(0.35, 0.78, shimmer);
    return result;
}

static float fogLayer(float2 uv, float time, float altitude, float width, float speed, float seed) {
    float2 p = float2(uv.x * 1.55 - time * speed, uv.y * 4.8 + seed);
    p.y += sin(uv.x * 3.4 + time * speed * 2.0 + seed) * 0.18;
    float structure = noise2(p) * 0.68 + noise2(p * 2.07 + 5.4) * 0.32;
    float detail = noise2(p * 3.1 + float2(seed, -time * speed));
    float band = gaussianBand(uv.y, altitude, width);
    return band * smoothstep(0.32, 0.78, structure * 0.82 + detail * 0.18);
}

static float airborneParticleLayer(
    float2 uv,
    float time,
    float columns,
    float rows,
    float speed,
    float radius,
    float density,
    float turbulence,
    float seed
) {
    float windWave = sin(uv.x * 8.0 - time * speed * 2.4 + seed) * turbulence;
    float2 gridPosition = float2(
        (uv.x - time * speed) * columns,
        (uv.y + windWave) * rows
    );
    float2 cell = floor(gridPosition);
    float2 local = fract(gridPosition);
    float2 center = mix(float2(0.14), float2(0.86), hash22(cell + seed * 17.3));
    float spawn = hash21(cell + float2(seed * 13.1, 37.0));
    float size = radius * mix(0.58, 1.32, hash21(cell + 61.7));
    float particle = 1.0 - smoothstep(size * 0.22, size, length(local - center));
    float exists = smoothstep(1.0 - density, 1.0 - density + 0.07, spawn);
    return particle * exists;
}

static float windStreakLayer(
    float2 uv,
    float time,
    float speed,
    float density,
    float width,
    float seed
) {
    float2 gridPosition = float2(
        (uv.x - time * speed) * 14.0,
        (uv.y + sin(uv.x * 9.0 - time * speed * 1.8 + seed) * 0.018) * 11.0
    );
    float2 cell = floor(gridPosition);
    float2 local = fract(gridPosition);
    float spawn = hash21(cell + float2(seed * 7.1, 23.0));
    float centerY = mix(0.20, 0.80, hash21(cell + seed * 19.7));
    centerY += sin(local.x * 3.14159265 + time * 0.7 + seed) * 0.055;
    float line = exp(-pow((local.y - centerY) / max(width, 0.001), 2.0));
    float body = smoothstep(0.02, 0.18, local.x) * (1.0 - smoothstep(0.68, 0.98, local.x));
    float exists = smoothstep(1.0 - density, 1.0 - density + 0.08, spawn);
    return line * body * exists;
}

static float lightningBolt(float2 uv, float strikeIndex) {
    float origin = 0.18 + hash21(float2(strikeIndex, 17.3)) * 0.64;
    float yCell = floor(uv.y * 22.0);
    float jag = (hash21(float2(yCell, strikeIndex + 4.7)) - 0.5) * 0.075;
    jag += sin(uv.y * 47.0 + strikeIndex) * 0.009;
    float trunkX = origin + jag;
    float trunk = 1.0 - smoothstep(0.0018, 0.010, abs(uv.x - trunkX));
    trunk *= smoothstep(0.08, 0.16, uv.y) * (1.0 - smoothstep(0.70, 0.82, uv.y));

    float branchStart = 0.30 + hash21(float2(strikeIndex, 63.1)) * 0.20;
    float branchDirection = hash21(float2(strikeIndex, 8.9)) > 0.5 ? 1.0 : -1.0;
    float branchX = origin + branchDirection * (uv.y - branchStart) * 0.48;
    branchX += sin(uv.y * 59.0 + strikeIndex * 2.0) * 0.013;
    float branch = 1.0 - smoothstep(0.0014, 0.008, abs(uv.x - branchX));
    branch *= smoothstep(branchStart - 0.015, branchStart + 0.025, uv.y);
    branch *= 1.0 - smoothstep(branchStart + 0.20, branchStart + 0.28, uv.y);
    return saturate(trunk + branch * 0.72);
}

[[ stitchable ]] half4 farmWeatherBackground(
    float2 position,
    half4 sourceColor,
    float2 size,
    float time,
    float mode,
    float daylight,
    float intensity,
    float cloudCover,
    float wind
) {
    (void)sourceColor;
    float2 uv = position / max(size, float2(1.0));
    float aspect = size.x / max(size.y, 1.0);
    float2 p = float2((uv.x - 0.5) * aspect, uv.y - 0.5);
    float t = fmod(time, 1800.0);

    float isClear = weatherModeWeight(mode, 0.0);
    float isPartlyCloudy = weatherModeWeight(mode, 1.0);
    float isCloudy = weatherModeWeight(mode, 2.0);
    float isRain = weatherModeWeight(mode, 3.0);
    float isSnow = weatherModeWeight(mode, 4.0);
    float isStorm = weatherModeWeight(mode, 5.0);
    float isFog = weatherModeWeight(mode, 6.0);
    float isHaze = weatherModeWeight(mode, 7.0);
    float isWind = weatherModeWeight(mode, 8.0);
    float isDust = weatherModeWeight(mode, 9.0);
    float isFreezingRain = weatherModeWeight(mode, 10.0);
    float isSleet = weatherModeWeight(mode, 11.0);
    float isHail = weatherModeWeight(mode, 12.0);
    float isBlowingSnow = weatherModeWeight(mode, 13.0);
    float isSunRain = weatherModeWeight(mode, 14.0);
    float isSunSnow = weatherModeWeight(mode, 15.0);
    float isTropicalStorm = weatherModeWeight(mode, 16.0);
    float isHeat = weatherModeWeight(mode, 17.0);
    float isFrigid = weatherModeWeight(mode, 18.0);
    float isSmoke = weatherModeWeight(mode, 19.0);
    float isBlizzard = weatherModeWeight(mode, 20.0);

    float effectIntensity = saturate(intensity);
    float normalizedCloudCover = saturate(cloudCover);
    float normalizedWind = saturate(wind);
    float rainWeather = saturate(
        isRain + isStorm + isFreezingRain + isSleet * 0.62 + isHail * 0.34
        + isSunRain + isTropicalStorm
    );
    float snowWeather = saturate(
        isSnow + isSleet * 0.62 + isBlowingSnow + isSunSnow + isBlizzard
        + isFrigid * 0.10
    );
    float iceWeather = saturate(isFreezingRain + isSleet + isHail + isFrigid * 0.30);
    float lightningWeather = saturate(isStorm + isTropicalStorm * 0.58);
    float windWeather = saturate(isWind + isDust + isBlowingSnow + isTropicalStorm + isBlizzard);
    float obscuredWeather = saturate(
        isFog + isHaze * 0.76 + isSmoke * 0.88 + isDust * 0.64
    );

    // Each state starts from its own atmosphere instead of recoloring one generic gradient.
    float3 clearTop = float3(0.018, 0.19, 0.55);
    float3 clearBottom = float3(0.14, 0.63, 0.88);
    float3 cloudyTop = float3(0.10, 0.25, 0.41);
    float3 cloudyBottom = float3(0.32, 0.53, 0.65);
    float3 rainTop = float3(0.018, 0.055, 0.11);
    float3 rainBottom = float3(0.07, 0.24, 0.31);
    float3 snowTop = float3(0.16, 0.25, 0.35);
    float3 snowBottom = float3(0.48, 0.62, 0.68);
    float3 fogTop = float3(0.18, 0.28, 0.34);
    float3 fogBottom = float3(0.50, 0.63, 0.64);
    float3 hazeTop = float3(0.30, 0.34, 0.34);
    float3 hazeBottom = float3(0.64, 0.62, 0.53);
    float3 smokeTop = float3(0.16, 0.19, 0.22);
    float3 smokeBottom = float3(0.41, 0.42, 0.39);
    float3 dustTop = float3(0.29, 0.22, 0.16);
    float3 dustBottom = float3(0.68, 0.49, 0.29);
    float3 tropicalTop = float3(0.010, 0.032, 0.060);
    float3 tropicalBottom = float3(0.035, 0.17, 0.19);
    float3 heatTop = float3(0.075, 0.23, 0.58);
    float3 heatBottom = float3(0.95, 0.49, 0.22);
    float3 frigidTop = float3(0.09, 0.18, 0.31);
    float3 frigidBottom = float3(0.56, 0.75, 0.83);
    float3 partlyTop = mix(clearTop, cloudyTop, 0.40);
    float3 partlyBottom = mix(clearBottom, cloudyBottom, 0.34);
    float3 mixedTop = mix(rainTop, snowTop, 0.55);
    float3 mixedBottom = mix(rainBottom, snowBottom, 0.55);
    float3 windTop = mix(clearTop, cloudyTop, max(normalizedCloudCover, 0.24));
    float3 windBottom = mix(clearBottom, cloudyBottom, max(normalizedCloudCover, 0.24));

    float3 dayTop =
        clearTop * isClear
        + partlyTop * isPartlyCloudy
        + cloudyTop * isCloudy
        + rainTop * (isRain + isStorm)
        + snowTop * isSnow
        + fogTop * isFog
        + hazeTop * isHaze
        + windTop * isWind
        + dustTop * isDust
        + mixedTop * (isFreezingRain + isSleet + isHail)
        + snowTop * isBlowingSnow
        + mix(clearTop, rainTop, 0.42) * isSunRain
        + mix(clearTop, snowTop, 0.40) * isSunSnow
        + tropicalTop * isTropicalStorm
        + heatTop * isHeat
        + frigidTop * isFrigid
        + smokeTop * isSmoke
        + mix(snowTop, tropicalTop, 0.40) * isBlizzard;
    float3 dayBottom =
        clearBottom * isClear
        + partlyBottom * isPartlyCloudy
        + cloudyBottom * isCloudy
        + rainBottom * (isRain + isStorm)
        + snowBottom * isSnow
        + fogBottom * isFog
        + hazeBottom * isHaze
        + windBottom * isWind
        + dustBottom * isDust
        + mixedBottom * (isFreezingRain + isSleet + isHail)
        + snowBottom * isBlowingSnow
        + mix(clearBottom, rainBottom, 0.38) * isSunRain
        + mix(clearBottom, snowBottom, 0.36) * isSunSnow
        + tropicalBottom * isTropicalStorm
        + heatBottom * isHeat
        + frigidBottom * isFrigid
        + smokeBottom * isSmoke
        + mix(snowBottom, tropicalBottom, 0.34) * isBlizzard;

    float nightObscurity = saturate(
        isCloudy + rainWeather + snowWeather + obscuredWeather + isTropicalStorm + isBlizzard
    );
    float3 nightTop = mix(float3(0.004, 0.010, 0.042), float3(0.014, 0.035, 0.075), nightObscurity);
    float3 nightBottom = mix(float3(0.025, 0.080, 0.16), float3(0.045, 0.12, 0.17), nightObscurity);
    nightTop = mix(nightTop, float3(0.16, 0.10, 0.055), isDust * 0.46);
    nightBottom = mix(nightBottom, float3(0.25, 0.16, 0.09), isDust * 0.52);
    float horizon = pow(saturate(uv.y), mix(0.72, 0.98, saturate(rainWeather + obscuredWeather)));
    float3 color = mix(mix(nightTop, nightBottom, horizon), mix(dayTop, dayBottom, horizon), daylight);

    float horizonHaze = gaussianBand(uv.y, 0.72, mix(0.18, 0.34, obscuredWeather));
    color += horizonHaze * mix(float3(0.025, 0.07, 0.09), float3(0.055, 0.10, 0.09), daylight);

    // Clear and partly cloudy states have a broad light source; rain, snow and fog only keep diffuse sky glow.
    float sunVisibility = saturate(
        isClear + isHeat + isPartlyCloudy * 0.58 + isSunRain * 0.72 + isSunSnow * 0.72
        + isWind * (1.0 - normalizedCloudCover) * 0.62
    );
    float2 sunPosition = float2(aspect * 0.27, -0.27);
    float sunDistance = length(p - sunPosition);
    if (daylight > 0.5) {
        float innerBloom = exp(-sunDistance * 12.0);
        float outerBloom = exp(-sunDistance * 3.8);
        float core = 1.0 - smoothstep(0.017, 0.045, sunDistance);
        color += float3(1.0, 0.70, 0.35) * outerBloom * 0.16 * sunVisibility;
        color += float3(1.0, 0.89, 0.67) * innerBloom * 0.48 * sunVisibility;
        color = mix(color, float3(1.0, 0.97, 0.86), core * sunVisibility);
    } else {
        float moonVisibility = saturate(
            isClear + isPartlyCloudy * 0.42 + isWind * (1.0 - normalizedCloudCover) * 0.48
        );
        float2 moonPosition = float2(aspect * 0.25, -0.25);
        float moonDistance = length(p - moonPosition);
        float moonDisc = 1.0 - smoothstep(0.036, 0.052, moonDistance);
        float moonCut = 1.0 - smoothstep(0.034, 0.050, length(p - moonPosition - float2(0.023, -0.012)));
        color += float3(0.25, 0.38, 0.70) * exp(-moonDistance * 5.5) * 0.30 * moonVisibility;
        color = mix(color, float3(0.84, 0.91, 1.0), moonDisc * (1.0 - moonCut * 0.90) * moonVisibility);
        color += starField(uv, t) * float3(0.68, 0.80, 1.0) * saturate(isClear + isFrigid * 0.55);
    }

    // Thin high-altitude motion gives clear weather life without fake radial rays.
    float cirrusPresence = saturate(isClear + isPartlyCloudy * 0.72 + isHeat * 0.36 + isWind * 0.50);
    if (cirrusPresence > 0.001) {
        float cirrus = cirrusField(uv, t) * cirrusPresence * smoothstep(0.02, 0.18, uv.y) * (1.0 - smoothstep(0.58, 0.86, uv.y));
        color = mix(color, mix(float3(0.36, 0.49, 0.67), float3(0.90, 0.95, 1.0), daylight), cirrus * 0.20);
    }

    // Large, slowly moving cloud masses. Directional offset samples produce soft volume lighting.
    float requiredCloudCover =
        isPartlyCloudy * 0.48 + isCloudy * 0.90 + rainWeather * 0.92 + snowWeather * 0.88
        + isFog * 0.38 + isHaze * 0.30 + isSmoke * 0.42 + isDust * 0.54
        + isTropicalStorm + isBlizzard;
    float cloudPresence = saturate(max(normalizedCloudCover, requiredCloudCover));
    if (cloudPresence > 0.025) {
        float coverage = mix(0.72, 0.47, cloudPresence);
        float cloudMotion = 1.0 + max(normalizedWind, windWeather * max(effectIntensity, 0.42)) * 2.8;
        float farField = cloudField(p + float2(-0.7, -0.13), t, 1.10, 0.006 * cloudMotion, 2.7);
        float midField = cloudField(p + float2(0.5, -0.03), t, 1.65, 0.011 * cloudMotion, 7.4);
        float nearField = cloudField(p + float2(1.8, 0.08), t, 2.25, 0.017 * cloudMotion, 13.8);
        float verticalCloudFade = smoothstep(0.01, 0.14, uv.y) * (1.0 - smoothstep(0.78, 0.98, uv.y));
        float farMask = cloudMask(farField, coverage + 0.035, 0.095) * verticalCloudFade * cloudPresence;
        float midMask = cloudMask(midField, coverage, 0.085) * verticalCloudFade * cloudPresence;
        float nearMask = cloudMask(nearField, coverage + 0.015, 0.078) * verticalCloudFade * cloudPresence;
        float midLighting = saturate(0.30 + midField * 0.72 + (0.5 - uv.y) * 0.18);
        float nearLighting = saturate(0.26 + nearField * 0.76 + (0.5 - uv.y) * 0.15);

        float daylightLevel = mix(0.20, 1.0, daylight);
        float stormDim = mix(1.0, 0.50, saturate(rainWeather + isTropicalStorm + isBlizzard));
        stormDim *= mix(1.0, 0.82, snowWeather);
        float3 cloudShadow = mix(float3(0.045, 0.075, 0.12), float3(0.30, 0.39, 0.46), daylightLevel * stormDim);
        float3 cloudLight = mix(float3(0.15, 0.21, 0.31), float3(0.88, 0.93, 0.94), daylightLevel * stormDim);
        cloudLight = mix(cloudLight, float3(0.88, 0.92, 0.94), snowWeather * daylight);
        cloudLight = mix(cloudLight, float3(0.66, 0.53, 0.38), isDust * daylight * 0.62);
        float3 farCloudColor = mix(cloudShadow, cloudLight, 0.42);
        float3 midCloudColor = mix(cloudShadow, cloudLight, midLighting);
        float3 nearCloudColor = mix(cloudShadow * 0.88, cloudLight, nearLighting);
        color = mix(color, farCloudColor, farMask * 0.42);
        color = mix(color, midCloudColor, midMask * 0.72);
        color = mix(color, nearCloudColor, nearMask * 0.54);
    }

    // The lower field remains chromatic so Liquid Glass has real color and luminance to refract.
    float2 lowerPoint = float2(p.x * 1.35 - t * 0.005, uv.y * 3.0 + 21.0);
    float lowerField = noise2(lowerPoint) * 0.68 + noise2(lowerPoint * 2.03 + 7.3) * 0.32;
    float lowerBlend = smoothstep(0.46, 1.0, uv.y);
    float3 dayLower = mix(dayTop * 1.08, dayBottom * 0.92, lowerField);
    float3 nightLower = mix(float3(0.025, 0.075, 0.16), float3(0.06, 0.19, 0.29), lowerField);
    color = mix(color, mix(nightLower, dayLower, daylight), lowerBlend * mix(0.34, 0.24, rainWeather));

    if (rainWeather > 0.001) {
        float rainStrength = max(effectIntensity, 0.16);
        float stormBoost = mix(1.0, 1.18, saturate(isStorm + isTropicalStorm));
        float rainSpeed = mix(0.38, 1.18, rainStrength) * stormBoost;
        RainSample rainFar = rainLayer(
            uv, t, 86.0, 42.0, rainSpeed * 0.72, 0.044, mix(0.18, 0.32, rainStrength),
            0.026, mix(0.12, 0.43, rainStrength), 3.2, 0.0
        );
        RainSample rainMid = rainLayer(
            uv, t, 56.0, 30.0, rainSpeed, 0.064, mix(0.26, 0.46, rainStrength),
            0.032, mix(0.10, 0.37, rainStrength), 17.9, 0.38
        );
        RainSample rainNear = rainLayer(
            uv, t, 34.0, 20.0, rainSpeed * 1.24, 0.086, mix(0.38, 0.64, rainStrength),
            0.038, mix(0.07, 0.29, rainStrength), 41.7, 0.85
        );
        float2 rainVeilPoint = float2(uv.x * 1.75 - t * 0.022, uv.y * 2.35 + t * 0.007);
        float rainVeil = noise2(rainVeilPoint) * 0.70 + noise2(rainVeilPoint * 2.11 + 9.7) * 0.30;
        float curtain = smoothstep(0.40, 0.79, rainVeil) * smoothstep(0.16, 0.96, uv.y);
        float rainCore = rainFar.core * 0.20 + rainMid.core * 0.40 + rainNear.core * mix(0.50, 0.72, rainStrength);
        float rainHalo = rainFar.halo * 0.10 + rainMid.halo * 0.20 + rainNear.halo * 0.32;
        float3 rainColor = mix(float3(0.42, 0.55, 0.69), float3(0.76, 0.84, 0.86), daylight);
        rainColor = mix(rainColor, float3(0.78, 0.90, 1.0), isFreezingRain * 0.42);

        color = mix(
            color,
            mix(float3(0.035, 0.085, 0.13), float3(0.11, 0.20, 0.24), daylight),
            curtain * mix(0.06, 0.24, rainStrength) * rainWeather
        );
        color *= 1.0 - saturate(rainHalo * 0.055 * rainWeather);
        color += rainColor * rainCore * rainWeather;
        color += float3(0.20, 0.31, 0.38) * rainHalo * 0.14 * rainWeather;
    }

    if (snowWeather > 0.001) {
        float snowStrength = max(effectIntensity, 0.12);
        float blowingStrength = saturate(isBlowingSnow + isBlizzard + isSleet * 0.22);
        float snowSpeed = mix(0.045, 0.20, snowStrength) * mix(1.0, 1.8, blowingStrength);
        float swayBoost = mix(1.0, 3.2, max(blowingStrength, normalizedWind));
        SnowSample snowFar = snowLayer(
            uv, t, 34.0, 25.0, snowSpeed * 0.58, 0.080,
            mix(0.10, 0.38, snowStrength), 0.008 * swayBoost, 4.3, 0.06
        );
        SnowSample snowMid = snowLayer(
            uv, t, 21.0, 17.0, snowSpeed, 0.105,
            mix(0.09, 0.34, snowStrength), 0.020 * swayBoost, 18.7, 0.34
        );
        SnowSample snowNear = snowLayer(
            uv, t, 12.0, 11.0, snowSpeed * 1.55, 0.145,
            mix(0.06, 0.28, snowStrength), 0.046 * swayBoost, 39.2, 0.92
        );
        float2 snowHazePoint = float2(uv.x * 1.25 + t * 0.009, uv.y * 1.85 + 6.0);
        float snowHazeField = noise2(snowHazePoint) * 0.70 + noise2(snowHazePoint * 2.05 + 3.8) * 0.30;
        float snowHaze = smoothstep(0.40, 0.82, snowHazeField);
        float snowCore = snowFar.core * 0.45 + snowMid.core * 0.72 + snowNear.core;
        float snowGlow = snowFar.glow * 0.07 + snowMid.glow * 0.15 + snowNear.glow * 0.28;

        color = mix(
            color,
            mix(float3(0.40, 0.49, 0.57), float3(0.65, 0.75, 0.77), daylight),
            snowHaze * mix(0.06, 0.22, snowStrength) * snowWeather
        );
        color += mix(float3(0.42, 0.53, 0.68), float3(0.82, 0.90, 0.92), daylight) * snowGlow * 0.14 * snowWeather;
        color = mix(color, float3(0.91, 0.95, 0.96), saturate(snowCore * 1.18) * snowWeather);
    }

    if (iceWeather > 0.001) {
        float hailStrength = saturate(isHail + isSleet * 0.35 + isFreezingRain * 0.18);
        SnowSample icePellets = snowLayer(
            uv, t, 22.0, 18.0, mix(0.42, 1.08, max(effectIntensity, 0.30)),
            0.095, mix(0.08, 0.28, effectIntensity), 0.004, 67.2, 0.0
        );
        float iceCore = saturate(icePellets.core * 0.92 + icePellets.glow * 0.16);
        color = mix(color, float3(0.82, 0.92, 1.0), iceCore * hailStrength);
        float iceSheen = pow(saturate(uv.y), 5.0) * (0.5 + 0.5 * sin(uv.x * 42.0 + t * 0.8));
        color += float3(0.35, 0.58, 0.78) * iceSheen * isFreezingRain * 0.055;
    }

    if (obscuredWeather > 0.001) {
        float fogFar = fogLayer(uv, t, 0.39, 0.34, 0.012, 2.4);
        float fogMid = fogLayer(uv, t, 0.61, 0.28, -0.018, 11.7);
        float fogNear = fogLayer(uv, t, 0.82, 0.24, 0.027, 23.1);
        float fog = saturate(fogFar * 0.38 + fogMid * 0.56 + fogNear * 0.72);
        float3 fogColor = mix(float3(0.25, 0.33, 0.38), float3(0.66, 0.74, 0.72), daylight);
        fogColor = mix(fogColor, float3(0.62, 0.57, 0.46), isHaze * 0.52);
        fogColor = mix(fogColor, float3(0.31, 0.32, 0.31), isSmoke * 0.72);
        fogColor = mix(fogColor, float3(0.67, 0.46, 0.25), isDust * 0.65);
        color = mix(color, fogColor, fog * mix(0.42, 0.82, obscuredWeather));
    }

    if (windWeather > 0.001) {
        float windStrength = max(max(normalizedWind, effectIntensity), 0.28);
        float windFar = windStreakLayer(uv, t, mix(0.18, 0.54, windStrength), mix(0.08, 0.30, windStrength), 0.050, 5.1);
        float windNear = windStreakLayer(uv, t, mix(0.30, 0.82, windStrength), mix(0.06, 0.24, windStrength), 0.034, 31.4);
        float windLines = windFar * 0.34 + windNear * 0.62;
        color += mix(float3(0.28, 0.38, 0.48), float3(0.80, 0.86, 0.84), daylight) * windLines * windWeather * 0.34;
    }

    if (isDust > 0.001) {
        float dustStrength = max(effectIntensity, 0.52);
        float dustFar = airborneParticleLayer(uv, t, 34.0, 20.0, 0.10 + dustStrength * 0.18, 0.075, 0.28, 0.020, 8.2);
        float dustNear = airborneParticleLayer(uv, t, 18.0, 12.0, 0.16 + dustStrength * 0.28, 0.11, 0.20, 0.035, 42.7);
        color += float3(0.68, 0.43, 0.21) * (dustFar * 0.30 + dustNear * 0.48) * isDust;
    }

    if (isHeat > 0.001) {
        float2 heatPoint = float2(uv.x * 3.2 + t * 0.020, uv.y * 7.4 - t * 0.035);
        float heatNoise = noise2(heatPoint) * 0.72 + noise2(heatPoint * 2.13 + 4.2) * 0.28;
        float heatWave = sin(uv.y * 42.0 - t * 3.1 + heatNoise * 5.0) * 0.5 + 0.5;
        float heatBand = smoothstep(0.56, 0.94, heatWave) * smoothstep(0.35, 1.0, uv.y);
        color += float3(0.42, 0.13, 0.025) * heatBand * 0.10 * isHeat;
    }

    if (isFrigid > 0.001) {
        float iceDust = airborneParticleLayer(uv, t, 30.0, 20.0, 0.025, 0.055, 0.16, 0.010, 73.3);
        color += float3(0.68, 0.86, 1.0) * iceDust * 0.36 * isFrigid;
    }

    if (lightningWeather > 0.001) {
        float lightningIntensity = max(effectIntensity, 0.42);
        float strikeClock = t / mix(7.0, 2.8, lightningIntensity);
        float strikeIndex = floor(strikeClock);
        float phase = fract(strikeClock);
        float event = step(mix(0.72, 0.24, lightningIntensity), hash21(float2(strikeIndex, 91.7)));
        float firstPulse = smoothstep(0.78, 0.82, phase) * (1.0 - smoothstep(0.87, 0.91, phase));
        float echoPulse = smoothstep(0.90, 0.925, phase) * (1.0 - smoothstep(0.955, 0.98, phase)) * 0.48;
        float flash = (firstPulse + echoPulse) * event;
        float bolt = lightningBolt(uv, strikeIndex) * flash;
        color += float3(0.34, 0.44, 0.76) * flash * 0.62 * lightningWeather;
        color = mix(color, float3(0.91, 0.95, 1.0), bolt * lightningWeather);
    }

    float vignetteDistance = length((uv - 0.5) * float2(0.82, 1.0));
    float vignette = 1.0 - smoothstep(0.30, 0.88, vignetteDistance);
    color *= 0.82 + vignette * 0.18;
    float grain = hash21(position + floor(t * 24.0)) - 0.5;
    color += grain / 320.0;
    return half4(half3(saturate(color)), 1.0h);
}
