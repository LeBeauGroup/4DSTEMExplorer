//
//  SettingsView.swift
//  4DSTEM Explorer
//
//  The Settings window (⌘,).
//
//  Only updates for now, which is the whole reason it exists: automatic
//  checking is something a user should be able to turn off, and Sparkle's own
//  first-run prompt is a single yes-or-no that never appears again. Without a
//  control somewhere, whatever was answered that first time is permanent.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        // No TabView. There is one pane, and a tab bar holding a single tab
        // draws either nothing or an odd one-item toolbar depending on the
        // system — neither of which helps anyone. Wrap this in a TabView on the
        // day there is a second pane to switch to.
        UpdateSettingsView()
            .frame(width: 460)
    }
}

struct UpdateSettingsView: View {
    @ObservedObject private var updater = SoftwareUpdater.shared

    /// Intervals worth offering. Sparkle takes any number of seconds, but a
    /// free-text field for something measured in days invites values that mean
    /// "never" by accident.
    private static let intervals: [(label: String, days: Double)] = [
        ("Daily", 1), ("Weekly", 7), ("Monthly", 30)
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically",
                       isOn: $updater.automaticallyChecksForUpdates)

                Picker("Check", selection: Binding(
                    get: { closestInterval },
                    set: { updater.checkIntervalDays = $0 })) {
                    ForEach(Self.intervals, id: \.days) { Text($0.label).tag($0.days) }
                }
                .disabled(!updater.automaticallyChecksForUpdates)

                Toggle("Download updates in the background",
                       isOn: $updater.automaticallyDownloadsUpdates)
                    // Sparkle does not download in the background when it is
                    // not checking in the background, so the control is
                    // disabled rather than left looking effective.
                    .disabled(!updater.automaticallyChecksForUpdates)
            } header: {
                Text("Software Updates")
            } footer: {
                Text("Updates are downloaded from the group's release bucket and installed only if they carry a valid signature. An update signed by anything other than this application's own key is refused.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(versionSummary)
                        Text(lastCheckSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The offered interval nearest to whatever is actually stored.
    ///
    /// Sparkle's value is free-form seconds and may have been set by an older
    /// build or by a default; snapping to the nearest offered value keeps the
    /// picker from showing nothing selected.
    private var closestInterval: Double {
        let current = updater.checkIntervalDays
        return Self.intervals
            .min { abs($0.days - current) < abs($1.days - current) }?.days ?? 1
    }

    private var versionSummary: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (build \(build))"
    }

    private var lastCheckSummary: String {
        guard let date = updater.lastCheck else { return "No update check yet." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Last checked \(formatter.string(from: date))"
    }
}
