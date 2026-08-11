//
//  CalibrationPlugin.swift
//  4DSTEM Explorer — Calibration
//
//  The plugin face of the calibration measurement.
//
//  This is an example, not the shipping path: calibration is core functionality
//  and the application does it in its own window, from the same engine. What is
//  left here is only the adapter — parameters in, results out — which is exactly
//  what makes it worth keeping as an example. It shows how a real measurement is
//  exposed through the plugin API without any of the measurement living here.
//
//  Everything that decides a number is in CalibrationMeasurement.swift, compiled
//  into both this bundle and the application, so there is one copy and it cannot
//  drift.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Accelerate

@objc(CalibrationPlugin)
public final class CalibrationPlugin: NSObject, FDSPlugin {

    public override init() { super.init() }

    private let engine = CalibrationEngine()

    public var pluginIdentifier: String { return "group.lebeau.4dstem.plugin.calibration" }
    public var pluginName: String { return "Calibration" }
    public var pluginAPIVersion: Int { return FDSPluginAPIVersion }
    public var pluginRequiresData: Bool { return true }
    public var pluginSupportsLiveUpdate: Bool { return true }

    public var pluginSummary: String {
        return "Calibrates the real-space or diffraction pixel size, and the affine "
             + "transform of the scan, against a lattice of known spacings and angle."
    }

    private static let realSpaceSource = "Computed image (real space)"
    private static let diffractionSource = "Diffraction pattern"

    // MARK: - Parameters

    public var pluginParameters: [[String: Any]] {
        return [
            FDSParameter.choice("source", label: "Measure from",
                                choices: [CalibrationPlugin.realSpaceSource,
                                          CalibrationPlugin.diffractionSource],
                                help: "The computed image gives the scan calibration; the diffraction pattern gives the detector calibration. Compute an image first if you want the former."),
            FDSParameter.choice("output", label: "Return",
                                choices: ["Detected lattice", "Calibration report", "Corrected image"],
                                help: "The report has the numbers. Detected lattice shows what was found, so you can confirm it locked onto the right peaks. Corrected image applies the fitted distortion, for the computed image only."),

            // No minimum or maximum, so these draw as text fields rather than
            // sliders: a lattice parameter is a number you know and type, not
            // one you hunt for by dragging. They are validated in the engine.
            FDSParameter.number("d1", label: "Known spacing 1 (Å)", defaultValue: 3.905,
                                help: "The lattice spacing along the first direction. The default is the SrTiO₃ cubic cell."),
            FDSParameter.number("d2", label: "Known spacing 2 (Å)", defaultValue: 3.905,
                                help: "The spacing along the second direction. Equal to the first for a cubic cell viewed down an axis."),
            FDSParameter.number("latticeAngle", label: "Angle between them (°)", defaultValue: 90,
                                help: "90° for a square or rectangular net, 120° for a hexagonal one."),

            FDSParameter.choice("window", label: "Window",
                                choices: CalibrationEngine.windowNames,
                                help: "Tapering the image edges suppresses the bright cross through the origin, at the cost of broadening every peak — Hann roughly doubles the width against no window, though it locates them most precisely of the three. Turn it off for the sharpest peaks; expect streaks along the axes, which matters most when the lattice is aligned with the raster and its peaks sit on those very axes. Real-space source only."),
            FDSParameter.integer("padFactor", label: "Transform padding", defaultValue: 2,
                                 minimum: 1, maximum: 8,
                                 help: "Interpolates the power spectrum so peaks can be located more precisely. Costs time as the square, and adds no information. Real-space source only."),
            FDSParameter.number("excludeRadius", label: "Ignore within (px)", defaultValue: 6,
                                minimum: 0, maximum: 500,
                                help: "Keeps the search away from the origin — the bright centre of the power spectrum, or the undiffracted beam in a pattern — which is not a lattice vector."),
            FDSParameter.integer("peakCount", label: "Peaks to consider", defaultValue: 60,
                                 minimum: 2, maximum: 500,
                                 help: "How many peaks to search among, shortest first. Only the shortest few can be primitive, but the rest are used to refine the fit — every peak on the lattice constrains it, and the far ones constrain it best."),
            FDSParameter.number("peakThreshold", label: "Peak threshold (fraction of strongest)",
                                defaultValue: 0.02, minimum: 0.0, maximum: 1.0,
                                help: "Peaks fainter than this fraction of the strongest are treated as noise. Raise it on a noisy image, lower it to reach weak reflections."),
            FDSParameter.number("minimumAngle", label: "Minimum vector angle (°)", defaultValue: 20,
                                minimum: 1, maximum: 89,
                                help: "Rejects a second vector too nearly parallel to the first to define a lattice. Lower it for a very oblique cell.")
        ]
    }

