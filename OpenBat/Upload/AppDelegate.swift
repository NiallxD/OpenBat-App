//
//  AppDelegate.swift
//  OpenBat
//
//  Exists solely to catch iOS relaunching the app to finish a background
//  URLSession upload transfer (RecordingUploader's backgroundSession). SwiftUI
//  apps have no UIApplicationDelegate by default; this is wired in via
//  `@UIApplicationDelegateAdaptor` in OpenBatApp.
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    var backgroundCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication,
                      handleEventsForBackgroundURLSession identifier: String,
                      completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        RecordingUploader.shared.activate()
    }
}
