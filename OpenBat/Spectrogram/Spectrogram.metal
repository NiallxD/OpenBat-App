//
//  Spectrogram.metal
//  OpenBat
//
//  Full-screen pass that samples the rolling spectrogram texture (a ring buffer
//  of FFT columns) and maps intensity through an inferno-style colormap.
//  X = time (newest at right), Y = frequency (low at bottom, ~192 kHz at top).
//

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut spectro_vertex(uint vid [[vertex_id]]) {
    // Triangle strip covering clip space.
    float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 p = corners[vid];
    VertexOut out;
    out.position = float4(p, 0, 1);
    out.uv = float2((p.x + 1) * 0.5, (p.y + 1) * 0.5); // uv.y = 0 at bottom
    return out;
}

static float3 colormap(float t) {
    t = clamp(t, 0.0, 1.0);
    const float3 c0 = float3(0.001, 0.000, 0.014); // near-black
    const float3 c1 = float3(0.215, 0.036, 0.405); // purple
    const float3 c2 = float3(0.575, 0.149, 0.404); // magenta
    const float3 c3 = float3(0.868, 0.288, 0.245); // red-orange
    const float3 c4 = float3(0.988, 0.645, 0.040); // orange
    const float3 c5 = float3(0.988, 0.998, 0.645); // pale yellow
    if (t < 0.2)  return mix(c0, c1, t / 0.2);
    if (t < 0.4)  return mix(c1, c2, (t - 0.2) / 0.2);
    if (t < 0.6)  return mix(c2, c3, (t - 0.4) / 0.2);
    if (t < 0.8)  return mix(c3, c4, (t - 0.6) / 0.2);
    return mix(c4, c5, (t - 0.8) / 0.2);
}

fragment float4 spectro_fragment(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 constant float &rightEdge [[buffer(0)]],
                                 constant float &windowLen [[buffer(1)]],
                                 constant float &texWidth [[buffer(2)]],
                                 constant float &bandLow [[buffer(3)]],
                                 constant float &bandHigh [[buffer(4)]],
                                 constant float &noiseFloor [[buffer(5)]]) {
    // Linear filtering + repeat wrapping gives smooth sub-column scrolling across
    // the ring buffer as `rightEdge` advances by fractional columns each frame.
    constexpr sampler smp(filter::linear, address::repeat);

    // Time: the right edge sits at column `rightEdge`; the visible window spans
    // `windowLen` columns to its left. The texture is wider than the window (the
    // extra is a write guard), so map through `texWidth`.
    float column = rightEdge - (1.0 - in.uv.x) * windowLen;
    float u = fmod(column + texWidth, texWidth) / texWidth;

    // Frequency: texture row 0 = lowest bin (0 Hz), row count = Nyquist. Crop to
    // the [bandLow, bandHigh] fraction so the band fills the view.
    float v = bandLow + in.uv.y * (bandHigh - bandLow);

    float intensity = tex.sample(smp, float2(u, v)).r;
    // Noise gate + contrast stretch: drop everything below the floor, rescale the
    // rest to [0, 1] so the colormap's full range covers the signal above it.
    intensity = max(0.0, (intensity - noiseFloor) / max(0.01, 1.0 - noiseFloor));
    return float4(colormap(intensity), 1.0);
}
