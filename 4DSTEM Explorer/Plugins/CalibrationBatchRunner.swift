//
//  CalibrationBatchRunner.swift
//  4DSTEM Explorer
//
//  Measuring the calibration of every dataset under a folder.
//
//  A session's worth of acquisitions arrives as a tree of folders, each holding
//  a dataset and whatever metadata the microscope wrote beside it. Calibrating
//  them one at a time is the same handful of gestures forty times over, and the
//  fortieth is not done as carefully as the first.
//
//  Each file's own sidecar seeds the run — the voltage, the raster, the
//  convergence angle, whatever it recorded — and the measurement refines what it
//  can. Nothing is inherited from the file before it, so a tree spanning two
//  microscopes calibrates correctly rather than plausibly.
//
//  What is written is a `_calib.json` beside the data, in the EMPAD metadata
//  format the application and phaser both read. An existing sidecar is never
//  overwritten: the file that seeded the measurement is exactly the file a bad
//  measurement would destroy, so the result goes to `_calib.measured.json`
//  instead and the two can be compared.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import AppKit

struct CalibrationBatchSettings {
    /// Measure the diffraction step from the bright-field disc.
    var measureDiffractionStep = true
    /// Convergence semi-angle, which is what turns a disc radius into an angle.
    var convergenceMilliradians: Double = 25

    /// Measure the scan rotation by minimising the centre-of-mass curl.
    var measureScanRotation = true
    /// Probe positions per side of one centre-of-mass measurement.
    var rotationRebin = 1

    /// Measure the scan step from a lattice in the computed image.
    var measureStepSize = false
    var d1: Double = 3.905
    var d2: Double = 3.905
    var latticeAngleDegrees: Double = 90

    var anythingToDo: Bool {
        return measureDiffractionStep || measureScanRotation || measureStepSize
    }
}

struct CalibrationBatchOutcome {
    let url: URL
    var status: String = "completed"
    var reason: String? = nil
    var seededFrom: String? = nil
    var measured: [String] = []
    var written: String? = nil
    var calibration: [String: Any] = [:]
    var seconds: Double = 0

    var dictionary: [String: Any] {
        var out: [String: Any] = ["file": url.lastPathComponent, "path": url.path,
                                  "status": status, "measured": measured,
                                  "seconds": (seconds * 100).rounded() / 100]
        if let reason = reason { out["reason"] = reason }
        if let seeded = seededFrom { out["seeded_from"] = seeded }
        if let written = written { out["written"] = written }
        if !calibration.isEmpty { out["calibration"] = calibration }
        return out
    }
}

