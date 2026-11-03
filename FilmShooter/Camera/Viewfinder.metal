#include <metal_stdlib>
using namespace metal;

// Must match `ViewfinderUniforms` in ViewfinderRenderer.swift (64 bytes).
struct VFUniforms {
    float2 uvScale;     // aspect-fill crop
    float2 uvOffset;
    float2 pixelUV;     // camera-uv footprint of one drawable pixel
    float lutScaleA;    // (N-1)/N of the previous LUT
    float lutBiasA;     // 0.5/N
    float lutScaleB;    // current LUT
    float lutBiasB;
    float mixT;         // 0 = previous LUT, 1 = current LUT
    float grain;        // grain amplitude (already scaled)
    float mono;         // 1 = monochrome grain
    float supersample;  // 1 = 4-tap box filter (frame larger than the drawable)
    uint frame;         // grain seed
    uint pad;
};

struct VFVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Full-screen triangle from the vertex id; uv (0,0) is the top-left of the image.
vertex VFVertexOut vf_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
    VFVertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// PCG3D hash (Jarzynski & Olano 2020).
static inline uint3 vf_pcg3d(uint3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

// Hash to a signed value in [-1, 1).
static inline float vf_signed(uint h) {
    return float(h >> 8) * (2.0 / 16777216.0) - 1.0;
}

fragment half4 vf_fragment(VFVertexOut in [[stage_in]],
                           texture2d<float> camera [[texture(0)]],
                           texture3d<float> lutA [[texture(1)]],
                           texture3d<float> lutB [[texture(2)]],
                           constant VFUniforms &u [[buffer(0)]]) {
    constexpr sampler camSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler lutSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    // BGRA8 is sampled as rgba; values stay sRGB-encoded (the LUT's domain).
    float2 uv = in.uv * u.uvScale + u.uvOffset;
    float3 c;
    if (u.supersample > 0.5) {
        // Downscaling: average four bilinear taps across the pixel footprint.
        float2 d = 0.25 * u.pixelUV;
        c = 0.25 * (camera.sample(camSampler, uv + float2(-d.x, -d.y)).rgb +
                    camera.sample(camSampler, uv + float2( d.x, -d.y)).rgb +
                    camera.sample(camSampler, uv + float2(-d.x,  d.y)).rgb +
                    camera.sample(camSampler, uv + float2( d.x,  d.y)).rgb);
    } else {
        c = camera.sample(camSampler, uv).rgb;
    }
    c = saturate(c);

    float3 graded = lutB.sample(lutSampler, c * u.lutScaleB + u.lutBiasB).rgb;
    if (u.mixT < 1.0) {
        float3 previous = lutA.sample(lutSampler, c * u.lutScaleA + u.lutBiasA).rgb;
        graded = mix(previous, graded, u.mixT);
    }

    if (u.grain > 0.0) {
        // Smooth value noise on a ~1.5 px lattice, reseeded every frame.
        float2 gp = in.position.xy * (1.0 / 1.5);
        float2 cell = floor(gp);
        float2 f = gp - cell;
        f = f * f * (3.0 - 2.0 * f);
        uint2 ic = uint2(cell);
        uint3 h00 = vf_pcg3d(uint3(ic, u.frame));
        uint3 h10 = vf_pcg3d(uint3(ic + uint2(1u, 0u), u.frame));
        uint3 h01 = vf_pcg3d(uint3(ic + uint2(0u, 1u), u.frame));
        uint3 h11 = vf_pcg3d(uint3(ic + uint2(1u, 1u), u.frame));
        float n = mix(mix(vf_signed(h00.x), vf_signed(h10.x), f.x),
                      mix(vf_signed(h01.x), vf_signed(h11.x), f.x), f.y);
        n *= 1.35; // restore the variance lost to interpolation

        float3 g = float3(n);
        if (u.mono < 0.5) {
            // A touch of dye-cloud colour for colour stocks.
            float3 chroma = float3(vf_signed(h00.y), vf_signed(h00.z), vf_signed(h11.y));
            g += 0.3 * (chroma - dot(chroma, float3(1.0 / 3.0)));
        }

        // Strongest in the mid-tones, fading in deep shadows and highlights.
        float luma = dot(graded, float3(0.2126, 0.7152, 0.0722));
        float weight = sqrt(saturate(4.0 * luma * (1.0 - luma)));
        graded += g * (u.grain * weight);
    }

    return half4(half3(saturate(graded)), 1.0h);
}
