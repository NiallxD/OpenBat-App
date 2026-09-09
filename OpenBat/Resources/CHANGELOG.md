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

## v0.9.7 (Build 223)

### Fixed
- **Bats Near You** - Fixed a bug on the detector page which made tapping a bat species in the 'Bats Near You' view cause a hard crash.
- **Species Guide** - Some species with lots of text in one of the ID fields would have a horizontal scroll to the page.

### Changed
- **Onboarding** - Updated the text in the onboarding and made some general tweaks.
- **Onboarding tells you if your microphone is missing** — The welcome screen now checks for a connected ultrasonic microphone and says whether it can see one, instead of warning in general terms. Without one the detector stays silent, which is easy to mistake for a broken app.
- **Every onboarding screen fits without scrolling** — Including on the smallest iPhones, where the last card used to sit below the fold.
- **Turning down the microphone now says what it costs** — It was given the same mild note as location, when in fact the app cannot hear anything at all without it.


## v0.9.6 (Build 220)

### New
- **Post a recording to iNaturalist** — A recording can become an observation without leaving the app, either posted for you when you sign in or handed over as a set of files to upload yourself. A leaf on a row marks the ones worth posting, gold for the best of a night.
- **Posting happens in the background** — The sheet closes as soon as you send it and a pill over the tab bar tracks the upload, so you are not held on one screen while a large file goes up.
- **Spectrogram exports carry real axes** — Frequency and time are labelled on every exported picture, on the same log scale the app draws.
- **A recording is kept even when nothing named it** — With no model active, or with identification switched off, the calls and the pulse count are still recorded. Those recordings used to read as empty triggers.

### Changed
- **The detector hears about three times as many calls** — It was quietly throwing most of them away while it drew the last one, and it threw away the fast-calling bats worst of all: the quicker a bat called, the less of it survived. On a 2020 iPad that has gone from keeping a third of what it heard to keeping over ninety percent, and an old iPad now keeps up with a recent iPhone.
- **An identification belongs to one bat, not to a minute of them** — A pass used to run until things had been quiet for two seconds, which on a busy night meant several bats blended into one entry named after whichever of them called most. A pass now ends after about a second of quiet, so each bat gets its own.
- **No name when two species are too close to separate** — If the top two are neck and neck, OpenBat says nothing rather than picking one. The calls and their measurements are still recorded; only the verdict is withheld. Two species overhead at once will sometimes go unnamed, which is the honest answer.
- **An entry with no species shows the app's own mark** — Rather than a spectrogram shrunk to thumbnail size, which read as a species photo that happened to be dull. Where OpenBat is sure it was not a bat, the mark is struck through.
- **Unidentified passes stay out of the species list** — The recently-heard panel answers what you have heard tonight, and "unidentified" is not an answer to that. They are still filed under the session.
- **An exported session says why a pass went unnamed** — There is a difference between hearing too little to tell and hearing plenty of two species at once, and the export now names which. Its timestamps are also fine enough to measure how fast a bat was calling.
- **Echoes count against a recording's score** — A call recorded somewhere reverberant scores lower for posting, and says so.
- **Sharing no longer asks for your photo library** — Nothing OpenBat exports needs that permission, so it stopped asking for it.
- **A species in a call's caption is marked as OpenBat's own** — So a reader knows the name came from the app rather than from a person.
- **Features can be switched off without an update** — If something goes wrong with identification, the maps or posting, we can turn it off and tell you why, rather than leaving it broken until the next release. The notice stays in Settings for as long as it applies.

### Fixed
- **The sound on an observation matches its pictures** — The audio and the spectrograms were cut from different parts of the recording, so no picture and no sound shared a starting point. Everything now comes from one clip.
- **An observation names the microphone that actually made the recording** — It was posting whichever detector is selected now, so anyone with two microphones would stamp tonight's onto a recording made last month with the other one.
- **Hoary and silver-haired bats were never drawn** — The pulse view would not show a call unless it scored well on a measure that quietly counted long calls as poor ones. Since the low, slow species call longest, the view was hiding exactly the bats it was least able to describe.
- **A long call no longer runs off the edge of the pulse view** — The window was a fixed width with the start pinned near the left, leaving only a few milliseconds for the call itself. It now opens up to hold whatever it is showing.
- **Call measurements posted to iNaturalist say they are rounded** — They are a quick reference rather than a measurement, and the recording that goes with them carries the full detail.

## v0.9.5 (Build 193)

### New
- **User Interface Overhaul** — The user interface has been overhauled with a clean, glass-like, interface. Everything is where it was before, but now with more sleekness.
- **OpenBat works in light mode** — The app was dark-only for its whole development. It now follows your phone, including its own sunset schedule, and every screen is drawn for both. In light mode the spectrogram turns over with it: silence is white and calls are ink, on the detector and on a recording alike. If you would rather not follow the phone, pick one outright. It is the first thing in Settings under Interface, and setting up asks you alongside how much of the detector you want to see.
- **The sun clock is on every tab** —  The Sun Clock now persists across Sessions and Species tabs and not just on the Detector tab.

