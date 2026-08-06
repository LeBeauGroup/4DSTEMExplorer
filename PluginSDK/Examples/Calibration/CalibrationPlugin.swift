//
//  CalibrationPlugin.swift
//  4DSTEM Explorer — Calibration
//
//  Calibrates against a lattice you already know the dimensions of.
//
//  Three things can be measured, all from the same observation — where the
//  lattice peaks are — and differing only in what those peaks mean:
//
//    * the real-space pixel size, from the periodicity of a computed image;
//    * the diffraction pixel size, from the spacing of Bragg spots in a pattern;
//    * the affine transform of the scan, from how the measured lattice geometry
//      differs from the geometry it is known to have.
//
//  The third is the reason the first two are not enough. A raster is not
//  necessarily square or orthogonal — the scan coils have their own gain and
//  cross-talk — so a single number cannot describe the mapping from pixels to
//  ångström. Measuring two lattice vectors instead of one length gives the whole
//  2×2 matrix, and separates the scale from the distortion that would otherwise
//  be silently folded into it.
//
//  Nothing here is a published method; it is the standard construction, and the
//  arithmetic that is easy to get wrong lives in LatticeFit.swift where it is
//  checked against lattices with known distortions planted in them.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Accelerate

@objc(CalibrationPlugin)
public final class CalibrationPlugin: NSObject, FDSPlugin {

    public override init() { super.init() }

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

    // MARK: Cache
    //
    // The window re-runs on every control change, and the transform is by far
    // the most expensive step while being independent of everything the user is
    // adjusting. Keyed on the source rather than recomputed, dragging the
    // exclusion radius costs only a peak search.

    private struct SpectrumKey: Equatable {
        var fileName: String
        var rows: Int
        var columns: Int
        var padFactor: Int
        var window: String
        var checksum: Double
    }
    private var cachedKey: SpectrumKey?
    private var cachedSpectrum: PowerSpectrum.Result?

    /// Cheap enough to run every time, and specific enough that a recomputed
    /// image is not mistaken for the previous one.
    private static func checksum(_ image: [Float]) -> Double {
        var total = 0.0
        let step = Swift.max(1, image.count / 512)
        var index = 0
        while index < image.count {
            total += Double(image[index]) * Double(index % 97 + 1)
            index += step
        }
        return total
    }

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
            // one you hunt for by dragging. They are validated in `run`.
            FDSParameter.number("d1", label: "Known spacing 1 (Å)", defaultValue: 3.905,
                                help: "The lattice spacing along the first direction. The default is the SrTiO₃ cubic cell."),
            FDSParameter.number("d2", label: "Known spacing 2 (Å)", defaultValue: 3.905,
                                help: "The spacing along the second direction. Equal to the first for a cubic cell viewed down an axis."),
            FDSParameter.number("latticeAngle", label: "Angle between them (°)", defaultValue: 90,
                                help: "90° for a square or rectangular net, 120° for a hexagonal one."),

