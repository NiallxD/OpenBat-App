# BatDetect2 → CoreML Conversion Notes

## Status: DONE — integrated and verified

BatDetect2 is converted, wired into `ModelRegistry.all`, and end-to-end verified: a
real UK example recording (`20180627_215323-RHIFER-LR_0_0.5.wav`, Rhinolophus
ferrumequinum) run through the Swift preprocessing path and the converted CoreML
model correctly predicts RHIFER at 0.92 confidence, matching the Python reference
pipeline's own prediction. The Swift-rendered spectrogram correlates 0.99 with the
real Python pipeline's output on the same audio (see "Verification" below).

## License — read this first

`github.com/macaodha/batdetect2` (the base repo — NOT the `batdetect2-acoupi` GPL3
wrapper) is licensed **CC BY-NC 4.0** (Creative Commons Attribution-NonCommercial), not
MIT. It forbids commercial use of the model without a separate grant from the authors.
Confirmed OK for OpenBat because OpenBat is non-commercial — re-check this note if that
ever changes.

## What shipped

- `OpenBat/Classifier/BatDetect2.mlpackage` — converted from
  `batdetect2_uk_same.ckpt` (the Lightning checkpoint bundled in the repo), tracing
  `Detector.forward` and exposing `detection_probs` (1×1×128×256) and `class_probs`
  (1×17×128×256) — exactly the output names `BatDetect2Classifier` already expected.
- `ModelRegistry.batDetect2` registered in `ModelRegistry.all`.
- `BatDetect2Classifier.classNames` — the real 17-class order, read directly from the
  checkpoint's `hyper_parameters['class_names']`, uppercased:
  `MYOMYS, MYOALC, CNESER, PIPNAT, BARBAR, MYONAT, MYODAU, MYOBRA, PIPPIP, MYOBEC,
  PIPPYG, RHIHIP, NYCLEI, RHIFER, PLEAUR, NYCNOC, PLEAUS`. There is NO extra
  "generic Bat"/background class — `ClassifierHead` has `num_classes+1` output
  channels, but the +1 is a background logit used only inside the softmax then
  discarded; `detection_probs` is the SUM of the 17 retained class probabilities, not
  a separate detection head's output.
- `BatDetect2SpectrogramRenderer`'s spec, confirmed against the checkpoint's own
  stored `preprocess` config (not guessed): 256 kHz, n_fft=512, hop=128, 10–120 kHz
  crop, PCEN (`time_constant=0.4` — the doc previously guessed 0.1), spectral mean
  subtraction, **no normalize step** (previously guessed `.peak`, which doesn't exist
  in the real pipeline), bilinear resize, output 128×256 (previously guessed 128×128 —
  height is fixed but width scales with input duration).
- `ModelInputSpec.batdetect2`: 256 ms window (matches the model's own training clip
  length) @ 30% onset. `PulseDetector.deferTrailSeconds` is now a computed max over
  `ModelRegistry.all`'s trailing requirements instead of a hardcoded constant, so it
  covers BatDetect2's 179.2 ms trailing need without regressing NABat's.
- `PolyphaseResampler.swift` (new, in `DSP/`) — a windowed-sinc (Kaiser β=5) polyphase
  resampler replacing the original naive linear-interpolation placeholder for the
  384 kHz → 256 kHz downsample. Verified against `scipy.signal.resample_poly` (the
  real pipeline's own resampler): max abs sample difference 1.5e-8, correlation
  0.9999999999999912.
- `PassAggregation.aggregate` now takes model-specific `rawConfidenceThreshold` /
  `noiseClassName` parameters (defaulting to NABat's existing values, so NABat is
  unaffected). `ModelDescriptor` gained matching fields. BatDetect2's
  `noidRawConfidenceThreshold` (0.4) is a documented **placeholder** — see "Known gaps"
  below.
- UK species groups/complexes added to `ModelDescriptor.batDetect2`: Myotis (6
  species), Pipistrelles (3), Nyctalus (2), Long-eared bats/Plecotus (2) — based on
  standard UK bat-acoustics literature on which species are routinely confused,
  mirroring how NABat's complexes were curated.

## Two real bugs found and fixed during verification

Verification was done by rendering the same real 384 kHz WAV through both the actual
Python `batdetect2` package and a standalone `swiftc`-compiled harness linking the
actual production Swift files (`ClassifierSpectrogramEngine.swift`,
`BatDetect2SpectrogramRenderer.swift`, `PolyphaseResampler.swift`), then comparing
tensors numerically. This caught two bugs that a purely visual/spot-check comparison
would likely have missed (same class of bug as the NABat magma/viridis colormap
mismatch — silent degradation, not a crash):

1. **PCEN's IIR filter had the wrong initial condition.** `applyPCEN` set
   `m[0] = S[0]` directly; the correct zero-history condition (matching
   `torchaudio.functional.lfilter`'s default, which `batdetect2`'s PCEN relies on) is
   `m[0] = s·S[0]`. With BatDetect2's smoothing constant this small (s≈0.049, i.e. a
   slow-adapting filter), the wrong initial value decayed as `(1-s)^n` and corrupted
   roughly the first 100+ of 513 frames. This alone took the full-pipeline
   bin-for-bin correlation against the Python reference from ~0.001 (fully
   decorrelated) to ~0.99.
