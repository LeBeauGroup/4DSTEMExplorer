//
//  ACBFReconstructor.swift
//  4DSTEM Explorer — Aberration-Corrected Bright Field
//
//  Turns a stack of bright-field virtual images into a reconstruction.
//
//  The whole design rests on one observation: the inverse transform is linear,
//  so
//
//      Σ_b IFFT( Î_b · W_b )  =  IFFT( Σ_b Î_b · W_b )
//
//  Every reconstruction here — tcBF, phase-only acBF, complex-inversion acBF —
//  is of that form, differing only in the weight W_b. So each virtual image is
//  transformed once when the stack is built, every reconstruction is an
//  accumulation in Fourier space, and exactly one inverse transform happens at
//  the end regardless of how many virtual detectors there are.
//
//  That matters twice over: it removes thousands of transforms from the inner
//  loop, and it leaves the loop purely elementwise, which is what makes the
//  Metal path in ACBFMetal.swift a straight port.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Accelerate

// MARK: - Transforms

/// A 2D complex FFT built from vDSP's DFT, which accepts any length of the form
/// f · 2ⁿ with f ∈ {1, 3, 5, 15}. Scan dimensions that are not of that form are
/// padded up by the caller.
final class ACBFFFT {

    let rows: Int
    let columns: Int
    private let rowForward: vDSP_DFT_Setup
    private let rowInverse: vDSP_DFT_Setup
    private let columnForward: vDSP_DFT_Setup
    private let columnInverse: vDSP_DFT_Setup

    /// The smallest length vDSP's DFT supports that is at least `target`.
    static func supportedLength(atLeast target: Int) -> Int {
        guard target > 8 else { return 8 }
        var best = Int.max
        for factor in [1, 3, 5, 15] {
            var length = factor * 8
            while length < target { length *= 2 }
            best = Swift.min(best, length)
        }
        return best
    }

    static func isSupported(_ length: Int) -> Bool {
        return supportedLength(atLeast: length) == length
    }

    init?(rows: Int, columns: Int) {
        guard rows > 0, columns > 0,
              ACBFFFT.isSupported(rows), ACBFFFT.isSupported(columns),
              let rf = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(columns), .FORWARD),
              let ri = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(columns), .INVERSE),
              let cf = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(rows), .FORWARD),
              let ci = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(rows), .INVERSE)
        else { return nil }
        self.rows = rows
        self.columns = columns
        self.rowForward = rf
        self.rowInverse = ri
        self.columnForward = cf
        self.columnInverse = ci
    }

    deinit {
        vDSP_DFT_DestroySetup(rowForward)
        vDSP_DFT_DestroySetup(rowInverse)
        vDSP_DFT_DestroySetup(columnForward)
        vDSP_DFT_DestroySetup(columnInverse)
    }

    /// In-place 2D transform. `inverse` divides by rows · columns, matching the
    /// usual convention where a forward followed by an inverse is the identity.
    func transform(real: inout [Float], imaginary: inout [Float], inverse: Bool) {
        precondition(real.count == rows * columns && imaginary.count == rows * columns)

        let rowSetup = inverse ? rowInverse : rowForward
        let columnSetup = inverse ? columnInverse : columnForward

        var scratchReal = [Float](repeating: 0, count: Swift.max(rows, columns))
        var scratchImaginary = scratchReal
        var outReal = scratchReal
        var outImaginary = scratchReal

        // Rows.
        real.withUnsafeMutableBufferPointer { r in
        imaginary.withUnsafeMutableBufferPointer { i in
            guard let rb = r.baseAddress, let ib = i.baseAddress else { return }
            for row in 0..<rows {
                let offset = row * columns
                outReal.withUnsafeMutableBufferPointer { or in
                outImaginary.withUnsafeMutableBufferPointer { oi in
                    vDSP_DFT_Execute(rowSetup, rb + offset, ib + offset,
                                     or.baseAddress!, oi.baseAddress!)
                    (rb + offset).update(from: or.baseAddress!, count: columns)
                    (ib + offset).update(from: oi.baseAddress!, count: columns)
                }}
            }
        }}

        // Columns, gathered into contiguous scratch because the DFT wants unit
        // stride.
        for column in 0..<columns {
            for row in 0..<rows {
                scratchReal[row] = real[row * columns + column]
                scratchImaginary[row] = imaginary[row * columns + column]
            }
            scratchReal.withUnsafeBufferPointer { sr in
            scratchImaginary.withUnsafeBufferPointer { si in
            outReal.withUnsafeMutableBufferPointer { or in
            outImaginary.withUnsafeMutableBufferPointer { oi in
                vDSP_DFT_Execute(columnSetup, sr.baseAddress!, si.baseAddress!,
                                 or.baseAddress!, oi.baseAddress!)
            }}}}
            for row in 0..<rows {
                real[row * columns + column] = outReal[row]
                imaginary[row * columns + column] = outImaginary[row]
            }
        }

        if inverse {
            var scale = Float(1) / Float(rows * columns)
            let n = vDSP_Length(rows * columns)
            vDSP_vsmul(real, 1, &scale, &real, 1, n)
            vDSP_vsmul(imaginary, 1, &scale, &imaginary, 1, n)
        }
    }
}