            FDSParameter.choice("window", label: "Window",
                                choices: ["Hann", "Light taper (Tukey)", "None"],
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
        let d1 = (parameters["d1"] as? NSNumber)?.doubleValue ?? 3.905
        let d2 = (parameters["d2"] as? NSNumber)?.doubleValue ?? 3.905
        let latticeAngle = (parameters["latticeAngle"] as? NSNumber)?.doubleValue ?? 90
        let padFactor = max(1, (parameters["padFactor"] as? NSNumber)?.intValue ?? 2)
        let excludeRadius = (parameters["excludeRadius"] as? NSNumber)?.doubleValue ?? 6
        let peakCount = max(2, (parameters["peakCount"] as? NSNumber)?.intValue ?? 24)
        let minimumAngle = (parameters["minimumAngle"] as? NSNumber)?.doubleValue ?? 20
        let peakThreshold = (parameters["peakThreshold"] as? NSNumber)?.doubleValue ?? 0.02
        let window = CalibrationPlugin.window(named: parameters["window"] as? String)

        // The lattice fields are free text, so check them here rather than
        // relying on a control to have constrained them.
        guard d1 > 0, d2 > 0, d1.isFinite, d2.isFinite else {
            return FDSResult.failure("The known spacings must be positive. Enter them in ångström.")
        }
        guard latticeAngle > 0, latticeAngle < 180, latticeAngle.isFinite else {
            return FDSResult.failure("The angle between the lattice vectors must be between 0 and 180 degrees.")
        }

        let known = KnownLattice(d1: d1, d2: d2, angleDegrees: latticeAngle)
        let isDiffraction = source == CalibrationPlugin.diffractionSource

        // 1. The image to measure.
        let image: [Float]
        let rows: Int, columns: Int
        if isDiffraction {
            guard let data = host.currentPatternData else {
                return FDSResult.failure("No diffraction pattern is displayed. Select a probe position first.")
            }
            image = FDSFloatArray(data)
            rows = host.patternHeight
            columns = host.patternWidth
        } else {
            guard let data = host.currentScanImageData else {
                return FDSResult.failure("No computed image is available. Compute one with a detector first, then run this.")
            }
            image = FDSFloatArray(data)
            rows = host.scanHeight
            columns = host.scanWidth
        }
        guard image.count >= rows * columns, rows > 8, columns > 8 else {
            return FDSResult.failure("The selected image is too small to find a lattice in.")
        }
        if host.isCancelled { return nil }

        // 2. Locate the lattice.
        //
        // A diffraction pattern is already reciprocal space, so its peaks are
        // measured directly. A real-space image has to be transformed first.
        let measurement: Measurement
        if isDiffraction {
            guard let found = measureDiffraction(image: image, rows: rows, columns: columns,
                                                 excludeRadius: excludeRadius, peakCount: peakCount,
                                                 minimumAngle: minimumAngle,
                                                 threshold: peakThreshold) else {
                return FDSResult.failure("Could not find two independent Bragg reflections. Check that the pattern shows a lattice, and try widening the peak search.")
            }
            measurement = found
        } else {
            guard let found = measureRealSpace(image: image, rows: rows, columns: columns,
                                               padFactor: padFactor, excludeRadius: excludeRadius,
                                               peakCount: peakCount, minimumAngle: minimumAngle,
                                               threshold: peakThreshold,
                                               fileName: host.fileName,
                                               window: window) else {
                return FDSResult.failure("Could not find a lattice in the computed image. Check that it shows resolved periodicity, and try a larger transform padding.")
            }
            measurement = found
        }
        host.reportProgress(0.6)
        if host.isCancelled { return nil }

        // 3. What maps the measured lattice onto the known one.
        //
        // For a real-space image both bases are real-space, in Å. For a
        // diffraction pattern both are reciprocal, in Å⁻¹ — the known reciprocal
        // basis being the inverse transpose of the real one.
        let target: Matrix2
        if isDiffraction {
            guard let reciprocal = known.basis.inverse?.transposed else {
                return FDSResult.failure("The known lattice is degenerate — check the spacings and angle.")
            }
            target = reciprocal
        } else {
            target = known.basis
        }

        guard let fit = bestFit(measured: measurement.basis, target: target, known: known,
                                isDiffraction: isDiffraction),
              let decomposition = CalibrationDecomposition(transform: fit.transform) else {
            return FDSResult.failure("The measured lattice could not be matched to the known one. Check the spacings and the angle between them.")
        }
        host.reportProgress(0.85)

        // 4. Report.
        switch output {
        case "Detected lattice":
            return detectedLatticeResult(measurement: measurement, host: host,
                                         isDiffraction: isDiffraction,
                                         decomposition: decomposition,
                                         excludeRadius: excludeRadius)
        case "Corrected image":
            guard !isDiffraction else {
                return FDSResult.failure("Correcting a diffraction pattern is not offered — the distortion measured there belongs to the detector, and correcting one pattern would not change the data. Use the report.")
            }
            return correctedImageResult(image: image, rows: rows, columns: columns,
                                        decomposition: decomposition, host: host)
        case "Calibration report":
            return reportResult(measurement: measurement, decomposition: decomposition,
                                known: known, swapped: fit.swapped,
                                isDiffraction: isDiffraction, host: host)
        default:
            return detectedLatticeResult(measurement: measurement, host: host,
                                         isDiffraction: isDiffraction,
                                         decomposition: decomposition,
                                         excludeRadius: excludeRadius)
        }
    }

    // MARK: - Measuring

