//
//  ACBFRefinement.swift
//  4DSTEM Explorer — Aberration-Corrected Bright Field
//
//  Finds the aberrations and the detector-to-scan orientation by maximising how
//  sharp the reconstruction looks.
//
//  This is a different principle from the cross-correlation fit in the
//  Tilt-Corrected Bright Field plugin. That one measures where each virtual
//  image sits and fits a model to the displacements; it is fast and needs no
//  reconstruction, but it can only see effects that translate an image, and it
//  needs enough contrast in every single virtual image to correlate.
//
//  Scoring the reconstruction instead asks the question that actually matters —
//  is the result sharper? — so it works for aberrations that blur rather than
//  shift, and it degrades gracefully on low-contrast data. The price is that
//  every evaluation is a full reconstruction, which is only affordable because
//  the stack is transformed once and each evaluation is a single accumulation
//  plus one inverse transform.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

/// Maximises an image-quality metric over the parameters that affect it.
struct ACBFRefinement {

    let reconstructor: ACBFReconstructor
    let orders: ACBFOrders
    var metric: ACBFMetric = .sobel
    var mode: ACBFMode = .tcBF
    var accelerator: ACBFMetalAccumulator?
    var cropFraction: Double = 0.5

    /// Detector coordinates before any frame transform, so orientation can be
    /// re-applied without rebuilding the virtual images.
    let detectorX: [Double]
    let detectorY: [Double]

    var isCancelled: () -> Bool = { false }

    /// One reconstruction, scored. Everything below is a search over this.
    func score(stack: ACBFStack, coefficients: [Double]) -> Double {
        guard let image = reconstructor.reconstruct(stack: stack, coefficients: coefficients,
                                                    mode: mode, accelerator: accelerator,
                                                    isCancelled: isCancelled)
        else { return -.greatestFiniteMagnitude }
        return metric.score(image, rows: stack.scanRows, columns: stack.scanColumns,
                            cropFraction: cropFraction)
    }

    // MARK: - Search primitive

    /// Coarse sweep to locate the peak, then Brent inside the bracket around it.
    ///
    /// Brent on its own is a local method: started cold on a wide range it walks
    /// into whichever maximum it happens to be nearest, which for a high-order
    /// coefficient is rarely the right one. The sweep costs a handful of extra
    /// reconstructions and makes the outcome independent of the starting point.
    private func sweepThenBrent(centre: Double, width: Double, points: Int,
                                evaluate: (Double) -> Double)
        -> (value: Double, score: Double, sweep: [(Double, Double)])? {

        guard width > 0 else { return nil }
        let count = Swift.max(5, points)
        var sweep: [(Double, Double)] = []
        sweep.reserveCapacity(count)

        var bestIndex = 0
        for i in 0..<count {
            if isCancelled() { return nil }
            let value = centre - width + 2 * width * Double(i) / Double(count - 1)
            let score = evaluate(value)
            sweep.append((value, score))
            if score > sweep[bestIndex].1 { bestIndex = i }
        }

        var best = sweep[bestIndex].0
        var bestScore = sweep[bestIndex].1

        if bestIndex > 0 && bestIndex < count - 1 {
            let step = sweep[1].0 - sweep[0].0
            if let refined = ACBFRefinement.brentMaximize(
                lower: sweep[bestIndex - 1].0, upper: sweep[bestIndex + 1].0,
                tolerance: abs(step) * 1e-3, isCancelled: isCancelled, evaluate: evaluate),
               refined.score >= bestScore {
                best = refined.value
                bestScore = refined.score
            }
        }
        return (best, bestScore, sweep)
    }

    // MARK: - Defocus

    struct DefocusResult {
        var coefficients: [Double]
        var defocus: Double          // Å
        var score: Double
        /// The coarse sweep, for plotting.
        var sweepDefocus: [Double]
        var sweepScore: [Double]
    }

