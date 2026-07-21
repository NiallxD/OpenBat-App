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

// Selectable display palettes. Stop tables MUST mirror `DisplayPalette.swift`
// (the CPU-side pulse-view/thumbnail colormap) exactly — see that file's header
// comment. Palette index (Swift `Palette.rawValue`): 0 inferno, 1 viridis,
// 2 magma, 3 greyscale, 4 jet, 5 plasma, 6 neon.

static float3 infernoColormap(float t) {
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

static float3 viridisColormap(float t) {
    const float3 c0 = float3(0.267, 0.005, 0.329);
    const float3 c1 = float3(0.231, 0.322, 0.545);
    const float3 c2 = float3(0.128, 0.565, 0.551);
    const float3 c3 = float3(0.369, 0.788, 0.384);
    const float3 c4 = float3(0.993, 0.906, 0.144);
    if (t < 0.25) return mix(c0, c1, t / 0.25);
    if (t < 0.50) return mix(c1, c2, (t - 0.25) / 0.25);
    if (t < 0.75) return mix(c2, c3, (t - 0.50) / 0.25);
    return mix(c3, c4, (t - 0.75) / 0.25);
}

static float3 magmaColormap(float t) {
    const float3 c0 = float3(0.001, 0.000, 0.016);
    const float3 c1 = float3(0.316, 0.071, 0.485);
    const float3 c2 = float3(0.716, 0.215, 0.475);
    const float3 c3 = float3(0.988, 0.538, 0.380);
    const float3 c4 = float3(0.988, 0.992, 0.749);
    if (t < 0.25) return mix(c0, c1, t / 0.25);
    if (t < 0.50) return mix(c1, c2, (t - 0.25) / 0.25);
    if (t < 0.75) return mix(c2, c3, (t - 0.50) / 0.25);
    return mix(c3, c4, (t - 0.75) / 0.25);
}

// Classic "thermal camera" rainbow — nostalgic, high-contrast, genuinely funky.
static float3 jetColormap(float t) {
    const float3 c0 = float3(0.000, 0.000, 0.500);
    const float3 c1 = float3(0.000, 0.000, 1.000);
    const float3 c2 = float3(0.000, 1.000, 1.000);
    const float3 c3 = float3(1.000, 1.000, 0.000);
    const float3 c4 = float3(1.000, 0.000, 0.000);
    const float3 c5 = float3(0.500, 0.000, 0.000);
    if (t < 0.125) return mix(c0, c1, t / 0.125);
    if (t < 0.375) return mix(c1, c2, (t - 0.125) / 0.25);
    if (t < 0.625) return mix(c2, c3, (t - 0.375) / 0.25);
    if (t < 0.875) return mix(c3, c4, (t - 0.625) / 0.25);
    return mix(c4, c5, (t - 0.875) / 0.125);
}

// Matplotlib plasma — vivid purple → magenta → orange → yellow.
static float3 plasmaColormap(float t) {
    const float3 c0 = float3(0.050, 0.030, 0.528);
    const float3 c1 = float3(0.494, 0.012, 0.658);
    const float3 c2 = float3(0.798, 0.280, 0.469);
    const float3 c3 = float3(0.973, 0.585, 0.253);
    const float3 c4 = float3(0.940, 0.975, 0.131);
    if (t < 0.25) return mix(c0, c1, t / 0.25);
    if (t < 0.50) return mix(c1, c2, (t - 0.25) / 0.25);
    if (t < 0.75) return mix(c2, c3, (t - 0.50) / 0.25);
    return mix(c3, c4, (t - 0.75) / 0.25);
}

// Synthwave-style neon — black → magenta → cyan → white.
static float3 neonColormap(float t) {
    const float3 c0 = float3(0.000, 0.000, 0.050);
    const float3 c1 = float3(0.850, 0.000, 0.850);
    const float3 c2 = float3(0.000, 0.850, 0.950);
    const float3 c3 = float3(1.000, 1.000, 1.000);
    if (t < 0.30) return mix(c0, c1, t / 0.30);
    if (t < 0.60) return mix(c1, c2, (t - 0.30) / 0.30);
    return mix(c2, c3, (t - 0.60) / 0.40);
}

static float3 colormap(float t, float paletteIndex) {
    t = clamp(t, 0.0, 1.0);
    int p = int(paletteIndex + 0.5);
    float3 c;
    if      (p == 1) c = viridisColormap(t);
    else if (p == 2) c = magmaColormap(t);
    else if (p == 3) c = float3(t, t, t);
    else if (p == 4) c = jetColormap(t);
    else if (p == 5) c = plasmaColormap(t);
    else if (p == 6) c = neonColormap(t);
    else             c = infernoColormap(t);
    // Fade the bottom of every palette to black so silence renders dark even for
    // palettes whose t=0 stop is a saturated colour (viridis, jet, plasma).
    // Mirrors the identical fade in DisplayColormap.rgb (DisplayPalette.swift).
    return c * min(t / 0.12, 1.0);
}

fragment float4 spectro_fragment(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 constant float &rightEdge [[buffer(0)]],
                                 constant float &windowLen [[buffer(1)]],
                                 constant float &texWidth [[buffer(2)]],
                                 constant float &bandLow [[buffer(3)]],
                                 constant float &bandHigh [[buffer(4)]],
                                 constant float &noiseFloor [[buffer(5)]],
                                 constant float &isRing [[buffer(6)]],
                                 constant float &paletteIndex [[buffer(7)]],
                                 constant float &logFreq [[buffer(8)]]) {
    // Ring texture: repeat wrapping gives smooth sub-column scrolling as `rightEdge`
    // advances by fractional columns each frame. Seek texture is linear (not a
    // ring) — repeat-wrapping it would blend in texels from the opposite edge near
    // the visible window's boundary, so it gets clamp_to_edge instead.
    constexpr sampler ringSampler(filter::linear, address::repeat);
    constexpr sampler seekSampler(filter::linear, address::clamp_to_edge);
    bool ring = isRing > 0.5;

    // Time: the right edge sits at column `rightEdge`; the visible window spans
    // `windowLen` columns to its left. The texture is wider than the window (the
    // extra is a write guard), so map through `texWidth`.
    float column = rightEdge - (1.0 - in.uv.x) * windowLen;
    float u = fmod(column + texWidth, texWidth) / texWidth;

    // Frequency: texture row 0 = lowest bin (0 Hz), row count = Nyquist. Crop to
    // the [bandLow, bandHigh] fraction so the band fills the view. Log mode spaces
    // rows logarithmically across the same crop instead of linearly, giving low
    // frequencies (where most calls' harmonic detail sits) more screen height —
    // clamped to a small positive floor since log(0) is undefined and a 0 Hz low
    // edge is the common default.
    float v;
    if (logFreq > 0.5) {
        float lo = max(bandLow, 0.01);
        float hi = max(bandHigh, lo * 1.001);
        v = lo * exp(in.uv.y * log(hi / lo));
    } else {
        v = bandLow + in.uv.y * (bandHigh - bandLow);
    }

    float intensity = ring ? tex.sample(ringSampler, float2(u, v)).r
                           : tex.sample(seekSampler, float2(u, v)).r;
    // Noise gate + contrast stretch: drop everything below the floor, rescale the
    // rest to [0, 1] so the colormap's full range covers the signal above it.
    intensity = max(0.0, (intensity - noiseFloor) / max(0.01, 1.0 - noiseFloor));
    return float4(colormap(intensity, paletteIndex), 1.0);
}
