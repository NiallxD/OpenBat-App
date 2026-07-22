# OpenBat — Claude Code Context

iOS bat detector app using the Griff ultrasonic USB microphone (384 kHz sample rate, 192 kHz Nyquist). Targets iOS 18.6. Uses `@Observable` (iOS 17+) throughout — no `@ObservableObject`/`@Published`.

## Project layout

```
OpenBat/
  Audio/
    AudioEngineController.swift   @MainActor @Observable — AVAudioEngine wrapper
    AudioDiagnostics.swift        Published stats struct (sample rate, level, input name)
  DSP/
    Biquad.swift                  Biquad filter (used by heterodyne)
  Heterodyne/
    HeterodyneProcessor.swift     Real-time heterodyne downmixer
  TimeExpansion/
    TimeExpansionProcessor.swift  Per-call RTE (real-time time expansion)
  Spectrogram/
    SpectrogramProcessor.swift    Audio-thread FFT → normalised 0–1 columns via vDSP
    SpectrogramRenderer.swift     MTKViewDelegate — ring texture + seek texture + HistoryBuffer
    SpectrogramView.swift         SwiftUI wrapper with drag-to-scroll gesture
    HistoryBuffer.swift           UInt8 ring buffer, 60 s @ ~90 MB; COW snapshot in O(1)
    FrequencyBandControl.swift    Popover: frequency range + time-window sliders
    RangeSlider.swift             Custom dual-thumb slider
    Spectrogram.metal             Full-screen pass, inferno colormap, ring-buffer UV math
  Classifier/
    PulseDetector.swift           @Observable pulse trigger + background image renderer
    PulseSettingsView.swift       Settings sheet for trigger/display options
  FieldGuide/
    SpeciesGuide.swift             Codable schema — GuideSpecies + measurements/morphology/echolocation/conservation/habits
    SpeciesGuideStore.swift        bundled → cached → GitHub raw-JSON resolution, dataVersion-gated
    SpeciesExplorerView.swift      Search bar + globe explorer + region species list (grouped by family)
    SpeciesDetailView.swift        Full species page — header/taxonomy breadcrumb, description, distribution, measurements, echolocation, conservation, habits
    GBIFService.swift              Scientific-name → taxon-key resolution (cached) + tile-overlay factory
    GBIFRangeMapView.swift          MKTileOverlay-backed interactive distribution map
  ContentView.swift               Main screen — GeometryReader proportional layout
  PulseZoomView.swift             Pinch-zoom + pan leaf view over the captured pulse render
  PulseStatsViews.swift           Stat row/column leaf views + shared staleIDSeconds
  LiveStatusViews.swift           Tuning pill, mic-status pill, amplitude meters
  DiagnosticsView.swift           Debug sheet
```

## Architecture

### Audio pipeline
`AudioEngineController.start()` configures an `AVAudioSession` (.playAndRecord, category needed for heterodyne output) at 384 kHz, installs a tap, and calls `bufferSink` for each buffer. `SpectrogramProcessor.process()` runs on the realtime audio thread — no main-actor work there.

`ListenMode`: `.off` / `.heterodyne` / `.timeExpansion`. Heterodyne downmixes to audible range. RTE (time expansion) plays each call back at 10× slower speed.

### Spectrogram rendering — dual-path Metal

**Live path** (`ringTexture`, 2560 × 512, ~5 MB):  
Columns written incrementally via `uploadToRing()`. `displayHead` glides forward with a feed-forward + feedback smoothing loop (latency ≈ 30 ms) for stutter-free scrolling. Ring wraps with `fmod` UV math in the Metal shader.

**Scroll path** (`seekTexture`, 2048 × 512, ~4 MB):  
When the user drags, `liveHistory.snapshot()` freezes a COW copy (O(1)). `uploadSeekSlice()` fills seekTexture from the snapshot for the current scroll position. New audio keeps writing to `liveHistory`. Return-to-live discards snapshot.

**HistoryBuffer** stores UInt8 columns (0–255) in ring layout `[col * binCount + bin]`. `rowMajorSlice(offset:count:)` returns `[Float]` in Metal row-major layout `[bin * count + col]` for single `texture.replace()` uploads.