    /// Coarse sweep, then Brent on the bracket around the best point.
    ///
    /// The sweep alone is limited by its own step size, and Brent alone needs a
    /// bracket that a cold start does not have — defocus scans are multi-modal
    /// once astigmatism is present, and a local method walks into the nearer
    /// line focus. Doing both is what gets a well-located optimum.
    func refineDefocus(stack: ACBFStack, coefficients: [Double],
                       range: Double, points: Int) -> DefocusResult? {

        guard let index = orders.defocusIndex else { return nil }
        var working = coefficients

        guard let outcome = sweepThenBrent(centre: coefficients[index], width: range,
                                           points: points, evaluate: { value in
            working[index] = value
            return score(stack: stack, coefficients: working)
        }) else { return nil }

        let best = outcome.value
        let bestScore = outcome.score
        let sweepDefocus = outcome.sweep.map { $0.0 }
        let sweepScore = outcome.sweep.map { $0.1 }

        working[index] = best
        return DefocusResult(coefficients: working, defocus: best, score: bestScore,
                             sweepDefocus: sweepDefocus, sweepScore: sweepScore)
    }

    // MARK: - Orientation

    struct RotationResult {
        var transform: ACBFCoordinateTransform
        var rotationDegrees: Double
        var score: Double
    }

    /// Brent over scan rotation, within `halfWidth` degrees of where it is now.
    func refineScanRotation(transform: ACBFCoordinateTransform,
                            stack: ACBFStack,
                            coefficients: [Double],
                            halfWidth: Double) -> RotationResult? {

        let centre = transform.rotationDegrees
        var candidate = transform

        func scoreAt(_ angle: Double) -> Double {
            candidate.rotationDegrees = angle
            let rotated = stack.retilted(using: candidate, detectorX: detectorX, detectorY: detectorY)
            // The coefficients live in the detector frame, so they rotate with it.
            let scanFrame = candidate.rotateCoefficients(coefficients, orders: orders)
            return score(stack: rotated, coefficients: scanFrame)
        }

        guard let best = ACBFRefinement.brentMaximize(
            lower: centre - halfWidth, upper: centre + halfWidth,
            tolerance: 1e-3, isCancelled: isCancelled, evaluate: scoreAt)
        else { return nil }

        var result = transform
        result.rotationDegrees = best.value
        return RotationResult(transform: result, rotationDegrees: best.value, score: best.score)
    }

    /// Tries every flip/transpose combination and keeps the best.
    ///
    /// There are only eight, and they are not continuous, so an exhaustive
    /// search is both cheaper and more reliable than anything cleverer. The scan
    /// rotation is re-searched inside each one because the best rotation depends
    /// on which flips are active.
    func refineFlips(transform: ACBFCoordinateTransform,
                     stack: ACBFStack,
                     coefficients: [Double],
                     rotationHalfWidth: Double) -> RotationResult? {

        var best: RotationResult?

        for flipRows in [false, true] {
            for flipColumns in [false, true] {
                for transpose in [false, true] {
                    if isCancelled() { return best }
                    var candidate = transform
                    candidate.flipRows = flipRows
                    candidate.flipColumns = flipColumns
                    candidate.transpose = transpose

                    let outcome: RotationResult
                    if rotationHalfWidth > 0,
                       let refined = refineScanRotation(transform: candidate, stack: stack,
                                                        coefficients: coefficients,
                                                        halfWidth: rotationHalfWidth) {
                        outcome = refined
                    } else {
                        let rotated = stack.retilted(using: candidate,
                                                     detectorX: detectorX, detectorY: detectorY)
                        let scanFrame = candidate.rotateCoefficients(coefficients, orders: orders)
                        outcome = RotationResult(transform: candidate,
                                                 rotationDegrees: candidate.rotationDegrees,
                                                 score: score(stack: rotated, coefficients: scanFrame))
                    }
                    if best == nil || outcome.score > best!.score { best = outcome }
                }
            }
        }
        return best
    }

    // MARK: - Aberrations

    struct AberrationResult {
        var coefficients: [Double]
        var score: Double
        var evaluations: Int
    }

