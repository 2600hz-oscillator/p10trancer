#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut gridVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    VOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = (positions[vid] + float2(1.0, 1.0)) * 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

struct GridParams {
    float cellAspect;
    /// Fraction of each cell's width reserved on the LEFT for the
    /// SwiftUI per-pad volume slider. The pad's video is rendered
    /// in the remaining (1 - leftMargin) on the right; the slider
    /// strip is filled with a dark BG so the SwiftUI slider drawn
    /// on top reads cleanly. 0 = no margin (legacy full-cell).
    float leftMargin;
    float _pad1;
    float _pad2;
};

fragment half4 gridFragment(
    VOut in [[stage_in]],
    texture2d<half> p0 [[texture(0)]],
    texture2d<half> p1 [[texture(1)]],
    texture2d<half> p2 [[texture(2)]],
    texture2d<half> p3 [[texture(3)]],
    texture2d<half> p4 [[texture(4)]],
    texture2d<half> p5 [[texture(5)]],
    texture2d<half> p6 [[texture(6)]],
    texture2d<half> p7 [[texture(7)]],
    texture2d<half> p8 [[texture(8)]],
    constant GridParams &params [[buffer(0)]],
    constant float *padAspects [[buffer(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 cell = floor(uv * 3.0);
    float2 inCell = fract(uv * 3.0);
    int idx = int(cell.y) * 3 + int(cell.x);

    // Reserve a slim strip on the LEFT of every cell for the per-pad
    // volume slider drawn by SwiftUI on top. Pad video only renders
    // in the inCell.x range [leftMargin, 1.0].
    float leftMargin = params.leftMargin;
    if (inCell.x < leftMargin) {
        return half4(0.04h, 0.04h, 0.06h, 1.0h);
    }
    // Remap the surviving (1 - leftMargin) horizontal strip back to
    // [0, 1] for the aspect-fit math below.
    float2 padInCell = float2((inCell.x - leftMargin) / max(0.0001, 1.0 - leftMargin),
                              inCell.y);
    float padCellAspect = params.cellAspect * (1.0 - leftMargin);

    float srcAspect = padAspects[idx];
    if (srcAspect <= 0.0) { srcAspect = 16.0 / 9.0; }
    float scaleX = 1.0;
    float scaleY = 1.0;
    if (padCellAspect > srcAspect) {
        scaleX = padCellAspect / srcAspect;
    } else {
        scaleY = srcAspect / padCellAspect;
    }
    float2 fitUV = (padInCell - 0.5) * float2(scaleX, scaleY) + 0.5;

    half4 c;
    if (any(fitUV < float2(0.0)) || any(fitUV > float2(1.0))) {
        c = half4(0.0h, 0.0h, 0.0h, 1.0h);
    } else {
        switch (idx) {
            case 0: c = p0.sample(s, fitUV); break;
            case 1: c = p1.sample(s, fitUV); break;
            case 2: c = p2.sample(s, fitUV); break;
            case 3: c = p3.sample(s, fitUV); break;
            case 4: c = p4.sample(s, fitUV); break;
            case 5: c = p5.sample(s, fitUV); break;
            case 6: c = p6.sample(s, fitUV); break;
            case 7: c = p7.sample(s, fitUV); break;
            default: c = p8.sample(s, fitUV); break;
        }
    }

    // Border darkens the edge of the pad-video sub-rect (not the
    // full cell — the slider strip stays its own region).
    float2 d = abs(padInCell - 0.5);
    float edgeDist = max(d.x, d.y);
    float border = smoothstep(0.485, 0.5, edgeDist);
    c.rgb = mix(c.rgb, half3(0.04h, 0.04h, 0.06h), half(border));
    return c;
}
