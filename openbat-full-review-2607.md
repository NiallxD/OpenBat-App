# OpenBat — Full Codebase Review (2026-07-27)

Sequential, area-by-area adversarial review (7 areas, one subagent per area, run
one at a time). This follows on from the earlier consolidated review (privacy/
consent/upload — already triaged and largely fixed/paused) and completes the
three areas that were cut short by that review's spend limit (detector core,
performance, species guide), plus four additional areas.

**How to use this doc:** add your comments/verdicts inline under each finding
(e.g. "agree, fix" / "not worth it" / "already known" / a question), then we'll
triage into a fix plan together, the same way we did with the last review.

---

## Area 1 — Detector core pipeline

Scope: `AudioEngineController.swift`, `AudioRecorder.swift`, `PlaybackEngine.swift`,
`DSP/Biquad.swift`, `HeterodyneProcessor.swift`, `FrequencyDivisionProcessor.swift`/
`Settings.swift`, `TimeExpansionProcessor.swift`/`Settings.swift`, `PulseDetector.swift`,
`PulseSettingsView.swift`, the `bufferSink` wiring in `ContentView.swift`.

### 1.1 (High) Playback stop/restart race can corrupt shared DSP state
**File:** `OpenBat/Audio/PlaybackEngine.swift:297`
`PlaybackDriver.stop()`'s 200ms semaphore wait can time out while the old pacing
thread is still blocked reading an iCloud-evicted WAV, letting two producer
threads run concurrently against the same lock-free heterodyne/frequency-division
processors.

**Failure scenario:** User scrubs/seeks playback on an iCloud-backed recording
that isn't fully downloaded; the old thread's `FileHandle.read()` blocks past
200ms on the fetch, `stop()` returns anyway and a new thread starts calling
`process()`/`enqueue()` on the same `HeterodyneProcessor`/`FrequencyDivisionProcessor`
instances (non-atomic `phase`, `Biquad.z1/z2`, `decimCounter`, `envelope`,
`noiseFloor`, ring indices) while the old thread's last buffer is still in
flight — torn writes, corrupted ring index, or audible corruption. `load()`
also calls `heterodyne.reset()` right after `stop()` with the same exposure.

> **Your comment:** Fix this as per suggestion.

### 1.2 (Medium) Real-time audio thread allocates per callback
**File:** `OpenBat/Audio/AudioRecorder.swift:125`
`append()` allocates a new `Array` via `Array(UnsafeBufferPointer(...))` on
every realtime audio callback, on the same real-time thread the codebase
otherwise takes care to keep allocation-free.

**Failure scenario:** Under memory/thermal pressure during a long recording
session, the ~2048-float heap allocation (~187/s) stalls momentarily inside
the CoreAudio tap callback, causing the input buffer to overrun and CoreAudio
to drop/glitch audio — the same class of risk `HeterodyneProcessor`/
`FrequencyDivisionProcessor` deliberately avoid with reused scratch buffers.

> **Your comment:** Fix this as per suggestion.

### 1.3 (Medium/Low) No output limiter on heterodyne/freq-division gain
**File:** `OpenBat/Heterodyne/HeterodyneProcessor.swift:326`
No limiter/soft-clip before heterodyne and frequency-division render output;
default gain (6x heterodyne, 4x frequency-division) can push a loud, close,
on-frequency call well past ±1.0 full scale with nothing to catch it.

**Failure scenario:** A loud bat call near the tuned frequency, or a user who
raises gain in Settings, produces samples reaching ~3.0 in the Float32 output
buffer feeding `AVAudioSourceNode`, causing audible hard clipping/distortion
with no safeguard.

> **Your comment:** Fix this as per suggestion.

