//
//  ACBFPlugin.swift
//  4DSTEM Explorer — Aberration-Corrected Bright Field
//
//  Aberration-corrected bright field, after the method used by fast-acbf in the
//  py4D-browser plugin of the same name.
//
//  What this does that the Tilt-Corrected Bright Field plugin does not: it
//  corrects the bright-field transfer function itself rather than only the
//  displacement it produces. tcBF translates each virtual image and adds it up,
//  which cancels the part of the aberration phase that is linear in the
//  specimen's spatial frequency. Everything beyond that — including the sign
//  reversals of the contrast transfer function — survives. acBF builds the
//  complex transfer for every bright-field pixel and either aligns the phases
//  before summing or inverts the whole thing as a regularised matched filter.
//
//  Both are offered here, along with tcBF done properly as a Fourier phase ramp
//  rather than by interpolation, so the three can be compared on the same data
//  with the same aberrations.
//
//  Aberrations and orientation are found by maximising how sharp the
//  reconstruction looks — see ACBFRefinement.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Accelerate

// MARK: - Plugin

@objc(ACBFPlugin)
public final class ACBFPlugin: NSObject, FDSPlugin {

    public override init() { super.init() }

    public var pluginIdentifier: String { return "group.lebeau.4dstem.plugin.acbf" }
    public var pluginName: String { return "Aberration-Corrected BF" }
    public var pluginAPIVersion: Int { return FDSPluginAPIVersion }
    public var pluginRequiresData: Bool { return true }
    public var pluginSupportsLiveUpdate: Bool { return true }

    public var pluginSummary: String {
        return "Corrects the bright-field transfer function, not just the tilt-induced shift. "
             + "Aberrations and scan orientation are found by maximising image sharpness."
    }

    // MARK: State kept across live updates

    /// The full coefficient vector in Å. Only the low orders get their own
    /// controls; the rest are filled in by refinement and reported in the
    /// aberration text output.
    private var coefficients: [Double] = []
    private var ordersInUse = ACBFOrders(maxOrder: 2)

    private struct StackKey: Equatable {
        var fileName: String
        var scanWidth: Int
        var scanHeight: Int
        var centerX: Float
        var centerY: Float
        var radius: Float
        var binning: Int
    }

    private var cachedKey: StackKey?
    private var cachedStack: ACBFStack?
    /// Detector coordinates in Å⁻¹ before any frame transform.
    private var cachedDetectorX: [Double] = []
    private var cachedDetectorY: [Double] = []

    private lazy var accelerator: ACBFMetalAccumulator? = ACBFMetalAccumulator()

    private static let autoDiscChoice = "Auto-detect disc"

    // MARK: - Parameters

    public func parameters(for host: FDSHostContext) -> [[String: Any]] {
        var tailored = pluginParameters
        for index in tailored.indices {
            guard let id = tailored[index][FDSParameterKey.identifier] as? String else { continue }
            switch id {
            case "detector":
                tailored[index] = FDSParameter.choice(
                    "detector", label: "Bright-field disc from",
                    choices: discSources(host: host),
                    defaultValue: ACBFPlugin.autoDiscChoice,
                    help: "Where the disc centre and radius come from. The radius sets the convergence semi-angle, which the transfer function depends on directly.")
            case "voltage":
                // The file usually knows; seeding from it saves retyping and
                // avoids a wavelength that silently disagrees with the data.
                let known = host.accelerationKilovolts
                tailored[index] = FDSParameter.number(
                    "voltage", label: "Accelerating voltage (kV)",
                    defaultValue: known > 0 ? known : 200, minimum: 10, maximum: 1000,
                    help: known > 0
                        ? "Read from the file. The wavelength follows from this and every phase in the reconstruction is measured in it."
                        : "The file does not record it. Set it correctly — the wavelength follows from this and every phase depends on it.")
            default:
                break
            }
        }
        return tailored
    }

