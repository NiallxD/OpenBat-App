# OpenBat Codebase Function Reference

Auto-generated reference of the major functions/methods across the OpenBat codebase, grouped by subsystem. Intended as a learning aid, not exhaustive API docs — trivial boilerplate (plain stored properties, pass-through inits) is skipped in favor of things that explain *why* the code exists.

Generated 2026-07-26 against branch `autoidv2`.

## Table of contents

1. [App shell & root-level views](#app-shell--root-level-views)
2. [Audio / DSP / Heterodyne / Time Expansion](#audio--dsp--heterodyne--time-expansion)
3. [Spectrogram (live Metal pipeline)](#spectrogram-live-metal-pipeline)
4. [Classifier (pulse detection & species ID)](#classifier-pulse-detection--species-id)
5. [Field Guide (species browser & range maps)](#field-guide-species-browser--range-maps)
6. [WavPlayer (recorded-file review & analysis)](#wavplayer-recorded-file-review--analysis)
7. [Upload / Consent / Location / Onboarding](#upload--consent--location--onboarding)
8. [Tests & backend Worker](#tests--backend-worker)

---

## App shell & root-level views

### AppInfoView.swift
Info sheet describing what OpenBat does, plus a guided spotlight tour that dims the screen and cuts a hole over live controls one at a time.

- `TourID` — stable enum of every control the tour can spotlight (panes, buttons, menus), tagged on both portrait and landscape variants of each control.
- `TourTargetKey` (PreferenceKey) — collects `[TourID: Anchor<CGRect>]` bounds from tagged controls, merging (not replacing) across nested views.
- `View.tourTarget(_:)` — tags a control for the tour using `transformAnchorPreference` rather than `anchorPreference`, specifically so anchors from nested/child views aren't dropped when a parent pane is also tagged.
- `TourScript.steps` — the ordered script of `TourStep`s (target, symbol, title, detail) walking the screen top-to-bottom.
- `AppInfoView.body` — presents the "About OpenBat" sheet (what it does, origin story, features, getting-started, attribution) with a "Take the guided tour" button.
- `AppInfoView.appIcon` / `appIconImage` — resolves the real app icon UIImage from Info.plist's `CFBundleIconFiles` (no reliable fixed asset name) and masks it to a rounded rect, falling back to a bundled bat glyph.
- `DataModelSourcesView` — shared attribution list (models from `ModelRegistry.all` plus fixed GBIF/Wikipedia entries) reused by both the info sheet and the species field guide's credits.
- `TourOverlay.body` — full-screen dim + spotlight cutout + caption card driven by the current step index; uses a custom `Equatable` conformance so SwiftUI can skip re-diffing it against the detector UI's constant relayout churn.
- `TourOverlay.captionLayer` — places the caption card above/below the spotlighted control depending on which half of the screen it's in, centred when there's no target.
- `TourOverlay.advance()` — steps to the next tour step or calls `finish()` on the last step.
- `SpotlightShape.path(in:)` — builds a full-rect path with an animatable rounded-rect hole, filled with an even-odd rule to dim everything except the hole.

### AutoIDSettingsView.swift
AutoID tab of Settings: lists available classifier models with single-select activation, and location-based prior warnings/suggestions.

- `AutoIDSettingsView.body` — Form combining location-status sections with a list of all `ModelRegistry.all` models.
- `locationUnavailableSection` — warns that species priors are unnormalized/neutral until a GPS fix lets GBIF narrow them, shown whenever there's no current coordinate.
- `locationSuggestionSection` — suggests activating whichever model covers the user's current coordinate (via `ModelRegistry.suggestedModel`), or says none does.
- `modelRow(_:)` — one model's row: a radio-style circle button that single-selects/deselects it as the active model, plus a `NavigationLink` into `ModelDetailView` to configure it.

### BatSwarmEasterEgg.swift
Hidden easter egg triggered by rapid-tapping the footer version text: a swarm of animated bat glyphs bursts from that spot across the screen.

- `VersionFooterAnchorKey` (PreferenceKey) — publishes the footer text's on-screen bounds so the swarm knows where to originate, same anchor-preference technique as the guided tour.
- `BatFlight.randomSwarm(count:)` — generates `count` bats spread evenly (with jitter) across an upward cone rather than a full radial burst, so the swarm reads as directional.
- `BatSwarmOverlay.body` — full-screen, non-interactive `TimelineView` animating each bat's position from `origin` using an ease-in outward travel, perpendicular sinusoidal wobble, and a squash-based wing "flap".
- `BatSwarmOverlay.batView(_:elapsed:travelUnit:)` — computes one bat's current position/opacity/scale at a given elapsed time, fading in near the origin and out near the end of its flight.

### ContentView.swift
The app's main detector screen: adaptive stats/pulse/spectrogram panels plus the transport bar, wiring together audio capture, pulse detection, recording, classification, and location.

- `ContentView.body` — assembles the NavigationStack, toolbar menus, all sheets (Diagnostics, Settings, Info, reconsent, location-change summary), and the many `.onChange`/`.onAppear` side effects that wire the audio/pulse/recorder/location pipeline together.
- `detectorLayout` — picks portrait vs. landscape vs. iPad-landscape layout based on size class and device idiom.
- `portraitLayout` / `landscapeLayout` / `ipadLandscapeLayout` — the three concrete panel arrangements (stacked vs. three-column vs. stacked-with-species-sidebar).
- `panel(_:tour:trailing:content:)` — shared scaffold building one card (header + body) used by all four pulse/spectrogram panel variants, so they only differ in title/trailing/content/tour target.
- `spectrogramPanelContent` / `pulsePanelContent` — keep `SpectrogramView`/`PulseZoomView` permanently mounted and overlay the Species ID feed on top instead of branching them out of the tree, so their live Metal/state isn't torn down when toggled.
- `applyBand()` — pushes the current frequency-band selection into the processor, heterodyne, and time-expansion engines.
- `startDetecting(newSession:)` / `stopDetecting()` — begins/ends a detecting run, optionally starting a logged Session (GPS track, session ID threaded through detector/recorder/location) vs. a bare "Listening" run.
- `toggleRecording()` — arms/disarms the triggered WAV recorder.
- `nyquist` — computed Nyquist frequency from the active sample rate, used to bound the frequency axis and band presets.
- `menuIsOpen` — true while any full-screen sheet is up, used to pause the spectrogram's live Metal render loop so it doesn't compete with the sheet's own gestures.
- `registerVersionTap()` — counts rapid taps on the footer version text within a rolling window; 10 taps triggers the bat-swarm easter egg.
- `flourishBatSwarmHaptics()` — fires a ramping light→heavy haptic volley timed to the swarm's staggered emergence, ending in a success notification.
- `isBatRange` / `batRangeButton` — one-tap toggle snapping the frequency band to the 15–90 kHz "bat range" preset.
- `RecordButton` / `RecordButtonCompact` (top-level structs) — standalone views isolating `recorder.isWriting`'s high-frequency churn so it doesn't invalidate all of `ContentView.body`.

### DeleteAllRecordingsConfirmationView.swift
Type-to-confirm gate in front of `ClassificationStore.deleteAllRecordings()` for the irreversible, local-only bulk delete of every recording.

- `DeleteAllRecordingsConfirmationView.body` — Form requiring the user to type the literal word "DELETE" before the destructive "Delete Everything" button is enabled; calls `classStore.deleteAllRecordings()` then `onFinished()` and dismisses.

### DiagnosticsView.swift
Sheet showing microphone/audio-capture diagnostics (input device, sample rates, level meter) and the classifier CSV log.

- `DiagnosticsView.body` — assembles status line, diagnostics card, level meter, and log section, all as separate leaf views to isolate the ~15 Hz `audio.diagnostics` churn from the sheet's own toolbar.
- `logSection` / `logFileSize()` — shows the classifier CSV's file size, with Share (via `ShareLink`) and Clear actions against `ClassificationLogger.shared`.
- `DiagnosticsCard.body` — renders input name/UID, the sanitized-for-contribution hardware name, session/capture/written sample rates (color-coded green/orange for full vs. clamped rate), channel count, and buffer count.
- `DiagnosticsLevelMeter.body` — a `ProgressView`-based dBFS input-level bar driven by `audio.diagnostics.currentLevelDB`.

### LazyDestination.swift
Utility wrapper that defers building an expensive `NavigationLink` destination until it is actually pushed, instead of when the link itself is constructed.

- `LazyDestination.init(_:)` / `body` — stores the destination-building closure and only invokes it when `body` is evaluated (i.e., on push), avoiding the cost (e.g. `WavPlayerView`'s ~15 MB PCM ring buffer allocation) of constructing every row's destination up front.

### LiveStatusViews.swift
Standalone leaf views for the always-on-screen status indicators (heterodyne tuning pill, mic status, session status/timer, feedback warning, amplitude meters) — split out of ContentView because their backing properties update at ~15 Hz.

- `TunedPillView.body` / `tuneGesture` — draggable pill showing/adjusting the heterodyne local-oscillator frequency; dragging manually tunes it, releasing without a drag re-enables auto-tune.
- `SessionStatusPillView.body` — small "Off"/"Listening"/"Session" indicator derived from `audio.isRunning` and whether a session is active.
- `SessionTimerPill.body` — elapsed-time readout for the running session/listening period, using its own `TimelineView(.periodic(from:by:))` so the once-a-second tick doesn't touch `ContentView.body`; `tourDemo` fakes a running clock during the guided tour.
- `SpeakerFeedbackWarningPill.body` — warns (with an explainer popover) when heterodyne/time-expansion audio is playing out the phone speaker, since the mic can pick that playback back up as a spurious call.
- `MicStatusPill.body` / `explainer(...)` — shows USB-mic connection state and delivered sample rate, flashing red if iOS clamps below the required 384 kHz, with a tap-to-explain popover.
- `PeakHoldTracker.update(db:)` — updates a 0–1 peak-hold position for the VU meter: jumps up to a new peak immediately, decays gradually after 0.8s of no new peak.
- `AmplitudeMeterView.body` / `VerticalAmplitudeMeterView.body` — horizontal/vertical segmented level meters colored from the active display palette, with a falling peak-hold dot.

### LocationChangeSummaryView.swift
One-time sheet shown after a large-enough location move, summarizing what changed: a newly-suggested model and/or shifted species priors.

- `LocationChangeSummaryView.body` — Form with sections for a recommended model (with a one-tap "Use" button), newly-enabled species, and newly-disabled species, all driven by `AutoIDSettings.PriorRefreshSummary`.

### ModelDetailView.swift
Per-model configuration screen: activation toggle, pass-detection thresholds, pulse quality gate, and the grouped species list with enable toggles and prior sliders.

- `ModelDetailView.body` — Form combining metadata, active toggle, pass-detection settings, quality gate, per-group species sections, and a reset-to-defaults action.
- `activeSection` — toggle binding that sets/clears `settings.activeModelID`, since only one model can classify at a time.
- `passSection` — sliders/steppers for pass timeout, minimum pulse count, and minimum confidence.
- `qualityGateSection` — toggle plus SNR/amplitude thresholds for rejecting faint or clipped pulses before classification.
- `speciesSections` — one Form section per species group, each with a group-level "Enable/Disable all" button and per-species `SpeciesRow`s.
- `bind(_:)` — generic helper producing a write-through `Binding` to one field of the current model's `AutoIDSettings.ModelSettings`.
- `enabledBinding(for:)` / `priorBinding(for:)` — per-species bindings that read/write into `settings.perModel[model.id].species[code]`, creating a default entry if absent.
- `allEnabled(_:)` / `setGroup(_:enabled:)` — checks/sets every species in a group at once for the group header's bulk toggle button.
- `SpeciesRow.body` — one species's checkbox, code/common-name label, and (when enabled) a prior-weight slider.

### OpenBatApp.swift
App entry point: sets up global UIKit navigation-bar appearance, runs one-time storage migration, and gates the root view behind onboarding.

- `OpenBatApp.init()` — configures the navigation bar appearance, registers default UserDefaults (iCloud storage on by default), and synchronously runs `CloudStorage.applyPendingStorageMigration()` before any store is constructed so nothing gets built against a root that's about to move.
- `configureNavigationBarAppearance()` — forces a flat opaque black nav bar with no glass/blur material or separator, across all four UIKit appearance variants, since SwiftUI's own `.toolbarBackground` API can't fully remove Liquid Glass's translucent material.
- `RootView.body` — shows `OnboardingView` until `OnboardingState.shared.hasCompletedWelcome`, then `ContentView`; kept as its own `View` (not inline in the Scene closure) so `ContentView`'s expensive `@State` initializer only re-runs when this view's identity changes, not on every `App.body` re-evaluation. Also forces `.dark` color scheme app-wide.

### PanelCard.swift
Shared card chrome (hairline-bordered vs. filled-material) used across the Detector, WAV player, and other screens for visual consistency.

- `View.panelCard(cornerRadius:)` — transparent rounded card with a thin hairline border, the "structural" grouping look.
- `View.filledPanelCard(cornerRadius:)` — filled `.ultraThinMaterial` rounded card, the "readout" look for text-heavy numeric panels.
- `PanelTitle.body` — reusable small-caps section-title row with an optional trailing control, matching ContentView's private `panelHeader`.

### PulseStatsViews.swift
Leaf views rendering the last-detected-pulse stat readouts (peak freq, bandwidth, duration, rate, pulse count, species) — extracted from ContentView because these values update on nearly every pulse.

- `StatCell.body` — one labelled stat readout (title/value/unit), used by both the row and column layouts.
- `SpeciesStatCell.body` — last-ID readout that reddens once stale (`staleIDSeconds`), using its own 1 Hz `TimelineView` so aging happens without needing a new pulse to redraw.
- `PulseStatsRow.body` / `PulseStatsColumn.body` — horizontal (portrait) / vertical (landscape sidebar) arrangements of the stat cells, both wrapped in a `TimelineView` so stats age out to "–" after `staleIDSeconds` of inactivity.
- `PulseStatValues.init(_:now:)` — computes the display strings for peak frequency, bandwidth, duration, and rate, blanking them to "–" once the last detection is stale.
- `staleIDSeconds` — shared 30-second threshold after which an ID/capture is considered stale across stat cells, the species feed, and the pulse stats.

### PulseZoomView.swift
Photos-app-style pinch-to-zoom and drag-to-pan view over the rendered last-detected-pulse image, with frequency-axis labels and a duration readout.

- `PulseZoomView.body` — hosts `pulseZoomContent` inside a `GeometryReader`, rebuilding the log-frequency-warped image on new pulses or toggle changes.
- `rebuildWarp()` — recomputes `warpedImage` via `LogFrequencyWarp.warp` when log-frequency display is on, cached so it isn't redone on every pinch/pan frame.
- `pulseZoomContent(geo:)` — composes the scaled/offset pulse image, grid overlay, frequency axis, and duration label; resets zoom/pan to the centered default whenever a new pulse arrives.
- `axisZoomGeometry(leftFrac:rightFrac:)` — given where the "tight" default window sits within the wider rendered content, returns the scale that exactly fills the frame with that window (the reference "1×" for pinch).
- `centeringOffset(midFrac:scale:)` — solves for the `.offset()` fraction that centers a given content point on screen at a given scale.
- `clampOffsetFrac(_:scale:)` — bounds a pan offset so the visible window can never scroll past the rendered content's edges.
- `pulseZoomPanGesture(geoSize:scaleX:scaleY:)` — combined `MagnificationGesture` + `DragGesture`; the magnification handler re-derives the pan offset each frame so the on-screen zoom center stays fixed as scale changes.
- `visibleVRange` / `visiblePulseFreqRange` / `tickFreqValues(count:)` — invert the current screen-space zoom/pan back into frequency values so the on-screen axis labels always match what's actually visible.

### RecordingViews.swift
UI for `Recording` (the WAV-backed bout unit) — row, detail screen, and shared small components (confidence badge, complex-species callouts, score bars) reused across the Sessions/Playback lists.

- `RecordingRow.body` / `uploadBadge` — row summarizing a recording (thumbnail, species, duration/pulse count/time), with a badge reflecting upload status (uploaded/uploading/eligible-to-upload/rejected/not-contributing) that also acts as the upload trigger button.
- `meetsUploadCriteriaNow` — re-checks live upload eligibility (consent, species, confidence, duration) for recordings saved before eligibility gating existed or before consent changed.
- `RecordingDetailView.body` / `recordingPasses` — whole-recording spectrogram plus every classified pass whose pulses fall inside the recording's time span, with a NoID visibility filter shared via `@AppStorage`.
- `SessionSpeciesSummary.body` / `counts` — bar-chart tally of species IDs across a whole session, excluding NOISE/NoID passes.
- `ConfidenceBadge.body` — colored percentage pill (green/yellow/orange by confidence threshold).
- `ComplexIndicator.body` — small amber pill flagging a species-complex ID, naming the close alternative when the ambiguity is "active".
- `ComplexCallout.body` — expanded explanation of a species complex and its alternative, with per-pass scores, for the pass detail screen.
- `PulseImagePlot.body` — stored pulse thumbnail with labelled frequency/time axes when crop bounds are known, falling back to the bare image for older records.

### SessionsView.swift
The Sessions area: list of field outings with GPS/map/species detail, plus the flat "Just Listening" recordings log; shared pass/pulse detail views used app-wide.

- `SessionsView.body` — segmented Sessions/Recordings picker over `sessionsContent`/`listeningContent`, with a NoID-filter toolbar toggle (Recordings tab only) and a delete-confirmation dialog for swiped-away sessions.
- `sessionsContent` / `listeningContent` — day-grouped lists of sessions / listening recordings, each with empty-state messaging and swipe-to-delete.
- `SessionRow.body` / `dominantSpecies(_:)` — one session's row: map thumbnail, title, time range, ID count and top species (excluding NOISE/NoID), and a GPS badge.
- `SessionMapThumbnail.body` — small non-interactive map preview of a session's GPS track for list rows.
- `fittedRegion(for:)` — computes an `MKCoordinateRegion` that fits a set of coordinates, falling back to a fixed placeholder region when empty.
- `SessionDetailView.body` — one outing's map (course + species pins), notes, species summary, and its list of recordings; `mappablePasses` filters to only passes clearing the confidence/pulse-count map-pin gates.
- `SessionMap.body` — renders the GPS polyline plus a marker per pinned pass.
- `groupPassesByDay` / `groupRecordingsByDay` / `groupSessionsByDay` / `dayTitle(_:)` — shared day-bucketing helpers (Today/Yesterday/date) used by all three list views.
- `PassRow.body` / `representativePulse` — one classified pass's row (thumbnail from its highest-confidence pulse, species, confidence badge, complex indicator).
- `PassDetailView.body` — full detail for one pass: species/confidence/runner-up/complex callout plus every constituent pulse via `PulseDetailRow`; also presented as a sheet from the live species feed.
- `PulseDetailRow.body` — one pulse's spectrogram plot, species/confidence, peak-freq/duration stats, and top alternative-species score bars.

### SettingsView.swift
Tabbed settings screen (AutoID / Audio / Location / Recordings / Privacy) hosting most of the app's tunable parameters.

- `SettingsView.body` — segmented picker switching between the five tabs; "Done" persists `settings.save()` and dismisses.
- `recordingsTab` — iCloud storage toggle (with pending-migration/failure/fallback status callouts) and three destructive bulk-delete actions (all, NoID, low-confidence), each behind a confirmation dialog or sheet.
- `participationBinding` — asymmetric binding for the community-science contribution toggle: turning ON opens the full consent sheet (informed consent required), turning OFF revokes immediately with no extra friction.
- `privacyTab` — contribution toggle (with reconsent-needed and awaiting-server-confirmation banners), device ID display/copy, and "Erase My Consent Record" flow.
- `audioTab` / `rteSections` / `pulseSections` / `recordingSections` — merged former RTE/Pulse/Recording tabs: sliders and steppers for time-expansion tuning, pulse-detector trigger mode/thresholds/noise-rejection, and recording bout/pre-roll/post-roll/thumbnail settings.
- `locationTab` — sliders/stepper for the minimum confidence and pulse count required for a session ID to drop a map pin.

### SpeciesFeedView.swift
Merlin Sound ID-style live feed: one row per recently-detected species, newest on top, swapped in for the spectrogram or pulse-zoom panel via a Settings toggle.

- `SpeciesFeedView.body` / `entries` — pulls deduped-by-species passes from `store.speciesFeed(sessionID:since:)` and renders them in an animated `LazyVStack`, or an empty state.
- `emptyMessage` — explains why the feed is empty: no AutoID model active, run not started yet, or genuinely nothing detected.
- `SpeciesFeedRow.body` — one feed row, using its own 1 Hz `TimelineView` so the "Xs ago" timestamp and stale-dimming update without new detections; tapping opens `PassDetailView` as a sheet.
- `SpeciesFeedRow.timeAgo(_:now:)` — plain seconds/minutes/hours/days relative-time formatter, chosen over `RelativeDateTimeFormatter` because it reads oddly for sub-minute deltas.

### View+FlatTopScrollEdge.swift
Small View extension removing iOS 26 Liquid Glass's scroll-edge scrim above scrollable content, since this app's all-black screens have nothing worth blending under the nav bar.

- `View.flatTopScrollEdge()` — calls `scrollEdgeEffectHidden(true, for: .top)` on iOS 26+, no-op otherwise, so lists/maps meeting the nav bar don't paint an extra grey scrim over the app's forced-flat-black bar.

---

## Audio / DSP / Heterodyne / Time Expansion

### OpenBat/Audio/AudioDiagnostics.swift
Value types that snapshot the current capture state (sample rate, input port, level) to prove the app is actually receiving the mic's native ultrasonic sample rate rather than a silently downsampled stream.
- `AudioDiagnostics.isNativeRate` — computed property flagging whether the delivered rate is meaningfully above the 48 kHz system-mixer ceiling (>60 kHz), the pass/fail gate for the whole diagnostics feature.
- `AudioLevel.rmsDB(of:)` — computes RMS level in dBFS of a buffer's first channel via `vDSP_rmsqv`, cheap enough to run on every realtime capture callback at 384 kHz.
- `AudioLevel.normalized(_:)` — maps a dBFS value into 0...1 for progress-bar/meter UI.

### OpenBat/Audio/AudioEngineController.swift
`@MainActor @Observable` class that owns the `AVAudioSession`/`AVAudioEngine`, captures the Griff mic's stream, and routes it to diagnostics, listening DSPs (heterodyne/time-expansion), and any subscribed buffer sinks.
- `activate()` — one-time, idempotent setup of idle mic monitoring; must be called from a view's `.task`, never an initializer, to avoid leaking timers/observers across SwiftUI's repeated `@State` init evaluations.
- `prepareInputMonitoring()` — sets a record-capable session category up front (without activating it) so the mic-connection pill works before first `start()`, and starts a 2s poll timer to detect plug/unplug while idle (route-change notifications only fire while the session is active).
- `start()` — requests mic permission, configures the session, starts the engine, and begins the stats timer; reports native vs clamped sample rate in `status`.
- `stop()` — tears down the tap/engine, deactivates the session off-main (tracked via `pendingDeactivation` to avoid racing a following reactivation), and resets the level meter to silence.
- `flushStats()` — copies audio-thread-accumulated stats (buffer count, level, actual sample rate/channels) into the `@Observable diagnostics` struct at a throttled 15 Hz so the UI thread isn't flooded by ~90/s tap callbacks.
- `syncSlowDiagnostics()` — equality-guarded mirror of slow-changing diagnostics fields into standalone `@Observable` properties, avoiding needless view invalidation of e.g. toolbar Menus on every stats tick.
- `configureSession()` — pushes `AVAudioSession` category/rate/buffer-duration setup onto a detached task since these synchronous system calls can block hundreds of ms, freezing the UI if run on the main actor; picks `.playAndRecord` when listening is active, else `.record`, and prefers the USB (Griff) input.
- `updateInputDiagnostics()` — reads the current route's input/output ports to populate `diagnostics` (name, UID, USB-ness, speaker-output warning) from the session's live state.
- `startEngine()` — builds a fresh `AVAudioEngine` each start, installs the input tap that feeds the buffer sink, active listening processor, and stats accumulator, and attaches the listen-mode output node if needed.
- `attachListenOutput()` — attaches an `AVAudioSourceNode` that pulls the active listen processor's rendered 48 kHz audio to the speaker via the main mixer.
- `setListenMode(_:)` — switches heterodyne/time-expansion/off, resetting tuning state, and restarts a running capture since the session category and engine graph both need to change.
- `notifyPulseDetected(frequency:)` — snaps or slews the heterodyne LO to a newly detected pulse's frequency immediately (rather than waiting on the stats timer) and opens the squelch gate, fixing silent calls when species shift or calls are too short for the timer to catch.
- `setManualTune(frequency:)` / `enableAutoTune()` — switch between user-driven manual LO tuning (gate always open) and automatic tracking of the detected call.
- `updateAutoTune()` — runs at ~15 Hz to slew the LO toward the currently detected peak frequency and manage the squelch gate's hold-then-close behavior between calls.
- `registerForNotifications()` — subscribes to route-change and interruption notifications, extracting Sendable values before hopping to a `Task` to satisfy Swift 6 concurrency rules.
- `handleRouteChange(_:)` — rebinds/restarts capture only on device add/remove (Griff plug/unplug), ignoring other route-change reasons to avoid a restart storm when heterodyne output itself triggers a route change.
- `handleInterruption(_:optionsRaw:)` — stops stats/marks not-running on interruption begin, and auto-resumes on end only when iOS signals `.shouldResume`.

### OpenBat/Audio/AudioRecorder.swift
`nonisolated @Observable` class implementing the triggered, pulse-gated full-spectrum WAV recorder with pre/post-roll, GUANO metadata embedding, and species-based auto-naming.
- `append(_:)` — realtime-audio-thread entry point; copies samples off the tap and hands them to the recorder's serial queue for all real work.
- `setActiveSession(id:startDate:label:)` — routes subsequent recordings into a session's date-stamped folder (or the "Listening" bucket) and tags the GUANO `OpenBat|Session` field.
- `addClassifiedPulse(result:date:)` — buffers per-pulse classification scores (queue-local, trimmed to a bounded window) so segment close can aggregate them into a species call.
- `setActiveModel(id:)` / `setPassGates(minConfidence:minPulseCount:)` — push the active AutoID model and its user-tunable pass gates so the recorder's own NoID/NOISE decision matches the in-app pass log.
- `setArmed(_:)` — toggles armed state; disarming force-closes any open segment and clears the pre-roll buffer.
- `setPulseActive(_:)` — drives the trigger from `PulseDetector.isInPulse`: starts a new segment on rising edge (if armed) and resets the post-roll countdown.
- `handle(_:sampleRate:)` — queue-local per-buffer dispatcher: rolls a pre-trigger buffer while idle, else writes samples, tracks post-roll expiry to close the segment, and enforces `maxSegmentSeconds` safety cap by rotating files.
- `startSegment()` — opens a new WAV file with a placeholder header, prepends any rolled pre-roll audio, and computes `segmentStartDate` as the true first-sample timestamp (not the trigger moment) so downstream time-window matching (e.g. pass aggregation) stays accurate.
- `closeSegment()` — discards zero-byte segments, otherwise runs `speciesAutoID` and either keeps (renames+finalizes) or discards NOISE-classified segments.
- `closeAndKeep(handle:url:outcome:)` — appends the GUANO chunk, patches RIFF/data chunk sizes, renames the file to its final `<stamp>_<SPECIES>.wav` form, renders its spectrogram, and reports a `RecordingReport` back via `onRecordingSaved`.
- `write(_:)` — vectorized (vDSP) Float32→16-bit PCM conversion and file append; reuses scratch buffers to avoid allocation on the recorder queue.
- `makeGuanoChunk(filename:outcome:)` — assembles the GUANO metadata fields (device Make/Model, timestamp, samplerate, location, species/confidence/pulse-count, app version) for the segment being closed.
- `speciesAutoID(segmentStart:segmentEnd:)` — aggregates all pulses classified within the segment's time span via `PassAggregation`, gated by the active model's NoID/NOISE thresholds, returning `.species`/`.noID`/`.noise`; bounds the window from both ends so straddling segments (pre-roll > post-roll) can't double-count pulses.
- `makeURL()` — builds the working file path under the active session's folder or the dated "Listening" folder.

### OpenBat/Audio/CloudStorage.swift
Resolves and migrates where the app's recordings/library actually live on disk — an iCloud ubiquity container by default, falling back to local Documents, with the chosen root persisted so it never silently changes mid-life of the library.
- `baseDirectory` — lazily-resolved static root: honors a previously recorded root choice first (never auto-upgrades local→iCloud later), otherwise detects an existing local library from a pre-iCloud build and stays local, otherwise honors the user's `keepInICloudKey` preference on first launch and records the outcome.
- `applyPendingStorageMigration()` — moves the entire library between local and iCloud roots when the user's preference no longer matches reality; all-or-nothing (rolls back partial moves on failure) and refuses to move out of iCloud while any files are still undownloaded placeholders (to avoid destroying the only copy).
- `undownloadedFiles(under:)` — walks a root's file tree flagging any file whose `ubiquitousItemDownloadingStatus` is `.notDownloaded`, used to gate a safe out-of-iCloud migration.
- `hasExistingLibrary(under:)` — detects whether a root already contains this app's `Classifications`/`Recordings` directories, the marker that an earlier build settled there.
- `ensureDownloaded(_:)` — fire-and-forget nudge to start downloading an iCloud placeholder file before reading it (playback, spectrogram render, GUANO parse all read files repeatedly, so a missed race isn't fatal).

### OpenBat/Audio/GuanoMetadata.swift
Builds and parses the `guan` RIFF chunk implementing the GUANO bat-acoustics metadata standard, embedded manually in WAV files since `AudioRecorder` writes WAVs by hand to preserve the 384 kHz rate.
- `Field` — one `Key: Value` metadata line; `tightColon` omits the space after the colon for fields (like `Loc Position`) where some downstream tools misparse a leading space.
- `chunk(fields:)` — serializes fields into the `guan` FOURCC + little-endian size + UTF-8 text + even-byte pad RIFF chunk.
- `read(from:)` — reads the trailing `guan` chunk back out of a WAV written by `AudioRecorder`, returning a key→value dictionary; used by `RecordingMigration` to backfill `Recording` entries for pre-existing WAVs.

### OpenBat/Audio/PlaybackEngine.swift
Plays back a saved Recording WAV through the same listening DSPs (heterodyne/time-expansion) the live Detector uses, split into a `@MainActor` UI-facing `PlaybackEngine` and a `nonisolated` `PlaybackDriver` that paces PCM to real time on its own thread.
- `PlaybackDriver.startEngineIfNeeded()` — attaches a source node routing the listen-mode's rendered audio to the speaker, claiming a playback-capable session category itself unless the live `AudioEngineController` is already running (would otherwise kill its input tap).
- `PlaybackDriver.start(url:sampleRate:totalSamples:fromSample:)` — spawns a dedicated pacing thread that reads WAV PCM at real-time cadence, feeds the spectrogram processor and heterodyne/time-expansion processors, and runs the same auto-tune math `AudioEngineController.updateAutoTune` uses (driven by the spectrogram's own peak detection rather than a live pulse trigger) so heterodyne playback correctly retunes per call.
- `PlaybackDriver.stop()` — signals the pacing thread to stop and waits (bounded, 200ms) via a semaphore before returning, preventing the old and new pacing threads from concurrently racing the shared single-producer DSP state on rapid seek/restart.
- `PlaybackEngine.load(url:)` — validates the file exists and its WAV header is readable, resets playback position, and reconfigures the listening processors/spectrogram for the file's sample rate.
- `PlaybackEngine.play()` / `pause()` / `seek(toSeconds:)` — control playback; `play()` restarts from 0 if the file already finished; `seek` stops/restarts the pacing thread at the new offset, resuming play if it was already playing.

### OpenBat/Audio/RecordingMigration.swift
One-time, manually-triggered backfill that scans `Recordings` on disk for orphaned WAVs (saved before the `Recording` model existed) and reconstructs `Recording` entries from their embedded GUANO metadata.
- `run(store:)` — enumerates un-tracked WAVs, parses+renders each on a detached background task, and adds recovered entries to the `ClassificationStore`, tallying imported/skipped counts.
- `collectWavURLs(root:docsPath:known:)` — pulled into a plain non-async function because `FileManager.DirectoryEnumerator` iteration is disallowed lexically inside an `async` body.
- `parseAndRender(url:docsPath:sessions:)` — reads the GUANO chunk, recovers timestamp/species/confidence/pulse-count/location, rejects legacy NOISE-tagged WAVs rather than reintroducing them, matches the file to a session by timestamp window, and renders its spectrogram at the same resolution as save-time rendering.
- `speciesFromFilename(_:)` — fallback species extraction from the `<stamp>_<SPECIES>.wav` filename when GUANO lacks a species field.
- `parseLocPosition(_:)` — parses the GUANO `Loc Position` "lat lon" string into a `CLLocationCoordinate2D`.

### OpenBat/Audio/WavHeader.swift
Minimal reader for the fixed 44-byte WAV header `AudioRecorder` writes, shared by every caller that only needs sample rate and PCM data size.
- `read(url:)` — requests iCloud download if needed, then reads sample rate (offset 24) and data byte count (offset 40) directly out of the raw header bytes.

### OpenBat/Audio/WavPCMReader.swift
Extracted shared utility for reading an arbitrary sample range out of a 16-bit mono WAV, replacing duplicated seek/read/convert logic across the spectrogram renderer, playback pacing, and call-analysis code paths.
- `readSamples(wavURL:startSample:count:)` — seeks to the requested sample offset, reads up to `count` samples, and vectorized-converts 16-bit PCM to normalized Float32; returns a best-effort shorter array (rather than nil) when the request runs past EOF, since callers already tolerate short reads and failing outright turned edge-of-file requests into indistinguishable "silently empty" results.

### OpenBat/DSP/Biquad.swift
A single biquad IIR filter section (transposed Direct Form II) shared by the heterodyne/time-expansion listening processors for band-limiting and low-pass filtering.
- `process(_:)` — applies one sample through the transposed Direct Form II difference equation, updating the two internal delay states.
- `lowpass(cutoff:sampleRate:q:)` / `highpass(cutoff:sampleRate:q:)` — RBJ audio-cookbook coefficient design for Butterworth-Q low-pass/high-pass sections.

### OpenBat/DSP/LogFrequencyWarp.swift
Nearest-neighbour pixel-row remap that converts a linear-frequency spectrogram bitmap into a log-frequency one, for non-Metal (`UIImage`/`CGImage`) rendering paths.
- `clampedLo(_:)` — floors the low frequency bound at 10 kHz for log-axis purposes (below that, log-compression would waste half the screen on content below the bat call band).
- `warp(_:loHz:hiHz:)` — for each destination row, computes the log-scale Hz it represents, finds the corresponding row in the original linear-scale image, and copies it across via raw `CGImage` byte manipulation.
- `hzToVFrac(_:lo:hi:log:)` / `vFracToHz(_:lo:hi:log:)` — bidirectional conversions between a frequency value and its vertical fraction within an axis, honoring linear or log mode, shared by axis labels and zoom geometry so they agree with what's rendered.

### OpenBat/DSP/PolyphaseResampler.swift
Offline (non-realtime) rational-ratio resampler mirroring `scipy.signal.resample_poly`'s design (zero-stuff, Kaiser-windowed-sinc low-pass, decimate), used e.g. to convert a captured pulse from 384 kHz to BatDetect2's expected 256 kHz without the aliasing a naive linear-interpolation resample would cause near Nyquist.
- `resample(_:from:to:)` — reduces the rate ratio by GCD, zero-stuffs by `up`, convolves with a cached Kaiser FIR via `vDSP_conv`, then decimates by `down` with group-delay-centered output alignment.
- `cachedFilter(up:down:numTaps:)` — designs (or returns a cached) Kaiser low-pass FIR per `(up,down)` ratio scaled for zero-stuffing's energy loss, avoiding redesigning the filter (including Bessel series evaluation) on every classified pulse.
- `designLowpass(numTaps:cutoff:)` — builds a windowed-sinc low-pass FIR normalized to unity DC gain.
- `kaiser(n:numTaps:beta:)` / `besselI0(_:)` — Kaiser window coefficient and its underlying modified Bessel function (Abramowitz & Stegun series approximation).

### OpenBat/DSP/STFTGrid.swift
Shared high-resolution STFT core used by every spectrogram/analysis renderer in the app, offering both a one-shot full-resolution grid and a disk-streaming pooled grid that bounds work regardless of file length.
- `compute(pcm:scratch:dynamicRangeDB:)` — computes a peak-normalized [0,1] dB grid at native STFT resolution (512-sample Hann window, 2048 FFT, 32-sample hop) for a short in-memory PCM slice, using vectorized (vDSP) windowing, FFT, magnitude, and dB conversion; reuses caller-owned `Scratch` buffers to avoid per-call allocation.
- `streamPooledGridFromFile(wavURL:startSample:endSample:targetColumns:scratch:oversample:)` — reads PCM directly off disk per sampled frame (rather than requiring the whole span pre-loaded) and pools each frame's per-bin peak (max) into a fixed `targetColumns` buckets, bounding total FFT work to O(width × oversample) so one pipeline can render everything from a detail tile to a whole multi-minute file's overview; guarantees every bucket gets at least one sampled frame even under a coarse stride.

### OpenBat/Heterodyne/HeterodyneProcessor.swift
`nonisolated` classic heterodyne bat-detector DSP: multiplies the ultrasonic input by a tunable local oscillator, low-pass filters the product, and decimates to an audible 48 kHz stream, connected between the realtime capture and output threads via a lock-free ring buffer.
- `setBand(low:high:)` / `loFrequency` / `gain` — thread-safe (lock-guarded) control surface set from the main thread and read on the audio thread: restricts the input band, sets the LO tuning frequency, and sets output makeup gain.
- `setGate(_:)` — opens/closes the squelch gate via an atomic bool, driven by the auto-tuner, so silence between calls is muted.
- `reset(inputSampleRate:)` — reconfigures decimation ratio, low-pass cutoff, and resets all ring/phase/gate state for a new capture sample rate; must be called before the tap starts since neither realtime thread is active yet.
- `reconfigureBand(low:high:)` — rebuilds the 4th-order (cascaded biquad) input band-limit high-pass/low-pass filters when the band fraction changes.
- `process(_:)` — the producer: band-limits, mixes with the LO (cosine multiply), low-pass filters, decimates, and enqueues onto the lock-free ring — runs entirely on the realtime capture thread with no allocation.
- `enqueue(_:)` — lock-free SPSC ring write; silently drops overflow samples if the consumer has fallen behind (rare).
- `render(_:frames:)` — the consumer: reads from the ring with fractional-rate interpolation to steer queue depth toward a soft target (compensating clock drift between independent input/output clocks), applies the slewed squelch-gate envelope (fast open, slow close to avoid clicks), and fills the output buffer.

### OpenBat/TimeExpansion/RTESettings.swift
`@Observable`, `UserDefaults`-persisted settings model for real-time time expansion (RTE), applied to `TimeExpansionProcessor` via `onChange` in the UI.
- `apply(to:)` — pushes all five tunable parameters (min frequency, margin dB, hold ms, gain, gate block ms) onto a `TimeExpansionProcessor` instance.
- `reset()` — restores all settings to their tuned field-corpus defaults.
- `init()` — loads each setting from `UserDefaults` if present, else falls back to the static defaults, with `didSet` observers persisting any subsequent change.

### OpenBat/TimeExpansion/TimeExpansionProcessor.swift
`nonisolated` real-time time-expansion ("RTE") DSP that keeps a bat pass's natural tempo: a relative (noise-floor-tracking) gate detects calls, and only the detected, band-limited segments are pushed into the 48 kHz output at full 384 kHz resolution, producing an 8× pitch/duration expansion of just the calls.
- `setBand`/`gain`/`marginDB`/`minFrequencyHz`/`holdMs`/`gateBlockMs` — thread-safe (lock-guarded) control properties tunable live from `RTESettings`.
- `reset(inputSampleRate:)` — rebuilds band and detection filters, resets noise-floor/gate-envelope/ring state for a new capture sample rate.
- `reconfigureDetection(minFreq:)` — builds the 4th-order detection high-pass (used only to drive the gate decision, not the audible output) so sub-bat-band noise (footsteps, wind) can't trigger expansion.
- `process(_:)` — the producer: applies continuous band-limit filtering for listening and a separate detection high-pass for gating; runs a fast per-sample soft noise-gate/expander (sidechained off the detection envelope) to suppress inter-call hiss without abrupt cutoffs; then scans fixed-size blocks, tracks a rolling noise floor (falls fast, rises slowly) and opens a sample-based hold-gate when a block's RMS clears `marginDB` above the floor, enqueuing only gated samples.
- `enqueue(_:range:gain:)` — lock-free SPSC ring write of the gated, gained samples (drops overflow if full).
- `render(_:frames:)` — the consumer: skips ahead without resetting the envelope if the ring has fallen too far behind (avoiding repeated re-ramp clicks under dense activity), and applies a smooth output envelope (holding the last sample during ramp-down) so silence-to-audio and audio-to-silence transitions never click.

---

## Spectrogram (live Metal pipeline)

### Spectrogram/DisplayPalette.swift
CPU-side color palette definitions and colormap sampling used to render the pulse-view/thumbnail spectrograms (mirrors the GPU colormap in Spectrogram.metal, kept manually in sync since MSL can't import Swift).

- `Palette` (enum): the seven user-selectable colormap options (inferno, viridis, magma, greyscale, jet, plasma, neon) with a `displayName` for UI.
- `DisplayColormap.rgb(_:palette:)`: linearly interpolates a palette's stop table at a given 0–1 intensity and fades near-zero values to black so silence renders dark regardless of the palette's t=0 hue.
- `DisplayColormap.makeLUT(palette:steps:)`: precomputes a 256-entry lookup table once per colorize pass, replacing a per-pixel dictionary lookup + linear search that was measured taking 1.6–5.3 seconds over a 4096×1024 image (the root cause of a slow-loading overview complaint).
- `DisplayColormap.sample(_:palette:)`: private helper that walks a palette's stop table and linearly interpolates between the two bracketing color stops.

### Spectrogram/FrequencyBandControl.swift
A SwiftUI popover for adjusting the live spectrogram's frequency band, time window, and noise floor.

- `FrequencyBandControl.body`: lays out the range slider (frequency band), a time-window slider, a log-frequency toggle, and a noise-floor slider with reset buttons for band and time window.
- `localNoiseFloor` (state): mirrors the noise floor while dragging so the real `@Observable`/`UserDefaults`-backed binding is only written once per gesture (on `onEditingChanged`) instead of every drag frame, avoiding main-thread contention with the still-running live spectrogram behind the popover.
- `cutoffLabel(_:_:)`: renders a labeled kHz readout for a given band fraction (converts fraction-of-Nyquist to kHz for display).

### Spectrogram/HistoryBuffer.swift
A CPU-side ring buffer storing FFT columns as `UInt8` (quantized from 0–1 float magnitude) to hold up to 60 s of spectrogram history at 4x less memory than Float32.

- `init(capacity:binCount:)`: allocates the flat ring buffer and reusable scratch arrays sized to avoid per-call allocation on the hot path.
- `append(_:)`: vectorized (vDSP) scale/clamp/convert of one float column into the ring at `writeHead`, then advances the head — runs on the main thread once per drained column (~750/s).
- `rowMajorSlice(offset:count:)`: extracts a window of columns as a row-major (bin-major) Float array ready for direct Metal texture upload, using a single strided `vDSP_vfltu8` per column instead of a separate transpose pass (an earlier transpose-based version had a diagonal-stripe corruption bug this design avoids).
- `clear()`: resets `writeHead`/`totalWritten` to 0, effectively discarding history without touching the underlying bytes (safe because `rowMajorSlice` zeroes anything beyond `totalWritten`).
- `snapshot()`: returns an independent `HistoryBuffer` sharing the same backing array via Swift's copy-on-write, making the "freeze for scroll-back" operation O(1) until the live buffer's next append forces the physical copy.

### Spectrogram/RangeSlider.swift
A reusable two-thumb SwiftUI slider over the 0...1 range, used to set the spectrogram's high-pass/low-pass frequency band.

- `RangeSlider.body`: computes thumb positions from the `low`/`high` bindings and view width, draws the track/highlighted range/thumbs, and attaches drag gestures to each thumb.
- `drag(usable:update:)`: builds a `DragGesture` that converts a thumb's drag location into a normalized 0...1 position and forwards it to the given update closure.
- The `low`/`high` update closures (inline in `body`) clamp each thumb so it can't cross the other by less than `minGap`, keeping the range non-degenerate.

### Spectrogram/ScrollMomentum.swift
A `CADisplayLink`-driven helper that eases a scroll offset from its release value down to zero ("coasts to a stop") after a drag-to-scroll gesture ends.

- `cancel()`: invalidates the display link and clears callbacks, called at the start of every new drag so a fresh touch always overrides a still-decelerating one.
- `start(residual:apply:completion:)`: begins a ~0.5 s cubic ease-out animation from the given residual distance, calling `apply` each frame and `completion` at the end; built on `CADisplayLink` (added with `.common` run-loop mode) rather than `Task.sleep` because an earlier `Task`-based version silently stopped ticking after its first frame during UIKit gesture-tracking run-loop mode.
- `tick()`: the per-frame `@objc` callback that computes the eased fraction of elapsed time and calls `apply` with the remaining eased distance, finishing and calling `completion` once the duration elapses.

### Spectrogram/SpectrogramProcessor.swift
Runs on the realtime audio thread: turns raw PCM samples into windowed, zero-padded FFT columns (via Accelerate/vDSP) with both a fixed-range "trigger" scale (for pulse detection/auto-tune) and an adaptive-contrast "display" scale, and buffers raw PCM for later pulse-capture snapshots.

- `Column` (struct): one finished FFT column's display magnitudes plus its dominant bin/level and the absolute sample index it ends at, so batched draining doesn't lose per-column peak information.
- `frequency(forBin:level:)`: converts a bin index to Hz, returning 0 if the level is below the detection threshold or the sample rate isn't yet known.
- `pcmSnapshot(count:startSamplesBack:)`: returns a slice of the raw-PCM ring buffer ending a given number of samples before "now", used by the pulse detector/capture pipeline.
- `pcmSnapshot(count:endingAtAbsolute:)`: returns a PCM slice anchored to an absolute stream index (from a `Column.endSample`) rather than a relative offset, keeping captured pulse windows pinned to a fixed point in time regardless of drain timing.
- `pcmSnapshotLocked(count:startSamplesBack:)`: the actual ring-buffer copy (must be called under `pcmLock`), handling wraparound with at most two `replaceSubrange` calls.
- `process(_:)`: the realtime audio-tap entry point — block-copies incoming samples into the PCM ring, appends them to the FFT accumulator, and (unless `suspended`) slices off complete `windowLen`-sample frames into FFT columns via `makeColumn`, then hands them off to `pending` under a lock with a backpressure cap (`maxPendingColumns`) so a stalled main thread can't grow the queue unboundedly.
- `drain()`: main-thread call that atomically empties and returns all columns produced since the last call.
- `makeColumn(from:endSample:)`: applies the Hann window to the raw frame, zero-pads and runs the vDSP real FFT, computes magnitudes, then produces two parallel scalings of the same magnitudes — a fixed-range trigger column (for stable pulse-detection thresholds) and an adaptive-ceiling display column (tracking a running dB ceiling that snaps up instantly and decays slowly, so the live view's contrast stays well-used regardless of absolute signal level) — and records the dominant in-band bin for the heterodyne auto-tuner.

### Spectrogram/SpectrogramRenderer.swift
The `MTKViewDelegate` that drives the Metal-rendered spectrogram, managing two coexisting display paths: a small ring texture for smooth live scrolling, and a linear "seek" texture reloaded from a frozen history snapshot when the user drags to scroll back.

- `isScrolling` (didSet): on drag-start, freezes a COW snapshot of `liveHistory` (live buffer keeps recording underneath); on drag-end, discards the snapshot and snaps the display head back to the live edge.
- `visibleColumns` (computed): the number of columns to show on screen, derived from `timeWindowSeconds * columnsPerSecond`, clamped to `maxVisibleColumns`.
- `init?(processor:maxVisibleColumns:historySeconds:guardColumns:)`: sets up the Metal pipeline/shaders, allocates the ring texture (live path) and two double-buffered seek textures (scroll path), and creates the CPU `liveHistory` ring buffer.
- `draw(in:)`: the per-frame delegate callback — clears history when triggered-display mode is freshly enabled, drains new FFT columns from the processor into the ring texture and `liveHistory` (skipping silent gaps in triggered mode), feeds the pulse detector per-column, refreshes the seek texture if scrolled and the scroll position/window changed, advances the smoothed live display head, and issues the actual Metal draw call with band/palette/noise-floor/log-frequency uniforms.
- `clearTexture(_:width:)`: zero-fills a texture at init so nothing garbage is sampled before the first real upload.
- `batchUploadToRing(_:)`: uploads a batch of columns to the ring texture in at most two `replace()` calls (splitting only at the ring wrap point) instead of one call per column, transposing column-major input into the bin-major staging layout the GPU expects.
- `uploadSeekSlice(offset:count:)`: pulls a row-major slice from the frozen snapshot and uploads it to the currently-inactive seek texture, then flips the read/write buffer indices so the GPU never reads a texture that's mid-write — avoiding a real write/read race that previously caused visible "stripy noise" while scrubbing.
- `advanceDisplayHead()`: smooths the live display head forward each frame using an exponentially-smoothed frame delta and target-latency tracking, so the live edge glides rather than jumps, while clamping it to stay within actually-written, in-bounds ring columns.

### Spectrogram/SpectrogramView.swift
The SwiftUI-facing wrapper around the Metal spectrogram: hosts the `MTKView` via `UIViewRepresentable`, renders the frequency-axis labels/grid overlay, and implements drag-to-scroll with momentum.

- `MetalSpectrogramView.makeCoordinator()`: constructs the `SpectrogramRenderer` (acting as the `MTKView`'s coordinator/delegate).
- `MetalSpectrogramView.makeUIView(context:)`: configures the `MTKView` (pixel format, 60fps target, manual redraw disabled, initial paused state).
- `MetalSpectrogramView.updateUIView(_:context:)`: pushes all SwiftUI state (band, palette, scroll position, time window, pause flag) into the renderer coordinator each SwiftUI update; toggling `isPaused` stops/starts the 60Hz render loop, freeing the main run loop for gesture recognition while a sheet/popover covers the view.
- `SpectrogramView.columnsPerSecond` (computed): derives FFT columns-per-second from `maxFrequency` (Nyquist) and the processor's hop size.
- `dragGesture(viewWidth:)`: converts horizontal drag translation into a scroll-column offset (dragging right scrolls into the past), and on release computes a residual distance from the gesture's predicted end translation and hands it to `ScrollMomentum` so the scroll coasts to a stop.
- `returnToLiveButton`: a button that cancels any momentum, resets the scroll offset to 0, and exits scrolling mode to snap back to the live edge.
- `gridOverlay`: draws faint quarter-line analysis gridlines matching the pulse view's grid style.
- `tickHzValues(count:)`: computes evenly screen-spaced tick frequencies for the axis labels, log-interpolated when `logFrequency` is on (must match the shader's own log interpolation) or linear otherwise.
- `frequencyAxis` / `axisLabel(_:)` / `format(_:)`: lay out and format the vertical frequency-axis tick labels (Hz vs kHz depending on magnitude).

### Spectrogram/Spectrogram.metal
A Metal shader pair (`spectro_vertex`/`spectro_fragment`) that renders a full-screen quad sampling the rolling FFT-column texture (ring texture for live playback, or a linear seek texture when scrolled), converting each texel's intensity into a color via one of seven palette functions that must mirror `DisplayPalette.swift`'s CPU-side stop tables exactly. The fragment shader also applies the visible frequency-band crop (linear or log-spaced), a noise-floor gate with contrast stretch, and handles the ring texture's fractional sub-column scrolling (repeat-wrap sampling) versus the seek texture's clamped, non-wrapping sampling.

---

## Classifier (pulse detection & species ID)

### Classifier/AutoIDSettings.swift
Persisted, per-model AutoID configuration (species toggles/priors, pass thresholds, quality gate) plus the single active-model selector, GBIF-driven prior refresh, and map-pin gating.

- `isMappable(_:)` — decides whether a pass earns a map pin (excludes NOISE/NoID and requires confidence/pulse-count gates), keeping noise off the session map while still listing it as a species.
- `acknowledgeChangeSummary()` — clears the pending "priors changed" summary once the UI has shown it to the user.
- `refreshPriorsFromGBIFIfNeeded(coordinate:)` — re-suggests every model's species priors from GBIF occurrence data if the user moved >100 km or this is the first fix, guarded by its own lock (not actor isolation) because it can be invoked concurrently off the main thread.
- `loadPersisted()` — one-shot guarded load of saved settings, deliberately not called from `init()` since `@State` initializers can re-run and pay a JSON decode for nothing.
- `effectivePrior(for:)` — returns a species' prior weight for classification, suppressing disabled species to a near-zero floor rather than 0.
- `qualityGate` — builds a plain-value snapshot of the active model's per-pulse quality gate for use off the `@Observable` object.
- `defaultSettings(for:)` — seeds a model's default settings (every species enabled, neutral prior, real-but-modest pass thresholds) from its descriptor.
- `resetModel(_:)` — resets one model back to its descriptor defaults.
- `save()` / `load()` — encode/decode the v2 per-model settings blob to UserDefaults, with `load()` also migrating a legacy single-model v1 blob into the NABat model.

### Classifier/BatClassifier.swift
Wraps the NABatML CoreML model, rendering a 100×100 NABat spectrogram from raw PCM and returning prior-adjusted classification posteriors.

- `QualityGate.passes(_:)` — gates a rendered pulse on SNR, amplitude, and peak-time-not-at-edge thresholds before it's ever handed to the model, matching nabat-ml's own pulse-quality filter.
- `classify(pcm:gate:prior:)` — renders the spectrogram, rejects it via the quality gate, runs CoreML inference, applies per-species priors to the raw softmax output, and renormalizes so the result is a proper posterior (needed so `minPassConfidence` compares against a meaningful scale rather than an arbitrary one).

### Classifier/BatDetect2Classifier.swift
Adapter that lets BatDetect2 (a fully-convolutional UK bat detector/classifier) plug into OpenBat's per-pulse `SpeciesClassifier` shape, using PulseDetector purely as the call-finder and BatDetect2 only to classify the window it's handed.
- `init?(modelName:)` — loads the BatDetect2 `.mlmodelc`/`.mlpackage` by name via the generic `MLModel` API rather than a generated wrapper class, so future model swaps need no code change.
- `classify(pcm:gate:prior:)` — resamples the pulse window to BatDetect2's 256 kHz, renders its spectrogram, runs inference, picks the spatial cell with the highest detection probability, reads that cell's class distribution, applies priors, and renormalizes — discarding BatDetect2's own bounding-box localization and keeping only its classification.

### Classifier/BatDetect2SpectrogramRenderer.swift
Spectrogram configuration (checkpoint-verified) for feeding PCM into BatDetect2's CNN.

- `render(pcm:)` — converts already-256 kHz PCM into the 128×256 grayscale image tensor BatDetect2 expects, via the shared `ClassifierSpectrogramEngine`; returns nil for too-short input.

### Classifier/ClassificationLogger.swift
Background CSV logger that appends every pulse/pass classification event to a rotating, size-capped log file under Documents, with columns covering the union of all registered models' class codes.

- `logPulse(_:modelID:at:)` / `logPass(_:pulseCount:modelID:at:)` — append a single-pulse or pass-aggregate classification row.
- `clearLog()` — deletes the active log and all rolled archives, then recreates the header.
- `writeHeaderSyncIfNeeded()` — (re)writes the CSV header if the file is missing or its header no longer matches the current column set (e.g. a new model widened the class-code union).
- `rotateIfNeeded()` — rolls the active file to a timestamped archive once it exceeds 5 MB, then starts a fresh file and prunes old archives past the cap of 5.
- `archiveURLs()` / `pruneArchives()` — list rolled archive files (oldest first) and delete the oldest ones beyond the retention limit.
- `makeRow(...)` — formats one CSV row (timestamp, type, model, species, confidence, pulse count, all class scores); `internal` visibility so tests can assert header/row alignment.
- `append(_:)` — serializes the rotate-check-then-write sequence on a background queue so it's atomic with respect to other writes.

### Classifier/ClassificationStore.swift
`@Observable` persistence layer for AutoID history: sessions (field outings), passes (aggregated multi-pulse IDs), and recordings (kept WAVs), each with JSON metadata plus JPEG thumbnails on disk.

- `PassRecord.isNoise` / `isNoID` — distinguish a confident "not a bat" call (NOISE) from insufficient evidence either way (NOID), used to decide map/list visibility.
- `PassRecord.complex` / `isComplexAmbiguous` — resolve a pass's persisted complex id back to its `SpeciesComplex` and report whether the runner-up made this ID an *active* ambiguity.
- `Array.filteredByNoID(showNoID:)` — shared filter (via `NoIDFilterable`) so both passes and recordings honor the same "hide NoID" display toggle.
- `startSession(startDate:)` / `endSession()` — begin/close a field outing, marking it the active session that new passes/recordings attach to.
- `setTitle(_:for:)` / `setNotes(_:for:)` / `setPlaceName(_:for:)` — edit a session's metadata, folding a reverse-geocoded place name into the title while preserving the start timestamp.
- `appendTrackPoint(_:)` — appends a GPS breadcrumb to the active session's recorded track.
- `passes(forRecording:)` — finds every pass whose timestamp falls inside a Recording's span (same session bucket), letting a WAV's detail page show its per-pulse IDs without duplicating pulse data.
- `speciesFeed(sessionID:since:)` — builds the Merlin-style "recently detected" species stack for the current run, scoped by a `since` floor so it doesn't resurrect species from long-past Listening-bucket outings.
- `deleteSession(_:)` — removes a session and cascades deletion to its passes (with images) and recordings (with WAVs).
- `addPass(...)` — builds a `PassRecord` off the main thread call site, writing pulse thumbnails and JSON off-thread, then inserts and persists on the main actor.
- `addRecording(...)` — records a finished kept WAV segment; `onInserted` fires only once the entry is actually present, since the write is asynchronous and JPEG-write-gated.
- `updateUploadStatus(recordingID:status:)` — updates a recording's upload phase and tracks a consecutive-failure counter used to gate automatic retries.
- `clearAllUploadStatus()` — resets every recording's upload badge to untouched after a consent-erasure rotates the device identifier, since per-recording "Uploaded" claims no longer describe an identity this device still holds.
- `delete(_ pass:)` / `delete(_ recording:)` / `delete(_ toDelete: [Recording])` — remove records and their on-disk assets (thumbnails, and for recordings, the WAV too); the bulk form avoids O(n²) cost from repeated full-array encodes during "Delete All".
- `clearAll()` / `clearListening()` / `deleteAllRecordings()` / `deleteNoIDRecordings()` / `deleteRecordings(belowConfidence:)` — bulk-delete helpers for Settings ▸ Recordings actions, each scoped differently (everything, only Listening bucket, only recordings, only NoID, only low-confidence).
- `image(for:)` / `spectrogramImage(for:)` — load a pulse/recording thumbnail from disk with an in-memory `NSCache` so scrolling doesn't re-decode JPEGs.
- `wavURL(for:)` — resolves a Recording's stored relative WAV path to an absolute URL at use time (never persisted absolute, since the container path can change).
- `prune()` — trims `passes` to `maxPasses`, deleting the evicted passes' thumbnail files.
- `persist()` / `persistRecordings()` / `persistSessions(force:)` — snapshot-and-encode each store to its own JSON file off-thread; session persistence is throttled unless `force` bypasses it, so a streaming GPS track doesn't rewrite on every breadcrumb.
- `load()` — one-shot async load of all three JSON stores off the main thread, re-checking the guard after the await so state recorded during the decode isn't clobbered by the disk copy.

### Classifier/ClassifierSpectrogramEngine.swift
Shared, spec-driven STFT → scale → denoise → normalize → resize → colorize pipeline used by every model's spectrogram renderer, also producing generic pulse-quality metrics (amplitude/SNR/peak time).

- `dftSetup(nFFT:)` — lazily creates and caches a `vDSP_DFT_Setup` per FFT size so multiple model specs can share the engine without recreating vDSP state per call.
- `windowTable(_:count:)` — builds the Hamming or Hann window table, using the DENORM (peak 1.0) Hann convention to match `torch.hann_window` exactly for PCEN correctness.
- `render(pcm:spec:)` — runs the full pipeline: STFT to dB (plus a parallel linear-magnitude copy for PCEN), bandpass zeroing outside the model's frequency range, peak/SNR/peak-time metric extraction pre-denoise, scaling (dB no-op or PCEN), denoise (row/column median or spectral mean subtraction), post-denoise quality metrics, normalization (minMax/peak/none), then crop+resize (nearest for NABat, bilinear with torch align-corners-false semantics for BatDetect2) into the final colored/grayscale tensor.
- `sortedMedian(_:count:)` — computes the median of a buffer slice, backing the row/column-median denoise path.
- `applyPCEN(...)` — implements Per-Channel Energy Normalization exactly matching BatDetect2's reference (fixed legacy hop/rate for the smoothing constant, zero-history initial condition, no final bias-power subtraction term) — a documented fidelity fix that took correlation from ~0.001 to ~0.99 against the real pipeline.
- `colorize(_:map:)` / `magma(_:)` — maps a normalized value through a 17-stop linear-interpolated approximation of matplotlib's magma colormap.

### Classifier/ModelRegistry.swift
Central registry describing every bundled classifier model (NABat ML, BatDetect2) as a `ModelDescriptor` — metadata, class list, species groupings/complexes, quality gate, input window spec, and a lazy classifier factory — so adding a model is a one-line append with no other code changes.

- `ModelCoverage.contains(_:)` — checks whether a coordinate falls in a model's (approximate) training-region bounding box, used only to drive location-based model suggestions.
- `ModelDescriptor.complex(for:)` — looks up which acoustic confusion complex (if any) a species code belongs to for this model.
- `descriptor(id:)` — looks up a registered model descriptor by its stable id.
- `suggestedModel(for:)` — finds the model whose coverage box contains the given coordinate, for the "we suggest switching models" location flow.
- `complex(id:)` — resolves a persisted complex id back to its `SpeciesComplex` across all models, so a pass can store just an id rather than duplicating name/note/members.
- `ModelInputSpec.nabat` / `.batdetect2` — static specs defining each model's classification window length and onset placement fraction; BatDetect2's 256 ms window forces `PulseDetector`'s trailing-audio budget wider to avoid truncating captures.
- `nabat` / `batDetect2` static descriptors — the actual registered model configs, including species groups, confusion complexes (e.g. Myotis, low-frequency bats, UK pipistrelles), quality gate defaults, and NoID raw-confidence thresholds (NABat's 0.57 field-verified, BatDetect2's 0.4 a documented placeholder).

### Classifier/NaBatSpectrogramRenderer.swift
Replicates nabat-ml's `_process_window`/`make_training_spectrogram` preprocessing exactly (Hamming STFT, 5–100 kHz bandpass, row/column-median denoise, min-max normalize, nearest-neighbor resize, magma colormap) to produce the 100×100×3 tensor the NABat CNN expects.

- `render(pcm:sampleRate:)` — converts 50 ms of raw PCM into the model's expected image tensor plus quality metrics (amplitude/SNR/peak time), delegating to `ClassifierSpectrogramEngine` with NABat's spec; returns nil if the PCM is too short.

### Classifier/PassAggregation.swift
Implements the NABat-ml reference pipeline's pass-level outcome rule (NoID / NOISE / species) from raw, pre-prior per-pulse softmax scores, shared by both the live pulse detector and the WAV recorder's own auto-ID tagging so the two never disagree.

- `aggregate(_:minAdjustedConfidence:minPulseCount:rawConfidenceThreshold:noiseClassName:)` — computes mean raw top-score across the pass's pulses and returns nil (NoID) if it's below the model's raw-confidence threshold; otherwise sums raw scores to find the winning class by unbiased evidence (returning a NOISE outcome if that's the winner), or falls through to prior-adjusted posteriors gated by the user's confidence/pulse-count settings to pick the winning species.

### Classifier/PulseDetector.swift
Core per-column pulse state machine: detects call onsets/ends from spectrogram peak levels, defers and captures each pulse's PCM window, classifies it via the active model, and aggregates classified pulses into a pass with silence-timeout finalization.

- `init()` — restores every tunable detection/display setting from UserDefaults, clamping any out-of-range legacy values (e.g. an old `displayWindowMs`).
- `accumulatePulse(_:raw:adjusted:)` — records one classified pulse's scores and detail into the running pass accumulator.
- `finalizePass()` — closes the current pass on silence timeout: runs `PassAggregation`, persists a NOID record if the outcome is nil (so evidence isn't silently dropped), otherwise computes the pass result, runner-up species, and complex-ambiguity flag, logs it, and persists it to the store with session/coordinate attachment.
- `resetStats()` — clears session-scoped counters (pulse count/rate, last capture, pass state) without touching persistent settings.
- `deferTrailSeconds` — computed trailing-audio budget (max over every registered model's classification window trailing fraction + slack) so no model's capture window is ever truncated.
- `activeClassifier()` — resolves and caches the classifier + descriptor for the currently active model id, rebuilding only when the id changes.
- `refreshModel()` — forces a warm (re)load of the active model, e.g. right after the user switches models in settings.
- `feed(peakLevel:peakFrequency:columnEndSample:columnsPerSecond:sampleRate:)` — the main per-column entry point: closes a timed-out pass, runs the amplitude/frequency trigger test, tracks the pulse-run state machine (rising edge, bridged gaps, trailing-edge validation), arms a deferred capture anchored to the onset's absolute sample index, and fires it once enough trailing audio exists.
- `registerDetection()` — records a validated pulse for the count/rate readouts independent of whether a capture actually gets scheduled for it, so stats reflect true pulse arrivals even during a fast feeding buzz.
- `scheduleCapture(columnsPerSecond:sampleRate:onsetAbs:)` — snapshots PCM windows (display + classification), priors, and quality gate on the main thread, then off-thread renders the pulse image, releases the capture gate early (so the next pulse can be armed while slow CoreML inference continues), classifies the pulse, and dispatches results back to the main thread to update display state, accumulate into the pass, and log the pulse.

### Classifier/PulseImageRenderer.swift
Renders a single captured pulse into a sharp, onset-locked high-resolution spectrogram image for the Pulse View panel and Sessions thumbnails, working directly from raw captured PCM rather than the coarser live-display buffer.

- `render(pcm:sampleRate:noiseFloor:minFrequencyHz:displaySpanSeconds:onsetFraction:expectedOnsetSample:palette:)` — computes a high-res STFT (via `STFTGrid`), locates the call within a search region around the detector's expected onset, applies a noise-floor gate with contrast stretch, measures duration from the −12 dB energy envelope and frequency extent from a threshold band, computes a pulse-quality score (peak-vs-mean column energy), then renders both a wide pannable/zoomable image and a tight "clean" crop for storage — locking the onset to a fixed fraction from the left so every capture pins the call at the same spot.

### Classifier/PulseSettingsView.swift
SwiftUI sheet for tuning the pulse detector's trigger mode, amplitude/frequency thresholds, display refresh interval, and noise-rejection (min duration, gap-bridging, hold-off) settings, bound directly to a `PulseDetector`.
(No non-trivial logic beyond simple `Binding` conversions, e.g. `minFreqKHz` converting Hz↔kHz for the slider.)

### Classifier/PulseViewControls.swift
Popover for purely display-related pulse-view settings (zoom window span, noise floor, log-frequency toggle), separate from detection-tuning which lives in `PulseSettingsView`.
(No non-trivial logic beyond simple UI bindings.)

### Classifier/SpectrogramRenderSpec.swift
Declarative, per-model configuration struct describing everything needed to turn raw PCM into the exact image tensor a classifier CNN was trained on (FFT params, frequency crop, scaling, denoise, normalize, resize, colormap) — pulling these knobs into data so a new model's spectrogram pipeline doesn't require duplicating a whole vDSP file.

- `channels` — computed property returning 3 for a colormap spec or 1 for grayscale, used to size the output image tensor.

---

## Field Guide (species browser & range maps)

### FieldGuide/GBIFRangeMapView.swift

Renders the species detail page's interactive distribution map by binning GBIF occurrence points into H3 hexagons on-device rather than using GBIF's fixed-pixel-size raster tile overlay.

- `GBIFDistributionCard.body` — drives the load state machine (loading/loaded/noData/error) and renders the `Map` with one `H3Cell` shape per bin, or the matching placeholder/error view.
- `GBIFDistributionCard.task(id:)` — resolves points in priority order (in-memory `resolvedCache` → committed `SpeciesRangeStore` snapshot → live `GBIFService` fetch), so revisiting a species is instant and offline data wins over a network call.
- `Self.resolvedCache` (static dict) — caches resolved state per species scientific name so a List row scrolling off/on screen doesn't reset `@State` and re-flash the loading spinner.
- `retryToken` / "Try Again" button — bumps a counter to force `.task(id:)` to re-run after a network error, since a failed fetch is deliberately never cached and `species.id` alone wouldn't change.
- `attributionFooter` — shows the GBIF credit, plus the range snapshot's version/date only when `usedSnapshot` is true (a live fetch has no meaningful version).
- `loadingPlaceholder` — a faded, disabled `Map` behind a spinner so the loading state still reads as "a map is coming."
- `Self.bin(_:at:)` — converts raw lat/lon points into H3 cells at a given resolution and counts records per cell; cheap enough to rerun on every resolution change.
- `Self.resolution(forSpanDegrees:)` — maps the map's current latitude span to an H3 resolution so displayed hexagons stay a sensible size/density regardless of zoom level.
- `density(for:)` / `opacity(for:)` — square-root-compress a cell's point count into an opacity value, so a few oversampled cells don't make lightly-sampled ones look negligible.
- `.onMapCameraChange(frequency: .onEnd)` — recomputes `resolution` from the new camera span after panning/zooming settles, triggering a re-bin via `.onChange(of: resolution)`.

### FieldGuide/GBIFService.swift

Minimal GBIF API client that resolves a species name to a taxon key and fetches raw occurrence coordinates for the distribution map, plus a location-based prior-suggestion helper for the classifier's species picker.

- `fetchTaxonKey(for:)` — resolves a scientific name to a GBIF taxon key via `/v1/species/match`, checking (and updating) a `UserDefaults`-backed on-device cache first, guarded by `taxonKeyCacheLock` against concurrent lost-update races from multiple species cards resolving at once.
- `fetchOccurrencePoints(taxonKey:maxRecords:)` — paginates `/v1/occurrence/search` for up to `maxRecords` coordinate-bearing records, caches the un-binned result to disk indefinitely, and returns a `PointFetchResult` distinguishing genuine "no data" from "network error" so the UI can show different copy for each.
- `region(for:)` — computes a padded `MKCoordinateRegion` bounding a species' occurrence points, so the map opens centered on the species' actual range instead of the whole world.
- `occurrenceCount(scientificName:near:radiusKm:)` — queries GBIF with `limit=0` to get just a record count near a coordinate (cheap), returning nil (distinct from a real 0) on failure so a GBIF outage isn't mistaken for "species absent."
- `suggestPriors(scientificNames:near:radiusKm:)` — concurrently fetches nearby occurrence counts for every candidate species and turns them into enabled/disabled + scaled prior suggestions (square-root-compressed relative to the locally most-recorded species) for the classifier's per-species prior sliders.
- `clampToPriorStep(_:)` — snaps a continuous suggested prior to the app's discrete prior scale (0.01/0.25/0.5/0.75/1.0) used elsewhere in the UI.

### FieldGuide/SpeciesDetailView.swift

The full field-guide species page, assembling a hero photo, header, distribution map, and optional sections (measurements, echolocation, conservation, habits, regions, references) that only render when their backing data exists.

- `body` — lays out the page as a `List` of conditional Sections, and on iPad landscape swaps the stacked "Overview" + "Distribution" sections for a side-by-side layout via `overviewAndDistributionSection`.
- `overviewAndDistributionSection(availableWidth:)` — manually computes text/map column widths (since a List row can't measure its own width) to show the overview text and a squared-off `GBIFDistributionCard` side by side on iPad landscape.
- `photoSection(url:)` — renders a full-bleed hero photo (fetched via `WikipediaSpeciesImageService`) with a blanket CC BY-SA attribution caption, since per-image licensing isn't tracked.
- `referencesSection` — shows the creator/editor summary row (opens `ContributorsSheet`) and any citation strings, only if either exists.
- `measurementsSection` / `echolocationSection` / `conservationSection` / `habitsSection` — each conditionally renders its Section only when the corresponding optional model field is present, letting sparse guide entries show fewer sections rather than empty boxes.
- `breadcrumb` — joins order/family/genus (dropping empties) into the taxonomy breadcrumb string shown under the species name.
- `.task(id: species.scientificName)` — fetches the hero photo URL asynchronously when the page appears or the species changes.
- `ContributorSummaryRow` / `ContributorsSheet` / `ContributorRow` — compact "Created by X · N edits" row that opens a sheet listing the full creator + editor history with dates and notes.
- `MeasurementRange.formatted(unit:)` — formats a min/max range as a string, defensively swapping min/max in case a hand-edited JSON entry has them reversed.
- `MeasurementRange.formattedHz()` — converts a Hz range to kHz before formatting, matching the app's spectrogram/pulse UI conventions.

### FieldGuide/SpeciesExplorerView.swift

The Species tab's explorer: a fuzzy search bar over a spinnable 3D MapKit globe showing one pin/outline per guide region, drilling down into region species lists and species detail pages.

- `SpeciesGuideDestination` (enum) — a single shared navigation-destination type for both region and species pushes, avoiding a `NavigationStack` desync bug caused by mixing `.navigationDestination(for:)` with `.navigationDestination(item:)`.
- `results` (computed) — scores every guide species against the current query via `GuideSpecies.searchScore` and returns them sorted best-match-first.
- `globe` — renders `MapPolygon`s (or fallback pins for regions without boundary data) plus per-region annotations on a realistic-elevation `Map`, fading in and only nudging the camera once per appearance (`hasNudgedCameraOnce`).
- `animateSwoop(to:)` — hand-steps the camera from Null Island to the user's location in small increments on a repeating `Timer`, because SwiftUI's `Map` silently shortens a single large `withAnimation(duration:)` camera move to MapKit's own short internal transition.
- `.onAppear` on `globe` — triggers the opening swoop after a short delay, which also works around realistic-elevation globes not laying out `Annotation` pins until the camera moves at least once.
- `regionColor(_:)` — assigns each region a stable color by cycling through a fixed palette by index (not hashed from id), so neighboring regions stay visually distinct.
- `globeFooter` — shows the guide's data version/update date, a refresh spinner, and a "Sources" button opening `DataModelSourcesView` for data/model attribution and licensing.
- `IUCNBadge.forStatus(_:)` — maps a free-text IUCN status string (case-insensitively) to a short badge label and color, defaulting to a neutral gray "?" for unrecognized/missing values so a wrong-but-visible badge is easier to catch and fix than a silently hidden one.
- `GuideSpeciesThumbnail` — shows a species' Wikipedia photo (async-loaded) or a deterministic family-tinted silhouette icon fallback while loading or if no photo exists.
- `GuideSpeciesRow` — shared row layout (thumbnail + names + peak-frequency caption + IUCN badge) used by both search results and region species lists.
- `RegionSpeciesView.families` (computed) — groups a region's species by family, alphabetically sorted with species lacking a family pinned last under "Other," as a stopgap taxonomy grouping.

### FieldGuide/SpeciesGuide.swift

Codable data model for the community-editable field-guide JSON document (species, regions, and all their optional page-content fields), plus fuzzy search scoring.

- `SpeciesGuide.parseISO8601(_:)` — parses an ISO 8601 string, falling back to a date-only format since `ISO8601DateFormatter`'s default options reject a hand-typed date-only string like "2026-07-21".
- `SpeciesGuide.species(in:)` — returns a region's species sorted alphabetically by common name, used to populate `RegionSpeciesView`.
- `GuideRegion.polygons` (computed) — decodes the raw GeoJSON-style `boundary` (`[[[Double]]]`, lon/lat order) into map-ready coordinate rings, dropping malformed rings with fewer than 3 points.
- `GuideSpecies.genus` (computed) — derives genus from the first word of `scientificName` rather than storing it redundantly, as a stopgap until a real taxonomy JSON exists.
- `GuideSpecies.creator` / `editors` (computed) — split the `contributors` edit history into the first (creator) entry and the rest (editors).
- `GuideSpecies.searchScore(for:)` — returns the best fuzzy-match score against either the common or scientific name, or nil if neither matches.
- `GuideSpecies.score(query:in:)` (private static) — tiered match scoring (exact prefix > word prefix > substring > in-order subsequence), each minus a length penalty so tighter matches rank higher; used to power the explorer's search bar.

### FieldGuide/SpeciesGuideStore.swift

`@Observable` store that loads the field-guide JSON via a three-tier resolution (bundled → cached → remote), always preferring the highest `dataVersion` so the guide works offline and self-updates over time.

- `init()` — deliberately does no I/O since it runs inline as a `@State` default value re-evaluated on every `WindowGroup` closure pass; all real loading happens in `loadLocal()`.
- `loadLocal()` — runs the bundled-vs-cached decode and version comparison on a detached background task (avoiding a synchronous ~328 KB JSON decode blocking the first frame), then applies the winning result on the main actor.
- `loadFromDisk()` (private static) — the actual bundled-vs-cached merge logic: prefers cached if strictly newer, self-heals a corrupt cache by deleting it, and specifically guards against a stale same-`dataVersion` cache shadowing bundled content that was edited without bumping the version (verified via raw byte comparison).
- `refreshFromRemote()` — fetches the GitHub-hosted JSON (bypassing `URLCache`), validates schema compatibility, and adopts + caches it only if its `dataVersion` is strictly newer; any failure is swallowed into `lastRefreshError` without degrading the in-memory guide.
- `decode(data:)` (private static) — decodes JSON and rejects it if its `schemaVersion` exceeds what this app build supports, rather than mis-decoding an incompatible future schema.

### FieldGuide/SpeciesRangeStore.swift

`@Observable` store for a precomputed snapshot of every guide species' GBIF occurrence points (`SpeciesRangeData.json`), using a two-tier (cached → remote) resolution with no bundled tier since the data is large and non-essential for first launch.

- `loadLocal()` — decodes the cached range snapshot off the main thread and applies it (ranges, version, updatedAt) on the main actor; a cold install with no cache just leaves `ranges` empty.
- `refreshFromRemote()` — fetches and adopts the GitHub-hosted snapshot only if its `dataVersion` is strictly newer, mirroring `SpeciesGuideStore.refreshFromRemote()` exactly.
- `decode(from:)` (private static) — decodes the cache file, self-healing (deleting it) on any decode failure or unsupported schema version so a corrupt cache doesn't silently keep failing on every launch.
- `CompactPoint.init(from:)` — decodes a point from a bare `[lat, lon]` two-element array instead of a keyed object, since the generator script drops repeated key names to shrink file size once precision is already rounded.
- `convert(_:)` (private static) — maps the decoded `[String: [CompactPoint]]` dictionary into `GBIFService.GBIFOccurrencePoint` values used by the rest of the app.

### FieldGuide/WikipediaSpeciesImageService.swift

Fetches a representative photo URL for a species from Wikipedia's public REST/action APIs, filtering out taxobox furniture (range maps, flags, logos) and preferring landscape-oriented images.

- `fetchImageURL(for:)` — checks the disk-backed `cache` first (distinguishing "no entry" from a cached `.some(nil)` meaning "checked, no usable photo"), otherwise calls `reallyFetch` and persists the result so repeat visits across app launches make no network request.
- `reallyFetch(_:)` — the actual three-step fetch: gets the page's media list, filters candidate image titles by extension and against `bannedTitleWords`, batch-queries `imageinfo` for the surviving titles, then picks the first landscape-oriented candidate (or the widest if none are landscape).
- `bannedTitleWords` — a filter list ("logo", "icon", "flag", "map", "range", "distribution") applied to media titles before even requesting their image info, to skip Wikipedia infobox graphics rather than actual photos.
- `loadCache()` / `saveCache()` (private static) — (de)serialize the URL cache to/from a JSON file in Application Support, so resolved (and "no photo found") results survive app relaunches.
- User-Agent header on `session` — set on every request per Wikimedia's API etiquette policy, since omitting it risks throttling/blocking of the app's requests.

---

## WavPlayer (recorded-file review & analysis)

### WavPlayer/BufferDebugStatus.swift
Debug-only `@Observable` model exposing the pan buffer's staged rendering state so it can be drawn as red/green segments on the minimap.

- `readyStart`/`readyEnd`/`hasReady` — bounds of the current detail tile that has actually finished rendering (shown GREEN); `hasReady` false until the first tile of a load/zoom lands.
- `renderingStart`/`renderingEnd`/`isRendering` — bounds of whatever span the in-flight background step is currently computing (shown RED); false during the "cheap recolor" fast path since that never re-reads PCM.

### WavPlayer/CallAnalysis.swift
Bioacoustic call-parameter measurement (peak/characteristic/knee frequency, bandwidth, duration, slope, toe direction) over an arbitrary sample range, generalizing PulseImageRenderer's threshold formulas to a plain selection/marker window.

- `analyze(wavURL:sampleRate:startSample:endSample:...)` — file-based entry point: clamps the span to `maxAnalysisSpanSeconds`, reads PCM via `WavPCMReader`, and delegates to the pure-data `analyze`.
- `analyze(pcm:sampleRate:...)` — the actual measurement pipeline: builds an STFT grid, finds the loudest column/bin, measures duration from a dB-threshold envelope around it, builds the frequency "ridge" (loudest bin per column), and derives all diagnostic values from it.
- `traceExtent(pcm:loSample:hiSample:fineHzPerBin:minBin:maxBin:)` — re-measures Fmax with a short zero-padded FFT window (finer time resolution than the main 512-sample grid) to correct the onset-smearing that under-reads fast frequency sweeps.
- Ridge decomposition (inline in `analyze`) — computes Fmax/Fmin from ridge extremes, extends Fmax leftward up the onset via a low trace floor, finds the knee via max-perpendicular-distance-from-chord ("kneedle") detection, fits a least-squares slope for the call body, and detects a terminal toe by residual-from-trend sign consistency.
- `ridgeFit(_:_:)` — local least-squares slope+intercept helper used for both the knee-toe trend line and the diagnostic body slope.
- Fc/Fk/Sc/toe/quality/points construction (inline) — builds the final `Result`, including annotation `Point`s (Hi f, Peak, Lo f, Fc, Fk) placed at their exact ridge column/sample offsets.

### WavPlayer/CallAnalysisPanel.swift
Displays a `CallAnalysis.Result` for the current manual drag-selection as a fixed-height stat grid, reusing the Detector screen's `StatCell`/panel styling.

- `body` — lays out three rows of `StatCell`s (Peak/Char.Freq/Bandwidth/Duration, Start/End/Sweep/Quality, Knee/Body Sc/Toe) plus a BETA pill that opens an explainer popover; grid stays fixed-size whether or not a result exists so the spectrogram above it never resizes.
- `Values.init(_:)` — maps an optional `CallAnalysis.Result` into display strings, substituting "–" placeholders for every field when there's no result yet.
- `Values.freqString(_:)` — formats a Hz value as either "X.X kHz" or "X Hz" depending on magnitude.

### WavPlayer/CallAnnotationOverlay.swift
Draws the labelled call landmarks (Hi f, Peak, Fc, Fk, Lo f) over the spectrogram at their audio position/frequency, mapped through the current viewport so they track pan and zoom.

- `style(_:)` — per-label color and label-offset direction, roughly matching where each landmark sits on a typical downward FM sweep so labels fall clear of the call.
- `body` — draws a small circle marker at each annotation's screen position plus its label, nudged and clamped on-screen.
- `screenPoint(_:)` — converts an annotation's (sample, freqHz) into a screen `CGPoint` via the viewport's time fraction and `LogFrequencyWarp`'s frequency-to-v-fraction mapping; returns nil if off-window.
- `labelPosition(_:style:)` — nudges the label off the marker by the style's offset, clamped to stay within the view bounds.

### WavPlayer/SilenceMap.swift
Model behind "hide silence" mode: detects non-silent segments in the whole-file overview grid and builds a compressed virtual timeline with silent gaps removed.

- `virtualToReal(_:)` — binary-searches the segment containing a virtual position and maps it back to the corresponding real sample.
- `realToVirtual(_:)` — binary-searches the segment containing a real sample and maps it to virtual; a real position inside a hidden gap collapses to the end of the preceding segment (where the playhead sits during a skipped gap).
- `nextActiveRealStart(after:)` — returns the real start of the next active segment if `r` is inside a hidden gap, else nil (used to skip playback over gaps).
- `realSlices(virtualStart:virtualEnd:)` — returns the real sample ranges (paired with their virtual sub-ranges) covering a virtual span, for stitched tile rendering.
- `compute(grid:nCols:binCount:totalSamples:sampleRate:sensitivity:minFreqHz:padSeconds:)` — detects active columns via `vDSP_vmax` per-bin peak, converts `sensitivity` to a file-relative dB threshold, pads/merges active runs, and quantizes them into real/virtual segments; falls back to a single whole-file segment if nothing clears the threshold.
- `wholeFile(totalSamples:)` — trivial one-segment map representing "nothing hidden", used as the safe fallback.
- `thresholdDB(colPeak:sensitivity:)` — maps a 0...1 sensitivity slider to an absolute dB cut by interpolating between the file's 20th-percentile column peak (quiet floor) and its single loudest column (a definite call), since bat recordings are too sparse for a high percentile to reliably land on signal.
- `percentile(_:_:)` — simple sorted-array percentile lookup used by `thresholdDB`.

### WavPlayer/TickerWheelControl.swift
A horizontal scrolling "ruler" picker control (replacing plain Sliders/VerticalRangeSlider) that snaps to a step as you drag a tick strip under a fixed center pointer.

- `body` — lays out the title, the capsule-clipped `TickerStrip`, a center pointer line, and the formatted current value below.
- `drag` (a `DragGesture`) — `onChanged` computes an accelerated step delta from drag translation and commits `value` on every settled step (not just at release); `onEnded` finalizes and clears the live-drag override.
- `acceleratedSteps(forTranslation:pointsPerStep:)` — converts screen-point translation into fractional steps with mild quadratic acceleration, so fine dragging still gives single-step precision while a longer swipe covers a wide range quickly.
- `TickerStrip.body` — a `Canvas`-based (not per-view) rendering of only the visible tick marks around the current value, with every 5th tick drawn taller/more opaque as a rhythm aid.

### WavPlayer/TwoAxisPinchView.swift
A UIKit `UIViewRepresentable` overlay providing per-axis (not uniform) pinch-to-zoom, since no stock SwiftUI/UIKit gesture recognizer separates horizontal vs vertical finger-separation scale.

- `axisScale(startSeparation:currentSeparation:)` — computes one axis's scale as `pow(currentSeparation/startSeparation, weight)`, where `weight` ramps from 0 (inert, below `axisDeadZonePt`) to 1 (full effect, at `axisFullWeightPt`+) so a near-single-axis pinch doesn't spuriously amplify through a tiny denominator on the other axis.
- `Coordinator.handle(_:)` — the recognizer's state-machine callback: forwards `.began`/`.changed`/`.ended` to the parent closures, but explicitly ignores a `.changed` delivered after a tracked touch has already lifted (UIKit dispatches it after `touchesEnded` nils the touch, which would otherwise compute a bogus scale of 1.0 and overwrite the real zoom right before commit).
- `Coordinator.value(for:in:)` — builds a `TwoAxisPinchValue` (per-axis scale, centroid delta, anchor fraction) from the recognizer's start/current touch points.
- `TwoAxisPinchGestureRecognizer.touchesBegan/Moved/Ended/Cancelled` — tracks exactly two touches, begins the instant the second lands, ends the instant either lifts; a third+ touch is explicitly ignored.
- `isTrackingBoth` — true only while both pinch touches are still down; guards against computing a degenerate scale mid-lift.

### WavPlayer/WavAxisOverlay.swift
Draws time (bottom) and frequency (left) axis ticks/labels over the WAV player's spectrogram at five evenly-spaced fractions of the current viewport.

- `body` — renders five time ticks and five frequency ticks via `ForEach` over `tickFracs`.
- `timeTick(frac:)` — computes the sample/seconds at a given fraction of the viewport and positions a tick+label along the bottom edge, clamped so labels can't spill off-frame.
- `freqTick(frac:)` — computes the Hz at a v-fraction via `LogFrequencyWarp.vFracToHz` (honoring log/linear mode) and positions a tick+label along the left edge, clamped above the time axis's reserved space.
- `formatTime(_:)`/`formatFreq(_:)` — human-readable formatting (ms/s/m:ss for time; k-suffixed for frequency ≥1kHz).

### WavPlayer/WavExport.swift
Bundles a recording's WAV plus a rendered spectrogram PNG into a single `.zip` for the share sheet, using `NSFileCoordinator` instead of a third-party zip library.

- `makeShareItem(wavURL:overview:baseName:)` — stages the WAV (renamed) and optional PNG in a temp directory, then zips it via a coordinated `.forUploading` read and moves the result to app-controlled storage; falls back to the plain WAV URL if any step fails.
- `ShareSheet` — minimal `UIViewControllerRepresentable` wrapper around `UIActivityViewController`, used because the export item is prepared asynchronously rather than upfront (so `ShareLink`'s prepare-eagerly model doesn't fit).

### WavPlayer/WavFileInfoCard.swift
A compact card showing a recording's file facts, read once off the main actor from the WAV's embedded GUANO metadata chunk plus its header/filesystem attributes.

- `body` — renders a `PanelTitle` plus either "No metadata" or a label/value row list, loaded via `.task(id: wavURL)`.
- `loadRows(wavURL:)` — off-main-actor (`Task.detached`) loader that pulls the most useful GUANO fields (Timestamp, Species, Location, Device, App) with sensible key-fallback ordering, then appends sample rate/duration/file size/filename from the WAV header and filesystem.

### WavPlayer/WavMinimapView.swift
A small always-visible strip showing the whole-file overview with a viewport-position rectangle and playhead, doubling as the scrub bar (drag anywhere to seek + recenter).

- `body` — draws the (frequency-cropped) overview image, a rectangle marking the current viewport's time extent, the debug buffer overlay, and the playhead overlay, with a drag gesture for scrubbing.
- `displayImage`/`croppedToFreqRange(_:)` — crops the overview image's vertical extent to match the main spectrogram's current frequency window, so the minimap's height always reflects the current zoom band.
- `scrubGesture(geoSize:)`/`scrub(to:width:)` — a zero-minimum-distance drag (covers tap and drag) that recenters the viewport and calls `engine.seek`, translating through the silence map to a real sample if hide-silence is active.
- `MinimapPlayheadOverlay.body`/`playheadX()` — separate leaf `TimelineView`-driven View (isolated from the parent body to avoid invalidating the scrub gesture at ~20-25Hz) drawing the playback position across the whole file width, mapped through the silence map if present.
- `BufferDebugOverlay.body`/`bar(start:end:color:bottomInset:)` — debug-only leaf View drawing the green "ready" and red "rendering" strips from `BufferDebugStatus`, stacked so both stay visible when overlapping.

### WavPlayer/WavPlayerDebugLog.swift
Toggleable diagnostic logging for the WavPlayer feature, compiled to nothing in Release builds so it's safe to leave in permanently.

- `log(_:_:)` — prints a category-tagged message if `isEnabled`, using an `@autoclosure` so the string interpolation is skipped entirely (not just the print) when disabled.
- `time(_:_:_:)` — runs a closure, logging its wall-clock duration in ms; used for profiling any non-realtime unit of work (file scans, FFT passes, colorize loops), deliberately never used in the audio pacing/per-buffer hot paths.

### WavPlayer/WavPlayheadOverlay.swift
Draws the current playback position as a vertical line over the spectrogram's current viewport, as a separate leaf View to isolate its ~20-25Hz update rate from the parent body.

- `body` — a `TimelineView`-driven `Rectangle` positioned at the computed playhead X, hidden entirely when the playhead is off-window.
- `playheadX(width:)` — while playing and the viewport isn't clamped at a file edge, pins the line to the exact screen center (so the spectrogram scrolls beneath a stationary line instead of a jittery derived position); otherwise computes the true position from `engine.currentTimeSeconds`, mapped through the silence map if present.

### WavPlayer/WavTuningControl.swift
Inline heterodyne/RTE tuning plus display options (log scale, noise floor, hide-silence + its sensitivity/padding) shown via a toolbar popover, without leaving the player.

- `body` — a form of Toggles/Sliders bound directly to `RTESettings` (via `@Bindable`) and the passed-in display bindings; includes a "Reset to defaults" button calling `rteSettings.reset()`.

### WavPlayer/WavViewport.swift
The current visible time/frequency window in `WavSpectrogramView`, plus the pure (unit-testable) geometry math for turning gestures or ticker-wheel input into a new viewport.

- `WavViewport.wholeFile(totalSamples:maxFreqHz:)` — constructs a viewport spanning the entire file/frequency range.
- `visibleFracRange(scale:offset:)` — inverts the `screen(v) = 0.5 + (v-0.5)*scale + offset` identity to recover the visible `[left, right]` fraction of the committed viewport for a given live scale/offset.
- `resolvedViewport(committed:timeScale:timeOffset:freqScale:freqOffset:totalSamples:nyquistHz:)` — the core function turning live gesture state (pan and/or pinch, per axis) into a new clamped viewport; clamps both edges of each axis together (never independently) to avoid silently shrinking the span when a drag pushes past a file/frequency boundary.
- `sampleSpan(forZoomFraction:totalSamples:)`/`zoomFraction(forSampleSpan:totalSamples:)` — log-scale mapping between a 0...1 "zoom slider" fraction and an actual sample span (and its inverse), since the usable zoom range spans many orders of magnitude.
- `viewportForTimeZoom(committed:zoomFraction:totalSamples:)` — computes a new viewport at a given zoom fraction, keeping the current center sample fixed (what the Zoom ticker drives).
- `viewportForFreqZoom(committed:spanHz:nyquistHz:)` — computes a new viewport at a given frequency span, keeping the current center frequency fixed (what the Range ticker drives), replacing the old absolute two-thumb trim slider.
- `timeFitScale(viewport:totalSamples:)`/`freqFitScale(viewport:nyquistHz:)` — the scale that exactly fits a viewport within the whole file on one axis; used as the gesture's "1×" reference and to decide whether the overview alone is sharp enough.

### WavPlayer/WavSpectrogramEngine.swift
Offline, static spectrogram rendering pipeline for the whole-file WAV player — one shared raw-grid + colorize pipeline drives both the whole-file overview and zoomed-in detail tiles.

- `renderRawTile(wavURL:startSample:endSample:targetColumns:)` — the expensive half: reads PCM and runs the pooled STFT (`STFTGrid.streamPooledGridFromFile`) over an arbitrary span, then reports the ACTUAL covered end sample (short of the naive request by up to one window) so display crops map exactly to CallAnalysis's own frame math.
- `colorize(_:sampleRate:minFreqHz:maxFreqHz:palette:noiseFloor:)` — the cheap half: crops a raw tile to a frequency range, tracks a per-column decaying "AGC ceiling" (so one loud burst in a tile can't crush contrast elsewhere), gates by noise floor, and colorizes via a precomputed LUT using fused vDSP linear maps instead of a per-pixel loop (this used to be the single largest cost in the whole pipeline).
- `renderDetailTile(wavURL:sampleRate:startSample:endSample:minFreqHz:maxFreqHz:targetColumns:palette:noiseFloor:)` — convenience wrapper composing `renderRawTile` + `colorize` for one-shot callers (tests); `WavSpectrogramView` calls the two steps separately so it can skip the expensive one on a noise-floor/palette-only change.
- `renderRawTileStitched(wavURL:virtualStart:virtualEnd:map:targetColumns:)` — renders a detail tile for a span of the SilenceMap's compressed virtual timeline by rendering each underlying real slice separately (proportionally sized) and concatenating their columns, standing in silence-floor columns for any slice too short for one STFT window.
- `compressedOverviewRawTile(from:map:)` — builds the compressed-timeline overview raw grid by pure column selection from an already-computed whole-file grid (no file IO/FFT), dropping the silent gaps' columns.
- `renderOverview(wavURL:maxWidth:palette:noiseFloor:)` — renders a whole-file overview (a RawTile pooled to `maxWidth` columns, colorized once for the initial paint), bounded regardless of file length.

### WavPlayer/WavPlayerView.swift
The rebuilt WAV player screen — composes the static zoomable spectrogram, minimap/scrub bar, call-analysis stats panel, and heterodyne/RTE tuning around the shared `PlaybackEngine` and transport controls.

- `displayOverview` — the overview all display consumers use: the compressed one while hide-silence is active, the real one otherwise; everything downstream (viewport, tiles, tickers) works in whichever domain this is in.
- `effectiveNoiseFloor` — squares the stored 0...0.9 noise-floor slider value before use as `colorize`'s gate, since measured norm values put the noise band and weakest calls close together, making a linear slider clip calls by mid-travel.
- `shareRecording()` — prepares the export item (WAV+PNG zip) off the main actor via `WavExport.makeShareItem`, then presents the share sheet.
- `body` — switches between `landscapeLayout`/`portraitLayout` based on vertical size class, wires up the toolbar (Select Region, hide-silence, tuning popover) and a long list of `.onChange` handlers driving debounced band-sync, recolor, silence-map rebuild, playhead follow, and call analysis.
- `portraitLayout`/`landscapeLayout` — the stacked single-column vs. two-column (spectrogram+controls left, stats+metadata right) layouts.
- `spectrogramSection` — the panel-carded `WavSpectrogramView` + `WavPlayheadOverlay` stack, with loading/error states for the overview render.
- `scheduleBandSyncDebounced()`/`syncBandFromViewport()`/`applyBand()` — debounces recomputing the heterodyne/RTE processing band (`bandLow`/`bandHigh`) from the viewport's current frequency window on every viewport change, since recomputing filter coefficients per drag frame is real, avoidable work.
- `scheduleRecolorDebounced()`/`recolorOverviewIfPossible()` — debounces and then recolors `overview.image` (and the compressed overview's image) in place from the already-resident raw tile on a noise-floor/palette change, generation-guarded against overlapping recolors racing.
- `load()` — kicks off `renderOverview` off the main actor, then on success sets a half-zoomed default viewport (rather than whole-file, which shows no usable call detail) and rebuilds the silence map if hide-silence is persisted on.
- `scheduleSilenceRebuildDebounced()`/`rebuildSilenceMap()` — builds or tears down the compressed hide-silence timeline to match the toggle/sensitivity/padding, preserving the centered real sample across the domain switch; suspended entirely while playing (playback runs on the real, linear timeline).
- `startFollowingPlayhead()` — a ~30Hz loop that recenters `viewport` on the playback position while playing (letting detail renders stay cheaply overview-cropped during scroll), and skips the engine past hidden silence gaps when hide-silence is on.
- `recenter(sample:)` — recenters the viewport on a display-domain sample, preserving span and clamping both edges together at file bounds.
- `requestAnalysis(startSample:endSample:minFreqHz:maxFreqHz:)` — maps a display-domain selection to the real sample range, floors the analysis frequency to exclude rumble, and runs `CallAnalysis.analyze` off the main actor, generation-guarded, mapping resulting landmarks back into annotations in the display domain.
- `MinimapTimeLabel.body`/`timeString(_:)` — separate leaf View (same ~20-25Hz isolation reason as the playhead overlay) showing elapsed/duration text under the minimap.

### WavPlayer/WavPlayheadOverlay.swift
(See above — listed once; duplicate heading intentionally omitted.)

### WavPlayer/WavSpectrogramView.swift
The whole-file, static, two-axis zoomable spectrogram — the core interactive view of the WAV player, replacing the old live-scrolling Metal SpectrogramView with a tile-rendered, gesture-driven navigable view of the entire recording.

- `body` — a `GeometryReader` stack of the image layer, selection overlay, axis overlay, call annotations, the `TwoAxisPinchView` overlay (pan mode only), and the unified pan/select gesture; wires up `.onChange` handlers for viewport, playing state, noise floor, palette, overview image, log-frequency toggle, and silence map changes.
- `spectrogramImageLayer(geoSize:)` — renders whichever image `currentSourceImage()` picks (falling back to plain black), applying `.resizable()`/`.interpolation(.high)` since a mixed `Image`/`Color` `Group` can't share that modifier chain.
- `tileCovers(_:start:end:minHz:maxHz:)` — checks whether a cached detail tile's (margined) bounds fully contain a requested time/frequency rectangle, allowing a live pan within the tile's margin to crop straight from it instead of falling back to the overview.
- `currentSourceImage()` — picks the detail tile (cropped) if it covers the live/committed range, else falls back to cropping the whole-file overview image; the single source-of-truth for what's actually displayed.
- `liveViewport()`/`liveSampleRange()`/`liveFreqRangeFromPan()` — computes the viewport implied by ALL live (uncommitted) gesture state (pan + pinch scale/offset) via the shared `WavViewportMath.resolvedViewport`, used both for live display and eventually baked in by `commitPan`.
- `displayedImage(source:)`/`rebuildWarpedImage()` — applies the log-frequency warp (`LogFrequencyWarp.warp`) to whichever source image is current; cached (`warpedDisplayImage`) at rest, computed live only during interactive dragging when the source itself changes every frame.
- `crop(image:imageStartSample:imageEndSample:imageMinHz:imageMaxHz:cropStart:cropEnd:minHz:maxHz:)` — general-purpose CGImage crop from a known source rectangle (either the overview or a detail tile) down to a requested time/frequency sub-rectangle.
- `scheduleDetailRenderDebounced(for:)` — debounces `scheduleDetailRender` by 0.15s for any trigger (viewport settle, noise-floor/palette change), since undebounced viewport writes could otherwise spawn hundreds of redundant renders per drag.
- `scheduleDetailRenderThrottled()` — during playback scroll (where the debounce never fires because motion never stops), fires a render periodically (leading if enough time passed, else one trailing render) so a fresh tile stays resident through the scroll.
- `scheduleGestureCommit(after:)`/`commitPan()` — schedules, then performs, baking the live pan+pinch offsets/scales into a new committed `viewport` via `resolvedViewport`, resetting all live gesture state and flagging an immediate (non-debounced) render if the viewport actually moved.
- `scheduleDetailRender(for:isPrefetch:)` — the single entry point for fetching a detail tile for any trigger (pan commit, ticker, prefetch, or noise-floor/palette change); first checks whether the cached raw tile is still dense enough to just recolor (`rawStillSharpEnough`) before falling through to a full staged re-render with a time margin biased toward the direction of recent movement.
- `renderChunkedStep(myGeneration:isPrefetch:target:currentStart:currentEnd:finalStart:finalEnd:)` — recursively renders the desired margined tile in `chunkSeconds`-sized steps, displaying the visible frame first (fastest) and growing outward toward whichever side has more remaining distance, so nothing waits for the whole buffer to finish before something sharper than the overview appears; abandons the whole chain if superseded by a newer render generation.
- `maybePrefetchTile()` — checks whether the live pan position has drifted close to the edge of the cached tile's margin and, if so and not already in flight, kicks off a background re-centered render before the margin actually runs out.
- `needsDetailTile(viewport:overviewTotalSamples:overviewWidth:overviewHeight:nyquistHz:targetColumns:)` — decides whether the overview's own pooled column/row density is already too coarse for the current viewport on EITHER the time or frequency axis, warranting a fresh detail-tile render.
- `pinchBegan()`/`pinchChanged(_:)`/`pinchEnded()` — wires `TwoAxisPinchView`'s callbacks into live scale/offset state (with anchor-preserving offset math) and commits the pan on pinch end.
- `panGesture(geoSize:)` — the unified single `DragGesture` handling both pan-with-momentum and tap-to-seek (deliberately not a `SimultaneousGesture`, which was the diagnosed cause of a momentum "stops dead" bug); tracks axis-locking, rebases translation baselines across new touches and post-pinch lingering fingers, self-tracks velocity for momentum seeding (instead of `predictedEndTranslation`), and scales coast distance down at deeper zoom levels.
- `selectGesture(geoSize:)` — the equivalent unified gesture for selection mode: drags define a time+frequency `AnalysisBox` (mapped through the log/linear frequency warp), and a tap clears the current selection instead of seeking.
- `SelectionOverlay.body` — draws the translucent rectangle for a manual (or live) analysis selection box, mapped through the viewport and frequency warp.

---

## Upload / Consent / Location / Onboarding

### Upload/AnonymizedUploadBuilder.swift
The single anonymization boundary that turns a raw recording's metadata/location/timestamp into the non-personal-data form actually sent to the server, and mints the object identity it's stored under.
- `AnonymizedUpload` (struct) — the fully-anonymized wire payload (object id/key, snapped coordinate, bucketed time, GUANO chunk, headers); deliberately has no device id field so one can't be added by accident.
- `build(originalFields:recordedAt:fallbackCoordinate:species:confidence:cutoffHz:quality:)` — the single entry point running every anonymizing step (location snap, timestamp bucket, GUANO allowlist filter, header assembly, object key mint) in one auditable place.
- `snapToGrid(_:)` — rounds a coordinate to a ~100 m grid cell, deterministic (not jitter) so it clusters many recordings onto identical points for k-anonymity-style protection.
- `anonymizedCoordinate(originalFields:fallback:)` — parses `Loc Position` from GUANO or falls back to the caller-supplied coordinate, then always snaps it; drops anything unparseable rather than forwarding it raw.
- `formattedCoordinate(_:)` — formats a coordinate to 3 decimals only, matching the grid so the string can't imply more precision than it has.
- `sanitizedHardwareName(_:)` — strips serial-number-shaped substrings (S/N markers, long digit/hex runs) from the mic's reported `Make`/`Model` so a badly-behaved microphone can't leak a per-unit identifier.
- `bucketedTimestamp(_:)` — floors (never rounds) a timestamp to a 5-minute bucket so the contributed time can't precede the true capture.
- `guanoChunk(from:)` — builds the final GUANO byte chunk in a fixed field order (not source order), so field ordering itself can't become a device fingerprint.

### Upload/AppDelegate.swift
Minimal `UIApplicationDelegate` whose sole job is catching iOS's background-URLSession relaunch event for finishing interrupted uploads.
- `application(_:handleEventsForBackgroundURLSession:completionHandler:)` — stashes the OS completion handler and reactivates `RecordingUploader.shared` so it can pick back up (or reconcile) any in-flight background transfer.

### Upload/FLACEncoder.swift
The real `LosslessAudioEncoder` implementation, wrapping libFLAC (vendored XCFramework) to losslessly compress the anonymized 16-bit mono WAV before upload.
- `encode(wavURL:outputURL:)` — reads the WAV header, configures a libFLAC stream encoder (mono/16-bit/matching sample rate), attaches a Vorbis comment block built from the file's already-anonymized GUANO, then streams PCM through it in blocks and finishes the file.
- `makeVorbisComment(from:)` — converts GUANO `Namespace|Key` fields into libFLAC Vorbis comment entries, sorted by key so byte-identical metadata always produces a byte-identical comment block (no dependence on Dictionary iteration order).

### Upload/HighPassPrivacyFilter.swift
Irreversible cascaded high-pass filter applied only to the transient upload copy, to strip human speech before contribution — never applied to the on-device original.
- `init(sampleRate:cutoffHz:)` — builds a cascade of 4 identical biquad high-pass sections (≈48 dB/octave combined) rather than one gentle section, making the speech removal a hard guarantee rather than a mild tilt.
- `process(_:)` — filters a PCM block in place, carrying biquad state across calls so a recording can be streamed through in chunks without producing an audible click/spectral artifact at each block boundary.

### Upload/LosslessAudioEncoder.swift
Protocol abstraction over "encode 16-bit mono WAV → FLAC," kept separate from the concrete libFLAC call site so the encoder backend is a one-line swap if ever needed.
- `encode(wavURL:outputURL:)` — the single required method; conforming types (only `FLACEncoder` today) do the actual synchronous encode work off the main actor.

### Upload/QualityGate.swift
Streaming SNR/clipping/pulse-count check on the upload copy, deciding reject-vs-allow before a recording is queued for upload (never touches the on-device original).
- `Accumulator.add(_:)` — feeds one PCM block into a fixed 32,768-bucket histogram of sample magnitudes, avoiding ever holding a whole long recording (hundreds of millions of samples) in memory for sorting.
- `Accumulator.result(pulseCount:)` — computes SNR/clipping from the histogram and combines with an externally-supplied pulse count to produce the pass/fail `UploadQualityGateResult`.
- `estimateSNRdB()` — crude proxy: ratio (in dB) of the mean power of the loudest 5% of samples to the median sample's power, standing in for a real noise-floor-vs-signal measurement this stage can't do.
- `power(atRank:)` / `meanPowerOfLoudest(_:)` — histogram-based order-statistic lookups that replace what used to require sorting the entire sample array.
- `clippingFraction()` — fraction of samples at or above the near-full-scale bucket (0.999 normalized), matching the old per-sample `>= 0.999` test exactly.

### Upload/RecordingUploader.swift
Singleton orchestrator for the whole upload pipeline: consent check → conversion → FLAC encode → background URLSession PUT → cleanup, reporting status back to `ClassificationStore` at every phase.
- `activate()` — called once at launch; reconciles pending uploads against the background session's live tasks, dropping/reporting-failed anything orphaned by a previous process death, then purges stale derived-copy files.
- `cancelAllUploads()` — clears bookkeeping *before* cancelling tasks (so the resulting delegate callbacks find nothing to report), used ahead of a full consent erasure so nothing can land in R2 after server-side erase.
- `cancelUpload(recordingID:)` — cancels the in-flight transfer for one deleted recording so it can't finish uploading after local deletion.
- `purgeOrphanedDerivedCopies()` — removes derived-copy files in Caches that no pending upload references and that are older than a grace window (avoids racing a conversion still in progress).
- `handleRecordingSaved(...)` — the eligibility gate: checks consent, max duration, NoID/low-confidence species, and Worker configuration; only actually converts+encodes+uploads when `forceAttempt` is true (i.e. an explicit user tap), otherwise just marks the recording `.queued`/`.notContributing`/`.rejected`.
- `retryFailedUploads()` — re-attempts only recordings left `.failed` (not merely `.queued`) when Wi-Fi returns, since `.failed` implies the user already asked to send it.
- `uploadNow(_:)` — the actual trigger path from the Playback row's upload badge; re-checks current consent (not whatever it was when recorded) and force-attempts the upload.
- `report(_:_:)` / `flushBufferedReports()` — funnels status updates onto the main actor, buffering them if `classStore` isn't wired up yet (common after a background relaunch with no UI).
- `upload(recordingID:flacURL:anonymized:)` — builds the PUT request, attaches the device id header (used server-side only to check consent, then discarded) and bearer token, copies over the already-anonymized headers, applies a random `earliestBeginDate` jitter (up to 10 min) to decouple upload time from capture time, and starts the background upload task.
- `loadPendingUploads()` / `persistPendingUploadsLocked()` — persist the in-flight-upload-to-recording map to Application Support (not Caches) as JSON so a killed/relaunched process can still resolve a delegate completion callback to a Recording.
- `urlSession(_:task:didCompleteWithError:)` (delegate) — on completion, always discards the derived copy, reports `.uploaded` on 2xx, and on 401/403 distinguishes "needs reconsent" from "needs a consent sync retry" (checked on the main actor) rather than reporting a generic failure.
- `urlSessionDidFinishEvents(forBackgroundURLSession:)` — signals iOS's stashed background completion handler, required for background URLSession uploads to be considered finished by the OS.

### Upload/UploadClient.swift
Thin, stateless endpoint/URL builder for the Worker's `PUT /upload` route.
- `uploadURL(objectKey:)` — appends the anonymizer-produced object key to the configured base URL; deliberately does not assemble or modify the key itself, so there's only one place (the builder) where a key can be constructed.

### Upload/UploadConversionPipeline.swift
Builds the transient, filtered, anonymized upload copy of a recording (the audio/IO half of upload prep); every privacy decision itself is delegated to `AnonymizedUploadBuilder`.
- `convert(originalWavURL:context:)` — two-pass streaming conversion: pass 1 runs the quality gate cheaply (no filtering/writing) so a rejected recording is never filtered or written out; pass 2 (only if it passes) builds the anonymized metadata and streams filter+encode to a new derived WAV.
- `streamSamples(from:totalSamples:_:)` — shared block-streaming reader used by both the quality-gate pass and the write pass, stopping cleanly on a short read near EOF instead of throwing.
- `discardDerivedCopy(at:)` — deletes a derived (pre-FLAC) file; called on upload success or on any failure partway through, never touching the original recording.
- `writeDerivedWav(sourceURL:totalSamples:sampleRate:filter:guano:)` — streams source PCM through the high-pass filter to a new WAV file a block at a time, patching the header's size fields at the end in case the source read short.

### Upload/UploadQueueView.swift
Read-only status list of recordings that have actually been through an upload attempt; not itself a place uploads are triggered.
- `grouped` (computed) — buckets recordings into Uploading/Uploaded/Failed/Not Eligible sections by their `UploadStatus.phase`, filtering out empty sections and excluding queued/not-contributing recordings (those are shown as a Playback row badge instead).
- `UploadQueueRow.statusBadge` — renders the phase-appropriate trailing UI (spinner + label while in progress, checkmark when uploaded, failure/rejection reason text otherwise).

### Upload/UploadStatus.swift
Per-recording upload lifecycle state persisted on `Recording`, letting the UI show real pending/uploading/failed status instead of a fire-and-forget pipeline.
- `Phase` (enum) — the state machine: notContributing → queued → converting → encoding → uploading → uploaded, or rejected (permanent, bad input) / failed (transient, retryable).
- static factory properties/functions (`.converting`, `.queued(_:)`, `.failed(_:)`, etc.) — computed rather than stored constants specifically so each call gets a fresh `updatedAt` timestamp instead of one frozen at first use.
- `isRetryEligible` — true only for `.failed` recordings under the retry cap; `.queued` is deliberately excluded since it merely means "eligible," not "the user asked to send this."
- `hasExhaustedRetries` — true once automatic retries have hit the cap, so the UI can say only a manual tap will help rather than appearing to still be trying.

### Consent/ConsentAPIClient.swift
Stateless HTTP client for the Cloudflare Worker's consent endpoints; the local Keychain record (`ConsentStore`) remains the source of truth, this only mirrors it server-side.
- `push(_:deviceID:)` — POSTs the consent record, returns whether the Worker actually confirmed it (rather than the old fire-and-forget approach that silently lost offline changes), and persists the one-time-issued device API token on first registration.
- `authorize(_:)` — attaches the device's bearer token to a request when one exists; required by every route except first registration.
- `coarseTimestamp(_:)` — rounds a consent timestamp down to the hour before it ever leaves the device, closing a residual timing-correlation join between the consent database and object creation times in storage.
- `eraseConsentRecord(deviceID:)` — DELETEs the device's consent row outright (distinct from merely revoking); does not and cannot touch already-contributed recordings, since those carry no device identifier at all.
- `fetchStatus(deviceID:)` — GETs current consent status for a device; used server-side conceptually by upload gating (the actual gate lives in the Worker, this is the client-side accessor).

### Consent/ConsentStore.swift
The single observable, Keychain-persisted source of truth for whether this device may currently upload recordings, versioned against the current consent wording.
- `ConsentRecordStorage.read()/write()/delete()` — raw Keychain persistence for the consent record, usable off the main actor and accessible while the device is locked (`kSecAttrAccessibleAfterFirstUnlock`), shared by both `ConsentStore` and the background `ConsentSync`.
- `isGranted` (computed) — true only when status is `.granted` AND the stored `consentVersion` exactly matches `currentConsentVersion`; fails closed so consent to old wording never silently authorizes uploads under new terms.
- `needsReconsent` (computed) — true when the user previously granted consent under wording that has since changed materially, surfaced so the UI can explain and re-prompt rather than just silently stopping uploads.
- `isAwaitingServerConfirmation` (computed) — true when the local decision hasn't yet been confirmed 2xx by the Worker, so Settings can show a withdrawal/grant as still in flight.
- `grant()` / `revoke()` — write a new record (with `syncedAt` cleared) and kick off `ConsentSync.syncIfNeeded()`; revoke also creates a record from nothing so "explicitly declined" is distinguishable from "never asked."
- `apply(_:)` — the shared private mutator: clears `syncedAt` optimistically-never (i.e. always unconfirmed until the server actually confirms), persists to Keychain, and triggers a sync.
- `eraseConsentRecord()` — fences in-flight uploads and consent syncs first (to close a race where a stale request could resurrect what's about to be deleted), calls the Worker to delete the D1 row, then clears local Keychain state and rotates the device identity so nothing future can be correlated to the erased id; returns false (leaving all state untouched) if the network call fails.

### Consent/ConsentSync.swift
Background reconciliation making the server-side consent mirror eventually consistent, since a naive fire-and-forget push could silently lose an offline grant or revoke.
- `suspend()` / `resume()` — blocks new pushes and waits (bounded, ~5s) for any in-flight one to finish, so an erasure can't be immediately undone by a stale push re-creating the just-deleted D1 row.
- `start()` — begins a one-time `NWPathMonitor` (idempotent) that retries syncing whenever connectivity returns, and attempts one immediately.
- `pushIsDue(_:)` — a push is due either because the record itself is unconfirmed, or because this device still lacks an API token (the migration path for devices registered before tokens existed).
- `syncIfNeeded()` — self-deduplicating (via `beginSyncing()`/`endSyncing()`) background task with exponential backoff (2s→120s, 6 attempts) that re-reads the record before each attempt and before confirming success, so a decision made mid-retry is never overwritten by a now-stale confirmation.

### Consent/DeviceIdentity.swift
App-controlled device identifier (independent of `identifierForVendor`) plus its server-issued API token, both persisted in the Keychain so they survive reinstall.
- `current` (computed) — returns the persisted UUID string, generating and storing one on first access if none exists yet.
- `currentToken` (computed) — the Worker-issued bearer token for this device, if registered; required (alongside the device id) on every upload and erasure request.
- `storeToken(_:)` — persists the one-time-issued token after first successful `POST /consent`.
- `regenerate()` — replaces the device id with a fresh UUID and drops the old token, called only after a successful consent erasure so no future activity can be linked back to the erased identity.

### Consent/EraseDataConfirmationView.swift
Type-to-confirm gate ("DELETE") in front of `ConsentStore.eraseConsentRecord()`, since deleting the consent record is irreversible and rotates the device identity.
- `erase()` — runs the erase call, then on success clears local upload-status badges (since the rotated device id can no longer meaningfully claim those contributions) and shows a result message before dismissing; on failure shows an explicit "nothing was deleted" message and leaves all state untouched.

### Location/LocationProvider.swift
`@Observable` CoreLocation wrapper providing both a session's GPS breadcrumb track and one-shot region fixes for feature suggestions.
- `accuracyAuthorization` (computed) — exposes iOS's per-app Precise Location toggle; read elsewhere (though the upload pipeline now fuzzes location unconditionally regardless of this).
- `requestAuthorizationDecision()` — requests when-in-use authorization and suspends (via `CheckedContinuation`, with a 60s safety timeout) until the OS dialog is actually resolved, so onboarding's soft-ask screen doesn't advance before the real prompt is answered.
- `resumeAuthorizationContinuation(with:)` — the single path every resume goes through, guaranteeing a continuation is never double-resumed (a crash) or dropped.
- `requestRegionFix()` — lightweight one-shot fix for region-based suggestions; only ever requests when-in-use (never escalates to Always) and no-ops while continuous tracking is already running.
- `requestCoarseLocation()` — temporarily relaxes `desiredAccuracy` to kilometre-scale so `requestLocation()` returns an immediate cheap fix instead of waiting tens of seconds for a GPS-grade one a region decision doesn't need.
- `startTracking(geocodeSessionID:)` / `stopTracking()` — begin/end continuous course recording for an active session, escalating to Always authorization so tracking continues with the phone locked.
- `beginUpdates()` — restores strict accuracy, conditionally enables background location updates (only if the `location` UIBackgroundMode is actually declared, to avoid a runtime crash), and starts continuous updates.
- `locationManagerDidChangeAuthorization(_:)` — reacts to authorization changes: resumes any pending continuation, fires a deferred region-fix request, and escalates/starts tracking updates as appropriate.
- `locationManager(_:didUpdateLocations:)` — filters incoming fixes by accuracy and staleness thresholds (stricter while actively tracking, looser for one-shot region fixes), updates `currentCoordinate`, and while tracking throttles breadcrumbs to ~5 m/~3 s and triggers reverse-geocoding of the session title.
- `geocodeTitleIfNeeded(_:)` — reverse-geocodes only the first good fix of a session into a human-readable place name for the session title.

### Onboarding/ConsentView.swift
The load-bearing consent screen (shown at onboarding and reachable from Settings) whose copy is the actual disclosure the "uploads are not personal data" claim rests on.
- `canContribute` (computed) — both research-use and funding-use toggles must be explicitly switched on (never pre-ticked, never persisted across screen visits) before contributing is enabled, satisfying explicit-consent requirements (GDPR/PIPEDA/Law 25).
- `irreversibilityCallout` — a visually distinct callout stating that, because nothing links a recording back to the user, a sent recording can never be deleted from the research dataset — deliberately given more visual weight than a plain bullet.
- `consentControls` — the two required toggles (research use, funding/licensing use) plus the "Start Contributing" (grants and calls `onDecided`) and "Not Now" (revokes and calls `onDecided`) buttons.

### Onboarding/OnboardingState.swift
Tiny `@Observable` flag tracking whether first-run onboarding has completed, deliberately not `@AppStorage` to avoid whole-root-view invalidation on unrelated `UserDefaults` writes.
- `hasCompletedWelcome` (stored property with `didSet`) — the only piece of state; setting it also persists to `UserDefaults`, and because it's tracked via `@Observable` rather than `@AppStorage`, unrelated preference writes elsewhere no longer force the root view (and every store it constructs) to rebuild.

### Onboarding/OnboardingView.swift
First-run flow (welcome → mic → location → consent → autoID → done) that gates every OS permission prompt behind an explanatory screen shown first.
- `content` (computed, `@ViewBuilder`) — renders the copy/imagery for the current step; the `.consent` step embeds `ConsentView` directly rather than generic step copy, since that step drives its own buttons.
- `controls` (computed) — suppresses the shared bottom "primary" button entirely on the `.consent` step, since `ConsentView` supplies its own two actions.
- `allComplexes` (computed) — collects all species complexes across every bundled model, deduplicated by name (the same complex can recur per-region/per-model) for the AutoID explainer step.
- `advance()` — drives the step machine; for `.mic` it awaits `AVAudioApplication.requestRecordPermission()`, for `.location` it awaits `LocationProvider.requestAuthorizationDecision()` then fires `requestRegionFix()`, disabling the button (`isAwaitingPermission`) for the duration so a double-tap can't double-request or race the transition.
- `firstSentence(of:)` — trims a species-complex note down to its leading sentence for the compact AutoID explainer cards.
- `OnboardingStepView` — shared centered icon/title/message header reused by every onboarding step (and by `ConsentView`) for visual consistency.
- `appIconImage` (computed) — resolves the real app icon bitmap from `Info.plist`'s `CFBundleIcons` (rather than a fixed asset name) for the welcome screen's logo.

### Onboarding/SafariView.swift
`UIViewControllerRepresentable` wrapper presenting an in-app Safari View Controller sheet, used by both `OnboardingView` and `ConsentView` for privacy-notice links.
- `makeUIViewController(context:)` — constructs the `SFSafariViewController` for the given URL; `updateUIViewController` is an intentional no-op since the URL never changes after presentation.
- `PrivacyLinks` (enum) — canonical URLs for the formal privacy policy (also given to App Store Connect), the shorter plain-language explainer, and the help page.

---

## Tests & backend Worker

### OpenBatTests/AnonymizedUploadBuilderTests.swift

Tests `AnonymizedUploadBuilder`, the component responsible for stripping identifying data from a recording before it is contributed to the shared dataset — the evidence backing the app's claim that uploads are not personal data.

- **Identifier scrubbing**: a sweep test (`noIdentifierSurvivesAnywhere`) scans the entire serialized upload (GUANO chunk, object key, headers) for device IDs, display names, precise filenames/session labels, and precise coordinates, asserting none survive; a companion test confirms unknown/future GUANO fields are dropped by default (allowlist, not blocklist) while legitimate scientific fields (species, confidence, pulse count, sample rate, etc.) do survive.
- **Location anonymization**: coordinate snapping to a coarse grid, deterministic and collapsing nearby points together, applied consistently whether the position comes from GUANO or a fallback coordinate, with unparseable positions dropped rather than forwarded, and the emitted GUANO field and HTTP header always agreeing.
- **Timestamp bucketing**: recorded time is floored (never rounded forward) to a 5-minute bucket, and the emitted timestamp reflects the bucketed value, not the source's precise one.
- **Object identity**: the generated object key matches the Worker's expected `{date}/{uuid}.flac` pattern, its date agrees with the bucketed timestamp, and a fresh random object ID is minted per build (not a stable/idempotent identifier).
- **Hardware name sanitizing**: serial-like tokens (S/N, SN:, #, long digit runs) are stripped from microphone/model names while legitimate model numbers (e.g. "iPhone15,2") are preserved; an entirely-serial name becomes "unknown" rather than empty.
- **Headers**: only an allowlisted set of headers is produced, and none ever carry a device or recordist identifier.

### OpenBatTests/CallAnalysisTests.swift

Tests `CallAnalysis.analyze`, the pure-data call-measurement routine that derives peak/characteristic/start/end frequency, duration, sweep rate, and quality from a raw PCM buffer, using synthetic signals with known ground truth.

- **Tone burst measurement**: a short tone burst padded with near-silence yields correct peak frequency, plausible duration, near-zero sweep rate, and non-trivial quality.
- **Chirp measurement**: a linear FM sweep with a flat tail correctly recovers start/end frequency (within STFT edge-smearing tolerance), a sharp characteristic frequency from the flat tail, a negative sweep rate for a downward sweep, and consistent min/max/bandwidth values.
- **Noise and edge cases**: broadband noise scores low quality; a selection shorter than one STFT window returns nil; pure silence still returns a result (not nil) with quality reading as exactly zero rather than crashing or producing a false-confident measurement.

### OpenBatTests/ClassificationLoggerTests.swift

Regression tests for `ClassificationLogger`'s CSV column layout, guarding against a bug where score columns were hardwired to one model's class list and scores from other models were silently logged as 0.0000.

- **Header shape**: the header is the fixed metadata columns followed by the union (deduped, sorted) of every registered model's class codes, independently recomputed from `ModelRegistry.all` and compared against `expectedHeader`.
- **Coverage**: every registered model's class codes are confirmed present in that header union.
- **Row population**: a `makeRow` call correctly fills the `model` column (the bug's blind spot), aligns each model's score values under the matching class-code column, and zero-fills every other class column.

### OpenBatTests/ClassifierSpectrogramEngineTests.swift

Property tests for `ClassifierSpectrogramEngine`, the shared STFT→denoise→normalize→resize→colorize pipeline that turns raw PCM into the tensor each classifier's CNN expects, covering both the NABat (dB/min-max/magma) and BatDetect2 (PCEN/grayscale) rendering specs.

- **Contract**: input shorter than one FFT window returns nil.
- **NABat path**: output has the expected shape and channel count (3, magma), stays bounded to [0,1] and finite, and its detected peak-time fraction both lands near a centered burst and correctly shifts earlier/later as the burst's position changes.
- **BatDetect2/PCEN path**: output has the expected shape and channel count (1, grayscale); the PCEN recursion (the most intricate numeric port in the app) produces finite, non-flat output for a real tone and stays finite (no NaN/Inf) even for all-zero silent input.

### OpenBatTests/ConsentVersionTests.swift

Tests the consent-versioning decision logic mirrored from `ConsentStore.isGranted`/re-consent rules, exercised directly against `ConsentRecord` values since the real store is a Keychain-backed singleton.

- **Granting**: a record granted at the current consent version is accepted and doesn't need re-consent; a granted record at an older *or* newer version is not live consent and does require re-consent (exact-version match, not "at least this version").
- **Non-granting**: a revoked record is never granted regardless of version, and revoked/absent records never trigger a re-consent prompt (no nagging someone who already declined).
- **Invariants**: "granted" and "needs reconsent" are mutually exclusive across all status/version combinations; re-granting at the current version clears the reconsent flag; and the app's `currentConsentVersion` constant is pinned to `"2.0"` with a comment tying it to the Worker's `CURRENT_CONSENT_VERSION`, which must be bumped in the same deploy.

### OpenBatTests/PlaybackEngineTests.swift

Drives `PlaybackEngine` end-to-end (load → play → wait) against synthetic WAV files built byte-for-byte like `AudioRecorder`'s own writer, covering the class of bug where playback fails silently with no error, progress, or spectrogram.

- **Loading**: a well-formed WAV's header parses correctly and sets `durationSeconds`; loading a missing file sets `loadError` rather than failing silently.
- **Playback progress**: after `play()`, `isPlaying` flips true, `currentTimeSeconds` advances with real wall-clock time, and the live spectrogram processor's `peakFrequency` correctly reads back the encoded tone's frequency (confirming audio actually reaches the processor, not just that something was fed).
- **Audio session category**: `play()` must itself claim an output-capable (`.playback`) `AVAudioSession` category, regression coverage for a fix that only changed session mode but not category, leaving playback silent when the shared session was still `.record`.
- **Heterodyne auto-tune**: the local oscillator auto-tunes away from its class default (40 kHz) during playback of an off-center call, and isolated `HeterodyneProcessor` tests directly confirm the DSP produces strong output when properly tuned near a call and near-silent output when parked far away (the pre-fix failure mode).

### OpenBatTests/PolyphaseResamplerTests.swift

Numeric-property tests for `PolyphaseResampler`, the 384→256 kHz resampler BatDetect2Classifier runs on every pulse — a deliberate (non-bit-exact) port of `scipy.signal.resample_poly`, so these check properties rather than an oracle.

- **Contract/edge cases**: equal input/output rates return the input unchanged; empty input returns empty; output length matches the expected up/down ratio.
- **Numeric behavior**: a constant signal's mean is preserved in the interior (away from filter edges); a low-frequency tone (well below the new Nyquist) keeps its amplitude; a tone above the new Nyquist (150 kHz) is strongly attenuated rather than aliasing down as a phantom tone, the key anti-aliasing guarantee.

### OpenBatTests/SilenceMapTests.swift

Tests `SilenceMap`, the virtual↔real sample-position mapping that every hide-silence consumer (seek, playhead, tile stitching, analysis) depends on, plus its `compute` detection logic.

- **Mapping**: virtual-to-real and real-to-virtual conversions are correct within and across segments, clamp out-of-range input, collapse real positions inside a hidden gap to the seam, and round-trip virtual→real→virtual as the identity; `realSlices` correctly splits a virtual span across multiple underlying segments.
- **Gap queries**: `nextActiveRealStart` only returns a value when probing from inside a gap, nil when inside an active segment or past the end.
- **Detection**: `compute` isolates a single loud region as one segment with correct padding-adjusted bounds; falls back to treating the whole file as one active segment when nothing clears the threshold; higher sensitivity hides strictly more (regression guard for a sensitivity slider that did nothing); and nearby loud regions get merged into one segment via padding.

### OpenBatTests/STFTGridTests.swift

Basic correctness tests for `STFTGrid`, the shared STFT engine extracted from `PulseImageRenderer`, covering both its one-shot `compute` and its streaming/pooled file-reading path.

- **One-shot compute**: too-short input returns nil; a synthetic tone's peak energy lands in the frequency bin matching its known frequency, and output values stay normalized within [0,1].
- **Streaming/pooled path**: `streamPooledGridFromFile` correctly pools a native-resolution span down to a requested target column count (the case it exists for) with all-finite raw dB values; when the target comfortably exceeds native columns, no pooling occurs and column count matches native frame count exactly; a whole-file-length span (many times longer than the target) still returns promptly with bounded, correct output size.

### OpenBatTests/TestWavFactory.swift

Test helper (not a test suite) providing a shared synthetic-WAV builder used by `WavSpectrogramEngineTests`, `CallAnalysisTests`-style tests, and `WavPCMReaderTests`, mirroring `AudioRecorder`'s own WAV header writer exactly.

- `make(sampleRate:seconds:toneFrequency:chirpToFrequency:amplitude:) -> URL` — writes a mono 16-bit PCM WAV file to a temporary location containing either a constant sine tone, or (when `chirpToFrequency` is supplied) a linear FM sweep from `toneFrequency` to `chirpToFrequency` over the file's duration; returns the file's URL for the caller to read and clean up.
- Private helpers `le32`/`le16` — encode `UInt32`/`UInt16` values as little-endian `Data` for building the RIFF/WAVE header fields.

### OpenBatTests/WavPCMReaderTests.swift

Tests `WavPCMReader.readSamples`, the file-backed PCM sample reader used throughout the WAV playback/analysis pipeline.

- **Correct decoding**: reads return the requested sample count and correctly decode 16-bit PCM amplitude (including from a mid-file offset).
- **Short-read contract**: a read overrunning the end of the file returns the samples that do exist (not nil) — a previously-inverted behavior that would otherwise make a selection dragged to a recording's end look like a broken/empty analysis; reads never return more samples than requested, for any requested count.
- **Boundary between short-read and nil**: a start position entirely past the end of the file returns nil, distinguishing "partially exists" (short read) from "doesn't exist at all" (nil); invalid ranges (negative start, zero/negative count) and a missing file all return nil.

### OpenBatTests/WavSpectrogramEngineTests.swift

Tests `WavSpectrogramEngine`'s two rendering entry points: a whole-file overview render and a bounded detail-tile render for the WAV viewport UI.

- **Overview rendering**: `renderOverview` returns correct whole-file metadata (sample rate, total samples) and a non-empty image for a synthetic file.
- **Detail tile rendering**: a narrow time span produces a correctly bounded image; a wide multi-second span still pools down to the requested target column count rather than ballooning to native resolution (the core memory-bound invariant `streamPooledGrid` exists for); frequency crop ranges outside valid bounds are clamped rather than causing a crash or nil; a zero-length sample range correctly returns nil.

---

### backend/consent-worker/src/index.ts

A Cloudflare Worker implementing OpenBat's minimal consent-and-upload backend: per-device consent state in D1, anonymous recordings as opaque objects in R2, with no queryable relationship between the two — the device_id used to gate an upload is looked up and then deliberately dropped before the object is ever written, which is what makes contributed recordings non-personal data rather than personal data handled carefully.

- **`hmacKey(env)`** — imports the Worker's `DEVICE_TOKEN_SECRET` as an HMAC-SHA256 `CryptoKey`, used to both issue and verify device tokens without storing them.
- **`issueDeviceToken(env, deviceID)`** — computes and hex-encodes `HMAC(secret, device_id)`, handed out exactly once on a device's first consent registration.
- **`hexToBytes(hex)`** — validates and decodes a hex string into raw bytes, used before verifying a bearer token.
- **`isValidDeviceToken(env, deviceID, token)`** — verifies a bearer token against the expected HMAC using `crypto.subtle.verify` (constant-time), length-checking the decoded signature first to avoid a 500 on malformed tokens.
- **`bearerToken(request)`** — extracts the token from an `Authorization: Bearer ...` header.
- **`authorize(request, env, deviceID)`** — combines the above to answer whether a request's bearer token is valid for a given device_id.
- **`withinRateLimit(env, key)`** — best-effort per-key throttle via the optional `RATE_LIMITER` binding; fails open (allows the request) if the binding is absent or errors, since the auth checks are the real gate.
- **`currentConsent(env, deviceID)`** — looks up a device's current `status`/`consent_version` row from D1.
- **`handleUpload(request, env, path)`** — handles `PUT /upload/{date}/{object_id}.flac`: validates the key pattern, requires and authorizes the `x-openbat-device-id` header via bearer token, rate-limits, validates `content-length` against `MAX_UPLOAD_BYTES` (100 MB, matching Cloudflare's own body cap), checks the device's consent is `granted` *and* at `CURRENT_CONSENT_VERSION` (rejecting stale-consent uploads with a 403), refuses to overwrite an existing object (409), mirrors an allowlisted subset of `x-openbat-*` headers (species, quality-score, location, verified — deliberately excluding device-id) into R2 `customMetadata`, then stores the body via `bucket.put` with the device_id already out of scope.
- **`handleErase(env, deviceID)`** — handles the consent-erasure half of `DELETE /consent`: deletes the device's row from `consent_records` and bumps an erasure counter; explicitly does *not* and structurally *cannot* touch R2, since recordings carry no identifier linking them back to a device.
- **`recordErasure(env)`** — increments a per-month `erasure_counts` counter (for accountability reporting) without recording any per-request or per-device detail; failures here are swallowed since they must never block the erasure itself.
- **Default `fetch` handler** — routes requests: `PUT /upload/*` → `handleUpload` (405 for other methods); `GET /consent?device_id=` → authorizes then returns the stored consent row (404 if none); `DELETE /consent?device_id=` → authorizes, rate-limits, then calls `handleErase`; `POST /consent` → validates the JSON body, rate-limits, issues a device token only on a device's first-ever registration (`token_issued = 0`, otherwise requires an existing valid token), and upserts the consent record into `consent_records`; anything else returns 404/405.