    private struct Measurement {
        /// Measured basis, as columns. Real-space pixels for an image source,
        /// reciprocal pixels for a pattern.
        let basis: Matrix2
        /// The peaks used, for the overlay.
        let first: LatticePeak
        let second: LatticePeak
        /// Everything found, for the overlay.
        let peaks: [LatticePeak]
        /// The image the peaks were found in, and where its origin sits.
        let field: [Float]
        let fieldRows: Int
        let fieldColumns: Int
        let origin: (x: Double, y: Double)
        /// Reciprocal vectors in cycles per source pixel — real-space source only.
        let reciprocal: Matrix2?
        /// The two vectors in pixels of `field`, for drawing. For a diffraction
        /// pattern this is the same as `basis`; for a power spectrum it is the
        /// reciprocal basis, which is what that field actually shows.
        let basisInField: Matrix2
    }

    private func measureRealSpace(image: [Float], rows: Int, columns: Int, padFactor: Int,
                                  excludeRadius: Double, peakCount: Int,
                                  minimumAngle: Double, threshold: Double,
                                  fileName: String,
                                  window: PowerSpectrum.Window) -> Measurement? {

        // The window belongs in the key: it changes the spectrum, so leaving it
        // out would make the control appear to do nothing.
        let key = SpectrumKey(fileName: fileName, rows: rows, columns: columns,
                              padFactor: padFactor,
                              window: String(describing: window),
                              checksum: CalibrationPlugin.checksum(image))
        let spectrum: PowerSpectrum.Result
        if key == cachedKey, let cached = cachedSpectrum {
            spectrum = cached
        } else {
            guard let made = PowerSpectrum.make(image: image, rows: rows, columns: columns,
                                                padFactor: padFactor,
                                                window: window) else { return nil }
            spectrum = made
            cachedSpectrum = made
            cachedKey = key
        }
        let peaks = LatticeFit.findPeaks(image: spectrum.flattened, rows: spectrum.rows,
                                         columns: spectrum.columns, centre: spectrum.centre,
                                         minimumRadius: excludeRadius, maximumRadius: 0,
                                         count: peakCount, relativeThreshold: threshold,
                                         locateIn: spectrum.values)
        guard var (inPixels, first, second) = LatticeFit.primitiveVectors(from: peaks,
                                                                          minimumAngle: minimumAngle)
        else { return nil }
        // Re-fit to every peak the lattice explains, rather than resting the
        // calibration on the two it was chosen from.
        if let refined = LatticeFit.refineBasis(inPixels, peaks: peaks) { inPixels = refined }

        // Spectrum pixels to cycles per source pixel.
        let G = Matrix2(columns: (inPixels.a * spectrum.frequencyStepX,
                                  inPixels.b * spectrum.frequencyStepY),
                        (inPixels.c * spectrum.frequencyStepX,
                         inPixels.d * spectrum.frequencyStepY))
        guard let realBasis = LatticeFit.realSpaceBasis(fromReciprocal: G) else { return nil }

        return Measurement(basis: realBasis, first: first, second: second, peaks: peaks,
                           field: spectrum.flattened, fieldRows: spectrum.rows,
                           fieldColumns: spectrum.columns, origin: spectrum.centre,
                           reciprocal: G, basisInField: inPixels)
    }

    private func measureDiffraction(image: [Float], rows: Int, columns: Int,
                                    excludeRadius: Double, peakCount: Int,
                                    minimumAngle: Double, threshold: Double) -> Measurement? {

        // The undiffracted beam is the origin everything is measured from, and
        // is the brightest thing in the pattern by a wide margin.
        var brightest = 0
        for i in 0..<(rows * columns) where image[i] > image[brightest] { brightest = i }
        let centre = (x: Double(brightest % columns), y: Double(brightest / columns))

        let peaks = LatticeFit.findPeaks(image: image, rows: rows, columns: columns,
                                         centre: centre, minimumRadius: excludeRadius,
                                         maximumRadius: 0, count: peakCount,
                                         relativeThreshold: threshold)
        guard var (basis, first, second) = LatticeFit.primitiveVectors(from: peaks,
                                                                       minimumAngle: minimumAngle)
        else { return nil }
        if let refined = LatticeFit.refineBasis(basis, peaks: peaks) { basis = refined }

        return Measurement(basis: basis, first: first, second: second, peaks: peaks,
                           field: image, fieldRows: rows, fieldColumns: columns,
                           origin: centre, reciprocal: nil, basisInField: basis)
    }

