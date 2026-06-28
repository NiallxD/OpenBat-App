//
//  SettingsView.swift
//  OpenBat
//

import SwiftUI

struct SettingsView: View {
    let settings: AutoIDSettings
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = "autoID"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $selectedTab) {
                    Text("AutoID").tag("autoID")
                    Text("Audio").tag("audio")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if selectedTab == "autoID" {
                    AutoIDSettingsView(settings: settings)
                } else {
                    audioTab
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        settings.save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @AppStorage("recording.screenCaptureEnabled") private var screenCaptureEnabled = true

    private var audioTab: some View {
        Form {
            Section {
                Toggle("Screen recording", isOn: $screenCaptureEnabled)
            } header: {
                Text("Recording")
            } footer: {
                Text("When on, tapping Record also captures a screen video (ReplayKit) alongside the triggered WAV passes. Turn off to save only audio.")
            }
        }
    }
}
