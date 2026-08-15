# tools

Offline scripts. Nothing here is part of the app target or runs on device.

- **`generate_species_range_data.py`** — builds the species range data
  (per-species occurrence points) that `FieldGuide/SpeciesRangeStore.swift`
  consumes. Run it offline and commit the output; the app never generates
  this itself.

  ```
  python3 tools/generate_species_range_data.py
  ```

- **`openbat_vs_echotouch_analysis.ipynb`** — one-off comparison of OpenBat's
  call measurements against EchoTouch's. Kept as a record of the analysis, not
  as a maintained tool.