    public var pluginParameters: [[String: Any]] {
        return [
            FDSParameter.choice("output", label: "Return",
                                choices: ["Reconstruction", "Defocus curve", "Aberration report"],
                                help: "The reconstruction, the sharpness-versus-defocus curve, or a written summary of the fitted aberrations and calibration."),
            FDSParameter.choice("mode", label: "Reconstruction",
                                choices: ["acBF (phase only)", "acBF (complex inversion)", "tcBF"],
                                help: "tcBF shifts and sums. Phase-only acBF aligns each detector's contribution by the phase of its transfer. Complex inversion solves a regularised matched filter over all detectors, which also restores amplitude but needs a good calibration to behave."),
            FDSParameter.choice("detector", label: "Bright-field disc from",
                                choices: [ACBFPlugin.autoDiscChoice],
                                help: "Where the disc centre and radius come from."),
            FDSParameter.integer("binning", label: "Detector binning", defaultValue: 4,
                                 minimum: 1, maximum: 32,
                                 help: "Groups disc pixels into virtual detectors. Memory and time scale with the number of groups, so this is the main cost control; too coarse and the transfer varies within a group."),

            FDSParameter.number("voltage", label: "Accelerating voltage (kV)", defaultValue: 200,
                                minimum: 10, maximum: 1000),
            FDSParameter.number("convergence", label: "Convergence semi-angle (mrad, 0 = from disc)",
                                defaultValue: 0, minimum: 0, maximum: 200,
                                help: "Overrides the angle implied by the disc radius and the diffraction calibration."),
            FDSParameter.number("rolloff", label: "Aperture edge taper (mrad)", defaultValue: 0,
                                minimum: 0, maximum: 20,
                                help: "Softens the aperture edge with a cosine taper. A hard edge truncates the transfer mid-oscillation and rings; a few mrad trades a little resolution for a cleaner image."),

            FDSParameter.integer("maxOrder", label: "Highest aberration order", defaultValue: 2,
                                 minimum: 1, maximum: 4,
                                 help: "1 is defocus and twofold astigmatism; 2 adds coma and threefold; 3 adds spherical, star and fourfold; 4 goes further. More orders need more signal to pin down and cost more to refine."),
            FDSParameter.number("c1", label: "C1 defocus (Å)", defaultValue: 0,
                                minimum: -100000, maximum: 100000,
                                help: "Positive is overfocus. Drag to refocus live."),
            FDSParameter.number("a1a", label: "A1 astigmatism a (Å)", defaultValue: 0,
                                minimum: -50000, maximum: 50000),
            FDSParameter.number("a1b", label: "A1 astigmatism b (Å)", defaultValue: 0,
                                minimum: -50000, maximum: 50000),

            FDSParameter.number("rotation", label: "Scan rotation (deg)", defaultValue: 0,
                                minimum: -180, maximum: 180,
                                help: "Angle between the detector and scan frames. Only observable through an anisotropic aberration — a pure defocus looks the same at every rotation."),
            FDSParameter.toggle("flipRows", label: "Flip rows", defaultValue: false),
            FDSParameter.toggle("flipColumns", label: "Flip columns", defaultValue: false),
            FDSParameter.toggle("transpose", label: "Transpose", defaultValue: false),

            FDSParameter.choice("metric", label: "Sharpness metric",
                                choices: ["Sobel gradient", "Laplacian variance", "Normalised variance"],
                                help: "What refinement maximises. Sobel is the most reliable general choice; normalised variance suits images dominated by a few strong features."),
            FDSParameter.button("refineDefocus", label: "Refine Defocus",
                                help: "Sweeps defocus, then refines the peak."),
            FDSParameter.button("refineAberrations", label: "Refine Aberrations",
                                help: "Sweeps each coefficient in turn, then runs a simplex over all of them together. Use after Refine Defocus."),
            FDSParameter.button("refineOrientation", label: "Refine Orientation",
                                help: "Searches every flip and transpose combination and the scan rotation within each."),
            FDSParameter.button("refineAll", label: "Refine All",
                                help: "Defocus, then orientation, then aberrations, in that order."),
            FDSParameter.button("zeroAll", label: "Zero Aberrations",
                                help: "Clears every coefficient, including the higher orders that have no control of their own."),

            FDSParameter.number("regularization", label: "Inversion regularisation", defaultValue: 1e-3,
                                minimum: 1e-8, maximum: 1,
                                help: "Damps frequencies the transfer barely carries. Only used by complex inversion; too small and it amplifies noise."),
            FDSParameter.toggle("useGPU", label: "Use GPU when available", defaultValue: true,
                                help: "Metal accumulation. The CPU path computes the same quantity in double precision and is used automatically if Metal is unavailable.")
        ]
    }

