//
//  PlaybackFollowState.swift
//  OpenBat
//
//  Carries the live playhead-follow sample position OUT of WavPlayerView's
//  own @State so writing it at ~30Hz doesn't invalidate that screen's entire
//  body (stats panel, minimap, tuning popover, transport controls) on every
//  tick — the same @Observable-churn shape already fixed elsewhere in this
//  app (see CLAUDE.md's "@Observable churn bug class" note). WavPlayerView
//  holds ONE instance in `@State` (never reassigned) and only ever WRITES
//  `displaySample`, never reads it in its own body — so mutating it doesn't
//  re-run that body. WavSpectrogramView/WavMinimapView READ it inside their
//  own `body`, so Observation scopes the 30Hz update to just those leaves,
//  same isolation rule WavPlayheadOverlay/MinimapPlayheadOverlay already
//  document for `engine.currentTimeSeconds`.
//

import Foundation

@MainActor
@Observable
final class PlaybackFollowState {
    /// Display-domain sample (virtual while hide-silence is on) the playhead
    /// is currently centered on. Only meaningful while playback's follow
    /// loop is running; readers gate on `isPlaying` themselves.
    var displaySample: Int = 0
}
