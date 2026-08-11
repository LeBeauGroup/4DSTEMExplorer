//
//  CalibrationMeasurement.swift
//  4DSTEM Explorer — Calibration
//
//  Calibrating against a lattice of known dimensions, with no dependency on how
//  the caller obtained the image or what it intends to do with the answer.
//
//  This file is compiled into both the application and the example plugin. That
//  is the point of it: the measurement is the same measurement wherever it is
//  invoked from, and a second copy of nine hundred lines of arithmetic would
//  start drifting from the first the day it was made. What differs between the
//  two callers is only how parameters arrive and how results are displayed, and
//  that is all their wrappers contain.
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

// MARK: - Settings

/// What to measure, and how hard to look.
struct CalibrationSettings: Equatable {

    /// Whether the image is a diffraction pattern (already reciprocal space) or
    /// a computed image (which has to be transformed first).
    var isDiffraction: Bool = false

    /// Known spacings in ångström, and the angle between them in degrees.
    var d1: Double = 3.905
    var d2: Double = 3.905
    var latticeAngleDegrees: Double = 90

    var windowName: String = "Hann"
    var padFactor: Int = 2
    var excludeRadius: Double = 6
    var peakCount: Int = 60
    var peakThreshold: Double = 0.02
    var minimumAngle: Double = 20

    var knownLattice: KnownLattice {
        return KnownLattice(d1: d1, d2: d2, angleDegrees: latticeAngleDegrees)
    }

    var window: PowerSpectrum.Window {
        return CalibrationEngine.window(named: windowName)
    }

    /// The spacings and angle are free text wherever they are entered, so they
    /// are checked here rather than trusting a control to have constrained them.
    func validated() throws {
        guard d1 > 0, d2 > 0, d1.isFinite, d2.isFinite else {
            throw CalibrationError.badSpacings
        }
        guard latticeAngleDegrees > 0, latticeAngleDegrees < 180,
              latticeAngleDegrees.isFinite else {
            throw CalibrationError.badAngle
        }
    }
}

enum CalibrationError: LocalizedError, Equatable {
    case badSpacings
    case badAngle
    case imageTooSmall
    case noImage(isDiffraction: Bool)
    case noLattice(isDiffraction: Bool)
    case unmatched
    case singularDistortion
    case cannotCorrectDiffraction

    var errorDescription: String? {
        switch self {
        case .badSpacings:
            return "The known spacings must be positive. Enter them in ångström."
        case .badAngle:
            return "The angle between the lattice vectors must be between 0 and 180 degrees."
        case .imageTooSmall:
            return "The selected image is too small to find a lattice in."
        case .noImage(let isDiffraction):
            return isDiffraction
                ? "No diffraction pattern is displayed. Select a probe position first."
                : "No computed image is available. Compute one with a detector first, then measure."
        case .noLattice(let isDiffraction):
            return isDiffraction
                ? "Could not find two independent Bragg reflections. Check that the pattern shows a lattice, and try widening the peak search."
                : "Could not find a lattice in the computed image. Check that it shows resolved periodicity, and try a larger transform padding."
        case .unmatched:
            return "The measured lattice could not be matched to the known one. Check the spacings and the angle between them."
        case .singularDistortion:
            return "The fitted distortion is singular and cannot be undone."
        case .cannotCorrectDiffraction:
            return "Correcting a diffraction pattern is not offered — the distortion measured there belongs to the detector, and correcting one pattern would not change the data. Use the report."
        }
    }
}

// MARK: - Results

/// The peaks and the basis found in one image.
struct LatticeMeasurement {
    /// Measured basis, as columns. Real-space pixels for an image source,
    /// reciprocal pixels for a pattern.
    let basis: Matrix2
    /// The two peaks the basis was chosen from.
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

/// A completed calibration.
struct CalibrationResult {
    let measurement: LatticeMeasurement
    let decomposition: CalibrationDecomposition
    let known: KnownLattice
    /// True when the two known spacings had to be exchanged to fit.
    let swapped: Bool
    let isDiffraction: Bool

