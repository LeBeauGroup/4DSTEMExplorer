//
//  TiltFromCoMPlugin.swift
//  4DSTEM Explorer — Sample Tilt
//
//  Maps local specimen tilt from the centre of mass of an annular dark-field
//  region of each diffraction pattern.
//
//  A port of the TiltSolver `adf_com` method. The measurement is in
//  TiltCoMMeasurement.swift, where it is checked against patterns with a known
//  lean planted in them; this file only turns parameters into settings and
//  results into something to look at.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

@objc(TiltFromCoMPlugin)
public final class TiltFromCoMPlugin: NSObject, FDSPlugin {

    public override init() { super.init() }

    private let engine = TiltCoMEngine()

    public var pluginIdentifier: String { return "group.lebeau.4dstem.plugin.tiltfromcom" }
    public var pluginName: String { return "Sample Tilt" }
    public var pluginAPIVersion: Int { return FDSPluginAPIVersion }
    public var pluginRequiresData: Bool { return true }
    public var pluginSupportsLiveUpdate: Bool { return true }

    public var pluginSummary: String {
        return "Maps local specimen tilt from the centre of mass of an annular "
             + "dark-field region of each diffraction pattern."
    }

    // MARK: - Parameters

    public var pluginParameters: [[String: Any]] {
        return [
            FDSParameter.choice("output", label: "Return",
                                choices: ["Tilt x", "Tilt y", "Tilt magnitude",
                                          "Annulus on the mean pattern", "Report"],
                                help: "The two components are along the detector axes. Magnitude is how far off the zone axis the specimen is, without a direction. Check the annulus first: it must sit outside the bright-field disc and inside the detector."),

            FDSParameter.number("innerAngle", label: "Annulus inner (mrad)", defaultValue: 0,
                                help: "Just outside the bright-field disc, so the unscattered beam contributes nothing — around 1.1 times the convergence semi-angle. Left at 0 this is taken from the convergence angle below."),
            FDSParameter.number("outerAngle", label: "Annulus outer (mrad)", defaultValue: 0,
                                help: "Bounded by the detector. Around 2.5 times the convergence semi-angle where the detector reaches that far. Left at 0 this is taken from the convergence angle below, or from the detector edge, whichever is smaller."),
            FDSParameter.number("convergenceAngle", label: "Convergence semi-angle (mrad)",
                                defaultValue: 25,
                                help: "Used only to place the annulus when the two angles above are left at zero. Measure it on the Diffraction Step tab of the calibration window if you do not know it."),

            FDSParameter.integer("rebin", label: "Scan binning", defaultValue: 8,
                                 minimum: 1, maximum: 64,
                                 help: "Probe positions per side of one measurement. Tilt is read from where a whole pattern's intensity leans, which needs counts; this trades the scan sampling the measurement does not need for the signal it does. Positions left over at the far edge are dropped rather than forming a smaller bin."),
            FDSParameter.number("outlierThreshold", label: "Reject beyond (mrad)", defaultValue: 6,
                                minimum: 0, maximum: 200,
                                help: "A value larger than this is treated as a failure and set to zero rather than clipped — vacuum, an amorphous region or a grain boundary gives a centre of mass that is not a tilt at all, and clipping would leave a large wrong number looking like a real steep tilt. Set to 0 to keep everything."),
            FDSParameter.number("smoothing", label: "Smoothing (binned pixels)", defaultValue: 0,
                                minimum: 0, maximum: 10,
                                help: "Gaussian blur over the binned map before it is resampled."),
            FDSParameter.number("offsetX", label: "Zero-tilt offset x (mrad)", defaultValue: 0,
                                help: "The measurement is relative to where the unscattered beam sits, which is the specimen's mean orientation and not necessarily zero tilt. Shift the origin here when the mean orientation is known."),
            FDSParameter.number("offsetY", label: "Zero-tilt offset y (mrad)", defaultValue: 0,
                                help: "As above, along the other detector axis."),
            FDSParameter.choice("grid", label: "Return on",
                                choices: ["Scan grid", "Binned grid"],
                                help: "The scan grid resamples the binned map back up so it overlays the data. The binned grid shows what was actually measured, one pixel per bin.")
        ]
    }

    // MARK: - Run