### Checked and found sound
Biquad math (textbook-correct RBJ cookbook coefficients), patent-adjacency
(both live listening modes are genuinely continuous sample-by-sample
transforms, no framing/selection/discard-then-transmit-slower scheme),
SPSC ring buffer design within `AudioEngineController`'s own capture pipeline,
state resets between sessions, `AudioRecorder`'s pre-roll/post-roll/segment
rotation state machine, `PulseDetector.feed()`'s deferred-capture arithmetic,
cross-thread control fields (all correctly guarded by `ctrlLock`).

Great to hear.

---

## Area 2 — Performance

Scope: `Spectrogram/*.swift`, `Spectrogram.metal`, `ClassificationStore.swift`
(perf angle), `PulseZoomView.swift`, `PulseStatsViews.swift`, `LiveStatusViews.swift`,
`ContentView.swift` (perf angle), `WavPlayer/*.swift`.

This area was unusually well pre-hardened — nearly every file has doc comments
describing prior perf bugs and fixes already in place. One genuine defect found.

### 2.1 (Medium) Per-hop heap allocation on realtime audio thread
**File:** `OpenBat/Spectrogram/SpectrogramProcessor.swift:345`
`makeColumn()` allocates two fresh zero-initialized `Float` arrays
(`triggerColumn`, `displayColumn`) on every FFT hop, breaking the file's own
reused-scratch-buffer discipline for the realtime audio thread.

**Failure scenario:** Runs ~1500x/sec inside the `AVAudioEngine` tap callback
(~12 MB/s of allocator+memset churn). On an older/base-model device with the
CoreML classifier also competing for CPU, allocator contention on this thread
risks audible clicks/dropouts during a dense burst of pulses. `triggerColumn`
is purely local and trivially fixable with a reused scratch member;
`displayColumn` escapes in `Column` so needs a small reusable buffer pool
instead.

> **Your comment:** Fix this as per suggestion.

### Checked and found sound
`HistoryBuffer`/`SpectrogramRenderer` (fully vDSP-vectorized, O(1) COW snapshot,
batched Metal uploads, no per-frame allocation in the draw loop), `ClassificationStore`
persistence throttling and bulk-delete (already fixed from O(n²)), `ContentView`/
`PulseZoomView`/`PulseStatsViews`/`LiveStatusViews` (`@Observable` churn-avoidance
pattern correctly applied everywhere, no new instances of the bug class),
`WavSpectrogramEngine`/`TwoAxisPinchView` (column-bounded regardless of zoom/file
length, debounced/throttled viewport renders), `CallAnalysis.swift` (bounded by
`maxAnalysisSpanSeconds`), `FrequencyBandControl`/`RangeSlider` (local `@State`
mirroring, commits only on gesture end).

Good to hear

---

## Area 3 — Species field guide

Scope: `SpeciesGuide.swift`, `SpeciesGuideStore.swift`, `SpeciesExplorerView.swift`,
`SpeciesDetailView.swift`, `GBIFService.swift`, `GBIFRangeMapView.swift`,
`WikipediaSpeciesImageService.swift`, `SpeciesGuideData.json`.

