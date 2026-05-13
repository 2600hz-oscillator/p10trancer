#include <metal_stdlib>
using namespace metal;

struct FBVOut {
    float4 position [[position]];
    float2 uv;
};

struct FBParams {
    float zoom;
    float panX;
    float panY;
    float tilt;       // axis rotation in radians
    /// Per-frame multiplier on the previous-frame sample. With the
    /// additive topology we can run the FULL 0..1 range without
    /// blowing out (the tonemap soft-clamps the sum). 0.94..0.98
    /// gives camera-into-CRT phosphor persistence; 0.999 is "trails
    /// forever". 0.0 disables the feedback.
    float persistence;
    /// How brightly the live source punches in each frame. >1 lets
    /// fresh frames overpower long trails for a strobe-y look; <1
    /// keeps the live signal subtle so the feedback dominates.
    float inputGain;
    /// Pre-tonemap brightness gain. Higher = more highlight bloom
    /// in the rolloff.
    float bloom;
    /// Saturation push on the previous-frame sample to fight chroma
    /// loss in linear sampling.
    float chromaBoost;
};

vertex FBVOut feedbackCameraVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    FBVOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = (positions[vid] + float2(1.0, 1.0)) * 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

/// Camera-feedback fragment.
/// `src` = the pad the virtual camera is "pointed at"
/// `prev` = previous-frame output of THIS feedback unit
/// `prev_uv = (uv − 0.5 − pan*0.5) / zoom + 0.5`
///   - zoom > 1: each frame samples a smaller central crop of `prev` →
///     classic recursive-tunnel / fractal effect.
///   - zoom < 1: samples beyond [0,1] return black via clamp_to_zero,
///     producing a literal black border around the source — the way a
///     real camera "sees off the screen edge".
fragment half4 feedbackCameraFragment(
    FBVOut in [[stage_in]],
    texture2d<half> src [[texture(0)]],
    texture2d<half> prev [[texture(1)]],
    constant FBParams &params [[buffer(0)]]
) {
    constexpr sampler liveSampler(filter::linear, address::clamp_to_edge);
    constexpr sampler tunnelSampler(filter::linear, address::clamp_to_zero);

    float zoom = max(params.zoom, 0.001);
    float2 c = in.uv - 0.5 - float2(params.panX, params.panY) * 0.5;
    float ct = cos(params.tilt);
    float st = sin(params.tilt);
    float2 rot = float2(c.x * ct - c.y * st, c.x * st + c.y * ct);
    float2 prev_uv = rot / zoom + 0.5;
    half3 prevSample = prev.sample(tunnelSampler, prev_uv).rgb;
    half3 srcSample  = src.sample(liveSampler, in.uv).rgb;

    // Saturate the recursive sample so colors don't bleed out over
    // many feedback iterations (linear chain progressively desaturates).
    half3 grey = half3(dot(prevSample, half3(0.299h, 0.587h, 0.114h)));
    prevSample = mix(grey, prevSample, half(params.chromaBoost));

    // ADDITIVE blend. Camera-into-CRT model: the phosphor "remembers"
    // some fraction of last frame's brightness (persistence), and the
    // camera adds the live shot on top. The sum can exceed 1 — the
    // Reinhard-style tonemap below soft-clamps it back into display
    // range with a gentle highlight rolloff, which is exactly what
    // a real CRT does at full beam.
    half3 sum = prevSample * half(params.persistence)
              + srcSample  * half(params.inputGain);

    half b = max(half(params.bloom), 0.001h);
    half3 driven = sum * b;
    // x / (x + 1) tonemap, per channel. Preserves color hue (unlike
    // luma-based tonemaps that desaturate highlights) and asymptotes
    // smoothly to 1 so bright spots don't hard-clip.
    half3 outColor = driven / (driven + 1.0h);
    return half4(outColor, 1.0h);
}