// MARK: - Stack

/// The bright-field virtual images, already transformed.
///
/// Built once per (disc, binning, orientation) and reused across every
/// reconstruction and every refinement step — which is the only reason a
/// hundreds-of-evaluations refinement is affordable at all.
final class ACBFStack {

    /// Number of virtual detectors.
    let count: Int
    /// Padded scan dimensions the transforms operate on.
    let rows: Int
    let columns: Int
    /// True scan dimensions, for cropping the result back.
    let scanRows: Int
    let scanColumns: Int

    /// Interleaved per detector: `[b][row * columns + column]`.
    private(set) var real: [Float]
    private(set) var imaginary: [Float]

    /// Detector coordinate of each virtual detector, in Å⁻¹, already in the
    /// scan frame.
    private(set) var tiltX: [Double]
    private(set) var tiltY: [Double]

    init(count: Int, rows: Int, columns: Int, scanRows: Int, scanColumns: Int,
         real: [Float], imaginary: [Float], tiltX: [Double], tiltY: [Double]) {
        self.count = count
        self.rows = rows
        self.columns = columns
        self.scanRows = scanRows
        self.scanColumns = scanColumns
        self.real = real
        self.imaginary = imaginary
        self.tiltX = tiltX
        self.tiltY = tiltY
    }

    var pixelCount: Int { return rows * columns }

    /// Re-points the virtual detectors into a new frame without touching the
    /// images, so a rotation search does not rebuild the stack.
    func retilted(using transform: ACBFCoordinateTransform,
                  detectorX: [Double], detectorY: [Double]) -> ACBFStack {
        var x = [Double](repeating: 0, count: count)
        var y = [Double](repeating: 0, count: count)
        for b in 0..<count {
            let mapped = transform.apply(kx: detectorX[b], ky: detectorY[b])
            x[b] = mapped.kx
            y[b] = mapped.ky
        }
        return ACBFStack(count: count, rows: rows, columns: columns,
                         scanRows: scanRows, scanColumns: scanColumns,
                         real: real, imaginary: imaginary, tiltX: x, tiltY: y)
    }
}

// MARK: - Modes

enum ACBFMode {
    /// Shift and sum, done as an exact Fourier phase ramp.
    case tcBF
    /// Align each detector's contribution by the phase of its transfer.
    case acBFPhaseOnly
    /// Regularized inversion of the transfer — a matched filter.
    case acBFComplexInversion(regularization: Double, supportThreshold: Double)
}

// MARK: - Reconstruction

/// Accumulates the Fourier-domain sum and inverts it once.
struct ACBFReconstructor {

