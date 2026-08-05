//
//  PluginLiveWindow.swift
//  4DSTEM Explorer
//
//  One window holding a plugin's controls and its result, re-running as the
//  user adjusts a parameter.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import SwiftUI
import AppKit
import Combine

// MARK: - Session

/// Runs a live plugin and publishes whatever it last produced.
///
/// Runs are serialised on one queue, so `run(host:parameters:)` is never called
/// re-entrantly and a plugin can cache across calls without locking. Moving a
/// control cancels the run in flight and schedules another after a short pause,
/// so dragging a slider does not queue up a run per tick.
final class PluginLiveSession: ObservableObject {

    let plugin: LoadedPlugin
    let store: PluginParameterStore

    @Published private(set) var payload: PluginResultPayload?
    @Published private(set) var image: NSImage?
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRunDuration: TimeInterval?
    @Published var liveUpdate: Bool = true {
        didSet { if liveUpdate && oldValue == false { parametersChanged() } }
    }

    private weak var model: DataViewModel?
    private let queue: DispatchQueue
    private var activeToken: PluginRunToken?
    private var pendingRun: DispatchWorkItem?
    private var storeObserver: AnyCancellable?

    /// What the last run was given. A change is only real if the current values
    /// differ from these — which is also how a plugin writing values back into
    /// the controls avoids triggering another run.
    private var lastRunParameters: [String: Any] = [:]

    private let debounce: TimeInterval = 0.12

    init(plugin: LoadedPlugin, model: DataViewModel) {
        self.plugin = plugin
        self.model = model
        self.store = PluginParameterStore(descriptors: PluginParameterDescriptor.parse(plugin.parameters(for: model)))
        self.queue = DispatchQueue(label: "lebeaugroup.stemexplorer.plugin.live.\(plugin.identifier)",
                                   qos: .userInitiated)

        // objectWillChange fires before the value lands, so read it next turn.
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.parametersChanged() }
        }

        // A button press is an action; run at once rather than waiting for the
        // debounce that smooths out slider drags.
        store.onTrigger = { [weak self] _ in self?.runNow() }

        runNow()
    }

    deinit {
        pendingRun?.cancel()
        activeToken?.cancel()
    }

    // MARK: Triggering

    private func parametersChanged() {
        guard liveUpdate else { return }
        guard !PluginLiveSession.parameters(store.objectValues(), match: lastRunParameters,
                                            ignoring: store.buttonIdentifiers) else { return }
        scheduleRun()
    }

    private func scheduleRun() {
        pendingRun?.cancel()
        // Stop the run in flight; its result is already stale.
        activeToken?.cancel()

        let work = DispatchWorkItem { [weak self] in self?.runNow() }
        pendingRun = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func runNow() {
        pendingRun?.cancel()
        pendingRun = nil
        activeToken?.cancel()

        guard let model = model else { return }
        guard !plugin.requiresData || model.imageWidth > 0 else {
            errorMessage = "Open a 4D dataset to run this plugin."
            return
        }
        guard !model.isLoading else {
            errorMessage = "Waiting for the current file to finish loading."
            return
        }

        let token = PluginRunToken()
        activeToken = token
        isRunning = true
        progress = 0

        // Re-snapshot every run, so detector edits in the main window are
        // picked up rather than frozen at the moment this window opened.
        let snapshot = model.makePluginSnapshot()
        let dataController = model.dataController
        let fileRoot = model.selectedURL?.deletingPathExtension().lastPathComponent ?? ""
        // Take the values while the press is still pending, so this run — and
        // only this run — sees the button as true.
        let parameters = store.objectValues()
        store.clearTrigger()
        let plugin = self.plugin
        lastRunParameters = parameters

        let context = PluginHostContext(
            dataController: dataController,
            snapshot: snapshot,
            token: token,
            progressHandler: { [weak self] fraction in
                DispatchQueue.main.async {
                    guard let self = self, self.activeToken === token else { return }
                    self.progress = fraction
                }
            },
            logHandler: { message in
                NSLog("[Plugin %@] %@", plugin.name, message)
            }
        )

        let started = Date()
        queue.async { [weak self] in
            let returned = plugin.instance.run(host: context, parameters: parameters)
            let elapsed = Date().timeIntervalSince(started)

            DispatchQueue.main.async {
                guard let self = self, self.activeToken === token else { return }   // superseded
                self.activeToken = nil
                self.isRunning = false
                if token.isCancelled { return }
                self.lastRunDuration = elapsed
                self.consume(returned, fileRoot: fileRoot)
            }
        }
    }

    private func consume(_ returned: [String: Any]?, fileRoot: String) {
        // Apply any parameter writeback first, and record the result as the
        // baseline so it does not read as a user edit and start another run.
        if let updates = returned?[FDSResultKey.parameters] as? [String: Any], !updates.isEmpty {
            store.apply(updates)
            lastRunParameters = store.objectValues()
        }

        switch PluginResultParser.parse(returned, pluginName: plugin.name, fileRoot: fileRoot) {
        case .success(let payload):
            errorMessage = nil
            self.payload = payload
            // Rendered once here, as the result window does, so the zoom in the
            // image view survives unrelated redraws.
            self.image = payload.makeImage()
        case .failure(let reason):
            // Empty means the plugin stopped on its own; keep showing the last
            // good result rather than blanking the window.
            if !reason.isEmpty { errorMessage = reason }
        }
    }

    func cancel() {
        pendingRun?.cancel()
        activeToken?.cancel()
    }

    private static func parameters(_ lhs: [String: Any], match rhs: [String: Any],
                                   ignoring skipped: Set<String> = []) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (key, value) in lhs where !skipped.contains(key) {
            guard let other = rhs[key],
                  let a = value as? NSObject,
                  let b = other as? NSObject,
                  a.isEqual(b) else { return false }
        }
        return true
    }
}