    /// `Å⁻¹` for a diffraction measurement, `Å` for a real-space one.
    var unit: String { return isDiffraction ? "Å⁻¹" : "Å" }

    /// True when a single pixel size cannot describe this raster.
    var isDistorted: Bool {
        return abs(decomposition.anisotropy) > 0.02 || abs(decomposition.shearDegrees) > 1.0
    }
}

/// The field the peaks were found in, and the lattice to draw over it.
struct CalibrationOverlay {
    /// Greyscale values, log-scaled for a power spectrum.
    let values: [Float]
    /// The markings, as geometry in pixels of `values` — keyed by `FDSShapeKey`
    /// so the host draws them the same way it draws a plugin's.
    let shapes: [[String: Any]]
    let rows: Int
    let columns: Int
    let message: String
}

/// What a measurement offers back to the application's calibration.
struct CalibrationOffer {
    var scanStepNanometres: Double?
    var diffractionStepMilliradians: Double?
    var scanCorrectionRowMajor: [Double]?
    var summary: String
}

// MARK: - Engine

final class CalibrationEngine {

    init() {}

    // MARK: Cache
    //
    // A live window re-runs on every control change, and the transform is by far
    // the most expensive step while being independent of everything the user is
    // adjusting. Keyed on the source rather than recomputed, dragging the
    // exclusion radius costs only a peak search.

    private struct SpectrumKey: Equatable {
        var identity: String
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
    static func checksum(_ image: [Float]) -> Double {
        var total = 0.0
        let step = Swift.max(1, image.count / 512)
        var index = 0
        while index < image.count {
            total += Double(image[index]) * Double(index % 97 + 1)
            index += step
        }
        return total
    }

    // MARK: Measuring

    /// Locates the lattice and matches it to the known one.
    ///
    /// - Parameter identity: something that changes when the image does — a file
    ///   name is enough, since the checksum catches a recomputation of the same
    ///   file. Only used to key the transform cache.
    func measure(image: [Float], rows: Int, columns: Int,
                 identity: String, settings: CalibrationSettings) throws -> CalibrationResult {

        try settings.validated()
        guard image.count >= rows * columns, rows > 8, columns > 8 else {
            throw CalibrationError.imageTooSmall
        }

        let known = settings.knownLattice
        let isDiffraction = settings.isDiffraction

        // 1. Locate the lattice.
        //
        // A diffraction pattern is already reciprocal space, so its peaks are
        // measured directly. A real-space image has to be transformed first.
        let measurement: LatticeMeasurement
        if isDiffraction {
            guard let found = measureDiffraction(image: image, rows: rows, columns: columns,
                                                 settings: settings) else {
                throw CalibrationError.noLattice(isDiffraction: true)
            }
            measurement = found
        } else {
            guard let found = measureRealSpace(image: image, rows: rows, columns: columns,
                                               identity: identity, settings: settings) else {
                throw CalibrationError.noLattice(isDiffraction: false)
            }
            measurement = found
        }

        // 2. What maps the measured lattice onto the known one.
        //
        // For a real-space image both bases are real-space, in Å. For a
        // diffraction pattern both are reciprocal, in Å⁻¹ — the known reciprocal
        // basis being the inverse transpose of the real one.
        let target: Matrix2
        if isDiffraction {
            guard let reciprocal = known.basis.inverse?.transposed else {
                throw CalibrationError.badSpacings
            }
            target = reciprocal
        } else {
            target = known.basis
        }

        // Lattice-aware: the fitted basis is only defined up to the lattice's own
        // symmetry, so the rotation is reduced into the fundamental domain before
        // it is reported. Without that, a square lattice reports a quarter turn
        // as readily as none.
        guard let fit = bestFit(measured: measurement.basis, target: target, known: known,
                                isDiffraction: isDiffraction),
              let decomposition = CalibrationDecomposition(transform: fit.transform,
                                                           lattice: known) else {
            throw CalibrationError.unmatched
        }

        return CalibrationResult(measurement: measurement, decomposition: decomposition,
                                 known: known, swapped: fit.swapped,
                                 isDiffraction: isDiffraction)
    }

