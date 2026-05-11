#include <metal_stdlib>
using namespace metal;

// XYZ raster scope: forward-scatter (not coord-remap). The vertex
// shader walks a grid of source-pixel sample points, reads luma at
// each one, and emits an output vertex whose POSITION is the
// shaped H/V ramp plus a luma-scaled displacement. The fragment
// shader draws lines between adjacent column-vertices in each row
// — classic Rutt-Etra: bright pixels push their scanline outward,
// dark pixels leave it flat, producing the "3D heightmap" look
// natively rather than warping the underlying raster.

struct XYZParams {
    float xShape;     // 0=linear, 0.333=triangle, 0.666=soft-fold, 1=radial
    float yShape;
    float xDisp;      // luma * xDisp added to ramp-X (lateral wiggle)
    float yDisp;      // luma * yDisp added to ramp-Y (heightmap)
    float intensity;  // brightness multiplier on emitted color
    float tintR;
    float tintG;
    float tintB;
    float xFreq;      // shaped-ramp frequency (1=one sweep, 2=two, etc.)
    float yFreq;
    float xPhase;
    float yPhase;
    uint  cols;       // horizontal scan-sample count
    uint  rows;       // vertical scan-sample count
};

struct XYZVertOut {
    float4 position [[position]];
    half3 color;
};

float shapedRamp(float t, float2 uv, float morph) {
    float lin = fract(t);
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

vertex XYZVertOut xyzVertex(
    uint vid [[vertex_id]],
    texture2d<float> srcTex [[texture(0)]],
    constant XYZParams &params [[buffer(0)]]
) {
    uint col = vid % params.cols;
    uint row = vid / params.cols;
    float h0 = float(col) / float(params.cols - 1);
    float v0 = float(row) / float(params.rows - 1);

    // Sample the source at the raw (h0, v0) — luma drives the
    // displacement, color comes out as-is.
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 src = srcTex.sample(s, float2(h0, v0));
    float lum = dot(src.rgb, float3(0.299, 0.587, 0.114));

    // Apply shaped ramps to get the base H/V position. Default
    // morph 0 = linear, so the unshaped raster reproduces the
    // source 1:1 before luma displacement.
    float h = shapedRamp(h0 * params.xFreq + params.xPhase, float2(h0, v0), params.xShape);
    float v = shapedRamp(v0 * params.yFreq + params.yPhase, float2(h0, v0), params.yShape);

    // Bipolar displacement (luma - 0.5 so mid-grey doesn't move).
    float x = h + (lum - 0.5) * params.xDisp;
    float y = v + (lum - 0.5) * params.yDisp;

    // [0,1] → NDC. Metal's NDC is y-up; our UVs are y-down, so flip.
    float ndcX = x * 2.0 - 1.0;
    float ndcY = 1.0 - y * 2.0;

    XYZVertOut out;
    out.position = float4(ndcX, ndcY, 0.0, 1.0);
    half3 color = half3(src.rgb * params.intensity *
                        float3(params.tintR, params.tintG, params.tintB));
    out.color = color;
    return out;
}

fragment half4 xyzFragment(XYZVertOut in [[stage_in]]) {
    return half4(in.color, 1.0h);
}
