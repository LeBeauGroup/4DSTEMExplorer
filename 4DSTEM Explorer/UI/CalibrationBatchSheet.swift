//
//  CalibrationBatchSheet.swift
//  4DSTEM Explorer
//
//  Choosing a folder to calibrate, and watching it happen.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import SwiftUI
import AppKit

struct CalibrationBatchSheet: View {

    let onClose: () -> Void

    @StateObject private var runner = CalibrationBatchRunner()
    @State private var root: URL? = nil
    @State private var settings = CalibrationBatchSettings()
    @State private var convergence = "25"
    @State private var d1 = "3.905"
    @State private var d2 = "3.905"
    @State private var latticeAngle = "90"
    @State private var message: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Batch Calibrations").font(.title3).bold()
            Text("Every dataset under the chosen folder is calibrated in turn, seeded from whatever metadata sits beside it — a JSON sidecar for preference, otherwise an acquisition XML. Each file uses only its own; nothing is carried over from the file before it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text("Folder").font(.headline)
                Spacer()
                Text(root?.path ?? "not chosen")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                Button("Choose…") { chooseRoot() }
            }
            if !runner.discovered.isEmpty {
                Text("\(runner.discovered.count) dataset\(runner.discovered.count == 1 ? "" : "s") found.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Text("Measure").font(.headline)

            Toggle("Diffraction step, from the bright-field disc", isOn: $settings.measureDiffractionStep)
            if settings.measureDiffractionStep {
                HStack {
                    Text("Convergence semi-angle").frame(width: 190, alignment: .leading)
                    TextField("", text: $convergence).frame(width: 70)
                    Text("mrad").foregroundStyle(.secondary)
                }.padding(.leading, 20)
            }

            Toggle("Scan rotation, by minimising the centre-of-mass curl", isOn: $settings.measureScanRotation)
            if settings.measureScanRotation {
                Text("Reads every pattern in every dataset, so this is the slow one.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
            }

            Toggle("Step size, from a known lattice in the computed image", isOn: $settings.measureStepSize)
            if settings.measureStepSize {
                HStack {
                    Text("Known spacings").frame(width: 190, alignment: .leading)
                    TextField("", text: $d1).frame(width: 60)
                    Text("×")
                    TextField("", text: $d2).frame(width: 60)
                    Text("Å at")
                    TextField("", text: $latticeAngle).frame(width: 50)
                    Text("°")
                }.padding(.leading, 20)
                Text("Only meaningful where every dataset in the tree is the same material on the same zone axis.")
                    .font(.caption).foregroundStyle(.orange).padding(.leading, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Results are written as <name>_calib.json beside each dataset. Where that name is already taken — which it is wherever a sidecar seeded the run — <name>_calib.measured.json is written instead, so nothing existing is replaced.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if runner.isRunning || !runner.outcomes.isEmpty {
                Divider()
                if runner.isRunning {
                    ProgressView(value: runner.progress, total: 1)
                    Text(runner.currentStep).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("\(runner.completedCount) of \(runner.outcomes.count) calibrated.")
                        .font(.callout)
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
            if let message = message {
                Text(message).font(.callout).foregroundStyle(.orange)
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
                }.keyboardShortcut(.cancelAction)
                Button("Run") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(runner.isRunning || root == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 600)
    }

    private func start() {
        guard let root = root else { return }
        var job = settings
        job.convergenceMilliradians = Double(convergence) ?? 25
        job.d1 = Double(d1) ?? 0
        job.d2 = Double(d2) ?? 0
        job.latticeAngleDegrees = Double(latticeAngle) ?? 0

        guard job.anythingToDo else {
            message = "Tick at least one measurement, or there is nothing to do."
            return
        }
        if job.measureDiffractionStep && !(job.convergenceMilliradians > 0) {
            message = "The disc measurement needs a convergence semi-angle."
            return
        }
        if job.measureStepSize && !(job.d1 > 0 && job.d2 > 0
                                    && job.latticeAngleDegrees > 0 && job.latticeAngleDegrees < 180) {
            message = "The lattice measurement needs positive spacings and an angle between 0 and 180°."
            return
        }
        message = nil
        runner.start(root: root, settings: job)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder to calibrate. Every subfolder is searched."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url
        runner.survey(root: url)
    }
}
