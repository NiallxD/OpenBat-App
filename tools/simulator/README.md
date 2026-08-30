# Driving a simulator by hand, from a script

Written 2026-08-30, chasing the App Review rejection of 0.9.3 (build 111). The
point of these is that some bugs only exist *between* taps — "the button works
once and then never again" cannot be seen in a screenshot of a forced state, and
that is exactly what the rejection was.

Needs `cliclick` (`brew install cliclick`) and Screen Recording + Accessibility
permission for the terminal.

- `simctl_ui.py` — taps a point given in **device pixels** (the coordinate space
  of `xcrun simctl io booted screenshot`). It calibrates itself by matching a
  device screenshot against a screen capture of the Simulator window, so it
  needs no per-device constants and survives the window being moved or the scale
  being changed. `simctl_ui.tap(x, y, recalibrate=True)` on the first call.
- `findplay.py` — finds the session button in a screenshot by template match,
  so a script does not need to know where each device puts it. Two templates,
  because the button is a play triangle on 26's bar and a red record circle on
  the pre-26 one.
- `sweep2.py` — boot → install → launch → tap the session button twice →
  three-panel montage, for a list of `name=UDID` pairs. Append `=rot` to rotate.
- `denytest.py` — the regression for the rejection itself: with the microphone
  refused, every tap must raise an alert and none may open a session.

Two things that will waste an afternoon if you don't know them:

- **`simctl io screenshot` always returns the portrait buffer**, whatever the
  device orientation is. For landscape, work from the window capture instead.
- **A simulator always answers an accessibility query and a device never does**,
  so anything relying on `accessibilityIdentifier`/`accessibilityLabel` passes
  here and fails on hardware. Launch with `-locator.structuralOnly YES` to force
  the code path real hardware takes — see `SessionButtonLocator`.