    private func discSources(host: FDSHostContext) -> [String] {
        var choices = [ACBFPlugin.autoDiscChoice]
        for index in 0..<host.detectorCount {
            guard let info = host.detectorInfo(at: index) else { continue }
            let name = info[FDSDetectorKey.name] as? String ?? "Detector \(index + 1)"
            let shape = info[FDSDetectorKey.shape] as? String ?? ""
            choices.append("\(index + 1). \(name)\(shape.isEmpty ? "" : " (\(shape))")")
        }
        return choices
    }

    // MARK: - Run

    public func run(host: FDSHostContext, parameters: [String: Any]) -> [String: Any]? {

        let scanWidth = host.scanWidth, scanHeight = host.scanHeight
        guard scanWidth > 0, scanHeight > 0 else {
            return FDSResult.failure("No 4D dataset is open.")
        }

        let output = parameters["output"] as? String ?? "Reconstruction"
        let modeName = parameters["mode"] as? String ?? "acBF (phase only)"
        let binning = max(1, (parameters["binning"] as? NSNumber)?.intValue ?? 4)
        let maxOrder = max(1, min(4, (parameters["maxOrder"] as? NSNumber)?.intValue ?? 2))
        let voltage = (parameters["voltage"] as? NSNumber)?.doubleValue ?? 200
        let convergenceOverride = (parameters["convergence"] as? NSNumber)?.doubleValue ?? 0
        let rolloff = (parameters["rolloff"] as? NSNumber)?.doubleValue ?? 0
        let regularization = (parameters["regularization"] as? NSNumber)?.doubleValue ?? 1e-3
        let useGPU = (parameters["useGPU"] as? NSNumber)?.boolValue ?? true
        let metric = ACBFMetric.named(parameters["metric"] as? String ?? "Sobel gradient")

        // 1. Calibration. Without a scan step and a diffraction step there is no
        //    way to put the transfer in physical units, and guessing would give
        //    a confidently wrong answer.
        guard host.scanStepNanometers > 0 else {
            return FDSResult.failure("This dataset has no scan calibration. acBF works in physical units — set the scan step with Calibrate before running it.")
        }
        guard host.diffractionStepMilliradians > 0 else {
            return FDSResult.failure("This dataset has no diffraction calibration. Set the diffraction sampling with Calibrate before running acBF.")
        }

        // 2. The disc.
        guard let disc = locateDisc(host: host, parameters: parameters) else {
            return FDSResult.failure("Could not find the bright-field disc. Pick a detector that covers it, or check the diffraction calibration.")
        }

        let convergence = convergenceOverride > 0
            ? convergenceOverride
            : Double(disc.radius) * host.diffractionStepMilliradians
        guard let optics = ACBFOptics(kilovolts: voltage,
                                      diffractionStepMilliradians: host.diffractionStepMilliradians,
                                      discRadiusPixels: convergence / host.diffractionStepMilliradians,
                                      scanStepNanometres: host.scanStepNanometers,
                                      rolloffMilliradians: rolloff)
        else { return FDSResult.failure("The calibration is not usable: check the voltage, scan step and diffraction step.") }

        // 3. Coefficient vector, resized if the user changed the order.
        let orders = ACBFOrders(maxOrder: maxOrder)
        resizeCoefficients(to: orders)

        if (parameters["zeroAll"] as? NSNumber)?.boolValue == true {
            coefficients = [Double](repeating: 0, count: orders.coefficientCount)
        }
        // Controls win over stored state, so dragging the defocus slider works.
        if let index = orders.defocusIndex,
           let value = (parameters["c1"] as? NSNumber)?.doubleValue {
            coefficients[index] = value
        }
        if let (ia, ib) = orders.astigmatismIndices {
            if let a = (parameters["a1a"] as? NSNumber)?.doubleValue { coefficients[ia] = a }
            if let b = (parameters["a1b"] as? NSNumber)?.doubleValue { coefficients[ib] = b }
        }

        var transform = ACBFCoordinateTransform(
            flipRows: (parameters["flipRows"] as? NSNumber)?.boolValue ?? false,
            flipColumns: (parameters["flipColumns"] as? NSNumber)?.boolValue ?? false,
            transpose: (parameters["transpose"] as? NSNumber)?.boolValue ?? false,
            rotationDegrees: (parameters["rotation"] as? NSNumber)?.doubleValue ?? 0)

        // 4. The virtual-image stack, rebuilt only when its inputs change.
        let key = StackKey(fileName: host.fileName, scanWidth: scanWidth, scanHeight: scanHeight,
                           centerX: disc.centerX, centerY: disc.centerY, radius: disc.radius,
                           binning: binning)
        var rebuilt = false
        if key != cachedKey || cachedStack == nil {
            host.log("Building virtual images for a \(String(format: "%.1f", disc.radius)) px disc at binning \(binning)")
            switch buildStack(host: host, disc: disc, binning: binning, optics: optics) {
            case .failure(let reason):
                return FDSResult.failure(reason)
            case .cancelled:
                return nil
            case .success(let stack, let dx, let dy):
                cachedStack = stack
                cachedDetectorX = dx
                cachedDetectorY = dy
                cachedKey = key
                rebuilt = true
            }
        }
        guard let baseStack = cachedStack else { return FDSResult.failure("The virtual images could not be built.") }
        if host.isCancelled { return nil }

        let mode: ACBFMode
        switch modeName {
        case "tcBF": mode = .tcBF
        case "acBF (complex inversion)":
            mode = .acBFComplexInversion(regularization: regularization, supportThreshold: 1e-6)
        default: mode = .acBFPhaseOnly
        }

        let reconstructor = ACBFReconstructor(optics: optics, orders: orders)
        var refinement = ACBFRefinement(reconstructor: reconstructor, orders: orders,
                                        detectorX: cachedDetectorX, detectorY: cachedDetectorY)
        refinement.metric = metric
        refinement.mode = mode
        refinement.accelerator = useGPU ? accelerator : nil
        refinement.isCancelled = { host.isCancelled }

        var notes: [String] = []
        var defocusCurve: (x: [Float], y: [Float])?

        // 5. Buttons. Each one is an action for exactly the run it fired on.
        let pressedDefocus = (parameters["refineDefocus"] as? NSNumber)?.boolValue ?? false
        let pressedAberrations = (parameters["refineAberrations"] as? NSNumber)?.boolValue ?? false
        let pressedOrientation = (parameters["refineOrientation"] as? NSNumber)?.boolValue ?? false
        let pressedAll = (parameters["refineAll"] as? NSNumber)?.boolValue ?? false
        let wantsCurve = output == "Defocus curve"

        func staged(_ t: ACBFCoordinateTransform) -> ACBFStack {
            return baseStack.retilted(using: t, detectorX: cachedDetectorX, detectorY: cachedDetectorY)
        }

        if pressedDefocus || pressedAll || wantsCurve {
            // A defocus search needs a range. One radian of phase per unit of
            // C1 sets the natural scale, and ±20 of those covers anything the
            // sharpness curve can still resolve.
            let range = 20 * optics.coefficientScale(order: 1)
            if let result = refinement.refineDefocus(stack: staged(transform),
                                                     coefficients: coefficients,
                                                     range: range, points: 41) {
                if pressedDefocus || pressedAll {
                    coefficients = result.coefficients
                    notes.append(String(format: "defocus %.0f Å", result.defocus))
                }
                defocusCurve = (result.sweepDefocus.map { Float($0) },
                                result.sweepScore.map { Float($0) })
            } else if host.isCancelled { return nil }
        }

        if pressedOrientation || pressedAll {
            if let result = refinement.refineFlips(transform: transform, stack: baseStack,
                                                   coefficients: coefficients,
                                                   rotationHalfWidth: 45) {
                transform = result.transform
                notes.append(String(format: "rotation %.1f°%@%@%@", result.rotationDegrees,
                                    transform.flipRows ? ", flip rows" : "",
                                    transform.flipColumns ? ", flip cols" : "",
                                    transform.transpose ? ", transpose" : ""))
            } else if host.isCancelled { return nil }
        }

        if pressedAberrations || pressedAll {
            if let result = refinement.refineAberrations(stack: staged(transform),
                                                         coefficients: coefficients,
                                                         radiansOfSearch: 3.0, passes: 2) {
                coefficients = result.coefficients
                notes.append("\(result.evaluations) reconstructions")
            } else if host.isCancelled { return nil }
        }

        if host.isCancelled { return nil }

        // 6. Hand refined values back to the controls.
        var writeBack: [String: Any] = [:]
        if pressedDefocus || pressedAberrations || pressedOrientation || pressedAll || (parameters["zeroAll"] as? NSNumber)?.boolValue == true {
            if let index = orders.defocusIndex {
                writeBack["c1"] = NSNumber(value: coefficients[index])
            }
            if let (ia, ib) = orders.astigmatismIndices {
                writeBack["a1a"] = NSNumber(value: coefficients[ia])
                writeBack["a1b"] = NSNumber(value: coefficients[ib])
            }
            writeBack["rotation"] = NSNumber(value: transform.rotationDegrees)
            writeBack["flipRows"] = NSNumber(value: transform.flipRows)
            writeBack["flipColumns"] = NSNumber(value: transform.flipColumns)
            writeBack["transpose"] = NSNumber(value: transform.transpose)
        }

        // 7. Output.
        if output == "Defocus curve" {
            guard let curve = defocusCurve else {
                return FDSResult.failure("The defocus sweep produced nothing — check the calibration.")
            }
            var result = FDSResult.plot(
                x: curve.x, y: curve.y,
                title: "acBF defocus curve — \(host.fileName)",
                xLabel: "C1 defocus (Å)", yLabel: metric.label,
                message: "\(baseStack.count) virtual detectors, binning \(binning), \(String(format: "%.1f", convergence)) mrad convergence.")
            if !writeBack.isEmpty { result[FDSResultKey.parameters] = writeBack }
            return result
        }

        let stack = staged(transform)
        let scanFrame = transform.rotateCoefficients(coefficients, orders: orders)

        if output == "Aberration report" {
            var report = "Aberration-corrected bright field\n\n"
            report += "File             \(host.fileName)\n"
            report += String(format: "Voltage          %.0f kV  (λ = %.5f Å)\n", voltage, optics.wavelength)
            report += String(format: "Convergence      %.2f mrad%@\n", convergence,
                             convergenceOverride > 0 ? "  (set by hand)" : "  (from the disc radius)")
            report += String(format: "Detector pixel   %.5f Å⁻¹\n", optics.dk)
            report += String(format: "Scan step        %.4f Å\n", optics.scanStep)
            report += "Virtual images   \(baseStack.count) (binning \(binning))\n"
            report += String(format: "Scan grid        %d×%d, transformed at %d×%d\n",
                             scanWidth, scanHeight, baseStack.columns, baseStack.rows)
            report += "Compute          \(useGPU ? (accelerator?.deviceName ?? "CPU (Metal unavailable)") : "CPU (requested)")\n\n"

            report += "Orientation\n"
            report += String(format: "  scan rotation  %.2f°\n", transform.rotationDegrees)
            report += "  flip rows      \(transform.flipRows)\n"
            report += "  flip columns   \(transform.flipColumns)\n"
            report += "  transpose      \(transform.transpose)\n\n"

            report += "Aberrations (Å, detector frame)\n"
            let labels = orders.coefficientLabels
            for (index, label) in labels.enumerated() {
                let value = coefficients[index]
                // Also as phase at the aperture edge, which is what decides
                // whether a term matters at all.
                let key = orders.keys.first { index >= $0.offset && index < $0.offset + $0.width }
                let radians = key.map { value / optics.coefficientScale(order: $0.n) } ?? 0
                report += String(format: "  %-26@ % 12.4g   (%+.2f rad at the edge)\n",
                                 label as NSString, value, radians)
            }
            report += "\nA term contributing much less than about a tenth of a radian at the\n"
            report += "aperture edge cannot be measured from image sharpness, and a value\n"
            report += "reported for one should be read as noise rather than as a measurement.\n\n"
            report += "The scan rotation and the astigmatism azimuth are partly degenerate:\n"
            report += "rotating the frame and the aberrations together rotates the result\n"
            report += "but does not blur it, and no isotropic sharpness metric can tell\n"
            report += "that apart. Fix the rotation from a known specimen direction when\n"
            report += "the absolute angle matters.\n"

            var result = FDSResult.text(report, title: "acBF Aberrations — \(host.fileName)")
            if !writeBack.isEmpty { result[FDSResultKey.parameters] = writeBack }
            return result
        }

        guard let image = reconstructor.reconstruct(stack: stack, coefficients: scanFrame,
                                                    mode: mode,
                                                    accelerator: useGPU ? accelerator : nil,
                                                    isCancelled: { host.isCancelled })
        else { return host.isCancelled ? nil : FDSResult.failure("The reconstruction failed.") }

        host.reportProgress(1.0)

        let score = metric.score(image, rows: scanHeight, columns: scanWidth)
        var message = String(format: "%@ · %d virtual detectors, binning %d · %.1f mrad · %@ %.4g",
                             modeName, baseStack.count, binning, convergence, metric.label, score)
        if !notes.isEmpty { message += " · refined: " + notes.joined(separator: ", ") }
        if rebuilt { message += " · virtual images rebuilt" }

        var result = FDSResult.scanImage(image, rows: scanHeight, columns: scanWidth,
                                         title: "\(modeName) — \(host.fileName)",
                                         message: message)
        if !writeBack.isEmpty { result[FDSResultKey.parameters] = writeBack }
        return result
    }

