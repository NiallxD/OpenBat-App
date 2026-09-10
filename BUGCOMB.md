# Bug comb — v1.1 pre-release

Run started 2026-09-10. Orchestrated sweep across subsystems.
Severity: **P0** ships-broken · **P1** wrong behaviour a user hits · **P2** edge case / latent · **P3** cleanup.

_Status: sections A–L complete. **Fixed 2026-09-10:** every P0 and P1 in A, B, D, E,
H, I and J; the field-guide and call-analysis findings in F; and in L — the snippet
level protections, the heterodyne output rate, the calibration-curve rate match, the
scroll-back end stop, and both export findings. **Also fixed 2026-09-10 (visual
tail):** the inert info glyph and the orphan `Spacer` in A, the winner-alone chip's
red half, the degenerate-geometry collapse in `SessionButtonLocator`, the duplicated
overview column at each hide-silence gap, and the ring sampler's vertical wrap.
Still open: the rest of the P2/P3 tail (see Context.md §17 for what was deliberately
left)._

---

## A. The uncommitted ID-score work (reviewed directly)

Build state: `xcodebuild` build-only **succeeds** with the working tree as it stands (0 errors).

### [P1] One pill shows two different quantities, and never says which
`OpenBat/IDScoreViews.swift:144` · `SpeciesFeedView.swift:297` · `SessionsView.swift:1206`

`IDBadge` shows the species' **precision** where the model publishes one and silently
falls back to the call's **confidence** where it doesn't (`kind = precision == nil ? .confidence : .precision`).
The two are different quantities on different scales with different colour bands — and the
pill prints a bare "94%" either way. In a Sessions list a NABat species and a species below
the 30-file sample floor sit one row apart wearing identical pills that mean unrelated things.
Only the accessibility label distinguishes them; a sighted user cannot. The onboarding card
added in this same change ("The percentage we show is how often this model is right when it
names that species") is simply false for every fallback case.

### [P1] Simplified view hides the numbers in the feed and shows them everywhere else
`SpeciesFeedView.swift:141,282,296` vs `SessionsView.swift:1206,1291,1351` · `RecordingViews.swift:394`

The species feed gates `IDBadge` and `ScoreComparison` behind `!simplifiedMode`, on the stated
reasoning that "numbers are advanced-mode furniture". Nothing else does. A simplified-mode user
sees no percentage in the live feed, taps a row through to a pass detail, and meets *two*
labelled percentages plus a per-pulse pill — the exact essay the feed decided they shouldn't
have to read. The "How we get to an ID" info button, which is the simplified user's only
explanation, tells them to enable Advanced mode to see scores they are already looking at.

### [P2] A pass with no runner-up still gets a red half to its chip
`IDScoreViews.swift:245-251,275`

`isClose` returns `false` when there is no runner-up, so `loserColor` becomes `.red` and the chip's
background gradient runs green → red — across a chip that renders the winner alone. The clearest
possible result (nothing else came close) is washed the same red as a decisive loss. Its own
popover says "Nothing else came close to this one" while the chip behind it reads as a warning.

### [P2] An info glyph that isn't tappable
`IDScoreViews.swift:163`

`pill` always draws an `info.circle`, but `IDBadge` only wraps it in a Button when
`interactive` is true. Every Sessions row (`interactive` defaults to false) shows an info
affordance that does nothing when tapped — the NavigationLink swallows it and pushes the detail
screen instead. Deliberate per the doc comment, but the glyph is what makes it a lie.

### [P2] Content collapses to zero on a degenerate first geometry
`SessionButtonLocator.swift:735-742`

The rewrite trades measured content size for pure layout, which fixed the tour spotlight.
But `max(0, above)` and `max(0, 2 * centreX)` now silently clamp: if the button's frame sits
above the host's top edge or at its leading edge for one pass — a tab transition, a rotation —
the content is framed at zero height or zero width and renders crushed rather than merely
mispositioned. The old code hid that frame with `.opacity(0)`; nothing hides this one.

### [P3] Dead model-dispatch table
`ModelReliability.swift:118-127`

`batDetect2` and `table(forModel:)` are unused — `reliability(for:)` reads `nabat` directly.
The comment explains why the lookup needs no model argument, which makes the dispatch table
that argument would have used vestigial.

### [P3] Spacer with nothing after it
`SessionsView.swift:1268-1271`

Removing the header badge left `HStack { Text(pass.species); Spacer() }`.

---

## B. Live audio capture, recording and playback

### [P0] A phone-call interruption silently disarms an armed recorder — the exact bug that was already fixed once, reappearing on a different path
`AudioEngineController.handleInterruption` (Audio/AudioEngineController.swift:1362-1381), `AudioEngineController.isActive` (line 98), `ContentView.swift:778-794`.

`isActive` is defined as `isRunning || isSwitchingListenMode` and exists specifically so a transient stop (a listen-mode restart) doesn't read as "session over" and disarm the recorder — see the long comment at `setListenMode` explaining the 2026-08-09 fix for exactly this class of bug. But `handleInterruption(.began)` (an incoming call, Siri, another app grabbing the session) sets `isRunning = false` directly without ever setting `isSwitchingListenMode`, so `isActive` also goes false. `ContentView`'s `onChange(of: audio.isRunning)` handler then runs `if !audio.isActive, recorder.isArmed { recorder.setArmed(false) }`. So a user who armed recording, gets a phone call, and lets `.ended` auto-resume capture (`handleInterruption(.ended)` calling `start()`) finds capture running again but recording silently disarmed — no restart of the recorder, no alert. This is precisely the failure mode the comment beside `isActive` says the flag exists to prevent, just reached via interruption instead of `setListenMode`.

### [P0] PlaybackEngine configures AVAudioSession synchronously on the main actor, violating the project's own stated rule
`PlaybackDriver.startEngine(outputRate:)` (Audio/PlaybackEngine.swift:269-326), called from `PlaybackEngine.startDriver()` → `driver.configureOutput(sampleRate:)` (line 1062), which is itself called directly from `play()`/`restartIfPlaying()` on `@MainActor` `PlaybackEngine`.

`AudioEngineController` is careful to run every `setCategory`/`setActive` call on a `Task.detached` (see `configureSession`), with an explicit comment citing "hundreds of ms" of blocking under route renegotiation — this is called out in both `CLAUDE.md` ("AVAudioSession configuration must run off the main actor") and Context.md §6. `PlaybackDriver.startEngine` calls `session.setCategory(.playback, mode: .default, options: [])` and `session.setActive(true)` directly, with no `Task.detached` and no thread hop. Because `configureOutput`/`startEngine` are invoked synchronously from `PlaybackEngine.play()` (a main-actor method), these blocking system calls execute on the main thread every time playback starts fresh or needs a different output rate (e.g. first play of a recording, or a mode/speed change that changes `outputRate`). A user pressing play, especially with headphones/Bluetooth routing in play, can see the UI freeze for as long as iOS takes to renegotiate — the same UI-freeze failure mode Context.md documents for the live capture path before it was fixed.

### [P1] A long recording bout rotating past `maxSegmentSeconds` reports a start time that doesn't match its audio, though this was traced and ruled out as fine
Not included as a separate item — verified benign: `preRollRing` is drained to empty by `writePreRoll()`/`clearPreRoll()` on the segment that consumes it, so a same-bout rotation (`AudioRecorder.handle`, Audio/AudioRecorder.swift:586-590) starts its next file with an empty pre-roll and a correct `triggerDate`-based `segmentStartDate`. No defect here — noting it because the mechanism looked suspicious on first read and needed the ring-lifecycle trace before it could be ruled out.

### [P2] Demo mode keeps feeding the pipeline through a system audio interruption while the UI reports "Interrupted"
Audio/AudioEngineController.swift:575-645 (`startDemoCapture`), :1362-1381 (`handleInterruption`).

`DemoFileSource.start` drives its own `DispatchSourceTimer` independent of `AVAudioSession`/`AVAudioEngine` state, and its buffer-delivery closure (line 627-633) calls `consume`/`bufferSink` unconditionally — nothing in it checks `isRunning`. A real interruption (incoming call) sets `isRunning = false` and status to "Interrupted", but does not call `demoSource?.stop()`, so in demo mode with listening on, the spectrogram/pulse detector keep receiving synthetic audio and the demo clock keeps advancing while the UI claims capture is interrupted. Cosmetic/inconsistent rather than data-losing (recording is already blocked in demo mode), but it means "Interrupted" is a lie in this specific case.

### [P2] `handleInterruption(.began)` tears down neither the tap, the engine, nor the session, unlike every other stop path
Audio/AudioEngineController.swift:1362-1368, contrast with `stop()` (lines 508-537) and `handleRouteChange` (lines 1350-1359), both of which explicitly `removeTap`/`engine.stop()` before touching anything else.

On `.began`, the handler only invalidates the stats timer and flips `isRunning`/`status`; it leaves `engine` (with its installed tap and, if listening, its attached source node) exactly as it was. `AVAudioEngine` itself may have been silenced by iOS at the interruption, but the app never explicitly relinquishes the tap or deactivates the session here. On `.ended`, `start()` → `startEngine()` unconditionally replaces `engine` with a fresh `AVAudioEngine()` (line 903) and reinstalls the tap, so the old engine/tap are simply dropped rather than torn down via the same `removeTap`/`stop()` sequence every other transition uses. Most likely masked by ARC deinit rather than a visible failure, but it's an inconsistent teardown path relative to every other engine transition in the file, and is the kind of thing that has previously produced a wedged session (Context.md §6's deactivation-race note) when two teardown paths raced.