2. **The engine's `.bilinear` resize path reused NABat's `.nearest` conventions**,
   which are wrong for BatDetect2: (a) it sampled with row 0 = highest frequency
   (NABat's pcolormesh convention), but the real pipeline's tensor resize does NOT
   flip the frequency axis — row 0 must be the LOWEST frequency in the cropped band;
   (b) it used frequency-continuous sampling over the full uncropped bin range,
   but the real pipeline physically crops to `[lowIndex, highIndex)` bins FIRST, then
   resizes that fixed-size tensor with `torch.nn.functional.interpolate(...,
   align_corners=False)` — a different source-coordinate formula
   (`src = (dst+0.5)*(srcSize/dstSize) - 0.5`) than the naive one `.nearest` uses.
   `.bilinear` was unused before BatDetect2 (confirmed via grep), so this was
   rewritten with no NABat regression risk.

A related, deliberately UNFIXED discrepancy: vDSP's Hann-window `NORM` flag and its
packed-real-FFT convention produce STFT magnitudes at a different absolute scale than
`torch`'s. This matters enormously for PCEN (which compares against fixed absolute
constants) but is invisible to NABat (whose `.minMax` normalize cancels any constant
multiplicative power scale, and which uses `.hamming` not `.hann` anyway) — see the
`ClassifierSpectrogramEngine.swift` step-1 comment for the exact scale factor (a
combined ×0.5, folded into `linearMag` only, never `stft`, to avoid touching NABat's
already-tuned `QualityGate` absolute-dB thresholds).

## Known gaps (documented in code, not silently ignored)

- **`noidRawConfidenceThreshold` (0.4) is a placeholder**, not independently verified
  against a labelled noise/no-call dataset the way NABat's 0.57 was. BatDetect2's
  per-pixel softmax tends to be far more sharply peaked (observed 0.7–0.92 on
  confidently-correct real calls during conversion) — revisit once field data exists.
  See `PassAggregation.aggregate`'s doc comment.
- A ~1-bin frequency-crop boundary difference between Swift's bandpass-masking bin
  math (used for the dB path / quality metrics, shared with NABat) and the exact
  Python `_frequency_to_index` formula (used only by the new `.bilinear` resize path)
  — negligible (max abs diff 1.7 out of a ~3.4 range in one edge pixel; 0.99 overall
  correlation), not worth the shared-code risk of unifying further.
- BatDetect2's own bounding-box/size regression head (`size_preds`) and raw
  `features` output are not used at all — the CoreML model still computes them (they
  come along for free from `Detector.forward`), but the conversion's wrapper module
  only exposes `detection_probs`/`class_probs`, matching the adapter's
  "keep only classification" design (see `BatDetect2Classifier`'s file header).

## Reproducing the conversion (for a future re-convert, e.g. a new checkpoint version)

```bash
git clone https://github.com/macaodha/batdetect2
cd batdetect2 && pip install -e . && pip install "matplotlib<3.9" coremltools
```

The checkpoint's own stored hyperparameters are authoritative — don't re-derive
preprocessing config from `model.yaml`/docs, read them directly:

```python
import torch
ckpt = torch.load("src/batdetect2/models/checkpoints/batdetect2_uk_same.ckpt",
                   map_location="cpu", weights_only=False)
hp = ckpt["hyper_parameters"]
hp["class_names"]                       # exact ordered class list
hp["model_config"]["preprocess"]        # exact STFT/PCEN/crop/resize config
```

For the conversion itself, `torch.jit.trace` fails on the decoder's
`FreqCoordConvUpBlock`/`StandardConvUpBlock` (they compute `F.interpolate`'s `size`
from the input tensor's own dynamic shape, which coremltools can't resolve to a
constant) — monkey-patch both blocks' `forward` to use `scale_factor=(2,2)` instead of
a computed `size`, which is behaviorally identical for a fixed trace input shape and
traces cleanly. See the conversion script pattern used for this integration (not
checked into the repo — recreate from this description if re-converting).

Trace with a fixed `(1, 1, 128, 256)` input (256 ms of audio, 256 kHz), which is what
`ModelInputSpec.batdetect2` + `BatDetect2SpectrogramRenderer` produce. Export both
`detection_probs` and `class_probs` (drop `size_preds`/`features`).