// MARK: - View

struct PluginLiveView: View {
    @ObservedObject var session: PluginLiveSession

    var body: some View {
        HSplitView {
            controlPane
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 520)
            resultPane
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controlPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !session.plugin.summary.isEmpty {
                Text(session.plugin.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                PluginParameterControls(store: session.store)
                    .padding(.trailing, 2)
            }

            Divider()

            HStack {
                Toggle("Live", isOn: $session.liveUpdate)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Re-run whenever a control changes")
                Spacer()
                if let citations = session.plugin.citations {
                    Button("Citations…") {
                        PluginCitationsWindowController.present(pluginName: session.plugin.name,
                                                               library: citations)
                    }
                    .controlSize(.small)
                    .help("Papers and software behind this plugin's method, with BibTeX export")
                }
                Button("Run") { session.runNow() }
                    .keyboardShortcut(.defaultAction)
            }

            statusLine
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var statusLine: some View {
        if session.isRunning {
            VStack(alignment: .leading, spacing: 3) {
                if session.progress > 0 {
                    ProgressView(value: session.progress, total: 1.0)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(session.progress > 0 ? "\(Int(session.progress * 100))%" : "Working…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let error = session.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let duration = session.lastRunDuration {
            Text(String(format: "Updated in %.2f s", duration))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var resultPane: some View {
        if let payload = session.payload {
            PluginResultView(payload: payload, image: session.image)
        } else if session.isRunning {
            VStack(spacing: 8) {
                ProgressView()
                Text("Running \(session.plugin.name)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(session.errorMessage ?? "No result yet.")
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Window

final class PluginLiveWindowController: NSObject, NSWindowDelegate {

    private static var open: [PluginLiveWindowController] = []

    private var window: NSWindow?
    private var session: PluginLiveSession?

    static func present(plugin: LoadedPlugin, model: DataViewModel) {
        // One live window per plugin; a second would fight the first over the
        // plugin's cached state.
        if let existing = open.first(where: { $0.session?.plugin.identifier == plugin.identifier }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = PluginLiveWindowController()
        controller.show(plugin: plugin, model: model)
        open.append(controller)
    }

    private func show(plugin: LoadedPlugin, model: DataViewModel) {
        let session = PluginLiveSession(plugin: plugin, model: model)
        self.session = session

        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let size = NSSize(width: min(1020, visible.width - 80), height: min(680, visible.height - 80))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = plugin.name
        window.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: PluginLiveView(session: session))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 720, height: 420)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                       height: CGFloat.greatestFiniteMagnitude)

        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        session?.cancel()
        session = nil
        window?.delegate = nil
        window = nil
        PluginLiveWindowController.open.removeAll { $0 === self }
    }
}
