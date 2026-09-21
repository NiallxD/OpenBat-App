# tools

Offline scripts. Nothing here is part of the app target or runs on device.

- **`generate_species_presence_data.py`** — builds `SpeciesPresenceData.json`,
  the coarse global grid of where each species the classifiers can name
  actually lives. It decides which species the app considers plausible at the
  user's location, and draws the species page's range map. Run offline, commit
  the output to the field guide repo, and copy it into
  `OpenBat/FieldGuide/`. **Read the runbook in `CLAUDE.md` first** — the
  taxonomy dry run is the step that catches the two ways a name lookup goes
  wrong.

  ```
  python3 -u tools/generate_species_presence_data.py --dry-run   # check taxonomy
  python3 -u tools/generate_species_presence_data.py             # ~1 minute
  python3 tools/verify_presence_data.py                          # 17 assertions
  ```

- **`update_presence_data.py`** — the whole publish runbook in one run: pulls
  the sibling field guide clone, regenerates, verifies, and — only if something
  actually changed — bumps the version, commits `SpeciesPresenceData.json` to
  the guide repo and pushes it. Stops without publishing if the generator
  reports failures, if verification fails, or if a species that had a range
  comes back with none. It does not touch the app repo: the bundled copy in
  `OpenBat/FieldGuide/` is a cold-install seed refreshed at release time, and
  the `DATA_VERSION` bump in the generator is left for you to commit.

  ```
  python3 -u tools/update_presence_data.py --dry-run   # pull, build, verify, report
  python3 -u tools/update_presence_data.py             # ~1 minute, publishes
  ```

- **`probe_range_coverage.py`** — read-only survey of which species have usable
  GBIF data and whether the app queries them under the name GBIF files them
  under. Worth re-running whenever a model is added; writes nothing.

- **`blog_autoid_figures.py`** — the three explanatory figures for the "how auto
  ID works" post on openbat.app: the pipeline diagram, pulses-into-a-pass, and
  what the range priors do to a set of scores. Drawn in presence_lab's palette
  so the site's figures match. The envelope and the scores are illustrative;
  the thresholds drawn on them are the real ones, so if a threshold changes
  here, change it there too.

  ```
  python3 tools/blog_autoid_figures.py --out ~/Desktop/"OpenBat AutoID Figures"
  ```

- **`blog_guide_figures.py`** — the two figures for the "adding a bat to the
  field guide" post: what one species entry holds, and what happens between
  pressing Submit and the entry reaching phones. The field names track the
  schema in the OpenBat-FieldGuide README.

  ```
  python3 tools/blog_guide_figures.py --out ~/Desktop/"OpenBat Guide Figures"
  ```

- **`blog_detection_figure.py`** — the detection-distance figure for the "why
  bats are hard to watch" post: how far a detector hears five different bats,
  drawn to scale. The distances are the approximate figures from survey
  guidance, not measurements of anything here.

  ```
  python3 tools/blog_detection_figure.py --out ~/Desktop/"OpenBat Figures"
  ```

- **`mvt_lite.py`** — dependency-free Mapbox Vector Tile reader, used by the
  presence generator to read GBIF's density tiles. Not a general-purpose
  parser; see its header for what it deliberately doesn't do.

- **`openbat_vs_echotouch_analysis.ipynb`** — one-off comparison of OpenBat's
  call measurements against EchoTouch's. Kept as a record of the analysis, not
  as a maintained tool.

- **`batsim.sh`** — a train of downward FM sweeps out of the Mac's speaker, for
  exercising the live listening path (detector, squelch gate, auto-tune,
  `HowlGuard`) without a bat. A laptop tops out around 23 kHz, so this is the
  right SHAPE at the wrong frequency: the defaults (22→16 kHz, 5 ms, 10/s) sit
  above the app's 15 kHz band floor and below Nyquist. `--buzz` appends a
  feeding buzz — the one natural sound dense enough to test that the runaway
  guard leaves real activity alone.

  ```
  tools/batsim.sh                        # play the default train
  tools/batsim.sh -s 23 -e 18 -d 3       # steeper, shorter pulses
  tools/batsim.sh --buzz -o /tmp/b.wav -P  # write a file, don't play
  ```

- **`batdetect2_parity/`** — proves OpenBat's Swift BatDetect2 preprocessing
  produces the same tensor as the reference Python pipeline, which BatDetect2's
  authors asked for directly. `build.sh` compiles a dumper against the app's own
  DSP sources; `compare.py` feeds both sides identical samples and reports the
  error over the 128×256 tensor. Needs the official BatDetect2 v2 environment.
  See `batdetect2_parity/README.md`.

  ```
  tools/batdetect2_parity/build.sh
  python3 tools/batdetect2_parity/compare.py --input capture.wav \
      --batdetect2-source ~/src/batdetect2
  ```

- **`make_uk_demo_clip.py`** — rebuilds the bundled UK demo clip
  (`OpenBat/Demo/uk_demo_bats.wav`) from BatDetect2's own example recordings.
  **It must stay at 384 kHz**: demo mode plays a file at its own rate, and
  `ModelInputSpec.nativeSampleRate` only classifies at 384 kHz, so an off-rate
  demo clip detects calls and identifies none of them — which is what the
  previous 500 kHz clip did. The script's header has the rest of the reasoning.

  ```
  python3 tools/make_uk_demo_clip.py \
      --first ~/Downloads/20180627_215323-RHIFER-LR_0_0.5.wav \
      --second ~/Downloads/20180530_213516-EPTSER-LR_0_0.5.wav
  ```

- **`make_uk_species_demo_clip.py`** — builds the ten-species UK demo clip
  (`OpenBat/Demo/Demo-UK-Species-2026.wav`, 35 s) from Niall's own bat-walk
  library. Two species show that the pipeline runs; ten show what the app is
  for. The windows are picked from `tools/bd2_eval/results/run1/reference.jsonl`
  — for each species, the 2 s stretch with the most confident detections of it
  and none of anything else — so each block lands as one pass with one answer.
  Same 384 kHz rule as above, and the same do-not-normalise rule, which matters
  more here because the ten sources span 32 dB. The header has the rest,
  including which species were left out and why.

  ```
  python3 tools/make_uk_species_demo_clip.py            # --library defaults to ~/Downloads/BatRecordings
  ```

  Verified 2026-09-21 by running the stitched clip back through
  `bd2_eval/run_reference.py`: all ten blocks still come back as their own
  species (PIPPYG 0.87, RHIFER 0.79 … MYOMYS 0.53), and the gaps produce no
  confident detection at all.