    // MARK: - Coefficients

    /// Keeps the stored vector the right length as the user changes the order,
    /// preserving what has already been found rather than starting over.
    private func resizeCoefficients(to orders: ACBFOrders) {
        guard orders.coefficientCount != coefficients.count || orders.maxOrder != ordersInUse.maxOrder else { return }
        var resized = [Double](repeating: 0, count: orders.coefficientCount)
        for key in orders.keys {
            guard let old = ordersInUse.keys.first(where: { $0.n == key.n && $0.m == key.m }),
                  old.offset + old.width <= coefficients.count else { continue }
            for slot in 0..<key.width { resized[key.offset + slot] = coefficients[old.offset + slot] }
        }
        coefficients = resized
        ordersInUse = orders
    }

    // MARK: - Disc

    private struct Disc {
        var centerX: Float
        var centerY: Float
        var radius: Float
        var source: String
    }

    private func locateDisc(host: FDSHostContext, parameters: [String: Any]) -> Disc? {
        let width = host.patternWidth, height = host.patternHeight
        guard width > 0, height > 0 else { return nil }

        // A named detector, when the user picked one.
        if let choice = parameters["detector"] as? String, choice != ACBFPlugin.autoDiscChoice,
           let number = Int(choice.prefix(while: { $0.isNumber })), number >= 1,
           number <= host.detectorCount,
           let info = host.detectorInfo(at: number - 1) {
            let cx = (info[FDSDetectorKey.centerX] as? NSNumber)?.floatValue ?? Float(width) / 2
            let cy = (info[FDSDetectorKey.centerY] as? NSNumber)?.floatValue ?? Float(height) / 2
            let outer = (info[FDSDetectorKey.outerRadius] as? NSNumber)?.floatValue ?? 0
            if outer > 0 {
                return Disc(centerX: cx, centerY: cy, radius: outer,
                            source: info[FDSDetectorKey.name] as? String ?? "detector \(number)")
            }
        }

        // Otherwise find it in the mean pattern: threshold at half the peak and
        // take the centroid and the area, which is steadier than tracing an
        // edge on noisy data.
        guard let mean = meanPattern(host: host) else { return nil }
        let peak = mean.max() ?? 0
        guard peak > 0 else { return nil }
        let threshold = peak * 0.5

        var sumX = 0.0, sumY = 0.0, weight = 0.0
        for y in 0..<height {
            for x in 0..<width where mean[y * width + x] >= threshold {
                sumX += Double(x); sumY += Double(y); weight += 1
            }
        }
        guard weight > 4 else { return nil }
        let radius = (weight / Double.pi).squareRoot()
        return Disc(centerX: Float(sumX / weight), centerY: Float(sumY / weight),
                    radius: Float(radius), source: "mean pattern")
    }

