//
//  TiltCorrectedBFPlugin.swift
//  4DSTEM Explorer — example plugin
//
//  Tilt-corrected bright-field (tcBF) reconstruction.
//
//  The physics
//  -----------
//  Each detector pixel inside the bright-field disc collects the part of the
//  convergent probe that arrived at one particular tilt. Forming a virtual
//  image from a single BF pixel therefore gives a full bright-field image of
//  the specimen — but laterally displaced, because a tilted ray crosses the
//  sample at an offset that grows with defocus:
//
//      displacement(t) = defocus · tan(θ) ≈ defocus · θ,   θ = t · diff_step
//
//  where t is the pixel's offset from the centre of the disc. Summing the BF
//  pixels without correcting that displacement is what an ordinary BF detector
//  does, and it blurs the result by exactly the disc-edge displacement.
//
//  Shifting each single-pixel image back by its own displacement before summing
//  removes the blur and keeps every electron: a bright-field image with the dose
//  efficiency of the full disc and the resolution of a single pixel of it.
//
//  Because the displacement is linear in t, one scalar fixes the whole
//  correction. This plugin parameterises it as the displacement at the edge of
//  the disc, in scan pixels, and finds it by maximising image sharpness — so it
//  works on uncalibrated data too. When the file carries a scan step and a
//  diffraction step, the corresponding defocus is reported in nanometres.
//
//  Reference: Yu, Zeltmann, Ophus et al., tilt-corrected BF-STEM.
//

import Foundation
import Accelerate

@objc(TiltCorrectedBFPlugin)
public final class TiltCorrectedBFPlugin: NSObject, FDSPlugin {

    public var pluginIdentifier: String { return "group.lebeau.4dstem.plugin.tiltcorrectedbf" }
    public var pluginName: String { return "Tilt-Corrected Bright Field" }
    public var pluginSummary: String {
        return "Aligns the bright-field disc pixel by pixel before summing, removing the defocus blur of an ordinary BF detector. The correction is found by maximising sharpness, so calibration is optional."
    }
    public var pluginAPIVersion: Int { return 1 }

    /// The expensive step — one pass over the 4D stack — depends only on the
    /// disc and the binning. Changing the displacement reuses it, which is what
    /// makes dragging the slider interactive.
    public var pluginSupportsLiveUpdate: Bool { return true }

    // MARK: Cache
    //
    // The host guarantees runs are serialised and never re-entrant, so this
    // needs no locking.

    private struct StackKey: Equatable {
        var fileName: String
        var scanWidth: Int, scanHeight: Int
        var patternWidth: Int, patternHeight: Int
        var centerX: Float, centerY: Float, radius: Float
        var binning: Int
    }

    private var cachedKey: StackKey?
    /// The disc and binning whose focus has already been found, so a new one
    /// gets an automatic search and an existing one keeps the user's slider.
    private var focusedKey: StackKey?
    private var cachedStack: [Float] = []
    private var cachedGrouping: Grouping?

    /// Refuse to build a virtual-image stack larger than this. Binning is the
    /// user's lever for staying under it.
    private let memoryBudgetBytes = 1_500_000_000

    /// Controls in the file's own units when it is calibrated.
    public func parameters(for host: FDSHostContext) -> [[String: Any]] {
        let units = Units(host: host)

        var tailored = pluginParameters
        for index in tailored.indices {
            guard let id = tailored[index][FDSParameterKey.identifier] as? String else { continue }
            switch id {
            case "detector":
                // A list of what is actually there beats a number the user has
                // to look up, and the entries carry the shape so the right one
                // is recognisable at a glance.
                tailored[index] = FDSParameter.choice("detector", label: "Bright-field disc from",
                                                      choices: discSources(host: host),
                                                      defaultValue: patternCOMChoice,
                                                      help: "Where the disc's centre and radius come from. \(patternCOMChoice) finds it from the mean diffraction pattern; pick a detector to use its centre and outer radius instead.")

            case "maxShift" where units.calibrated:
                tailored[index] = FDSParameter.number("maxShift", label: "Search range (± nm)",
                                                      defaultValue: 400, minimum: 5, maximum: 20000,
                                                      help: "Widest defocus to test either side of zero. Widen it if the best value lands at the end of the focus curve.")
            case "edgeShift" where units.calibrated:
                tailored[index] = FDSParameter.number("edgeShift", label: "Defocus (nm)",
                                                      defaultValue: 0, minimum: -2000, maximum: 2000,
                                                      help: "Drag to refocus. Auto Defocus leaves the value it found here, so you can explore either side of it.")
            default:
                break
            }
        }
        return tailored
    }

    public var pluginParameters: [[String: Any]] {
        return [
            FDSParameter.integer("detector", label: "Bright-field disc from", defaultValue: 0, minimum: 0, maximum: 32,
                                 help: "Detector number whose centre and outer radius mark the disc. 0 finds it from the mean pattern instead. With a dataset open this becomes a list of the detectors."),
            FDSParameter.integer("binning", label: "Detector binning", defaultValue: 2, minimum: 1, maximum: 16,
                                 help: "Group the disc into blocks this many detector pixels across. Larger is faster and needs less memory; too large reintroduces blur."),
            FDSParameter.number("maxShift", label: "Search range (scan px)", defaultValue: 10, minimum: 1, maximum: 200,
                                help: "Largest edge displacement to test, in scan pixels. Widen it if the best value lands at the end of the focus curve."),
            FDSParameter.integer("steps", label: "Search steps", defaultValue: 41, minimum: 5, maximum: 201,
                                 help: "Number of trial displacements across the search range."),
            FDSParameter.button("autoDefocus", label: "Auto Defocus",
                                help: "Search for the sharpest focus and put it in the slider below. Runs by itself the first time a disc or binning is used; press it again after changing anything that should move the focus."),
            FDSParameter.number("edgeShift", label: "Edge displacement (scan px)", defaultValue: 0, minimum: -40, maximum: 40,
                                help: "Drag to refocus. Auto Defocus leaves the value it found here, so you can explore either side of it."),
            FDSParameter.choice("correction", label: "Correct for",
                                choices: ["Defocus only", "Defocus + astigmatism", "+ coma & three-fold", "+ spherical"],
                                help: "Beyond defocus the displacement field is measured by cross-correlating each virtual image against the defocus-corrected sum, then fitted to the aberration gradients. More terms need a specimen with enough contrast to correlate well."),
            FDSParameter.choice("output", label: "Return", choices: ["Corrected image", "Focus curve", "Uncorrected sum", "Aberration fit"],
                                help: "Focus curve plots sharpness against displacement; Uncorrected sum is the plain BF image for comparison.")
        ]
    }


    // MARK: - Units
    //
    // Internally everything is `k`: scan pixels of image shift per detector
    // pixel of tilt. That is the quantity the reconstruction actually needs and
    // it does not depend on the disc radius. Everything the user sees is
    // converted at the boundary — to nanometres and milliradians when the file
    // carries a calibration, and to pixels only when it does not.

    private struct Units {
        let scanStep: Double        // nm per scan pixel, 0 when unknown
        let diffStep: Double        // mrad per detector pixel, 0 when unknown

        init(host: FDSHostContext) {
            scanStep = host.scanStepNanometers
            diffStep = host.diffractionStepMilliradians
        }

        var calibrated: Bool { return scanStep > 0 && diffStep > 0 }
        var stepRadians: Double { return diffStep / 1000.0 }

        /// Defocus in nm from the canonical k. C1 = k · scanStep / θ-per-pixel.
        func defocus(fromK k: Float) -> Double { return Double(k) * scanStep / stepRadians }
        func k(fromDefocus nm: Double) -> Float { return Float(nm * stepRadians / scanStep) }