    let optics: ACBFOptics
    let orders: ACBFOrders
    /// Stabilises the phase-only normalisation where the transfer vanishes.
    var epsilon: Double = 1e-2

    private var aberrations: ACBFAberrationFunction {
        return ACBFAberrationFunction(orders: orders, wavelength: optics.wavelength)
    }

    /// Scan-frequency axes in cycles per Å, in FFT order.
    static func frequencies(count: Int, step: Double) -> [Double] {
        var q = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let index = i < (count + 1) / 2 ? i : i - count
            q[i] = Double(index) / (Double(count) * step)
        }
        return q
    }

    /// The reconstructed image, cropped back to the true scan dimensions.
    ///
    /// - Parameter accelerator: used when present; the CPU path is otherwise
    ///   identical and is what the GPU is checked against.
    func reconstruct(stack: ACBFStack,
                     coefficients: [Double],
                     mode: ACBFMode,
                     accelerator: ACBFMetalAccumulator? = nil,
                     isCancelled: () -> Bool = { false }) -> [Float]? {

        let qx = ACBFReconstructor.frequencies(count: stack.columns, step: optics.scanStep)
        let qy = ACBFReconstructor.frequencies(count: stack.rows, step: optics.scanStep)

        var accumulated: ACBFAccumulation?
        if let accelerator = accelerator {
            accumulated = accelerator.accumulate(stack: stack, coefficients: coefficients,
                                                 mode: mode, optics: optics, orders: orders,
                                                 epsilon: epsilon, qx: qx, qy: qy)
        }
        if accumulated == nil {
            accumulated = accumulate(stack: stack, coefficients: coefficients, mode: mode,
                                     qx: qx, qy: qy, isCancelled: isCancelled)
        }
        guard var result = accumulated else { return nil }

        // Complex inversion finishes in Fourier space: divide the matched
        // numerator by the accumulated transfer power.
        if case .acBFComplexInversion(let regularization, let supportThreshold) = mode {
            guard let power = result.power else { return nil }
            let reference = ACBFReconstructor.medianOfPositive(power)
            let floor = Float(regularization) * reference
            let threshold = Float(supportThreshold) * reference
            for i in 0..<result.real.count {
                if power[i] > threshold {
                    let denominator = power[i] + floor
                    result.real[i] /= denominator
                    result.imaginary[i] /= denominator
                } else {
                    result.real[i] = 0
                    result.imaginary[i] = 0
                }
            }
        }

        guard let fft = ACBFFFT(rows: stack.rows, columns: stack.columns) else { return nil }
        fft.transform(real: &result.real, imaginary: &result.imaginary, inverse: true)

        return crop(result.real, rows: stack.rows, columns: stack.columns,
                    toRows: stack.scanRows, toColumns: stack.scanColumns)
    }

    /// Median of the strictly positive entries, which sets the regularisation
    /// scale. Using the median rather than the mean keeps a few very strong
    /// frequencies from setting the floor for the whole image.
    ///
    /// For an even count this is the lower of the two central values, not their
    /// average. That is the convention the reference implementation's tensor
    /// library uses, and since this one number scales both the regularisation
    /// floor and the support threshold, averaging instead shifts the result by
    /// percent-level amounts wherever the transfer power is weak.
    static func medianOfPositive(_ values: [Float]) -> Float {
        var positive = values.filter { $0 > 0 }
        guard !positive.isEmpty else { return 1 }
        positive.sort()
        return positive[(positive.count - 1) / 2]
    }

    private func crop(_ image: [Float], rows: Int, columns: Int,
                      toRows: Int, toColumns: Int) -> [Float] {
        if rows == toRows && columns == toColumns { return image }
        var out = [Float](repeating: 0, count: toRows * toColumns)
        for y in 0..<toRows {
            let source = y * columns
            let destination = y * toColumns
            for x in 0..<toColumns { out[destination + x] = image[source + x] }
        }
        return out
    }

    // MARK: CPU accumulation

    func accumulate(stack: ACBFStack, coefficients: [Double], mode: ACBFMode,
                    qx: [Double], qy: [Double],
                    isCancelled: () -> Bool = { false }) -> ACBFAccumulation? {

        let pixels = stack.pixelCount
        var sumReal = [Float](repeating: 0, count: pixels)
        var sumImaginary = [Float](repeating: 0, count: pixels)
        var power: [Float]? = nil

        let wantsPower: Bool
        if case .acBFComplexInversion = mode { wantsPower = true } else { wantsPower = false }
        if wantsPower { power = [Float](repeating: 0, count: pixels) }

        let evaluator = ACBFPhaseEvaluator(orders: orders,
                                           wavelength: optics.wavelength,
                                           coefficients: coefficients)
        let function = aberrations
        let epsilonF = Float(epsilon)
        let rows = stack.rows, columns = stack.columns

        for b in 0..<stack.count {
            if b % 32 == 0 && isCancelled() { return nil }

            let kxt = stack.tiltX[b]
            let kyt = stack.tiltY[b]
            let base = b * pixels

            switch mode {
            case .tcBF:
                let shift = function.shift(kx: kxt, ky: kyt, coefficients: coefficients)
                for y in 0..<rows {
                    let rowShift = shift.dy * qy[y]
                    for x in 0..<columns {
                        let phase = -2 * Double.pi * (shift.dx * qx[x] + rowShift)
                        let w = Float(cos(phase)), v = Float(sin(phase))
                        let i = base + y * columns + x
                        let ir = stack.real[i], ii = stack.imaginary[i]
                        sumReal[y * columns + x] += ir * w - ii * v
                        sumImaginary[y * columns + x] += ir * v + ii * w
                    }
                }

            case .acBFPhaseOnly, .acBFComplexInversion:
                let chiTilt = evaluator.chi(kx: kxt, ky: kyt)
                for y in 0..<rows {
                    for x in 0..<columns {
                        let transfer = ACBFReconstructor.transfer(
                            qx: qx[x], qy: qy[y], kxt: kxt, kyt: kyt,
                            chiTilt: chiTilt, evaluator: evaluator, optics: optics)

                        let i = base + y * columns + x
                        let o = y * columns + x
                        let ir = stack.real[i], ii = stack.imaginary[i]

                        if wantsPower {
                            let tr = Float(transfer.real), ti = Float(transfer.imaginary)
                            sumReal[o] += tr * ir - ti * ii
                            sumImaginary[o] += tr * ii + ti * ir
                            power![o] += tr * tr + ti * ti
                        } else {
                            let magnitude = Float((transfer.real * transfer.real
                                                 + transfer.imaginary * transfer.imaginary).squareRoot())
                            let scale = 1 / (magnitude + epsilonF)
                            let tr = Float(transfer.real) * scale
                            let ti = Float(transfer.imaginary) * scale
                            sumReal[o] += ir * tr - ii * ti
                            sumImaginary[o] += ir * ti + ii * tr
                        }
                    }
                }
            }
        }

        return ACBFAccumulation(real: sumReal, imaginary: sumImaginary, power: power)
    }

    /// The bright-field transfer for one detector pixel at one scan frequency.
    ///
    /// This is the interference between the unscattered beam at tilt t and the
    /// beams it scatters to ±q: two aperture-limited terms whose phases are the
    /// aberration difference across that scattering. It is the quantity acBF
    /// corrects for and tcBF only approximates — expanding it to first order in
    /// q recovers a pure translation, which is why the two agree at low
    /// frequency and diverge where the transfer changes sign.
    @inline(__always)
    static func transfer(qx: Double, qy: Double, kxt: Double, kyt: Double,
                         chiTilt: Double, evaluator: ACBFPhaseEvaluator,
                         optics: ACBFOptics) -> (real: Double, imaginary: Double) {

        let plusX = qx + kxt,  plusY = qy + kyt
        let minusX = qx - kxt, minusY = qy - kyt

        let aperturePlus = acbfAperture(
            alpha: (plusX * plusX + plusY * plusY).squareRoot() * optics.wavelength,
            maxAlphaMilliradians: optics.maxAlpha, rolloffMilliradians: optics.rolloff)
        let apertureMinus = acbfAperture(
            alpha: (minusX * minusX + minusY * minusY).squareRoot() * optics.wavelength,
            maxAlphaMilliradians: optics.maxAlpha, rolloffMilliradians: optics.rolloff)

        // Nothing to interfere with: both scattered beams are outside the disc.
        if aperturePlus == 0 && apertureMinus == 0 { return (0, 0) }

        let chiPlus = aperturePlus == 0 ? 0 : evaluator.chi(kx: plusX, ky: plusY)
        let chiMinus = apertureMinus == 0 ? 0 : evaluator.chi(kx: -minusX, ky: -minusY)

        // term₋ = A(q−t)·e^(−i(χ(t) − χ(t−q))),  term₊ = A(q+t)·e^(+i(χ(t) − χ(q+t)))
        let phaseMinus = -(chiTilt - chiMinus)
        let phasePlus = chiTilt - chiPlus

        let dReal = apertureMinus * cos(phaseMinus) - aperturePlus * cos(phasePlus)
        let dImaginary = apertureMinus * sin(phaseMinus) - aperturePlus * sin(phasePlus)

        // T = −i·D rotates the difference onto the real axis for a pure phase
        // object, so the reconstruction is real-valued rather than quadrature.
        return (real: dImaginary, imaginary: -dReal)
    }
}

