# OpenBat: Onboarding, Consent & Upload Pipeline Spec

Spec for implementing first-run onboarding, permissions, recording consent, and the WAV upload pipeline. Written for handoff to a coding agent. Decisions marked **[DECIDED]** are settled; **[OPEN]** items still need a number, a library choice, or user testing before they can be built with confidence.

---

## 1. Welcome Screen & Permission Flow

**Goal:** explain the app before asking for anything, and never let a system permission dialog be the first thing a user sees.

- [ ] First-run welcome screen: what OpenBat does, why it records, why it needs mic + location, link to full privacy notice.
- [ ] Soft-ask pattern for both mic and location: show an in-app screen explaining *why* the permission is needed, immediately followed by the real OS permission dialog. Never fire the OS dialog cold.
- [ ] Mic permission copy: "OpenBat needs your microphone to record bat calls above human hearing range."
- [ ] Location permission copy: "OpenBat uses your location to tag where each call was recorded. You can choose to share an approximate area instead of your exact location."
- [ ] Graceful denial handling for both. If mic is denied, recording features are disabled with a clear explanation and a way to re-enable via system settings, not a crash or dead end. If location is denied, fall back silently to the no-location option (see §4).
- [ ] Do not request permissions on app launch before the welcome screen has been seen.

---

## 2. Recording Consent System

**Goal:** a lightweight, verifiable record that a specific device approved sharing its recordings, without relying on identifiers that can silently change.

### 2.1 Device identifier **[DECIDED]**

- Do **not** use the OS-level device identifier (iOS `identifierForVendor` resets on reinstall; Android equivalents can rotate).
- Generate a UUID on first launch, app-controlled.
- Store it in Keychain (iOS) / secure storage (Android) so it survives reinstalls.
- This UUID is what appears in consent records and in recording metadata.

### 2.2 Consent record schema **[DECIDED — direction]**

Store as **current state per device**, not an append-only log. A log of "approved" events alone doesn't represent withdrawal.

```
consent_records
  device_id        (text, primary key)
  consent_version   (text — which version of the consent copy they agreed to)
  status            (enum: granted | revoked)
  granted_at        (timestamp)
  revoked_at        (timestamp, nullable)
```

- val.town + SQL DB is sufficient for this. It's small, low-write-volume, and doesn't need to hold audio or heavy metadata — just the consent state.
- If consent copy is ever updated, bump `consent_version` so you always know which text a given device actually agreed to.
- Expose a simple endpoint the app can call to check current consent status for a device before allowing an upload.

### 2.3 Linking consent to recordings **[DECIDED]**

- Every uploaded recording embeds the device_id and consent_version in its metadata (GUANO — see §5).
- This is the proof-of-consent chain: consent state lives in the val.town DB, the recording carries a reference to it, so provenance can always be reconstructed.

### 2.4 Consent copy requirements **[DECIDED — content, not final wording]**

The consent screen must state plainly, not bury in a linked document:

