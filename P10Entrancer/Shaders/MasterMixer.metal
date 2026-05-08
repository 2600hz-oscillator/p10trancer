#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 position [[position]];
    float2 uv;
};

struct MixerParams {
    int kind;
    float position;
    float keyR;
    float keyG;
    float keyB;
    float keyThreshold;
    float keySoftness;
    float _pad;
};

vertex VOut mixerVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    VOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = (positions[vid] + float2(1.0, 1.0)) * 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

static inline half4 sampleBlurred(texture2d<half> tex, sampler s, float2 uv, float radius) {
    float2 px = float2(1.0) / float2(tex.get_width(), tex.get_height());
    half4 c = half4(0.0h);
    float total = 0.0;
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            float2 o = float2(dx, dy) * px * radius;
            float w = exp(-float(dx * dx + dy * dy) / 6.0);
            c += tex.sample(s, uv + o) * half(w);
            total += w;
        }
    }
    return c / half(total);
}

fragment half4 mixerFragment(
    VOut in [[stage_in]],
    texture2d<half> ch1 [[texture(0)]],
    texture2d<half> ch2 [[texture(1)]],
    constant MixerParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float p = clamp(params.position, 0.0, 1.0);
    float2 uv = in.uv;

    half4 a = ch1.sample(s, uv);
    half4 b = ch2.sample(s, uv);

    if (params.kind == 0) {
        // crossfade with reciprocal blur — both sides bloom briefly through the cross
        float crossWeight = 1.0 - abs(p - 0.5) * 2.0;
        float radius = 6.0 * crossWeight;
        if (radius > 0.05) {
            a = sampleBlurred(ch1, s, uv, radius);
            b = sampleBlurred(ch2, s, uv, radius);
        }
        return mix(a, b, half(p));
    }

    if (params.kind == 1) {
        // linear horizontal swipe with feathered edge
        float feather = 0.04;
        float k = smoothstep(p - feather, p + feather, uv.x);
        return mix(a, b, half(k));
    }

    if (params.kind == 2) {
        // star swipe: radial wipe with star-shaped boundary
        float2 c = uv - 0.5;
        float r = length(c) * 1.4142;
        float angle = atan2(c.y, c.x);
        float starModulation = 1.0 + 0.35 * cos(angle * 5.0);
        float starR = r * starModulation;
        float feather = 0.05;
        float k = 1.0 - smoothstep(p - feather, p + feather, starR);
        return mix(a, b, half(k));
    }

    if (params.kind == 3) {
        // chroma key: ch2 keyed over ch1 by distance from key color (RGB)
        half3 key = half3(params.keyR, params.keyG, params.keyB);
        half d = distance(b.rgb, key);
        half thr = half(params.keyThreshold);
        half soft = max(half(params.keySoftness), half(0.001));
        half alpha = smoothstep(thr, thr + soft, d);
        // Apply position as overall key intensity (0=off, 1=full key)
        alpha = mix(half(1.0), alpha, half(p));
        return half4(mix(a.rgb, b.rgb, alpha), 1.0h);
    }

    if (params.kind == 4) {
        // luma key: ch2 keyed where its luma exceeds threshold
        half luma = dot(b.rgb, half3(0.299h, 0.587h, 0.114h));
        half thr = half(params.keyThreshold);
        half soft = max(half(params.keySoftness), half(0.001));
        half alpha = smoothstep(thr - soft, thr + soft, luma);
        alpha = mix(half(1.0) - alpha, alpha, half(p));
        return half4(mix(a.rgb, b.rgb, alpha), 1.0h);
    }

    return mix(a, b, half(p));
}