    /// A coarse coordinate sweep to get into the right basin, then a simplex
    /// over all the coefficients at once.
    ///
    /// The sweep alone is not enough because the coefficients are coupled —
    /// defocus trades against spherical, and a coordinate method cannot move
    /// along that valley, so it stalls with C1 absorbing part of C3. The simplex
    /// alone is not enough either: started cold on an oscillatory objective it
    /// collapses into the nearest local maximum. Together they are reliable.
    ///
    /// The search runs in units of "one radian of phase at the aperture edge"
    /// rather than in ångström, which is what makes a single simplex step size
    /// meaningful for every order at once.
    func refineAberrations(stack: ACBFStack,
                           coefficients: [Double],
                           radiansOfSearch: Double = 3.0,
                           passes: Int = 2,
                           sweepPoints: Int = 9,
                           simplexIterations: Int = 600) -> AberrationResult? {

        var working = coefficients
        var best = score(stack: stack, coefficients: working)
        var evaluations = 1

        let scales = orders.keys.reduce(into: [Int: Double]()) { table, key in
            table[key.n] = reconstructor.optics.coefficientScale(order: key.n)
        }

        // --- stage 1: coordinate sweeps ---
        for pass in 0..<Swift.max(1, passes) {
            var improved = false
            let narrowing = pow(0.5, Double(pass))
            for key in orders.keys {
                guard let scale = scales[key.n] else { continue }
                let width = radiansOfSearch * scale * narrowing
                for slot in 0..<key.width {
                    if isCancelled() {
                        return AberrationResult(coefficients: working, score: best, evaluations: evaluations)
                    }
                    let index = key.offset + slot
                    let outcome = sweepThenBrent(centre: working[index], width: width,
                                                 points: sweepPoints) { value in
                        var trial = working
                        trial[index] = value
                        evaluations += 1
                        return score(stack: stack, coefficients: trial)
                    }
                    if let outcome = outcome, outcome.score > best {
                        working[index] = outcome.value
                        best = outcome.score
                        improved = true
                    }
                }
            }
            if !improved { break }
        }

        // --- stage 2: simplex over the whole vector, in scaled units ---
        var unit = [Double](repeating: 1, count: orders.coefficientCount)
        for key in orders.keys {
            guard let scale = scales[key.n] else { continue }
            for slot in 0..<key.width { unit[key.offset + slot] = scale }
        }

        let startPoint = (0..<orders.coefficientCount).map { working[$0] / unit[$0] }
        let simplex = ACBFRefinement.nelderMead(
            start: startPoint,
            step: 0.25,                       // a quarter radian of phase
            iterations: simplexIterations,
            isCancelled: isCancelled) { point in
                var trial = [Double](repeating: 0, count: point.count)
                for i in 0..<point.count { trial[i] = point[i] * unit[i] }
                evaluations += 1
                return score(stack: stack, coefficients: trial)
            }

        if let simplex = simplex, simplex.score > best {
            for i in 0..<orders.coefficientCount { working[i] = simplex.point[i] * unit[i] }
            best = simplex.score
        }

        return AberrationResult(coefficients: working, score: best, evaluations: evaluations)
    }

    // MARK: - Simplex

    /// Nelder–Mead, maximising. Derivative-free, which matters because the
    /// objective here is a reconstruction plus an image metric and there is no
    /// gradient to be had without autodiff.
    static func nelderMead(start: [Double], step: Double, iterations: Int,
                           isCancelled: () -> Bool = { false },
                           evaluate: ([Double]) -> Double)
        -> (point: [Double], score: Double)? {

        let n = start.count
        guard n > 0, step > 0 else { return nil }

        // n + 1 vertices: the start, plus one displaced along each axis.
        var points: [[Double]] = [start]
        for i in 0..<n {
            var vertex = start
            vertex[i] += step
            points.append(vertex)
        }
        var values = points.map { -evaluate($0) }      // minimise the negation

        func centroidExcluding(_ index: Int) -> [Double] {
            var c = [Double](repeating: 0, count: n)
            for (j, point) in points.enumerated() where j != index {
                for i in 0..<n { c[i] += point[i] }
            }
            for i in 0..<n { c[i] /= Double(n) }
            return c
        }

        for _ in 0..<iterations {
            if isCancelled() { break }

            let order = (0...n).sorted { values[$0] < values[$1] }
            let bestIndex = order[0], worstIndex = order[n], nextWorstIndex = order[n - 1]

            // Converged when the spread across the simplex is negligible.
            let spread = abs(values[worstIndex] - values[bestIndex])
            let magnitude = abs(values[bestIndex]) + abs(values[worstIndex]) + 1e-30
            if 2 * spread / magnitude < 1e-8 { break }

            let centroid = centroidExcluding(worstIndex)
            func combine(_ factor: Double) -> [Double] {
                var out = [Double](repeating: 0, count: n)
                for i in 0..<n { out[i] = centroid[i] + factor * (points[worstIndex][i] - centroid[i]) }
                return out
            }

            let reflected = combine(-1.0)
            let reflectedValue = -evaluate(reflected)

            if reflectedValue < values[bestIndex] {
                let expanded = combine(-2.0)
                let expandedValue = -evaluate(expanded)
                if expandedValue < reflectedValue {
                    points[worstIndex] = expanded; values[worstIndex] = expandedValue
                } else {
                    points[worstIndex] = reflected; values[worstIndex] = reflectedValue
                }
            } else if reflectedValue < values[nextWorstIndex] {
                points[worstIndex] = reflected; values[worstIndex] = reflectedValue
            } else {
                let contracted = combine(0.5)
                let contractedValue = -evaluate(contracted)
                if contractedValue < values[worstIndex] {
                    points[worstIndex] = contracted; values[worstIndex] = contractedValue
                } else {
                    // Shrink everything toward the best vertex.
                    let anchor = points[bestIndex]
                    for j in 0...n where j != bestIndex {
                        for i in 0..<n { points[j][i] = anchor[i] + 0.5 * (points[j][i] - anchor[i]) }
                        values[j] = -evaluate(points[j])
                    }
                }
            }
        }

        var bestIndex = 0
        for j in 1...n where values[j] < values[bestIndex] { bestIndex = j }
        return (points[bestIndex], -values[bestIndex])
    }