    public func run(host: FDSHostContext, parameters: [String: Any]) -> [String: Any]? {

        let output = parameters["output"] as? String ?? "Tilt magnitude"
        let convergence = (parameters["convergenceAngle"] as? NSNumber)?.doubleValue ?? 25
        let step = host.diffractionStepMilliradians

        guard step > 0 else {
            return FDSResult.failure(TiltCoMError.noDiffractionCalibration.localizedDescription)
        }

        // The detector's own reach, which bounds the annulus.
        let halfWidth = Double(min(host.patternWidth, host.patternHeight)) / 2
        let detectorEdge = halfWidth * step

        var settings = TiltCoMSettings()
        let inner = (parameters["innerAngle"] as? NSNumber)?.doubleValue ?? 0
        let outer = (parameters["outerAngle"] as? NSNumber)?.doubleValue ?? 0
        settings.innerMilliradians = inner > 0 ? inner : convergence * 1.1
        settings.outerMilliradians = outer > 0 ? outer
            : min(convergence * 2.5, detectorEdge)
        settings.rebin = max(1, (parameters["rebin"] as? NSNumber)?.intValue ?? 8)
        settings.outlierThresholdMilliradians = (parameters["outlierThreshold"] as? NSNumber)?.doubleValue ?? 6
        settings.smoothingSigma = (parameters["smoothing"] as? NSNumber)?.doubleValue ?? 0
        settings.offsetXMilliradians = (parameters["offsetX"] as? NSNumber)?.doubleValue ?? 0
        settings.offsetYMilliradians = (parameters["offsetY"] as? NSNumber)?.doubleValue ?? 0
        settings.upsampleToScanGrid = (parameters["grid"] as? String ?? "Scan grid") == "Scan grid"

        let geometry = TiltCoMGeometry(scanWidth: host.scanWidth, scanHeight: host.scanHeight,
                                       patternWidth: host.patternWidth,
                                       patternHeight: host.patternHeight,
                                       diffractionStepMilliradians: step)

        let result: TiltCoMResult
        do {
            result = try engine.measure(
                geometry: geometry, settings: settings, identity: host.filePath,
                provider: { row, column, buffer, capacity in
                    host.copyPattern(row: row, column: column, into: buffer, capacity: capacity)
                },
                progress: { host.reportProgress($0) },
                isCancelled: { host.isCancelled })
        } catch is CancellationError {
            return nil
        } catch {
            return FDSResult.failure((error as? LocalizedError)?.errorDescription
                                     ?? error.localizedDescription)
        }
        host.reportProgress(1)

        switch output {
        case "Annulus on the mean pattern":
            return attach(annulusResult(result, host: host, settings: settings),
                          result: result, settings: settings, host: host, convergence: convergence)
        case "Report":
            return FDSResult.text(report(result, host: host, settings: settings,
                                         convergence: convergence, detectorEdge: detectorEdge),
                                  title: "Sample tilt — \(host.fileName)")
        case "Tilt x":
            return attach(map(result, component: .x, host: host, settings: settings),
                          result: result, settings: settings, host: host, convergence: convergence)
        case "Tilt y":
            return attach(map(result, component: .y, host: host, settings: settings),
                          result: result, settings: settings, host: host, convergence: convergence)
        default:
            return attach(map(result, component: .magnitude, host: host, settings: settings),
                          result: result, settings: settings, host: host, convergence: convergence)
        }
    }