    /// Tries both pairings of measured to known vectors and keeps the better.
    private func bestFit(measured: Matrix2, target: Matrix2, known: KnownLattice,
                         isDiffraction: Bool) -> (transform: Matrix2, swapped: Bool)? {

        let alternate: Matrix2
        if isDiffraction {
            let swappedReal = KnownLattice(d1: known.d2, d2: known.d1,
                                           angleDegrees: known.angleDegrees).basis
            guard let reciprocal = swappedReal.inverse?.transposed else { return nil }
            alternate = reciprocal
        } else {
            alternate = KnownLattice(d1: known.d2, d2: known.d1,
                                     angleDegrees: known.angleDegrees).basis
        }

        var best: (Matrix2, Bool, Double)?
        for (candidate, swapped) in [(target, false), (alternate, true)] {
            guard let T = LatticeFit.transform(measured: measured, known: candidate),
                  let decomposition = CalibrationDecomposition(transform: T) else { continue }
            let cost = abs(decomposition.anisotropy) + abs(decomposition.shearDegrees) / 90
            if best == nil || cost < best!.2 { best = (T, swapped, cost) }
        }
        guard let chosen = best else { return nil }
        return (chosen.0, chosen.1)
    }

    // MARK: - Outputs

    private func reportResult(measurement: Measurement, decomposition: CalibrationDecomposition,
                              known: KnownLattice, swapped: Bool, isDiffraction: Bool,
                              host: FDSHostContext) -> [String: Any] {

        let unit = isDiffraction ? "Å⁻¹" : "Å"
        var report = "Calibration\n\n"
        report += "File              \(host.fileName)\n"
        report += "Measured from     \(isDiffraction ? "the diffraction pattern" : "the computed image")\n"
        report += String(format: "Known lattice     %.4f Å × %.4f Å at %.2f°\n",
                         known.d1, known.d2, known.angleDegrees)
        if swapped {
            report += "                  (matched with the two spacings exchanged)\n"
        }
        report += "\n"

        let a1 = measurement.basis.firstColumn
        let a2 = measurement.basis.secondColumn
        report += "Measured lattice, in pixels\n"
        report += String(format: "  vector 1        (%+8.3f, %+8.3f)   length %8.3f px\n",
                         a1.x, a1.y, vectorLength(a1))
        report += String(format: "  vector 2        (%+8.3f, %+8.3f)   length %8.3f px\n",
                         a2.x, a2.y, vectorLength(a2))
        report += String(format: "  angle           %.3f°\n\n", abs(angleBetween(a1, a2)))

        report += "Calibration\n"
        report += String(format: "  pixel size      %.6g %@ per pixel  (geometric mean)\n",
                         decomposition.meanPixelSize, unit)
        report += String(format: "  along principal %.6g and %.6g %@/px\n",
                         decomposition.principalPixelSizes.0,
                         decomposition.principalPixelSizes.1, unit)
        report += String(format: "  principal axis  %.2f° from +x\n", decomposition.principalAxisDegrees)

        if isDiffraction {
            // Å⁻¹ per pixel becomes an angle per pixel once the wavelength is known.
            let kilovolts = host.accelerationKilovolts
            if kilovolts > 0 {
                let wavelength = CalibrationPlugin.wavelength(kilovolts: kilovolts)
                let milliradians = decomposition.meanPixelSize * wavelength * 1000
                report += String(format: "  angular size    %.6g mrad per pixel  (at %.0f kV, λ = %.5f Å)\n",
                                 milliradians, kilovolts, wavelength)
            } else {
                report += "  angular size    unavailable — the file records no accelerating voltage\n"
            }
        } else {
            report += String(format: "  in nanometres   %.6g nm per pixel\n",
                             decomposition.meanPixelSize / 10)
        }
        report += "\n"

        report += "Affine transform A, pixels → \(unit) (columns are the images of x̂ and ŷ)\n"
        report += String(format: "  [ %+12.6g  %+12.6g ]\n", decomposition.transform.a, decomposition.transform.c)
        report += String(format: "  [ %+12.6g  %+12.6g ]\n\n", decomposition.transform.b, decomposition.transform.d)

        report += "Factored as A = R · D\n\n"

        report += String(format: "  R, rotation by %.4f°\n", decomposition.rotationDegrees)
        report += String(format: "    [ %+9.6f  %+9.6f ]\n", decomposition.rotation.a, decomposition.rotation.c)
        report += String(format: "    [ %+9.6f  %+9.6f ]\n\n", decomposition.rotation.b, decomposition.rotation.d)

        report += "  D, distortion (symmetric, carries the scale)\n"
        report += String(format: "    [ %+12.6g  %+12.6g ]\n", decomposition.distortion.a, decomposition.distortion.c)
        report += String(format: "    [ %+12.6g  %+12.6g ]\n\n", decomposition.distortion.b, decomposition.distortion.d)

        report += "  D with the scale divided out (unit determinant)\n"
        report += String(format: "    [ %+9.6f  %+9.6f ]\n", decomposition.correction.a, decomposition.correction.c)
        report += String(format: "    [ %+9.6f  %+9.6f ]\n", decomposition.correction.b, decomposition.correction.d)
        report += String(format: "  anisotropy      %+.4f   (0 when the two axes have equal scale)\n",
                         decomposition.anisotropy)
        report += String(format: "  shear           %+.4f°  (0 when the axes are perpendicular)\n",
                         decomposition.shearDegrees)
        report += String(format: "  rotation        %+.4f°\n\n", decomposition.rotationDegrees)

        report += "Reading this\n"
        report += "  The pixel size is the number to enter in Calibrate. Anisotropy and\n"
        report += "  shear describe how far the raster departs from square and orthogonal;\n"
        report += "  both are zero for an undistorted scan, and a single pixel size is only\n"
        report += "  the whole story when they are.\n\n"
        report += "  R and D are independent: R is a choice of reference frame, which a\n"
        report += "  scan-rotation setting undoes and which harms nothing; D is a property\n"
        report += "  of the instrument, and is what actually corrupts a measurement. D is\n"
        report += "  unchanged by any rotation of the frame, so the two can be read apart.\n\n"
        report += "  The rotation is the rotation of the fitted map, not the microscope's\n"
        report += "  scan rotation. When the raster is sheared the two differ, because the\n"
        report += "  decomposition attributes part of an asymmetric shear to rotation.\n\n"
        report += "  Only the relative geometry of the lattice is observable, so the\n"
        report += "  absolute orientation is arbitrary: the fit places the first known\n"
        report += "  vector along +x. For a lattice with n-fold symmetry the rotation is\n"
        report += "  therefore only determined modulo 360/n degrees — a square net fitted\n"
        report += "  to an undistorted image may report 0°, 90°, 180° or 270° with equal\n"
        report += "  justification. The pixel size, anisotropy and shear do not share this\n"
        report += "  ambiguity.\n"

        return offer(FDSResult.text(report, title: "Calibration — \(host.fileName)"),
                     decomposition: decomposition, isDiffraction: isDiffraction, host: host)
    }

