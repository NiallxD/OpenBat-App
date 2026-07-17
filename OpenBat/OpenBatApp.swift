//
//  OpenBatApp.swift
//  OpenBat
//
//  Created by Niall Bell on 27/06/2026.
//

import SwiftUI

@main
struct OpenBatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // The UI (dark spectrogram backgrounds, white/orange/green icon
                // tints) is designed for dark mode only — force it regardless of
                // the system appearance setting so light mode never washes it out.
                .preferredColorScheme(.dark)
        }
    }
}
