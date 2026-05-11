#include <metal_stdlib>
using namespace metal;

// Rutt-Etra-flavored 2D coordinate remap fused with the SHAPEDRAMPS
// continuous-morph coord field. Three shaped-ramp modes per axis
// (linear / triangle / soft-fold / radial) crossfaded by the
// xShape / yShape morph parameter. Luma of the source displaces
// the final sample coordinate, producing the Rutt-Etra effect on
// any video pad routed in.

struct XYZParams {
    float xShape;     // 0=linear, 0.333=triangle, 0.666=soft-fold, 1=radial
    float yShape;
    float xDisp;      // luma-driven displacement strength, X
    float yDisp;
    float intensity;  // output multiplier
    float tintR;
    float tintG;
    float tintB;
    float xFreq;      // ramp frequency (1.0 = single sweep across screen)
    float yFreq;
    float xPhase;
    float yPhase;
};

struct XYZVertOut {
    float4 position [[position]];
    float2 uv;
};

vertex XYZVertOut xyzVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    XYZVertOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = (positions[vid] + float2(1.0, 1.0)) * 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

// Generates the X or Y coord field at uv, morphed continuously
// between linear / triangle / soft-fold / radial as `morph` sweeps
// 0..1.
float shapedRamp(float t, float2 uv, float morph) {
    float lin = clamp(t, 0.0, 1.0);
    float tri = abs(2.0 * lin - 1.0);
    float sf = 0.5 - 0.5 * cos(2.0 * M_PI_F * lin);
    float radial = clamp(length(uv - 0.5) * 1.41421356, 0.0, 1.0);
    morph = clamp(morph, 0.0, 1.0);
    if (morph < 0.333) {
        return mix(lin, tri, morph * 3.0);
    } else if (morph < 0.666) {
        return mix(tri, sf, (morph - 0.333) * 3.0);
    } else {
        return mix(sf, radial, (morph - 0.666) * 3.0);
    }
}

float luma(float3 rgb) {
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

fragment half4 xyzFragment(
    XYZVertOut in [[stage_in]],
    texture2d<float> zTex [[texture(0)]],
    constant XYZParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float rampX = shapedRamp(in.uv.x * params.xFreq + params.xPhase, in.uv, params.xShape);
    float rampY = shapedRamp(in.uv.y * params.yFreq + params.yPhase, in.uv, params.yShape);
    float l = luma(zTex.sample(s, in.uv).rgb);
    float finalU = rampX + (l - 0.5) * params.xDisp;
    float finalV = rampY + (l - 0.5) * params.yDisp;
    float3 sampled = zTex.sample(s, clamp(float2(finalU, finalV), 0.0, 1.0)).rgb;
    float3 tinted = sampled * float3(params.tintR, params.tintG, params.tintB) * params.intensity;
    return half4(half3(tinted), 1.0);
}
