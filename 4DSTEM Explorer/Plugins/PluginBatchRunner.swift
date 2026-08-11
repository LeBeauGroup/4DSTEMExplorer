//
//  PluginBatchRunner.swift
//  4DSTEM Explorer
//
//  Running one plugin, with one set of parameters, over many files.
//
//  The point of holding the parameters fixed is that the comparison between
//  datasets is then a comparison of the specimens rather than of the settings.
//  Tuning a measurement on one file and then repeating it by hand on forty is
//  both tedious and unreliable — the fortieth rarely has quite the same numbers
//  as the first — so the parameters come from the window where they were tuned
//  and are not touched again.
//
//  Nothing here needs a user interface. A plugin is a function of a host context
//  and a parameter dictionary, and `PluginHostContext` is built from a data
//  controller, so a batch opens each file into a controller of its own and runs
//  the plugin against it exactly as the live window would.
//
//  Two deliberate choices, both of which show up in the manifest:
//
//    * each file's calibration is whatever that file carries. Nothing is
//      inherited from the session or from the file before it, because a batch
//      that spans two microscopes would otherwise write one instrument's
//      calibration onto the other's data and produce numbers that look fine.
//    * a file that cannot be read, cannot be sized, or that the plugin refuses
//      is recorded and stepped over. A forty-file run started in the evening is
//      worth more finished with three failures listed than halted at the first.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import AppKit

// MARK: - What to run

struct PluginBatchJob {

    let plugin: LoadedPlugin
    let files: [URL]

    /// The parameters as tuned in the live window, used unchanged for every file.
    let parameters: [String: Any]

    /// The parameter that selects which result the plugin returns, and the
    /// values of it to run. Empty runs once with `parameters` as they stand.
    let outputParameter: String?
    let outputs: [String]

    /// Folder to write into. One subfolder per input file.
    let destination: URL

    /// The detectors as configured in the application, so a plugin that asks
    /// for a mask or a computed image gets the same ones for every file.
    let detectors: [DetectorConfiguration]
    let selectedDetectorIDs: Set<DetectorConfiguration.ID>

    /// Total number of plugin runs this job implies.
    var runCount: Int { return files.count * max(1, outputs.count) }
}

// MARK: - What happened

struct PluginBatchOutcome {

    enum Status {
        case completed
        case skipped(String)
        case failed(String)

        var word: String {
            switch self {
            case .completed: return "completed"
            case .skipped:   return "skipped"
            case .failed:    return "failed"
            }
        }
        var reason: String? {
            switch self {
            case .completed:            return nil
            case .skipped(let why):     return why
            case .failed(let why):      return why
            }
        }
    }

    let url: URL
    var status: Status = .completed
    var outputsWritten: [String] = []
    var filesWritten: [String] = []
    var seconds: Double = 0
    var scanShape: [Int]? = nil
    var patternShape: [Int]? = nil
    var calibration: [String: Any] = [:]

    var dictionary: [String: Any] {
        var out: [String: Any] = [
            "file": url.lastPathComponent,
            "path": url.path,
            "status": status.word,
            "seconds": (seconds * 1000).rounded() / 1000,
            "outputs": outputsWritten,
            "written": filesWritten
        ]
        if let reason = status.reason { out["reason"] = reason }
        if let shape = scanShape { out["scan_shape"] = shape }
        if let shape = patternShape { out["pattern_shape"] = shape }
        if !calibration.isEmpty { out["calibration"] = calibration }
        return out
    }
}

// MARK: - The runner