    /// Everything measured, and how it was measured, attached to whichever map
    /// is on screen.
    ///
    /// Both grids go in. The binned one is what was actually measured — one
    /// value per bin, no interpolation — and the resampled one is what overlays
    /// the data. Exporting only the resampled arrays would ship interpolated
    /// values with nothing to check them against; exporting only the binned ones
    /// would leave the caller to redo the resampling and get a different answer.
    private func attach(_ dictionary: [String: Any], result: TiltCoMResult,
                        settings: TiltCoMSettings, host: FDSHostContext,
                        convergence: Double) -> [String: Any] {

        var datasets = [
            FDSDataset.float("binned/tilt_x", result.tiltX,
                             rows: result.rows, columns: result.columns, units: "mrad",
                             note: "Tilt along the detector x axis, one value per bin of \(settings.rebin)x\(settings.rebin) probe positions."),
            FDSDataset.float("binned/tilt_y", result.tiltY,
                             rows: result.rows, columns: result.columns, units: "mrad",
                             note: "Tilt along the detector y axis, one value per bin."),
            FDSDataset.float("mean_pattern", result.meanPattern,
                             rows: result.patternRows, columns: result.patternColumns,
                             units: "counts",
                             note: "Mean diffraction pattern over the scan, which located the beam."),
            FDSDataset.float("annulus", result.mask,
                             rows: result.patternRows, columns: result.patternColumns,
                             units: "weight",
                             note: "The annular mask the centre of mass was taken over, 0 to 1.")
        ]

        // Only when it is a different grid; otherwise it is the same numbers
        // twice under two names.
        if result.scanRows != result.rows || result.scanColumns != result.columns {
            datasets.insert(FDSDataset.float("scan/tilt_x", result.scanTiltX,
                                             rows: result.scanRows, columns: result.scanColumns,
                                             units: "mrad",
                                             note: "Tilt along x, resampled bilinearly onto the full scan grid."),
                            at: 2)
            datasets.insert(FDSDataset.float("scan/tilt_y", result.scanTiltY,
                                             rows: result.scanRows, columns: result.scanColumns,
                                             units: "mrad",
                                             note: "Tilt along y, resampled bilinearly onto the full scan grid."),
                            at: 3)
        }

        let provenance: [String: Any] = [
            "method": "Dark-field centre of mass (TiltSolver adf_com)",
            "plugin": pluginName,
            "source_file": host.fileName,
            "scan_shape": [host.scanWidth, host.scanHeight],
            "pattern_shape": [host.patternWidth, host.patternHeight],
            "binned_shape": [result.columns, result.rows],
            "rebin": settings.rebin,
            "probe_positions_per_bin": result.positionsPerBin,
            "annulus_inner_mrad": settings.innerMilliradians,
            "annulus_outer_mrad": settings.outerMilliradians,
            "convergence_semi_angle_mrad": convergence,
            "diffraction_step_mrad_per_px": host.diffractionStepMilliradians,
            "scan_step_nm": host.scanStepNanometers,
            "accelerating_voltage_kv": host.accelerationKilovolts,
            "beam_centre_px": [result.centre.x, result.centre.y],
            "zero_tilt_offset_mrad": [settings.offsetXMilliradians, settings.offsetYMilliradians],
            "outlier_threshold_mrad": settings.outlierThresholdMilliradians,
            "smoothing_sigma_binned_px": settings.smoothingSigma,
            "rejected_fraction": result.rejectedFraction,
            "max_tilt_mrad": result.maximumMilliradians,
            "resampling": "bilinear",
            "caveat": "Not an absolute tilt. How far the dark-field centre of mass leans for a given tilt depends on thickness, convergence angle, voltage and the annulus used. Read as relative tilt across the scan unless the scale has been checked against a known specimen."
        ]

        return FDSResult.withDatasets(dictionary, datasets,
                                      provenance: provenance,
                                      exportExtension: "tilts")
    }

    private enum Component { case x, y, magnitude }

    private func map(_ result: TiltCoMResult, component: Component,
                     host: FDSHostContext, settings: TiltCoMSettings) -> [String: Any] {

        let onScanGrid = settings.upsampleToScanGrid
        let rows = onScanGrid ? result.scanRows : result.rows
        let columns = onScanGrid ? result.scanColumns : result.columns
        let x = onScanGrid ? result.scanTiltX : result.tiltX
        let y = onScanGrid ? result.scanTiltY : result.tiltY

        let values: [Float]
        let name: String
        switch component {
        case .x:         values = x; name = "Tilt x"
        case .y:         values = y; name = "Tilt y"
        case .magnitude: values = zip(x, y).map { ($0 * $0 + $1 * $1).squareRoot() }
                         name = "Tilt magnitude"
        }

        var dictionary = FDSResult.scanImage(values, rows: rows, columns: columns,
                                             title: "\(name) — \(host.fileName)",
                                             valueLabel: "mrad")
        dictionary[FDSResultKey.text] = String(
            format: "%@ in mrad, from the dark-field centre of mass over %.4g–%.4g mrad. %d×%d probe positions per measurement; %.0f%% rejected; largest surviving %.3f mrad.%@",
            name as NSString, settings.innerMilliradians, settings.outerMilliradians,
            settings.rebin, settings.rebin, result.rejectedFraction * 100,
            result.maximumMilliradians,
            result.rejectedFraction > 0.25
                ? " That much rejection usually means the threshold is too low or the annulus is wrong."
                : "")
        return dictionary
    }

