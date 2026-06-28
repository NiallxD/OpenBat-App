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
    HistoryBuffer.swift           UInt8 ring buffer, 120 s @ ~44 MB; COW snapshot in O(1)
    FrequencyBandControl.swift    Popover: frequency range + time-window sliders
    RangeSlider.swift             Custom dual-thumb slider
    Spectrogram.metal             Full-screen pass, inferno colormap, ring-buffer UV math
  Classifier/
    PulseDetector.swift           @Observable pulse trigger + background image renderer
    PulseSettingsView.swift       Settings sheet for trigger/display options
  ContentView.swift               Main screen — GeometryReader proportional layout
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

Buffer geometry: `usePulseLen = min(consecutiveAbove, 100)`, `bufCol = max(4, usePulseLen / 3)`. This places the pulse onset at exactly **20% from the left** of the captured image: `bufCol / (2*bufCol + usePulseLen) = (P/3) / (5P/3) = 1/5 = 20%`.

Frequency crop uses **relative threshold** (50% of peak value across pulse columns). Avoids the absolute-threshold failure where broadband noise floor fills all bins.

### Inferno colormap
Defined identically in `Spectrogram.metal` (GPU) and `PulseDetector.colormap()` (CPU/static). 6-stop piecewise linear: near-black → dark purple → medium purple → dark orange → bright orange → pale yellow. Keep these in sync.

## Key constants

| Symbol | Value | Notes |
|--------|-------|-------|
| `fftSize` | 1024 | Hann-windowed |
| `hopSize` | 512 | 50% overlap |
| `binCount` | 512 | `fftSize / 2` |
| `columnsPerSecond` | 750 | at 384 kHz: `384000 / 512` |
| `maxVisibleColumns` | 2048 | seek texture width |
| `ringTextureWidth` | 2560 | `maxVisibleColumns + 512 guard` |
| `liveHistory capacity` | 90 000 | 120 s × 750 cols |
| `minDB / maxDB` | −90 / −20 dB | display dynamic range |
| Metal max texture dim | 16 384 | limits single-texture history |

## SourceKit false positives

SourceKit frequently reports spurious errors like "Cannot find 'UIKit' in scope", "Cannot find type 'SpectrogramProcessor' in scope", "Reference to member 'shaderRead' cannot be resolved", etc. These are **indexing artifacts** — the project builds and runs correctly. Ignore them.

## Pending / future work

- **NABat ML v2.0 integration**: Convert USGS Python model to CoreML. Notes in `mlconversion.md`. Prior-based species filtering: disabled species → weight=0 → renormalize remaining softmax outputs.
- **Stats panel** (top 18% of screen): placeholder for species ID output.
- **Pulse log**: store last N captures as a scrollable history in the pulse zoom panel.
- **384 kHz capture verification**: confirm iOS hands the Griff mic's native rate and doesn't silently downsample. Check `diagnostics.isNativeRate` and `diagnostics.actualSampleRate`.
