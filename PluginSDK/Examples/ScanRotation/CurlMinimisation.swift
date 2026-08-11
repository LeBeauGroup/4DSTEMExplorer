//
//  CurlMinimisation.swift
//  4DSTEM Explorer — Scan Rotation
//
//  Finds the angle between the scan axes and the detector axes.
//
//  The measurement rests on one fact about the centre-of-mass signal. The first
//  moment of each diffraction pattern is the mean momentum transferred to the
//  beam, which for a thin specimen is proportional to the projected electric
//  field — and an electrostatic field is the gradient of a potential. A gradient
//  field has no curl. So the true CoM field is curl-free, and any curl in the
//  measured one is an artefact of the frame it was measured in.
//
//  Scan and detector axes are not generally aligned: the scan coils are driven
//  in their own frame while the camera sits at whatever angle it was mounted.
//  A CoM vector recorded in detector coordinates but differentiated against scan
//  coordinates therefore mixes the two, and the mixture shows up as curl. The
//  angle that removes the curl is the angle between the frames.
//
//  Written out, with `C` the curl and `D` the divergence of the unrotated field,
//  rotating the CoM vectors by θ gives
//
//      curl(θ) =  C·cos θ − D·sin θ
//      div (θ) =  D·cos θ + C·sin θ
//
//  — the two mix into each other exactly as a rotation of a vector would, which
//  is what makes a single θ able to move all of the curl into the divergence.
//  Minimising Σcurl² is then a closed-form problem, not a search:
//
//      tan 2θ = −2·Σ(C·D) / (Σ C² − Σ D²)
//
//  There is no iteration and no starting guess. `curlVersusAngle` exists only so
//  the minimum can be seen and judged, not to find it.
//
//  Two ambiguities are real and are resolved here rather than left to the caller:
//
//    * θ and θ+180° both null the curl. They differ in the sign of the
//      divergence, and the physical sign is known — the divergence of the CoM
//      field is proportional to the projected charge density, which is positive
//      at atomic columns. The solution with positive divergence is the right one.
//
//    * a detector may be mounted mirrored with respect to the scan, and no
//      rotation can undo a reflection. Both handednesses are tried; the one that
//      reaches a lower residual curl is the one the instrument has.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

/// A centre-of-mass vector field sampled on the scan grid.
///
/// `x` and `y` are the two components in **detector** coordinates, in detector
/// pixels relative to the unscattered beam, laid out row-major over the scan.
struct CoMField {
    var x: [Double]
    var y: [Double]
    let rows: Int
    let columns: Int

    var isUsable: Bool {
        return rows >= 3 && columns >= 3 && x.count == rows * columns && y.count == x.count
    }
}

/// What the curl minimisation found.
struct ScanRotationSolution {

    /// The angle to rotate CoM vectors by, in degrees, to remove the curl.
    let rotationDegrees: Double
    /// Whether the detector is mirrored with respect to the scan.
    ///
    /// A reflection is not a rotation, so when this is true the rotation alone
    /// does not describe the relationship between the frames.
    let transposed: Bool

    /// RMS curl at the solution, in CoM units per probe position.
    let residualCurl: Double
    /// RMS curl at the worst angle, for scale. The ratio of the two is what says
    /// whether the minimum means anything.
    let worstCurl: Double
    /// RMS divergence at the solution.
    let divergence: Double

    /// How firmly the 180° ambiguity was resolved: the magnitude of the
    /// divergence skewness that chose between θ and θ+180°.
    ///
    /// Near zero the two are indistinguishable from this data alone, and the
    /// reported angle may be a half-turn out. That is not a failure of the fit —
    /// the curl is nulled either way — but it is something the user has to settle
    /// by other means, so it is reported rather than hidden.
    let divergenceSkewness: Double

    /// True when the divergence distribution was too symmetric to choose between
    /// θ and θ+180° with any confidence.
    var halfTurnUncertain: Bool { return divergenceSkewness < 0.05 }

