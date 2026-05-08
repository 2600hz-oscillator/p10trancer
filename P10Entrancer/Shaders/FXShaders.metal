#include <metal_stdlib>
using namespace metal;

struct FXVOut {
    float4 position [[position]];
    float2 uv;
};

vertex FXVOut fxVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    FXVOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = (positions[vid] + float2(1.0, 1.0)) * 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

struct FXBlurParams {
    float radius;
    float _pad0;
    float _pad1;
    float _pad2;
};

fragment half4 fxBlurFragment(
    FXVOut in [[stage_in]],
    texture2d<half> src [[texture(0)]],
    constant FXBlurParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 px = float2(1.0) / float2(src.get_width(), src.get_height());
    float r = max(params.radius, 0.001);
    half4 sum = half4(0.0h);
    float total = 0.0;
    for (int dy = -3; dy <= 3; dy++) {
        for (int dx = -3; dx <= 3; dx++) {
            float w = exp(-float(dx * dx + dy * dy) / (2.0 * r * r * 0.6));
            sum += src.sample(s, in.uv + float2(dx, dy) * px * r) * half(w);
            total += w;
        }
    }
    return sum / half(total);
}

struct FXFeedbackParams {
    float mix;
    float zoom;
    float rotation;
    float decay;
};

fragment half4 fxFeedbackFragment(
    FXVOut in [[stage_in]],
    texture2d<half> src [[texture(0)]],
    texture2d<half> prev [[texture(1)]],
    constant FXFeedbackParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 c = in.uv - 0.5;
    float cs = cos(params.rotation);
    float sn = sin(params.rotation);
    float2 r = float2(cs * c.x - sn * c.y, sn * c.x + cs * c.y) / max(params.zoom, 0.001);
    float2 prevUV = r + 0.5;
    half4 current = src.sample(s, in.uv);
    half4 history = prev.sample(s, prevUV) * half(params.decay);
    return mix(current, history, half(params.mix));
}

struct FXChromaDistortParams {
    float hueShift;
    float saturation;
    float channelOffset;
    float _pad;
};

static inline half3 rgb2hsv(half3 c) {
    half4 K = half4(0.0h, -1.0h/3.0h, 2.0h/3.0h, -1.0h);
    half4 p = mix(half4(c.bg, K.wz), half4(c.gb, K.xy), step(c.b, c.g));
    half4 q = mix(half4(p.xyw, c.r), half4(c.r, p.yzx), step(p.x, c.r));
    half d = q.x - min(q.w, q.y);
    half e = 1.0e-10h;
    return half3(abs(q.z + (q.w - q.y) / (6.0h * d + e)), d / (q.x + e), q.x);
}

static inline half3 hsv2rgb(half3 c) {
    half4 K = half4(1.0h, 2.0h/3.0h, 1.0h/3.0h, 3.0h);
    half3 p = abs(fract(c.xxx + K.xyz) * 6.0h - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0h, 1.0h), c.y);
}

fragment half4 fxChromaDistortFragment(
    FXVOut in [[stage_in]],
    texture2d<half> src [[texture(0)]],
    constant FXChromaDistortParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float ofs = params.channelOffset * 0.02;
    half r = src.sample(s, in.uv + float2(ofs, 0)).r;
    half g = src.sample(s, in.uv).g;
    half b = src.sample(s, in.uv - float2(ofs, 0)).b;
    half3 rgb = half3(r, g, b);
    half3 hsv = rgb2hsv(rgb);
    hsv.x = fract(hsv.x + half(params.hueShift));
    hsv.y = clamp(hsv.y * half(params.saturation), 0.0h, 1.0h);
    return half4(hsv2rgb(hsv), 1.0h);
}

struct FXYUVPhaserParams {
    float phase;
    float depth;
    float _pad0;
    float _pad1;
};

