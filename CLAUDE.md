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
    TimeExpansionProcessor.swift  Playback-only classic time expansion (pass-through, no framing/selection)
    TimeExpansionSettings.swift   Persisted gain setting, owned locally by WavPlayerView
    AdaptiveTimeExpansionProcessor.swift  LIVE event-triggered time expansion, hangover-delimited events
    AdaptiveTimeExpansionSettings.swift   Persisted gain/hangover/cap/threshold, owned by ContentView
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

`ListenMode`: `.off` / `.heterodyne` / `.adaptiveTimeExpansion` (live capture only) / `.timeExpansion` (file playback only). The live cycle is off → heterodyne → adaptive time expansion → off. Frequency division was **removed** (2026-07-27) — it was a working classic technique but redundant next to the vocoder for continuous monitoring, and it sounded no better on real recordings. The phase vocoder (`.phaseVocoder`) and the first live snapshot time expansion (`.triggeredTimeExpansion`, `TriggeredTimeExpansionProcessor`) were both **removed** (2026-07-27); live time expansion returned the same day as `.adaptiveTimeExpansion` (see below).

**Live adaptive time expansion** (`AdaptiveTimeExpansionProcessor`, 2026-07-27): states idle → capturing → draining → idle. An on-thread energy trigger (12 kHz detection high-pass, tracked noise floor) opens an event; every sample from a 2 ms pre-roll onward is emitted in order into the 48 kHz ring, which at 384 kHz input is 8× expansion with no resampling. Further pulses arriving within `hangoverMs` (default 60) extend the same event, so bursts and feeding buzzes merge into one contiguous stretch instead of fragments. The event closes 5 ms after the level last exceeded the release threshold, or at `maxBufferMs` (default 200), whichever comes first.

**The gate is two-threshold (hysteresis), and it has to be.** Opening needs `thresholdDB` (default 12) over the floor; *staying open* needs only `releaseDB` (default 6). A single threshold clipped the end off every call — the decaying tail of a downsweep drops below the attack threshold while still being real, audible signal, so the close point landed early and no plausible fixed post-roll covered it. `postRollMs` is 5 ms of margin around the release point, not the mechanism that finds the call end. If endings still sound truncated, lower `releaseDB`; if events run on into background noise, raise it.

Two invariants in that file are load-bearing and documented there at length — read them before touching it:
1. **Nothing is selected out or discarded within an event.** Emission runs through a delay line (`emitDelaySamples = hangover − postRoll`) so the tail can be trimmed without ever retracting an emitted sample. An eager emitter that trims by dropping would click *and* would be the thing the patent covers.
2. **Capture stops while the ring drains.** An event of length L takes 8L to play and the processor is deaf throughout. Under sustained calling it falls behind and misses material — deliberately, like a Pettersson D240x. Making it keep up (capturing into a second buffer while draining the first) would turn it into continuous real-time monitoring with selective retention, i.e. US 8,599,647's subject matter. The deafness is the feature.

Because search-phase inter-pulse intervals (~50–150 ms) exceed the hangover, isolated search pulses each get their own tight event that drains inside the following gap; the hangover only merges approach phase and buzzes.

`missedCount` tallies pulses that triggered while the ring was still draining (debounced by `missedPulseGapMs` = 5 ms, or it would tick once per 0.33 ms detection block). `AdaptiveTimeExpansionStatePill` shows it in red once non-zero and is tappable for a plain-language explainer of why the mode isn't real-time. Treat that counter as the honest cost of invariant 2 — if it ever reads zero during a buzz, something has broken.

**Why time expansion is the mode that matters.** Every frequency-only mode maps pitch down while leaving duration alone, and that sounds worse than it should for a *temporal* reason, not a spectral one: an EPFU call is ~5 ms, so transposed to 5 kHz it is ~25 cycles. Pitch/timbre perception needs ~6-10 cycles just to register a pitch and far more to resolve structure within a sweep, so a perfectly transposed call still lands as a click. Stretching 5 ms to 40 ms puts that structure inside the ear's temporal resolution. No amount of frequency-domain work substitutes — don't go looking for a cleverer transposition.