    public func parameters(for host: FDSHostContext) -> [[String: Any]] {
        var tailored = pluginParameters
        // Offer the diffraction pattern first when there is no computed image to
        // measure, rather than defaulting to a source that cannot work.
        if host.currentScanImageData == nil {
            for index in tailored.indices
            where tailored[index][FDSParameterKey.identifier] as? String == "source" {
                tailored[index] = FDSParameter.choice(
                    "source", label: "Measure from",
                    choices: [CalibrationPlugin.diffractionSource, CalibrationPlugin.realSpaceSource],
                    defaultValue: CalibrationPlugin.diffractionSource,
                    help: "No computed image is available yet — compute one to calibrate the scan.")
            }
        }
        return tailored
    }

    // MARK: - Run

    public func run(host: FDSHostContext, parameters: [String: Any]) -> [String: Any]? {

        let source = parameters["source"] as? String ?? CalibrationPlugin.realSpaceSource
        let output = parameters["output"] as? String ?? "Detected lattice"
        let isDiffraction = source == CalibrationPlugin.diffractionSource

        var settings = CalibrationSettings()
        settings.isDiffraction = isDiffraction
        settings.d1 = (parameters["d1"] as? NSNumber)?.doubleValue ?? 3.905
        settings.d2 = (parameters["d2"] as? NSNumber)?.doubleValue ?? 3.905
        settings.latticeAngleDegrees = (parameters["latticeAngle"] as? NSNumber)?.doubleValue ?? 90
        settings.padFactor = max(1, (parameters["padFactor"] as? NSNumber)?.intValue ?? 2)
        settings.excludeRadius = (parameters["excludeRadius"] as? NSNumber)?.doubleValue ?? 6
        settings.peakCount = max(2, (parameters["peakCount"] as? NSNumber)?.intValue ?? 24)
        settings.minimumAngle = (parameters["minimumAngle"] as? NSNumber)?.doubleValue ?? 20
        settings.peakThreshold = (parameters["peakThreshold"] as? NSNumber)?.doubleValue ?? 0.02
        settings.windowName = parameters["window"] as? String ?? "Hann"

        // The image to measure.
        let image: [Float]
        let rows: Int, columns: Int
        if isDiffraction {
            guard let data = host.currentPatternData else {
                return FDSResult.failure(CalibrationError.noImage(isDiffraction: true).localizedDescription)
            }
            image = FDSFloatArray(data)
            rows = host.patternHeight
            columns = host.patternWidth
        } else {
            guard let data = host.currentScanImageData else {
                return FDSResult.failure(CalibrationError.noImage(isDiffraction: false).localizedDescription)
            }
            image = FDSFloatArray(data)
            rows = host.scanHeight
            columns = host.scanWidth
        }
        if host.isCancelled { return nil }

        let result: CalibrationResult
        do {
            result = try engine.measure(image: image, rows: rows, columns: columns,
                                        identity: host.fileName, settings: settings)
        } catch {
            return FDSResult.failure((error as? LocalizedError)?.errorDescription
                                     ?? error.localizedDescription)
        }
        host.reportProgress(0.85)
        if host.isCancelled { return nil }

        switch output {
        case "Corrected image":
            do {
                let corrected = try engine.correctedImage(result, image: image,
                                                          rows: rows, columns: columns)
                return offer(FDSResult.scanImage(corrected, rows: rows, columns: columns,
                                                 title: "Distortion-corrected — \(host.fileName)",
                                                 message: CalibrationEngine.correctionMessage(result),
                                                 valueLabel: "counts"),
                             result: result, host: host)
            } catch {
                return FDSResult.failure((error as? LocalizedError)?.errorDescription
                                         ?? error.localizedDescription)
            }

        case "Calibration report":
            let text = engine.report(result, fileName: host.fileName,
                                     kilovolts: host.accelerationKilovolts)
            return offer(FDSResult.text(text, title: "Calibration — \(host.fileName)"),
                         result: result, host: host)

        default:
            let overlay = engine.overlay(result, excludeRadius: settings.excludeRadius)
            let base = FDSResult.pattern(overlay.values, rows: overlay.rows, columns: overlay.columns,
                                         title: isDiffraction
                                            ? "Detected reflections — \(host.fileName)"
                                            : "Detected lattice — \(host.fileName)",
                                         message: overlay.message,
                                         // The power spectrum is shown log
                                         // scaled, so the number under the
                                         // pointer is a log, and saying so
                                         // stops it being read as counts.
                                         valueLabel: isDiffraction ? "counts" : "log power")
            return offer(FDSResult.withOverlay(base, overlay.shapes),
                         result: result, host: host)
        }
    }

    /// Attaches the measured calibration so the host can offer to apply it.
    private func offer(_ dictionary: [String: Any], result: CalibrationResult,
                       host: FDSHostContext) -> [String: Any] {
        guard let offered = engine.offer(result, kilovolts: host.accelerationKilovolts) else {
            return dictionary
        }
        return FDSResult.withCalibration(
            dictionary,
            scanStepNanometers: offered.scanStepNanometres,
            diffractionStepMilliradians: offered.diffractionStepMilliradians,
            scanCorrectionRowMajor: offered.scanCorrectionRowMajor,
            summary: offered.summary)
    }
}
