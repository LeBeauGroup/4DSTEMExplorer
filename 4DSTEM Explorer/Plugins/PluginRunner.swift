//
//  PluginRunner.swift
//  4DSTEM Explorer
//
//  Drives a plugin: collect parameters, run it off the main thread with
//  progress and cancellation, then present whatever it returned.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import SwiftUI
import AppKit

// MARK: - Runner

final class PluginRunner: ObservableObject {

    static let shared = PluginRunner()

    @Published private(set) var isRunning: Bool = false

    private var sheet: PluginSheetController?
    private var token: PluginRunToken?
    private var log: [String] = []
    private let logLock = NSLock()

    private init() {}

    /// Entry point from the Plugins menu.
    func run(_ plugin: LoadedPlugin, model: DataViewModel) {
        guard !isRunning else { return }

        if plugin.requiresData && model.imageWidth == 0 {
            PluginRunner.presentAlert(style: .informational,
                                      title: plugin.name,
                                      message: "Open a 4D dataset before running this plugin.")
            return
        }
        if model.isLoading {
            PluginRunner.presentAlert(style: .informational,
                                      title: plugin.name,
                                      message: "Wait for the current file to finish loading.")
            return
        }

        let descriptors = PluginParameterDescriptor.parse(plugin.parameters)
        guard !descriptors.isEmpty else {
            execute(plugin, parameters: [:], model: model)
            return
        }

        let store = PluginParameterStore(descriptors: descriptors)
        let controller = PluginSheetController()
        sheet = controller

        controller.present(title: plugin.name, width: 460) {
            PluginParameterSheet(
                pluginName: plugin.name,
                summary: plugin.summary,
                store: store,
                onCancel: { [weak self] in
                    controller.dismiss()
                    self?.sheet = nil
                },
                onRun: { [weak self] in
                    controller.dismiss()
                    self?.sheet = nil
                    self?.execute(plugin, parameters: store.objectValues(), model: model)
                }
            )
        }
    }

    // MARK: - Execution

    private func execute(_ plugin: LoadedPlugin, parameters: [String: Any], model: DataViewModel) {
        let token = PluginRunToken()
        self.token = token
        logLock.lock(); log = []; logLock.unlock()

        let progress = PluginProgressModel(pluginName: plugin.name)
        let controller = PluginSheetController()
        sheet = controller
        isRunning = true

        controller.present(title: plugin.name, width: 360, maximumHeight: 200) {
            PluginProgressSheet(model: progress, onCancel: {
                token.cancel()
                progress.note = "Cancelling…"
            })
        }

        let snapshot = model.makePluginSnapshot()
        let context = PluginHostContext(
            dataController: model.dataController,
            snapshot: snapshot,
            token: token,
            progressHandler: { [weak progress] fraction in
                // Called from the plugin's thread; the model is main-thread only.
                DispatchQueue.main.async { progress?.fraction = fraction }
            },
            logHandler: { [weak self] message in
                guard let self = self else { return }
                self.logLock.lock()
                if self.log.count < 200 { self.log.append(message) }
                self.logLock.unlock()
                NSLog("[Plugin %@] %@", plugin.name, message)
            }
        )

        let fileRoot = model.selectedURL?.deletingPathExtension().lastPathComponent ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let returned = plugin.instance.run(host: context, parameters: parameters)

            DispatchQueue.main.async {
                guard let self = self else { return }
                controller.dismiss()
                self.sheet = nil
                self.token = nil
                self.isRunning = false

                if token.isCancelled { return }

                switch PluginResultParser.parse(returned, pluginName: plugin.name, fileRoot: fileRoot) {
                case .success(let payload):
                    PluginResultWindowController.present(payload)
                case .failure(let reason):
                    // An empty reason means the plugin returned nil, which is
                    // how a plugin signals it stopped on its own.
                    guard !reason.isEmpty else { return }
                    self.logLock.lock()
                    let tail = self.log.suffix(10).joined(separator: "\n")
                    self.logLock.unlock()
                    PluginRunner.presentAlert(
                        style: .warning,
                        title: "\(plugin.name) did not produce a result",
                        message: tail.isEmpty ? reason : "\(reason)\n\n\(tail)"
                    )
                }
            }
        }
    }

    // MARK: - Alerts

    static func presentAlert(style: NSAlert.Style, title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = PluginSheetController.hostWindow() {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - View model snapshot

extension DataViewModel {

    /// Freezes the state a plugin is allowed to see. Called on the main thread
    /// before the run starts so the plugin never reads `@Published` properties
    /// from its background queue.
    func makePluginSnapshot() -> PluginDataSnapshot {
        var selectedRow = -1
        var selectedColumn = -1
        var rect: CGRect? = nil

        if let point = selected as? (Int, Int) {
            selectedRow = point.0
            selectedColumn = point.1
        } else if let selectionRect = selected as? CGRect {
            rect = selectionRect.standardized
        }

        return PluginDataSnapshot(
            fileName: selectedURL?.lastPathComponent ?? "",
            filePath: selectedURL?.path ?? "",
            scanStepNanometers: Double(calibrations?.scan_step ?? 0),
            diffractionStepMilliradians: Double(calibrations?.diff_step ?? 0),
            selectedRow: selectedRow,
            selectedColumn: selectedColumn,
            selectionRect: rect,
            currentPattern: pattern_mat,
            currentScanImage: lastScanMatrix,
            detectors: detectors,
            selectedDetectorIDs: selectedDetectorIDs
        )
    }
}
