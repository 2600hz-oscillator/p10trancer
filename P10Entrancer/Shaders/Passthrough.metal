#include <metal_stdlib>
using namespace metal;

struct PVOut {
    float4 position [[position]];
    float2 uv;
};

struct PassthroughParams {
    float aspectScaleX;
    float aspectScaleY;
    float _pad0;
    float _pad1;
};

vertex PVOut passthroughVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    PVOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = (positions[vid] + float2(1.0, 1.0)) * 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

fragment half4 passthroughFragment(
    PVOut in [[stage_in]],
    texture2d<half> src [[texture(0)]],
    constant PassthroughParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 c = in.uv - 0.5;
    c.x *= params.aspectScaleX;
    c.y *= params.aspectScaleY;
    float2 uv = c + 0.5;
    if (any(uv < float2(0.0)) || any(uv > float2(1.0))) {
        return half4(0.0h, 0.0h, 0.0h, 1.0h);
    }
    return src.sample(s, uv);
}