        /// Aberration coefficient whose shift goes as tⁿ, as a length in nm.
        func length(_ coefficient: Float, order: Int) -> Double {
            return Double(coefficient) * scanStep / pow(stepRadians, Double(order))
        }

        /// Collection angle of a detector radius, in mrad.
        func angle(_ detectorPixels: Float) -> Double { return Double(detectorPixels) * diffStep }

        /// The user-facing value of k: nm of defocus when calibrated, edge
        /// displacement in scan pixels when not.
        func display(k: Float, radius: Float) -> Double {
            return calibrated ? defocus(fromK: k) : Double(k * radius)
        }
        func k(fromDisplay value: Double, radius: Float) -> Float {
            return calibrated ? k(fromDefocus: value) : Float(value) / Swift.max(radius, 1)
        }

        var displayUnit: String { return calibrated ? "nm" : "scan px" }

        /// A length in nm, shown with a sensible prefix.
        func formatLength(_ nanometres: Double) -> String {
            let magnitude = abs(nanometres)
            if magnitude >= 1_000_000 { return String(format: "%.3f mm", nanometres / 1_000_000) }
            if magnitude >= 1_000 { return String(format: "%.3f µm", nanometres / 1_000) }
            if magnitude >= 1 { return String(format: "%.1f nm", nanometres) }
            return String(format: "%.1f pm", nanometres * 1000)
        }
    }

    /// First entry of the detector list: work the disc out from the data.
    private var patternCOMChoice: String { return "Pattern COM" }