### 3.1 (High, confirmed) Species range store points at wrong GitHub repo
**File:** `OpenBat/FieldGuide/SpeciesRangeStore.swift:33`
`remoteURL` still points at `NiallxD/OpenBat` (this app's own repo) instead of
`NiallxD/OpenBat-FieldGuide` where `SpeciesRangeData.json` actually lives —
the exact same stale-URL bug already fixed in `SpeciesGuideStore.swift` this
session, missed in this sibling file.

**Failure scenario:** Every launch, `refreshFromRemote()` 404s against the
wrong repo and fails silently into `lastRefreshError`; the committed range
snapshot can never be picked up, so `GBIFDistributionCard` permanently falls
back to slower live per-species GBIF fetches instead of the fast/offline
snapshot path it was built for, for every user, forever.

> **Your comment:** Fix this as per suggestion.

### 3.2 (High, confirmed) Unsynchronized concurrent writes to Wikipedia photo cache
**File:** `OpenBat/FieldGuide/WikipediaSpeciesImageService.swift:41`
The photo-URL cache dictionary is mutated from concurrent, non-actor-isolated
`fetchImageURL` calls with no lock, unlike `GBIFService`'s `taxonKeyCache`
which has one for the identical concurrent-SwiftUI-`.task` shape.

**Failure scenario:** A region list scrolls with several `GuideSpeciesThumbnail`
rows resolving different species photos concurrently; the plain Swift
`Dictionary` write is unsynchronized across threads (execution isn't
guaranteed back on any particular thread after the network await), risking a
lost update, a corrupted cache, or undefined behavior under Swift's
exclusivity enforcement. `saveCache()` has the same unguarded race for the
on-disk file.

> **Your comment:** Fix this as per suggestion. Also, can we m load several images and allow the user to swipe through. Our approach shows a random image and some are not as good as others so a swipine mechanism would help mitigate that for now.

### 3.3 (Medium, confirmed) Wrong contribute-link URL in empty region view
**File:** `OpenBat/FieldGuide/SpeciesExplorerView.swift:493`
`RegionSpeciesView`'s empty-state "get started here" link points at
`github.com/NiallxD/OpenBat` instead of the real field-guide repo
`NiallxD/OpenBat-FieldGuide`.

**Failure scenario:** A user in an empty region taps the contribute link and
lands on the app's source repo instead of the field-guide data repo where
species/region PRs actually belong.

> **Your comment:** Fix this as per suggestion.

### 3.4 (Medium, plausible) No antimeridian handling in GBIF bounding box
**File:** `OpenBat/FieldGuide/GBIFService.swift:200`
`region(for:)` computes a bounding box with naive `min()`/`max()` longitude,
no antimeridian wraparound handling.

**Failure scenario:** Not triggered by today's 3 species/4 regions, but any
future community-contributed species whose occurrence points straddle ±180°
longitude would compute a ~360° span, centering the distribution map near 0°
instead of the dateline — opens zoomed out to nearly the whole globe instead
of the actual small range.

> **Your comment:** Fix this as per suggestion.

### 3.5 (Low, confirmed) Family color tint not actually stable across launches
**File:** `OpenBat/FieldGuide/SpeciesExplorerView.swift:397`
`GuideSpeciesThumbnail`'s family-color tint uses `String.hashValue` and
comments that it's "deterministic across launches," but Swift's hash seed is
randomized per process, so the claim is false.

**Failure scenario:** Each fresh app launch can reshuffle which color a given
family displays as, contradicting the stated intent; cosmetic only, not a
crash.

> **Your comment:** Fix this as per suggestion.

### 3.6 (Low, plausible) Non-unique ForEach IDs on duplicate content
**File:** `OpenBat/FieldGuide/SpeciesDetailView.swift:358`
`ForEach(species.editors, id: \.self)` and a similar `ForEach` for
`otherFeatures` use content identity, which collides on duplicate entries.

**Failure scenario:** Two editors with identical name/date/note, or a
duplicate string in `otherFeatures`, produce non-unique SwiftUI IDs — a
logged runtime diagnostic and possible row-identity glitches, not a crash. No
such duplicates exist in today's data.

> **Your comment:** Fix this as per suggestion.

### Checked and found sound
`SpeciesGuideStore.swift`'s bundled/cached/remote resolution (validates HTTP
200, decodes, checks `schemaVersion` + strictly-greater `dataVersion` before
ever adopting a remote copy; self-heals a corrupt cache), `SpeciesGuide.swift`
schema/fuzzy search, the bundled JSON data (no id collisions, no dangling
region refs, no missing required fields), GBIF taxon-key cache lock, H3
binning, `GBIFDistributionCard` state machine, region-grouped-by-family list.


I jsut wanted to add something here - we dont want to capture any personal info here if we can. So consider that. If it is a risk, we can leave contributor info in the git repo and just show a link in the app to the repo.

---

## Area 4 — Classifier / AutoID

