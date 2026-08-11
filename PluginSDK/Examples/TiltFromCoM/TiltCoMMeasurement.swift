//
//  TiltCoMMeasurement.swift
//  4DSTEM Explorer — Sample Tilt (dark-field centre of mass)
//
//  Local specimen tilt from the centre of mass of an annular dark-field region
//  of each diffraction pattern.
//
//  A crystal sitting exactly on a zone axis scatters symmetrically: the
//  diffracted intensity outside the bright-field disc is balanced about the
//  optic axis, and its centre of mass sits on it. Tilt the crystal and the Laue
//  circle moves, the excitation errors on opposite sides of the zone axis stop
//  matching, and the dark-field intensity leans one way. The centre of mass of
//  the annulus leans with it, and how far it leans is the measurement.
//
//  This is a port of the TiltSolver `adf_com` method (fit_tilt.py), whose steps
//  are followed deliberately rather than improved on where the answer would
//  change. Two things are done differently, both noted at the point they occur:
//  the mask is evaluated analytically at the sub-pixel centre instead of being
//  built at an integer centre and interpolated onto one, and the scan binning is
//  accumulated as moments rather than by materialising binned patterns. The
//  second is exactly equivalent and the first is strictly more accurate.
//
//  What this is not: an absolute, calibration-free tilt. The lean of the
//  dark-field centre of mass depends on thickness, convergence angle, voltage
//  and which annulus is used, and the useful annulus was chosen in the original
//  work by testing against simulations. Treat the map as a quantitative measure
//  of *relative* tilt across the scan whose absolute scale has been calibrated
//  for a particular kind of specimen, and say so wherever a number leaves here.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Accelerate

// MARK: - Settings

struct TiltCoMSettings: Equatable {

    /// Annulus inner and outer radii, in milliradians.
    ///
    /// The inner edge sits outside the bright-field disc — a little over the
    /// convergence angle — so the unscattered beam contributes nothing. The
    /// outer edge is bounded by the detector.
    var innerMilliradians: Double = 30
    var outerMilliradians: Double = 40

    /// Scan positions per side of a binned measurement.
    ///
    /// Tilt is measured from where a whole pattern's intensity leans, which
    /// needs counts. Binning trades the scan sampling this measurement does not
    /// need for the signal it does.
    var rebin: Int = 8

    /// Milliradians beyond which a value is treated as a failure rather than a
    /// measurement, and set to zero.
    ///
    /// Zero, not clipped: a probe on vacuum, on an amorphous region or on a
    /// grain boundary produces a centre of mass that is not a tilt at all, and
    /// clipping it to the threshold would leave a large wrong value that looks
    /// like a real steep tilt. Zero at least reads as "nothing here". Set to 0
    /// to keep every value.
    var outlierThresholdMilliradians: Double = 6

    /// Gaussian blur applied to the binned tilt maps, in binned pixels.
    var smoothingSigma: Double = 0

    /// Manual offset of the assumed zero-tilt direction, in milliradians.
    ///
    /// The measurement is relative to wherever the unscattered beam sits, which
    /// is the specimen's mean orientation, not necessarily zero tilt. This
    /// shifts the origin when the mean orientation is known to be off.
    var offsetXMilliradians: Double = 0
    var offsetYMilliradians: Double = 0

    /// Resample the binned maps back onto the full scan grid.
    var upsampleToScanGrid: Bool = true

    func validated() throws {
        guard innerMilliradians >= 0, outerMilliradians > innerMilliradians,
              innerMilliradians.isFinite, outerMilliradians.isFinite else {
            throw TiltCoMError.badAnnulus
        }
        guard rebin >= 1 else { throw TiltCoMError.badRebin }
    }
}

enum TiltCoMError: LocalizedError, Equatable {
    case badAnnulus
    case badRebin
    case noDiffractionCalibration
    case scanTooSmall(rebin: Int)
    case annulusOffDetector(outerPixels: Double, halfWidth: Double)
    case emptyAnnulus

