# Changelog

<!--
  This file IS the What's New screen. It is bundled with the app and parsed at
  runtime by ChangeLog.swift, so the format below is load-bearing:

    ## v0.8.9 (Build 89)     one per release, NEWEST FIRST — only the first
                             block is shown in What's New, and its heading is
                             the screen's title
    ### New                  a section; the heading is shown as written
    - **Title** — detail     one item; the em dash splits it into the bold
                             line and the grey line under it

  A bullet with no em dash is shown as a title on its own, which is fine for a
  short one. Anything that is not a "##", "###" or "-" line is ignored by
  What's New, so prose between releases is safe to write — the full change log
  screen renders the file as ordinary Markdown, minus comments like this one.

  TO MAKE A RELEASE RE-RUN ONBOARDING, put an HTML comment containing exactly
-->

<!-- openbat: reonboard -->
      
<!--
  anywhere inside that release's "##" block. (It has to be inside the block —
  this comment sits above the first one precisely so that these instructions
  can name the directive without triggering it.)

  It fires ONCE for that build, and only for people who already had the app
  installed — never on a fresh install, where onboarding runs anyway. Use it
  only when the app has changed enough that the intro is worth seeing again: it
  interrupts everybody, before they reach the detector.
-->

## v0.9.4 (Build 118)

### New
- **Compare two bats side by side** — Pick any two species from the guide and read their pages together. The two sides scroll in step, so the same section is always next to the same section.
- **Bats near you** — A button in the guide's toolbar shows which species are plausible where you're standing, as a grid of photos.
- **Records or range on distribution maps** — Species maps are now shaded by how many records each area holds, so you can see the difference between the heart of a bat's range and its thin edges. A toggle switches between the records themselves and the fuller range built from them.
- **A sun arc** — The sun clock draws the night as an arc through the evening rather than listing sunset and sunrise as two rows.

### Improved
- **Ranges no longer stop where the records run out** — Distribution maps were being trimmed wherever records get sparse, which is exactly where a bat is least likely to have been recorded and most likely to be new to you. Whole regions were missing: the spotted bat stopped dead at the Canadian border despite living well into British Columbia, and the Hawaiian hoary bat was not on the map at all. Ranges now carry through thinly recorded ground, and every species gained rather than lost coverage.
- **Species photos load once** — Guide photos are kept on the device after the first download instead of being fetched again every time you open a page.
- **Guide collections your way** — Species lists can be shown as photo cards or as a compact list.
- **A calmer spectrogram** — A slightly wider default time window, two hard-to-read colour palettes retired, and the display now settles into place when a session ends instead of stuttering.
- **Settings rebuilt** — Grouped into cards so related controls sit together, and the simplified-view switch is now called Advanced mode, which is what it actually does.
- **Harder to end a session by accident** — Ending a session from the transport menu asks first, and bulk delete is now limited to unidentified detections or all sessions rather than anything in between.

### Fixed
- **Call thumbnails everywhere** — Detections show their call picture in every view, and species rows no longer reshuffle when a call is re-identified.
- **Single stray pulses no longer become detections** — A lone click picked up out of nowhere used to be filed as an unidentified bat.
- **The session glow stays lit** — It went out when recording stopped even though the app was still listening.
- **The microphone rate warning** — It could stick mid-flash after the rate had already recovered, and the speaker feedback warning now only appears while audio is actually running.
- **iPhone no longer rotates upside down.**

## v0.9.1 (Build 95)

### New
- **Weight, at a glance** — Species pages now show what a bat's weight compares to — a coin, a strawberry, a battery — instead of leaving you to picture a number in grams.

### Improved
- **Distribution maps** — Range shading no longer shows a striped border between rows, so it reads as one shape instead of a stack of stripes. A few species also had their map skewed by a small number of clearly mislocated records (a mislabeled museum specimen, a misidentification); those are now filtered out automatically.

## v0.9.1 (Build 93)

### Improved
- **Onboarding** - Reduced the length of the onboarding process and simplified some of the information.
- **Mic Calibration** - Added a mic calibration prompt for the first time a mic is plugged in. This offers an opportunity to calibrate the mic but also can be done later in settings.

## v0.9.0 (Build 92)

### Improved
- **Minor Improvements** - Just a few tweaks to existing systems to improve how they run.

## v0.8.9 (Build 91)

<!-- openbat: reonboard -->

### Improved
- **Simplified the Easy Mode tour** - Just a slight improvement in the tour by offering fewer options and ensuring key features are explained.

### Fixed
- **Species search** — Typing in the field guide's search box no longer closes the keyboard after the first letter. Matches now appear in a list under the search bar and narrow as you type.
- **Distribution maps** — Species with tall ranges are no longer cut off at the top and bottom. The map is square, which fits every range there is.
- **Species pages hold still** — They no longer drag sideways.


## v0.8.9 (Build 89)

### New
- **What's New** — This screen. It appears once after each update, and lives under Info & Tour the rest of the time.
- **Guided tour, on request** — A button beside the settings gear offers a tour of the detector screen, and takes itself away once you've been through it.

### Improved
- **A shorter tour in simplified view** — A handful of steps covering the three panes and how to start listening, rather than every control on the screen.
- **The sun clock stays put during the tour** — The tour now shows the screen exactly as it really is.
- **A calmer welcome** — The setup flow leads with the app's own icons, explains what location is for including tonight's sunset and sunrise, and no longer ends by pushing you into a tour.

### Fixed
- **The sun clock is back** — Sunset and sunrise times were not appearing at all on the detector screen. They are now.