    /// The field the peaks were found in, with the lattice drawn over it in red.
    ///
    /// Rendered in colour rather than as a grayscale image with bright pixels
    /// poked into it: a marker made by raising the value is indistinguishable
    /// from a real peak, which is precisely the thing the picture exists to let
    /// you judge. Red sits on top of the data instead of joining it.
    private func detectedLatticeResult(measurement: Measurement, host: FDSHostContext,
                                       isDiffraction: Bool,
                                       decomposition: CalibrationDecomposition,
                                       excludeRadius: Double) -> [String: Any] {

        let rows = measurement.fieldRows, columns = measurement.fieldColumns

        // A power spectrum spans many orders of magnitude, so it is shown
        // logarithmically; without that only the origin is visible.
        var display = [Float](repeating: 0, count: measurement.field.count)
        if isDiffraction {
            display = measurement.field
        } else {
            var maximum: Float = 0
            vDSP_maxv(measurement.field, 1, &maximum, vDSP_Length(measurement.field.count))
            let floor = max(maximum, 1) * 1e-8
            for i in 0..<measurement.field.count {
                display[i] = log(max(measurement.field[i], floor))
            }
        }

        var minimum: Float = 0, maximum: Float = 0
        vDSP_minv(display, 1, &minimum, vDSP_Length(display.count))
        vDSP_maxv(display, 1, &maximum, vDSP_Length(display.count))
        let span = max(maximum - minimum, .leastNormalMagnitude)

        var rgba = [UInt8](repeating: 255, count: rows * columns * 4)
        for i in 0..<(rows * columns) {
            let level = UInt8(max(0, min(255, ((display[i] - minimum) / span) * 255)))
            rgba[i * 4] = level
            rgba[i * 4 + 1] = level
            rgba[i * 4 + 2] = level
        }

        let red: (UInt8, UInt8, UInt8) = (255, 48, 48)
        let dimRed: (UInt8, UInt8, UInt8) = (190, 40, 40)

        func plot(_ x: Int, _ y: Int, _ colour: (UInt8, UInt8, UInt8)) {
            guard x >= 0, x < columns, y >= 0, y < rows else { return }
            let i = (y * columns + x) * 4
            rgba[i] = colour.0; rgba[i + 1] = colour.1; rgba[i + 2] = colour.2
        }
        func cross(at point: (x: Double, y: Double), size: Int, colour: (UInt8, UInt8, UInt8)) {
            let cx = Int(point.x.rounded()), cy = Int(point.y.rounded())
            for offset in -size...size where abs(offset) > 1 {
                plot(cx + offset, cy, colour)
                plot(cx, cy + offset, colour)
            }
        }
        func circle(centre: (x: Double, y: Double), radius: Double, colour: (UInt8, UInt8, UInt8)) {
            guard radius >= 1 else { return }
            let steps = max(64, Int(radius * 8))
            for step in 0..<steps {
                let angle = 2 * Double.pi * Double(step) / Double(steps)
                plot(Int((centre.x + radius * cos(angle)).rounded()),
                     Int((centre.y + radius * sin(angle)).rounded()), colour)
            }
        }

        let origin = measurement.origin

        // The exclusion zone, so its effect is visible while it is being set.
        circle(centre: origin, radius: excludeRadius, colour: dimRed)

        // The lattice the two vectors generate, marked out over the whole field.
        // Predicted points landing on observed peaks is the confirmation that
        // the fit describes the pattern and not just two of its spots.
        let a1 = measurement.basisInField.firstColumn
        let a2 = measurement.basisInField.secondColumn
        let reach = Int(Double(max(rows, columns)) / max(1.0, min(vectorLength(a1), vectorLength(a2)))) + 2
        for m in -reach...reach {
            for n in -reach...reach where !(m == 0 && n == 0) {
                let x = origin.x + Double(m) * a1.x + Double(n) * a2.x
                let y = origin.y + Double(m) * a1.y + Double(n) * a2.y
                guard x >= 0, x < Double(columns), y >= 0, y < Double(rows) else { continue }
                // The two primitive vectors and their negatives get a full
                // cross; the rest of the lattice a single point.
                let isPrimitive = (abs(m) == 1 && n == 0) || (m == 0 && abs(n) == 1)
                if isPrimitive {
                    cross(at: (x, y), size: 6, colour: red)
                } else {
                    plot(Int(x.rounded()), Int(y.rounded()), dimRed)
                }
            }
        }

        let unit = isDiffraction ? "Å⁻¹" : "Å"
        let message = String(format: "%.6g %@/px · anisotropy %+.4f · shear %+.3f° · vectors %.2f and %.2f px at %.2f° · %d peaks",
                             decomposition.meanPixelSize, unit,
                             decomposition.anisotropy, decomposition.shearDegrees,
                             vectorLength(measurement.basis.firstColumn),
                             vectorLength(measurement.basis.secondColumn),
                             abs(angleBetween(measurement.basis.firstColumn,
                                              measurement.basis.secondColumn)),
                             measurement.peaks.count)

        let base = FDSResult.pattern(display, rows: rows, columns: columns,
                                       title: isDiffraction
                                          ? "Detected reflections — \(host.fileName)"
                                          : "Detected lattice — \(host.fileName)",
                                     message: message)
        return offer(FDSResult.withColor(base, rgba: rgba),
                     decomposition: decomposition, isDiffraction: isDiffraction, host: host)
    }