    var errorDescription: String? {
        switch self {
        case .badAnnulus:
            return "The outer angle must be larger than the inner one, and both must be finite."
        case .badRebin:
            return "The scan binning must be at least 1."
        case .noDiffractionCalibration:
            return "This needs the diffraction step in mrad per detector pixel. Measure it on the Diffraction Step tab of the calibration window, or set it by hand."
        case .scanTooSmall(let rebin):
            return "The scan is smaller than one \(rebin)×\(rebin) bin. Lower the binning."
        case .annulusOffDetector(let outer, let half):
            return String(format: "The annulus reaches %.1f px, past the %.1f px edge of the detector. Lower the outer angle.", outer, half)
        case .emptyAnnulus:
            return "The annulus contains no counts. Check the inner and outer angles against the pattern."
        }
    }
}

// MARK: - Result

struct TiltCoMResult {

    /// Tilt in milliradians on the binned grid, row-major.
    let tiltX: [Float]
    let tiltY: [Float]
    let rows: Int
    let columns: Int

    /// The same maps on the full scan grid, when asked for.
    let scanTiltX: [Float]
    let scanTiltY: [Float]
    let scanRows: Int
    let scanColumns: Int

    /// Where the unscattered beam was taken to be, in detector pixels.
    let centre: (x: Double, y: Double)
    /// The annulus, for display over the mean pattern.
    let mask: [Float]
    let meanPattern: [Float]
    let patternRows: Int
    let patternColumns: Int

    /// Fraction of binned positions rejected by the outlier threshold.
    let rejectedFraction: Double
    /// Largest magnitude that survived, in milliradians.
    let maximumMilliradians: Double
    /// Scan positions that went into each binned measurement.
    let positionsPerBin: Int

    /// Tilt magnitude, for a single map.
    var magnitude: [Float] {
        return zip(tiltX, tiltY).map { ($0 * $0 + $1 * $1).squareRoot() }
    }
}

// MARK: - Engine

/// Supplies one diffraction pattern into a caller-owned buffer.
typealias TiltPatternProvider = (_ row: Int, _ column: Int,
                                 _ buffer: UnsafeMutablePointer<Float>, _ capacity: Int) -> Bool

struct TiltCoMGeometry: Equatable {
    var scanWidth: Int
    var scanHeight: Int
    var patternWidth: Int
    var patternHeight: Int
    /// Milliradians per detector pixel.
    var diffractionStepMilliradians: Double
    var patternPixelCount: Int { return patternWidth * patternHeight }
}

final class TiltCoMEngine {

    init() {}

    // MARK: Cache
    //
    // The mean pattern needs a pass over the whole stack and depends on nothing
    // the user adjusts, so it is computed once. The annulus, the centre and
    // every derived map are cheap by comparison — but the moments are not, so
    // they are cached on what actually determines them.

    private struct MeanKey: Equatable {
        var identity: String
        var scanWidth: Int
        var scanHeight: Int
    }
    private var meanKey: MeanKey?
    private var meanPattern: [Float]?

    private struct MomentKey: Equatable {
        var identity: String
        var scanWidth: Int
        var scanHeight: Int
        var rebin: Int
        var inner: Double
        var outer: Double
        var centreX: Double
        var centreY: Double
    }
    private var momentKey: MomentKey?
    private var momentCache: (comX: [Double], comY: [Double], rows: Int, columns: Int)?

    func invalidate() {
        meanKey = nil; meanPattern = nil
        momentKey = nil; momentCache = nil
    }

    // MARK: The measurement

