//
//  SoftwareUpdater.swift
//  4DSTEM Explorer
//
//  Automatic updates, through Sparkle.
//
//  The application is distributed directly rather than through the App Store,
//  so nothing tells a user that a new version exists unless the application
//  does it itself. Sparkle checks an appcast in S3, verifies that the update is
//  signed by the private half of the EdDSA key whose public half is in
//  Info.plist, and installs it. The signature is the part that matters: it means
//  someone who gets write access to the bucket still cannot ship code, because
//  the key is not in the bucket.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import SwiftUI
import Sparkle

/// Owns the updater for the lifetime of the application.
///
/// Sparkle wants to be started once and left alone; a controller created per
/// view would check on every appearance and lose the scheduling state that
/// spaces checks out.
final class SoftwareUpdater: ObservableObject {

    static let shared = SoftwareUpdater()

    private let controller: SPUStandardUpdaterController

    /// Whether Sparkle checks on its own schedule.
    ///
    /// Mirrored rather than bound straight through, because `SPUUpdater`'s
    /// properties are plain Objective-C properties with no change publisher: a
    /// SwiftUI control bound to one would set it happily and then never redraw
    /// when anything else changed it. The mirror is the published side and the
    /// updater is the stored side — Sparkle keeps its own value in user
    /// defaults, so this reads back correctly on the next launch.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != controller.updater.automaticallyChecksForUpdates
            else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Whether an update is fetched before the user is asked about it.
    ///
    /// Sparkle ignores this while automatic checking is off — there is nothing
    /// to download in the background if nothing looks — so the control for it
    /// is disabled in that state rather than left to look effective.
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard automaticallyDownloadsUpdates != controller.updater.automaticallyDownloadsUpdates
            else { return }
            controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    /// When Sparkle last managed to ask, for display.
    @Published private(set) var lastCheck: Date?

    private init() {
        // `startingUpdater: true` begins the scheduled checks. The first one
        // asks the user whether to allow automatic checking at all, so this is
        // not a decision being made on their behalf.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
    }

    var updater: SPUUpdater { return controller.updater }

    /// How often Sparkle checks, in days, when it checks automatically.
    var checkIntervalDays: Double {
        get { return controller.updater.updateCheckInterval / 86400 }
        set {
            controller.updater.updateCheckInterval = max(newValue, 0.04) * 86400
            objectWillChange.send()
        }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
        // The check is asynchronous and the date is only written when it
        // finishes, so this is read back rather than assumed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            self.lastCheck = self.controller.updater.lastUpdateCheckDate
        }
    }
}

/// The "Check for Updates…" item.
///
/// The Sparkle sample binds the button's enabled state to the updater's
/// `canCheckForUpdates` through a KVO publisher. That is a key path to a
/// main-actor-isolated property, which Swift 6 rejects — and it buys nothing,
/// since Sparkle ignores a check requested while one is already running.
struct CheckForUpdatesView: View {
    @ObservedObject var updater = SoftwareUpdater.shared

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
    }
}