/// A Fourier-domain accumulation: the weighted image sum, plus the transfer
/// power when the mode needs it.
struct ACBFAccumulation {
    var real: [Float]
    var imaginary: [Float]
    var power: [Float]?
}

// MARK: - Fast χ

/// χ evaluation stripped down for the inner loop.
///
/// Two things make it worth having separately from `ACBFAberrationFunction`:
/// the coefficients are folded in once so each call is a plain polynomial, and
/// the radial powers are integer (n + 1 − m is always even) so `pow` never
/// appears. It is called once per detector pixel per scan frequency — tens of
/// millions of times per reconstruction — and the general version is far too
/// slow there.
struct ACBFPhaseEvaluator {

    private struct Term {
        let radialPower: Int      // exponent of α², always an integer
        let m: Int
        let scaleX: Double        // coefficient · (2π/λ) / (n+1), X component
        let scaleY: Double        // same for the Y component; 0 for m == 0
    }

    private let terms: [Term]
    private let wavelength: Double
    private let maxM: Int

    init(orders: ACBFOrders, wavelength: Double, coefficients: [Double]) {
        self.wavelength = wavelength
        let multiplier = 2 * Double.pi / wavelength
        var terms: [Term] = []
        var maxM = 0
        for key in orders.keys {
            let inverse = multiplier / Double(key.n + 1)
            let x = coefficients[key.offset] * inverse
            let y = key.width == 2 ? coefficients[key.offset + 1] * inverse : 0
            if x == 0 && y == 0 { continue }        // skip terms the user zeroed
            terms.append(Term(radialPower: (key.n + 1 - key.m) / 2, m: key.m,
                              scaleX: x, scaleY: y))
            maxM = Swift.max(maxM, key.m)
        }
        self.terms = terms
        self.maxM = maxM
    }