- Recordings, approximate or precise location (user's choice), device ID, and optional display name are collected.
- Data is stored privately — not published publicly, not fed live into any public map.
- Data may be used for: building a reference call library, training classification models, informing conservation research, and **may be licensed to commercial or research users to help fund the project.**
- Data is not sold or shared for purposes unrelated to bat research and conservation.
- Consent can be withdrawn at any time via Settings.

**[OPEN]** Final wording — worth drafting once the rest of the flow is built and reviewable end to end.

---

## 3. Privacy & Legal Status (context for the agent, not build tasks)

- Project is currently run by an individual, no registered company. Under UK GDPR, the individual is personally the data controller regardless of business status.
- UK ICO self-assessment completed: registered status "not currently trading" → no data protection fee currently due. Revisit this assessment immediately if any commercial data licensing begins.
- Canada: PIPEDA is triggered by *commercial activity*, not by data processing alone. A non-commercial individual project is likely outside its scope for now. Quebec's Law 25 is stricter and doesn't share the same personal-purposes carve-out — revisit if Quebec-based uptake becomes meaningful.
- Both of the above should be re-checked the moment the project starts accepting payment for data access.
- No ads, no unrelated commercial use of user data.

---

## 4. Location Handling

- [ ] **Default:** fuzz to a ~5km block.
- [ ] **Opt-in:** user can choose to share precise GPS instead, with copy explaining precise data helps location-specific research and is not published.
- [ ] Precise location, when granted, is personal data and should be treated accordingly — not exposed via any public-facing feature, API, or export.
- [ ] Data model should separate **precise location + device identity** (deletable, tied to consent withdrawal) from **fuzzed location + audio + species ID** (retained as the anonymized research asset) — build this split into the schema from day one, not retrofitted later.
- [ ] No public map, public API, or iNat-style export should ever expose precise coordinates. Fuzzed location only for anything public-facing.

---

## 5. Audio Processing Pipeline (on-device, before upload)

Order of operations for a captured recording, all running on-device before anything is queued for upload:

1. **Pulse detection & trimming**
   - Keep only the windows containing actual echolocation pulses, with a buffer either side to preserve pulse rate/sequence context.
   - Discards the (large) silent majority of a raw recording. Reduces storage and incidental audio duration.

2. **High-pass filter — privacy guarantee [DECIDED direction, OPEN exact number]**
   - Applied irreversibly, on-device, before the file is ever queued for upload or stored.
   - Purpose: guarantee — not merely reduce the likelihood — that no intelligible human speech survives in the file. Speech intelligibility lives almost entirely below ~8–10kHz; UK bat species call no lower than ~17kHz even at the extreme low end (noctule FM sweep tail).
   - **[OPEN]** Exact cutoff. Target range 12–13kHz, giving headroom below the noctule's sweep floor. Needs validation against real noctule recordings before locking in.
   - Record the applied cutoff frequency in the file's own metadata (see §5.4) so nobody downstream mistakes it for untouched full-spectrum audio.
   - This is a UK-species-scoped decision. If non-UK species are ever supported, this cutoff must be revisited — some species elsewhere call lower than any UK bat.

3. **Voice activity detection — quality/etiquette filter, not privacy-critical [OPEN]**
   - Separate from the high-pass filter. Used to flag/reject recordings with significant human chatter for quality reasons (a chatty recording usually also means a poorly-positioned or unattended detector), not as the privacy mechanism.
   - **[OPEN]** Library choice — Silero VAD or WebRTC VAD are reasonable on-device candidates, need evaluation for mobile runtime footprint.

4. **Quality gate**
   - Only sufficient-quality recordings proceed to upload. Run on-device to save bandwidth and storage.
   - **[OPEN]** Exact thresholds: SNR floor, clipping detection, minimum pulse count. Needs calibration against real-world recordings from actual target hardware, not lab conditions — this is deliberate, since the whole point of the reference library is matching real-world capture conditions (see §7).

5. **Classifier inference (if running NABat ML or similar on-device)**
   - Run classification on the **untouched, full-spectrum** audio, before the high-pass filter is applied, so the model always sees the input distribution it was trained on.
   - Only after classification is complete does the filtered/trimmed version get built for storage/upload.

6. **Lossless compression**
   - FLAC on the filtered, trimmed WAV. No lossy codecs (MP3/AAC/Opus) at any stage — defeats the reference-library purpose.

### 5.4 Metadata — GUANO standard **[DECIDED]**

- Use GUANO tags embedded in the WAV file itself as the durable, self-describing source of truth. Travels with the file wherever it's copied.
- Fields to include:
  - `device_id`
  - `consent_version`
  - timestamp
  - location (precise and/or fuzzed, per user's location choice)
  - recordist display name (optional — falls back to device_id if blank, see §6)
  - hardware/detector type, and mic module where capturable **[OPEN — best-effort field, not all self-build hardware variants are identifiable; nullable/free-text with "unknown" fallback, don't block pipeline on this]**
  - app version, OS
  - high-pass filter cutoff applied (Hz)
  - quality score / gate metrics
  - species classification + confidence, if inference was run
- Mirror the key **filterable** fields (species, quality score, region-fuzzed location, verified status) into R2 object metadata at upload time (see §6) — this avoids needing a database purely to answer "list all confirmed Myotis calls from Yorkshire" type queries.

---

## 6. Storage

**Provider [DECIDED]:** Cloudflare R2.
- S3-compatible, no egress fees, free tier: 10GB storage / 1M write ops / 10M read ops per month, renewed monthly, no expiry.
- Rough budget: at ~1MB average per processed (trimmed, filtered, FLAC) recording, free tier covers roughly 10,000 recordings before storage costs kick in. Beyond that: $0.015/GB/month, egress stays free forever.

**Access [DECIDED]:**
- Single private bucket. No public URLs, ever.
- Uploads/downloads via short-lived signed URLs, generated server-side (a small val.town endpoint), not via long-lived credentials shipped in the app.

**Object key convention [DECIDED]:**
```
{device_id}/{date}/{recording_id}.flac
```
- Matches the consent log's device_id for easy cross-referencing.
- Enables free, fast prefix-based listing per contributor without needing an index.

**No separate metadata database for recordings [DECIDED — for now]:**
- The GUANO-tagged file plus R2 object metadata is the record. No need for a relational DB purely to store what's already embedded in the file.
- Re-evaluate once volume reaches a scale where listing/filtering the whole bucket per query becomes slow (low tens of thousands of files) — at that point a periodically regenerated lightweight index (even flat JSON or SQLite built by scanning object metadata) is enough; a full DB engine is not required.

**[ ] Build:** a simple usage check (list + sum object sizes, or R2's own usage metrics) that warns before the 10GB free tier is exhausted, so uploads don't silently start failing.

---

## 7. Settings: Recordist Name Field

- [ ] Optional free-text "display name" field in Settings (not framed as legal name).
- [ ] If set, stored in the recording's GUANO metadata for credit purposes.
- [ ] If blank, falls back to device_id.
- [ ] Copy near the field should note it may be visible alongside recordings shared for research/credit purposes — this is a privacy-relevant field even though it's optional.

---

## 8. Why on-device, real-hardware quality gating matters (context, not a build task)

The reference library's value proposition is training data that matches real-world usage: affordable self-build/consumer hardware, in the hands of non-experts, in noisy real conditions — not researcher-grade equipment in controlled survey conditions, which is what existing datasets (NABat, BatDetect2, ChiroVox, etc.) are mostly built from. This means the quality gate should filter out genuinely unusable recordings (clipping, no discernible pulses) but should **not** be tuned so strict that it filters out the realistic noise (wind, traffic, distance) that the eventual model needs to learn to handle. This is a threshold-calibration problem to solve with real test recordings, not a number to guess up front.

---

## Summary of Open Decisions

| Item | Status |
|---|---|
| High-pass filter cutoff (target 12–13kHz) | Needs validation against real noctule recordings |
| VAD library for etiquette/quality filtering | Needs evaluation |
| Quality gate thresholds (SNR, clipping, pulse count) | Needs calibration against real hardware recordings |
| Mic module capture for self-build hardware variants | Best-effort field, not blocking |
| Final consent screen wording | Draft once flow is otherwise built |
| Index/DB for recording metadata | Not needed yet — revisit at scale |
