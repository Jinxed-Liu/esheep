#include <metal_stdlib>
using namespace metal;

struct ESMotionParticleVertex {
    float2 position;
    float size;
    float4 color;
};

struct ESMotionParticleRaster {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

vertex ESMotionParticleRaster esmotionParticleVertex(
    const device ESMotionParticleVertex *vertices [[buffer(0)]],
    uint vertexID [[vertex_id]]
) {
    ESMotionParticleRaster output;
    output.position = float4(vertices[vertexID].position, 0.0, 1.0);
    output.pointSize = vertices[vertexID].size;
    output.color = vertices[vertexID].color;
    return output;
}

fragment float4 esmotionParticleFragment(
    ESMotionParticleRaster input [[stage_in]],
    float2 pointCoordinate [[point_coord]]
) {
    float2 centered = pointCoordinate * 2.0 - 1.0;
    float distanceFromCenter = length(centered);
    float alpha = 1.0 - smoothstep(0.62, 1.0, distanceFromCenter);
    return float4(input.color.rgb, input.color.a * alpha);
}
