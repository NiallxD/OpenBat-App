# Third-party components

OpenBat is source-available, all-rights-reserved (see `LICENSE`), but it
redistributes several third-party components under their own terms. This file
is the canonical list — the in-app "About → Data & Model Sources" screen shows
the same information (and, for the classifier models, the full licence text),
generated from the same source (`ModelRegistry.swift`, `AppInfoView.swift`), so
the two can't drift silently. This file exists because the weights below are
committed to a public repository, which makes this a redistribution, not just
a use — attribution belongs in the repo itself, not only behind an in-app
screen a reader has to know to open.

## Classifier models (bundled in `OpenBat/Classifier/`)

### NABat ML

- **Author:** North American Bat Monitoring Program (NABat), U.S. Geological
  Survey.
- **Licence:** CC BY 4.0. Full text:
  https://creativecommons.org/licenses/by/4.0/legalcode
- **Citation:** Gotthold, B.S., Khalighifar, A., Straw, B.R., Reichert, B.E.,
  2022, North American Bat Monitoring Program: NABat Acoustic ML, Version
  1.0.1: U.S. Geological Survey software release,
  https://doi.org/10.5066/P9XJRJZX
- **What's bundled:** a CoreML conversion of the authors' published TensorFlow
  model — a modification under the licence's terms; identification logic and
  class outputs are unchanged.
- **Source:** https://code.usgs.gov/fort/nabat/nabat-ml

### BatDetect2

- **Author:** University of Edinburgh (macaodha/batdetect2).
- **Licence:** **CC BY-NC 4.0 — non-commercial use only.** Contact the authors
  for any commercial use. Full text:
  https://creativecommons.org/licenses/by-nc/4.0/legalcode
- **What's bundled:** a CoreML conversion of the authors' published
  `batdetect2_uk_same.ckpt` PyTorch checkpoint — a modification under the
  licence's terms.
- **Source:** https://github.com/macaodha/batdetect2

BatDetect2's non-commercial term is why OpenBat is currently free with no
in-app purchase or subscription — see `LICENSE`.

## Data sources (not bundled — fetched or referenced at runtime)

- **GBIF** — species distribution maps are built from the Global Biodiversity
  Information Facility's occurrence data, licensed CC BY 4.0.
  https://www.gbif.org
- **Wikipedia** — species photos in the field guide are sourced from
  Wikipedia's open media, licensed CC BY-SA 4.0. Description text is written
  for the field guide and cited to its own references, not to Wikipedia.
  https://www.wikipedia.org

## Open-source libraries

- **FLAC** — lossless audio encoding for recording contribution. BSD 3-Clause.
  Copyright 2000-2009 Josh Coalson, 2011-2025 Xiph.Org Foundation.
  https://github.com/sbooth/flac-binary-xcframework
- **libogg** — Ogg container support, bundled alongside FLAC. BSD 3-Clause.
  Copyright 2002 Xiph.org Foundation.
  https://github.com/sbooth/ogg-binary-xcframework

## Field guide data

The species and region data the app downloads is maintained in a separate
repository (`NiallxD/OpenBat-FieldGuide`) under CC BY-NC 4.0 — see that repo's
own `LICENSE` and `NOTICE`. It is not covered by this file or by OpenBat's
`LICENSE`.
