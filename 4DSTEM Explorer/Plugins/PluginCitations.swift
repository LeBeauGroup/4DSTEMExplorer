//
//  PluginCitations.swift
//  4DSTEM Explorer
//
//  The window that shows a plugin's references and exports them.
//
//  A plugin declares what to cite by shipping a .bib file; see PluginBibTeX.swift
//  for how it is read. This is only the presentation of it. Export writes the
//  author's file back out unchanged, so what lands in someone's bibliography is
//  exactly what the plugin author wrote and checked — the app never re-renders a
//  reference and so cannot corrupt one.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Window

final class PluginCitationsWindowController: NSObject, NSWindowDelegate {

    private static var open: [PluginCitationsWindowController] = []
    private var window: NSWindow?

    /// Shows a plugin's references, bringing an already-open window for the same
    /// plugin forward rather than stacking duplicates.
    static func present(pluginName: String, library: PluginCitationLibrary) {
        if let existing = open.first(where: { $0.window?.title == title(for: pluginName) }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = PluginCitationsWindowController()
        controller.show(pluginName: pluginName, library: library)
        open.append(controller)
    }

    private static func title(for pluginName: String) -> String {
        return "Citations — \(pluginName)"
    }

    private func show(pluginName: String, library: PluginCitationLibrary) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = PluginCitationsWindowController.title(for: pluginName)
        window.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: PluginCitationsView(pluginName: pluginName,
                                                                 library: library))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 460, height: 320)

        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        PluginCitationsWindowController.open.removeAll { $0 === self }
    }
}

// MARK: - View

struct PluginCitationsView: View {

    let pluginName: String
    let library: PluginCitationLibrary

    @State private var showingSource = false
    @State private var exportNote: String?
    @State private var exportFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("If you publish results from \(pluginName), please cite:")
                    .font(.callout)
                Text("This plugin implements published methods. Check each entry against the publisher's record before submitting — these are provided as a convenience, not as an authority.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            ScrollView {
                if showingSource {
                    // The file itself, for anyone who would rather read BibTeX
                    // than a rendering of it.
                    Text(library.source)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(library.citations) { citation in
                            entry(citation)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                Toggle("BibTeX source", isOn: $showingSource)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                if let note = exportNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(exportFailed ? Color.orange : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Copy BibTeX") { copyBibTeX() }
                Button("Export BibTeX…") { exportBibTeX() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 320)
    }

    @ViewBuilder
    private func entry(_ citation: PluginCitation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !citation.reason.isEmpty {
                Text(citation.reason.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(citation.title.isEmpty ? citation.id : citation.title)
                // The first entry in the file is the one to cite first.
                .fontWeight(citation.order == 0 ? .semibold : .regular)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if !citation.displayAuthors.isEmpty {
                Text(citation.displayAuthors)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !citation.displayDetail.isEmpty {
                Text(citation.displayDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !citation.note.isEmpty {
                Text(citation.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let link = citation.link {
                Link(citation.linkLabel, destination: link)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Export

    private var document: String {
        return library.exportText(pluginName: pluginName)
    }

    private func copyBibTeX() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(document, forType: .string)
        exportFailed = false
        exportNote = "\(library.citations.count) entries copied."
    }

    private func exportBibTeX() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bib") ?? .plainText]
        panel.nameFieldStringValue = library.fileName
        panel.canCreateDirectories = true
        panel.message = "Save the BibTeX references for \(pluginName)"

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try document.write(to: url, atomically: true, encoding: .utf8)
                exportFailed = false
                exportNote = "Saved to \(url.lastPathComponent)."
            } catch {
                exportFailed = true
                exportNote = "Could not save: \(error.localizedDescription)"
            }
        }

        // Attached to this window rather than free-floating: the citations
        // window can be opened from a modal parameter sheet, where a detached
        // panel would never receive events.
        if let window = NSApp.keyWindow, window.title.hasPrefix("Citations —") {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
}
