#include <metal_stdlib>
using namespace metal;

struct Instance {
    float2 origin;
    float2 size;
    float2 uvOrigin;
    float2 uvSize;
    float4 color;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex VertexOut omacy_vertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              constant Instance *instances [[buffer(0)]],
                              constant float2 &viewport [[buffer(1)]]) {
    const float2 corners[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(1.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0)
    };
    Instance inst = instances[iid];
    float2 pixel = inst.origin + corners[vid] * inst.size;
    VertexOut out;
    out.position = float4(
        pixel.x / viewport.x * 2.0 - 1.0,
        1.0 - pixel.y / viewport.y * 2.0,
        0.0,
        1.0
    );
    out.uv = inst.uvOrigin + corners[vid] * inst.uvSize;
    out.color = inst.color;
    return out;
}

fragment float4 omacy_fragment(VertexOut in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float coverage = atlas.sample(s, in.uv).a;
    return float4(in.color.rgb, in.color.a * coverage);
}
