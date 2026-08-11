//
//  ScanRotationMeasurement.swift
//  4DSTEM Explorer — Scan Rotation
//
//  Turning a 4D stack into a centre-of-mass field, and the answer into something
//  readable, with no dependency on where the patterns come from.
//
//  Compiled into both the application and the example plugin, so the measurement
//  is the same measurement wherever it is invoked from. The caller supplies
//  patterns through a closure; whether they arrive from a data controller or
//  across a plugin boundary is not this file's business.
//
//  The arithmetic is in CurlMinimisation.swift, where it is checked against
//  fields with rotations planted in them.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Accelerate

/// What to measure over, and how much to smooth it first.
struct ScanRotationSettings: Equatable {
    /// Nil measures over the whole pattern.
    var detectorIndex: Int? = nil
    /// Gaussian blur in probe positions, applied before differentiating.
    var smoothing: Double = 0
    /// Probe positions to drop from every edge of the scan.
    var edgeTrim: Int = 0
}

enum ScanRotationError: LocalizedError {
    case scanTooSmall
    case noSignal
    case uniformField

    var errorDescription: String? {
        switch self {
        case .scanTooSmall:
            return "The scan is too small to measure a rotation from — the curl needs a derivative in both directions."
        case .noSignal:
            return "The centre of mass could not be computed. Every pattern appears to be empty."
        case .uniformField:
            return "The centre-of-mass field is uniform — there is no structure to determine an angle from. Check that a specimen is in the scan."
        }
    }
}

/// Supplies one diffraction pattern into a caller-owned buffer.
/// Returns false when the coordinates are out of range.
typealias PatternProvider = (_ row: Int, _ column: Int,
                             _ buffer: UnsafeMutablePointer<Float>, _ capacity: Int) -> Bool

/// The geometry of the stack being measured.
struct ScanRotationGeometry: Equatable {
    var scanWidth: Int
    var scanHeight: Int
    var patternWidth: Int
    var patternHeight: Int
    var patternPixelCount: Int { return patternWidth * patternHeight }
}

final class ScanRotationEngine {

    init() {}

    // MARK: Cache
    //
    // Computing the centre of mass touches every pixel of the dataset, while
    // everything the user can adjust afterwards — trimming, smoothing, which
    // output to show — costs nothing. Caching the field on what actually
    // determines it is what makes a control respond at all.

    private struct FieldKey: Equatable {
        var identity: String
        var scanWidth: Int
        var scanHeight: Int
        var detectorIndex: Int?
    }
    private var cachedKey: FieldKey?
    private var cachedField: CoMField?

    /// Discards the cached centre-of-mass field.
    func invalidate() {
        cachedKey = nil
        cachedField = nil
    }

