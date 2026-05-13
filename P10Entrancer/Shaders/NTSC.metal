#include <metal_stdlib>
using namespace metal;

struct NTSCVOut {
    float4 position [[position]];
    float2 uv;
};

vertex NTSCVOut ntscVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    NTSCVOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = (positions[vid] + float2(1.0, 1.0)) * 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

constant int NTSC_OVERSAMPLE = 4;
constant float NTSC_SUBCARRIER_PERIOD = 4.0;

struct NTSCEncodeParams {
    float compositeWidth;
    float burstPhaseShift;
    float subcarrierDrift;
    float time;
    float ycDelay;
    float _pad0;
    float _pad1;
    float _pad2;
};

struct NTSCGlitchParams {
    float chromaBoost;
    float lumaNoise;
    float chromaNoise;
    float hsyncWobble;
    float dropoutRate;
    float dropoutSeed;
    float compositeWidth;
    float compositeHeight;
};

struct NTSCDecodeParams {
    float compositeWidth;
    float combStrength;
    float lumaPeaking;
    float _pad0;
};

static inline half3 rgbToYIQ(half3 rgb) {
    half y = dot(rgb, half3(0.299h, 0.587h, 0.114h));
    half i = dot(rgb, half3(0.596h, -0.275h, -0.321h));
    half q = dot(rgb, half3(0.212h, -0.523h, 0.311h));
    return half3(y, i, q);
}

static inline half3 yiqToRGB(half3 yiq) {
    half r = yiq.x + 0.956h * yiq.y + 0.621h * yiq.z;
    half g = yiq.x - 0.272h * yiq.y - 0.647h * yiq.z;
    half b = yiq.x - 1.106h * yiq.y + 1.703h * yiq.z;
    return half3(r, g, b);
}

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

fragment half4 ntscEncodeFragment(
    NTSCVOut in [[stage_in]],
    texture2d<half> src [[texture(0)]],
    constant NTSCEncodeParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;

    half3 rgb = src.sample(s, uv).rgb;
    half3 yiq = rgbToYIQ(rgb);

    float t = uv.x * params.compositeWidth;
    float burstPhase = (params.burstPhaseShift + params.subcarrierDrift * params.time) * 6.2831853;
    float phase = 6.2831853 * t / NTSC_SUBCARRIER_PERIOD + burstPhase;

    half3 yiqShifted = yiq;
    if (params.ycDelay != 0.0) {
        float2 shiftedUV = uv + float2(params.ycDelay / params.compositeWidth, 0);
        half3 chromaSample = rgbToYIQ(src.sample(s, shiftedUV).rgb);
        yiqShifted = half3(yiq.x, chromaSample.y, chromaSample.z);
    }

    half cs = half(cos(phase));
    half sn = half(sin(phase));
    half composite = yiqShifted.x + yiqShifted.y * cs + yiqShifted.z * sn;
    return half4(composite, yiqShifted.x, yiqShifted.y, yiqShifted.z);
}

fragment half4 ntscGlitchFragment(
    NTSCVOut in [[stage_in]],
    texture2d<half> composite [[texture(0)]],
    constant NTSCGlitchParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;

    if (params.hsyncWobble > 0.0) {
        float lineNoise = hash21(float2(uv.y * params.compositeHeight, params.dropoutSeed));
        float wobble = (lineNoise - 0.5) * 2.0 * params.hsyncWobble * 0.05;
        uv.x += wobble;
    }

    half4 sampleC = composite.sample(s, uv);
    half compositeValue = sampleC.x;
    half luma = sampleC.y;

    float lineY = uv.y * params.compositeHeight;
    if (params.dropoutRate > 0.0) {
        float dropHash = hash21(float2(floor(lineY), floor(uv.x * params.compositeWidth / 8.0) + params.dropoutSeed));
        if (dropHash < params.dropoutRate * 0.05) {
            compositeValue = luma;
        }
    }

    if (params.lumaNoise > 0.0) {
        float n = hash21(float2(uv.x * params.compositeWidth, lineY * 2.0 + params.dropoutSeed));
        compositeValue += half((n - 0.5) * 2.0 * params.lumaNoise);
    }

    half3 chromaPart = half3(0.0h, sampleC.z, sampleC.w) * half(params.chromaBoost - 1.0);
    half boostedComposite = compositeValue + chromaPart.y * 0.0h + chromaPart.z * 0.0h;

    if (params.chromaBoost != 1.0) {
        half chromaContribution = compositeValue - luma;
        boostedComposite = luma + chromaContribution * half(params.chromaBoost);
    } else {
        boostedComposite = compositeValue;
    }

    if (params.chromaNoise > 0.0) {
        float n = hash21(float2(uv.x * params.compositeWidth + 100.0, lineY + params.dropoutSeed));
        boostedComposite += half((n - 0.5) * 2.0 * params.chromaNoise * 0.5);
    }

    return half4(boostedComposite, sampleC.y, sampleC.z, sampleC.w);
}

fragment half4 ntscDecodeFragment(
    NTSCVOut in [[stage_in]],
    texture2d<half> composite [[texture(0)]],
    constant NTSCDecodeParams &params [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float pxStep = 1.0 / params.compositeWidth;
    int N = 6;

    half ySum = 0.0h;
    half iSum = 0.0h;
    half qSum = 0.0h;
    half weightSum = 0.0h;

    for (int k = -N; k <= N; k++) {
        float2 uv = in.uv + float2(float(k) * pxStep, 0);
        half c = composite.sample(s, uv).x;
        float t = uv.x * params.compositeWidth;
        float phase = 6.2831853 * t / NTSC_SUBCARRIER_PERIOD;
        half w = half(exp(-float(k * k) / float(N * N) * 2.0));
        ySum += c * w;
        iSum += c * 2.0h * half(cos(phase)) * w;
        qSum += c * 2.0h * half(sin(phase)) * w;
        weightSum += w;
    }

    half y = ySum / weightSum;
    half i = iSum / weightSum;
    half q = qSum / weightSum;

    if (params.lumaPeaking > 0.0) {
        half center = composite.sample(s, in.uv).x;
        half left = composite.sample(s, in.uv + float2(-pxStep, 0)).x;
        half right = composite.sample(s, in.uv + float2(pxStep, 0)).x;
        half hf = center - (left + right) * 0.5h;
        y += hf * half(params.lumaPeaking);
    }

    half3 rgb = clamp(yiqToRGB(half3(y, i, q)), 0.0h, 1.0h);
    return half4(rgb, 1.0h);
}