    private func measureRealSpace(image: [Float], rows: Int, columns: Int,
                                  identity: String,
                                  settings: CalibrationSettings) -> LatticeMeasurement? {

        // The window belongs in the key: it changes the spectrum, so leaving it
        // out would make the control appear to do nothing.
        let key = SpectrumKey(identity: identity, rows: rows, columns: columns,
                              padFactor: settings.padFactor,
                              window: String(describing: settings.window),
                              checksum: CalibrationEngine.checksum(image))
        let spectrum: PowerSpectrum.Result
        if key == cachedKey, let cached = cachedSpectrum {
            spectrum = cached
        } else {
            guard let made = PowerSpectrum.make(image: image, rows: rows, columns: columns,
                                                padFactor: settings.padFactor,
                                                window: settings.window) else { return nil }
            spectrum = made
            cachedSpectrum = made
            cachedKey = key
        }
        let peaks = LatticeFit.findPeaks(image: spectrum.flattened, rows: spectrum.rows,
                                         columns: spectrum.columns, centre: spectrum.centre,
                                         minimumRadius: settings.excludeRadius, maximumRadius: 0,
                                         count: settings.peakCount,
                                         relativeThreshold: settings.peakThreshold,
                                         locateIn: spectrum.values)
        guard var (inPixels, first, second) = LatticeFit.primitiveVectors(from: peaks,
                                                                          minimumAngle: settings.minimumAngle)
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

        return LatticeMeasurement(basis: realBasis, first: first, second: second, peaks: peaks,
                                  field: spectrum.flattened, fieldRows: spectrum.rows,
                                  fieldColumns: spectrum.columns, origin: spectrum.centre,
                                  reciprocal: G, basisInField: inPixels)
    }

