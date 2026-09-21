# How well does OpenBat identify bats, compared with BatDetect2 itself?

`tools/batdetect2_parity/` answered a narrower question — is the app feeding
BatDetect2 the tensor its own Python code would (yes, to ~1e-07). It says
nothing about identification. This harness asks the next question: run a real
library of recordings through the app's whole pipeline and through
BatDetect2's own, and count how often they say the same thing.

**There are no species labels on this library.** So "accuracy" here means
agreement with BatDetect2's published pipeline, which is the right reference
anyway: OpenBat ships BatDetect2's model, so wherever the two differ, the app
is losing something the model was capable of. When they agree, both can still
be wrong about the bat — that needs labelled audio and is a different job.

## The three arms

| Arm | Finds the calls | Preprocesses | Runs the model |
|---|---|---|---|
| **coreml** | OpenBat's `PulseDetector` | OpenBat (Swift) | the app's Core ML export, on the host |
| **pytorch** | OpenBat's `PulseDetector` | OpenBat (Swift) | PyTorch checkpoint |
| **reference** | BatDetect2's detection heatmap + NMS | BatDetect2 (Python) | PyTorch checkpoint |

Everything up to the model's input is the app's own Swift in the first two
arms: the real `PulseDetector` finds the calls, `ClassifierAnalysis`'s
windowing cuts them, `BatDetect2SpectrogramRenderer` builds the tensor. Only
the final inference happens on the host.

**Why not run the inference inside the app too?** The Swift harness does, and
its result is written to `app_arm.jsonl` — but on a *simulator* it is
worthless. Core ML there returns an all-zero output for `.cpuOnly` and
`.cpuAndGPU`, and the app asks for `.all`, which is not reliable either: a
full 927-file run came back with every class probability exactly 0.0
(2026-09-21). That is not a small inaccuracy, it is no computation at all, and
taken at face value it says OpenBat can identify nothing. The same tensors
through the same `.mlpackage` on the host give `PIPPYG 0.174`, and PyTorch
gives `0.175`. So `compare.py` defaults to `--app-scores coreml`. Run the
harness on a real device and `--app-scores app` becomes the honest choice.

The PyTorch arm exists because two arms cannot tell two different failures
apart. The conversion had been recorded as suspect — 0.883 against 0.711 on
one UK recording, same winning class (2026-09-20) — so an app-vs-reference gap
would blend "my detector finds different calls" with "my model export answers
differently". Scoring the same pulses both ways separates them. (On this
library it turned out to be the first: see "What the export costs" below.)

The deeper asymmetry is structural and worth stating plainly: **BatDetect2 is
its own detector, and OpenBat does not use that half of it.** One inference
over a spectrogram gives BatDetect2 a detection heatmap it extracts calls
from; OpenBat finds calls with its own amplitude/pitch trigger and asks
BatDetect2 only to name the window it cut. So the reference arm is not "the
same thing, done properly" — it is a different pipeline that happens to share
the weights, and the call-detection section of the report is where that shows.

## Running it

```sh
# 1. Reference arm: BatDetect2's own pipeline (~8 min for 927 × 5 s files)
"$BD2/.venv/bin/python" run_reference.py \
    --input ~/Downloads/BatRecordings \
    --output results/run1

# 2. App arm: the shipping Swift pipeline, on a simulator
./run_app_arm.sh ~/Downloads/BatRecordings "$PWD/results/run1"

# 3. Score the app's tensors with the app's own export, on the host
python3 run_coreml_arm.py --results results/run1

# 4. Attribution arm: the same tensors, the PyTorch checkpoint
"$BD2/.venv/bin/python" run_pytorch_arm.py \
    --results results/run1 --delete-tensors

# 5. The report
python3 compare.py --results results/run1 --sweep \
    --output results/run1/report.json
```

`run_app_arm.sh` takes `AMPLITUDE=` to override the trigger threshold, which
this library needs (see below). `$BD2` is a BatDetect2 **v2** checkout — the pip `batdetect2` is v1 and has no
`preprocess` module. The recipe that works, including the torchaudio version
the installed torch needs, is in `../batdetect2_parity/README.md`.

Each step appends JSON lines and skips what it already has, so any of them can
be interrupted and re-run.

## What the harness does, and what it deliberately does not

The app arm runs inside the test target (`OpenBatTests/BD2EvalHarnessTests`)
rather than as a command-line tool, because `PulseDetector` imports UIKit and
the classifier loads a Core ML resource from the app bundle. A macOS tool
would have to re-implement both, and then the number would describe the
re-implementation. It drives the real objects: `SpectrogramProcessor` columns
into `PulseDetector.feed`, exactly as `BackgroundDetectionPump` does, then the
same window `ClassifierAnalysis` cuts into the real `BatDetect2Classifier`,
then `PassAggregation` for the verdict. When the scores come from a host arm
instead, `compare.py` re-derives the pass verdicts in Python following
`PassAggregation.aggregate` — the NoID gate on the mean top-raw score, then
the winner by summed raw score. With priors of 1 the adjusted and raw vectors
are identical, so that function's second half collapses into its first.

Four deliberate departures from the live app, each of which would otherwise
make the comparison say something other than what it claims:

- **Every detected pulse is classified.** Live, render-and-classify is
  rate-limited against wall-clock and a busy pass loses some
  (`PulseDetector.capturesSkipped`). Offline the audio is fed faster than real
  time, so that limit would measure this Mac, not the app.
- **No location priors.** `prior` returns 1 for every class, so this compares
  model against model. OpenBat's range knowledge is a real advantage in the
  field and is not what is being tested here.
- **The trigger threshold is the app's own 0.5 unless `AMPLITUDE=` says
  otherwise.** These recordings come off the Griff's own card, not through the
  app's input gain, and at 0.5 the trigger barely fires on them: in one file,
  1 of 7,486 spectrogram columns clears it. Whether that is a gain difference
  or a threshold that is simply too high for real UK material is exactly what
  a sweep of this setting answers.
- **The last ~0.5 s of each recording is excluded from both arms.**
  BatDetect2's clipper discards the trailing partial clip, so it never sees
  it; the app streams the whole file. `covered_seconds` in the reference
  records is the honest overlap, and `compare.py` truncates to it.

## Reading the report

**File verdict** is the headline: one species per recording from each arm, the
way the app's list reads. `app found nothing` and `app triggered but refused`
are separated on purpose — a trigger that never fired and a pass that failed
the NoID gate are different problems with different fixes.

**Call detection** is about the trigger alone. Low recall here with high
verdict agreement means OpenBat hears fewer calls but still names the pass
right; high recall with low agreement points at the windowing or the model.
Note the app's own peak-search band, 0.02–0.45 of Nyquist (≈3.8–86 kHz at
384 kHz capture), which by construction cannot trigger on a horseshoe bat's
110 kHz CF call — the reference arm has no such limit, and any
`RHIFER`/`RHIHIP` row in the per-species table should be read with that in
mind.

**What the export costs** needs the PyTorch arm. It scores the *same* pulses
with the other set of weights and puts them through the *same* verdict rule,
so the only difference between the two figures is the conversion. On the first
158 pulses of this library that difference was nil: same species every time,
mean confidence delta −0.0002, largest single delta 0.008. That is worth
knowing on its own — the conversion had been recorded as unverified since
2026-09-20.

The reference threshold matters and there is no single right value.
BatDetect2 emits everything above 0.01, which is ~450 detections per 5 s
recording and mostly heatmap texture; the report defaults to 0.3 and `--sweep`
shows how the agreement moves with it. Quote the threshold with the number,
always.