    /// Mean diffraction pattern over a subsample of the scan — enough to find
    /// the disc without reading the whole dataset.
    private func meanPattern(host: FDSHostContext) -> [Float]? {
        let pixels = host.patternPixelCount
        guard pixels > 0 else { return nil }
        var accumulator = [Float](repeating: 0, count: pixels)
        var buffer = [Float](repeating: 0, count: pixels)
        let stride = max(1, min(host.scanWidth, host.scanHeight) / 8)
        var used = 0

        for row in Swift.stride(from: 0, to: host.scanHeight, by: stride) {
            for column in Swift.stride(from: 0, to: host.scanWidth, by: stride) {
                let copied = buffer.withUnsafeMutableBufferPointer { pointer -> Bool in
                    guard let base = pointer.baseAddress else { return false }
                    return host.copyPattern(row: row, column: column, into: base, capacity: pixels)
                }
                guard copied else { continue }
                vDSP_vadd(accumulator, 1, buffer, 1, &accumulator, 1, vDSP_Length(pixels))
                used += 1
            }
        }
        guard used > 0 else { return nil }
        var scale = Float(1) / Float(used)
        vDSP_vsmul(accumulator, 1, &scale, &accumulator, 1, vDSP_Length(pixels))
        return accumulator
    }

    // MARK: - Stack

