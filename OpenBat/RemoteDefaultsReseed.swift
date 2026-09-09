//
//  RemoteDefaultsReseed.swift
//  OpenBat
//
//  Making a remotely-set default apply in the launch it arrived in, instead of
//  the one after.
//
//  WHY THIS EXISTS
//  ---------------
//  The config file lands a second or two into launch, by which time every
//  settings store has already read its values. The levels are fine — they are
//  computed properties read at capture start, so they were never stale (see
//  `RemoteDefaults`). Everything with a slider behind it was read once in an
//  `init` and would have waited for the next launch.
//
//  That gap is not academic: somebody who opens the app at dusk and listens
//  until midnight would spend the whole night on the previous values, and the
//  point of being able to change a number remotely is that the change reaches
//  people who are out working (Niall, 2026-09-09). The alternative asked for
//  first was an alert offering to restart the app — iOS has no supported way to
//  relaunch itself, `exit(0)` looks like a crash to a user and to App Review,
//  and needing it at all is the thing worth removing.
//
//  THE TWO RULES A RE-SEED MUST OBEY
//  ---------------------------------
//  1. **It must not persist what it writes.** Every one of these properties
//     persists on `didSet`, and a stored value is this app's record that the
//     USER chose it. A re-seed that tripped those observers would write down
//     values nobody chose and freeze every one of them against every future
//     config change — the exact failure this whole scheme exists to avoid, and
//     it would arrive silently. Hence `Reseedable.isSeeding`, checked by every
//     store's `persist`, which suppresses the write and NOTHING else: the queue
//     mirrors in `AudioRecorder`, the engine start/stop in `PulseHaptics`, all
//     still happen.
//  2. **It must not run during a session.** Values that decide what counts as a
//     call have to hold still for the length of a recording, or the spectrogram,
//     the detector and the file disagree about which second used which number.
//     `ContentView` defers the re-seed to the end of a running session rather
//     than skipping it.
//
//  WHAT IT TOUCHES
//  ---------------
//  Only parameters with no stored value — the ones nobody has ever set by hand.
//  A user's own choice is never overwritten, awake or asleep.
//

import Foundation

/// A settings store that can pick up new remote defaults without a relaunch.
@MainActor
protocol Reseedable: AnyObject {
    /// True while `reseedRemoteDefaults` is assigning. Every `persist` checks it.
    var isSeeding: Bool { get set }
    /// Re-read every parameter the user has never set. Must assign only those.
    func reseedRemoteDefaults()
}

extension Reseedable {
    /// Run `body` with persistence suppressed.
    func seeding(_ body: () -> Void) {
        isSeeding = true
        defer { isSeeding = false }
        body()
    }
}