    var isZero: Bool { return terms.isEmpty }

    @inline(__always)
    func chi(kx: Double, ky: Double) -> Double {
        if terms.isEmpty { return 0 }

        let ax = kx * wavelength
        let ay = ky * wavelength
        let alphaSquared = ax * ax + ay * ay

        // (αx + i·αy)^m by repeated multiplication, up to the largest m in use.
        var powerX = [Double](repeating: 0, count: maxM + 1)
        var powerY = [Double](repeating: 0, count: maxM + 1)
        powerX[0] = 1
        if maxM > 0 {
            for m in 0..<maxM {
                powerX[m + 1] = powerX[m] * ax - powerY[m] * ay
                powerY[m + 1] = powerX[m] * ay + powerY[m] * ax
            }
        }

        var total = 0.0
        for term in terms {
            var radial = 1.0
            for _ in 0..<term.radialPower { radial *= alphaSquared }
            total += radial * (term.scaleX * powerX[term.m] + term.scaleY * powerY[term.m])
        }
        return total
    }
}

// MARK: - Quality metrics

/// How focused an image looks. Higher is better, for all of them.
///
/// Scored on the centre by default: a padded reconstruction has guard bands at
/// the edges whose sharp boundary would otherwise dominate every gradient
/// measure and make the metric track the padding rather than the focus.
enum ACBFMetric: String {
    case sobel
    case laplacian
    case normalizedVariance

