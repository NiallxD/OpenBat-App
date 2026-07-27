//
//  LazyDestination.swift
//  OpenBat
//
//  Defers building a navigation destination until it is actually pushed.
//
//  `NavigationLink { Destination() } label: { Row() }` reads as though the
//  destination is built on tap. It isn't: the destination is a stored property
//  of the link, so the expression is evaluated when the LINK is created — once
//  per row, every time the list's body is evaluated. For a cheap destination
//  that's merely wasteful. For an expensive one it is the difference between a
//  screen that opens instantly and one that visibly hangs.
//
//  This bit hard in `PlaybackListView`: every row's destination is a
//  `WavPlayerView`, whose `@State private var engine = PlaybackEngine()` default
//  expression constructs a `SpectrogramProcessor` — which allocates and
//  zero-fills a 3,840,000-element Float PCM ring (~15 MB) and builds a vDSP FFT
//  setup. Thirty recordings meant ~460 MB of zeroing and thirty FFT setups to
//  open the list, repeated on every body evaluation (a filter toggle, an upload
//  status change, a new recording arriving).
//
//  Wrapping the destination in this makes the closure the stored property
//  instead, so nothing inside it runs until `body` is evaluated — which happens
//  when the destination is pushed, and only for the one being pushed.
//
//  Use it for any destination that owns non-trivial `@State`. It costs nothing
//  when the destination is cheap, so "is this expensive enough to bother?" is
//  the wrong question to spend time on — if it's a real screen, wrap it.
//
//  The value-based `NavigationLink(value:)` + `.navigationDestination(for:)` API
//  solves this too and is the better long-term shape, but it requires every
//  pushed model to be `Hashable` and restructures where destinations are
//  declared. This is the local fix that doesn't touch navigation architecture.
//

import SwiftUI

struct LazyDestination<Content: View>: View {
    private let build: () -> Content

    init(@ViewBuilder _ build: @escaping () -> Content) {
        self.build = build
    }

    var body: Content { build() }
}
