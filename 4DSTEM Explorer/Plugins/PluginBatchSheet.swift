//
//  PluginBatchSheet.swift
//  4DSTEM Explorer
//
//  Choosing the files for a batch, and watching it run.
//
//  Opened from the plugin's own window so that the parameters come across
//  already set. That is the whole ergonomic point: the settings have just been
//  tuned against a dataset on screen, and asking for them again in a separate
//  dialog is both tedious and the place a batch quietly diverges from the run it
//  was meant to reproduce.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PluginBatchSheet: View {

    let plugin: LoadedPlugin
    /// Parameters exactly as the live window has them.
    let parameters: [String: Any]
    let detectors: [DetectorConfiguration]
    let selectedDetectorIDs: Set<DetectorConfiguration.ID>
    let onClose: () -> Void

    @StateObject private var runner = PluginBatchRunner()
    @State private var files: [URL] = []
    @State private var destination: URL? = nil
    @State private var selectedOutputs: Set<String> = []
    @State private var message: String? = nil

    /// The parameter that chooses which result comes back, if the plugin has
    /// one. Found by looking for a choice parameter — that is what an output
    /// selector is — rather than by insisting on a particular identifier, so a
    /// plugin naming it something else still batches.
    private var outputDescriptor: (identifier: String, choices: [String])? {
        for descriptor in plugin.parameters {
            guard let identifier = descriptor[FDSParameterKey.identifier] as? String,
                  let choices = descriptor[FDSParameterKey.choices] as? [String],
                  !choices.isEmpty else { continue }
            if identifier == "output" { return (identifier, choices) }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Run \(plugin.name) on Files").font(.title3).bold()
                Spacer()
            }
            Text("The parameters are taken from the window you opened this from and used unchanged for every file, so what differs between the results is the data. Each file's own calibration is used; nothing is carried over from this session or from the file before it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            filesSection
            outputsSection
            destinationSection

            if runner.isRunning || !runner.outcomes.isEmpty {
                Divider()
                progressSection
            }
            if let message = message {
                Text(message).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            Divider()

            HStack {
                if let manifest = runner.manifestURL {
                    Button("Show Results") {
                        NSWorkspace.shared.activateFileViewerSelecting([manifest])
                    }
                }
                Spacer()
                Button(runner.isRunning ? "Stop" : "Close") {
                    if runner.isRunning { runner.cancel() } else { onClose() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Run") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(runner.isRunning || files.isEmpty || destination == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 560)
    }

    // MARK: Files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files").font(.headline)
                Spacer()
                Text(files.isEmpty ? "" : "\(files.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Add…") { chooseFiles() }
                Button("Clear") { files = [] }.disabled(files.isEmpty)
            }
            if files.isEmpty {
                Text("No files chosen. Add the datasets to run over — they may be in different folders.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                    .background(Color.secondary.opacity(0.06))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(files, id: \.self) { url in
                            HStack(spacing: 6) {
                                Text(url.lastPathComponent).font(.callout)
                                Text(url.deletingLastPathComponent().lastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if url.pathExtension.lowercased() == "raw",
                                   !PluginBatchNaming.rawIsSizeable(url) {
                                    // Said before the run rather than after: a
                                    // RAW with no sidecar and no size in its name
                                    // cannot be opened unattended, and finding
                                    // that out at file thirty is no use.
                                    Text("no dimensions")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .help("This RAW file has neither a metadata sidecar nor a scan_x…_y… name, so a batch cannot know its raster. It will be skipped.")
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                        }
                    }
                }
                .frame(height: 120)
                .background(Color.secondary.opacity(0.06))
            }
        }
    }

    // MARK: Outputs

    @ViewBuilder
    private var outputsSection: some View {
        if let descriptor = outputDescriptor {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Outputs").font(.headline)
                    Spacer()
                    Button("All") { selectedOutputs = Set(descriptor.choices) }
                    Button("None") { selectedOutputs = [] }
                }
                Text("The plugin is run once for each ticked output. Where it attaches its arrays, those are written too — the whole measurement, not just the view on screen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(descriptor.choices, id: \.self) { choice in
                    Toggle(choice, isOn: Binding(
                        get: { selectedOutputs.contains(choice) },
                        set: { on in
                            if on { selectedOutputs.insert(choice) }
                            else { selectedOutputs.remove(choice) }
                        }))
                }
            }
            .onAppear {
                if selectedOutputs.isEmpty { selectedOutputs = Set(descriptor.choices) }
            }
        } else {
            Text("This plugin returns one result, so it is run once per file.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Destination

    private var destinationSection: some View {
        HStack {
            Text("Results folder").font(.headline)
            Spacer()
            Text(destination?.path ?? "not chosen")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
            Button("Choose…") { chooseDestination() }
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if runner.isRunning {
                ProgressView(value: runner.progress, total: 1)
                Text(runner.currentStep.isEmpty ? runner.currentFile : runner.currentStep)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else if !runner.outcomes.isEmpty {
                Text("\(runner.completedCount) of \(runner.outcomes.count) completed"
                     + (runner.failedCount > 0 ? ", \(runner.failedCount) not" : "."))
                    .font(.callout)
                    .foregroundStyle(runner.failedCount > 0 ? .orange : .secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(runner.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 110)
            .background(Color.secondary.opacity(0.06))
        }
    }

    // MARK: Actions

    private func start() {
        guard let destination = destination else { return }
        message = nil
        let job = PluginBatchJob(plugin: plugin,
                                 files: files,
                                 parameters: parameters,
                                 outputParameter: outputDescriptor?.identifier,
                                 outputs: outputDescriptor == nil ? [] : Array(selectedOutputs).sorted(),
                                 destination: destination,
                                 detectors: detectors,
                                 selectedDetectorIDs: selectedDetectorIDs)
        if outputDescriptor != nil && selectedOutputs.isEmpty {
            message = "Tick at least one output, or there is nothing to write."
            return
        }
        runner.start(job)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose the datasets to run \(plugin.name) over"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        // Appended and de-duplicated, so a second visit to the panel adds to the
        // list rather than replacing it — the files are often in several folders.
        var seen = Set(files.map { $0.path })
        for url in panel.urls where !seen.contains(url.path) {
            files.append(url)
            seen.insert(url.path)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for the results. One subfolder is made per file."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        destination = panel.url
    }

}