Scope: `ModelRegistry.swift`, `BatDetect2Classifier.swift`,
`BatDetect2SpectrogramRenderer.swift`, `BatClassifier.swift`, `PassAggregation.swift`,
`ClassificationStore.swift` (classification-result angle), `AutoIDSettings.swift`,
species-complex logic.

### 4.1 (High, confirmed) NOISE class can appear as a runner-up species
**File:** `OpenBat/Classifier/PulseDetector.swift:339`
Runner-up computation excludes only the winning species, not the `NOISE`
class, so `NOISE` can be shown as a "runner-up species" candidate.

**Failure scenario:** `PassAggregation.aggregate` correctly excludes `NOISE`
from the winner pool, but `PulseDetector`'s separate runner-up calc doesn't —
a pass can win as e.g. `EPFU` while `NOISE` has the second-highest mean
score, persisting `runnerUpSpecies = "NOISE"` and rendering as "Runner-up:
NOISE (12%)" in `SpeciesFeedView` and `SessionsView`, confusing a non-taxon
class with a candidate species ID.

> **Your comment:** Would there be a situatin were a sound might be genuinely close to a bat pulse but could be noise? I dont see it being a big issue to show noise as a runner up if it genuonly could be? But if noise is somehow overstepping a genuine runner up we need to fix that.

### 4.2 (Medium, plausible) No NaN guard in classifier normalization
**File:** `OpenBat/Classifier/BatClassifier.swift:142`
No `isFinite`/NaN guard when normalizing classifier output; a NaN raw score
makes `total` NaN, skips normalization, and silently defaults `bestIdx` to 0
with a NaN confidence.

**Failure scenario:** A genuine CoreML numerical fault produces NaN in one
output; `total > 0` evaluates false so normalization is skipped, and every
`adjusted[i] > adjusted[bestIdx]` comparison against NaN is false so
`bestIdx` stays 0 — the app silently reports `classNames[0]` (ANPA/MYOMYS)
with a NaN confidence that then propagates into `PassAggregation`'s summed
scores and `max()` calls with undefined behavior on NaN-containing
collections.

> **Your comment:** Fix this as per suggestion.

### 4.3 (Low, plausible) Renormalization safety is implicit, not enforced
**File:** `OpenBat/Classifier/BatClassifier.swift:142`
Prior renormalization's safety against divide-by-zero when all species are
disabled relies entirely on an out-of-file invariant (`AutoIDSettings` floors
disabled priors at 0.01, never 0.0) rather than a guard in the classifier
itself.

**Failure scenario:** Not currently exploitable since `AutoIDSettings.
effectivePrior` never returns exactly 0, but a future caller (test harness, a
hard-exclude feature) passing a genuine 0 prior for every species would hit
`total == 0` with no explicit guard, leaving an unnormalized/garbage
posterior.

> **Your comment:** Fix this as per suggestion.