`.timeExpansion` is `TimeExpansionProcessor` (`TimeExpansion/`), used **playback-only**, in `PlaybackEngine`/`WavPlayerView` — never in `AudioEngineController`, which treats this case identically to `.off`. It's classic time expansion done the safe way: every sample of the recording is played back untouched, just slower (8×, since the file's native 384 kHz gets paced out at the 48 kHz output rate — see `PlaybackDriver.start`'s `paceRate`). No framing, no selection, no discarding — the processor itself is a dumb pass-through with no idea it's being fed slowly. This is exactly the OLD, unpatented technique the WA patent's own background section describes; it only works for playback because the whole file already exists on disk, unlike live capture, which can't pace itself slower than real time without falling permanently behind.

### Patent notes

- **US 8,599,647** (Wildlife Acoustics, real-time frame-based sample selection
  for time expansion) — see the audio pipeline section above for the
  non-infringement reasoning behind `.timeExpansion`/`TimeExpansionProcessor`.
- **US 8,995,230** (FFT→zero-crossing conversion) — not currently relevant:
  `CallAnalysis.swift`'s Fmax/Fmin refinement uses only a forward, zero-padded
  FFT with parabolic-interpolation peak sharpening, no inverse FFT. Worth a
  targeted look *if* an inverse-FFT-based Fmax refinement is ever added there.

### Spectrogram rendering — dual-path Metal

**Live path** (`ringTexture`, 2560 × 512, ~5 MB):  
Columns written incrementally via `uploadToRing()`. `displayHead` glides forward with a feed-forward + feedback smoothing loop (latency ≈ 30 ms) for stutter-free scrolling. Ring wraps with `fmod` UV math in the Metal shader.

**Scroll path** (`seekTexture`, 2048 × 512, ~4 MB):  
When the user drags, `liveHistory.snapshot()` freezes a COW copy (O(1)). `uploadSeekSlice()` fills seekTexture from the snapshot for the current scroll position. New audio keeps writing to `liveHistory`. Return-to-live discards snapshot.

**HistoryBuffer** stores UInt8 columns (0–255) in ring layout `[col * binCount + bin]`. `rowMajorSlice(offset:count:)` returns `[Float]` in Metal row-major layout `[bin * count + col]` for single `texture.replace()` uploads.

### Triggered display mode
`PulseDetector.triggeredDisplayMode = true` → `SpectrogramRenderer` skips `uploadToRing` / `liveHistory.append` when `pulseDetector.isInPulse == false`. Silent gaps are dropped; the ring fills with back-to-back pulses (classic triggered-view style). `isInPulse` is set at the END of `feed()` so the renderer reads it one column ahead (≈1 ms lag — negligible).

### Pulse detector
`PulseDetector.feed()` is called per drained column on the main thread. On the trailing edge it:
1. Reads `liveHistory.rowMajorSlice()` on the main thread (safe, produces a value-type `[Float]`)
2. Dispatches heavy computation (peak scan, pixel render, `CGImage` creation) to `captureQueue` (background)
3. Posts results back on `DispatchQueue.main` to update `@Observable` properties

Capture geometry: captures are *deferred* — on the trailing edge the detector arms a pending capture and waits until enough trailing PCM exists, then renders a fixed `displayWindowMs` window from the raw PCM ring (`PulseImageRenderer`, fftSize 512 / hop 64) with the onset locked at `onsetFraction` = **25% from the left**. The classification window is cut separately per the model's `ModelInputSpec` (NABat: 50 ms, onset 30%).

Frequency crop uses **relative threshold** (50% of peak value across pulse columns). Avoids the absolute-threshold failure where broadband noise floor fills all bins.

### Inferno colormap
Defined identically in `Spectrogram.metal` (GPU) and `DisplayPalette.swift`'s `DisplayColormap` enum (CPU). 6-stop piecewise linear: near-black → dark purple → medium purple → dark orange → bright orange → pale yellow. Keep these in sync.

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
- **Illustrated morphology icons**: `SpeciesDetailView`'s morphology section is text-only; see its own TODO comment.