    func measure(geometry: TiltCoMGeometry,
                 settings: TiltCoMSettings,
                 identity: String,
                 provider: TiltPatternProvider,
                 progress: ((Double) -> Void)? = nil,
                 isCancelled: (() -> Bool)? = nil) throws -> TiltCoMResult {

        try settings.validated()
        let step = geometry.diffractionStepMilliradians
        guard step > 0, step.isFinite else { throw TiltCoMError.noDiffractionCalibration }

        let pixels = geometry.patternPixelCount
        guard pixels > 0, geometry.patternWidth > 2, geometry.patternHeight > 2 else {
            throw TiltCoMError.emptyAnnulus
        }

        let rebin = settings.rebin
        let binColumns = geometry.scanWidth / rebin
        let binRows = geometry.scanHeight / rebin
        guard binColumns >= 1, binRows >= 1 else { throw TiltCoMError.scanTooSmall(rebin: rebin) }

        // 1. The mean pattern, which locates the unscattered beam.
        let mean = try meanPattern(geometry: geometry, identity: identity,
                                   provider: provider, progress: progress,
                                   isCancelled: isCancelled)
        if isCancelled?() == true { throw CancellationError() }

        // 2. Where the beam sits, plus any offset the user asked for.
        var centre = TiltCoMEngine.beamCentre(mean, rows: geometry.patternHeight,
                                              columns: geometry.patternWidth)
        centre.x += settings.offsetXMilliradians / step
        centre.y += settings.offsetYMilliradians / step

        // 3. The annulus, in pixels.
        let innerPixels = settings.innerMilliradians / step
        let outerPixels = settings.outerMilliradians / step
        let halfWidth = Double(min(geometry.patternWidth, geometry.patternHeight)) / 2
        guard outerPixels <= halfWidth * 1.45 else {
            throw TiltCoMError.annulusOffDetector(outerPixels: outerPixels, halfWidth: halfWidth)
        }
        let mask = TiltCoMEngine.annulus(rows: geometry.patternHeight,
                                         columns: geometry.patternWidth,
                                         centre: centre,
                                         innerPixels: innerPixels, outerPixels: outerPixels)
        guard mask.contains(where: { $0 > 0.01 }) else { throw TiltCoMError.emptyAnnulus }

        // 4. The moments, binned over the scan.
        let moments = try self.moments(geometry: geometry, settings: settings,
                                       identity: identity, centre: centre, mask: mask,
                                       binRows: binRows, binColumns: binColumns,
                                       provider: provider, progress: progress,
                                       isCancelled: isCancelled)

        // 5. Pixels to milliradians, about the beam.
        var tiltX = [Float](repeating: 0, count: binRows * binColumns)
        var tiltY = tiltX
        var rejected = 0
        let threshold = settings.outlierThresholdMilliradians

        for i in 0..<(binRows * binColumns) {
            let x = (moments.comX[i] - centre.x) * step
            let y = (moments.comY[i] - centre.y) * step
            if !x.isFinite || !y.isFinite {
                rejected += 1
                continue
            }
            if threshold > 0, abs(x) > threshold || abs(y) > threshold {
                // Zeroed, not clipped — see the note on the setting.
                rejected += 1
                continue
            }
            tiltX[i] = Float(x)
            tiltY[i] = Float(y)
        }

        if settings.smoothingSigma > 0 {
            tiltX = TiltCoMEngine.blurred(tiltX, rows: binRows, columns: binColumns,
                                          sigma: settings.smoothingSigma)
            tiltY = TiltCoMEngine.blurred(tiltY, rows: binRows, columns: binColumns,
                                          sigma: settings.smoothingSigma)
        }

        var scanX = tiltX, scanY = tiltY
        var scanRows = binRows, scanColumns = binColumns
        if settings.upsampleToScanGrid, rebin > 1 {
            scanRows = geometry.scanHeight
            scanColumns = geometry.scanWidth
            scanX = TiltCoMEngine.resampled(tiltX, rows: binRows, columns: binColumns,
                                            toRows: scanRows, toColumns: scanColumns)
            scanY = TiltCoMEngine.resampled(tiltY, rows: binRows, columns: binColumns,
                                            toRows: scanRows, toColumns: scanColumns)
        }

        let magnitudes = zip(tiltX, tiltY).map { Double(($0 * $0 + $1 * $1).squareRoot()) }
        return TiltCoMResult(
            tiltX: tiltX, tiltY: tiltY, rows: binRows, columns: binColumns,
            scanTiltX: scanX, scanTiltY: scanY, scanRows: scanRows, scanColumns: scanColumns,
            centre: centre, mask: mask, meanPattern: mean,
            patternRows: geometry.patternHeight, patternColumns: geometry.patternWidth,
            rejectedFraction: Double(rejected) / Double(max(1, binRows * binColumns)),
            maximumMilliradians: magnitudes.max() ?? 0,
            positionsPerBin: rebin * rebin)
    }