static inline half3 rgb2yuv(half3 rgb) {
    half y = dot(rgb, half3(0.299h, 0.587h, 0.114h));
    half u = dot(rgb, half3(-0.14713h, -0.28886h, 0.436h));
    half v = dot(rgb, half3(0.615h, -0.51499h, -0.10001h));
    return half3(y, u, v);
}

static inline half3 yuv2rgb(half3 yuv) {
    half r = yuv.x + 1.13983h * yuv.z;
    half g = yuv.x - 0.39465h * yuv.y - 0.58060h * yuv.z;
    half b = yuv.x + 2.03211h * yuv.y;
    return half3(r, g, b);
}

fragment half4 fxYUVPhaserFragment(
    FXVOut in [[stage_in]],
    texture2d<half> src [[texture(0)]],
    constant FXYUVPhaserParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half3 yuv = rgb2yuv(src.sample(s, in.uv).rgb);
    float a = params.phase * 6.28318;
    float cs = cos(a);
    float sn = sin(a);
    float depth = params.depth;
    half u = yuv.y * half(cs) - yuv.z * half(sn);
    half v = yuv.y * half(sn) + yuv.z * half(cs);
    yuv.y = mix(yuv.y, u, half(depth));
    yuv.z = mix(yuv.z, v, half(depth));
    return half4(yuv2rgb(yuv), 1.0h);
}

struct FXLumaPhaserParams {
    float phase;
    float strength;
    float curve;
    float _pad;
};

fragment half4 fxLumaPhaserFragment(
    FXVOut in [[stage_in]],
    texture2d<half> src [[texture(0)]],
    constant FXLumaPhaserParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 c = src.sample(s, in.uv);
    half y = dot(c.rgb, half3(0.299h, 0.587h, 0.114h));
    half ymod = sin(half(y) * 6.28318h * half(params.curve) + half(params.phase) * 6.28318h);
    half delta = ymod * half(params.strength);
    half3 rgb = clamp(c.rgb + half3(delta), 0.0h, 1.0h);
    return half4(rgb, 1.0h);
}

struct FXEdgeEnhanceParams {
    float strength;
    float _pad0;
    float _pad1;
    float _pad2;
};

fragment half4 fxEdgeEnhanceFragment(
    FXVOut in [[stage_in]],
    texture2d<half> src [[texture(0)]],
    constant FXEdgeEnhanceParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 px = float2(1.0) / float2(src.get_width(), src.get_height());

    half3 tl = src.sample(s, in.uv + float2(-px.x, -px.y)).rgb;
    half3 t  = src.sample(s, in.uv + float2(0,    -px.y)).rgb;
    half3 tr = src.sample(s, in.uv + float2( px.x, -px.y)).rgb;
    half3 l  = src.sample(s, in.uv + float2(-px.x, 0)).rgb;
    half3 c  = src.sample(s, in.uv).rgb;
    half3 r  = src.sample(s, in.uv + float2( px.x, 0)).rgb;
    half3 bl = src.sample(s, in.uv + float2(-px.x,  px.y)).rgb;
    half3 b  = src.sample(s, in.uv + float2(0,     px.y)).rgb;
    half3 br = src.sample(s, in.uv + float2( px.x,  px.y)).rgb;

    half3 gx = (tr + 2.0h * r + br) - (tl + 2.0h * l + bl);
    half3 gy = (bl + 2.0h * b + br) - (tl + 2.0h * t + tr);
    half gxLuma = (gx.x + gx.y + gx.z) / 3.0h;
    half gyLuma = (gy.x + gy.y + gy.z) / 3.0h;
    half edge = sqrt(gxLuma * gxLuma + gyLuma * gyLuma);

    half3 result = c + (c - (tl + t + tr + l + r + bl + b + br) / 8.0h) * half(params.strength);
    result = clamp(result, 0.0h, 1.0h);
    half3 highlight = mix(result, half3(1.0h), min(edge * half(params.strength) * 0.5h, 1.0h));
    return half4(mix(result, highlight, half(0.4h * params.strength)), 1.0h);
}
