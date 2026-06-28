# NABat ML → CoreML Conversion Notes

## Goal
Convert the USGS NABat Acoustic ML v2.0 model to a CoreML `.mlpackage` for on-device
bat species identification in OpenBat. 31-class classifier (30 North American species +
noise), 92% overall accuracy.

## Source
- Repo: https://code.usgs.gov/fort/nabat/nabat-ml
- Data: https://www.sciencebase.gov/catalog/item/627ed4b2d34e3bef0c9a2f30
- USGS page: https://www.usgs.gov/data/north-american-bat-monitoring-program-nabat-acoustic-ml-version-200

## Steps

### 1. Clone and inspect
```bash
git clone https://code.usgs.gov/fort/nabat/nabat-ml
cd nabat-ml
# Check README for model format (.h5 / SavedModel / .pt) and input tensor shape
```

### 2. Convert to CoreML
```bash
pip install coremltools tensorflow  # or torch if PyTorch model
```

```python
import coremltools as ct

# TensorFlow SavedModel path
model = ct.convert(
    "path/to/saved_model",
    inputs=[ct.ImageType(shape=(1, H, W, C), scale=1/255.0)],
    classifier_config=ct.ClassifierConfig(class_labels)
)
model.short_description = "NABat ML v2.0 — 30 North American bat species + noise"
model.save("NABatML.mlpackage")
```

> **TODO**: fill in H, W, C and normalization once model repo is inspected.
> The CoreMLBats project (github.com/vrunkel/CoreMLBats) uses 512×512 B&W with
> FFT 1024 / 96% overlap / Harris window — check if NABat uses the same.

### 3. Add to Xcode
Drag `NABatML.mlpackage` into the OpenBat Xcode project. Xcode auto-generates the
Swift interface. Expected output shape:
- `classLabel: String` — top predicted species
- `classLabelProbs: [String: Double]` — full probability vector over all 31 classes

## Swift Integration Plan

### Pipeline (per detected pulse)
```
SpectrogramProcessor peak detection
    → raw audio capture (~50 ms window around peak)
    → headless spectrogram renderer (matching model's FFT settings)
    → CVPixelBuffer
    → CoreML inference (background queue, ~5–10 ms)
    → apply prior (see below)
    → results overlay on SpectrogramView
```

### Prior / species toggle
Disabling a species in Settings sets its prior weight to 0. The posterior is the model's
softmax output masked by enabled priors and renormalized. No retraining required.

```swift
func applyPrior(
    probs: [String: Double],
    enabledSpecies: Set<String>
) -> (species: String, confidence: Float)? {
    let masked = probs.filter { enabledSpecies.contains($0.key) }
    let total = masked.values.reduce(0, +)
    guard total > 0 else { return nil }
    let normalized = masked.mapValues { $0 / total }
    let best = normalized.max(by: { $0.value < $1.value })!
    return (best.key, Float(best.value))
}
```

Settings persist enabled species in `UserDefaults`. UI is a grouped toggle list of the
30 species (grouped by region: Northeast / Southeast / West / etc.).

### Future: geographic prior
NABat's own post-processing uses species range maps weighted by GPS location — a
continuous geographic prior rather than the binary user toggle. Worth adding once the
basic pipeline is working. The prior multiplication is the same; only the weight source
changes.

## Reference: CoreMLBats (alternative / prototype)
- github.com/vrunkel/CoreMLBats — pre-built CoreML model, European species focus
- Input: 512×512 B&W spectrogram, FFT 1024, 96% overlap, Harris window
- Useful as a drop-in prototype to validate the end-to-end Swift pipeline before the
  NABat conversion is done