    // MARK: Steps

    private func meanPattern(geometry: TiltCoMGeometry, identity: String,
                             provider: TiltPatternProvider,
                             progress: ((Double) -> Void)?,
                             isCancelled: (() -> Bool)?) throws -> [Float] {

        let key = MeanKey(identity: identity, scanWidth: geometry.scanWidth,
                          scanHeight: geometry.scanHeight)
        if key == meanKey, let cached = meanPattern { return cached }

        let pixels = geometry.patternPixelCount
        var total = [Float](repeating: 0, count: pixels)
        var pattern = [Float](repeating: 0, count: pixels)
        var counted = 0

        for row in 0..<geometry.scanHeight {
            if isCancelled?() == true { throw CancellationError() }
            if row % 8 == 0 {
                progress?(0.35 * Double(row) / Double(geometry.scanHeight))
            }
            for column in 0..<geometry.scanWidth {
                let ok = pattern.withUnsafeMutableBufferPointer {
                    provider(row, column, $0.baseAddress!, pixels)
                }
                guard ok else { continue }
                vDSP_vadd(total, 1, pattern, 1, &total, 1, vDSP_Length(pixels))
                counted += 1
            }
        }
        guard counted > 0 else { throw TiltCoMError.emptyAnnulus }
        var scale = Float(1) / Float(counted)
        vDSP_vsmul(total, 1, &scale, &total, 1, vDSP_Length(pixels))

        meanKey = key
        meanPattern = total
        return total
    }