    /// The first moment of every pattern, relative to the detector centre.
    ///
    /// The origin the moments are measured from cancels out of every derivative,
    /// so it cannot affect the answer; the centre of the detector is used anyway
    /// so that the numbers reported alongside are physically meaningful.
    ///
    /// - Parameters:
    ///   - mask: 1 inside the detector, 0 outside, `patternPixelCount` long. Nil
    ///     measures over the whole pattern. A wrong-sized mask is ignored rather
    ///     than treated as an error — a missing mask is a reason to measure over
    ///     everything, not a reason to measure nothing.
    ///   - identity: something that changes when the data does, to key the cache.
    func centreOfMassField(geometry: ScanRotationGeometry,
                           mask: [Float]?,
                           identity: String,
                           detectorIndex: Int?,
                           provider: PatternProvider,
                           progress: ((Double) -> Void)? = nil,
                           isCancelled: (() -> Bool)? = nil) -> CoMField? {

        let key = FieldKey(identity: identity,
                           scanWidth: geometry.scanWidth, scanHeight: geometry.scanHeight,
                           detectorIndex: detectorIndex)
        if key == cachedKey, let cached = cachedField { return cached }

        let width = geometry.patternWidth, height = geometry.patternHeight
        let pixels = geometry.patternPixelCount
        guard pixels > 0, width > 0, height > 0 else { return nil }

        let usableMask = (mask?.count == pixels) ? mask : nil

        // Coordinate ramps, so each moment is one vDSP dot product.
        var xRamp = [Float](repeating: 0, count: pixels)
        var yRamp = [Float](repeating: 0, count: pixels)
        let centreX = Float(width - 1) / 2, centreY = Float(height - 1) / 2
        for row in 0..<height {
            for column in 0..<width {
                xRamp[row * width + column] = Float(column) - centreX
                yRamp[row * width + column] = Float(row) - centreY
            }
        }
        if let usableMask = usableMask {
            vDSP_vmul(xRamp, 1, usableMask, 1, &xRamp, 1, vDSP_Length(pixels))
            vDSP_vmul(yRamp, 1, usableMask, 1, &yRamp, 1, vDSP_Length(pixels))
        }

        let rows = geometry.scanHeight, columns = geometry.scanWidth
        var comX = [Double](repeating: 0, count: rows * columns)
        var comY = [Double](repeating: 0, count: rows * columns)

        var pattern = [Float](repeating: 0, count: pixels)
        var masked = [Float](repeating: 0, count: pixels)
        var anySignal = false

        for row in 0..<rows {
            if isCancelled?() == true { return nil }
            if row % 8 == 0 { progress?(0.85 * Double(row) / Double(rows)) }

            for column in 0..<columns {
                let ok = pattern.withUnsafeMutableBufferPointer {
                    provider(row, column, $0.baseAddress!, pixels)
                }
                guard ok else { continue }

                var total: Float = 0
                if let usableMask = usableMask {
                    vDSP_vmul(pattern, 1, usableMask, 1, &masked, 1, vDSP_Length(pixels))
                    vDSP_sve(masked, 1, &total, vDSP_Length(pixels))
                } else {
                    vDSP_sve(pattern, 1, &total, vDSP_Length(pixels))
                }
                // A pattern with no counts has no centre of mass. Leaving it at
                // zero is the honest choice — it is where the unscattered beam
                // would be, so it contributes no spurious field.
                guard total > 0 else { continue }
                anySignal = true

                var momentX: Float = 0, momentY: Float = 0
                vDSP_dotpr(pattern, 1, xRamp, 1, &momentX, vDSP_Length(pixels))
                vDSP_dotpr(pattern, 1, yRamp, 1, &momentY, vDSP_Length(pixels))

                let index = row * columns + column
                comX[index] = Double(momentX / total)
                comY[index] = Double(momentY / total)
            }
        }
        guard anySignal else { return nil }

        let field = CoMField(x: comX, y: comY, rows: rows, columns: columns)
        cachedKey = key
        cachedField = field
        return field
    }

    /// The measured field after trimming and smoothing, and the solution.
    func solve(_ measured: CoMField,
               settings: ScanRotationSettings) throws -> (field: CoMField, solution: ScanRotationSolution) {
        var field = CurlMinimisation.trimmed(measured, by: settings.edgeTrim)
        field = CurlMinimisation.smoothed(field, sigma: settings.smoothing)
        guard let solution = CurlMinimisation.solve(field) else {
            throw ScanRotationError.uniformField
        }
        return (field, solution)
    }

    // MARK: What the application should adopt