final class PluginBatchRunner: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentFile: String = ""
    @Published private(set) var currentStep: String = ""
    @Published private(set) var outcomes: [PluginBatchOutcome] = []
    @Published private(set) var log: [String] = []
    @Published private(set) var manifestURL: URL? = nil

    private var token = LoadCancellationToken()
    private var cancelled = false

    var completedCount: Int {
        outcomes.filter { if case .completed = $0.status { return true } else { return false } }.count
    }
    var failedCount: Int { outcomes.count - completedCount }

    func cancel() {
        cancelled = true
        token.cancel()
    }

    // MARK: Running

    func start(_ job: PluginBatchJob) {
        guard !isRunning, !job.files.isEmpty else { return }
        isRunning = true
        progress = 0
        outcomes = []
        log = []
        manifestURL = nil
        cancelled = false
        token = LoadCancellationToken()

        // Off the main thread, and it must be: each file is loaded by waiting on
        // the data controller, whose completion is delivered *to* the main
        // thread. Waiting there would deadlock on the first file.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(job)
        }
    }

    private func run(_ job: PluginBatchJob) {
        let started = Date()
        note("Running \(job.plugin.name) on \(job.files.count) file\(job.files.count == 1 ? "" : "s").")

        var results: [PluginBatchOutcome] = []
        for (index, url) in job.files.enumerated() {
            if cancelled { note("Cancelled."); break }

            DispatchQueue.main.async {
                self.currentFile = url.lastPathComponent
                self.progress = Double(index) / Double(job.files.count)
            }

            let outcome = process(url, job: job)
            results.append(outcome)
            DispatchQueue.main.async { self.outcomes = results }

            switch outcome.status {
            case .completed:
                note("✓ \(url.lastPathComponent) — \(outcome.outputsWritten.joined(separator: ", "))")
            case .skipped(let why):
                note("– \(url.lastPathComponent) skipped: \(why)")
            case .failed(let why):
                note("✗ \(url.lastPathComponent) failed: \(why)")
            }
        }

        let manifest = writeManifest(results, job: job, seconds: Date().timeIntervalSince(started))
        DispatchQueue.main.async {
            self.manifestURL = manifest
            self.progress = 1
            self.currentFile = ""
            self.currentStep = ""
            self.isRunning = false
        }
        let done = results.filter { if case .completed = $0.status { return true } else { return false } }.count
        note("Finished: \(done) of \(results.count) completed.")
    }

    /// One file, start to finish.
    private func process(_ url: URL, job: PluginBatchJob) -> PluginBatchOutcome {
        var outcome = PluginBatchOutcome(url: url)
        let started = Date()
        defer { outcome.seconds = Date().timeIntervalSince(started) }

        // 1. On this machine. A placeholder would otherwise be fetched inside
        //    the first read, silently, with the batch appearing to hang.
        step("waiting for \(url.lastPathComponent)")
        do {
            try FileMaterializer.ensureLocal(url, token: token) { _, line in
                self.step(line)
            }
        } catch {
            outcome.status = .failed((error as? LocalizedError)?.errorDescription
                                     ?? error.localizedDescription)
            return outcome
        }
        if cancelled { outcome.status = .skipped("cancelled"); return outcome }

        // 2. RAW carries no dimensions, and a batch cannot ask. A sidecar or the
        //    filename can answer; nothing else may, because a guessed raster
        //    reads the file as a valid dataset of the wrong shape.
        let controller = STEMDataController()
        controller.filePath = url
        if url.pathExtension.lowercased() == "raw" {
            guard let raw = rawGeometry(for: url) else {
                outcome.status = .skipped("a RAW file needs its scan dimensions, and neither a sidecar nor the filename gives them")
                return outcome
            }
            controller.setRawImageSize(width: raw.width, height: raw.height)
            controller.setRawTransforms(flipRows: raw.flips.flipY, flipCols: raw.flips.flipX,
                                        transpose: raw.flips.transpose)
            controller.calibrations = raw.calibrations
        }

        // 3. Read it, and wait.
        step("reading \(url.lastPathComponent)")
        let loader = BatchLoader()
        controller.delegate = loader
        do {
            try controller.openFile(url: url)
        } catch {
            outcome.status = .failed(describe(error))
            return outcome
        }
        guard loader.wait(seconds: 3600) else {
            controller.cancelLoad()
            outcome.status = .failed("timed out while reading")
            return outcome
        }
        if let failure = loader.failure {
            outcome.status = .failed(describe(failure))
            return outcome
        }
        if cancelled { outcome.status = .skipped("cancelled"); return outcome }

        outcome.scanShape = [controller.imageSize.width, controller.imageSize.height]
        outcome.patternShape = [controller.patternSize.width, controller.patternSize.height]
        outcome.calibration = describe(controller.calibrations)

        // 4. Somewhere to put it.
        let folder = job.destination.appendingPathComponent(
            PluginBatchNaming.folderName(for: url), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            outcome.status = .failed("could not create \(folder.lastPathComponent): \(error.localizedDescription)")
            return outcome
        }

        // 5. Run, once per ticked output.
        let snapshot = makeSnapshot(controller: controller, job: job)
        let variants: [(name: String, parameters: [String: Any])]
        if let key = job.outputParameter, !job.outputs.isEmpty {
            variants = job.outputs.map { value in
                var parameters = job.parameters
                parameters[key] = value
                return (value, parameters)
            }
        } else {
            variants = [("result", job.parameters)]
        }

        var anySucceeded = false
        var lastFailure: String? = nil
        for variant in variants {
            if cancelled { break }
            step("\(url.lastPathComponent) — \(variant.name)")

            let context = PluginHostContext(dataController: controller,
                                            snapshot: snapshot,
                                            token: PluginRunToken(),
                                            progressHandler: { _ in },
                                            logHandler: { _ in })
            let returned = job.plugin.instance.run(host: context, parameters: variant.parameters)
            let parsed = PluginResultParser.parse(returned,
                                                  pluginName: job.plugin.name,
                                                  fileRoot: url.deletingPathExtension().lastPathComponent)
            switch parsed {
            case .failure(let why):
                lastFailure = why.isEmpty ? "cancelled" : why
            case .success(let payload):
                let written = write(payload, named: variant.name, into: folder)
                if written.isEmpty {
                    lastFailure = "nothing could be written for \(variant.name)"
                } else {
                    anySucceeded = true
                    outcome.outputsWritten.append(variant.name)
                    outcome.filesWritten.append(contentsOf: written)
                }
            }
        }

        writeRunRecord(outcome: outcome, job: job, into: folder)

        if cancelled && !anySucceeded {
            outcome.status = .skipped("cancelled")
        } else if !anySucceeded {
            outcome.status = .failed(lastFailure ?? "the plugin returned nothing")
        }
        return outcome
    }

    // MARK: Writing

    /// Everything one result has to offer, as files. Returns what was written.
    private func write(_ payload: PluginResultPayload, named name: String,
                       into folder: URL) -> [String] {
        var written: [String] = []
        let stem = PluginBatchNaming.safeName(name)

        switch payload.kind {
        case .scanImage, .pattern:
            if let matrix = payload.matrix,
               let image = matrix.floatImageRep().cgImage {
                let url = folder.appendingPathComponent("\(stem).tif")
                PluginResultExporter.writeTIFFPublic(image, to: url)
                if FileManager.default.fileExists(atPath: url.path) {
                    written.append(url.lastPathComponent)
                }
            }
        case .plot:
            let url = folder.appendingPathComponent("\(stem).csv")
            let text = zip(payload.x, payload.y)
                .map { "\($0),\($1)" }
                .joined(separator: "\n")
            if (try? ("x,y\n" + text).write(to: url, atomically: true, encoding: .utf8)) != nil {
                written.append(url.lastPathComponent)
            }
        case .text:
            let url = folder.appendingPathComponent("\(stem).txt")
            if (try? payload.text.write(to: url, atomically: true, encoding: .utf8)) != nil {
                written.append(url.lastPathComponent)
            }
        }

        // Everything the plugin attached, which for a plugin that attaches is
        // the whole measurement rather than the one view of it on screen.
        if !payload.datasets.isEmpty {
            let ext = payload.exportExtension ?? "h5"
            let url = folder.appendingPathComponent("\(stem).\(ext)")
            do {
                try PluginResultExporter.writeHDF5(payload, to: url)
                written.append(url.lastPathComponent)
            } catch {
                note("  could not write \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return written
    }

    private func writeRunRecord(outcome: PluginBatchOutcome, job: PluginBatchJob, into folder: URL) {
        var record = outcome.dictionary
        record["plugin"] = job.plugin.name
        record["plugin_identifier"] = job.plugin.identifier
        record["parameters"] = PluginBatchNaming.jsonSafe(job.parameters)
        record["outputs_requested"] = job.outputs
        record["written_at"] = ISO8601DateFormatter().string(from: Date())
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record,
                                                     options: [.prettyPrinted, .sortedKeys,
                                                               .withoutEscapingSlashes]) else { return }
        try? data.write(to: folder.appendingPathComponent("run.json"))
    }

    @discardableResult
    private func writeManifest(_ results: [PluginBatchOutcome], job: PluginBatchJob,
                               seconds: Double) -> URL? {
        let manifest: [String: Any] = [
            "plugin": job.plugin.name,
            "plugin_identifier": job.plugin.identifier,
            "parameters": PluginBatchNaming.jsonSafe(job.parameters),
            "outputs_requested": job.outputs,
            "files": results.count,
            "completed": results.filter { if case .completed = $0.status { return true } else { return false } }.count,
            "seconds": (seconds * 10).rounded() / 10,
            "written_at": ISO8601DateFormatter().string(from: Date()),
            "calibration_policy": "Each file's own; nothing inherited from the session or from other files.",
            "results": results.map { $0.dictionary }
        ]
        guard JSONSerialization.isValidJSONObject(manifest),
              let data = try? JSONSerialization.data(withJSONObject: manifest,
                                                     options: [.prettyPrinted, .sortedKeys,
                                                               .withoutEscapingSlashes]) else { return nil }
        let url = job.destination.appendingPathComponent("manifest.json")
        try? FileManager.default.createDirectory(at: job.destination, withIntermediateDirectories: true)
        try? data.write(to: url)
        return url
    }

    // MARK: Pieces

    /// The scan dimensions and calibration a RAW file can be opened with.
    ///
    /// A sidecar first — it says more — then the `scan_x180_y180` convention in
    /// the name. Nothing else: a batch that guessed would read the file as a
    /// perfectly valid dataset of the wrong shape, and nothing downstream could
    /// tell.
    private func rawGeometry(for url: URL)
        -> (width: Int, height: Int, flips: DetectorFlips, calibrations: Calibrations?)? {

        for candidate in PluginBatchNaming.sidecarCandidates(for: url) {
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let metadata = try? ScanMetadata.read(url: candidate),
                  let width = metadata.scanWidth, let height = metadata.scanHeight,
                  width > 0, height > 0 else { continue }
            let flips = metadata.detectorFlips.flatMap { DetectorFlips(triple: $0) }
                ?? .empadDefault
            let calibrations = Calibrations(
                scan_step: metadata.scanStepNanometres,
                diff_step: metadata.diffractionStepMilliradians,
                voltage: metadata.voltageKilovolts,
                scanRotationDegrees: metadata.scanRotationDegrees,
                scanCorrection: metadata.scanCorrectionRowMajor.flatMap { ScanCorrection(rowMajor: $0) },
                detectorFlips: flips)
            return (width, height, flips, calibrations)
        }

        if let size = ScanMetadata.dimensions(fromFilename: url.lastPathComponent) {
            // The name gives a raster and nothing else, so the calibration stays
            // empty and any plugin needing one will say so.
            return (size.width, size.height, .empadDefault, nil)
        }
        return nil
    }

    private func makeSnapshot(controller: STEMDataController,
                              job: PluginBatchJob) -> PluginDataSnapshot {
        // A computed image, for the plugins that measure one. Costs a pass over
        // the stack, which is small beside the read that just happened, and
        // without it every plugin that reads `currentScanImageData` would fail
        // on every file in the batch.
        var scanImage: Matrix? = nil
        if let config = job.detectors.first(where: { job.selectedDetectorIDs.contains($0.id) })
            ?? job.detectors.first {
            let centre = NSPoint(x: config.center.x, y: config.center.y)
            let detector = Detector(shape: config.shape, type: config.type, center: centre,
                                    params: [.innerRadius: Float(config.innerRadius),
                                             .outerRadius: Float(config.outerRadius)],
                                    size: NSSize(width: controller.patternSize.width,
                                                 height: controller.patternSize.height))
            let matrix = controller.integrating(detector, strideLength: 1)
            if matrix.rows > 0 && matrix.columns > 0 { scanImage = matrix }
        }

        return PluginDataSnapshot(
            fileName: controller.filePath?.lastPathComponent ?? "",
            filePath: controller.filePath?.path ?? "",
            scanStepNanometers: Double(controller.calibrations?.scan_step ?? 0),
            diffractionStepMilliradians: Double(controller.calibrations?.diff_step ?? 0),
            accelerationKilovolts: Double(controller.calibrations?.voltage ?? 0),
            detectorFlips: controller.currentDetectorFlips,
            selectedRow: controller.imageSize.height / 2,
            selectedColumn: controller.imageSize.width / 2,
            selectionRect: nil,
            currentPattern: controller.pattern(controller.imageSize.height / 2,
                                               controller.imageSize.width / 2),
            currentScanImage: scanImage,
            detectors: job.detectors,
            selectedDetectorIDs: job.selectedDetectorIDs)
    }

    private func describe(_ calibrations: Calibrations?) -> [String: Any] {
        guard let c = calibrations else { return [:] }
        var out: [String: Any] = [:]
        if let v = c.scan_step { out["scan_step_nm"] = Double(v) }
        if let v = c.diff_step { out["diff_step_mrad"] = Double(v) }
        if let v = c.voltage { out["voltage_kv"] = Double(v) }
        if let v = c.scanRotationDegrees { out["scan_rotation_deg"] = Double(v) }
        if let v = c.scanCorrection { out["scan_correction"] = v.rows.map { $0.map(Double.init) } }
        if let v = c.detectorFlips { out["det_flips"] = v.triple }
        return out
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case FileReadError.invalidTiff:       return "not a readable TIFF stack"
        case FileReadError.invalidRaw:        return "not a readable RAW file"
        case FileReadError.invalidDimensions: return "the dimensions in the file do not describe a 4D dataset"
        case FileReadError.notDiffractionSI:  return "no “Diffraction SI” image in this file"
        default:
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func note(_ line: String) {
        DispatchQueue.main.async { self.log.append(line) }
    }
    private func step(_ line: String) {
        DispatchQueue.main.async { self.currentStep = line }
    }

}

// MARK: - Waiting for a load

/// Turns the data controller's delegate callbacks into something a batch can
/// wait on.
private final class BatchLoader: NSObject, STEMDataControllerDelegate {

    private let semaphore = DispatchSemaphore(value: 0)
    private(set) var failure: Error?

    func didFinishLoadingData() -> (pattern: NSImage?, virtual: NSImage?) {
        semaphore.signal()
        return (nil, nil)
    }

    func didFailLoadingData(_ error: Error) {
        failure = error
        semaphore.signal()
    }

    /// True if the load finished, false if it took longer than `seconds`.
    func wait(seconds: TimeInterval) -> Bool {
        return semaphore.wait(timeout: .now() + seconds) == .success
    }
}