### Checked and found sound
Colormap/preprocessing fidelity for BOTH classifiers (extensively
checkpoint-verified against real training pipelines — this was the past
LANO/magma-vs-viridis failure class, re-checked carefully and found correct
for both NABat and BatDetect2's very different renderers), prior-based
species filtering (implemented correctly, contrary to CLAUDE.md's stale
"Pending" note), confidence/threshold consistency, species-complex membership/
ambiguity logic, pass aggregation weighting (averaging, not vote-counting —
a defensible design, not a bug).

Great to hear.

---

## Area 5 — Sessions / GPS / Recording

Scope: `LocationProvider.swift`, `ClassificationStore.swift` (session
lifecycle), `SessionsView.swift`, `LocationChangeSummaryView.swift`,
`GuanoMetadata.swift`, `AudioRecorder.swift` (session/segment lifecycle),
`PassAggregation.swift`, `RecordingMigration.swift`, map-pin gating.

### 5.1 (High, confirmed) Listening-mode WAVs get exact GPS despite no-location rule
**File:** `OpenBat/ContentView.swift:400`
Recorder's GPS coordinate is pushed unconditionally from
`location.currentCoordinate` with no gate on whether a session is active,
contradicting `AudioRecorder`'s own documented "Listening files get none"
design and `PulseDetector`'s correct session-gated coordinate provider.

**Failure scenario:** `requestRegionFix()` runs on every launch/foreground
independent of sessions, so `currentCoordinate` is frequently non-nil during
"Just Listening" — which the UI explicitly describes as not logging
location. Recordings made in that mode still get an exact 6-decimal GPS fix
baked unfuzzed into the WAV's GUANO `Loc Position` field and
`Recording.latitude/longitude`, which a user could then share via
Files/AirDrop, defeating the "Listening = no location" contract even though
the separate upload path does grid-snap correctly.

> **Your comment:** Ok, we store accurate gps on the session recordings and we should do on just listening too. All session does is groups them into a batch and adds them to a map. Just to ways of viewing things. But location is needed in the file and the comments are an oversigh. Fix the oversight and make sure a session recording and a just listening recording hold the same data fields/accuracy. 

### 5.2 (Medium, confirmed) Silent GPS failure mid-session, no user-facing signal
**File:** `OpenBat/Location/LocationProvider.swift:167`
Authorization revocation mid-session (denied/restricted) and location errors
are silently swallowed — tracking state is never cleared and no UI signal
reflects that fixes stopped arriving.

**Failure scenario:** User starts a session then revokes location permission
(or "Always" access lapses in background); the session silently stops
accumulating GPS breadcrumbs forever while the location UI still displays as
if live, with no alert that positioning stopped.

> **Your comment:** Fix this as per suggestion. Maybe just add a warning in the same spot as the headphone warning. Maybe make it yellow if there is one warning (just headphones or just gps) and red if there are two or more. Tapping will show a pullover that shows all warning/errors. This keeps it within the UI and simplifies the tour alteration.

### 5.3 (Medium, confirmed) Killed sessions never get an end date, never reconciled
**File:** `OpenBat/Classifier/ClassificationStore.swift` (`activeSessionID`)
`activeSessionID` is pure in-memory state, never persisted, so an app
kill/eviction mid-session leaves the persisted `RecordingSession`'s `endDate`
nil forever with no startup reconciliation to close it out.

**Failure scenario:** `SessionsView` shows "start – now" indefinitely for the
orphaned session, implying an ongoing outing that ended long ago; it also
widens `RecordingMigration`'s date-range session-matching into an unbounded
window that could mis-attribute a later orphaned WAV to the wrong, long-dead
session during a manual migration run.

> **Your comment:** Fix this as per suggestion. What happens when the app is backgrounded fduring a just listening or a session? Ideally we keep going to allow someone to put headphones in and pocket theri phone while holding the detector on a long wire.

### 5.4 (Low, plausible) GUANO session label never updated after rename
**File:** `OpenBat/Audio/AudioRecorder.swift:1350`
The GUANO session-label tag is frozen at session start and never refreshed
when the session is later reverse-geocoded or manually renamed.

**Failure scenario:** Every WAV from a session keeps the stale
pre-geocode/pre-rename date/time label in its GUANO chunk permanently, while
the in-app Sessions list shows the enriched title — a metadata mismatch on
any exported file.

> **Your comment:** Fix this as per suggestion.

### 5.5 (Low, plausible) Failed writes still counted in WAV's declared length
**File:** `OpenBat/Audio/AudioRecorder.swift:371`
`write(_:)` uses `try?` and unconditionally increments `dataBytes` regardless
of whether the write actually succeeded.

**Failure scenario:** A write throws under disk-full/I/O error conditions;
`dataBytes` still counts those bytes, so `closeAndKeep` patches the
RIFF/data-size header fields to a length exceeding what's actually on disk —
a strict WAV parser could read past real EOF or reject the file outright.
The GUANO-chunk-append and header-patch writes have the same silent
`try?`-swallowing pattern.

> **Your comment:** Fix this as per suggestion.

### Checked and found sound
GUANO chunk framing (correct FOURCC, size, padding, round-trips correctly),
RIFF size patching on close, filename collisions (negligible risk),
map-pin gating (straightforward thresholds, no clustering logic to have an
off-by-one in), `PassAggregation` sharing between live IDs and WAV tags,
coordinate staleness/accuracy filtering in `didUpdateLocations`.

---

## Area 6 — Settings / Onboarding / ContentView

Scope: `ContentView.swift` (full), `SettingsView.swift` (full),
`OnboardingView.swift`, `ConsentView.swift`, `SafariView.swift`,
`OpenBatApp.swift`, `DiagnosticsView.swift`.

### 6.1 (Medium, confirmed) Pre-roll/post-roll recording settings don't persist
**File:** `OpenBat/Audio/AudioRecorder.swift:68`
`preRollSeconds` and `postRollSeconds` are plain properties with no
persistence (no `@AppStorage`, no UserDefaults load/save), unlike every
sibling control in the same Settings section.

**Failure scenario:** User tunes pre-roll/close-after-silence sliders (e.g.
to keep a feeding buzz in one WAV), force-quits the app, and the values
silently revert to the 3.0s/3.0s defaults on next launch since `AudioRecorder`
is a `@State` recreated fresh each cold start — no restart-needed banner, no
indication the setting isn't durable.

> **Your comment:** Fix this as per suggestion.

### 6.2 (Medium, plausible — unverified on-device) Settings view not isolated from AppStorage churn
**File:** `OpenBat/SettingsView.swift:55`
Four `@AppStorage` properties are declared directly on `SettingsView`'s
top-level body rather than scoped into a leaf view, so any UserDefaults write
from a sibling control (`FrequencyDivisionSettings`/`PulseDetector` sliders
write on every drag tick) invalidates the whole `SettingsView` body — the
same churn-bug class already fixed elsewhere in this codebase, potentially
recurring here.

**Failure scenario:** Dragging a slider like "Output gain" fires `didSet`
writes to `UserDefaults.standard` dozens of times/second; since
`SettingsView.body` (containing the segmented Picker and toolbar Done
button) isn't isolated from that churn the way `ContentView`'s leaf views
were, a tap on Done during/right after a drag could plausibly be dropped for
the same reason the old amplitude-meter churn froze `ContentView`'s buttons.
Not reproduced on-device (build-only review) — worth a manual
drag-then-tap-Done check.

> **Your comment:** Fix this as per suggestion.

### Checked and found sound
App-root reconstruction bug (not reintroduced — `OnboardingState` correctly
uses `@Observable`, not `@AppStorage`), `@Observable` churn class in
`ContentView`/`DiagnosticsView` (no new instances, all high-rate reads
correctly scoped into leaf views), dead-code reachability of `ConsentView`
(genuinely unreachable — only call site gated behind the hardcoded-false
`uploadContributionEnabled` flag), onboarding flow permission-denial handling
(advances gracefully regardless of grant/deny), app lifecycle/scenePhase
handling, other Settings tabs (AutoID model switching, `keepInICloud`
restart-needed alert).

---

## Area 7 — Backend Worker

Scope: `backend/consent-worker/src/index.ts`, `schema.sql`, `wrangler.toml`,
`README.md`, `package.json`, migrations. Excludes everything already
catalogued/deferred from the prior consolidated review (App Attest gap, 3.0
consent-version 403 loop, missing `consent_text_sha256`/`received_at`/
append-only events, upload-header join risk, `GET /consent` dead code,
erasure race in `suspend()`).

### 7.1 (Medium, confirmed) README describes a removed, contradictory design
**File:** `backend/consent-worker/README.md:129`
README's Endpoints reference table describes a design that was already
removed from code: it claims `DELETE /consent` sweeps R2 objects under
`{device_id}/` and emails `privacy@openbat.app`, and that upload URLs are
device-prefixed — neither matches the shipped anonymized `index.ts`.

**Failure scenario:** `handleErase` only deletes the D1 row and bumps a
monthly counter (no R2 sweep, no email, `RESEND_API_KEY` already removed
elsewhere), and `UPLOAD_KEY_PATTERN` has no device_id segment at all. Anyone
auditing "does erasure/upload actually behave the way we tell users" — a
future engineer or an App Store privacy sign-off — would read this section
and get a false picture that directly contradicts the anonymous-upload
design the rest of the codebase relies on. The file's own earlier
setup/history prose correctly says this stuff is gone; only the endpoint
reference table at the bottom was never updated.

> **Your comment:** Fix this as per suggestion.

### 7.2 (Medium, confirmed) TOCTOU race on upload overwrite protection
**File:** `backend/consent-worker/src/index.ts:270`
The "no overwrite" guarantee on uploads is a TOCTOU race: `bucket.head(key)`
and `bucket.put(key, ...)` are separate non-atomic R2 calls, not an atomic
conditional write.

**Failure scenario:** A client that times out waiting for a PUT response
(body already fully delivered) and retries with the same `object_id` — a
realistic retry pattern, not just adversarial — can race two concurrent
requests past the `head()` check before either `put()` lands, silently
overwriting one upload's `customMetadata` (species/quality-score/
location/verified) with no error surfaced to either caller. The 409
protection is best-effort, not the real guarantee the code comment claims.