    /// The rotation this measurement supports, and the orientation change it
    /// implies, or nil when the minimum is too shallow to mean anything.
    ///
    /// A rotation read off a curve with no trough in it is not a measurement, and
    /// offering it invites the user to write noise into a metadata file.
    ///
    /// A reflection cannot be absorbed into an angle, so when one is needed it is
    /// offered as an orientation change — composed with the orientation the
    /// patterns were actually read with, not asserted from nothing, since the
    /// measurement sees the data after those flips.
    func offer(_ solution: ScanRotationSolution,
               currentFlips: [Bool]) -> (rotationDegrees: Double, flips: [Bool]?, summary: String)? {

        guard solution.contrast >= 0.05 else { return nil }

        var summary = String(format: "Scan rotation %+.3f°, from minimising the centre-of-mass curl (minimum depth %.3f, %@).",
                             solution.rotationDegrees, solution.contrast,
                             ScanRotationEngine.verdict(solution.contrast) as NSString)

        var flips: [Bool]? = nil
        if solution.transposed {
            let base = currentFlips.count == 3 ? currentFlips : [false, false, false]
            flips = [base[0], base[1], !base[2]]
            summary += String(format: " The detector is mirrored with respect to the scan, so the transpose is offered too (det_flips %@ → %@).",
                              ScanRotationEngine.describe(base) as NSString,
                              ScanRotationEngine.describe(flips!) as NSString)
        }
        if solution.halfTurnUncertain {
            summary += " The half-turn is unresolved; if the atomic columns are dark in the divergence map, add 180°."
        }
        return (solution.rotationDegrees, flips, summary)
    }

    // MARK: Presentation

    /// `[flip_y, flip_x, transpose]` in words.
    static func describe(_ flips: [Bool]) -> String {
        guard flips.count == 3 else { return "unknown" }
        var parts: [String] = []
        if flips[0] { parts.append("flip y") }
        if flips[1] { parts.append("flip x") }
        if flips[2] { parts.append("transpose") }
        return parts.isEmpty ? "none" : parts.joined(separator: " + ")
    }

    static func verdict(_ contrast: Double) -> String {
        switch contrast {
        case ..<0.05:  return "no information — do not use"
        case ..<0.2:   return "weak — treat with suspicion"
        case ..<0.5:   return "usable"
        case ..<0.8:   return "good"
        default:       return "sharp"
        }
    }

    func report(_ solution: ScanRotationSolution, field: CoMField, fileName: String,
                detectorName: String, settings: ScanRotationSettings,
                currentFlips: [Bool]) -> String {

        var report = "Scan rotation — \(fileName)\n\n"

        report += String(format: "  scan rotation     %+.3f°\n", solution.rotationDegrees)
        report += String(format: "  detector mirrored %@\n", solution.transposed ? "yes" : "no")
        report += String(format: "  minimum depth     %.4f  (%@)\n", solution.contrast,
                         ScanRotationEngine.verdict(solution.contrast) as NSString)
        report += String(format: "  residual curl     %.4g  (worst %.4g)\n",
                         solution.residualCurl, solution.worstCurl)
        report += String(format: "  divergence        %.4g rms, skew %.3f\n\n",
                         solution.divergence, solution.divergenceSkewness)

        report += "Measured over\n"
        report += String(format: "  %d × %d probe positions, %@\n",
                         field.columns, field.rows, detectorName as NSString)
        if settings.edgeTrim > 0 {
            report += String(format: "  %d positions trimmed from each edge\n", settings.edgeTrim)
        }
        if settings.smoothing > 0 {
            report += String(format: "  smoothed with σ = %.2g positions\n", settings.smoothing)
        }
        report += "\n"

        if solution.transposed {
            let base = currentFlips.count == 3 ? currentFlips : [false, false, false]
            report += "⚠︎ The detector is mirrored with respect to the scan.\n"
            report += "  A reflection is not a rotation, so the angle above does not\n"
            report += "  describe the relationship on its own — the two detector axes\n"
            report += "  must also be exchanged. That is the transpose flag in EMPAD\n"
            report += "  metadata's det_flips, and it is offered along with the angle:\n"
            report += String(format: "    %@  →  %@\n",
                             ScanRotationEngine.describe(base) as NSString,
                             ScanRotationEngine.describe([base[0], base[1], !base[2]]) as NSString)
            report += "  Applying records the new orientation. It does not re-read the\n"
            report += "  file, so the patterns on screen keep the orientation they were\n"
            report += "  loaded with until you reopen with the transpose set.\n\n"
            report += "  Which reflection it is cannot be determined here. Any mirror\n"
            report += "  equals a transpose followed by some rotation, so a transpose\n"
            report += "  plus the angle above is a complete description of what was\n"
            report += "  measured — it is not necessarily how the camera is bolted on.\n\n"
        }
        if solution.halfTurnUncertain {
            report += "⚠︎ The half-turn is not resolved.\n"
            report += String(format: "  The divergence skew is only %.3f, so θ and θ+180° fit this data\n",
                             solution.divergenceSkewness)
            report += "  about equally well. Both null the curl; they differ in the sign of\n"
            report += "  the divergence, which should be positive at the atomic columns.\n"
            report += "  Check the divergence map — if the columns come out dark, add 180°.\n\n"
        }
        if solution.contrast < 0.2 {
            report += "⚠︎ The minimum is shallow, and the angle above may be meaningless.\n"
            report += "  Restrict the centre of mass to the bright-field disc, raise the\n"
            report += "  smoothing, or use a scan with more contrast. Look at the curl\n"
            report += "  versus angle curve: a real measurement has an obvious trough.\n\n"
        }

        report += "Reading this\n"
        report += "  The centre of mass of each pattern is the mean momentum given to\n"
        report += "  the beam, which for a thin specimen follows the projected electric\n"
        report += "  field. That field is a gradient, so it has no curl. Any curl in the\n"
        report += "  measured field is an artefact of measuring the vectors in detector\n"
        report += "  coordinates while differentiating against scan coordinates, and the\n"
        report += "  angle that removes it is the angle between the two frames.\n\n"
        report += "  This is a property of the instrument, not the specimen. It does not\n"
        report += "  depend on knowing a lattice, and a lattice cannot supply it: the\n"
        report += "  rotation the lattice calibration reports is the crystal's orientation\n"
        report += "  in the image, ambiguous up to the crystal's own symmetry.\n\n"
        report += "  The minimum depth is 1 − residual/worst. Near 1 the angle is sharply\n"
        report += "  determined. Near 0 the curl barely changes with angle, which means\n"
        report += "  the data has no orientation information and the number above is\n"
        report += "  noise, however precisely it is printed.\n"

        return report
    }