    // MARK: - Brent

    struct Extremum {
        var value: Double
        var score: Double
    }

    /// Brent's method, maximising. A parabola through the best three points is
    /// used where it is well behaved, and a golden-section step taken where it
    /// is not, so it converges quickly on a smooth peak without diverging on a
    /// rough one.
    static func brentMaximize(lower: Double, upper: Double,
                              tolerance: Double,
                              maxIterations: Int = 40,
                              isCancelled: () -> Bool = { false },
                              evaluate: (Double) -> Double) -> Extremum? {

        guard upper > lower, tolerance >= 0 else { return nil }
        let golden = 0.3819660112501051      // (3 − √5) / 2

        var a = lower, b = upper
        var x = a + golden * (b - a)
        var w = x, v = x
        var fx = -evaluate(x)                // Brent minimises; negate to maximise.
        var fw = fx, fv = fx
        var step = 0.0, previousStep = 0.0
        let floor = max(tolerance, 1e-12)

        for _ in 0..<maxIterations {
            if isCancelled() { break }
            let middle = 0.5 * (a + b)
            let tolerance1 = floor * abs(x) + 1e-12
            let tolerance2 = 2 * tolerance1
            if abs(x - middle) <= tolerance2 - 0.5 * (b - a) { break }

            var useGolden = true
            if abs(previousStep) > tolerance1 {
                // Fit a parabola through (x, fx), (w, fw), (v, fv).
                let r = (x - w) * (fx - fv)
                var q = (x - v) * (fx - fw)
                var p = (x - v) * q - (x - w) * r
                q = 2 * (q - r)
                if q > 0 { p = -p }
                q = abs(q)
                let stored = previousStep
                previousStep = step
                // Accept the vertex only if it stays inside the bracket and is
                // a real improvement on the last step.
                if abs(p) < abs(0.5 * q * stored), p > q * (a - x), p < q * (b - x) {
                    step = p / q
                    let candidate = x + step
                    if candidate - a < tolerance2 || b - candidate < tolerance2 {
                        step = x < middle ? tolerance1 : -tolerance1
                    }
                    useGolden = false
                }
            }
            if useGolden {
                previousStep = x < middle ? b - x : a - x
                step = golden * previousStep
            }

            let candidate = abs(step) >= tolerance1
                ? x + step
                : x + (step > 0 ? tolerance1 : -tolerance1)
            let value = -evaluate(candidate)

            if value <= fx {
                if candidate < x { b = x } else { a = x }
                v = w; fv = fw
                w = x; fw = fx
                x = candidate; fx = value
            } else {
                if candidate < x { a = candidate } else { b = candidate }
                if value <= fw || w == x {
                    v = w; fv = fw
                    w = candidate; fw = value
                } else if value <= fv || v == x || v == w {
                    v = candidate; fv = value
                }
            }
        }
        return Extremum(value: x, score: -fx)
    }
}
