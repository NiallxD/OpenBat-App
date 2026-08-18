# Consistency review — 2026-08-15

App source as the source of truth; everything else follows it.
**16 findings, 14 fixed, 2 left for you.** Not committed to the repo — see the
note at the end.

## Fixed

| # | Finding | Where fixed |
|---|---|---|
| A1 | App fetched range data from `NiallxD/OpenBat` while the field guide README promised edits there reached the app | `SpeciesRangeStore.swift` → `OpenBat-FieldGuide`; `Context.md` §15 item 3.1 closed |
| A2 | Field guide README duplicated the app description and had drifted ("slowed 10×", wrong coverage, Griff Mini only) | field guide `README.md` — app description replaced with a pointer |
| B1 | `README.md` said location was used only during a Session | `README.md` §Privacy |
| B2 | The book documented adaptive time expansion + sampler mode as shipped, never mentioned snippet expansion | *How OpenBat Works* §12 rewritten, plus 12 references across the document |
| B3 | Function explainer: 23 stale mode mentions, no repo twin | staleness banner added; deletion left to you |
| B4 | "App Store Review Notes" is actually a superseded architecture spec | banner added explaining both problems |
| C1 | Home offered an App Store download; `/download-openbat/` said coming soon | `Home.md` — app confirmed *not* on the App Store |
| C2 | Home claimed "North America and Canada with UK/Europe in beta" | `Home.md` — North America, UK in beta |
| C3 | Help said location was used for two things, "nothing more" | `Help.md` |
| C4 | Contribute linked `OpenBat-Fieldguide` | `Contribute.md` |
| C5 | Privacy Policy numbering skipped §5 | renumbered; confirmed no content lost |
| D1 | UI copy promised not to touch "anything already uploaded" | `SettingsView.swift`, `DeleteAllRecordingsConfirmationView.swift` |
| D2 | Bundled seed guide was dataVersion 4 (3 species) vs remote 10 (19 species) | refreshed and validated |
| — | `LiveTuningTabs` comment said four tabs; there are five | `LiveTuningTabs.swift` |

Also: `Context.md` now records where the book lives, and `CLAUDE.md` carries a
propagation map (below).

## Left for you — both need a decision, not a fix

### 1. There is a second, live website with a wrong licence ⚠️

`OpenBat-FieldGuide` also serves a GitHub Pages site at
**niallxd.github.io/OpenBat-FieldGuide/** (HTTP 200), built from `index.html`,
`help.html`, `privacy.html` in that repo. Two problems:

- **`privacy.html` is a placeholder.** "Last Updated: **TBD**", an unfinished
  sentence ("what data OpenBat collects, when it collects it, why it."), and it
  describes opting in to data collection and requesting removal — a flow the
  shipped app does not have. It contradicts the real policy at openbat.app.
- **It states "Released under the MIT License."** Your `LICENSE` says the
  opposite: source-available, all rights reserved, explicitly *not* open source.

A published, incorrect licence grant is the most serious thing this review
found. Options: delete the three HTML files (Pages 404s), redirect to
openbat.app, or turn Pages off in repo settings. I didn't act because taking
down a live site is your call.

### 2. Delete the two Obsidian documents, or maintain them?

The function explainer is unmaintainable by nature — the same reason its repo
twin was deleted. The architecture spec has archival value but a misleading
name. Both now carry banners; neither vault is version-controlled, so deleting
is irreversible.

## Not pushed

- **App repo** — pushed.
- **Website** — committed locally (`4a73d8b`), not pushed. It publishes to
  openbat.app.
- **Field guide** — committed in a temporary clone at
  `scratchpad/fg`, not pushed. Say the word and I'll push both.
- **Obsidian** — saved in place; no version control, nothing to push.

## What stops this recurring

`CLAUDE.md` now opens with a propagation map: where each of the five descriptions
of the app lives, which ones are outside version control, and what to update for
each kind of change (listening modes, models, location/privacy, schema, seed
data, deletions, release status). It ends with a rule — name the targets you
updated in your final report, because "docs updated" is how this drift happened:
the 2026-08-09 mode rework reached none of the four external documents, and two
of them still described the removed mode nine days later.