### Changed
- **Settings say one thing each** — Every card is a name, one line saying what it is for, and the control. The paragraphs that used to sit under each switch are gone: they explained the same idea twice at two sizes, and the sheet read as a wall of text.
- **The model page is in plain English** — "Pass detection" is "Making an ID", "Pulse quality" is "Call quality", and the controls are named for what they do rather than for what they are called in the code. Its sliders are full width instead of squeezed into half a row.
- **One card material across the app** — Sessions, the field guide, the tours and the Info sheet were drawn four different ways. They are the same card everywhere now, and Info & Tour's four buttons are cards in their own right.
- **Species pages give the measurements more room** — Peak frequency, forearm, wingspan, call duration and characteristic frequency were clipping on a normal-sized iPhone. They now take 40% of the row rather than a third.
- **Group headings sit with what they head** — A family in the guide, and a date in Sessions, now sit close to their first card instead of floating between two groups.
- **No painted strip behind the title** — On Sessions, on a recording, and on a region's species list, the header no longer paints a bar of its own behind the title and buttons.
- **Choosing a species to compare confirms your tap** — The row you pick ticks straight away, rather than the screen sitting still while it works.

### Fixed
- **Blue icons in the field guide** — The characteristic features and the region rows on a species page were drawing in the system blue, which read as something bleeding in from the map above them. They are the app's orange.
- **Confidence pills are readable in light mode** — The percentage and the "sounds alike" flag were a bright colour on a wash of the same colour, which all but disappeared on white. They have darker text and an edge to sit in.
- **The map on a session has a card under it** — It was the one thing on that screen drawn straight onto the page, and the species tally beside it had lost its own background.

## v0.9.5 (Build 135)

### Fixed
- **The detector stops triggering on your own footsteps** — Rustling clothing, stones underfoot and handling noise were setting it off, filling a night with recordings of nothing. The loudness needed to trigger had been set to a value that never actually took effect, and correcting that made the detector far more sensitive than it had ever been in the field. It is back where it was, which on a test night kept every bat and removed two thirds of the noise.
- **A single click no longer counts as a bat** — Bats call in trains, so one lone trigger with silence either side is almost always a knock or a footfall. Those are no longer saved or listed. What triggered still counts toward the pulse total, so the readouts stay honest.

### Changed
- **Field Guide Image** — The photograph on a species entry now flows to the top of the screen to offer a more immersive view.

## v0.9.5 (Build 134)

### New
- **Bat group common name** — Added a line with the common group name for that species. This is akin to calling birds 'hawks' or 'hummingbirds'. The name appears at the top of the species profile and can be updates and added to in the Openbat.app field guide editor.

## v0.9.5 (Build 133)

### New
- **Try OpenBat without a microphone** — Info & Tour now has a demo. It plays a real night's recording through the detector, so the spectrogram, the pulse detection and the species IDs all run exactly as they do live and you can see what the app does before you have any hardware. It will play your own recordings the same way. While one is running the detector shows a Demo badge, and tapping that badge is how you end it and hand the app back to the microphone.

### Changed
- **You choose where recordings are kept when you set up** — Setting up now asks whether to keep recordings in your own iCloud, alongside the microphone and location questions, and says what it costs: bat audio is large, and a busy night can use several gigabytes. It was on from the start before, and only mentioned in Settings. It is still in Settings whenever you want to change it.
- **The play button is its own button on iPad** — It used to be the last item inside the tab pill, where it looked like a fourth place to go rather than the control that starts listening. It now sits beside the pill as its own circle, the way it already did on iPhone.

### Fixed
- **The session button always answers now** — With microphone access refused, the button explained itself once and then went quiet: every tap after the first did nothing at all, with no way to tell whether the app had heard you. It now says what is wrong every time you ask, and says it for any other reason a session can't start too.
- **No more empty sessions from a session that never started** — A refused start still opened a session, armed recording and started the timer, so the screen said it was recording while the button said it hadn't started. Nothing opens until listening is actually running.
- **The session controls open on iPhone again** — On iOS 18 the second tap turned the button into a cross and opened nothing, leaving no way to arm recording, change listening mode or end a session from it.
- **Calls now play in time with the playhead** — In a recording, the sound ran about a tenth of a second behind the picture, so every call was heard just after it had passed under the playhead. The playhead now follows what is actually coming out of the speaker.
- **The gap in the sound before each call is gone** — With silence hidden, the recording's background hiss dropped away completely for a moment between calls, which came out as a lurch just before each one. The background now carries straight through the joins.
- **Scrubbing lands where you put it** — Moving the playhead, or changing the playback speed, used to play a last moment of wherever you had just come from before the new position started.
- **A sharper spectrogram when zoomed right in** — Past roughly a tenth of a second on screen, the picture was being stretched rather than redrawn, which left calls looking soft and smeared at the zoom levels where you are looking hardest at them. They are now drawn at full detail at every zoom.

## v0.9.4 (Build 119)

### New
- **Compare two bats side by side** — Read two species' pages together, with the two sides scrolling in step so the same section is always next to the same section. Start from a list and pick two, or tap compare while reading one bat and choose what to set beside it.
- **Bats near you** — A button in the guide's toolbar shows which species are plausible where you're standing, as a grid of photos.
- **Records or range on distribution maps** — Species maps are now shaded by how many records each area holds, so you can see the difference between the heart of a bat's range and its thin edges. Tap the button beside the Distribution heading to switch between the records themselves and the fuller range built from them.
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
