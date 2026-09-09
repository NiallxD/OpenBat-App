# Parameter audit: what could be tuned remotely, and what stops it

2026-09-09. Written for the "host the defaults on GitHub so a value can be
changed without a build" idea. It answers one question for every tunable number
in the app: **if I changed its default remotely tomorrow, would an existing
install pick it up?**

## The rule this all turns on

The requirement is "a value the user has chosen is theirs; a value they never
touched is mine to move". Almost every store in the app already encodes exactly
that distinction, because they all read the same way:

> is there a stored value? use it. Otherwise use the compiled default.

**Absence is the record of "never touched".** So a remote default doesn't need
any new bookkeeping — it slots in as the fallback where the compiled constant is
now, and the rule falls out for free.

It only holds while nothing writes a value the user didn't choose. Four places
currently do, and each one permanently freezes whatever it wrote. That is what
most of this document is about.

## The three-way answer

**Free** — nothing to fix, remote value can simply take effect:
constants with no user control at all (Tier 0), plus every store that already
reads "stored if present, else compiled default" (Tier 1).

**Needs a tweak first** — one write to remove, then free: the loudness
threshold, the frequency band (Tier 2).

**Cannot, by decision** — per-model AutoID settings, and everything in the
"keep out" list. These change what the app identifies and what it does with
your data; they belong to a build that was reviewed and tested, not to a file
that can change under a phone at 2 a.m.

## Tier 0 — numbers with no setting at all (the easy half)

These have no UserDefaults key, no control, and nothing a user could have
chosen. A remote value can simply replace the compiled one, unconditionally,
with no "has the user touched it" question to answer. Several are exactly the
numbers we have spent the last week arguing about by ear:

| Number | Where | What it decides |
|---|---|---|
| Heterodyne resting level | `HeterodyneProcessor.defaultGain` | how loud the live channel is |
| Output makeup gain, soft-clip knee | `ListenOutputStage` | how loud everything is, and where it compresses |
| Replay target level, background cap | `SnippetExpansionProcessor` | how loud and how clean a replay comes back |
| Call-vs-noise crest threshold | `SnippetExpansionProcessor.minCallCrestDB` | whether a snippet is worth replaying at all |
| Heterodyne duck depth and slew | `AudioEngineController` | how far the live bed drops under a replay |
| Simplified view's band | `SimplifiedView.bandLowHz/bandHighHz` | what most users see on the spectrogram |

**This is where I would start.** It is the largest share of the "a setting that
works better" case, it needs none of the fixes below, and it cannot conflict
with a user's choice because there is no way for them to have made one.

## Tier 1 — settings that already work correctly

Absent until touched, read through the compiled default. A remote default would
work today, with no change beyond the plumbing.

| Group | Values | Where |
|---|---|---|
| Detection | trigger mode, lowest pitch, shortest call, gap joining, hold-off, display window, both noise floors, refresh interval | `PulseDetector` |
| Time expansion | speed, buffer, volume trim, background, re-arm, fade, routing | `SnippetExpansionSettings` |
| Heterodyne | volume trim, background | `HeterodyneSettings` |
| Haptics | strength, level floor/ceiling, min intensity, frequency floor/ceiling, buzz enter/exit, rate window, hangover, min tap interval | `PulseHaptics` |
| Map pins | minimum confidence, minimum pulses | `AutoIDSettings` |

One wrinkle: haptics' on/off switch is read with `bool(forKey:)`, which returns
false for an absent key, so "off by default" and "the user turned it off" are
the same state. Harmless today; it means that one switch alone can't be
remotely defaulted until it reads presence like its neighbours do.

## Tier 2 — frozen, and why

These would be silently ignored on most or all existing installs.

**Loudness threshold — written on every install.** The one-time amplitude repair
in `PulseDetector.init` writes the threshold back to storage whether or not the
user ever set it, so every install that has launched once has a stored value.
*Fix:* only write when the repair actually changed something.

**Everything per-model in AutoID — RESERVED FOR BUILDS** (Niall, 2026-09-09).
Pass timeout, minimum confidence, minimum pulses, winning margin, the quality
gate and its two thresholds decide what the app claims to have heard, and a
number that changes what a recording is identified as should ship with the model
it belongs to and the testing that went with it. Not a candidate for remote
tuning at all, so the blob write that freezes them is no longer a defect to fix
— it is simply irrelevant. (For the record: Settings writes the whole encoded
blob on Done and on swipe-down, touched or not, so after one visit every
per-model value reads as "chosen".)

**The frequency band — written on entering simplified view.** Simplified view is
the default mode, so in practice every install has stored a band it never chose.
It already keeps a separate "defaults applied" marker, so the values needn't be
written at all. *Fix:* apply to the live processor, don't persist.

**Recording lengths — were not persisted at all. FIXED 2026-09-09.** Pre-roll,
post-roll and maximum segment length were edited in Settings and lived only in
memory: they returned to 3 s / 3 s / 600 s at every launch. A setting that
silently forgets, and a bug regardless of the remote-defaults idea. They now
persist, written only on an actual assignment, so an untouched install stores
nothing and they join Tier 1.

## What I would keep out of remote control entirely

Not because they're hard, because the blast radius is wrong: consent and
contribution, storage root, iNaturalist, device identity, onboarding and
release stamps, and the feature overrides themselves.

The existing kill-switch scheme rests on a promise — *the worst a bad config
file can do is remove a feature*. Numbers break that promise: a bad threshold
doesn't remove anything, it makes the app quietly deaf while still looking like
it works. So anything eligible should be range-checked against the same limits
the slider has, and a value outside them ignored rather than clamped, so a typo
fails loudly in the config rather than half-applying in the field.

## Decisions

1. **Start at Tier 0 only?** It is most of the value, none of the risk, and it
   needs no audit fixes. Tiers 1 and 2 can follow.
2. **When does a new value take effect** — next launch, or live? Next launch
   matches the flags and gives one moment where everything is consistent.
3. **An amnesty for existing installs?** Without one, the loudness threshold,
   the band and every AutoID value stay frozen at today's numbers forever on
   every phone already out there, even after the writes above are fixed. With
   one, a stored value equal to the old compiled default is treated as untouched
   — once, on one build.