    /// Masked first moments, accumulated per scan bin.
    ///
    /// The reference implementation bins the 4D data and then takes the centre
    /// of mass of each binned pattern. Accumulating `Σ M·I`, `Σ M·I·x` and
    /// `Σ M·I·y` over a bin's positions gives exactly the same ratio — the
    /// centre of mass of a sum is the sum of the moments over the sum of the
    /// weights — while never holding more than one pattern. On a large scan the
    /// difference is between a few kilobytes and the whole dataset again.
    private func moments(geometry: TiltCoMGeometry, settings: TiltCoMSettings,
                         identity: String, centre: (x: Double, y: Double), mask: [Float],
                         binRows: Int, binColumns: Int,
                         provider: TiltPatternProvider,
                         progress: ((Double) -> Void)?,
                         isCancelled: (() -> Bool)?)
        throws -> (comX: [Double], comY: [Double], rows: Int, columns: Int) {

        let key = MomentKey(identity: identity,
                            scanWidth: geometry.scanWidth, scanHeight: geometry.scanHeight,
                            rebin: settings.rebin,
                            inner: settings.innerMilliradians, outer: settings.outerMilliradians,
                            centreX: centre.x, centreY: centre.y)
        if key == momentKey, let cached = momentCache { return cached }

        let pixels = geometry.patternPixelCount
        let width = geometry.patternWidth

        // The mask, and the mask times each coordinate — so a pattern costs
        // three dot products rather than a pass with a branch in it.
        var maskX = [Float](repeating: 0, count: pixels)
        var maskY = [Float](repeating: 0, count: pixels)
        for i in 0..<pixels {
            maskX[i] = mask[i] * Float(i % width)
            maskY[i] = mask[i] * Float(i / width)
        }

        var sumI = [Double](repeating: 0, count: binRows * binColumns)
        var sumX = sumI, sumY = sumI
        var pattern = [Float](repeating: 0, count: pixels)

        let rebin = settings.rebin
        for row in 0..<(binRows * rebin) {
            if isCancelled?() == true { throw CancellationError() }
            if row % 8 == 0 {
                progress?(0.35 + 0.6 * Double(row) / Double(binRows * rebin))
            }
            let binRow = row / rebin
            for column in 0..<(binColumns * rebin) {
                let ok = pattern.withUnsafeMutableBufferPointer {
                    provider(row, column, $0.baseAddress!, pixels)
                }
                guard ok else { continue }

                var intensity: Float = 0, momentX: Float = 0, momentY: Float = 0
                vDSP_dotpr(pattern, 1, mask, 1, &intensity, vDSP_Length(pixels))
                vDSP_dotpr(pattern, 1, maskX, 1, &momentX, vDSP_Length(pixels))
                vDSP_dotpr(pattern, 1, maskY, 1, &momentY, vDSP_Length(pixels))

                let bin = binRow * binColumns + (column / rebin)
                sumI[bin] += Double(intensity)
                sumX[bin] += Double(momentX)
                sumY[bin] += Double(momentY)
            }
        }

        var comX = [Double](repeating: .nan, count: binRows * binColumns)
        var comY = comX
        for i in 0..<(binRows * binColumns) where sumI[i] != 0 {
            comX[i] = sumX[i] / sumI[i]
            comY[i] = sumY[i] / sumI[i]
        }

        let result = (comX: comX, comY: comY, rows: binRows, columns: binColumns)
        momentKey = key
        momentCache = result
        return result
    }

    // MARK: Pieces

    /// The unscattered beam, as the centroid of the bright part of the mean
    /// pattern.
    ///
    /// The reference finds it with a wrapped `fftfreq` ramp, which reads zero
    /// for a centred pattern and the offset for a nearly centred one, but turns
    /// over entirely once the beam is more than a quarter of the detector off
    /// centre. A plain centroid of everything above half height has no such
    /// horizon and needs no assumption about where the beam already is.
    static func beamCentre(_ pattern: [Float], rows: Int, columns: Int) -> (x: Double, y: Double) {
        let fallback = (x: Double(columns - 1) / 2, y: Double(rows - 1) / 2)
        guard pattern.count >= rows * columns, rows > 0, columns > 0 else { return fallback }

        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        for i in 0..<(rows * columns) where pattern[i].isFinite {
            minimum = Swift.min(minimum, pattern[i])
            maximum = Swift.max(maximum, pattern[i])
        }
        guard maximum > minimum else { return fallback }
        let half = (maximum + minimum) / 2

        var sum = 0.0, sumX = 0.0, sumY = 0.0
        for y in 0..<rows {
            for x in 0..<columns {
                let value = pattern[y * columns + x]
                guard value.isFinite, value > half else { continue }
                let weight = Double(value - minimum)
                sum += weight
                sumX += weight * Double(x)
                sumY += weight * Double(y)
            }
        }
        guard sum > 0 else { return fallback }
        return (x: sumX / sum, y: sumY / sum)
    }

    /// A soft-edged annulus.
    ///
    /// The edge profile is the reference's: a logistic of width 1/10 pixel,
    /// which is a hard edge with just enough softness to stop the mask jumping
    /// by a whole pixel of area as the radius is dragged. It is evaluated
    /// directly at the sub-pixel centre rather than built at an integer centre
    /// and interpolated onto the real one, which is the same mask without the
    /// interpolation blur.
    static func annulus(rows: Int, columns: Int, centre: (x: Double, y: Double),
                        innerPixels: Double, outerPixels: Double) -> [Float] {
        var mask = [Float](repeating: 0, count: rows * columns)
        for y in 0..<rows {
            let dy = Double(y) - centre.y
            for x in 0..<columns {
                let dx = Double(x) - centre.x
                let r = (dx * dx + dy * dy).squareRoot()
                let outside = 1 / (1 + exp(10 * (r - outerPixels)))
                let inside = 1 / (1 + exp(10 * (r - innerPixels)))
                mask[y * columns + x] = Float(Swift.max(0, outside - inside))
            }
        }
        return mask
    }