    private enum StackOutcome {
        case success(ACBFStack, [Double], [Double])
        case failure(String)
        case cancelled
    }

    /// Sweeps the 4D data once, forming every virtual image, then transforms
    /// each one. This is the only pass over the full dataset; everything after
    /// it works on the transforms.
    private func buildStack(host: FDSHostContext, disc: Disc, binning: Int,
                            optics: ACBFOptics) -> StackOutcome {

        let patternWidth = host.patternWidth, patternHeight = host.patternHeight
        let scanWidth = host.scanWidth, scanHeight = host.scanHeight
        let patternPixels = host.patternPixelCount

        // Group disc pixels into square blocks `binning` across.
        var groupOf = [Int](repeating: -1, count: patternPixels)
        var groupIndex: [Int: Int] = [:]
        var sumX: [Double] = [], sumY: [Double] = [], counts: [Double] = []
        let radiusSquared = Double(disc.radius) * Double(disc.radius)

        for y in 0..<patternHeight {
            for x in 0..<patternWidth {
                let dx = Double(x) - Double(disc.centerX)
                let dy = Double(y) - Double(disc.centerY)
                guard dx * dx + dy * dy <= radiusSquared else { continue }
                // Block index, biased so both coordinates are non-negative before
                // being packed. A shift-and-xor of signed offsets aliases blocks
                // either side of the centre onto each other.
                let blockY = Int(floor(dy / Double(binning))) + 32768
                let blockX = Int(floor(dx / Double(binning))) + 32768
                let block = blockY &* 65536 &+ blockX
                let group: Int
                if let existing = groupIndex[block] {
                    group = existing
                } else {
                    group = sumX.count
                    groupIndex[block] = group
                    sumX.append(0); sumY.append(0); counts.append(0)
                }
                groupOf[y * patternWidth + x] = group
                sumX[group] += dx; sumY[group] += dy; counts[group] += 1
            }
        }

        let groups = sumX.count
        guard groups > 0 else { return .failure("The bright-field disc has no pixels in it — check the disc position and radius.") }

        // Pad the scan to lengths the transform accepts.
        let rows = ACBFFFT.supportedLength(atLeast: scanHeight)
        let columns = ACBFFFT.supportedLength(atLeast: scanWidth)
        let paddedPixels = rows * columns

        // Two float arrays of groups × padded pixels have to fit in memory, and
        // silently thrashing is worse than saying so.
        let bytes = Double(groups) * Double(paddedPixels) * 8
        let budget = 4.0 * 1024 * 1024 * 1024
        if bytes > budget {
            let suggestion = binning * Int((bytes / budget).squareRoot().rounded(.up))
            return .failure(String(format: "This would need %.1f GB for %d virtual images at %d×%d. Raise the detector binning to about %d.",
                                   bytes / 1e9, groups, columns, rows, Swift.max(binning + 1, suggestion)))
        }

        var images = [Float](repeating: 0, count: groups * paddedPixels)
        var pattern = [Float](repeating: 0, count: patternPixels)

        for row in 0..<scanHeight {
            if host.isCancelled { return .cancelled }
            for column in 0..<scanWidth {
                let copied = pattern.withUnsafeMutableBufferPointer { pointer -> Bool in
                    guard let base = pointer.baseAddress else { return false }
                    return host.copyPattern(row: row, column: column, into: base, capacity: patternPixels)
                }
                guard copied else { continue }
                let destination = row * columns + column
                for p in 0..<patternPixels {
                    let group = groupOf[p]
                    if group >= 0 { images[group * paddedPixels + destination] += pattern[p] }
                }
            }
            host.reportProgress(0.6 * Double(row + 1) / Double(scanHeight))
        }

        // Transform each virtual image once.
        guard let fft = ACBFFFT(rows: rows, columns: columns) else {
            return .failure("No transform is available for a \(columns)×\(rows) scan.")
        }
        var real = images
        var imaginary = [Float](repeating: 0, count: groups * paddedPixels)
        var scratchReal = [Float](repeating: 0, count: paddedPixels)
        var scratchImaginary = [Float](repeating: 0, count: paddedPixels)

        for group in 0..<groups {
            if host.isCancelled { return .cancelled }
            let base = group * paddedPixels
            for i in 0..<paddedPixels { scratchReal[i] = real[base + i]; scratchImaginary[i] = 0 }
            fft.transform(real: &scratchReal, imaginary: &scratchImaginary, inverse: false)
            for i in 0..<paddedPixels { real[base + i] = scratchReal[i]; imaginary[base + i] = scratchImaginary[i] }
            host.reportProgress(0.6 + 0.4 * Double(group + 1) / Double(groups))
        }

        // Detector coordinate of each group, in Å⁻¹.
        var detectorX = [Double](repeating: 0, count: groups)
        var detectorY = [Double](repeating: 0, count: groups)
        for g in 0..<groups {
            detectorX[g] = sumX[g] / counts[g] * optics.dk
            detectorY[g] = sumY[g] / counts[g] * optics.dk
        }

        let stack = ACBFStack(count: groups, rows: rows, columns: columns,
                              scanRows: scanHeight, scanColumns: scanWidth,
                              real: real, imaginary: imaginary,
                              tiltX: detectorX, tiltY: detectorY)
        return .success(stack, detectorX, detectorY)
    }
}