final class CalibrationBatchRunner: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentStep = ""
    @Published private(set) var log: [String] = []
    @Published private(set) var outcomes: [CalibrationBatchOutcome] = []
    @Published private(set) var manifestURL: URL? = nil
    @Published private(set) var discovered: [URL] = []

    private var token = LoadCancellationToken()
    private var cancelled = false

    var completedCount: Int { outcomes.filter { $0.status == "completed" }.count }

    func cancel() { cancelled = true; token.cancel() }

    /// Lists what a run would cover, without running anything.
    func survey(root: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = BatchDiscovery.datasets(under: root)
            DispatchQueue.main.async { self.discovered = found }
        }
    }

    func start(root: URL, settings: CalibrationBatchSettings) {
        guard !isRunning, settings.anythingToDo else { return }
        isRunning = true
        progress = 0
        log = []
        outcomes = []
        manifestURL = nil
        cancelled = false
        token = LoadCancellationToken()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(root: root, settings: settings)
        }
    }

    private func run(root: URL, settings: CalibrationBatchSettings) {
        let started = Date()
        let files = BatchDiscovery.datasets(under: root) { self.cancelled }
        DispatchQueue.main.async { self.discovered = files }
        note("Found \(files.count) dataset\(files.count == 1 ? "" : "s") under \(root.lastPathComponent).")

        var results: [CalibrationBatchOutcome] = []
        for (index, url) in files.enumerated() {
            if cancelled { note("Cancelled."); break }
            DispatchQueue.main.async { self.progress = Double(index) / Double(max(1, files.count)) }
            let outcome = process(url, settings: settings)
            results.append(outcome)
            DispatchQueue.main.async { self.outcomes = results }

            switch outcome.status {
            case "completed":
                note("✓ \(url.lastPathComponent) — \(outcome.measured.joined(separator: ", "))"
                     + (outcome.written.map { " → \($0)" } ?? ""))
            case "skipped":
                note("– \(url.lastPathComponent): \(outcome.reason ?? "")")
            default:
                note("✗ \(url.lastPathComponent): \(outcome.reason ?? "")")
            }
        }

        let manifest = writeManifest(results, root: root, settings: settings,
                                     seconds: Date().timeIntervalSince(started))
        DispatchQueue.main.async {
            self.manifestURL = manifest
            self.progress = 1
            self.currentStep = ""
            self.isRunning = false
        }
        note("Finished: \(results.filter { $0.status == "completed" }.count) of \(results.count) calibrated.")
    }

    // MARK: One file

    private func process(_ url: URL, settings: CalibrationBatchSettings) -> CalibrationBatchOutcome {
        var outcome = CalibrationBatchOutcome(url: url)
        let started = Date()
        defer { outcome.seconds = Date().timeIntervalSince(started) }

        step("waiting for \(url.lastPathComponent)")
        do {
            try FileMaterializer.ensureLocal(url, token: token) { _, line in self.step(line) }
        } catch {
            outcome.status = "failed"
            outcome.reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return outcome
        }
        if cancelled { outcome.status = "skipped"; outcome.reason = "cancelled"; return outcome }

        // The sidecar, which both sizes a RAW file and seeds every calibration.
        let isRaw = url.pathExtension.lowercased() == "raw"
        let seed = BatchDiscovery.seed(for: url, requiringScanSize: isRaw)
        if let seed = seed { outcome.seededFrom = seed.source.lastPathComponent }

        let controller = STEMDataController()
        controller.filePath = url

        var scanWidth = 0, scanHeight = 0
        if isRaw {
            var size: (width: Int, height: Int)? = nil
            if let metadata = seed?.metadata, let w = metadata.scanWidth, let h = metadata.scanHeight {
                size = (w, h)
            } else if let named = ScanMetadata.dimensions(fromFilename: url.lastPathComponent) {
                size = (named.width, named.height)
            }
            guard let size = size else {
                outcome.status = "skipped"
                outcome.reason = "a RAW file needs its raster, and no sidecar here records one"
                return outcome
            }
            scanWidth = size.width; scanHeight = size.height
            controller.setRawImageSize(width: size.width, height: size.height)
            let flips = seed?.metadata.detectorFlips.flatMap { DetectorFlips(triple: $0) }
                ?? .empadDefault
            controller.setRawTransforms(flipRows: flips.flipY, flipCols: flips.flipX,
                                        transpose: flips.transpose)
        }

        // Seeded first, so anything the measurement cannot supply survives.
        var calibration = seed.map { BatchDiscovery.calibrations(from: $0.metadata) }
        controller.calibrations = calibration

        step("reading \(url.lastPathComponent)")
        let loader = CalibrationBatchLoader()
        controller.delegate = loader
        do { try controller.openFile(url: url) }
        catch {
            outcome.status = "failed"; outcome.reason = describe(error); return outcome
        }
        guard loader.wait(seconds: 3600) else {
            controller.cancelLoad()
            outcome.status = "failed"; outcome.reason = "timed out while reading"; return outcome
        }
        if let failure = loader.failure {
            outcome.status = "failed"; outcome.reason = describe(failure); return outcome
        }
        if cancelled { outcome.status = "skipped"; outcome.reason = "cancelled"; return outcome }

        // A file that carries its own calibration — DM does — beats the sidecar.
        if let own = controller.calibrations { calibration = merge(own, over: calibration) }
        scanWidth = controller.imageSize.width
        scanHeight = controller.imageSize.height

        let geometry = (rows: controller.patternSize.height, columns: controller.patternSize.width)
        guard geometry.rows > 0, geometry.columns > 0, scanWidth > 0, scanHeight > 0 else {
            outcome.status = "failed"; outcome.reason = "the file did not resolve to a 4D dataset"
            return outcome
        }

        // 1. Diffraction step, from the bright-field disc of the mean pattern.
        if settings.measureDiffractionStep {
            step("\(url.lastPathComponent) — central disc")
            if let mean = meanPattern(controller),
               let disc = CentralDiskFit.measure(image: mean, rows: geometry.rows,
                                                 columns: geometry.columns),
               let mrad = CentralDiskFit.step(convergenceMilliradians: settings.convergenceMilliradians,
                                              radiusPixels: disc.radius) {
                calibration = Calibrations(scan_step: calibration?.scan_step,
                                           diff_step: Float(mrad),
                                           voltage: calibration?.voltage,
                                           scanRotationDegrees: calibration?.scanRotationDegrees,
                                           scanCorrection: calibration?.scanCorrection,
                                           detectorFlips: calibration?.detectorFlips)
                outcome.measured.append(String(format: "diffraction step %.4g mrad/px", mrad))
            } else {
                outcome.measured.append("diffraction step: no disc found")
            }
        }

        // 2. Scan rotation, which needs nothing but the stack.
        if settings.measureScanRotation, !cancelled {
            step("\(url.lastPathComponent) — scan rotation")
            let engine = ScanRotationEngine()
            let rotationGeometry = ScanRotationGeometry(scanWidth: scanWidth, scanHeight: scanHeight,
                                                        patternWidth: geometry.columns,
                                                        patternHeight: geometry.rows)
            let pixels = controller.patternPixels
            let provider: PatternProvider = { row, column, buffer, capacity in
                guard row >= 0, row < scanHeight, column >= 0, column < scanWidth,
                      capacity >= pixels, let base = controller.patternPointer else { return false }
                buffer.update(from: base + (row * scanWidth + column) * pixels, count: pixels)
                return true
            }
            var rotationSettings = ScanRotationSettings()
            rotationSettings.edgeTrim = 0
            if let field = engine.centreOfMassField(geometry: rotationGeometry, mask: nil,
                                                    identity: url.path, detectorIndex: nil,
                                                    provider: provider,
                                                    isCancelled: { self.cancelled }),
               let (_, solution) = try? engine.solve(field, settings: rotationSettings),
               solution.contrast >= 0.05 {
                calibration = Calibrations(scan_step: calibration?.scan_step,
                                           diff_step: calibration?.diff_step,
                                           voltage: calibration?.voltage,
                                           scanRotationDegrees: Float(solution.rotationDegrees),
                                           scanCorrection: calibration?.scanCorrection,
                                           detectorFlips: calibration?.detectorFlips)
                outcome.measured.append(String(format: "scan rotation %+.3f° (depth %.2f)",
                                               solution.rotationDegrees, solution.contrast))
            } else {
                outcome.measured.append("scan rotation: the curl minimum was too shallow to use")
            }
        }

        // 3. Step size, from a lattice in the computed image.
        if settings.measureStepSize, !cancelled {
            step("\(url.lastPathComponent) — lattice")
            let detector = Detector(shape: .bf, type: .integrating,
                                    center: NSPoint(x: Double(geometry.columns) / 2,
                                                    y: Double(geometry.rows) / 2),
                                    params: [.innerRadius: 0,
                                             .outerRadius: Float(min(geometry.rows, geometry.columns)) / 4],
                                    size: NSSize(width: geometry.columns, height: geometry.rows))
            let image = controller.integrating(detector, strideLength: 1)
            var latticeSettings = CalibrationSettings()
            latticeSettings.isDiffraction = false
            latticeSettings.d1 = settings.d1
            latticeSettings.d2 = settings.d2
            latticeSettings.latticeAngleDegrees = settings.latticeAngleDegrees
            if image.rows > 8, image.columns > 8,
               let result = try? CalibrationEngine().measure(image: image.real, rows: image.rows,
                                                             columns: image.columns,
                                                             identity: url.path,
                                                             settings: latticeSettings),
               let offer = CalibrationEngine().offer(result, kilovolts: Double(calibration?.voltage ?? 0)),
               let nanometres = offer.scanStepNanometres {
                calibration = Calibrations(
                    scan_step: Float(nanometres),
                    diff_step: calibration?.diff_step,
                    voltage: calibration?.voltage,
                    scanRotationDegrees: calibration?.scanRotationDegrees,
                    scanCorrection: offer.scanCorrectionRowMajor
                        .flatMap { ScanCorrection(rowMajor: $0.map(Float.init)) }
                        ?? calibration?.scanCorrection,
                    detectorFlips: calibration?.detectorFlips)
                outcome.measured.append(String(format: "step size %.5g nm/px", nanometres))
            } else {
                outcome.measured.append("step size: no lattice found")
            }
        }

        outcome.calibration = describe(calibration)

        // 4. Write it beside the data, never over what was already there.
        do {
            let destination = BatchDiscovery.destination(for: url)
            let data = try EMPADMetadataWriter.json(url: url, scanWidth: scanWidth,
                                                    scanHeight: scanHeight,
                                                    calibrations: calibration)
            try data.write(to: destination, options: .atomic)
            outcome.written = destination.lastPathComponent
        } catch {
            outcome.status = "failed"
            outcome.reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return outcome
    }

    // MARK: Pieces

    private func meanPattern(_ controller: STEMDataController) -> [Float]? {
        let pixels = controller.patternPixels
        guard pixels > 0, let base = controller.patternPointer else { return nil }
        let count = controller.imageSize.width * controller.imageSize.height
        guard count > 0 else { return nil }
        var total = [Float](repeating: 0, count: pixels)
        // Every position: the mean is what makes the disc edge sharp enough to
        // fit, and one pattern at a time is not worth the noise.
        for index in 0..<count {
            let pattern = base + index * pixels
            for i in 0..<pixels { total[i] += pattern[i] }
        }
        let scale = 1 / Float(count)
        for i in 0..<pixels { total[i] *= scale }
        return total
    }

    private func merge(_ newer: Calibrations, over older: Calibrations?) -> Calibrations {
        return Calibrations(scan_step: newer.scan_step ?? older?.scan_step,
                            diff_step: newer.diff_step ?? older?.diff_step,
                            voltage: newer.voltage ?? older?.voltage,
                            scanRotationDegrees: newer.scanRotationDegrees ?? older?.scanRotationDegrees,
                            scanCorrection: newer.scanCorrection ?? older?.scanCorrection,
                            detectorFlips: newer.detectorFlips ?? older?.detectorFlips)
    }

    private func describe(_ calibrations: Calibrations?) -> [String: Any] {
        guard let c = calibrations else { return [:] }
        var out: [String: Any] = [:]
        if let v = c.scan_step { out["scan_step_nm"] = Double(v) }
        if let v = c.diff_step { out["diff_step_mrad"] = Double(v) }
        if let v = c.voltage { out["voltage_kv"] = Double(v) }
        if let v = c.scanRotationDegrees { out["scan_rotation_deg"] = Double(v) }
        if let v = c.detectorFlips { out["det_flips"] = v.triple }
        return out
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case FileReadError.invalidDimensions: return "the dimensions do not describe a 4D dataset"
        case FileReadError.notDiffractionSI:  return "no “Diffraction SI” image in this file"
        case FileReadError.invalidRaw:        return "not a readable RAW file"
        case FileReadError.invalidTiff:       return "not a readable TIFF stack"
        default:
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @discardableResult
    private func writeManifest(_ results: [CalibrationBatchOutcome], root: URL,
                               settings: CalibrationBatchSettings, seconds: Double) -> URL? {
        var measured: [String] = []
        if settings.measureDiffractionStep { measured.append("diffraction step (central disc)") }
        if settings.measureScanRotation { measured.append("scan rotation (curl minimisation)") }
        if settings.measureStepSize { measured.append("step size (lattice)") }

        let manifest: [String: Any] = [
            "root": root.path,
            "measured": measured,
            "convergence_semi_angle_mrad": settings.convergenceMilliradians,
            "known_lattice": ["d1": settings.d1, "d2": settings.d2,
                              "angle_deg": settings.latticeAngleDegrees],
            "files": results.count,
            "completed": results.filter { $0.status == "completed" }.count,
            "seconds": (seconds * 10).rounded() / 10,
            "written_at": ISO8601DateFormatter().string(from: Date()),
            "policy": "Each dataset seeded from its own sidecar; existing _calib.json files are never overwritten.",
            "results": results.map { $0.dictionary }
        ]
        guard JSONSerialization.isValidJSONObject(manifest),
              let data = try? JSONSerialization.data(withJSONObject: manifest,
                                                     options: [.prettyPrinted, .sortedKeys,
                                                               .withoutEscapingSlashes]) else { return nil }
        let url = root.appendingPathComponent("calibration_batch.json")
        try? data.write(to: url)
        return url
    }

    private func note(_ line: String) { DispatchQueue.main.async { self.log.append(line) } }
    private func step(_ line: String) { DispatchQueue.main.async { self.currentStep = line } }
}

/// Turns the data controller's delegate callbacks into something to wait on.
private final class CalibrationBatchLoader: NSObject, STEMDataControllerDelegate {
    private let semaphore = DispatchSemaphore(value: 0)
    private(set) var failure: Error?

    func didFinishLoadingData() -> (pattern: NSImage?, virtual: NSImage?) {
        semaphore.signal(); return (nil, nil)
    }
    func didFailLoadingData(_ error: Error) { failure = error; semaphore.signal() }
    func wait(seconds: TimeInterval) -> Bool {
        return semaphore.wait(timeout: .now() + seconds) == .success
    }
}