### Triggered display mode
`PulseDetector.triggeredDisplayMode = true` → `SpectrogramRenderer` skips `uploadToRing` / `liveHistory.append` when `pulseDetector.isInPulse == false`. Silent gaps are dropped; the ring fills with back-to-back pulses (Wildlife Acoustics style). `isInPulse` is set at the END of `feed()` so the renderer reads it one column ahead (≈1 ms lag — negligible).

### Pulse detector
`PulseDetector.feed()` is called per drained column on the main thread. On the trailing edge it:
1. Reads `liveHistory.rowMajorSlice()` on the main thread (safe, produces a value-type `[Float]`)
2. Dispatches heavy computation (peak scan, pixel render, `CGImage` creation) to `captureQueue` (background)
3. Posts results back on `DispatchQueue.main` to update `@Observable` properties

Capture geometry: captures are *deferred* — on the trailing edge the detector arms a pending capture and waits until enough trailing PCM exists, then renders a fixed `displayWindowMs` window from the raw PCM ring (`PulseImageRenderer`, fftSize 512 / hop 64) with the onset locked at `onsetFraction` = **25% from the left**. The classification window is cut separately per the model's `ModelInputSpec` (NABat: 50 ms, onset 30%).

Frequency crop uses **relative threshold** (50% of peak value across pulse columns). Avoids the absolute-threshold failure where broadband noise floor fills all bins.

### Inferno colormap
Defined identically in `Spectrogram.metal` (GPU) and `PulseDetector.colormap()` (CPU/static). 6-stop piecewise linear: near-black → dark purple → medium purple → dark orange → bright orange → pale yellow. Keep these in sync.

## Key constants

| Symbol | Value | Notes |
|--------|-------|-------|
| `windowLen` | 512 | Hann-windowed, raw samples per column |
| `fftSize` | 2048 | zero-padded from `windowLen` — drives bin count, not hop |
| `hopSize` | 256 | 50% overlap (of `windowLen`) |
| `binCount` | 1024 | `fftSize / 2` |
| `columnsPerSecond` | 1500 | at 384 kHz: `384000 / 256` (hop drives this, not fftSize) |
| `maxVisibleColumns` | 2048 | seek texture width |
| `ringTextureWidth` | 2560 | `maxVisibleColumns + 512 guard` |
| `liveHistory capacity` | 90 000 | 60 s × 1500 cols (`historySeconds` default in `SpectrogramRenderer`) |
| `minDB / maxDB` | −90 / −20 dB | display dynamic range |
| Metal max texture dim | 16 384 | limits single-texture history |

## SourceKit false positives

SourceKit frequently reports spurious errors like "Cannot find 'UIKit' in scope", "Cannot find type 'SpectrogramProcessor' in scope", "Reference to member 'shaderRead' cannot be resolved", etc. These are **indexing artifacts** — the project builds and runs correctly. Ignore them.

## Build/test policy

Don't boot a simulator or run `xcodebuild test` unless it's genuinely necessary (e.g. no other way to check a fix) — the user runs actual builds/tests themselves on-device or in their own simulator session. To check for compile errors, use a **build-only** invocation that doesn't launch a simulator instance:

```
xcodebuild -project OpenBat.xcodeproj -scheme OpenBat -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

This compiles against the simulator SDK without booting one. Prefer this over picking a concrete `-destination ... ,name:/id:` simulator, which will boot it.

## Pending / future work

- **NABat ML v2.0 integration**: Convert USGS Python model to CoreML. Notes in `mlconversion.md`. Prior-based species filtering: disabled species → weight=0 → renormalize remaining softmax outputs.
- **Stats panel** (top 18% of screen): placeholder for species ID output.
- **Pulse log**: store last N captures as a scrollable history in the pulse zoom panel.
- **384 kHz capture verification**: confirm iOS hands the Griff mic's native rate and doesn't silently downsample. Check `diagnostics.isNativeRate` and `diagnostics.actualSampleRate`.
- **Taxonomy browser**: an explorable full taxonomic tree (order → family → genus → species) for the field guide, replacing/complementing the region-grouped-by-family list in `RegionSpeciesView`.
