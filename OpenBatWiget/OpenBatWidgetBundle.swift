//
//  OpenBatWidgetBundle.swift
//  OpenBatWigetExtension
//
//  Xcode generates a bundle file when you add the target; if yours differs, keep
//  whichever one is marked `@main` and make sure `OpenBatLiveActivity()` is listed.
//

import SwiftUI
import WidgetKit

/// Entry point for the `OpenBatWigetExtension` process. Registers every
/// widget/Live Activity the extension provides — currently just the one.
@main
struct OpenBatWidgetBundle: WidgetBundle {
    var body: some Widget {
        OpenBatLiveActivity()
    }
}