    private func measureDiffraction(image: [Float], rows: Int, columns: Int,
                                    settings: CalibrationSettings) -> LatticeMeasurement? {

        // The undiffracted beam is the origin everything is measured from, and
        // is the brightest thing in the pattern by a wide margin.
        var brightest = 0
        for i in 0..<(rows * columns) where image[i] > image[brightest] { brightest = i }
        let centre = (x: Double(brightest % columns), y: Double(brightest / columns))

        let peaks = LatticeFit.findPeaks(image: image, rows: rows, columns: columns,
                                         centre: centre, minimumRadius: settings.excludeRadius,
                                         maximumRadius: 0, count: settings.peakCount,
                                         relativeThreshold: settings.peakThreshold)
        guard var (basis, first, second) = LatticeFit.primitiveVectors(from: peaks,
                                                                       minimumAngle: settings.minimumAngle)
        else { return nil }
        if let refined = LatticeFit.refineBasis(basis, peaks: peaks) { basis = refined }

        return LatticeMeasurement(basis: basis, first: first, second: second, peaks: peaks,
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

    // MARK: What the application should adopt

    /// The calibration this measurement supports, or nil when it supports none.
    ///
    /// A real-space measurement calibrates the scan step; a diffraction one
    /// calibrates the detector, and becomes an angle per pixel only once the
    /// wavelength is known.
    ///
    /// From the decomposition `A = R·D`, the scale in D becomes the scan step and
    /// D's unit-determinant part becomes the scan correction. Splitting it this
    /// way is what lets a raster that is not square survive — a single pixel size
    /// silently misreports one.
    ///
    /// `R` is deliberately **not** offered as a scan rotation. It is the angle
    /// between the fitted lattice and the arbitrary frame this holds the known
    /// lattice in, so it describes how the crystal sits in the image, not how the
    /// scan sits relative to the detector. That it is defined only up to the
    /// lattice's own point group is the proof — a square net gives 0°, 90°, 180°
    /// and 270° with equal justification, and a quantity the crystal symmetry can
    /// rotate at will cannot be a property of the instrument. The scan rotation
    /// is the detector-to-scan angle, found by minimising the curl of the
    /// centre-of-mass field — a different measurement entirely.
    func offer(_ result: CalibrationResult, kilovolts: Double) -> CalibrationOffer? {

        let d = result.decomposition
        let caveat = result.isDistorted
            ? String(format: " The raster is not square: anisotropy %+.3f, shear %+.2f°, which a single pixel size cannot express.",
                     d.anisotropy, d.shearDegrees)
            : ""

        if result.isDiffraction {
            guard kilovolts > 0 else { return nil }
            let wavelength = CalibrationEngine.wavelength(kilovolts: kilovolts)
            let milliradians = d.meanPixelSize * wavelength * 1000
            return CalibrationOffer(
                diffractionStepMilliradians: milliradians,
                summary: String(format: "Measured from the diffraction pattern: %.5g mrad per detector pixel (%.6g Å⁻¹/px at %.0f kV).%@",
                                milliradians, d.meanPixelSize, kilovolts, caveat))
        }

        let nanometres = d.meanPixelSize / 10

        // `Matrix2` stores columns, so `apply` computes x' = a·x + c·y and
        // y' = b·x + d·y. Row-major — which is what the application and the
        // metadata format both want — is therefore [a, c, b, d], not the field
        // order.
        let D = d.correction
        return CalibrationOffer(
            scanStepNanometres: nanometres,
            scanCorrectionRowMajor: [D.a, D.c, D.b, D.d],
            summary: String(format: "Measured from the computed image: %.6g nm per probe position (%.5g Å/px).%@",
                            nanometres, d.meanPixelSize, caveat))
    }

    // MARK: Presentation

    /// The full written report.
    func report(_ result: CalibrationResult, fileName: String, kilovolts: Double) -> String {

        let d = result.decomposition
        let known = result.known
        let unit = result.unit

        var report = "Calibration\n\n"
        report += "File              \(fileName)\n"
        report += "Measured from     \(result.isDiffraction ? "the diffraction pattern" : "the computed image")\n"
        report += String(format: "Known lattice     %.4f Å × %.4f Å at %.2f°\n",
                         known.d1, known.d2, known.angleDegrees)
        if result.swapped {
            report += "                  (matched with the two spacings exchanged)\n"
        }
        report += "\n"

        let a1 = result.measurement.basis.firstColumn
        let a2 = result.measurement.basis.secondColumn
        report += "Measured lattice, in pixels\n"
        report += String(format: "  vector 1        (%+8.3f, %+8.3f)   length %8.3f px\n",
                         a1.x, a1.y, vectorLength(a1))
        report += String(format: "  vector 2        (%+8.3f, %+8.3f)   length %8.3f px\n",
                         a2.x, a2.y, vectorLength(a2))
        report += String(format: "  angle           %.3f°\n\n", abs(angleBetween(a1, a2)))

        report += "Calibration\n"
        report += String(format: "  pixel size      %.6g %@ per pixel  (geometric mean)\n",
                         d.meanPixelSize, unit)
        report += String(format: "  along principal %.6g and %.6g %@/px\n",
                         d.principalPixelSizes.0, d.principalPixelSizes.1, unit)
        report += String(format: "  principal axis  %.2f° from +x\n", d.principalAxisDegrees)

        if result.isDiffraction {
            // Å⁻¹ per pixel becomes an angle per pixel once the wavelength is known.
            if kilovolts > 0 {
                let wavelength = CalibrationEngine.wavelength(kilovolts: kilovolts)
                let milliradians = d.meanPixelSize * wavelength * 1000
                report += String(format: "  angular size    %.6g mrad per pixel  (at %.0f kV, λ = %.5f Å)\n",
                                 milliradians, kilovolts, wavelength)
            } else {
                report += "  angular size    unavailable — no accelerating voltage is set\n"
            }
        } else {
            report += String(format: "  in nanometres   %.6g nm per pixel\n", d.meanPixelSize / 10)
        }
        report += "\n"

        report += "Affine transform A, pixels → \(unit) (columns are the images of x̂ and ŷ)\n"
        report += String(format: "  [ %+12.6g  %+12.6g ]\n", d.transform.a, d.transform.c)
        report += String(format: "  [ %+12.6g  %+12.6g ]\n\n", d.transform.b, d.transform.d)

        report += "Factored as A = R · D\n\n"

        report += String(format: "  R, rotation by %.4f°\n", d.rotationDegrees)
        report += String(format: "    [ %+9.6f  %+9.6f ]\n", d.rotation.a, d.rotation.c)
        report += String(format: "    [ %+9.6f  %+9.6f ]\n\n", d.rotation.b, d.rotation.d)

        report += "  D, distortion (symmetric, carries the scale)\n"
        report += String(format: "    [ %+12.6g  %+12.6g ]\n", d.distortion.a, d.distortion.c)
        report += String(format: "    [ %+12.6g  %+12.6g ]\n\n", d.distortion.b, d.distortion.d)

        report += "  D with the scale divided out (unit determinant)\n"
        report += String(format: "    [ %+9.6f  %+9.6f ]\n", d.correction.a, d.correction.c)
        report += String(format: "    [ %+9.6f  %+9.6f ]\n", d.correction.b, d.correction.d)
        report += String(format: "  anisotropy      %+.4f   (0 when the two axes have equal scale)\n",
                         d.anisotropy)
        report += String(format: "  shear           %+.4f°  (0 when the axes are perpendicular)\n",
                         d.shearDegrees)
        report += String(format: "  rotation        %+.4f°\n\n", d.rotationDegrees)

        report += "Reading this\n"
        report += "  The pixel size is what Apply writes into the calibration. Anisotropy\n"
        report += "  and shear describe how far the raster departs from square and\n"
        report += "  orthogonal; both are zero for an undistorted scan, and a single pixel\n"
        report += "  size is only the whole story when they are.\n\n"
        report += "  R and D are independent: R is a choice of reference frame, which\n"
        report += "  harms nothing; D is a property of the instrument, and is what\n"
        report += "  actually corrupts a measurement. D is unchanged by any rotation of\n"
        report += "  the frame, so the two can be read apart. Only the pixel size and D\n"
        report += "  are applied.\n\n"
        report += "  R is NOT the microscope's scan rotation, and must not be used as one.\n"
        report += "  It is the angle between the fitted lattice and the arbitrary frame\n"
        report += "  the known lattice is held in, so it says how the crystal sits in the\n"
        report += "  image — a sample property, not an instrument one. The give-away is\n"
        report += "  that it is only determined modulo the lattice's own symmetry: a\n"
        report += "  square net fitted to an undistorted image may report 0°, 90°, 180°\n"
        report += "  or 270° with equal justification, and the value above is simply the\n"
        report += "  representative nearest zero. Nothing the crystal's point group can\n"
        report += "  rotate at will is a property of the scan.\n\n"
        report += "  The scan rotation is the angle between the scan axes and the\n"
        report += "  detector axes. It is measured by minimising the curl of the\n"
        report += "  centre-of-mass field over the whole 4D stack, needs no known\n"
        report += "  lattice, and is what the Scan rotation tab measures.\n\n"
        report += "  A sheared raster shifts R further still, because the decomposition\n"
        report += "  attributes part of an asymmetric shear to rotation. The pixel size,\n"
        report += "  anisotropy and shear are free of all of this.\n"

        return report
    }

    /// The field the peaks were found in, and the lattice to draw over it.
    ///
    /// Geometry, not pixels written into a copy of the data. Two reasons, and
    /// the second is the one that matters here. A marker made by raising a
    /// value is indistinguishable from a real peak — precisely the thing the
    /// picture exists to let you judge. And a marker one data pixel wide is a
    /// hairline in a zoomed-out view and a single hard block in a zoomed-in one,
    /// so the exclusion radius and the peak threshold, which are set by watching
    /// what they include, were being judged through a drawing that changed
    /// meaning with the zoom. Stroked geometry stays the same width at every
    /// magnification and sits at its true sub-pixel position.
    func overlay(_ result: CalibrationResult, excludeRadius: Double) -> CalibrationOverlay {

        let measurement = result.measurement
        let rows = measurement.fieldRows, columns = measurement.fieldColumns

        // A power spectrum spans many orders of magnitude, so it is shown
        // logarithmically; without that only the origin is visible.
        var display = [Float](repeating: 0, count: measurement.field.count)
        if result.isDiffraction {
            display = measurement.field
        } else {
            var maximum: Float = 0
            vDSP_maxv(measurement.field, 1, &maximum, vDSP_Length(measurement.field.count))
            let floor = max(maximum, 1) * 1e-8
            for i in 0..<measurement.field.count {
                display[i] = log(max(measurement.field[i], floor))
            }
        }

        // Direction 1 and direction 2 get different colours, because knowing
        // *which* vector is which is the difference between entering the two
        // known spacings the right way round and the wrong way round. The rest
        // of the lattice stays a dim single colour so the two stand out.
        let dim: FDSShape.Colour = (0.85, 0.25, 0.25, 0.75)

        var shapes: [[String: Any]] = []
        let origin = measurement.origin

        // The exclusion zone, so its effect is visible while it is being set.
        if excludeRadius >= 0.5 {
            shapes.append(FDSShape.circle(x: origin.x, y: origin.y, radius: excludeRadius,
                                          colour: dim, lineWidth: 1))
        }

        // The lattice the two vectors generate, marked out over the whole field.
        // Predicted points landing on observed peaks is the confirmation that
        // the fit describes the pattern and not just two of its spots.
        let a1 = measurement.basisInField.firstColumn
        let a2 = measurement.basisInField.secondColumn
        let shortest = max(1.0, min(vectorLength(a1), vectorLength(a2)))
        let reach = Int(Double(max(rows, columns)) / shortest) + 2

        // A ring per predicted site rather than a dot, because a dot on top of a
        // peak hides the peak it is claiming to have predicted. The ring is small
        // enough to read as a marker and open enough to see through.
        let siteRadius = max(1.5, min(4.0, shortest * 0.08))

        // A fine basis generates tens of thousands of sites, which is a wall of
        // ink rather than a check on the fit, and thousands of strokes on every
        // redraw of a view the user is dragging.
        //
        // Thinned to a sublattice rather than truncated. Stopping after so many
        // would mark the top of the field and leave the bottom bare — which
        // reads as the fit having failed down there. Every k-th site is still an
        // exact lattice site, so each ring still lands on a real peak, and the
        // markings still reach the corners: the far ones are the strongest test
        // of the basis, since a small error in a vector accumulates with order.
        let siteLimit = 2500
        let estimate = (2 * reach + 1) * (2 * reach + 1)
        let stride = estimate > siteLimit
            ? max(1, Int((Double(estimate) / Double(siteLimit)).squareRoot().rounded(.up)))
            : 1

        for m in Swift.stride(from: -reach, through: reach, by: stride) {
            for n in Swift.stride(from: -reach, through: reach, by: stride) where !(m == 0 && n == 0) {
                let x = origin.x + Double(m) * a1.x + Double(n) * a2.x
                let y = origin.y + Double(m) * a1.y + Double(n) * a2.y
                guard x >= 0, x < Double(columns), y >= 0, y < Double(rows) else { continue }
                // The primitive vectors are drawn separately below, in their own
                // colours; everything else is one dim ring.
                let isPrimitive = (abs(m) == 1 && n == 0) || (m == 0 && abs(n) == 1)
                if isPrimitive { continue }
                shapes.append(FDSShape.circle(x: x, y: y, radius: siteRadius,
                                              colour: dim, lineWidth: 0.75))
            }
        }

        // The two directions, appended last so they draw over everything else.
        //
        // Labelled by which *known* spacing each one matched, not by the order
        // they happened to be found in: `bestFit` will exchange the pairing when
        // that fits better, and a picture labelling the vector that matched d₂ as
        // "1" would send the user off to correct a lattice parameter that was
        // right all along.
        let directions: [(vector: (x: Double, y: Double), label: Int)] = result.swapped
            ? [(a1, 2), (a2, 1)]
            : [(a1, 1), (a2, 2)]

        for (vector, label) in directions {
            let colour = label == 1 ? FDSShape.red : FDSShape.amber
            let tip = (x: origin.x + vector.x, y: origin.y + vector.y)
            let opposite = (x: origin.x - vector.x, y: origin.y - vector.y)
            let arm = max(4.0, min(12.0, vectorLength(vector) * 0.25))
            shapes.append(FDSShape.line(x0: origin.x, y0: origin.y, x1: tip.x, y1: tip.y,
                                        colour: colour, lineWidth: 1.5))
            shapes.append(FDSShape.cross(x: tip.x, y: tip.y, radius: arm,
                                         colour: colour, lineWidth: 1.5))
            shapes.append(FDSShape.cross(x: opposite.x, y: opposite.y, radius: arm,
                                         colour: colour, lineWidth: 1.5))
            // Offset perpendicular to the vector so the label does not sit on
            // the peak it is naming. Real text at a fixed size on screen, which
            // is what makes "1" and "2" readable on a 128-pixel spectrum at all.
            let length = max(vectorLength(vector), 1)
            let offset = arm + 2
            shapes.append(FDSShape.label("\(label)",
                                         x: tip.x - vector.y / length * offset,
                                         y: tip.y + vector.x / length * offset,
                                         colour: colour, fontSize: 13))
        }

        let d = result.decomposition
        let message = String(format: "%.6g %@/px · anisotropy %+.4f · shear %+.3f° · direction 1 (red) %.2f px, direction 2 (amber) %.2f px, %.2f° apart · %d peaks",
                             d.meanPixelSize, result.unit,
                             d.anisotropy, d.shearDegrees,
                             vectorLength(measurement.basis.firstColumn),
                             vectorLength(measurement.basis.secondColumn),
                             abs(angleBetween(measurement.basis.firstColumn,
                                              measurement.basis.secondColumn)),
                             measurement.peaks.count)

        return CalibrationOverlay(values: display, shapes: shapes, rows: rows, columns: columns,
                                  message: message)
    }

    /// The computed image resampled so the fitted distortion is undone.
    func correctedImage(_ result: CalibrationResult, image: [Float],
                        rows: Int, columns: Int) throws -> [Float] {

        guard !result.isDiffraction else { throw CalibrationError.cannotCorrectDiffraction }

        // Only D's shape is undone — not R, and not the scale. R is a frame
        // choice whose absolute value was never observable, and rescaling would
        // resample for no benefit. Using `correction` rather than the full
        // transform is what keeps the rotation out of it.
        guard let inverse = result.decomposition.correction.inverse else {
            throw CalibrationError.singularDistortion
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
        return out
    }

    /// One line describing what the correction did, for the caller to display.
    static func correctionMessage(_ result: CalibrationResult) -> String {
        return String(format: "Distortion undone: anisotropy %+.4f, shear %+.4f°. Scale and orientation left as they were.",
                      result.decomposition.anisotropy, result.decomposition.shearDegrees)
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

    /// The names the window control offers, in order.
    static let windowNames = ["Hann", "Light taper (Tukey)", "None"]

    /// Relativistic electron wavelength in ångström.
    static func wavelength(kilovolts: Double) -> Double {
        let volts = kilovolts * 1000
        return 12.2639 / (volts + 0.97845e-6 * volts * volts).squareRoot()
    }
}