    /// Separable Gaussian blur, edges clamped.
    static func blurred(_ values: [Float], rows: Int, columns: Int, sigma: Double) -> [Float] {
        guard sigma > 0, rows > 0, columns > 0, values.count >= rows * columns else { return values }
        let radius = Swift.max(1, Int((3 * sigma).rounded()))
        var kernel = [Double](repeating: 0, count: 2 * radius + 1)
        var total = 0.0
        for offset in -radius...radius {
            let weight = exp(-Double(offset * offset) / (2 * sigma * sigma))
            kernel[offset + radius] = weight
            total += weight
        }
        for i in kernel.indices { kernel[i] /= total }

        var horizontal = [Float](repeating: 0, count: rows * columns)
        for y in 0..<rows {
            for x in 0..<columns {
                var sum = 0.0
                for offset in -radius...radius {
                    let source = Swift.min(columns - 1, Swift.max(0, x + offset))
                    sum += Double(values[y * columns + source]) * kernel[offset + radius]
                }
                horizontal[y * columns + x] = Float(sum)
            }
        }
        var output = [Float](repeating: 0, count: rows * columns)
        for y in 0..<rows {
            for x in 0..<columns {
                var sum = 0.0
                for offset in -radius...radius {
                    let source = Swift.min(rows - 1, Swift.max(0, y + offset))
                    sum += Double(horizontal[source * columns + x]) * kernel[offset + radius]
                }
                output[y * columns + x] = Float(sum)
            }
        }
        return output
    }

    /// Bilinear resample onto another grid.
    ///
    /// The reference uses a quadratic spline. Bilinear is used here because a
    /// spline overshoots at a step, and the steps in a tilt map are grain
    /// boundaries and specimen edges — the places where an invented value either
    /// side of the edge is least welcome.
    static func resampled(_ values: [Float], rows: Int, columns: Int,
                          toRows: Int, toColumns: Int) -> [Float] {
        guard rows > 0, columns > 0, toRows > 0, toColumns > 0,
              values.count >= rows * columns else { return values }
        if rows == toRows && columns == toColumns { return values }

        var output = [Float](repeating: 0, count: toRows * toColumns)
        // Cell centres map to cell centres, so the binned value sits in the
        // middle of the block it came from rather than at its corner.
        let scaleY = Double(rows) / Double(toRows)
        let scaleX = Double(columns) / Double(toColumns)

        for y in 0..<toRows {
            let sy = Swift.min(Double(rows) - 1, Swift.max(0, (Double(y) + 0.5) * scaleY - 0.5))
            let y0 = Int(sy), y1 = Swift.min(rows - 1, y0 + 1)
            let fy = Float(sy - Double(y0))
            for x in 0..<toColumns {
                let sx = Swift.min(Double(columns) - 1, Swift.max(0, (Double(x) + 0.5) * scaleX - 0.5))
                let x0 = Int(sx), x1 = Swift.min(columns - 1, x0 + 1)
                let fx = Float(sx - Double(x0))

                let v00 = values[y0 * columns + x0], v10 = values[y0 * columns + x1]
                let v01 = values[y1 * columns + x0], v11 = values[y1 * columns + x1]
                output[y * toColumns + x] = (1 - fy) * ((1 - fx) * v00 + fx * v10)
                                          + fy * ((1 - fx) * v01 + fx * v11)
            }
        }
        return output
    }
}