    /// The mean pattern with the annulus drawn on it — the first thing to look
    /// at, because every number depends on the annulus being in the right place.
    private func annulusResult(_ result: TiltCoMResult, host: FDSHostContext,
                               settings: TiltCoMSettings) -> [String: Any] {

        let rows = result.patternRows, columns = result.patternColumns
        var display = [Float](repeating: 0, count: rows * columns)
        var maximum: Float = 0
        for i in 0..<(rows * columns) {
            display[i] = log(max(result.meanPattern[i], 0) + 1)
            if display[i] > maximum { maximum = display[i] }
        }
        var minimum = Float.greatestFiniteMagnitude
        for value in display where value < minimum { minimum = value }
        let span = max(maximum - minimum, .leastNormalMagnitude)

        var rgba = [UInt8](repeating: 255, count: rows * columns * 4)
        for i in 0..<(rows * columns) {
            let level = UInt8(max(0, min(255, (display[i] - minimum) / span * 255)))
            // The annulus tints red, so what is being summed is visible against
            // the pattern rather than described in a caption.
            let weight = min(1, max(0, result.mask[i]))
            rgba[i * 4] = UInt8(min(255, Float(level) + 160 * weight))
            rgba[i * 4 + 1] = UInt8(Float(level) * (1 - 0.55 * weight))
            rgba[i * 4 + 2] = UInt8(Float(level) * (1 - 0.55 * weight))
        }

        var dictionary = FDSResult.pattern(display, rows: rows, columns: columns,
                                           title: "Tilt annulus — \(host.fileName)",
                                           valueLabel: "counts (log)")
        dictionary = FDSResult.withColor(dictionary, rgba: rgba)
        dictionary[FDSResultKey.text] = String(
            format: "Mean pattern, log scaled, with the %.4g–%.4g mrad annulus in red. Beam at (%.1f, %.1f) px. The annulus must clear the bright-field disc completely — any of the unscattered beam inside it swamps the measurement.",
            settings.innerMilliradians, settings.outerMilliradians,
            result.centre.x, result.centre.y)
        return dictionary
    }

    private func report(_ result: TiltCoMResult, host: FDSHostContext,
                        settings: TiltCoMSettings, convergence: Double,
                        detectorEdge: Double) -> String {

        var report = "Sample tilt — \(host.fileName)\n\n"
        report += String(format: "  annulus           %.4g – %.4g mrad  (%.1f – %.1f detector px)\n",
                         settings.innerMilliradians, settings.outerMilliradians,
                         settings.innerMilliradians / host.diffractionStepMilliradians,
                         settings.outerMilliradians / host.diffractionStepMilliradians)
        report += String(format: "  detector reaches  %.4g mrad\n", detectorEdge)
        report += String(format: "  beam at           (%.2f, %.2f) detector px\n",
                         result.centre.x, result.centre.y)
        report += String(format: "  measured on       %d × %d bins of %d × %d positions\n",
                         result.columns, result.rows, settings.rebin, settings.rebin)
        report += String(format: "  rejected          %.1f%% of bins\n", result.rejectedFraction * 100)
        report += String(format: "  largest tilt      %.3f mrad\n\n", result.maximumMilliradians)

        if settings.innerMilliradians < convergence {
            report += "⚠︎ The annulus starts inside the convergence angle, so it contains\n"
            report += "  part of the bright-field disc. The unscattered beam is orders of\n"
            report += "  magnitude brighter than anything scattered, so its centre of mass\n"
            report += "  will dominate and the map will show the beam, not the tilt.\n\n"
        }
        if result.rejectedFraction > 0.25 {
            report += "⚠︎ More than a quarter of the bins were rejected. Either the\n"
            report += "  threshold is too low for this specimen, or the annulus is not\n"
            report += "  where it should be. Look at the annulus on the mean pattern.\n\n"
        }

        report += "Reading this\n"
        report += "  A crystal on a zone axis scatters symmetrically about it, so the\n"
        report += "  centre of mass of the dark-field annulus sits on the optic axis.\n"
        report += "  Tilting the crystal moves the Laue circle, the excitation errors on\n"
        report += "  opposite sides stop matching, and the intensity leans. How far it\n"
        report += "  leans is what is mapped here.\n\n"
        report += "  This is not an absolute, calibration-free tilt. How far the centre\n"
        report += "  of mass leans for a given tilt depends on specimen thickness, the\n"
        report += "  convergence angle, the voltage and which annulus is used — the\n"
        report += "  useful range was chosen in the original work by testing against\n"
        report += "  simulations. Read the map as relative tilt across the scan, and\n"
        report += "  check the absolute scale against a specimen you know before\n"
        report += "  quoting it.\n\n"
        report += "  Zero is where the unscattered beam sits, which is the specimen's\n"
        report += "  mean orientation over the scan — not necessarily zero tilt. Use the\n"
        report += "  zero-tilt offset to move the origin when the mean is known.\n"

        return report
    }
}
