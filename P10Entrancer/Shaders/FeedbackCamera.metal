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
    float decay;
    float feedbackMix;
    float luminosity;
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
    // Center, pan, rotate by tilt (camera roll), zoom, re-center.
    float2 c = in.uv - 0.5 - float2(params.panX, params.panY) * 0.5;
    float ct = cos(params.tilt);
    float st = sin(params.tilt);
    float2 rot = float2(c.x * ct - c.y * st, c.x * st + c.y * ct);
    float2 prev_uv = rot / zoom + 0.5;
    half4 prevSample = prev.sample(tunnelSampler, prev_uv) * half(params.decay);
    half4 srcSample = src.sample(liveSampler, in.uv);

    // Boost luminosity + saturation on the recursive sample so it doesn't
    // darken / desaturate over many feedback iterations.
    half3 prevRGB = prevSample.rgb * half(params.luminosity);
    half3 grey = half3(dot(prevRGB, half3(0.299h, 0.587h, 0.114h)));
    prevRGB = mix(grey, prevRGB, half(params.chromaBoost));

    // Mix the live source with the recursive feedback. Higher feedbackMix =
    // more fractal carry-over; lower = more "live" with mild trails.
    half mixAmount = half(params.feedbackMix);
    half3 outColor = mix(srcSample.rgb, prevRGB, mixAmount);
    return half4(outColor, 1.0h);
}