    /// How deep the minimum is: `1 - residual/worst`. Near 1 the angle is sharply
    /// determined; near 0 the data carries no orientation information at all and
    /// the reported angle is noise.
    var contrast: Double {
        guard worstCurl > 0 else { return 0 }
        return 1 - residualCurl / worstCurl
    }

    /// RMS curl as a function of angle, sampled every degree over 360°, for the
    /// diagnostic curve. Index `i` is `i` degrees.
    let curlVersusAngle: [Double]
    /// The same, for the handedness that was rejected.
    let rejectedCurlVersusAngle: [Double]
    /// Residual curl the rejected handedness reached.
    let rejectedResidualCurl: Double
}

enum CurlMinimisation {

    /// Central differences over the interior of the scan.
    ///
    /// One-sided differences at the edges would be a different estimator with a
    /// different bias, and the edge of a scan is where flyback and drift do their
    /// worst; both derivatives are therefore evaluated only where a centred
    /// stencil fits, and every sum below runs over that same interior. Mixing
    /// stencils would tilt the fit toward whichever artefact lives on the border.
    private static func derivatives(_ field: CoMField)
        -> (curl: [Double], divergence: [Double])? {

        guard field.isUsable else { return nil }
        let rows = field.rows, columns = field.columns
        var curl = [Double](); var divergence = [Double]()
        curl.reserveCapacity((rows - 2) * (columns - 2))
        divergence.reserveCapacity((rows - 2) * (columns - 2))

        for row in 1..<(rows - 1) {
            for column in 1..<(columns - 1) {
                let index = row * columns + column
                let dXdx = (field.x[index + 1] - field.x[index - 1]) / 2
                let dXdy = (field.x[index + columns] - field.x[index - columns]) / 2
                let dYdx = (field.y[index + 1] - field.y[index - 1]) / 2
                let dYdy = (field.y[index + columns] - field.y[index - columns]) / 2
                curl.append(dXdy - dYdx)
                divergence.append(dXdx + dYdy)
            }
        }
        return (curl, divergence)
    }

    /// Rotation-invariant sums that everything else is built from.
    private struct Moments {
        let curlSquared: Double        // Σ C²
        let divergenceSquared: Double  // Σ D²
        let cross: Double              // Σ C·D
        let count: Int
    }

    private static func moments(_ field: CoMField) -> Moments? {
        guard let (curl, divergence) = derivatives(field), !curl.isEmpty else { return nil }
        var cc = 0.0, dd = 0.0, cd = 0.0
        for index in curl.indices {
            let c = curl[index], d = divergence[index]
            cc += c * c; dd += d * d; cd += c * d
        }
        return Moments(curlSquared: cc, divergenceSquared: dd, cross: cd, count: curl.count)
    }

    /// RMS curl and divergence after rotating the field by `degrees`.
    ///
    /// Computed from the moments rather than by rotating and re-differentiating,
    /// which is both exact and independent of the scan size.
    private static func response(_ m: Moments, degrees: Double) -> (curl: Double, divergence: Double) {
        let radians = degrees * .pi / 180
        let c = cos(radians), s = sin(radians)
        let curl = m.curlSquared * c * c - 2 * m.cross * c * s + m.divergenceSquared * s * s
        let div  = m.divergenceSquared * c * c + 2 * m.cross * c * s + m.curlSquared * s * s
        let n = Double(m.count)
        return ((max(0, curl) / n).squareRoot(), (max(0, div) / n).squareRoot())
    }