    /// The detector list, newest state of the main window included.
    private func discSources(host: FDSHostContext) -> [String] {
        var choices = [patternCOMChoice]
        for index in 0..<host.detectorCount {
            let info = host.detectorInfo(at: index)
            let name = (info?[FDSDetectorKey.name] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Detector \(index + 1)"
            let shape = (info?[FDSDetectorKey.shape] as? String)?.uppercased() ?? ""
            choices.append(shape.isEmpty ? "\(index + 1). \(name)" : "\(index + 1). \(name) (\(shape))")
        }
        return choices
    }

    /// 0 for Pattern COM, otherwise the 1-based detector number.
    ///
    /// Accepts the older integer form too, so a saved run or a host that never
    /// asked for a tailored list still works.
    private func detectorSelection(_ parameters: [String: Any]) -> Int {
        if let choice = parameters["detector"] as? String {
            guard !choice.hasPrefix(patternCOMChoice) else { return 0 }
            guard let dot = choice.firstIndex(of: "."),
                  let number = Int(choice[choice.startIndex..<dot]) else { return 0 }
            return number
        }
        return (parameters["detector"] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Run

    public func run(host: FDSHostContext, parameters: [String: Any]) -> [String: Any]? {

        let scanWidth = host.scanWidth
        let scanHeight = host.scanHeight
        let patternPixels = host.patternPixelCount
        let patternWidth = host.patternWidth
        let patternHeight = host.patternHeight

        guard scanWidth > 1, scanHeight > 1, patternPixels > 0 else {
            return FDSResult.failure("No 4D dataset is open, or the scan is only one probe position across.")
        }

        let units = Units(host: host)
        let binning = max(1, (parameters["binning"] as? NSNumber)?.intValue ?? 2)
        let autoPressed = (parameters["autoDefocus"] as? NSNumber)?.boolValue ?? false
        let manualDisplay = (parameters["edgeShift"] as? NSNumber)?.doubleValue ?? 0
        let maxDisplay = abs((parameters["maxShift"] as? NSNumber)?.doubleValue ?? 10)
        let steps = max(5, (parameters["steps"] as? NSNumber)?.intValue ?? 41)
        let output = parameters["output"] as? String ?? "Corrected image"
        let correction = parameters["correction"] as? String ?? "Defocus only"
        let terms = termCount(for: correction)

        // 1. Where is the bright-field disc?
        let discResult = locateDisc(host: host, parameters: parameters,
                                    patternWidth: patternWidth, patternHeight: patternHeight)
        guard case .found(let centerX, let centerY, let radius, let discSource) = discResult else {
            if case .failed(let reason) = discResult { return FDSResult.failure(reason) }
            return FDSResult.failure("Could not locate the bright-field disc.")
        }
        host.log(String(format: "Bright-field disc: centre %.1f, %.1f, radius %.1f detector px (%@)",
                        centerX, centerY, radius, discSource))

        // 2. Group the disc pixels into binned virtual detectors.
        let key = StackKey(fileName: host.fileName,
                           scanWidth: scanWidth, scanHeight: scanHeight,
                           patternWidth: patternWidth, patternHeight: patternHeight,
                           centerX: centerX, centerY: centerY, radius: radius,
                           binning: binning)

        let grouping: Grouping
        let scanPixels = scanWidth * scanHeight
        var stack: [Float]
        var rebuilt = false

        if key == cachedKey, let cached = cachedGrouping, cachedStack.count == cached.groupCount * scanPixels {
            // Same disc and binning as last time — reuse the pass over the 4D
            // data. This is what makes dragging the displacement interactive.
            grouping = cached
            stack = cachedStack
        } else {
            grouping = buildGroups(centerX: centerX, centerY: centerY, radius: radius,
                                   binning: binning, patternWidth: patternWidth, patternHeight: patternHeight)
            guard grouping.groupCount > 0, grouping.discPixelCount > 0 else {
                return FDSResult.failure("The bright-field disc covers no detector pixels. Check the detector's outer radius, or choose \(patternCOMChoice) to find the disc from the data.")
            }

            let stackBytes = grouping.groupCount * scanPixels * MemoryLayout<Float>.size
            guard stackBytes <= memoryBudgetBytes else {
                let suggested = binning * Int((Double(stackBytes) / Double(memoryBudgetBytes)).squareRoot().rounded(.up))
                return FDSResult.failure(String(format: "This would need %.1f GB for %d virtual images. Raise the detector binning to about %d and try again.",
                                                Double(stackBytes) / 1e9, grouping.groupCount, max(binning + 1, suggested)))
            }
            host.log("\(grouping.discPixelCount) disc pixels grouped into \(grouping.groupCount) virtual detectors (\(stackBytes / 1_048_576) MB).")

            // 3. One pass over the 4D data to build every virtual image at once.
            //    Everything after this works on the stack, not the raw dataset.
            guard let built = buildVirtualImageStack(host: host, grouping: grouping,
                                                     patternPixels: patternPixels,
                                                     scanWidth: scanWidth, scanHeight: scanHeight) else {
                return nil   // cancelled — leave the cache alone, it is still valid
            }
            stack = built
            rebuilt = true

            // Only commit a cache built from a complete pass.
            cachedKey = key
            cachedGrouping = grouping
            cachedStack = built
        }

        // 4. Find the displacement, unless the user pinned it. `edgeShift` is
        //    kept in scan-pixels-at-the-disc-edge internally; the user's number
        //    is nanometres of defocus whenever the file is calibrated.
        let maxShift = abs(units.k(fromDisplay: maxDisplay, radius: radius)) * radius
        var edgeShift = units.k(fromDisplay: manualDisplay, radius: radius) * radius
        var curveShifts: [Float] = []
        var curveSharpness: [Float] = []

        // Search when asked, when this disc and binning have never been focused
        // — otherwise the first view would sit at zero defocus, which is just
        // the uncorrected sum — or when the focus curve is what was asked for.
        let neverFocused = focusedKey != key
        let searching = autoPressed || neverFocused || output == "Focus curve"

        if searching {
            guard let search = searchEdgeShift(host: host, stack: &stack, grouping: grouping,
                                               scanWidth: scanWidth, scanHeight: scanHeight,
                                               maxShift: maxShift, steps: steps, radius: radius) else {
                return nil   // cancelled
            }
            curveShifts = search.shifts
            curveSharpness = search.sharpness
            edgeShift = search.best
            focusedKey = key
        }
        let foundK = radius > 0 ? edgeShift / radius : 0

        if host.isCancelled { return nil }

        // 5. Report the equivalent defocus when the file is calibrated.
        //    displacement[nm] = defocus[nm] · θ[rad]  with θ = t · diff_step/1000
        // One statement of where the focus is, in whichever unit the file
        // supports — never both, never mixed.
        let focusNote: String
        if units.calibrated {
            focusNote = String(format: "Defocus %@ (disc edge %.1f mrad)",
                               units.formatLength(units.defocus(fromK: foundK)), units.angle(radius))
        } else {
            focusNote = String(format: "Edge displacement %.2f scan px (disc radius %.0f detector px)",
                               edgeShift, radius)
        }

        // A completed search hands its answer back to the controls and switches
        // to manual, so the slider starts from what was found and the next drag
        // refocuses live instead of searching again.
        // A search leaves what it found in the slider, so the next drag starts
        // from there rather than from wherever the control happened to be.
        var writeBack: [String: Any] = [:]
        if searching && !curveSharpness.isEmpty {
            writeBack["edgeShift"] = NSNumber(value: units.display(k: foundK, radius: radius))
        }

        if output == "Focus curve" {
            guard !curveSharpness.isEmpty else {
                return FDSResult.failure("The focus curve is empty — try more search steps.")
            }
            // Plot in the same unit as the control, so the curve and the
            // slider can be read against each other.
            let curveDisplay = curveShifts.map {
                Float(units.display(k: radius > 0 ? $0 / radius : 0, radius: radius))
            }
            var result = FDSResult.plot(
                x: curveDisplay, y: curveSharpness,
                title: "tcBF Focus Curve — \(host.fileName)",
                xLabel: units.calibrated ? "Defocus (nm)" : "Disc-edge displacement (scan pixels)",
                yLabel: "Normalised gradient energy",
                message: String(format: "Sharpest at %@. %d virtual detectors, binning %d.",
                                focusNote, grouping.groupCount, binning)
            )
            if !writeBack.isEmpty { result[FDSResultKey.parameters] = writeBack }
            return result
        }

        // 6. Beyond defocus: measure where each virtual image actually sits and
        //    fit the aberration gradients to that field. Bootstrapped from the
        //    defocus result above, so the residuals being searched are small.
        var fit: Aberrations?
        var fitNote = ""
        if terms > 1 && output != "Uncorrected sum" {
            let scanPixels = scanWidth * scanHeight
            var accumulator = [Float](repeating: 0, count: scanPixels)
            var coverage = [Float](repeating: 0, count: scanPixels)
            var safeCoverage = [Float](repeating: 0, count: scanPixels)
            var reference = [Float](repeating: 0, count: scanPixels)

            var (currentX, currentY) = linearShifts(grouping: grouping, edgeShift: edgeShift, radius: radius)

            // Two passes. The defocus bootstrap can be a long way off precisely
            // when there is astigmatism to find: with two line foci the
            // sharpness search settles on one of them rather than the mean, so
            // the first pass starts from a reference that is itself astigmatic.
            // Re-forming the reference from the first fit and measuring again
            // converges on the real field.
            for pass in 0..<2 {
                if host.isCancelled { return nil }

                accumulate(stack: &stack, grouping: grouping, scanWidth: scanWidth, scanHeight: scanHeight,
                           shiftX: currentX, shiftY: currentY, bilinear: false,
                           accumulator: &accumulator, coverage: &coverage)
                normalise(accumulator: accumulator, coverage: coverage,
                          safeCoverage: &safeCoverage, into: &reference)

                // The residual left by a wrong starting focus scales with the
                // displacement across the disc, so the window has to as well —
                // a fixed few pixels silently clips exactly the cases that need
                // correcting most. The second pass starts close, so it narrows.
                let searchRadius = pass == 0
                    ? Swift.max(4, Swift.min(16, Int((abs(edgeShift) * 0.75).rounded(.up))))
                    : 3

                guard let measured = measureShifts(host: host, stack: &stack, grouping: grouping,
                                                   scanWidth: scanWidth, scanHeight: scanHeight,
                                                   baseShiftX: currentX, baseShiftY: currentY,
                                                   reference: reference, searchRadius: searchRadius) else {
                    return nil   // cancelled
                }
                guard let solved = fitAberrations(grouping: grouping, measured: measured, terms: terms) else {
                    break
                }
                fit = solved
                let refined = modelShifts(grouping: grouping, aberrations: solved)
                currentX = refined.0
                currentY = refined.1
            }

            if let solved = fit {
                fitNote = " " + describeAberrations(solved, radius: radius, units: units) + "."
                if solved.rmsResidual > 0.9 * solved.rmsMeasured {
                    let residual = units.calibrated
                        ? units.formatLength(Double(solved.rmsResidual) * units.scanStep) + " of " + units.formatLength(Double(solved.rmsMeasured) * units.scanStep)
                        : String(format: "%.2f of %.2f scan px", solved.rmsResidual, solved.rmsMeasured)
                    fitNote += " The fit explains little of the measured field (residual \(residual) of image shift) — treat it with suspicion."
                }
            } else {
                fitNote = " Aberration fit failed; fell back to defocus alone."
            }
        }

        if output == "Aberration fit" {
            guard let solved = fit else {
                return FDSResult.failure(terms > 1
                    ? "The aberration fit did not converge. Check that the specimen has enough contrast to correlate, or use fewer terms."
                    : "Choose a correction beyond \"Defocus only\" to fit aberrations.")
            }
            var report = "Tilt-corrected bright field — aberration fit\n\n"
            report += "File            \(host.fileName)\n"
            if units.calibrated {
                report += String(format: "Disc            %.1f mrad radius (%.0f detector px)\n",
                                 units.angle(radius), radius)
                report += String(format: "Calibration     %.4g nm/scan px, %.4g mrad/detector px\n",
                                 units.scanStep, units.diffStep)
            } else {
                report += String(format: "Disc            radius %.1f detector px\n", radius)
                report += "Calibration     none in the file\n"
            }
            report += "Virtual images  \(grouping.groupCount) (binning \(binning))\n"
            report += "Correlated      \(solved.groupsUsed) of \(grouping.groupCount)\n\n"
            report += "Fitted aberrations\n  \(describeAberrations(solved, radius: radius, units: units))\n\n"
            // These are image shifts, so the scan step converts them.
            if units.calibrated {
                report += "Measured field  " + units.formatLength(Double(solved.rmsMeasured) * units.scanStep) + " rms of image shift\n"
                report += "Fit residual    " + units.formatLength(Double(solved.rmsResidual) * units.scanStep) + " rms\n"
            } else {
                report += String(format: "Measured field  %.3f scan px rms of image shift\n", solved.rmsMeasured)
                report += String(format: "Fit residual    %.3f scan px rms\n", solved.rmsResidual)
            }
            report += String(format: "Explained       %.0f%%\n\n",
                             100 * (1 - Double(solved.rmsResidual / Swift.max(solved.rmsMeasured, .leastNormalMagnitude))))

            let names = ["C1 defocus", "A1 astigmatism a", "A1 astigmatism b",
                         "cubic tx³", "cubic tx²ty", "cubic txty²", "cubic ty³", "C3 spherical"]
            let orders = [1, 1, 1, 2, 2, 2, 2, 3]
            if units.calibrated {
                report += "Coefficients\n"
                for (n, c) in solved.coefficients.enumerated() {
                    let name = names[Swift.min(n, names.count - 1)]
                    let order = orders[Swift.min(n, orders.count - 1)]
                    report += String(format: "  %-18@ %@\n", name as NSString,
                                     units.formatLength(units.length(c, order: order)) as NSString)
                }
            } else {
                report += "Coefficients (scan px per detector px^n)\n"
                for (n, c) in solved.coefficients.enumerated() {
                    report += String(format: "  %-18@ % .6g\n",
                                     names[Swift.min(n, names.count - 1)] as NSString, c)
                }
                report += "\nThe file carries no scan or diffraction step, so these are in pixels.\n"
                report += "Calibrate the dataset to read them in nanometres.\n"
            }
            var result = FDSResult.text(report, title: "tcBF Aberrations — \(host.fileName)")
            if !writeBack.isEmpty { result[FDSResultKey.parameters] = writeBack }
            return result
        }

        // 7. Final reconstruction at sub-pixel precision.
        let shifts: ([Float], [Float])
        if output == "Uncorrected sum" {
            shifts = ([Float](repeating: 0, count: grouping.groupCount),
                      [Float](repeating: 0, count: grouping.groupCount))
        } else if let solved = fit {
            shifts = modelShifts(grouping: grouping, aberrations: solved)
        } else {
            shifts = linearShifts(grouping: grouping, edgeShift: edgeShift, radius: radius)
        }
        let image = reconstruct(stack: &stack, grouping: grouping,
                                scanWidth: scanWidth, scanHeight: scanHeight,
                                shiftX: shifts.0, shiftY: shifts.1)
        host.reportProgress(1.0)

        let title = (output == "Uncorrected sum")
            ? "Bright Field (uncorrected) — \(host.fileName)"
            : "Tilt-Corrected Bright Field — \(host.fileName)"

        let message: String
        if output == "Uncorrected sum" {
            message = String(format: "Plain sum of %d disc pixels, no tilt correction. For comparison the search found %@.",
                             grouping.discPixelCount, focusNote)
        } else {
            message = String(format: "%@%@.%@ %d disc pixels in %d virtual detectors, binning %d.%@",
                             focusNote,
                             searching ? " (from Auto Defocus)" : "",
                             fitNote,
                             grouping.discPixelCount, grouping.groupCount, binning,
                             rebuilt ? " Virtual images rebuilt from the 4D data." : " Reusing the cached virtual images.")
        }

        var result = FDSResult.scanImage(image, rows: scanHeight, columns: scanWidth,
                                         title: title, message: message)
        if !writeBack.isEmpty { result[FDSResultKey.parameters] = writeBack }
        return result
    }

    // MARK: - Bright-field disc

    private enum DiscResult {
        case found(centerX: Float, centerY: Float, radius: Float, source: String)
        case failed(String)
    }

    private func locateDisc(host: FDSHostContext, parameters: [String: Any],
                            patternWidth: Int, patternHeight: Int) -> DiscResult {

        let detectorNumber = detectorSelection(parameters)

        if detectorNumber > 0 {
            let index = detectorNumber - 1
            guard index < host.detectorCount, let info = host.detectorInfo(at: index) else {
                // The list was built when the window opened; detectors can be
                // removed after that.
                return .failed("Detector \(detectorNumber) no longer exists — the dataset now has \(host.detectorCount). Reopen the plugin to refresh the list, or choose \(patternCOMChoice).")
            }
            let cx = Float(info[FDSDetectorKey.centerX] as? Double ?? 0)
            let cy = Float(info[FDSDetectorKey.centerY] as? Double ?? 0)
            let r = Float(info[FDSDetectorKey.outerRadius] as? Double ?? 0)
            guard r >= 2 else {
                return .failed("Detector \(detectorNumber) has an outer radius of \(r) pixels, too small to be the bright-field disc.")
            }
            return .found(centerX: cx, centerY: cy, radius: r, source: "detector \(detectorNumber)")
        }

        // Auto-detect: average a sample of patterns, threshold at half the
        // bright level, then take the centroid and equivalent-area radius.
        let patternPixels = patternWidth * patternHeight
        var mean = [Double](repeating: 0, count: patternPixels)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: patternPixels)
        defer { buffer.deallocate() }

        let strideY = max(1, host.scanHeight / 16)
        let strideX = max(1, host.scanWidth / 16)
        var sampled = 0
        for row in 0..<host.scanHeight where row % strideY == 0 {
            for column in 0..<host.scanWidth where column % strideX == 0 {
                guard host.copyPattern(row: row, column: column, into: buffer, capacity: patternPixels) else { continue }
                for i in 0..<patternPixels { mean[i] += Double(buffer[i]) }
                sampled += 1
            }
        }
        guard sampled > 0 else { return .failed("Could not read any diffraction patterns.") }

        // A high percentile rather than the maximum, so one hot pixel cannot
        // set the threshold.
        var sorted = mean
        sorted.sort()
        let bright = sorted[min(patternPixels - 1, Int(Double(patternPixels - 1) * 0.995))]
        let floorLevel = sorted[Int(Double(patternPixels - 1) * 0.05)]
        guard bright > floorLevel else {
            return .failed("The mean diffraction pattern has no contrast, so \(patternCOMChoice) cannot find the bright-field disc. Pick a detector from the list instead.")
        }
        let threshold = floorLevel + 0.5 * (bright - floorLevel)

        var sumX = 0.0, sumY = 0.0, count = 0
        for row in 0..<patternHeight {
            for column in 0..<patternWidth where mean[row * patternWidth + column] >= threshold {
                sumX += Double(column)
                sumY += Double(row)
                count += 1
            }
        }
        guard count >= 4 else {
            return .failed("Only \(count) detector pixels are above the bright-field threshold, too few for \(patternCOMChoice) to locate the disc. Pick a detector from the list instead.")
        }

        let radius = (Double(count) / Double.pi).squareRoot()
        return .found(centerX: Float(sumX / Double(count)),
                      centerY: Float(sumY / Double(count)),
                      radius: Float(radius),
                      source: "\(patternCOMChoice) over \(sampled) patterns")
    }

    // MARK: - Grouping

    /// A binned virtual detector: where its rays came from, and which detector
    /// pixels feed it.
    private struct Grouping {
        var groupCount: Int
        var discPixelCount: Int
        /// Mean tilt vector of each group, in detector pixels from the centre.
        var tiltX: [Float]
        var tiltY: [Float]
        /// Flat detector index of every disc pixel, ordered by group.
        var pixelIndices: [Int]
        /// Start of each group's slice of `pixelIndices`, with a trailing end.
        var groupStart: [Int]

        /// The same pixels as contiguous runs — a binned block covers whole
        /// spans of a detector row, so each run can be summed with one vDSP
        /// call instead of a scalar walk. Parallel arrays keep it flat.
        var runOffset: [Int]
        var runLength: [Int]
        /// Start of each group's slice of the run arrays, with a trailing end.
        var runStart: [Int]
        /// Longest run, so the caller can tell whether vectorising is worth it.
        var longestRun: Int
    }

    private func buildGroups(centerX: Float, centerY: Float, radius: Float, binning: Int,
                             patternWidth: Int, patternHeight: Int) -> Grouping {

        // Bin on a grid anchored at the disc centre so binning stays symmetric
        // about it — otherwise the groups' mean tilts pick up a bias.
        var members: [Int: [Int]] = [:]
        let radiusSquared = radius * radius

        for row in 0..<patternHeight {
            let dy = Float(row) - centerY
            for column in 0..<patternWidth {
                let dx = Float(column) - centerX
                guard dx * dx + dy * dy <= radiusSquared else { continue }
                let binX = Int(floor(dx / Float(binning)))
                let binY = Int(floor(dy / Float(binning)))
                let key = binY &* 100_000 &+ binX
                members[key, default: []].append(row * patternWidth + column)
            }
        }

        var tiltX: [Float] = []
        var tiltY: [Float] = []
        var pixelIndices: [Int] = []
        var groupStart: [Int] = [0]
        var runOffset: [Int] = []
        var runLength: [Int] = []
        var runStart: [Int] = [0]
        var longestRun = 0

        for key in members.keys.sorted() {
            guard let pixels = members[key], !pixels.isEmpty else { continue }
            var sumX: Float = 0, sumY: Float = 0
            for index in pixels {
                sumX += Float(index % patternWidth) - centerX
                sumY += Float(index / patternWidth) - centerY
            }
            let n = Float(pixels.count)
            tiltX.append(sumX / n)
            tiltY.append(sumY / n)

            // Collapse the group's pixels into contiguous runs. They were
            // collected in row-major order, so adjacent indices that differ by
            // one and share a row belong to the same run.
            let sorted = pixels.sorted()
            var runBegin = sorted[0]
            var runCount = 1
            for index in sorted.dropFirst() {
                let contiguous = index == runBegin + runCount
                    && index / patternWidth == runBegin / patternWidth
                if contiguous {
                    runCount += 1
                } else {
                    runOffset.append(runBegin)
                    runLength.append(runCount)
                    longestRun = Swift.max(longestRun, runCount)
                    runBegin = index
                    runCount = 1
                }
            }
            runOffset.append(runBegin)
            runLength.append(runCount)
            longestRun = Swift.max(longestRun, runCount)

            pixelIndices.append(contentsOf: sorted)
            groupStart.append(pixelIndices.count)
            runStart.append(runOffset.count)
        }

        return Grouping(groupCount: tiltX.count,
                        discPixelCount: pixelIndices.count,
                        tiltX: tiltX, tiltY: tiltY,
                        pixelIndices: pixelIndices, groupStart: groupStart,
                        runOffset: runOffset, runLength: runLength, runStart: runStart,
                        longestRun: longestRun)
    }

    // MARK: - Virtual image stack

    /// `stack[g * scanPixels + p]` is the sum of group g's detector pixels at
    /// probe position p. Nil if the user cancelled.
    private func buildVirtualImageStack(host: FDSHostContext, grouping: Grouping,
                                        patternPixels: Int,
                                        scanWidth: Int, scanHeight: Int) -> [Float]? {

        let scanPixels = scanWidth * scanHeight
        var stack = [Float](repeating: 0, count: grouping.groupCount * scanPixels)

        let pattern = UnsafeMutablePointer<Float>.allocate(capacity: patternPixels)
        defer { pattern.deallocate() }

        stack.withUnsafeMutableBufferPointer { stackBuffer in
            guard let stackBase = stackBuffer.baseAddress else { return }

            // Below this a vDSP call costs more than the adds it saves, which is
            // the case at binning 1 where every run is a single pixel.
            let vectorise = grouping.longestRun >= 4

            grouping.pixelIndices.withUnsafeBufferPointer { indices in
            grouping.groupStart.withUnsafeBufferPointer { starts in
            grouping.runOffset.withUnsafeBufferPointer { runOffsets in
            grouping.runLength.withUnsafeBufferPointer { runLengths in
            grouping.runStart.withUnsafeBufferPointer { runStarts in
                for row in 0..<scanHeight {
                    if host.isCancelled { return }

                    for column in 0..<scanWidth {
                        let probe = row * scanWidth + column
                        guard host.copyPattern(row: row, column: column,
                                               into: pattern, capacity: patternPixels) else { continue }

                        if vectorise {
                            for group in 0..<grouping.groupCount {
                                var sum: Float = 0
                                for run in runStarts[group]..<runStarts[group + 1] {
                                    var partial: Float = 0
                                    vDSP_sve(pattern + runOffsets[run], 1, &partial, vDSP_Length(runLengths[run]))
                                    sum += partial
                                }
                                stackBase[group * scanPixels + probe] = sum
                            }
                        } else {
                            for group in 0..<grouping.groupCount {
                                var sum: Float = 0
                                for slot in starts[group]..<starts[group + 1] {
                                    sum += pattern[indices[slot]]
                                }
                                stackBase[group * scanPixels + probe] = sum
                            }
                        }
                    }

                    // Building the stack is the only pass over the raw data,
                    // so it gets the bulk of the progress bar.
                    host.reportProgress(0.7 * Double(row + 1) / Double(scanHeight))
                }
            }}}}}
        }

        return host.isCancelled ? nil : stack
    }

    // MARK: - Search

    private struct SearchResult {
        var best: Float
        var shifts: [Float]
        var sharpness: [Float]
    }

    private func searchEdgeShift(host: FDSHostContext, stack: inout [Float], grouping: Grouping,
                                 scanWidth: Int, scanHeight: Int,
                                 maxShift: Float, steps: Int, radius: Float) -> SearchResult? {

        let scanPixels = scanWidth * scanHeight
        var shifts = [Float](repeating: 0, count: steps)
        var sharpness = [Float](repeating: 0, count: steps)

        var accumulator = [Float](repeating: 0, count: scanPixels)
        var coverage = [Float](repeating: 0, count: scanPixels)
        var safeCoverage = [Float](repeating: 0, count: scanPixels)
        var normalised = [Float](repeating: 0, count: scanPixels)
        var scratch = Scratch()

        let fullCoverage = 0.99 * Float(grouping.groupCount)

        for step in 0..<steps {
            if host.isCancelled { return nil }

            let edgeShift = -maxShift + 2 * maxShift * Float(step) / Float(steps - 1)
            shifts[step] = edgeShift

            // Whole-pixel sampling is enough to find the peak and is several
            // times faster; the final image is done bilinearly.
            let (sx, sy) = linearShifts(grouping: grouping, edgeShift: edgeShift, radius: radius)
            accumulate(stack: &stack, grouping: grouping, scanWidth: scanWidth, scanHeight: scanHeight,
                       shiftX: sx, shiftY: sy, bilinear: false,
                       accumulator: &accumulator, coverage: &coverage)

            normalise(accumulator: accumulator, coverage: coverage,
                      safeCoverage: &safeCoverage, into: &normalised)
            sharpness[step] = gradientEnergy(normalised, coverage: coverage,
                                             width: scanWidth, height: scanHeight,
                                             minCoverage: fullCoverage,
                                             scratch: &scratch)

            host.reportProgress(0.7 + 0.25 * Double(step + 1) / Double(steps))
        }

        // Peak, refined by a parabola through its neighbours so the answer is
        // not quantised to the search grid.
        var bestIndex = 0
        for step in 1..<steps where sharpness[step] > sharpness[bestIndex] { bestIndex = step }
        var best = shifts[bestIndex]

        if bestIndex > 0, bestIndex < steps - 1 {
            let left = sharpness[bestIndex - 1]
            let peak = sharpness[bestIndex]
            let right = sharpness[bestIndex + 1]
            let denominator = left - 2 * peak + right
            if abs(denominator) > .ulpOfOne {
                let delta = 0.5 * (left - right) / denominator
                if abs(delta) <= 1 {
                    best += delta * (shifts[1] - shifts[0])
                }
            }
        }

        if bestIndex == 0 || bestIndex == steps - 1 {
            host.log("The sharpest displacement is at the end of the search range — widen it.")
        }

        return SearchResult(best: best, shifts: shifts, sharpness: sharpness)
    }

    // MARK: - Accumulation

    /// Sums every virtual image shifted back by its own displacement.
    /// `coverage` counts how many groups reached each output pixel.
    private func accumulate(stack: inout [Float], grouping: Grouping,
                            scanWidth: Int, scanHeight: Int,
                            shiftX: [Float], shiftY: [Float], bilinear: Bool,
                            accumulator: inout [Float], coverage: inout [Float]) {

        let scanPixels = scanWidth * scanHeight

        var zero: Float = 0
        vDSP_vfill(&zero, &accumulator, 1, vDSP_Length(scanPixels))
        vDSP_vfill(&zero, &coverage, 1, vDSP_Length(scanPixels))

        stack.withUnsafeMutableBufferPointer { stackBuffer in
            accumulator.withUnsafeMutableBufferPointer { accBuffer in
                coverage.withUnsafeMutableBufferPointer { covBuffer in
                    guard let stackBase = stackBuffer.baseAddress,
                          let acc = accBuffer.baseAddress,
                          let cov = covBuffer.baseAddress else { return }

                    for group in 0..<grouping.groupCount {
                        let source = stackBase + group * scanPixels
                        let shiftX = shiftX[group]
                        let shiftY = shiftY[group]

                        if bilinear {
                            let baseX = floor(shiftX), baseY = floor(shiftY)
                            let fracX = shiftX - baseX, fracY = shiftY - baseY
                            let corners: [(Int, Int, Float)] = [
                                (Int(baseX),     Int(baseY),     (1 - fracX) * (1 - fracY)),
                                (Int(baseX) + 1, Int(baseY),     fracX * (1 - fracY)),
                                (Int(baseX),     Int(baseY) + 1, (1 - fracX) * fracY),
                                (Int(baseX) + 1, Int(baseY) + 1, fracX * fracY)
                            ]
                            for (offsetX, offsetY, weight) in corners where weight > 0 {
                                addShifted(source: source, offsetX: offsetX, offsetY: offsetY, weight: weight,
                                           width: scanWidth, height: scanHeight, accumulator: acc, coverage: cov)
                            }
                        } else {
                            addShifted(source: source,
                                       offsetX: Int(shiftX.rounded()), offsetY: Int(shiftY.rounded()), weight: 1,
                                       width: scanWidth, height: scanHeight, accumulator: acc, coverage: cov)
                        }
                    }
                }
            }
        }
    }

    /// `accumulator(x, y) += weight · source(x + offsetX, y + offsetY)` over the
    /// rows where that sample exists, as whole-row vector operations.
    private func addShifted(source: UnsafePointer<Float>, offsetX: Int, offsetY: Int, weight: Float,
                            width: Int, height: Int,
                            accumulator: UnsafeMutablePointer<Float>, coverage: UnsafeMutablePointer<Float>) {

        let firstX = max(0, -offsetX)
        let lastX = min(width, width - offsetX)
        let firstY = max(0, -offsetY)
        let lastY = min(height, height - offsetY)
        guard lastX > firstX, lastY > firstY else { return }

        let run = vDSP_Length(lastX - firstX)
        var scale = weight

        for y in firstY..<lastY {
            let destination = y * width + firstX
            let origin = (y + offsetY) * width + (firstX + offsetX)
            vDSP_vsma(source + origin, 1, &scale, accumulator + destination, 1, accumulator + destination, 1, run)
            vDSP_vsadd(coverage + destination, 1, &scale, coverage + destination, 1, run)
        }
    }

    /// Divides out coverage so the borders, where fewer tilts reach, are not dark.
    ///
    /// Runs once per trial displacement over the whole scan, so it is on the
    /// interactive path. Coverage is a count: clamping it up to 1 first means
    /// the division needs no per-pixel branch, and uncovered pixels — where the
    /// accumulator is 0 — still come out 0.
    private func normalise(accumulator: [Float], coverage: [Float],
                           safeCoverage: inout [Float], into result: inout [Float]) {
        let n = vDSP_Length(result.count)
        var one: Float = 1
        vDSP_vthr(coverage, 1, &one, &safeCoverage, 1, n)
        vDSP_vdiv(safeCoverage, 1, accumulator, 1, &result, 1, n)
    }

    // MARK: - Sharpness

    /// Mean squared gradient divided by the squared mean — scale-free, so trial
    /// displacements are compared on how sharp the image is, not how bright.
    /// Only fully covered pixels count, keeping partly filled borders out of it.
    ///
    /// Vectorised because it runs once per trial displacement over the whole
    /// scan. The coverage test becomes a 0/1 mask multiplied into the gradient
    /// energy, which is equivalent to the per-pixel branch it replaces but has
    /// no branch in the inner loop.
    private func gradientEnergy(_ image: [Float], coverage: [Float],
                                width: Int, height: Int, minCoverage: Float,
                                scratch: inout Scratch) -> Float {

        guard width > 2, height > 2 else { return 0 }
        let interiorWidth = width - 2
        let rows = height - 2
        let count = interiorWidth * rows
        guard count > 0 else { return 0 }

        scratch.ensure(count: count)

        var energySum: Float = 0
        var valueSum: Float = 0
        var maskSum: Float = 0

        image.withUnsafeBufferPointer { img in
            coverage.withUnsafeBufferPointer { cov in
                guard let image = img.baseAddress, let coverage = cov.baseAddress else { return }

                scratch.gx.withUnsafeMutableBufferPointer { gxBuf in
                scratch.gy.withUnsafeMutableBufferPointer { gyBuf in
                scratch.mask.withUnsafeMutableBufferPointer { maskBuf in
                scratch.temp.withUnsafeMutableBufferPointer { tmpBuf in
                    guard let gx = gxBuf.baseAddress, let gy = gyBuf.baseAddress,
                          let mask = maskBuf.baseAddress, let temp = tmpBuf.baseAddress else { return }

                    let n = vDSP_Length(interiorWidth)
                    var limit = minCoverage
                    var zero: Float = 0
                    var one: Float = 1

                    for row in 1..<(height - 1) {
                        let centre = row * width + 1
                        let out = (row - 1) * interiorWidth

                        // Central differences, whole rows at a time.
                        vDSP_vsub(image + centre - 1, 1, image + centre + 1, 1, gx + out, 1, n)
                        vDSP_vsub(image + centre - width, 1, image + centre + width, 1, gy + out, 1, n)

                        // Mask = 1 only where this pixel and its four neighbours
                        // are all fully covered; built as a running minimum.
                        vDSP_vmin(coverage + centre,         1, coverage + centre - 1,     1, mask + out, 1, n)
                        vDSP_vmin(mask + out,                1, coverage + centre + 1,     1, mask + out, 1, n)
                        vDSP_vmin(mask + out,                1, coverage + centre - width, 1, mask + out, 1, n)
                        vDSP_vmin(mask + out,                1, coverage + centre + width, 1, mask + out, 1, n)
                        // Below the limit -> 0, at or above -> 1.
                        vDSP_vthrsc(mask + out, 1, &limit, &one, mask + out, 1, n)
                        vDSP_vthres(mask + out, 1, &zero, mask + out, 1, n)

                        vDSP_vmul(image + centre, 1, mask + out, 1, temp + out, 1, n)
                    }

                    let total = vDSP_Length(count)
                    // energy = Σ mask · (gx² + gy²)
                    vDSP_vsq(gx, 1, gx, 1, total)
                    vDSP_vsq(gy, 1, gy, 1, total)
                    vDSP_vadd(gx, 1, gy, 1, gx, 1, total)
                    vDSP_dotpr(gx, 1, mask, 1, &energySum, total)

                    vDSP_sve(temp, 1, &valueSum, total)
                    vDSP_sve(mask, 1, &maskSum, total)
                }}}}
            }
        }

        guard maskSum > 0 else { return 0 }
        let mean = valueSum / maskSum
        guard mean > 0 else { return 0 }
        return (energySum / maskSum) / (mean * mean)
    }

    /// Reusable buffers for `gradientEnergy`, so a 41-step search does not
    /// allocate 41 times.
    private struct Scratch {
        var gx: [Float] = []
        var gy: [Float] = []
        var mask: [Float] = []
        var temp: [Float] = []

        mutating func ensure(count: Int) {
            guard gx.count != count else { return }
            gx = [Float](repeating: 0, count: count)
            gy = [Float](repeating: 0, count: count)
            mask = [Float](repeating: 0, count: count)
            temp = [Float](repeating: 0, count: count)
        }
    }


    // MARK: - Aberrations

    /// A fitted displacement field, in the plugin's own parameterisation:
    /// scan pixels of shift per (detector pixel of tilt)^n.
    private struct Aberrations {
        var coefficients: [Float]
        var terms: Int
        var rmsResidual: Float      // scan px, after the fit
        var rmsMeasured: Float      // scan px, of the measured field itself
        var groupsUsed: Int
    }

    /// How many basis terms each correction level uses.
    ///
    /// The displacement of the image formed at tilt t is the gradient of the
    /// aberration function, so each aberration contributes a fixed vector
    /// polynomial in t with one free coefficient. That the coefficients enter
    /// linearly is what makes this a least-squares fit rather than a search
    /// through many dimensions.
    private func termCount(for correction: String) -> Int {
        if correction.hasPrefix("Defocus + astig") { return 3 }
        if correction.hasPrefix("+ coma") { return 7 }
        if correction.hasPrefix("+ spherical") { return 8 }
        return 1
    }

    /// Gradient basis at tilt (tx, ty), in detector pixels.
    ///
    ///  1      defocus C1            grad of  (tx²+ty²)/2
    ///  2,3    twofold astigmatism   grad of  (tx²−ty²)/2  and  tx·ty
    ///  4...7  coma and threefold    gradients of the four cubics
    ///  8      spherical C3          grad of  (tx²+ty²)²/4
    private func basis(tx: Float, ty: Float, terms: Int) -> [(Float, Float)] {
        var rows: [(Float, Float)] = [(tx, ty)]
        if terms >= 3 {
            rows.append((tx, -ty))
            rows.append((ty,  tx))
        }
        if terms >= 7 {
            rows.append((3 * tx * tx, 0))
            rows.append((2 * tx * ty, tx * tx))
            rows.append((ty * ty,     2 * tx * ty))
            rows.append((0,           3 * ty * ty))
        }
        if terms >= 8 {
            let r2 = tx * tx + ty * ty
            rows.append((r2 * tx, r2 * ty))
        }
        return rows
    }

    /// Pure-defocus shifts, the one-parameter case.
    private func linearShifts(grouping: Grouping, edgeShift: Float, radius: Float) -> ([Float], [Float]) {
        let k = radius > 0 ? edgeShift / radius : 0
        var x = [Float](repeating: 0, count: grouping.groupCount)
        var y = [Float](repeating: 0, count: grouping.groupCount)
        for g in 0..<grouping.groupCount {
            x[g] = k * grouping.tiltX[g]
            y[g] = k * grouping.tiltY[g]
        }
        return (x, y)
    }

    private func modelShifts(grouping: Grouping, aberrations: Aberrations) -> ([Float], [Float]) {
        var x = [Float](repeating: 0, count: grouping.groupCount)
        var y = [Float](repeating: 0, count: grouping.groupCount)
        for g in 0..<grouping.groupCount {
            let rows = basis(tx: grouping.tiltX[g], ty: grouping.tiltY[g], terms: aberrations.terms)
            var sx: Float = 0, sy: Float = 0
            for (n, row) in rows.enumerated() where n < aberrations.coefficients.count {
                sx += aberrations.coefficients[n] * row.0
                sy += aberrations.coefficients[n] * row.1
            }
            x[g] = sx
            y[g] = sy
        }
        return (x, y)
    }

    // MARK: Measuring the displacement field

    private struct MeasuredShift {
        var dx: Float
        var dy: Float
        var weight: Float
    }

    /// Cross-correlates every virtual image against a reference to measure where
    /// it actually sits.
    ///
    /// The reference is the defocus-corrected sum, so what is left to find is a
    /// small residual — a few scan pixels at most. That is why a direct search
    /// over a short range is enough and no FFT is needed, and it is also why
    /// this is bootstrapped from the defocus search rather than run cold.
    private func measureShifts(host: FDSHostContext, stack: inout [Float], grouping: Grouping,
                               scanWidth: Int, scanHeight: Int,
                               baseShiftX: [Float], baseShiftY: [Float],
                               reference: [Float], searchRadius: Int) -> [MeasuredShift]? {

        let scanPixels = scanWidth * scanHeight
        var centred = reference
        var mean: Float = 0
        vDSP_meanv(reference, 1, &mean, vDSP_Length(scanPixels))
        var negativeMean = -mean
        vDSP_vsadd(reference, 1, &negativeMean, &centred, 1, vDSP_Length(scanPixels))

        var results = [MeasuredShift](repeating: MeasuredShift(dx: 0, dy: 0, weight: 0),
                                      count: grouping.groupCount)
        let span = 2 * searchRadius + 1
        var scores = [Float](repeating: 0, count: span * span)
        var image = [Float](repeating: 0, count: scanPixels)

        for group in 0..<grouping.groupCount {
            if host.isCancelled { return nil }

            // Zero-mean copy of this group's virtual image.
            stack.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var groupMean: Float = 0
                vDSP_meanv(base + group * scanPixels, 1, &groupMean, vDSP_Length(scanPixels))
                var negative = -groupMean
                vDSP_vsadd(base + group * scanPixels, 1, &negative, &image, 1, vDSP_Length(scanPixels))
            }

            let baseX = Int(baseShiftX[group].rounded())
            let baseY = Int(baseShiftY[group].rounded())

            var best = -Float.greatestFiniteMagnitude
            var bestU = 0, bestV = 0

            image.withUnsafeBufferPointer { src in
            centred.withUnsafeBufferPointer { ref in
                guard let source = src.baseAddress, let referenceBase = ref.baseAddress else { return }
                for v in -searchRadius...searchRadius {
                    for u in -searchRadius...searchRadius {
                        let offsetX = baseX + u, offsetY = baseY + v
                        let firstX = Swift.max(0, -offsetX), lastX = Swift.min(scanWidth, scanWidth - offsetX)
                        let firstY = Swift.max(0, -offsetY), lastY = Swift.min(scanHeight, scanHeight - offsetY)
                        guard lastX > firstX, lastY > firstY else { continue }

                        let run = vDSP_Length(lastX - firstX)
                        var total: Float = 0
                        for y in firstY..<lastY {
                            var partial: Float = 0
                            vDSP_dotpr(source + (y + offsetY) * scanWidth + firstX + offsetX, 1,
                                       referenceBase + y * scanWidth + firstX, 1,
                                       &partial, run)
                            total += partial
                        }
                        // Per-sample, so a larger overlap is not rewarded on its own.
                        let score = total / Float((lastX - firstX) * (lastY - firstY))
                        scores[(v + searchRadius) * span + (u + searchRadius)] = score
                        if score > best { best = score; bestU = u; bestV = v }
                    }
                }
            }}

            guard best > 0 else { continue }   // no usable correlation for this group

            // Parabolic refinement, skipped at the edge of the search window
            // where the peak is probably outside it.
            var refinedU = Float(bestU), refinedV = Float(bestV)
            if abs(bestU) < searchRadius {
                let l = scores[(bestV + searchRadius) * span + (bestU - 1 + searchRadius)]
                let r = scores[(bestV + searchRadius) * span + (bestU + 1 + searchRadius)]
                let d = l - 2 * best + r
                if abs(d) > .ulpOfOne { refinedU += Swift.max(-1, Swift.min(1, 0.5 * (l - r) / d)) }
            }
            if abs(bestV) < searchRadius {
                let l = scores[(bestV - 1 + searchRadius) * span + (bestU + searchRadius)]
                let r = scores[(bestV + 1 + searchRadius) * span + (bestU + searchRadius)]
                let d = l - 2 * best + r
                if abs(d) > .ulpOfOne { refinedV += Swift.max(-1, Swift.min(1, 0.5 * (l - r) / d)) }
            }

            results[group] = MeasuredShift(dx: Float(baseX) + refinedU,
                                           dy: Float(baseY) + refinedV,
                                           weight: best)
            host.reportProgress(0.7 + 0.15 * Double(group + 1) / Double(grouping.groupCount))
        }
        return results
    }

    /// Weighted least squares of the measured field onto the gradient basis.
    ///
    /// Fitting rather than using the measured shifts directly is deliberate:
    /// the model has at most eight parameters against hundreds of measurements,
    /// so it averages away per-group correlation noise, and it cannot represent
    /// a displacement field that no aberration could produce.
    private func fitAberrations(grouping: Grouping, measured: [MeasuredShift], terms: Int) -> Aberrations? {
        var normal = [[Double]](repeating: [Double](repeating: 0, count: terms), count: terms)
        var target = [Double](repeating: 0, count: terms)
        var used = 0
        var weightTotal: Double = 0
        var measuredSquares: Double = 0

        // Weights are correlation peak heights, normalised so no single strong
        // group dominates.
        let peak = measured.map { $0.weight }.max() ?? 1
        guard peak > 0 else { return nil }

        for g in 0..<grouping.groupCount {
            let m = measured[g]
            guard m.weight > 0 else { continue }
            let w = Double(m.weight / peak)
            let rows = basis(tx: grouping.tiltX[g], ty: grouping.tiltY[g], terms: terms)
            for a in 0..<terms {
                target[a] += w * (Double(rows[a].0) * Double(m.dx) + Double(rows[a].1) * Double(m.dy))
                for b in 0..<terms {
                    normal[a][b] += w * (Double(rows[a].0) * Double(rows[b].0)
                                       + Double(rows[a].1) * Double(rows[b].1))
                }
            }
            measuredSquares += w * (Double(m.dx * m.dx) + Double(m.dy * m.dy))
            weightTotal += w
            used += 1
        }
        guard used >= terms + 2, weightTotal > 0 else { return nil }
        guard let solution = solve(normal, target) else { return nil }

        let coefficients = solution.map { Float($0) }
        var residualSquares: Double = 0
        for g in 0..<grouping.groupCount {
            let m = measured[g]
            guard m.weight > 0 else { continue }
            let w = Double(m.weight / peak)
            let rows = basis(tx: grouping.tiltX[g], ty: grouping.tiltY[g], terms: terms)
            var px: Float = 0, py: Float = 0
            for n in 0..<terms { px += coefficients[n] * rows[n].0; py += coefficients[n] * rows[n].1 }
            residualSquares += w * (Double((m.dx - px) * (m.dx - px)) + Double((m.dy - py) * (m.dy - py)))
        }

        return Aberrations(coefficients: coefficients, terms: terms,
                           rmsResidual: Float((residualSquares / weightTotal).squareRoot()),
                           rmsMeasured: Float((measuredSquares / weightTotal).squareRoot()),
                           groupsUsed: used)
    }

    /// Gaussian elimination with partial pivoting. The system is at most 8×8,
    /// so nothing fancier is warranted.
    private func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = matrix
        var b = rhs
        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivot][column]) { pivot = row }
            guard abs(a[pivot][column]) > 1e-12 else { return nil }   // singular: basis not constrained
            if pivot != column { a.swapAt(pivot, column); b.swapAt(pivot, column) }
            for row in (column + 1)..<n {
                let factor = a[row][column] / a[column][column]
                guard factor != 0 else { continue }
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        return x.allSatisfy { $0.isFinite } ? x : nil
    }

    /// Fitted coefficients, in the file's units when it has them.
    private func describeAberrations(_ fit: Aberrations, radius: Float, units: Units) -> String {
        var parts: [String] = []

        if units.calibrated {
            parts.append("defocus " + units.formatLength(units.length(fit.coefficients[0], order: 1)))
        } else {
            parts.append(String(format: "defocus %.3f scan px/det px", fit.coefficients[0]))
        }

        if fit.terms >= 3 {
            let a = fit.coefficients[1], b = fit.coefficients[2]
            let magnitude = (a * a + b * b).squareRoot()
            // The astigmatism axis is the angle doubled, hence the half.
            let angle = 0.5 * atan2(Double(b), Double(a)) * 180.0 / Double.pi
            if units.calibrated {
                parts.append(String(format: "astigmatism %@ at %.0f°",
                                    units.formatLength(units.length(magnitude, order: 1)), angle))
            } else {
                parts.append(String(format: "astigmatism %.3f scan px/det px at %.0f°", magnitude, angle))
            }
        }
        if fit.terms >= 7 {
            var edge: Float = 0
            for n in 3..<Swift.min(7, fit.coefficients.count) {
                edge += abs(fit.coefficients[n]) * radius * radius
            }
            if units.calibrated {
                // Second-order terms are a length per rad²; quoting the length
                // at the edge of the disc keeps it comparable with the others.
                parts.append("coma/threefold " + units.formatLength(units.length(edge / Swift.max(radius, 1), order: 1)) + " at the disc edge")
            } else {
                parts.append(String(format: "coma/threefold %.2f scan px at the disc edge", edge))
            }
        }
        if fit.terms >= 8, fit.coefficients.count >= 8 {
            if units.calibrated {
                parts.append("spherical " + units.formatLength(units.length(fit.coefficients[7], order: 3)))
            } else {
                parts.append(String(format: "spherical %.4g scan px/det px³", fit.coefficients[7]))
            }
        }
        return parts.joined(separator: ", ")
    }

    private func calibrated(scanStep: Double, diffStep: Double) -> Bool {
        return scanStep > 0 && diffStep > 0
    }

    // MARK: - Reconstruction

    private func reconstruct(stack: inout [Float], grouping: Grouping,
                             scanWidth: Int, scanHeight: Int,
                             shiftX: [Float], shiftY: [Float]) -> [Float] {

        let scanPixels = scanWidth * scanHeight
        var accumulator = [Float](repeating: 0, count: scanPixels)
        var coverage = [Float](repeating: 0, count: scanPixels)

        accumulate(stack: &stack, grouping: grouping, scanWidth: scanWidth, scanHeight: scanHeight,
                   shiftX: shiftX, shiftY: shiftY, bilinear: true,
                   accumulator: &accumulator, coverage: &coverage)

        // Rescale to the intensity a plain BF sum would have given, so the
        // numbers stay comparable with the app's own integrating detector.
        let n = vDSP_Length(scanPixels)
        var maximumCoverage: Float = 0
        vDSP_maxv(coverage, 1, &maximumCoverage, n)

        var safeCoverage = [Float](repeating: 0, count: scanPixels)
        var one: Float = 1
        vDSP_vthr(coverage, 1, &one, &safeCoverage, 1, n)

        var result = [Float](repeating: 0, count: scanPixels)
        vDSP_vdiv(safeCoverage, 1, accumulator, 1, &result, 1, n)
        vDSP_vsmul(result, 1, &maximumCoverage, &result, 1, n)
        return result
    }
}
