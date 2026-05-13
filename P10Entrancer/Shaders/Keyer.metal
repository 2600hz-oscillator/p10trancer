#include <metal_stdlib>
using namespace metal;

struct KeyerVOut {
    float4 position [[position]];
    float2 uv;
};

struct KeyerParams {
    int kind;            // 0 = chroma (YCbCr), 1 = luma
    float keyR;
    float keyG;
    float keyB;
    /// For chroma: inner chrominance radius (key is fully transparent
    /// when chroma distance < this). For luma: brightness threshold.
    float tolerance;
    /// Width of the smooth band — alpha ramps from 0 → 1 over
    /// (tolerance, tolerance + softness) for chroma, or
    /// (tolerance − softness, tolerance + softness) for luma.
    float softness;
    /// Chroma key spill suppression strength 0..1. Pulls the chroma
    /// of edge pixels toward neutral so the key color doesn't tint
    /// the subject. Ignored for luma.
    float spill;
    /// Invert the alpha output (so "key" pixels show foreground and
    /// "non-key" show background). Stored as 0 / 1.
    float invert;
};

vertex KeyerVOut keyerVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    KeyerVOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = (positions[vid] + float2(1.0, 1.0)) * 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

/// RGB → HSV. Hue is [0,1) (0 = red, 1/3 = green, 2/3 = blue);
/// saturation + value are [0,1]. Used for chroma keying so the
/// matte is luma-invariant — same hue at any brightness reads as
/// the same "color" (which YCbCr chrominance does NOT — its values
/// scale with luma and break on dark greens).
static inline half3 rgbToHsv(half3 c) {
    half maxc = max(c.r, max(c.g, c.b));
    half minc = min(c.r, min(c.g, c.b));
    half v = maxc;
    half d = maxc - minc;
    half s = (maxc > 0.0001h) ? d / maxc : 0.0h;
    half h = 0.0h;
    if (d > 0.0001h) {
        if (maxc == c.r) {
            h = (c.g - c.b) / d;
            if (h < 0.0h) h += 6.0h;
        } else if (maxc == c.g) {
            h = (c.b - c.r) / d + 2.0h;
        } else {
            h = (c.r - c.g) / d + 4.0h;
        }
        h /= 6.0h;
    }
    return half3(h, s, v);
}

/// Shortest hue distance with wrap-around. Output is in [0, 0.5]
/// where 0 = identical hue, 0.5 = exactly complementary.
static inline half hueDistance(half a, half b) {
    half d = abs(a - b);
    return min(d, 1.0h - d);
}

fragment half4 keyerFragment(
    KeyerVOut in [[stage_in]],
    texture2d<half> fg [[texture(0)]],
    texture2d<half> bg [[texture(1)]],
    constant KeyerParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 fgColor = fg.sample(s, in.uv);
    half4 bgColor = bg.sample(s, in.uv);

    half tol = max(half(params.tolerance), half(0.0));
    half soft = max(half(params.softness), half(0.001));

    half alpha;
    if (params.kind == 0) {
        // Chroma key — HSV hue distance, brightness-invariant.
        // Saturation gate: gray-ish pixels aren't "any color", so
        // we treat them as non-key regardless of where their hue
        // happens to compute. Spill suppression desaturates edge
        // pixels (where alpha is small) — pulls the chroma out so
        // a green-screen halo doesn't tint the comped subject.
        half3 fgHSV  = rgbToHsv(fgColor.rgb);
        half3 keyHSV = rgbToHsv(half3(params.keyR, params.keyG, params.keyB));
        half hd = hueDistance(fgHSV.x, keyHSV.x);
        half satGate = smoothstep(0.04h, 0.18h, fgHSV.y);
        // Convert tolerance/softness (slider 0..1) onto the hue
        // distance range 0..0.5. Tolerance > 0 keeps a band of
        // nearby hues fully transparent; softness extends the
        // ramp band beyond it.
        half tolH = tol * 0.5h;
        half softH = max(soft * 0.5h, 0.001h);
        half hueAlpha = smoothstep(tolH, tolH + softH, hd);
        // satGate < 1 means the pixel is unsaturated → bias alpha
        // toward 1 (keep foreground) so we don't accidentally key
        // grays.
        alpha = mix(1.0h, hueAlpha, satGate);

        if (params.spill > 0.001) {
            half pull = (1.0h - alpha) * half(params.spill);
            // Desaturate the pixel proportional to spill amount.
            half s2 = fgHSV.y * (1.0h - pull);
            // Reconstruct from HSV with reduced saturation.
            // Cheap "back to RGB" via HSV inverse:
            half h6 = fgHSV.x * 6.0h;
            half c2 = fgHSV.z * s2;
            half x2 = c2 * (1.0h - abs(fmod(h6, 2.0h) - 1.0h));
            half3 rgb2;
            if (h6 < 1.0h)      rgb2 = half3(c2, x2, 0.0h);
            else if (h6 < 2.0h) rgb2 = half3(x2, c2, 0.0h);
            else if (h6 < 3.0h) rgb2 = half3(0.0h, c2, x2);
            else if (h6 < 4.0h) rgb2 = half3(0.0h, x2, c2);
            else if (h6 < 5.0h) rgb2 = half3(x2, 0.0h, c2);
            else                rgb2 = half3(c2, 0.0h, x2);
            half m = fgHSV.z - c2;
            fgColor.rgb = saturate(rgb2 + m);
        }
    } else {
        // Luma key — alpha ramps across (tol-soft, tol+soft).
        half luma = dot(fgColor.rgb, half3(0.299h, 0.587h, 0.114h));
        alpha = smoothstep(tol - soft, tol + soft, luma);
    }

    if (params.invert > 0.5h) { alpha = 1.0h - alpha; }

    return half4(mix(bgColor.rgb, fgColor.rgb, alpha), 1.0h);
}
