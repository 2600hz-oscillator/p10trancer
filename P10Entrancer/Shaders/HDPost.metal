#include <metal_stdlib>
using namespace metal;

// HD output post-processing — a single fragment pass applied to the
// master mixer's image when the user is in HD 720p mode. Mirror of
// NTSCPipeline but for clean HD output: color grading + bloom, no
// analog video artifacts.
//
// Defaults are neutral (every knob produces an identity transform
// at 0 / 1 / depending on field). Sliders push above/below to
// reshape the image. Bloom uses a tight 5-tap box-blurred bright
// pass to keep the GPU cost low — this is not a wide gaussian.

struct HDPostVOut {
    float4 position [[position]];
    float2 uv;
};

struct HDPostParams {
    float gamma;       // 0.5 (lifted shadows) … 2.5 (crushed). neutral = 1.0
    float contrast;    // 0.5 … 2.0. neutral = 1.0
    float saturation;  // 0 (greyscale) … 2 (oversat). neutral = 1.0
    float brightness;  // -0.5 … +0.5 additive offset. neutral = 0.0
    float bloom;       // 0 … 1 — mix of bright-bloom into output. neutral = 0.0
    float bloomThresh; // 0 … 1 — luma threshold above which a pixel contributes to bloom. neutral = 0.75
    float _pad0;
    float _pad1;
};

vertex HDPostVOut hdPostVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    HDPostVOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = (positions[vid] + float2(1.0, 1.0)) * 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

// Helper: luma using BT.709 weights.
inline float luma(float3 rgb) {
    return dot(rgb, float3(0.2126, 0.7152, 0.0722));
}

// 5-tap bright-pass box blur sample. Compares each tap's luma to
// `bloomThresh`, soft-knees pixels above the threshold, and averages.
inline float3 bloomSample(texture2d<half> src, float2 uv, float thresh) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 size = float2(src.get_width(), src.get_height());
    float2 step = 1.5 / size;   // 1.5 pixels — soft halo without going wide
    const float2 offsets[5] = {
        float2( 0.0,  0.0),
        float2( step.x,  0.0),
        float2(-step.x,  0.0),
        float2( 0.0,  step.y),
        float2( 0.0, -step.y),
    };
    float3 acc = float3(0.0);
    for (int i = 0; i < 5; i++) {
        float3 rgb = float3(src.sample(s, uv + offsets[i]).rgb);
        float l = luma(rgb);
        // Soft knee: below thresh→0, above→remaining linear contribution.
        float w = smoothstep(thresh, min(1.0, thresh + 0.25), l);
        acc += rgb * w;
    }
    return acc * 0.2;
}

fragment half4 hdPostFragment(
    HDPostVOut in [[stage_in]],
    texture2d<half> src [[texture(0)]],
    constant HDPostParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 rgb = float3(src.sample(s, in.uv).rgb);

    // Gamma — applied in [0,1] perceptual space.
    rgb = pow(max(rgb, float3(0.0001)), float3(1.0 / max(params.gamma, 0.01)));

    // Contrast — around mid-gray 0.5.
    rgb = (rgb - 0.5) * params.contrast + 0.5;

    // Saturation — interpolate from per-pixel luma toward rgb.
    float l = luma(rgb);
    rgb = mix(float3(l), rgb, params.saturation);

    // Brightness — additive offset.
    rgb += float3(params.brightness);

    // Bloom — add scaled bright-pass on top. params.bloom = 0 turns
    // it off completely; 1.0 fully adds the bright pass.
    if (params.bloom > 0.001) {
        float3 b = bloomSample(src, in.uv, params.bloomThresh);
        rgb += b * params.bloom;
    }

    rgb = clamp(rgb, 0.0, 1.5);   // allow modest overdrive for bloom
    return half4(half3(rgb), 1.0h);
}
