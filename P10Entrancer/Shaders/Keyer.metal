#include <metal_stdlib>
using namespace metal;

struct KeyerVOut {
    float4 position [[position]];
    float2 uv;
};

struct KeyerParams {
    int kind;
    float keyR;
    float keyG;
    float keyB;
    float threshold;
    float softness;
    float _pad0;
    float _pad1;
};

vertex KeyerVOut keyerVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    KeyerVOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = (positions[vid] + float2(1.0, 1.0)) * 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

fragment half4 keyerFragment(
    KeyerVOut in [[stage_in]],
    texture2d<half> fg [[texture(0)]],
    texture2d<half> bg [[texture(1)]],
    constant KeyerParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 fgColor = fg.sample(s, in.uv);
    half4 bgColor = bg.sample(s, in.uv);

    half thr = half(params.threshold);
    half soft = max(half(params.softness), half(0.001));

    half alpha;
    if (params.kind == 0) {
        // chroma key: cut where fg color is close to key color
        half3 key = half3(params.keyR, params.keyG, params.keyB);
        half d = distance(fgColor.rgb, key);
        alpha = smoothstep(thr, thr + soft, d);
    } else {
        // luma key: cut where fg luma is below threshold
        half luma = dot(fgColor.rgb, half3(0.299h, 0.587h, 0.114h));
        alpha = smoothstep(thr - soft, thr + soft, luma);
    }

    return half4(mix(bgColor.rgb, fgColor.rgb, alpha), 1.0h);
}