> **Your comment:** Fix this as per suggestion.

### 7.3 (Medium, confirmed) Declared upload size never checked against actual bytes
**File:** `backend/consent-worker/src/index.ts:238`
Upload size limit only validates the declared `Content-Length` header against
`MAX_UPLOAD_BYTES`; the actual byte count streamed into R2 is never verified
against that declared/checked length.

**Failure scenario:** A client sends a `Content-Length` under the cap but
streams more bytes than declared — the 413 check never fires since it only
inspects the header, and the extra bytes get written straight into R2,
bounded only by Cloudflare's platform-level 100MB cap rather than this
Worker's stated business limit.

> **Your comment:** Fix this as per suggestion.

### 7.4 (Low, confirmed) db:migrate script skips three later migrations
**File:** `backend/consent-worker/package.json:8`
The `db:migrate` npm script only runs migration 001; migrations 002-004 exist
on disk but aren't referenced by any script, only runnable by hand-copying
each file's own wrangler command.

**Failure scenario:** Anyone following the README's documented `npm run
db:migrate` path on an older database applies only the token-issuance
migration and silently misses the `erasure_requests` table creation and two
subsequent schema changes in 002-004, unless they separately read every
migration file's header comments.

> **Your comment:** Fix this as per suggestion.

### Checked and found sound
SQL parameterization (every D1 query uses `.bind()`, no string concatenation
anywhere), path traversal on R2 keys (regex shape makes it structurally
impossible), auth boundary/routing order (every side-effecting route gates on
`authorize()` first), schema vs. code assumptions (no drift), config/secrets
(no committed API keys or account-scoped secrets, `DEVICE_TOKEN_SECRET`
correctly kept out of `wrangler.toml`).

---

## Summary tally

| Area | High | Medium | Low | Total |
|---|---|---|---|---|
| 1. Detector core pipeline | 1 | 2 | 0 | 3 |
| 2. Performance | 0 | 1 | 0 | 1 |
| 3. Species field guide | 2 | 2 | 2 | 6 |
| 4. Classifier/AutoID | 1 | 0 | 2 | 3 |
| 5. Sessions/GPS/Recording | 1 | 2 | 2 | 5 |
| 6. Settings/Onboarding/ContentView | 0 | 2 | 0 | 2 |
| 7. Backend Worker | 0 | 3 | 1 | 4 |
| **Total** | **5** | **12** | **7** | **24** |
