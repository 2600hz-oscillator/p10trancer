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
    float _pad0;
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
    constant GridParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 cell = floor(uv * 3.0);
    float2 inCell = fract(uv * 3.0);
    int idx = int(cell.y) * 3 + int(cell.x);

    // Aspect-fit: each cell on screen has aspect = params.cellAspect, source is 16:9 = 1.778.
    // If cell wider than source: letterbox horizontally (pillarbox); shrink uv.x toward center.
    // If cell taller than source: letterbox vertically.
    float srcAspect = 16.0 / 9.0;
    float scaleX = 1.0;
    float scaleY = 1.0;
    if (params.cellAspect > srcAspect) {
        scaleX = params.cellAspect / srcAspect;
    } else {
        scaleY = srcAspect / params.cellAspect;
    }
    float2 fitUV = (inCell - 0.5) * float2(scaleX, scaleY) + 0.5;

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

    float2 d = abs(inCell - 0.5);
    float edgeDist = max(d.x, d.y);
    float border = smoothstep(0.485, 0.5, edgeDist);
    c.rgb = mix(c.rgb, half3(0.04h, 0.04h, 0.06h), half(border));
    return c;
}
