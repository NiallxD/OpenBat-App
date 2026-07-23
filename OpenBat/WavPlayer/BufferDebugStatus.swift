//
//  BufferDebugStatus.swift
//  OpenBat
//
//  Debug-only visibility into the pan buffer's staged rendering (see
//  WavSpectrogramView.renderChunkedStep) — surfaced as small red/green
//  segments on the minimap (WavMinimapView) so the buffer's actual extent
//  and in-flight state are visible on-device instead of only inferred from
//  logs. Shared (not private to one view) since WavSpectrogramView is the
//  one doing the rendering but WavMinimapView is where it's displayed.
//

import Foundation

@Observable
final class BufferDebugStatus {
    /// The current detail tile's own bounds — shown GREEN on the minimap.
    /// `hasReady` is false before the very first tile of a load/zoom has
    /// landed.
    var readyStart = 0
    var readyEnd = 0
    var hasReady = false

    /// Whatever span the in-flight background step is CURRENTLY computing
    /// — shown RED on the minimap. `isRendering` is false whenever nothing
    /// is in flight, including the fast "cheap recolor" path (a noise-
    /// floor/palette change or a small in-margin pan) — that doesn't
    /// re-read PCM at all, so there's nothing meaningful to flash red for.
    var renderingStart = 0
    var renderingEnd = 0
    var isRendering = false
}