    /// The divergence or curl of the corrected field, as an image.
    ///
    /// These are the two halves of the same check. At the right angle the
    /// divergence should show the atomic columns — it is the projected charge
    /// density — and the curl should show nothing but noise. If the curl has
    /// structure in it, the fit has not explained the field.
    func map(_ field: CoMField, solution: ScanRotationSolution,
             wantCurl: Bool) -> (values: [Float], rows: Int, columns: Int, message: String) {

        let radians = solution.rotationDegrees * .pi / 180
        let c = cos(radians), s = sin(radians)
        let source = solution.transposed
            ? CoMField(x: field.y, y: field.x, rows: field.rows, columns: field.columns)
            : field

        // Rotate the vectors, then differentiate — the same order the solution
        // was derived in.
        var x = [Double](repeating: 0, count: source.x.count)
        var y = x
        for index in source.x.indices {
            x[index] = source.x[index] * c - source.y[index] * s
            y[index] = source.x[index] * s + source.y[index] * c
        }

        let rows = source.rows, columns = source.columns
        var image = [Float](repeating: 0, count: rows * columns)
        for row in 1..<(rows - 1) {
            for column in 1..<(columns - 1) {
                let index = row * columns + column
                let dXdx = (x[index + 1] - x[index - 1]) / 2
                let dXdy = (x[index + columns] - x[index - columns]) / 2
                let dYdx = (y[index + 1] - y[index - 1]) / 2
                let dYdy = (y[index + columns] - y[index - columns]) / 2
                image[index] = Float(wantCurl ? (dXdy - dYdx) : (dXdx + dYdy))
            }
        }

        let message = wantCurl
            ? String(format: "Curl of the corrected field, RMS %.4g. This should look like noise; structure here means the fit has not explained the field.", solution.residualCurl)
            : String(format: "Divergence of the corrected field, RMS %.4g. This is proportional to the projected charge density, so the atomic columns should be bright. If they are dark, add 180° to the rotation.", solution.divergence)

        return (image, rows, columns, message)
    }
}
