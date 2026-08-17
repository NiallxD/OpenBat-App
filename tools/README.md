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

- **`probe_range_coverage.py`** — read-only survey of which species have usable
  GBIF data and whether the app queries them under the name GBIF files them
  under. Worth re-running whenever a model is added; writes nothing.

- **`mvt_lite.py`** — dependency-free Mapbox Vector Tile reader, used by the
  presence generator to read GBIF's density tiles. Not a general-purpose
  parser; see its header for what it deliberately doesn't do.

- **`openbat_vs_echotouch_analysis.ipynb`** — one-off comparison of OpenBat's
  call measurements against EchoTouch's. Kept as a record of the analysis, not
  as a maintained tool.