---

## C. Upload, consent and iNaturalist

# Upload / consent / iNaturalist — findings

## Invariant check

1. **`AnonymizedUploadBuilder` is the single anonymisation boundary; nothing derived from `DeviceIdentity` appears in its output.** HOLDS. `AnonymizedUploadBuilder.build` (`OpenBat/Upload/AnonymizedUploadBuilder.swift:165-209`) takes no device-identity parameter and the type has no way to obtain one. The only place `DeviceIdentity.current` is used in the upload path is `RecordingUploader.upload` (`OpenBat/Upload/RecordingUploader.swift:459`), as a transient `x-openbat-device-id` request header built independently of `anonymized.headers` — it is never merged into the GUANO or the R2 object key. Traced every field in `AnonymizedUpload`: `objectID` is a fresh `UUID()` (line 177, not `Recording.id`), `objectKey` derives only from the bucketed date + that UUID, `coordinate`/`recordedAt` are grid-snapped/bucketed, and `guanoChunk`/`headers` are built solely from `allowedGuanoKeys`-filtered fields plus species/confidence/quality. No leak found.

2. **The GUANO key list is an allowlist, never a denylist.** HOLDS. `derived = originalFields.filter { allowedGuanoKeys.contains($0.key) }` (`AnonymizedUploadBuilder.swift:179`) — a field survives only if explicitly named in `allowedGuanoKeys`. `guanoChunk(from:)` also only emits keys present in the fixed `guanoKeyOrder` list, so even a defensive double-check is allowlist-shaped, not denylist-shaped.

3. **The on-device original is never reopened for writing.** HOLDS. `UploadConversionPipeline.convert` (`UploadConversionPipeline.swift:84-127`) only opens the original for reading (`WavPCMReader.readSamples`, `GuanoMetadata.read`) and writes exclusively to a freshly created file in `derivedCopyDirectory` (`writeDerivedWav`, line 179). `FLACEncoder.encode` likewise only reads the derived WAV and writes a new `.flac`. No write path touches `originalWavURL`.

4. **No lossy codec at any stage.** HOLDS. The only compression step is `FLACEncoder` (`Upload/FLACEncoder.swift`), backed by libFLAC (lossless). `HighPassPrivacyFilter` is a filter, not a codec, and is explicitly documented as privacy-motivated, applied only to the transient copy. The iNaturalist path (a separate, identified feature, not the anonymisation boundary) posts WAV/PNG only — no MP3/AAC/Opus anywhere in `Upload/` or `INaturalist/`.

5. **Nothing uploads on its own — contribution is always a deliberate tap.** HOLDS, and doubly so at present. `handleRecordingSaved` requires `forceAttempt` (set only by the user tapping "Upload Now" or a retry of something the user already asked to send) before it converts/encodes/uploads anything; absent that it only ever marks a recording `.queued`/`.notContributing` (`RecordingUploader.swift:249-363`). `retryFailedUploads` only re-attempts recordings already `.failed` (i.e. previously tapped). On top of that, `ConsentStore.uploadContributionEnabled = false` is the shipped state, and both `UploadClient.baseURL` and `ConsentAPIClient.baseURL` are empty strings, so the entire consent-backend/upload path is presently a severed no-op regardless of taps. The iNaturalist path is independently gated on an explicit "Post to iNaturalist" tap plus a mandatory "Before you post" alert (`INatObservationSheet.swift:348-364`); `INatUploadManager.post` guards `job == nil` so a second tap while one is in flight is a no-op.

All five hold. The anonymised-upload feature is currently inert end-to-end (contribution switched off, both backend base URLs empty), so these invariants are presently unfalsifiable in production traffic, but the code that will run the moment they're restored is sound.

## Findings

### [P1] Every iNaturalist post leaves multi-megabyte temp files on disk forever
`OpenBat/INaturalist/INatObservationSheet.swift:143-192`, `OpenBat/INaturalist/INatObservation.swift:415, 471, 706, 1070`

`INatObservationSheet`'s `.task` writes the cut pass segment (`INatExport.passSegment` → `writeSegment`, up to ~20 MB) and every rendered photo (`prepared.photos`, one file per PNG) into `FileManager.default.temporaryDirectory`, named after the recording (`\(baseName)-pass.wav`, `\(baseName)-\(photo.name)`). Nothing in `INaturalist/` or the sheet's dismissal path ever calls `removeItem` on these — contrast with `INatClient.attach`, which does clean up its own multipart temp files via `defer`. Each recording a user opens the "Add to iNaturalist" sheet for (whether or not they post, sign in, or use the manual route) leaves its pass WAV and PNGs behind permanently; the app never sweeps `tmp` at launch the way `RecordingUploader.purgeOrphanedDerivedCopies` does for the anonymised-upload path. Over a season of reviewing many recordings this accumulates tens or hundreds of MB in `/tmp`, reclaimed only whenever iOS itself decides to purge it (unpredictable timing, not guaranteed while the app is in use). User-visible effect: on-device storage fills silently; nothing in the UI shows it or explains it.

### [P2] `RecordingUploader.handleRecordingSaved` treats "upload service not configured" the same as "quota rejected," but the user still sees an actionable-looking status
`OpenBat/Upload/RecordingUploader.swift:305-308`

Because `UploadClient.baseURL` is empty by design right now, every `forceAttempt` (a real user tap on "Upload Now") reports `.failed("Upload service not configured yet")` — worded as if it's a transient outage. `retryFailedUploads` will then repeatedly re-attempt this via the Wi-Fi-return path (`RecordingUploader.swift:144-146`, `NWPathMonitor` handler) every time the device regains Wi-Fi, and via `.failed`'s general retry-eligibility, forever, for a feature that is deliberately switched off with no ETA. This isn't a privacy defect, but it's a real UX defect worth flagging alongside the invariant work: a user who taps "Upload Now" gets a message implying the network/server is briefly down, and the app will keep quietly retrying a request that can never succeed until the flag is flipped.

### [P2] iNat sound-size check runs against the wrong number after a user removes photos or when padding shrinks
`OpenBat/INaturalist/INatUploadAssessment.swift:336-359`

