//
//  ListeningEarIcon.swift
//  OpenBat
//
//  The START/STOP detecting button's glyph: a static ear when idle, and an
//  animated Lottie loader while detection is running.
//
//  It replaces a red button with a `stop.fill` square. That combination read as
//  "recording" to users who were only listening — recording is a separate,
//  manually armed action in this app, so the icon was actively teaching the
//  wrong thing. Orange + motion says "running" without borrowing the visual
//  language of the record button.
//
//  The animation is `Resources/ListeningEar.json`, from Niall's `Music.json`:
//  a five-bar equaliser, 600×600, 1 s at 30 fps, each bar a stroked-and-filled
//  shape. An earlier build used a different file entirely (a rotating loader,
//  "Lottie Loader new 2") because the LottieFiles share link resolved to it —
//  worth knowing if the two ever get confused again.
//
//  The ear and the animation SWAP; they are not composed.
//
//  Recolouring: the file carries its own fill colours, so `.valueProvider` is
//  used to force every stroke and fill to white at playback time rather than
//  editing the JSON. That keeps the asset byte-identical to what was exported,
//  so re-exporting from LottieFiles later needs no re-editing here.
//
//  The animation is only mounted while listening. LottieView keeps a display
//  link running for as long as it exists, and this sits in the session button,
//  which is on screen for the whole session — an always-mounted animation would
//  burn frames continuously behind a spectrogram that is already GPU-bound.
//
//  Only the pre-26 bar uses it. On iOS 26 the session button is a `Tab` whose
//  label the system renders outside the normal view tree, which is no place to
//  rely on a Lottie view — that path shows an SF Symbol instead.
//

import SwiftUI
import Lottie

struct ListeningEarIcon: View {
    /// Drives the animation. False renders the plain glyph with no Lottie view
    /// in the hierarchy at all.
    let isListening: Bool
    // Named for what it means to the user ("listening"), not for `isRunning` —
    // the caller maps its own state onto that.
    /// Matches the size the surrounding button gives its SF Symbol.
    var size: CGFloat = 22

    var body: some View {
        Group {
            if isListening {
                // The animation REPLACES the glyph — the ear is the idle state,
                // the loader is the active one. They are not composed.
                LottieView {
                    await LottieAnimation.named("ListeningEar")
                }
                .configure { view in
                    view.contentMode = .scaleAspectFit
                    view.backgroundBehavior = .pauseAndRestore

                    // Every bar is a stroke (teal, width 40) plus a fill (red),
                    // both recoloured white so the equaliser sits with the other
                    // control glyphs.
                    //
                    // The keypath is `**.Color`, NOT `**.Fill 1.Color` /
                    // `**.Stroke 1.Color`. This file was authored in Japanese, so
                    // its shape items are named 塗り 1 (fill) and 線 1 (stroke) —
                    // the English keypaths matched nothing at all and the bars
                    // silently stayed teal and red. Matching on the property
                    // rather than the item name also survives a re-export under
                    // any locale.
                    //
                    // Whitening the FILLS is right for this artwork and was wrong
                    // for the loader that preceded it, where the fills were
                    // full-canvas backdrop discs and turning them white produced a
                    // solid white blob over the button. Check what a fill actually
                    // is before whitening it.
                    view.setValueProvider(ColorValueProvider(UIColor.white.lottieColorValue),
                                          keypath: AnimationKeypath(keypath: "**.Color"))
                }
                .playing(loopMode: .loop)
                .allowsHitTesting(false)
            } else {
                // EXACTLY what this button drew before the animation was added:
                // `.font(.body)` in a 24x22 box, via `controlIcon()`. Restyling it
                // (a bigger, semibold ear) made it sit wrong against the record and
                // listen-mode glyphs beside it, which are all `.body`.
                Image(systemName: "ear")
                    .font(.body)
            }
        }
        // One frame for both states, matching `controlIcon()`'s 24x22, so the
        // button is the same size whether or not it is animating and the control
        // row never shifts.
        .frame(width: 24, height: 22)
    }
}