    /// Skewness of the divergence after rotation, which is what distinguishes θ
    /// from θ+180°.
    ///
    /// The RMS cannot: it is blind to sign, and both angles null the curl
    /// equally. The obvious discriminator — the mean divergence — is worse than
    /// useless, because the divergence of a field summed over a region reduces to
    /// its flux through the boundary, so a scan across a neutral specimen has a
    /// mean of essentially zero no matter which way round the field is. Reading a
    /// sign off that is reading noise.
    ///
    /// The distribution's *shape* does carry it. The divergence of the CoM field
    /// is proportional to the projected charge density, which is not symmetric
    /// about zero: it has sharp positive spikes at the atomic columns and a
    /// shallow negative background everywhere else, averaging out to nothing.
    /// That asymmetry is skewness, and it changes sign with the field. Positive
    /// skew is the physical orientation.
    private static func divergenceSkewness(_ field: CoMField, degrees: Double) -> Double {
        guard let (curl, divergence) = derivatives(field), !curl.isEmpty else { return 0 }
        let radians = degrees * .pi / 180
        let c = cos(radians), s = sin(radians)
        let n = Double(curl.count)

        var mean = 0.0
        for index in curl.indices { mean += divergence[index] * c + curl[index] * s }
        mean /= n

        var second = 0.0, third = 0.0
        for index in curl.indices {
            let value = divergence[index] * c + curl[index] * s - mean
            second += value * value
            third += value * value * value
        }
        let variance = second / n
        guard variance > 0 else { return 0 }
        return (third / n) / pow(variance, 1.5)
    }

    /// The field as the other handedness would have recorded it.
    ///
    /// Swapping the two components is a reflection, and reflections are exactly
    /// what a rotation cannot reach — which is why this has to be tried as a
    /// separate hypothesis rather than folded into the angle search.
    private static func transposed(_ field: CoMField) -> CoMField {
        return CoMField(x: field.y, y: field.x, rows: field.rows, columns: field.columns)
    }

    /// Solves one handedness.
    private static func solveOne(_ field: CoMField) -> (degrees: Double, m: Moments)? {
        guard let m = moments(field) else { return nil }

        // d/dθ Σcurl² = 0  ⟹  tan 2θ = −2ΣCD / (ΣC² − ΣD²).
        // atan2 picks the branch; the half then lands on either the minimum or
        // the maximum, so both are evaluated and the smaller kept. Cheaper and
        // more certain than reasoning about which branch atan2 chose.
        let doubled = atan2(-2 * m.cross, m.curlSquared - m.divergenceSquared)
        let first = doubled / 2 * 180 / .pi
        let candidates = [first, first + 90, first + 180, first + 270]

        var best = candidates[0]
        var bestCurl = Double.infinity
        for candidate in candidates {
            let curl = response(m, degrees: candidate).curl
            // A hair of tolerance so that when two candidates tie — a field with
            // no orientation information at all — the first is kept rather than
            // the choice turning on the last bit of the arithmetic.
            if curl < bestCurl - 1e-15 { bestCurl = curl; best = candidate }
        }
        return (best, m)
    }

    /// Measures the scan rotation from a centre-of-mass field.
    ///
    /// Returns nil when the scan is too small to differentiate, or when the field
    /// is uniform and there is nothing to fit.
    static func solve(_ measured: CoMField) -> ScanRotationSolution? {

        func evaluate(_ field: CoMField) -> (degrees: Double, m: Moments, curl: Double)? {
            guard let (degrees, m) = solveOne(field) else { return nil }
            return (degrees, m, response(m, degrees: degrees).curl)
        }

        let straight = evaluate(measured)
        let mirrored = evaluate(transposed(measured))

        guard straight != nil || mirrored != nil else { return nil }

        // The handedness that explains the data with less leftover curl.
        let useMirrored: Bool
        switch (straight, mirrored) {
        case (nil, _): useMirrored = true
        case (_, nil): useMirrored = false
        case let (s?, m?): useMirrored = m.curl < s.curl
        }

        let field = useMirrored ? transposed(measured) : measured
        guard let chosen = useMirrored ? mirrored : straight else { return nil }
        let other = useMirrored ? straight : mirrored

        // θ and θ+180° null the curl equally well; the divergence distribution
        // tells them apart, being positively skewed only the physical way round.
        var degrees = chosen.degrees
        let skew = divergenceSkewness(field, degrees: degrees)
        if skew < 0 { degrees += 180 }
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees > 180 { degrees -= 360 }
        if degrees <= -180 { degrees += 360 }

        var curve = [Double](repeating: 0, count: 360)
        for angle in 0..<360 { curve[angle] = response(chosen.m, degrees: Double(angle)).curl }
        var rejectedCurve = [Double](repeating: 0, count: 360)
        if let other = other {
            for angle in 0..<360 { rejectedCurve[angle] = response(other.m, degrees: Double(angle)).curl }
        }

        let atSolution = response(chosen.m, degrees: degrees)
        return ScanRotationSolution(
            rotationDegrees: degrees,
            transposed: useMirrored,
            residualCurl: atSolution.curl,
            worstCurl: curve.max() ?? 0,
            divergence: atSolution.divergence,
            divergenceSkewness: abs(skew),
            curlVersusAngle: curve,
            rejectedCurlVersusAngle: rejectedCurve,
            rejectedResidualCurl: other.map { $0.curl } ?? .nan)
    }