`estimatedUploadBytes` is explicitly documented (and self-documented in the code) as an approximation that "cannot see the silence map" and can under-count relative to the real cut in `INatExport.passSegment` when calls alone span more than 27 s — at which point `INatUploadAssessment.assess`'s hard blocker (using the real `uploadBytes`, computed after the real segment exists) is the actual backstop. This is called out and accepted in-repo (`Context.md` §11, "its two thresholds are reasoned, not measured" / "the real cut can [exceed the estimate]"), so it is a known, bounded approximation rather than a new defect — flagging only because the badge (list row) can show a size/rating a full grade more generous than the sheet's own assessment for the same recording, which is a UX inconsistency a reviewer should be aware persists by design.

### [Not a defect, verified] Duplicate-submission safety on retry/double-tap
`OpenBat/INaturalist/INatClient.swift:91-187`, `OpenBat/INaturalist/INatObservation.swift:98-102`

Confirmed idempotent: `observationUUID = recording.id` (deterministic, not a fresh UUID), and `INatClient.post` calls `observationExists(uuid:)` before `create`, short-circuiting to `alreadyExisted = true` if the observation already exists server-side. A network failure after the server actually created the observation (client-side timeout) is handled correctly on retry — the second attempt finds the record via the UUID and skips re-creating it, and `INatPostLedger.record` (governs the per-species/night/place cap) is only invoked from `INatUploadManager.complete` when a post actually finishes, so a failed/interrupted attempt never double-counts against the cap. `INatUploadManager.post` also refuses to start a second job while one is in flight. No fix needed here — called out because it was explicitly in scope and holds up.

### [Not a defect, verified] Token expiry/refresh and HTTP status handling
`OpenBat/INaturalist/INatAuth.swift:174-205`, `OpenBat/INaturalist/INatClient.swift:433-479`

The v2 JWT is re-minted a few minutes early relative to its ~20-24h life (comment says up to 20h, cache line says 20 hours — consistent) rather than cached to the wire, and a 401 minting it triggers `signOut()` so a revoked-on-iNaturalist's-side token doesn't strand the UI in a broken "signed in" state. Every network call in `INatClient` goes through `perform`/`send`, which check HTTP status explicitly (`200..<300`) before treating a response as success; `observationExists` explicitly distinguishes 404 from 200-with-empty-results. No force-unwrap on response bodies (`try?`/`guard let` throughout); the two `!` unwraps present (`request.url!`, `components.url!`) are on URLs built from static/validated components, not on network-controlled data.


