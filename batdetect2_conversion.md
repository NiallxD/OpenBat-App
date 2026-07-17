# BatDetect2 → CoreML Conversion Notes

## License — read this first

`github.com/macaodha/batdetect2` (the base repo — NOT the `batdetect2-acoupi` GPL3
wrapper) is licensed **CC BY-NC 4.0** (Creative Commons Attribution-NonCommercial), not
MIT. It forbids commercial use of the model without a separate grant from the authors.
Confirmed OK for OpenBat because OpenBat is non-commercial — re-check this note if that
ever changes.

## Goal

Convert BatDetect2's pretrained UK model to a CoreML `.mlpackage` for on-device bat
detection/classification in OpenBat, wired in as a `SpeciesClassifier` adapter (see
`OpenBat/Classifier/BatDetect2Classifier.swift`).

## Source

- Repo: https://github.com/macaodha/batdetect2
- Pretrained weights (in-repo): `src/batdetect2/models/checkpoints/batdetect2_uk_same.ckpt`
  (current Lightning checkpoint) or `Net2DFast_UK_same.pth.tar` (legacy v1 architecture)
- Architecture: fully-convolutional U-Net (`FreqCoordConvDown`/`FreqCoordConvUp` blocks,
  32→64→128→256 channels, `SelfAttention` bottleneck at 256 ch)

## What OpenBat's Swift side already assumes (confirm all of this against the real checkpoint)

`BatDetect2SpectrogramRenderer.swift` and `BatDetect2Classifier.swift` are written against
the *published config*, not a verified conversion. Specifically:

| Param | Assumed value | Source |
|---|---|---|
| Sample rate | 256 kHz | model.yaml `samplerate` |
| FFT window / hop | 512 / 128 samples (2 ms / 75% overlap, Hann) | model.yaml |
| Freq crop | 10 kHz – 120 kHz | model.yaml |
| Output size | 128 × 128 (height fixed, width **unverified**) | model.yaml `height`/`resize_factor` |
| Scaling | PCEN (time_constant 0.1, gain 0.98, bias 2, power 0.5) | model.yaml `spectrogram_transforms` |
| Denoise | per-frequency-bin mean subtraction, clip ≥ 0 | model.yaml |
| Normalize | peak-normalize per spectrogram | model.yaml |
| Resize | bilinear | `torch.nn.functional.interpolate` in the reference code |
| Channels | grayscale (1 channel) | model.yaml `in_channels: 1` |

Every row above is a guess pending validation — same process the NABat integration went
through (see the magma/viridis note in `NaBatSpectrogramRenderer.swift`: a preprocessing
mismatch a CNN was never trained on can silently degrade to near-random output rather
than throwing an error). Do not trust these numbers without running the actual
`bat_detect2/preprocess/spectrogram.py` pipeline on a reference clip and diffing against
Swift's `ClassifierSpectrogramEngine.render(pcm:spec:)` output.

## Steps

### 1. Clone and inspect

```bash
git clone https://github.com/macaodha/batdetect2
cd batdetect2
pip install -e .
```

Check `src/batdetect2/preprocess/config.py` and `model.yaml` for the exact values in
the table above — the repo may have moved on since this doc was written.

### 2. Generate a reference spectrogram to diff against

Run the Python preprocessing pipeline on a short real bat-call WAV and dump the
resulting tensor (e.g. `np.save`) before touching Swift. This is the ground truth
`ClassifierSpectrogramEngine` output must match.

### 3. Convert to CoreML

```bash
pip install coremltools torch
```

```python
import coremltools as ct
import torch

model = ...  # load the Lightning checkpoint / instantiate the Detector and load_state_dict
model.eval()

example_input = torch.rand(1, 1, 128, 128)  # confirm real input shape first
traced = torch.jit.trace(model, example_input)

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=example_input.shape)],
)
mlmodel.save("BatDetect2.mlpackage")
```

`BatDetect2Classifier` expects output feature names `detection_probs` (shape
`1×1×H×W`) and `class_probs` (shape `1×C×H×W`) — check what coremltools actually names
the converted outputs (it may keep the PyTorch `ModelOutput` field names, or rename
them) and update the `OutputKey` enum in that file to match.

### 4. Confirm the class list

Extract the real class order from the checkpoint (label list is typically bundled
alongside the weights, e.g. `class_names` in the config or a separate labels file).
Replace `BatDetect2Classifier.classNames` (currently empty on purpose) with the real
list — 17 UK species + a generic "Bat" (uncertain ID) class + a background/"Not bat"
class per the paper. **Never guess this list**; a wrong class order silently mislabels
every classification, the same way NABat's class list has to match `NABatML`'s output
index order exactly.

### 5. Add to Xcode and wire in

Drag `BatDetect2.mlpackage` into the project (target membership: OpenBat). Then in
`OpenBat/Classifier/ModelRegistry.swift`, append `batDetect2` to `all`:

```swift
static let all: [ModelDescriptor] = [nabat, batDetect2]
```

### 6. Verify end-to-end against the Python reference

Feed the same real recording through both the Python `batdetect2` package and the
in-app pipeline; confirm species + confidence match closely on several real passes
before trusting it in the field. Also revisit `PassAggregation.swift` — its NoID/NOISE
pass-level rule (0.57 raw-confidence threshold, literal `"NOISE"` class name) is tuned
to NABat's reference pipeline and has not been adapted for BatDetect2's background
class or confidence calibration.
