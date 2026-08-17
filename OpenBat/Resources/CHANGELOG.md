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