    /// Attaches the measured calibration so the host can offer to apply it.
    ///
    /// A real-space measurement calibrates the scan step; a diffraction one
    /// calibrates the detector, and becomes an angle per pixel only once the
    /// wavelength is known. Nothing else is offered: the affine distortion has
    /// nowhere to go in the application's calibration yet, and quietly folding
    /// it into a single pixel size would misreport a raster that is not square.
    private func offer(_ result: [String: Any], decomposition: CalibrationDecomposition,
                       isDiffraction: Bool, host: FDSHostContext) -> [String: Any] {

        let distorted = abs(decomposition.anisotropy) > 0.02 || abs(decomposition.shearDegrees) > 1.0
        let caveat = distorted
            ? String(format: " The raster is not square: anisotropy %+.3f, shear %+.2f°, which a single pixel size cannot express.",
                     decomposition.anisotropy, decomposition.shearDegrees)
            : ""

        if isDiffraction {
            let kilovolts = host.accelerationKilovolts
            guard kilovolts > 0 else { return result }
            let wavelength = CalibrationPlugin.wavelength(kilovolts: kilovolts)
            let milliradians = decomposition.meanPixelSize * wavelength * 1000
            return FDSResult.withCalibration(
                result,
                diffractionStepMilliradians: milliradians,
                summary: String(format: "Measured from the diffraction pattern: %.5g mrad per detector pixel (%.6g Å⁻¹/px at %.0f kV).%@",
                                milliradians, decomposition.meanPixelSize, kilovolts, caveat))
        }

        let nanometres = decomposition.meanPixelSize / 10
        return FDSResult.withCalibration(
            result,
            scanStepNanometers: nanometres,
            summary: String(format: "Measured from the computed image: %.6g nm per probe position (%.5g Å/px).%@",
                            nanometres, decomposition.meanPixelSize, caveat))
    }