    /// Smooths both components with a separable Gaussian.
    ///
    /// Differentiating amplifies noise in proportion to frequency, so on a noisy
    /// CoM field the curl is dominated by shot noise — which is isotropic, has no
    /// preferred angle, and therefore does not bias θ so much as bury it. A mild
    /// blur trades spatial detail, which this measurement does not use, for a
    /// minimum deep enough to locate.
    static func smoothed(_ field: CoMField, sigma: Double) -> CoMField {
        guard sigma > 0, field.isUsable else { return field }
        let radius = max(1, Int((3 * sigma).rounded()))
        var kernel = [Double](repeating: 0, count: 2 * radius + 1)
        var total = 0.0
        for offset in -radius...radius {
            let weight = exp(-Double(offset * offset) / (2 * sigma * sigma))
            kernel[offset + radius] = weight
            total += weight
        }
        for index in kernel.indices { kernel[index] /= total }

        func blur(_ input: [Double]) -> [Double] {
            let rows = field.rows, columns = field.columns
            var horizontal = [Double](repeating: 0, count: input.count)
            for row in 0..<rows {
                for column in 0..<columns {
                    var sum = 0.0
                    for offset in -radius...radius {
                        // Clamped edges: a wrapped one would join the last column
                        // of the raster to the first, inventing a discontinuity
                        // exactly where the derivative is about to be taken.
                        let source = min(columns - 1, max(0, column + offset))
                        sum += input[row * columns + source] * kernel[offset + radius]
                    }
                    horizontal[row * columns + column] = sum
                }
            }
            var output = [Double](repeating: 0, count: input.count)
            for row in 0..<rows {
                for column in 0..<columns {
                    var sum = 0.0
                    for offset in -radius...radius {
                        let source = min(rows - 1, max(0, row + offset))
                        sum += horizontal[source * columns + column] * kernel[offset + radius]
                    }
                    output[row * columns + column] = sum
                }
            }
            return output
        }

        return CoMField(x: blur(field.x), y: blur(field.y),
                        rows: field.rows, columns: field.columns)
    }

    /// Drops `trim` probe positions from every edge of the scan.
    ///
    /// The first columns of each row carry the flyback transient, and the field
    /// there is not a measurement of the specimen.
    static func trimmed(_ field: CoMField, by trim: Int) -> CoMField {
        guard trim > 0, field.isUsable else { return field }
        let rows = field.rows - 2 * trim
        let columns = field.columns - 2 * trim
        guard rows >= 3, columns >= 3 else { return field }
        var x = [Double](repeating: 0, count: rows * columns)
        var y = x
        for row in 0..<rows {
            for column in 0..<columns {
                let source = (row + trim) * field.columns + (column + trim)
                x[row * columns + column] = field.x[source]
                y[row * columns + column] = field.y[source]
            }
        }
        return CoMField(x: x, y: y, rows: rows, columns: columns)
    }
}
