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

    // Hard-clamp the endpoints across every transition kind so the
    // user always gets a clean fully-CH1 / fully-CH2 picture at the
    // slider rails. Wipes get residual feathered edges otherwise
    // (smoothstep bands leak past the texture domain at p=0/1); the
    // key transitions used to ride a non-zero alpha at p=0 too.
    if (p <= 0.0001) { return a; }
    if (p >= 0.9999) { return b; }

    if (params.kind == 0) {
        // Crossfade with reciprocal blur — both sides bloom briefly
        // through the cross. The blur radius is 0 at the rails so
        // crossfade endpoints are already clean.
        float crossWeight = 1.0 - abs(p - 0.5) * 2.0;
        float radius = 6.0 * crossWeight;
        if (radius > 0.05) {
            a = sampleBlurred(ch1, s, uv, radius);
            b = sampleBlurred(ch2, s, uv, radius);
        }
        return mix(a, b, half(p));
    }

    if (params.kind == 1) {
        // Linear horizontal swipe — CH2 reveals from the LEFT as p
        // grows. Map the boundary across [-feather, 1+feather] so
        // at p=0 it sits just past the right edge (all CH1) and at
        // p=1 just past the left (all CH2). The feather band gives
        // the wipe a soft, anti-aliased edge.
        float feather = 0.04;
        float boundary = -feather + p * (1.0 + 2.0 * feather);
        float k = 1.0 - smoothstep(boundary - feather, boundary + feather, uv.x);
        return mix(a, b, half(k));
    }

    if (params.kind == 2) {
        // Star wipe — CH2 grows out from the centre in a 5-point
        // star. starR ranges [0, ~1.35]; map the boundary across
        // [-feather, starRMax+feather] so the wipe fully covers
        // both endpoints with no centre leak at p=0 and no corner
        // stragglers at p=1.
        float2 c = uv - 0.5;
        float r = length(c) * 1.4142;
        float angle = atan2(c.y, c.x);
        float starModulation = 1.0 + 0.35 * cos(angle * 5.0);
        float starR = r * starModulation;
        float feather = 0.05;
        float starRMax = 1.35;
        float boundary = -feather + p * (starRMax + 2.0 * feather);
        float k = 1.0 - smoothstep(boundary - feather, boundary + feather, starR);
        return mix(a, b, half(k));
    }

    if (params.kind == 3) {
        // Chroma key transition — keyed CH2 over CH1 at p=0.5,
        // ramps cleanly out to pure CH1 at p=0 and pure CH2 at
        // p=1 via a piecewise blend on the alpha. Hard endpoint
        // clamp above already short-circuits this; the in-between
        // gives the "key effect peaks at half-way" feel.
        half3 key = half3(params.keyR, params.keyG, params.keyB);
        half d = distance(b.rgb, key);
        half thr = half(params.keyThreshold);
        half soft = max(half(params.keySoftness), half(0.001));
        half keyedAlpha = smoothstep(thr, thr + soft, d);
        half alpha;
        if (p < 0.5) {
            alpha = keyedAlpha * half(2.0 * p);
        } else {
            alpha = mix(keyedAlpha, half(1.0), half((p - 0.5) * 2.0));
        }
        return half4(mix(a.rgb, b.rgb, alpha), 1.0h);
    }

    if (params.kind == 4) {
        // Luma key transition — same piecewise scheme as chroma so
        // the rails are pure-CH1 / pure-CH2.
        half luma = dot(b.rgb, half3(0.299h, 0.587h, 0.114h));
        half thr = half(params.keyThreshold);
        half soft = max(half(params.keySoftness), half(0.001));
        half keyedAlpha = smoothstep(thr - soft, thr + soft, luma);
        half alpha;
        if (p < 0.5) {
            alpha = keyedAlpha * half(2.0 * p);
        } else {
            alpha = mix(keyedAlpha, half(1.0), half((p - 0.5) * 2.0));
        }
        return half4(mix(a.rgb, b.rgb, alpha), 1.0h);
    }

    return mix(a, b, half(p));
}