    /// The computed image resampled so the fitted distortion is undone.
    private func correctedImageResult(image: [Float], rows: Int, columns: Int,
                                      decomposition: CalibrationDecomposition,
                                      host: FDSHostContext) -> [String: Any] {

        // Only D's shape is undone — not R, and not the scale. R is a frame
        // choice whose absolute value was never observable, and rescaling would
        // resample for no benefit. Using `correction` rather than the full
        // transform is what keeps the rotation out of it.
        guard let inverse = decomposition.correction.inverse else {
            return FDSResult.failure("The fitted distortion is singular and cannot be undone.")
        }

        var out = [Float](repeating: 0, count: rows * columns)
        let cx = Double(columns - 1) / 2, cy = Double(rows - 1) / 2

        for y in 0..<rows {
            for x in 0..<columns {
                // Where this output pixel comes from in the input.
                let corrected = (x: Double(x) - cx, y: Double(y) - cy)
                let sourcePoint = inverse.apply(corrected)
                let sx = sourcePoint.x + cx
                let sy = sourcePoint.y + cy

                let x0 = Int(floor(sx)), y0 = Int(floor(sy))
                guard x0 >= 0, x0 + 1 < columns, y0 >= 0, y0 + 1 < rows else { continue }
                let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))

                let v00 = image[y0 * columns + x0]
                let v10 = image[y0 * columns + x0 + 1]
                let v01 = image[(y0 + 1) * columns + x0]
                let v11 = image[(y0 + 1) * columns + x0 + 1]
                out[y * columns + x] = (1 - fy) * ((1 - fx) * v00 + fx * v10)
                                     + fy * ((1 - fx) * v01 + fx * v11)
            }
        }

        let message = String(format: "Distortion undone: anisotropy %+.4f, shear %+.4f°. Scale and orientation left as they were.",
                             decomposition.anisotropy, decomposition.shearDegrees)
        return offer(FDSResult.scanImage(out, rows: rows, columns: columns,
                                         title: "Distortion-corrected — \(host.fileName)",
                                         message: message),
                     decomposition: decomposition, isDiffraction: false, host: host)
    }

    // MARK: - Physics

    /// A half-width Tukey, not a narrower one. Measured against synthetic
    /// lattices, a 25% taper leaves near-sidelobes strong enough to be mistaken
    /// for first-order peaks; 50% does not, and is still sharper than Hann.
    static func window(named name: String?) -> PowerSpectrum.Window {
        switch name {
        case "None": return .none
        case "Light taper (Tukey)": return .tukey(fraction: 0.5)
        default: return .hann
        }
    }

    /// Relativistic electron wavelength in ångström.
    static func wavelength(kilovolts: Double) -> Double {
        let volts = kilovolts * 1000
        return 12.2639 / (volts + 0.97845e-6 * volts * volts).squareRoot()
    }
}
