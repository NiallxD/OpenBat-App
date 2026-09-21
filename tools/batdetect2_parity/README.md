# BatDetect2 preprocessing parity

BatDetect2's authors asked for one specific check (Oisin Mac Aodha, 2026-09-14):

> The correct pre-processing is essential to make BD2, and likely the other models,
> work. If the pre-processing steps are not the exact same as our code it will not
> work as intended and give users an inaccurate impression of how well it actually
> works. Best thing to do would be to test that your app generates the exact same
> outputs as BD2's Python code.

This is that check, run against the app's own code rather than a re-implementation
of it: `build.sh` compiles `main.swift` directly against
`OpenBat/Classifier/ClassifierSpectrogramEngine.swift`,
`BatDetect2SpectrogramRenderer.swift` and `DSP/PolyphaseResampler.swift`, so if the
shipping preprocessing changes, so does what is measured here.

Both sides are handed the **same float32 samples** — `compare.py` cuts the window
from the WAV and writes it to a raw `.f32` file that the Swift binary reads — so any
disagreement is the transform, not the input.

## Running it

```sh
./build.sh                                     # once, and after any DSP change
python3 compare.py \
    --input ~/recordings/uk-pipistrelle.wav \
    --start-seconds 0.5 \
    --batdetect2-source ~/src/batdetect2
```

`compare.py` needs the official BatDetect2 v2 environment (torch, soundfile, and the
`batdetect2_uk_same.ckpt` checkpoint inside the checkout). The Swift side needs only
a Mac with Xcode's toolchain.

## Result, 2026-09-20

Measured against `macaodha/batdetect2` at rev `9e26974` (v2.0.0b3), on BatDetect2's
own UK example recordings, using its `batdetect2_uk_same.ckpt` preprocessor. Reports
in `results/`.

| Recording | Stage | Mean abs. error | Max abs. error |
|---|---|---|---|
| EPTSER | transform only (256 kHz) | 1.2e-07 | 3.2e-05 |
| RHIFER | transform only (256 kHz) | 7.8e-08 | 1.0e-05 |
| MYOMYS | transform only (256 kHz) | 8.1e-08 | 8.4e-06 |
| EPTSER | 384 kHz capture, whole path | 1.5e-07 | 2.7e-05 |
| RHIFER | 384 kHz capture, whole path | 1.0e-07 | 8.6e-06 |

That is float32 noise: the app feeds BatDetect2 the same tensor its own Python code
would. **It was not, until this harness was written.** The first run scored a mean
absolute error of 4.7e-03 and a maximum of 1.76 — a 0.993 correlation, which is
exactly the kind of number that looks like agreement and is not. Two causes, both
fixed in `ClassifierSpectrogramEngine`:

- **Zero padding where the reference reflect-pads.** `torchaudio.transforms.Spectrogram`
  is constructed with `center=True` and takes `pad_mode="reflect"` by default. The port
  zero-padded, which made the last time column of the tensor 26% too quiet and the
  first nine columns wrong by a decreasing amount. Now `SpectrogramPadding.reflect`,
  set per model so NABat's zero-padded path is untouched.
- **The bandpass ate the lowest retained frequency bin.** NABat's bandpass keeps bins
  strictly inside `[min, max]`; BatDetect2's `FrequencyCrop` keeps the half-open
  `[floor(min), floor(max))` range. The port applied NABat's rule to both, so the
  10 kHz bin was zeroed before PCEN ever saw it, and the model's lowest output row
  arrived blank. Now `SpectrogramBandEdge.matchingCrop`.

## Reproducing the reference side

```sh
git clone https://github.com/macaodha/batdetect2.git
cd batdetect2 && git checkout 9e2697458d3b3b03c30ccd7e49ed5409c8ac330d
python3 -m venv --system-site-packages .venv
.venv/bin/pip install -e .          # the checkpoint ships in the repo, no download
.venv/bin/pip install torchaudio==2.6.0   # must match your torch build
```

`example_data/audio/` holds three real UK recordings, two of them at 384 kHz — the
rate OpenBat captures at. For the transform-only comparison, resample a copy to
256 kHz offline (`scipy.signal.resample_poly`) so neither side resamples.

## Reading the numbers

Two different things can be measured, and the WAV's sample rate picks which:

- **256 kHz input** — the spectrogram transform alone (STFT, PCEN, spectral mean
  subtraction, resize). Expect agreement at float32 noise level: ~1e-07 mean, ~3e-05
  maximum, as in the table above (the equivalent Rust port in OpenBat-Android scores
  2.2e-07 / 6.4e-06). Anything materially worse is a bug in the port, not rounding —
  and note that correlation is the wrong thing to watch: it stayed at 0.993 while the
  tensor was visibly wrong.
- **384 kHz input** (the app's real capture rate) — resampling *and* the transform.
  The error floor is higher here by design: `PolyphaseResampler` deliberately does
  not match `scipy.signal.resample_poly` bit-for-bit (it centres the filter's group
  delay rather than fine-tuning the decimation phase — see that file's header). Read
  this one as "does the app's whole path agree", and the 256 kHz one as "is the
  transform right".

Neither number says anything about how well BatDetect2 identifies bats. It says the
model is being fed what it was trained on.

Keep the JSON report from a run (`--output`) beside the Android port's
`benchmarks/batdetect2-preprocessing-parity.json` — same schema, so the two ports can
be compared directly.
