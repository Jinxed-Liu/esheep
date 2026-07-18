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

static float cloudField(float2 p, float time, float scale, float speed, float seed) {
    float2 q = p * scale + float2(-time * speed, seed);
    float warp = fbm4(q * 0.47 + float2(seed * 1.7, 4.1));
    float body = fbm4(q + float2(warp * 0.82, warp * 0.24));
    float detail = fbm4(q * 2.35 - float2(time * speed * 0.31, seed * 2.1));
    return body * 0.84 + detail * 0.16;
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

static float rainStreak(
    float2 uv,
    float time,
    float columns,
    float rows,
    float speed,
    float slant,
    float length,
    float width,
    float density,
    float seed
) {
    float gust = sin(time * 0.21 + seed) * 0.018;
    gust += (noise2(float2(time * 0.075, seed)) - 0.5) * 0.055;
    float shearedX = uv.x + uv.y * (slant + gust);
    shearedX += sin(uv.y * 8.0 + time * 0.33 + seed) * 0.0035;

    float2 gridPosition = float2(shearedX * columns, uv.y * rows - time * speed);
    float2 cell = floor(gridPosition);
    float2 local = fract(gridPosition);
    float spawn = hash21(cell + float2(seed * 17.3, seed * 31.7));
    float2 variation = hash22(cell + float2(seed * 7.1, 19.4));
    float opacity = hash21(cell + float2(5.3, seed * 53.1));

    float rainBand = fbm4(float2(uv.x * 2.1 - time * 0.026, uv.y * 1.3 + seed * 2.7));
    float threshold = 1.0 - density * mix(0.70, 1.14, rainBand);
    float exists = smoothstep(threshold, threshold + 0.075, spawn);

    float dropLength = length * mix(0.58, 1.20, variation.y);
    float head = mix(0.72, 0.94, hash21(cell + float2(seed * 3.7, 71.2)));
    float tail = head - dropLength;
    float body = smoothstep(tail - 0.045, tail + 0.025, local.y);
    body *= 1.0 - smoothstep(head - 0.018, head + 0.035, local.y);

    float progress = saturate((local.y - tail) / max(dropLength, 0.001));
    float taperedWidth = width * mix(0.30, 1.0, pow(progress, 0.64));
    float centerX = mix(0.16, 0.84, variation.x);
    float across = exp(-pow((local.x - centerX) / max(taperedWidth, 0.001), 2.0));
    float headSpark = exp(-pow((local.y - head) / 0.025, 2.0)) * across;
    return exists * (body * across * mix(0.32, 0.96, opacity) + headSpark * 0.20);
}

static float snowParticle(
    float2 uv,
    float time,
    float columns,
    float rows,
    float speed,
    float radius,
    float density,
    float seed
) {
    float sway = sin(time * (0.32 + seed * 0.015) + uv.y * 7.0 + seed) * 0.018;
    float2 gridPosition = float2((uv.x + sway) * columns, uv.y * rows - time * speed);
    float2 cell = floor(gridPosition);
    float2 local = fract(gridPosition);
    float2 center = mix(float2(0.18), float2(0.82), hash22(cell + seed * 13.7));
    center.x += sin(time * 0.74 + hash21(cell) * 13.0) * 0.12;
    float spawn = hash21(cell + float2(seed * 5.7, 31.1));
    float size = radius * mix(0.58, 1.22, hash21(cell + 73.4));
    float flake = 1.0 - smoothstep(size * 0.28, size, length(local - center));
    float snowBand = fbm4(float2(uv.x * 1.7 + time * 0.015, uv.y * 1.2 + seed));
    float exists = smoothstep(1.0 - density * mix(0.74, 1.10, snowBand), 1.0, spawn);
    return flake * exists;
}

static float fogLayer(float2 uv, float time, float altitude, float width, float speed, float seed) {
    float2 p = float2(uv.x * 1.55 - time * speed, uv.y * 4.8 + seed);
    p.y += sin(uv.x * 3.4 + time * speed * 2.0 + seed) * 0.18;
    float structure = fbm4(p);
    float detail = noise2(p * 3.1 + float2(seed, -time * speed));
    float band = gaussianBand(uv.y, altitude, width);
    return band * smoothstep(0.32, 0.78, structure * 0.82 + detail * 0.18);
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
    float daylight
) {
    (void)sourceColor;
    float2 uv = position / max(size, float2(1.0));
    float aspect = size.x / max(size.y, 1.0);
    float2 p = float2((uv.x - 0.5) * aspect, uv.y - 0.5);
    float t = fmod(time, 1800.0);

    float isClear = 1.0 - step(0.5, mode);
    float isCloudy = step(0.5, mode) * (1.0 - step(1.5, mode));
    float isRain = step(1.5, mode) * (1.0 - step(2.5, mode));
    float isSnow = step(2.5, mode) * (1.0 - step(3.5, mode));
    float isStorm = step(3.5, mode) * (1.0 - step(4.5, mode));
    float isFog = step(4.5, mode);
    float wetWeather = saturate(isRain + isStorm);

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

    float3 dayTop = clearTop * isClear + cloudyTop * isCloudy + rainTop * wetWeather + snowTop * isSnow + fogTop * isFog;
    float3 dayBottom = clearBottom * isClear + cloudyBottom * isCloudy + rainBottom * wetWeather + snowBottom * isSnow + fogBottom * isFog;
    float3 nightTop = mix(float3(0.004, 0.010, 0.042), float3(0.014, 0.035, 0.075), 1.0 - isClear);
    float3 nightBottom = mix(float3(0.025, 0.080, 0.16), float3(0.045, 0.12, 0.17), wetWeather + isFog * 0.7);
    float horizon = pow(saturate(uv.y), mix(0.72, 0.96, wetWeather + isFog));
    float3 color = mix(mix(nightTop, nightBottom, horizon), mix(dayTop, dayBottom, horizon), daylight);

    float horizonHaze = gaussianBand(uv.y, 0.72, mix(0.18, 0.31, isFog));
    color += horizonHaze * mix(float3(0.025, 0.07, 0.09), float3(0.055, 0.10, 0.09), daylight);

    // Clear and partly cloudy states have a broad light source; rain, snow and fog only keep diffuse sky glow.
    float sunVisibility = isClear + isCloudy * 0.30;
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
        float moonVisibility = isClear + isCloudy * 0.18;
        float2 moonPosition = float2(aspect * 0.25, -0.25);
        float moonDistance = length(p - moonPosition);
        float moonDisc = 1.0 - smoothstep(0.036, 0.052, moonDistance);
        float moonCut = 1.0 - smoothstep(0.034, 0.050, length(p - moonPosition - float2(0.023, -0.012)));
        color += float3(0.25, 0.38, 0.70) * exp(-moonDistance * 5.5) * 0.30 * moonVisibility;
        color = mix(color, float3(0.84, 0.91, 1.0), moonDisc * (1.0 - moonCut * 0.90) * moonVisibility);
        color += starField(uv, t) * float3(0.68, 0.80, 1.0) * isClear;
    }

    // Thin high-altitude motion gives clear weather life without fake radial rays.
    float cirrus = cirrusField(uv, t) * isClear * smoothstep(0.02, 0.18, uv.y) * (1.0 - smoothstep(0.58, 0.86, uv.y));
    color = mix(color, mix(float3(0.36, 0.49, 0.67), float3(0.90, 0.95, 1.0), daylight), cirrus * 0.20);

    // Large, slowly moving cloud masses. Directional offset samples produce soft volume lighting.
    float cloudPresence = isClear * 0.20 + isCloudy * 0.88 + wetWeather + isSnow * 0.90 + isFog * 0.42;
    float coverage = isClear > 0.5 ? 0.69 : (isCloudy > 0.5 ? 0.54 : (isFog > 0.5 ? 0.62 : 0.49));
    float farField = cloudField(p + float2(-0.7, -0.13), t, 1.10, 0.006, 2.7);
    float midField = cloudField(p + float2(0.5, -0.03), t, 1.65, 0.011, 7.4);
    float nearField = cloudField(p + float2(1.8, 0.08), t, 2.25, 0.017, 13.8);
    float midLightSample = cloudField(p + float2(0.46, -0.085), t, 1.65, 0.011, 7.4);
    float nearLightSample = cloudField(p + float2(1.74, 0.025), t, 2.25, 0.017, 13.8);
    float verticalCloudFade = smoothstep(0.01, 0.14, uv.y) * (1.0 - smoothstep(0.78, 0.98, uv.y));
    float farMask = cloudMask(farField, coverage + 0.035, 0.095) * verticalCloudFade * cloudPresence;
    float midMask = cloudMask(midField, coverage, 0.085) * verticalCloudFade * cloudPresence;
    float nearMask = cloudMask(nearField, coverage + 0.015, 0.078) * verticalCloudFade * cloudPresence;
    float midLighting = saturate(0.48 + (midLightSample - midField) * 5.2);
    float nearLighting = saturate(0.45 + (nearLightSample - nearField) * 4.8);

    float daylightLevel = mix(0.20, 1.0, daylight);
    float stormDim = mix(1.0, 0.54, wetWeather) * mix(1.0, 0.82, isSnow);
    float3 cloudShadow = mix(float3(0.045, 0.075, 0.12), float3(0.30, 0.39, 0.46), daylightLevel * stormDim);
    float3 cloudLight = mix(float3(0.15, 0.21, 0.31), float3(0.88, 0.93, 0.94), daylightLevel * stormDim);
    cloudLight = mix(cloudLight, float3(0.88, 0.92, 0.94), isSnow * daylight);
    float3 farCloudColor = mix(cloudShadow, cloudLight, 0.42);
    float3 midCloudColor = mix(cloudShadow, cloudLight, midLighting);
    float3 nearCloudColor = mix(cloudShadow * 0.88, cloudLight, nearLighting);
    color = mix(color, farCloudColor, farMask * 0.42);
    color = mix(color, midCloudColor, midMask * 0.72);
    color = mix(color, nearCloudColor, nearMask * 0.54);

    // The lower field remains chromatic so Liquid Glass has real color and luminance to refract.
    float lowerField = fbm4(float2(p.x * 1.35 - t * 0.005, uv.y * 3.0 + 21.0));
    float lowerBlend = smoothstep(0.46, 1.0, uv.y);
    float3 clearLower = mix(float3(0.08, 0.42, 0.68), float3(0.12, 0.69, 0.73), lowerField);
    float3 cloudLower = mix(float3(0.12, 0.30, 0.43), float3(0.24, 0.48, 0.56), lowerField);
    float3 wetLower = mix(float3(0.025, 0.12, 0.20), float3(0.055, 0.28, 0.34), lowerField);
    float3 snowLower = mix(float3(0.24, 0.37, 0.46), float3(0.48, 0.65, 0.68), lowerField);
    float3 fogLower = mix(float3(0.27, 0.40, 0.43), float3(0.48, 0.61, 0.58), lowerField);
    float3 dayLower = clearLower * isClear + cloudLower * isCloudy + wetLower * wetWeather + snowLower * isSnow + fogLower * isFog;
    float3 nightLower = mix(float3(0.025, 0.075, 0.16), float3(0.06, 0.19, 0.29), lowerField);
    color = mix(color, mix(nightLower, dayLower, daylight), lowerBlend * mix(0.34, 0.25, wetWeather));

    if (wetWeather > 0.5) {
        float intensity = mix(0.88, 1.18, isStorm);
        float rainFar = rainStreak(uv, t, 71.0, 35.0, 13.0, 0.055, 0.20, 0.035, 0.48 * intensity, 3.2);
        float rainMid = rainStreak(uv, t, 43.0, 24.0, 16.8, 0.075, 0.31, 0.048, 0.37 * intensity, 17.9);
        float rainNear = rainStreak(uv, t, 25.0, 17.0, 20.5, 0.105, 0.48, 0.066, 0.22 * intensity, 41.7);
        float rainVeil = fbm4(float2(uv.x * 1.8 - t * 0.018, uv.y * 2.6 + t * 0.006));
        float haze = smoothstep(0.42, 0.80, rainVeil) * smoothstep(0.28, 1.0, uv.y);
        color = mix(color, float3(0.07, 0.17, 0.23), haze * 0.15 * intensity);
        color += float3(0.22, 0.38, 0.50) * rainFar * 0.24;
        color += float3(0.42, 0.63, 0.74) * rainMid * 0.39;
        color += float3(0.72, 0.85, 0.90) * rainNear * 0.56;
    }

    if (isSnow > 0.5) {
        float snowFar = snowParticle(uv, t, 30.0, 24.0, 2.1, 0.12, 0.40, 4.3);
        float snowMid = snowParticle(uv, t, 19.0, 16.0, 2.8, 0.16, 0.34, 18.7);
        float snowNear = snowParticle(uv, t, 11.0, 10.0, 3.5, 0.21, 0.24, 39.2);
        float snowHaze = smoothstep(0.40, 0.82, fbm4(float2(uv.x * 1.3 + t * 0.008, uv.y * 2.0 + 6.0)));
        color = mix(color, float3(0.62, 0.72, 0.75), snowHaze * 0.12);
        color = mix(color, float3(0.88, 0.94, 0.96), snowFar * 0.34 + snowMid * 0.58 + snowNear * 0.84);
    }

    if (isFog > 0.5) {
        float fogFar = fogLayer(uv, t, 0.39, 0.34, 0.012, 2.4);
        float fogMid = fogLayer(uv, t, 0.61, 0.28, -0.018, 11.7);
        float fogNear = fogLayer(uv, t, 0.82, 0.24, 0.027, 23.1);
        float fog = saturate(fogFar * 0.38 + fogMid * 0.56 + fogNear * 0.72);
        float3 fogColor = mix(float3(0.25, 0.33, 0.38), float3(0.66, 0.74, 0.72), daylight);
        color = mix(color, fogColor, fog * 0.78);
    }

    if (isStorm > 0.5) {
        float strikeClock = t / 4.8;
        float strikeIndex = floor(strikeClock);
        float phase = fract(strikeClock);
        float event = step(0.62, hash21(float2(strikeIndex, 91.7)));
        float firstPulse = smoothstep(0.78, 0.82, phase) * (1.0 - smoothstep(0.87, 0.91, phase));
        float echoPulse = smoothstep(0.90, 0.925, phase) * (1.0 - smoothstep(0.955, 0.98, phase)) * 0.48;
        float flash = (firstPulse + echoPulse) * event;
        float bolt = lightningBolt(uv, strikeIndex) * flash;
        color += float3(0.34, 0.44, 0.76) * flash * 0.62;
        color = mix(color, float3(0.91, 0.95, 1.0), bolt);
    }

    float vignetteDistance = length((uv - 0.5) * float2(0.82, 1.0));
    float vignette = 1.0 - smoothstep(0.30, 0.88, vignetteDistance);
    color *= 0.82 + vignette * 0.18;
    float grain = hash21(position + floor(t * 24.0)) - 0.5;
    color += grain / 320.0;
    return half4(half3(saturate(color)), 1.0h);
}
