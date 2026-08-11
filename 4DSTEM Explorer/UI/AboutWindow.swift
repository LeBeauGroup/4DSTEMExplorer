//
//  AboutWindow.swift
//  4DSTEM Explorer
//
//  The About window, and the acknowledgements it carries.
//
//  This replaces the standard AppKit about panel rather than adding to it,
//  because the standard panel's credits area cannot hold a scrollable licence
//  list at a readable size. The licence text is not written out here: it is read
//  from THIRD-PARTY-LICENSES.txt in the bundle, which
//  ThirdPartyLicenses/collect.sh generates from the installed libraries. So the
//  notices shown are the ones actually shipped, and upgrading HDF5 cannot leave
//  this window quoting a stale licence.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import SwiftUI
import AppKit

// MARK: - Window

final class AboutWindowController: NSObject, NSWindowDelegate {

    private static var current: AboutWindowController?
    private var window: NSWindow?

    /// Shows the window, or brings the existing one forward.
    static func present() {
        if let existing = current, let window = existing.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = AboutWindowController()
        controller.show()
        current = controller
    }

    private func show() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "About \(AboutInfo.applicationName)"
        window.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: AboutView())
        hosting.sizingOptions = []
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 460, height: 360)

        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        AboutWindowController.current = nil
    }
}

// MARK: - Bundle facts

/// What the app knows about itself, read from the bundle rather than restated
/// here so the version cannot drift from the one that shipped.
enum AboutInfo {

    static var applicationName: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "4DSTEM Explorer"
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (version?, build?): return "Version \(version) (\(build))"
        case let (version?, nil): return "Version \(version)"
        case let (nil, build?): return "Build \(build)"
        default: return ""
        }
    }

    static var copyright: String {
        return Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © The LeBeau Group"
    }

    static var icon: NSImage? {
        return NSApp.applicationIconImage
    }

    /// The acknowledgements file that ships in the bundle, if it is there.
    static var acknowledgements: String? {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-LICENSES", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text
    }
}

// MARK: - View

struct AboutView: View {

    @State private var showingAcknowledgements = true
    @State private var copied = false

    private let acknowledgements = AboutInfo.acknowledgements

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary.padding(8)
            Divider()
            if showingAcknowledgements, let text = acknowledgements {
                licences(text)
            } else {
                Spacer(minLength: 0)
            }
            Divider()
            controls
        }
        .frame(minWidth: 460)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 16) {
            if let icon = AboutInfo.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(AboutInfo.applicationName)
                    .font(.title2).bold()
                Text(AboutInfo.version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(AboutInfo.copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Released under the MIT licence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
//                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
//        .padding(.horizontal, 4)
    }

    private func licences(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(12)
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack {
//            if acknowledgements == nil {
//                // Only reachable if the resource went missing from the bundle;
//                // saying so beats a button that does nothing.
//                Text("Acknowledgements are not available in this build.")
//                    .font(.caption)
//                    .foregroundStyle(.orange)
//            } else {
//                Button(showingAcknowledgements ? "Hide Acknowledgements" : "Acknowledgements…") {
//                    showingAcknowledgements.toggle()
//                    copied = false
//                }
//            }
            if copied {
                Text("Copied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if showingAcknowledgements, let text = acknowledgements {
                Button("Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    copied = true
                }
            }
        }
        .padding(12)
    }
}