    static func named(_ name: String) -> ACBFMetric {
        switch name.lowercased() {
        case let n where n.hasPrefix("lap"): return .laplacian
        case let n where n.hasPrefix("norm"), let n where n.hasPrefix("var"): return .normalizedVariance
        default: return .sobel
        }
    }

    var label: String {
        switch self {
        case .sobel: return "Sobel gradient"
        case .laplacian: return "Laplacian variance"
        case .normalizedVariance: return "Normalised variance"
        }
    }

    func score(_ image: [Float], rows: Int, columns: Int, cropFraction: Double = 0.5) -> Double {
        let fraction = max(0.05, min(1.0, cropFraction))
        let cropRows = max(1, Int((Double(rows) * fraction).rounded()))
        let cropColumns = max(1, Int((Double(columns) * fraction).rounded()))
        let firstRow = (rows - cropRows) / 2
        let firstColumn = (columns - cropColumns) / 2

        switch self {
        case .normalizedVariance:
            var sum = 0.0, sumSquares = 0.0, n = 0.0
            for y in firstRow..<(firstRow + cropRows) {
                for x in firstColumn..<(firstColumn + cropColumns) {
                    let v = Double(image[y * columns + x])
                    sum += v; sumSquares += v * v; n += 1
                }
            }
            guard n > 0 else { return 0 }
            let mean = sum / n
            let variance = max(0, sumSquares / n - mean * mean)
            return variance.squareRoot() / (abs(mean) + 1e-6)

        case .sobel, .laplacian:
            // Convolutions are evaluated one pixel inside the crop so the
            // kernel never reads outside the image.
            let y0 = max(1, firstRow), y1 = min(rows - 1, firstRow + cropRows)
            let x0 = max(1, firstColumn), x1 = min(columns - 1, firstColumn + cropColumns)
            guard y1 > y0, x1 > x0 else { return 0 }

            if self == .sobel {
                var total = 0.0, n = 0.0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = y * columns + x
                        let gx = Double(-image[i - columns - 1] + image[i - columns + 1]
                                        - 2 * image[i - 1] + 2 * image[i + 1]
                                        - image[i + columns - 1] + image[i + columns + 1])
                        let gy = Double(-image[i - columns - 1] - 2 * image[i - columns] - image[i - columns + 1]
                                        + image[i + columns - 1] + 2 * image[i + columns] + image[i + columns + 1])
                        total += gx * gx + gy * gy
                        n += 1
                    }
                }
                return n > 0 ? total / n : 0
            } else {
                var sum = 0.0, sumSquares = 0.0, n = 0.0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = y * columns + x
                        let value = Double(image[i - columns] + image[i + columns]
                                           + image[i - 1] + image[i + 1] - 4 * image[i])
                        sum += value; sumSquares += value * value; n += 1
                    }
                }
                guard n > 0 else { return 0 }
                let mean = sum / n
                return max(0, sumSquares / n - mean * mean)
            }
        }
    }
}
