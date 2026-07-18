#include <metal_stdlib>
using namespace metal;

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x),
               mix(hash21(i + float2(0, 1)), hash21(i + 1.0), f.x), f.y);
}

static float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 5; i++) {
        value += noise(p) * amplitude;
        p = p * 2.03 + 13.7;
        amplitude *= 0.5;
    }
    return value;
}

[[ stitchable ]] half4 farmWeatherBackground(
    float2 position,
    half4 sourceColor,
    float2 size,
    float time,
    float mode,
    float daylight
) {
    float2 uv = position / max(size, float2(1.0));
    float aspect = size.x / max(size.y, 1.0);
    float2 p = float2(uv.x * aspect, uv.y);
    float t = fmod(time, 1200.0);

    float3 dayTop = float3(0.08, 0.47, 0.92);
    float3 dayBottom = float3(0.18, 0.73, 0.92);
    float3 nightTop = float3(0.015, 0.035, 0.14);
    float3 nightBottom = float3(0.05, 0.16, 0.32);
    float3 sky = mix(mix(dayTop, dayBottom, uv.y), mix(nightTop, nightBottom, uv.y), 1.0 - daylight);

    if (mode > 0.5) {
        float darken = mode > 1.5 ? 0.42 : 0.16;
        sky = mix(sky, float3(0.12, 0.19, 0.27), darken);
    }

    if (daylight > 0.5 && mode < 1.5) {
        float2 sunPosition = float2(aspect * 0.82, 0.18);
        float glow = exp(-length(p - sunPosition) * 5.2);
        sky += float3(1.0, 0.68, 0.24) * glow * 0.48;
    } else if (daylight < 0.5) {
        float stars = step(0.992, hash21(floor(p * 85.0))) * (0.55 + 0.45 * sin(t * 1.7 + p.x * 20.0));
        sky += stars * float3(0.75, 0.86, 1.0);
    }

    float cloudField = fbm(float2(p.x * 1.8 - t * 0.018, p.y * 3.3));
    float cloudMask = smoothstep(0.52, 0.76, cloudField) * smoothstep(0.96, 0.20, uv.y);
    float3 cloudColor = mix(float3(0.72, 0.79, 0.86), float3(1.0), daylight * 0.72);
    float cloudStrength = mode < 0.5 ? 0.28 : 0.68;
    sky = mix(sky, cloudColor, cloudMask * cloudStrength);

    if (mode > 1.5 && mode < 3.5) {
        float2 cell = float2(p.x * 46.0, p.y * 20.0);
        float column = floor(cell.x);
        float speed = 0.85 + hash21(float2(column, 2.0)) * 1.6;
        float y = fract(cell.y + t * speed + hash21(float2(column, 8.0)));
        float xDistance = abs(fract(cell.x) - 0.5);

        if (mode < 2.5) {
            float rain = smoothstep(0.075, 0.0, xDistance) * smoothstep(0.34, 0.0, y);
            sky = mix(sky, float3(0.68, 0.84, 1.0), rain * 0.72);
        } else {
            float snow = smoothstep(0.12, 0.0, length(float2(xDistance, y - 0.5)));
            sky = mix(sky, float3(1.0), snow * 0.88);
        }
    }

    if (mode > 3.5 && mode < 4.5) {
        float pulse = smoothstep(0.975, 1.0, sin(t * 0.72 + noise(p * 3.0) * 4.0));
        sky += pulse * float3(0.48, 0.58, 0.82);
    }

    if (mode > 4.5) {
        float mist = fbm(float2(p.x * 2.2 - t * 0.009, p.y * 8.0));
        sky = mix(sky, float3(0.69, 0.75, 0.78), smoothstep(0.38, 0.72, mist) * 0.55);
    }

    float vignette = smoothstep(0.95, 0.25, length(uv - 0.5));
    sky *= 0.88 + vignette * 0.12;
    return half4(half3(saturate(sky)), 1.0h);
}