> **Orchestrator note on the /tmp accumulation finding:** the filenames are derived from
> `baseName` (the WAV's own millisecond timestamp + species), so re-exporting the *same*
> recording overwrites rather than accumulates, and the failure paths do clean up after
> themselves (`INatObservation.swift:481,719,1082`). What is unbounded is one set of files
> per *distinct* recording ever exported. That makes it a slow leak rather than a fast one —
> real, but I'd rate it P2 rather than P1.


---

## D. Remotely-settable defaults (reviewed directly)

`RemoteDefaults.swift`'s header states the trap this whole scheme exists to avoid:
*"If you add a `didSet`-free write of a default anywhere, you have quietly frozen that
parameter on every install."* The re-seed paths all honour it correctly — every store has
`isSeeding`/`seeding {}` and each guards on `object(forKey:) == nil`. The **reset** paths do not.

### [P1] "Reset Settings" permanently freezes every remotely-settable parameter it touches
`SettingsView.swift:336-346` · `PulseHaptics.swift:257+` · `HeterodyneSettings.swift:106` · `SnippetExpansionSettings.swift:250` · `AudioRecorder.swift:216`

`resetAllSettings()` calls `SettingsReset.eraseUserPreferences()` — which removes the stored
keys — and then immediately calls four `reset()`/`resetToDefaults()` methods that assign to
every property **outside** `seeding {}`. Each assignment fires its persisting `didSet`, so all
the keys the erase just removed are written straight back with today's default value baked in.
From that point `reseedRemoteDefaults()`'s `object(forKey:) == nil` test fails forever for
roughly eighteen parameters — the haptic mapping, the heterodyne trim, the snippet timings, the
recording pre/post-roll and segment length — and that install can never receive a remote change
to any of them again.

Every one of these methods already has the mechanism it needs; the fix is to wrap each body in
`seeding { }`, which is exactly what `AudioRecorder.resetToDefaults`'s own doc comment describes
wanting (memory updated, storage left alone). Worth noting the reset is the *most* likely moment
for a user to end up wanting a remote correction — they reset because something was wrong.

### [P1] An inverted floor/ceiling pair passes validation and inverts or NaNs the haptics
`RemoteDefaults.swift:157-158,177-181` · `PulseHaptics.swift:560-571`

`Tunable.range` validates each parameter alone. `hapticLevelFloor` and `hapticLevelCeiling` are
both `0...1`; `hapticFreqFloorHz` and `hapticFreqCeilingHz` are both `0...200_000`;
`simplifiedBandLowHz` is `0...100_000` against `simplifiedBandHighHz`'s `1_000...192_000`.
A config that swaps a pair is accepted in full. `intensityFor` then computes
`span = levelCeiling - levelFloor` and divides by it: a swapped pair gives a negative span, so
the clamp maps faint calls to full strength and loud ones to the minimum, and an **equal** pair
gives `span == 0`, a NaN that the `min(max(t, 0), 1)` clamp does not catch (every comparison
against NaN is false, so both calls return NaN) and which then goes into a
`CHHapticEventParameter`. `sharpnessFor` has the same division with no clamp before the cast.

`buzzEnterHz`/`buzzExitHz` are the one pair that *is* cross-checked, in their `didSet`s — so the
pattern to follow already exists in the same file. The header's promise is that a bad config
"fails visibly rather than half-applying in the field"; a swapped pair is precisely a config
error that half-applies invisibly.

### [P3] A same-value config download still writes to storage
`RemoteDefaults.swift:259-262`

`adopt` computes `changed` to avoid a pointless re-seed, then writes `accepted` to `UserDefaults`
unconditionally anyway. Harmless, but the `changed` calculation implies the write was meant to be
conditional too.

---

## E. UI state, navigation and first-launch presentation

# UI state / navigation / presentation — findings

### [P0] The reconsent sheet and What's New can both fire from the same `onAppear`, and one is dropped
`OpenBat/ContentView.swift:580-588` and `OpenBat/ContentView.swift:681-686`

`ContentView`'s `.onAppear` sets `showReconsentPrompt = ConsentStore.uploadContributionEnabled && consent.needsReconsent` (line 587), then later in the same closure sets `showWhatsNew = true` when `ReleaseState.shared.shouldShowWhatsNew` (lines 681-683). Both `@State` bools can become `true` in the same synchronous call, before SwiftUI re-renders. This is exactly the class of bug the file's own comments describe fixing twice already (`pendingChangeSummary` gated on `!tourActive && !showWhatsNew`, and `showCalibrationOffer` gated on `!showWhatsNew`) — but `showReconsentPrompt` was never added to either side of that guard. Trigger: ship a build that both bumps the consent version (making `needsReconsent` true for someone who opted into contribution) and updates `CFBundleVersion` (making `shouldShowWhatsNew` true) — i.e. any ordinary release that changes the terms. The user sees only one of "Terms Updated" or "What's New" the first time they open the update; the other is silently swallowed for good (`markWhatsNewSeen`/`hasCheckedReconsent` both latch, so it never re-offers).

### [P1] `offerCalibrationIfAppropriate`'s guard omits `showReconsentPrompt` and `showNearbySpecies`
`OpenBat/ContentView.swift:1940-1955`, guard at `1945-1946`

The guard reads `!tourActive, !showWhatsNew, !showCalibrationOffer, !showMicCalibration, !menuIsOpen` — deliberately listing every "already presented" flag per its own doc comment ("Not over the guided tour, the What's New sheet, the model suggestion, or anything else already presented"). It omits `showReconsentPrompt` and `showNearbySpecies`, both real sheets that can be up at the same moment a mic route change fires this function (e.g. plugging the Griff in while the reconsent sheet from the same launch is still on screen). Trigger: a device with `needsReconsent == true` connects the Griff for the first time during the same session the reconsent sheet is showing — `showCalibrationOffer` flips true while `showReconsentPrompt` is still true, and the calibration offer is dropped silently (it never retries; `micCalSettings.recordCalibrationOffered` has already latched, so this specific mic never gets offered calibration again).

### [P2] A comparison-picker navigation write can land after the path it targets has changed
`OpenBat/ContentView.swift:1089-1102`, `replaceSpeciesPage` at `1047-1053`

`SpeciesComparePickerSheet`'s completion clears `compareBase`, then after a hardcoded 350 ms `Task.sleep` calls `replaceSpeciesPage`, which unconditionally does `path.removeLast()` on `sectionPaths[.species]` and appends the comparison destination. The comment explains the sleep is needed so the sheet's dismissal doesn't eat the navigation change, but nothing re-checks that the top of the species stack is still the same species page 350 ms later. If the user backs out of the species page (or pushes a different one) inside that window, the removeLast()/append pops whatever is now on top and replaces it with the comparison view instead of the page the comparison was started from — a stale-destination navigation write, not a crash, but a wrong screen with no back-step to the page the user actually left.

### [P2] iPhone's `advancedOnly`/simplified-view rule is not re-verified against every settings control that binds straight to a live DSP object
`OpenBat/SettingsView.swift:907-939`

"Telling calls apart" (shortest call / join gaps / wait after a call) is hidden in simplified mode via `.advancedOnly(simplifiedMode)`, and — per its own comment — deliberately *not* overridden, because overriding would silently change what gets detected. That reasoning is sound for this card specifically, but it depends entirely on the Advanced-mode switch being the only route to these three sliders now and forever; nothing enforces it structurally (no assertion, no test), so a future control added to this file that also binds directly to `pulseDetector.minConsecutiveColumns`/`maxGapMs`/`holdOffSeconds` outside the Advanced sheet would silently re-open the "no route back" hazard `SimplifiedView.swift`'s header warns about. Flagging as a maintenance risk rather than a live bug: today there is no other route to these three fields but the Advanced switch, so nothing is currently stranded.


> **Orchestrator note on the reconsent / What's New P0:** verified — both flags are set in the
> same `.onAppear` with no mutual guard, and two `.sheet` modifiers on one view means the second
> is silently dropped. But `showReconsentPrompt` is gated on
> `ConsentStore.uploadContributionEnabled`, which is `false` in the shipping build (confirmed
> independently in section C), so the collision **cannot fire in this release**. It is a loaded
> gun rather than a live one: P0 the moment contribution is switched back on, P2 today. Worth
> fixing now precisely because the condition that arms it is a one-line change made elsewhere.


---

## F. Offline review (WavPlayer) and DSP

# WavPlayer / DSP bug hunt

### [P1] Manual call-selections under ~1.4 ms silently produce no measurement

`OpenBat/WavPlayer/CallAnalysis.swift:255-263`, `OpenBat/DSP/STFTGrid.swift:89-103`, `OpenBat/WavPlayer/WavSpectrogramView.swift:1870-1902`

`CallAnalysis.analyze(pcm:...)` calls `STFTGrid.compute(pcm:scratch:dynamicRangeDB:calibrationCurve:)` with no `frameHop` argument, so it always uses the native hop of 32 samples. `compute` requires `nFrames >= 2`, i.e. `pcm.count >= windowLen + hop = 544` samples (1.42 ms at 384 kHz) — anything shorter returns `nil` and `analyze` aborts with only a debug-log line. The drag-to-select gesture in `WavSpectrogramView.selectGesture` enforces no minimum box width (`guard s1 > s0 else { return }` is the only check), so a user zoomed in on a short, fast call can easily box a span under 544 samples. `WavSpectrogramEngine.renderRawTile`/`STFTGrid.effectiveHop` already solve exactly this problem for the *picture* (shrinking the analysis hop so a narrow span still gets real columns instead of being stretched), but `CallAnalysis` never calls `effectiveHop`, so the same narrow selection that draws fine goes completely unmeasured. The user sees the Call Analysis card go blank with no explanation, indistinguishable from "the analysis doesn't work" — exactly the failure mode this codebase's own `WavPCMReader` comment says was fixed for the read path but was never carried into the STFT step here.

### [P2] Hide-silence's compressed overview can duplicate a column at every segment boundary

`OpenBat/WavPlayer/WavSpectrogramEngine.swift:414-440` (`compressedOverviewRawTile`)

Each segment's source-column range is computed independently: `c0 = floor(realStart * nCols / total)`, `c1 = round(realEnd * nCols / total)` (clamped to at least `c0+1`). Because one segment's end uses `round` and the next segment's start uses `floor`, a boundary that falls inside a single overview column can produce `c1` for segment *i* one past `c0` for segment *i+1*, so that column is copied into the compressed image twice — once as the tail of the kept region before a gap and once as the head of the one after it. It's cosmetic (a duplicated column at a gap edge in the whole-file compressed overview, not audio and not the detail-tile path used by CallAnalysis), but it does mean the compressed picture and the real column count can disagree by a column at every gap, and it silently violates the "non-overlapping, gap-free" invariant the segment list otherwise guarantees.

### [P2] A disk-read failure at a tile's first frame silently zeroes an entire column instead of using the guaranteed fallback frame

`OpenBat/DSP/STFTGrid.swift:340-353` (`streamPooledGridFromFile`, non-bulk disk path)

The doc comment claims "every bucket still gets its `bucketStart` frame at minimum" as the guarantee that no output column is ever left unfilled, but the code that backs this is just `frame += stride; continue` when the `handle.seek`/`read` at `bucketStart` fails — there is no retry and no distinction between "this frame legitimately doesn't exist" and "the guaranteed minimum frame failed to read." If that happens for every frame in a bucket (a short read right at the file's tail, or a transient I/O hiccup), `accum` for that whole column stays at its initial `-.greatestFiniteMagnitude` for all 1024 bins. Downstream, `colorize`'s per-column ceiling tracking (`WavSpectrogramEngine.swift:164-187`) happens to clamp this to `absoluteSignalFloorDB` before display, so today it only shows as one anomalous black column rather than corrupting the picture or crashing — but the guarantee the comment describes isn't actually enforced, and any future caller that trusts "every bucket has real data" (e.g. a min/mean computed directly over `accum` before colorize's clamp) would silently ingest a `-3.4e38` value.


---

## G. Concurrency escape hatches (reviewed directly)

I swept every `MainActor.assumeIsolated`, `nonisolated(unsafe)` and `@unchecked Sendable` in the
app. `assumeIsolated` **traps** rather than hops, so each site has to be genuinely on the main
actor. Seven of the eight are safe and correctly reasoned — `queue: .main` notification
observers (`PulseHaptics.swift:354,374`, `ConsentStore.swift:146`) and main-run-loop
`Timer.scheduledTimer` callbacks (`PulseHaptics.swift:656`, `SessionButtonLocator.swift:337`,
`BackgroundDetectionPump.swift:49`, `AudioEngineController.swift:686`). One is not.

### [P2] A nonisolated function that traps if anyone ever calls it off the main actor
`INatUploadAssessment.swift:179` reading `:116-119`

`INatUploadAssessment` is a `nonisolated struct`, so `assess(recording:...)` is callable from any
isolation — but `overrideLimits` is marked `@MainActor`, so reading it needs
`MainActor.assumeIsolated`, which is a trap and not a hop. Both current callers
(`RecordingViews.swift:221`, `INatObservationSheet.swift:208`) are view code on the main actor,
so it doesn't crash today. It is a landmine rather than a bug: `assess` does ledger reads and a
scoring pass, which makes "move it off the main thread" the obvious future optimisation, and the
sheet that calls it already wraps neighbouring work in `Task.detached`. The whole trap exists to
read one debug `UserDefaults` flag — dropping the `@MainActor` from `overrideLimits` removes it.


---

## H. Persistence, settings and reset

# Persistence / Settings / Feature Flags / Live Activity / Haptics — findings

### [P0] "Reset all settings" is silently undone for the entire AutoID tab the moment the sheet closes

`OpenBat/SettingsView.swift:336-346` (`resetAllSettings`), `OpenBat/SettingsView.swift:133-136` (Done button), `OpenBat/ContentView.swift:371-380` (`.sheet(... onDismiss:)`), `OpenBat/Classifier/AutoIDSettings.swift:395-399` (`loadPersisted`).

`resetAllSettings()` calls `SettingsReset.eraseUserPreferences()` (which clears `AutoIDSettings_v2`, `MapPinMinConfidence`, `MapPinMinPulseCount` from disk) and then calls `settings.loadPersisted()` to make the live `AutoIDSettings` object pick the erasure up without a relaunch. But `loadPersisted()` is guarded by `hasLoaded`, which is already `true` by the time Settings is ever opened (it's set on the app's very first `.task`), so the call is a no-op — the in-memory `perModel`, `activeModelID`, `mapPinMinConfidence` and `mapPinMinPulseCount` are left exactly as they were before the reset.

The Settings sheet is dismissed by tapping "Done" (`settings.save()` at `SettingsView.swift:134`) or by any other dismissal, because `ContentView.swift`'s `.sheet(isPresented: $showSettings, onDismiss: { autoIDSettings.save() ... })` fires `autoIDSettings.save()` unconditionally on every dismissal, including a swipe-down. Either path re-serialises the untouched, pre-reset in-memory state straight back into `UserDefaults`, overwriting the erasure that just happened — before the user ever gets to "close and reopen," which the reset's own confirmation alert asks them to do.

**What the user sees:** tap Reset all settings → the alert says "Close and reopen OpenBat to finish" → the user dismisses the sheet (there is no other way back to the app) → every AutoID setting (per-species enable/priors, per-model pass thresholds and quality gate, active model, and the two map-pin thresholds) is exactly as it was before the reset, both on screen and on disk. The developer's own comment above the `loadPersisted()` call ("an AutoIDSettings still holding the old values in memory would undo half of this on the way out") describes precisely this failure and believes it is guarded against; it is not.

### [P1] Demo-run pulse thumbnails can be orphaned on disk permanently

`OpenBat/Classifier/ClassificationStore.swift:611-651` (`addPass`), `OpenBat/Classifier/ClassificationStore.swift:395-408` (`endDemoRun`).

`addPass` writes each pulse's thumbnail JPEG to `imagesDir` unconditionally, inside the `io.async` block, before checking whether the pass is a demo pass that should be kept. Only afterwards, on the main-thread completion, does it check `if isDemo && !self.demoRun { return }` and drop the pass metadata without inserting it into `passes`. `endDemoRun()`'s cleanup sweep only deletes thumbnails belonging to passes it finds in `passes` (`demoPasses = passes.filter { $0.isDemo == true }`) — a pass that lost this race never appears there, so its already-written JPEG file(s) are never referenced by anything and never deleted. The pass's own comment ("A pass that was still being encoded when the demo ended must not slip in behind endDemoRun's sweep") shows the metadata race was noticed and handled; the matching file on disk was not. Each occurrence is small (one or a few JPEGs per straddled pass), but it is unbounded over repeated demo runs and never reclaimed — a real, if slow, storage leak with no code path that will ever clean it up.

### [P2] "Reset all settings" preserves a device-chosen debug override under a rationale that describes something else

`OpenBat/SettingsReset.swift:40-43,75-76`, `OpenBat/FeatureFlags.swift:166-176,256-259`.

`config.localFeatureOverrides` is preserved across a reset with the stated reason "What the config file said... not this user's choices at all." But `FeatureFlagStore`'s own header for `localOverrides` describes it as the opposite: "What the config menu has decided by hand for this device" — a per-device decision made through the passcode-gated debug menu, in either direction (on or off), independent of and able to contradict the remote config file. Grouping it with `config.remoteDefaults` (which genuinely is "what the file said") means a device that has toggled a feature off (or force-on) through the config menu keeps that override through "Reset all settings," so a reset install does not behave like a fresh one for whichever feature was locally overridden. Low real-world impact since the config menu is passcode-gated and not consumer-facing, but it directly contradicts the reset's stated purpose and its own doc comment's classification of what the key represents.

### [P2] Live Activity thumbnail feature (App Group) is present in entitlements only — no runtime risk, but worth noting for target-wiring hygiene

Not a defect — flagged by the brief as known-intentional (App Group declared, unused). No action needed; mentioned only to confirm it was checked and excluded.

## Settings keys vs. "Reset all settings" clearance

| Key | Store | Cleared by reset? | Notes |
|---|---|---|---|
| `AutoIDSettings_v2` | AutoIDSettings | Yes (on disk) | **But in-memory object is not reloaded — see P0 above; effectively not reset in practice.** |
| `MapPinMinConfidence` / `MapPinMinPulseCount` | AutoIDSettings | Yes (on disk) | Same P0 as above. |
| `AutoIDSettings_lastPriorCoordinate` | AutoIDSettings | Yes | Forces a fresh prior derivation on next fix — correct. |
| `AutoIDSettings_passTimeout_1.1` (migration flag) | AutoIDSettings | Yes | Re-runs a one-time migration harmlessly. |
| `haptics.*` (11 keys) | PulseHaptics | Yes | `resetToDefaults()` assigns in-memory defaults directly — works correctly, unlike AutoIDSettings. |
| `snippet.*` / heterodyne keys | SnippetExpansionSettings / HeterodyneSettings | Yes | `.reset()` assigns in-memory — works correctly. |
| Recorder keys | AudioRecorder | Yes | `.resetToDefaults()` assigns in-memory — works correctly. |
| `configMenuUnlocked` | SettingsView | Yes | Fine — re-locks the debug menu. |
| `detector.model` | SettingsView | Yes | Fine — GUANO hardware-name metadata. |
| `recording.autoRecordOnSessionStart`, `display.showNoID`, `storage.usesUbiquityContainer`(preserved), simplified-view key, etc. | Various `@AppStorage` | Yes except `storage.usesUbiquityContainer` | Correct per documented rationale (moving the library would empty it). |
| `onboarding.hasCompletedWelcome` | OnboardingState | **No** (preserved) | Intentional — re-onboarding after a settings reset would be unwelcome. |
| `tour.hasCompletedSimplified` / `tour.hasCompletedAdvanced` / `tour.hasNudged` | OnboardingState | Yes (on disk) | In-memory singleton (`OnboardingState.shared`) keeps stale values until the next real relaunch, same class of gap as AutoIDSettings but with no code path that force-rewrites the stale value back to disk before then — lower severity, not filed separately. |
| `release.lastSeenBuild`, `release.reonboardedBuild` | ReleaseState | No (preserved) | Intentional — matches doc. |
| `config.remoteDefaults` | RemoteDefaults | No (preserved) | Intentional and correctly reasoned — reset lands on the config file's numbers. |
| `config.localFeatureOverrides` | FeatureFlagStore | No (preserved) | **Misclassified — see P2 above.** |
| `config.lastSeenMaintenanceMessage`, `config.lastFetchDate` | FeatureFlagStore | No (preserved) | Fine. |
| `openbat.deviceID`, `openbat.inat.posted` | Identity / ledger | No (preserved) | Correct per doc. |
| `openbat.inat.debugIgnoreLimits` | Debug-only | Yes | Correct — debug bypass shouldn't survive a reset. |
| `MicCal.*` (prefix) | Mic calibration | No (preserved) | Correct — hardware measurement, not a preference. |

## Areas checked with no substantiated defect found

- `FeatureFlags.swift` / `RemoteDefaults.swift`: range validation, schema-version gate, and the cached/remote/compiled fallback chain are all sound; the branch-name bug already fixed (`main` vs `master`) is documented and resolved.
- `RemoteDefaultsReseed.swift` and its six `Reseedable` conformers (`PulseDetector`, `AudioRecorder`, `HeterodyneSettings`, `SnippetExpansionSettings`, `PulseHaptics`, `AutoIDSettings`): the `isSeeding` suppression and "only touch a key nobody has set" pattern is consistently applied; the deferred-until-session-end re-seed trigger (`ContentView.applyRemoteDefaultsIfSafe`) is wired correctly.
- `PulseHaptics.swift`: engine restart after Low Power Mode and after backgrounding/foregrounding is handled (`activate()`'s two observers); `resetHandler`/`stoppedHandler` correctly drop only player state, not settings; no per-pulse persistence; absence-vs-false distinction for `isEnabled` is correct and matches the `RemoteDefaults` convention.
- `LiveActivityController.swift` / `BatDetectorAttributes.swift`: no per-pulse or per-frame update path; update path is pass + 15 s heartbeat + 3 s coalescing + no-op guard, as required; staleness (`isIDStale`/`isPulseStale`/`isDetectionRecent`) is computed app-side and carried in `ContentState`, never derived from `Date()` in the widget; `start`/`end` are correctly paired across `stopDetecting`, `startDemo`, `endDemo`, `beginSessionBookkeeping`; `endOrphanedActivities()` is called once at launch.
- `ClassificationStore` delete paths (`deleteSession`, `delete(_:[PassRecord])`, `delete(_:[Recording])`, `deleteAllSessions`, `deleteNoIDRecordings`): DB row and on-disk file (WAV, thumbnail, pulse image) removal are correctly paired in every path examined; `deleteAllSessions` is deliberately routed through `deleteSession` per-session rather than clearing arrays wholesale, avoiding the orphaning hazard.
- `PassRecord` / `Recording` / `RecordingSession` Codable shapes: every field added after initial ship is `Optional`, so older persisted JSON decodes cleanly with no migration needed; the one non-optional addition (`SpeciesState.resolved`) uses a hand-written `init(from:)` that defaults it to `false` for old data — correct.


> **Orchestrator note:** I verified the reset P0 independently — `loadPersisted()`'s
> `guard !hasLoaded else { return }` (`AutoIDSettings.swift:395-399`) does make the reset's
> re-read a no-op. Note also that this section marks the `Reseedable` stores "sound"; they are,
> on the re-seed path, but their **reset** path has its own defect — see section D, which found
> that every `reset()`/`resetToDefaults()` writes outside `seeding {}` and so freezes ~18
> remotely-settable parameters. The two findings compound: the same button both fails to clear
> AutoID and over-clears (by re-writing) everything else.


---

## I. Classifier, model selection and pass aggregation

# Classifier subsystem — bug hunt findings

### [P1] The "turn AutoID on" message points at a control that no longer exists

`OpenBat/SpeciesFeedView.swift:112` (and its accessibility twin, line 124):
when `autoIDActive` is false, the species feed's empty state reads "No AutoID
model is active. Turn one on in Settings ▸ AutoID to identify species." This
fires whenever `effectiveModelID == nil` — no location fix yet, or the user is
outside every model's coverage box. But `AutoIDSettings.applyCoverage`
(`OpenBat/Classifier/AutoIDSettings.swift:319-353`) is the *only* thing that
ever sets `activeModelID` now (2026-09-08, "coverage picks the model; nobody
is asked"), and `AutoIDSettingsView.swift`'s own header comment says plainly
"**The activation control is gone**" — the radio buttons and "Use this model"
toggle were deleted. A user who reads the feed's message and taps through to
Settings ▸ AutoID finds only an explanation of why nothing is running
(`locationUnavailableSection`/`noCoverageSection`), not the switch the message
told them to use. Anyone genuinely out of coverage (travelling, or simply
outside NABat/BatDetect2's boxes) has literally no way to comply with the
instruction the app is giving them.

### [P1] A pass can blend two models' class vocabularies if the active model changes mid-pass

`PassAggregation.aggregate` (`OpenBat/Classifier/PassAggregation.swift:162-217`)
sums `rawScores`/`adjustedScores` into plain `[String: Float]` dictionaries
keyed only by species code, with no check that every pulse in the pass came
from the same model. `AutoIDSettings.applyCoverage` can retarget
`activeModelID` at any location refresh, and `ContentView.swift:854` requests
a fresh fix on every `scenePhase == .active` transition — i.e. every time the
app is foregrounded during a running session (a phone call, checking the map,
switching apps). If a fix lands mid-session near/across a coverage boundary
(or is simply a noisy/glitchy fix — GPS fixes right after backgrounding are
often degraded), `PulseDetector.activeClassifier()` starts handing out the new
model's classifier for newly-armed pulses while a pass that started under the
old model is still open (`passTimeoutSeconds` ~1.1 s). `finalizePass()` then
runs `PassAggregation.aggregate` over `passAggPulses` containing scores from
two different code spaces (e.g. NABat's 4-letter codes mixed with
BatDetect2's 6-letter codes) and picks a "winner" and margin over that mixed
pool with no indication anything was wrong. Narrow window, but nothing guards
against it.

### [P2] A pre-2026-06-29 (v1-schema) upgrade gets one live session with the old broken 2.0 s pass timeout

`OpenBat/Classifier/AutoIDSettings.swift:614-628`: the legacy-v1 migration
branch of `load()` copies `v1.passTimeoutSeconds` straight into the seeded
NABat `ModelSettings` and calls `save()`, but never calls
`migratePassTimeoutIfNeeded` (that function is only invoked from the v2
branch above it, lines 604-611). If a v1 blob still holds the superseded 2.0 s
default (the exact value Context.md §9 documents as producing "26 seconds of
four species, averaged" — a species name that changes with capture throughput
rather than the audio), this launch runs the whole session with 2.0 s still
in effect; the fix only lands on the *next* launch, once `save()` has written
a v2 blob for `migratePassTimeoutIfNeeded` to inspect. A real (if now rare)
install on the original per-model-settings schema hits the historical bug for
one full session after updating.

### [P2] `ClassifierSpectrogramEngine`'s peak scan still traps on an inverted range if anyone widens a model's frequency bounds

`OpenBat/Classifier/ClassifierSpectrogramEngine.swift:150`: `for bin in
loBin...hiBin` is a `ClosedRange`, and it will trap if `loBin > hiBin`. This
is currently unreachable only because `PulseDetector` refuses to classify
audio delivered off a model's native sample rate (Context.md §9, "Species ID
is refused off the native capture rate") — a real low delivered rate is what
would invert the range. `ModelReliability.swift` is proof this subsystem is
actively growing (new model-metadata concepts landing all the time); nothing
in `ModelDescriptor`/`ModelInputSpec` documents or asserts the invariant that
keeps this range non-empty, so a future model addition (a different
`minFreqHz`/`maxFreqHz`/native rate combination) can silently reintroduce a
crash here with no compiler or runtime signal until it fires in the field.

### [P2] `ModelReliability.reliability(for:)` ignores its own model-scoping and just indexes the NABat table

`OpenBat/Classifier/ModelReliability.swift:137-150`: `precision(for:)` and
`reliability(for:)` take a bare species code and look it up only in `nabat`,
relying entirely on the comment's claim that "the two models' code
vocabularies don't overlap" (NABat's 4-letter codes vs BatDetect2's 6-letter
ones). That's true for the two shipped models, but there is no assertion or
runtime guard enforcing it — contrast with
`tools/generate_species_presence_data.py`, which CLAUDE.md says "refuses to
run if two models use the same species code for different bats." A third
model added later with a colliding code would silently show one species'
precision figure on another species' pass/recording, with nothing to catch
it at the point of definition. `ModelReliability.table(forModel:)`
(line 121) exists and is correctly model-scoped but is never called from
anywhere in the app — the actual display path bypasses it entirely.


---

## J. Field guide, species presence and location

### [P1] A failed Wikipedia photo fetch is cached as a permanent "no photo"

`OpenBat/FieldGuide/WikipediaSpeciesImageService.swift:74, 163-176, 233-235`

`cache: [String: Photo?]` deliberately uses `.some(nil)` to mean "checked Wikipedia, no usable photo exists" so a species is never re-queried — that's the documented intent (line 68-73). But `reallyFetch` returns plain `nil` from its single catch-all `catch { return nil }` (line 233-235) for *every* failure mode: a timeout, offline device, a 5xx, a JSON decode failure from a malformed/partial body, or a 429 rate-limit (only 404 gets special-cased at line 188) — and `SpeciesImageCache.swift`'s own comments confirm Wikimedia does answer bursts of parallel requests with 429s in practice. `fetchPhoto` then unconditionally writes that `nil` into `cache[scientificName]` and persists it to disk via `saveCache()` (lines 171-174), with no distinction from a genuine "no photo" result and no TTL or retry anywhere in the file. A user who opens the guide once while offline, or during a Wikipedia hiccup, permanently loses that species' photo — every future launch, even on Wi-Fi, returns the cached `nil` instantly without ever hitting the network again. A `SpeciesGuideStore.warmImageCache()` preload burst at launch over a flaky connection could poison many entries at once, and the only recovery is reinstalling or manually deleting `WikipediaImages/cache.json`.

### [P2] Family-tint colour is not actually deterministic across launches

`OpenBat/FieldGuide/SpeciesExplorerView.swift:786-792` (`GuideSpeciesThumbnail.tint`) and `OpenBat/FieldGuide/SpeciesCollectionView.swift:441-447` (`GuideSpeciesCard.tint`)

Both compute `species.family.hashValue` and index a fixed 6-colour palette with it, under the explicit comment "Deterministic (not random) so the same family always gets the same color across launches." Swift's `String.hashValue` is seeded per-process specifically to prevent hash-flooding (true since Swift 4.2), so the hash — and the placeholder tint a species silhouette/card shows before its photo loads — actually changes every app launch, contradicting the stated intent. Cosmetic only, but present in two call sites that would need the same fix.

### [P2] LocationProvider swallows every location failure silently

`OpenBat/Location/LocationProvider.swift:190`

`func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }` is a no-op. If `requestLocation()` fails outright (no signal, airplane mode, a CoreLocation daemon error), nothing is logged, nothing retried, and `currentCoordinate` simply never updates — a `requestRegionFix()` call silently does nothing observable. Combined with `currentCoordinate` having no staleness expiry once set (only fixes older than 15 minutes are rejected *at the moment they arrive*, `maxAcceptableRegionAgeSeconds`, line 179), a session that never gets a fresh fix keeps using an arbitrarily old coordinate for the sun clock, species presence lookup, and pass tagging, with no indication to the user that the position is stale or that a fix ever failed.

### [P2] SpeciesImageCache never negatively-caches, so a dead photo URL is retried forever

`OpenBat/FieldGuide/SpeciesImageCache.swift:138-160, 200-205`

`image(for:size:)` and `preloadOne` both return/write nothing when `download`+`downscale` fail, and nothing marks the URL as known-bad. Unlike the Wikipedia service (which over-corrects the other way, see above), this cache has no negative-cache path at all: a guide entry with a permanently dead `imageURL` (typo, deleted Commons file, a 404) is re-downloaded on every row appearance, every relaunch's `warmImageCache()` preload sweep, and every detail-page view, indefinitely — wasted network and battery for a link that will never succeed, with no backoff.

### [P2] AutoIDSettings only re-derives priors/model coverage on app foreground/launch, not while a long session stays foregrounded

`OpenBat/ContentView.swift:672, 854`; `OpenBat/Location/LocationProvider.swift:106-116`

`requestRegionFix()` — the only trigger for `AutoIDSettings.refreshPriors`/`applyCoverage` — fires from `ContentView`'s init-time call and from `.onChange(of: phase)` when the scene becomes `.active`. If the app is kept in the foreground for an extended field session (screen never locks, e.g. plugged in), no new fix is ever requested, so a drive across a model-coverage boundary or a presence-grid cell boundary mid-session would not be picked up until the app is backgrounded and reopened. Low real-world impact since users are typically stationary while recording, but it is a real gap in the "moved 10 km" refresh story, which assumes fixes keep arriving.


> **Orchestrator notes on this section.**
>
> The `String.hashValue` finding checks out and is worth taking seriously: Swift seeds string
> hashing per *process*, so those family tints genuinely change on every launch, exactly against
> the comment beside them. `abs()` on the result is also a trap if the hash ever lands on
> `Int.min` — vanishingly unlikely, but free to avoid. A stable substitute is a hand-rolled
> fold over the string's UTF-8 bytes, or `SpeciesInfo`-style explicit per-family colours.
>
> This section reports `IDScoreViews.swift` as clean. Read as one file it is — the defects I
> found in it (section A) are all cross-view: what the pill *means* changes with whether
> `ModelReliability` has an entry, and whether it appears at all changes with simplified mode,
> and neither is visible without the call sites in three other files. Not a disagreement, a
> difference in what was in scope.


---

## K. Release readiness (reviewed directly)

### [P1] What's New will announce the wrong build number
`OpenBat/Resources/CHANGELOG.md:35` vs `project.pbxproj:472,516` · `ChangeLog.swift:29-32,77` · `WhatsNewSheet.swift:66`

The new changelog section is headed `## v0.9.7 (Build 242)`. `CURRENT_PROJECT_VERSION` in the
same uncommitted change went to **247**. `ChangeLog.latest` takes the first `##` section
regardless of what it says, and `WhatsNewSheet` prints `release.title` verbatim as the screen's
subtitle — so every user who installs this build opens What's New and reads a heading for a build
they don't have. Nothing malfunctions; it just looks like the wrong notes were shipped, which for
a release-notes screen is the whole of its job.

### [P1] The changelog doesn't mention the headline change in the release
`OpenBat/Resources/CHANGELOG.md`

The uncommitted work is the identification-score rework — precision shown beside confidence, the
winner-versus-runner-up chip, the two explanation popovers, the new onboarding card about what a
percentage means, and the "How we get to an ID" button for simplified view. The changelog's new
section covers the listening-settings consolidation, remote defaults and the tour, and says
nothing about any of it. This is the most user-visible change in the diff and the one most likely
to prompt "why does it say 94% now when it said 66% before".

Per `CLAUDE.md`'s propagation map this change also has downstream targets that appear untouched:
the book's onboarding section (§19) gained a card, and website `Help.md` §"Species identification"
describes what the app tells people about confidence. Worth confirming before the push — I have
not checked the two out-of-repo targets, since both live outside this working copy.

### [P3] Typo in user-facing release notes
`OpenBat/Resources/CHANGELOG.md:41` — "to improve the experieince" → "experience".


---

## L. Listening DSP, spectrogram and session export (reviewed directly)

The subsystems sections A–K never reached: `Spectrogram/` (processor, renderer, view,
shader, history buffer, mic calibration), `TimeExpansion/` and `Heterodyne/` (the live
and playback listening paths), and `SessionExport`/`SessionExportManager`.

### [P1] Every session export leaves its zip in the temporary directory forever
`SessionExport.swift:233-235` · `SessionExportManager.swift:255`

`makeShareItem` moves the coordinated read's zip to `tmp/<title>.zip` and hands the URL
back; `finish` stores it in `ready` for the share sheet. Nothing ever deletes it. The
staging directory is cleaned up (`SessionExport.swift:237`) and a *re-export of the same
session* overwrites its own zip (`removeItem(at: dest)` at line 234), so this is bounded
at one file per distinct session title — but each file is a whole session's WAVs
compressed, routinely hundreds of megabytes, where the sibling iNaturalist leak already
filed in section C is a pass segment and a few PNGs. Nothing sweeps `tmp` at launch for
these the way `RecordingUploader.purgeOrphanedDerivedCopies` does for the upload path,
and the user is never shown the space. A season of exporting one session a night is
gigabytes of invisible, unreclaimed storage.

`Classifier/DemoLogger.swift:385` and `Classifier/ClassificationLogger.swift:118` build
their diagnostic zips into `tmp` the same way and never remove them either — much smaller,
same missing sweep.

### [P2] Cancelling an export during the zip leg still opens the share sheet
`SessionExportManager.swift:109-117, 248-260`

`cancel()` sets `job = nil` and flips the cancel flag, and `makeShareItem` only polls that
flag before the copy and before compressing — the zip itself is uninterruptible, which
`cancel()`'s own comment acknowledges. So a cancel landing during compression (the longer
leg on a large session) lets the export finish and return a URL, and `finish` assigns
`ready` on `if let url` *before* it consults `wasCancelled`. The banner disappears on the
tap, the app is quiet for a minute, and then a share sheet appears for the export the user
cancelled. The check is already computed one line above; it just isn't applied to the
success branch, and the abandoned zip stays on disk per the finding above.

### [P1] "High" background removal — the shipped default — disables both of the replay path's level protections
`TimeExpansion/SnippetExpansionProcessor.swift:461-486` · `DSP/SpectralDenoise.swift` (`cleanMask`/`applyMask`)

`prepareSnippet` measures peak and background *after* denoising, and takes the background
as the median of the window's own sample magnitudes. In `.scrub` — `SnippetDenoiseMode`'s
default for the replay path, labelled "High" — rejected time-frequency cells are multiplied
by a hard 0/1 keep mask, so a window's median sample is digital zero, not a level. Two
consequences, both to constants the file documents as load-bearing:

* `background` clamps to `1e-9`, so `crestDB` is 100+ dB for any window holding any
  surviving transient at all. The 24 dB crest gate — chosen from a bimodal raw
  distribution where noise-only windows sit at 15–19 dB — can then only reject a window
  that scrubbed to *complete* silence. A window whose only content is a mask-surviving
  click or footstep passes, and the mode spends the replay deaf, which is precisely the
  cost `minCallCrestDB` exists to avoid.
* `byBackground = levelMaxBackground / background` is ~6×10⁵, so `auto` is always
  `min(byPeak, 32)`. The `maxBackground` constraint — "the whole fix for 'some replays
  are all hiss'", "this constraint, not the peak, is what makes replays sound alike" — is
  inert in the default mode. That leaves a faint residual click matched up to `targetPeak`
  or the 32× ceiling, i.e. replayed loud.

Both protections work as documented in `.off` and `.reduce`, where the background is still
a level. Measuring the crest and the background *before* the denoiser (peak may still be
measured after) restores both without changing what is heard.

### [P2] The heterodyne channel assumes the input rate is an integer multiple of 48 kHz
`Heterodyne/HeterodyneProcessor.swift:238`

`decimation = max(1, Int((fs / outputSampleRate).rounded()))`, but `outputSampleRate` is a
hard `let 48_000` and the ring is drained at that rate. The producer actually emits
`fs / decimation` samples per second, so the two agree only when `fs` is a multiple of
48 kHz. Every rate the app expects is (384 k on the Griff, 48/96/192 k elsewhere), and
`setPreferredSampleRate(384_000)` asks for one — but the rate is whatever the hardware
negotiates and nothing checks it. A 44.1 kHz USB interface gives `decimation == 1` and a
permanent 8% underfill; the drift correction in `render` clamps at ±3% and cannot close
it, so the ring runs dry, `available >= 2` fails, and the zero-fill path at the bottom of
`render` produces continuous crackle for as long as that mic is connected. The `max(1,
...)` shows the degenerate case was considered; the rate mismatch it leaves behind was not.
A cheap fix is to derive `outputSampleRate` as `fs / decimation` rather than assert it.

### [P2] A mic calibration curve is matched by name only, never by the rate it was measured at
`DSP/MicCalibrationCurve.swift:41-50` · `Spectrogram/MicCalibrationSettings.swift:101`

`apply(to:)` documents its precondition as "`binCount`/`fftSize`/`sampleRate` all equal"
and then guards only the two counts. `binCount` is 1024 for the live path at *every*
sample rate (it is `fftSize / 2`, and `fftSize` is fixed at 2048), so the guard can never
catch a rate mismatch — and `currentCurve(forMicName:)`, the only gate in front of it,
compares the mic's name. A curve measured on a mic that once negotiated 192 kHz and later
applied at 384 kHz is a per-bin correction applied at half the frequencies it was measured
at: a silently wrong ±12 dB shape across the whole band, on the realtime audio thread,
flowing into both the display column and the trigger scan. This is exactly the failure the
`micName` check was added to prevent, and the field that would catch it (`sampleRate`) is
already stored in the curve.

### [P2] Scroll-back has no end stop, so a flick can strand the view in empty history
`Spectrogram/SpectrogramView.swift:166, 176`

Both the drag and its momentum coast clamp `scrollColumnOffset` at zero and nothing else.
Past the 60 s history the renderer's `rowMajorSlice` zeroes every column that isn't there
(`HistoryBuffer.swift:111-115`), so the spectrogram goes flat black with no indication that
this is the end of the buffer rather than a stall or a dead mic. A hard flick can leave the
offset tens of thousands of columns past anything real, and dragging back has to cover all
of it; the only quick way out is the "Return to live" button — which is the control the
mode's own doc comment describes as one you only find *because* you are already lost.
Clamping the offset to `min(totalWritten, capacity) - visibleColumns` would make the
history feel like it has an edge.

### [P2] `SnippetExpansionProcessor.reset()` has no handshake with its preparation worker
`TimeExpansion/SnippetExpansionProcessor.swift:493-532` (against `workerLoop`, 409-429)

`reset` documents its contract as "call before installing the tap — no concurrent
`process`/`render` at this point", which is true of the two realtime threads and says
nothing about the third. The preparation worker can be inside `prepareSnippet` when a
listen-mode change stops and restarts capture, and `reset` then re-initialises `ring` and
`prepared` and zeroes `replayCount` underneath it. Today the damage is contained: the
worker's `compareExchange` on `Phase.preparing` fails after a `reset` has stored
`Phase.recording`, so the torn snippet is dropped rather than played. What is not contained
is the branch above it — `if needed > ringCapacity` *deallocates both buffers* while the
worker may be reading them. That branch is unreachable only because the initial capacity is
sized for 384 kHz and no supported input exceeds it; a higher-rate mic turns a latent race
into a use-after-free on a background thread. A `stopping`-style flag or a semaphore the
way `deinit` already does it would settle both.

### [P3] The live ring texture wraps vertically, so the top pixel row blends Nyquist with the DC bin
`Spectrogram/Spectrogram.metal:123` · `SpectrogramProcessor.swift:573-584`

`ringSampler` is `address::repeat` on both axes, so at `bandHigh == 1` the topmost row
samples between the last bin and — wrapped — row 0, which `vDSP_zvabs` on the packed
real-FFT output makes `sqrt(DC² + Nyquist²)`: a bin that means neither thing, and one this
hardware is known to have a DC offset on. The seek texture uses `clamp_to_edge` and does
not do this, so the live view and the scrolled-back view disagree along their top edge. The
display ceiling was already fixed to skip bin 0 for this exact reason; the sampler wasn't.
One row, but free to fix — the vertical axis wants clamping on both textures.

### [P3] The history buffer is sized at a hardcoded 1500 columns/second
`Spectrogram/SpectrogramRenderer.swift:177`

`HistoryBuffer(capacity: Int(historySeconds * 1500))` bakes in the Griff's 384 kHz / hop
256, while `columnsPerSecond` beside it is computed from the real rate. On a 48 kHz input
that is 187 columns/second into a buffer sized for 1500, so "60 s of history" is really
eight minutes — harmless in itself, but it means the documented memory figures and the
scroll extent are both wrong for every non-Griff input, and the constant is not derived
from the one place the rate is known.

### [P3] Two recordings sharing a filename silently lose one from the export
`SessionExport.swift:197-206`

The staged copy is named `row.wavURL.lastPathComponent`, and a `copyItem` onto an existing
name throws, which `guard ... else { continue }` swallows. The second recording is then
absent from the zip *and* from `includedNames`, so its CSV row points at no file, with no
error anywhere. Generated names carry a millisecond timestamp so this needs imported
recordings (or a merge across devices) to collide — but when it happens the export is
quietly incomplete, which is the one thing an evidence export must not be.
