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

    /// Refuse to build a virtual-image stack larger than this. Binning is the
    /// user's lever for staying under it.
    private let memoryBudgetBytes = 1_500_000_000

    public var pluginParameters: [[String: Any]] {
        return [
            FDSParameter.integer("detector", label: "Bright-field disc from", defaultValue: 0, minimum: 0, maximum: 32,
                                 help: "Detector number whose centre and outer radius mark the disc. 0 detects the disc from the mean pattern instead."),
            FDSParameter.integer("binning", label: "Detector binning", defaultValue: 2, minimum: 1, maximum: 16,
                                 help: "Group the disc into blocks this many detector pixels across. Larger is faster and needs less memory; too large reintroduces blur."),
            FDSParameter.number("maxShift", label: "Search range (scan px)", defaultValue: 10, minimum: 1, maximum: 200,
                                help: "Largest edge displacement to test, in scan pixels. Widen it if the best value lands at the end of the focus curve."),
            FDSParameter.integer("steps", label: "Search steps", defaultValue: 41, minimum: 5, maximum: 201,
                                 help: "Number of trial displacements across the search range."),
            FDSParameter.toggle("useManual", label: "Use a fixed displacement", defaultValue: false,
                                help: "Skip the search and apply the value below — useful for reproducing a previous run."),
            FDSParameter.number("edgeShift", label: "Fixed edge displacement (scan px)", defaultValue: 0, minimum: -200, maximum: 200),
            FDSParameter.choice("output", label: "Return", choices: ["Corrected image", "Focus curve", "Uncorrected sum"],
                                help: "Focus curve plots sharpness against displacement; Uncorrected sum is the plain BF image for comparison.")
        ]
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

        let binning = max(1, (parameters["binning"] as? NSNumber)?.intValue ?? 2)
        let useManual = (parameters["useManual"] as? NSNumber)?.boolValue ?? false
        let manualEdgeShift = Float((parameters["edgeShift"] as? NSNumber)?.doubleValue ?? 0)
        let maxShift = Float(abs((parameters["maxShift"] as? NSNumber)?.doubleValue ?? 10))
        let steps = max(5, (parameters["steps"] as? NSNumber)?.intValue ?? 41)
        let output = parameters["output"] as? String ?? "Corrected image"

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
        let grouping = buildGroups(centerX: centerX, centerY: centerY, radius: radius,
                                   binning: binning, patternWidth: patternWidth, patternHeight: patternHeight)
        guard grouping.groupCount > 0, grouping.discPixelCount > 0 else {
            return FDSResult.failure("The bright-field disc covers no detector pixels. Check the detector radius, or use 0 to detect the disc automatically.")
        }

        let scanPixels = scanWidth * scanHeight
        let stackBytes = grouping.groupCount * scanPixels * MemoryLayout<Float>.size
        guard stackBytes <= memoryBudgetBytes else {
            let suggested = binning * Int((Double(stackBytes) / Double(memoryBudgetBytes)).squareRoot().rounded(.up))
            return FDSResult.failure(String(format: "This would need %.1f GB for %d virtual images. Raise the detector binning to about %d and try again.",
                                            Double(stackBytes) / 1e9, grouping.groupCount, max(binning + 1, suggested)))
        }
        host.log("\(grouping.discPixelCount) disc pixels grouped into \(grouping.groupCount) virtual detectors (\(stackBytes / 1_048_576) MB).")

        // 3. One pass over the 4D data to build every virtual image at once.
        //    Everything after this works on the stack, not the raw dataset.
        guard var stack = buildVirtualImageStack(host: host, grouping: grouping,
                                                 patternPixels: patternPixels,
                                                 scanWidth: scanWidth, scanHeight: scanHeight) else {
            return nil   // cancelled
        }

        // 4. Find the displacement, unless the user pinned it.
        var edgeShift = manualEdgeShift
        var curveShifts: [Float] = []
        var curveSharpness: [Float] = []

        if !useManual || output == "Focus curve" {
            guard let search = searchEdgeShift(host: host, stack: &stack, grouping: grouping,
                                               scanWidth: scanWidth, scanHeight: scanHeight,
                                               maxShift: maxShift, steps: steps, radius: radius) else {
                return nil   // cancelled
            }
            curveShifts = search.shifts
            curveSharpness = search.sharpness
            if !useManual { edgeShift = search.best }
        }

        if host.isCancelled { return nil }

        // 5. Report the equivalent defocus when the file is calibrated.
        //    displacement[nm] = defocus[nm] · θ[rad]  with θ = t · diff_step/1000
        let scanStep = host.scanStepNanometers            // nm per scan pixel
        let diffStep = host.diffractionStepMilliradians   // mrad per detector pixel
        var defocusNote = ""
        if scanStep > 0, diffStep > 0, radius > 0 {
            let edgeAngle = Double(radius) * diffStep / 1000.0            // rad
            let defocus = Double(edgeShift) * scanStep / edgeAngle        // nm
            defocusNote = String(format: " Defocus %.1f nm (disc edge %.1f mrad).", defocus, Double(radius) * diffStep)
        }

        if output == "Focus curve" {
            guard !curveSharpness.isEmpty else {
                return FDSResult.failure("The focus curve is empty — try more search steps.")
            }
            return FDSResult.plot(
                x: curveShifts, y: curveSharpness,
                title: "tcBF Focus Curve — \(host.fileName)",
                xLabel: "Disc-edge displacement (scan pixels)",
                yLabel: "Normalised gradient energy",
                message: String(format: "Sharpest at %.2f scan px.%@ %d virtual detectors, binning %d.",
                                edgeShift, defocusNote, grouping.groupCount, binning)
            )
        }

        // 6. Final reconstruction at sub-pixel precision.
        let appliedShift = (output == "Uncorrected sum") ? 0 : edgeShift
        let image = reconstruct(stack: &stack, grouping: grouping,
                                scanWidth: scanWidth, scanHeight: scanHeight,
                                edgeShift: appliedShift, radius: radius)
        host.reportProgress(1.0)

        let title = (output == "Uncorrected sum")
            ? "Bright Field (uncorrected) — \(host.fileName)"
            : "Tilt-Corrected Bright Field — \(host.fileName)"

        let message: String
        if output == "Uncorrected sum" {
            message = String(format: "Plain sum of %d disc pixels, no tilt correction. For comparison the search found %.2f scan px.%@",
                             grouping.discPixelCount, edgeShift, defocusNote)
        } else {
            message = String(format: "Edge displacement %.2f scan px%@%@ %d disc pixels in %d virtual detectors, binning %d. Edges are normalised by coverage.",
                             edgeShift,
                             useManual ? " (fixed)" : " (from sharpness search)",
                             defocusNote,
                             grouping.discPixelCount, grouping.groupCount, binning)
        }

        return FDSResult.scanImage(image, rows: scanHeight, columns: scanWidth,
                                   title: title, message: message)
    }

    // MARK: - Bright-field disc

    private enum DiscResult {
        case found(centerX: Float, centerY: Float, radius: Float, source: String)
        case failed(String)
    }

    private func locateDisc(host: FDSHostContext, parameters: [String: Any],
                            patternWidth: Int, patternHeight: Int) -> DiscResult {

        let detectorNumber = (parameters["detector"] as? NSNumber)?.intValue ?? 0

        if detectorNumber > 0 {
            let index = detectorNumber - 1
            guard index < host.detectorCount, let info = host.detectorInfo(at: index) else {
                return .failed("Detector \(detectorNumber) does not exist; the dataset has \(host.detectorCount).")
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
            return .failed("The mean diffraction pattern has no contrast, so the bright-field disc cannot be found. Pick a detector explicitly instead.")
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
            return .failed("Only \(count) detector pixels are above the bright-field threshold. Pick a detector explicitly instead.")
        }

        let radius = (Double(count) / Double.pi).squareRoot()
        return .found(centerX: Float(sumX / Double(count)),
                      centerY: Float(sumY / Double(count)),
                      radius: Float(radius),
                      source: "auto-detected from \(sampled) patterns")
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
            pixelIndices.append(contentsOf: pixels)
            groupStart.append(pixelIndices.count)
        }

        return Grouping(groupCount: tiltX.count,
                        discPixelCount: pixelIndices.count,
                        tiltX: tiltX, tiltY: tiltY,
                        pixelIndices: pixelIndices, groupStart: groupStart)
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

            grouping.pixelIndices.withUnsafeBufferPointer { indices in
                grouping.groupStart.withUnsafeBufferPointer { starts in
                    for row in 0..<scanHeight {
                        if host.isCancelled { return }

                        for column in 0..<scanWidth {
                            let probe = row * scanWidth + column
                            guard host.copyPattern(row: row, column: column,
                                                   into: pattern, capacity: patternPixels) else { continue }

                            for group in 0..<grouping.groupCount {
                                var sum: Float = 0
                                for slot in starts[group]..<starts[group + 1] {
                                    sum += pattern[indices[slot]]
                                }
                                stackBase[group * scanPixels + probe] = sum
                            }
                        }

                        // Building the stack is the only pass over the raw data,
                        // so it gets the bulk of the progress bar.
                        host.reportProgress(0.7 * Double(row + 1) / Double(scanHeight))
                    }
                }
            }
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
        var normalised = [Float](repeating: 0, count: scanPixels)

        let fullCoverage = 0.99 * Float(grouping.groupCount)

        for step in 0..<steps {
            if host.isCancelled { return nil }

            let edgeShift = -maxShift + 2 * maxShift * Float(step) / Float(steps - 1)
            shifts[step] = edgeShift

            // Whole-pixel sampling is enough to find the peak and is several
            // times faster; the final image is done bilinearly.
            accumulate(stack: &stack, grouping: grouping, scanWidth: scanWidth, scanHeight: scanHeight,
                       edgeShift: edgeShift, radius: radius, bilinear: false,
                       accumulator: &accumulator, coverage: &coverage)

            normalise(accumulator: accumulator, coverage: coverage, into: &normalised)
            sharpness[step] = gradientEnergy(normalised, coverage: coverage,
                                             width: scanWidth, height: scanHeight,
                                             minCoverage: fullCoverage)

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
                            edgeShift: Float, radius: Float, bilinear: Bool,
                            accumulator: inout [Float], coverage: inout [Float]) {

        let scanPixels = scanWidth * scanHeight
        let k = radius > 0 ? edgeShift / radius : 0   // scan px per detector px

        for i in 0..<scanPixels { accumulator[i] = 0; coverage[i] = 0 }

        stack.withUnsafeMutableBufferPointer { stackBuffer in
            accumulator.withUnsafeMutableBufferPointer { accBuffer in
                coverage.withUnsafeMutableBufferPointer { covBuffer in
                    guard let stackBase = stackBuffer.baseAddress,
                          let acc = accBuffer.baseAddress,
                          let cov = covBuffer.baseAddress else { return }

                    for group in 0..<grouping.groupCount {
                        let source = stackBase + group * scanPixels
                        let shiftX = k * grouping.tiltX[group]
                        let shiftY = k * grouping.tiltY[group]

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
    private func normalise(accumulator: [Float], coverage: [Float], into result: inout [Float]) {
        for i in 0..<result.count {
            let weight = coverage[i]
            result[i] = weight > 0 ? accumulator[i] / weight : 0
        }
    }

    // MARK: - Sharpness

    /// Mean squared gradient divided by the squared mean — scale-free, so trial
    /// displacements are compared on how sharp the image is, not how bright.
    /// Only fully covered pixels count, keeping partly filled borders out of it.
    private func gradientEnergy(_ image: [Float], coverage: [Float],
                                width: Int, height: Int, minCoverage: Float) -> Float {

        guard width > 2, height > 2 else { return 0 }
        var energy = 0.0
        var total = 0.0
        var counted = 0

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                guard coverage[i] >= minCoverage,
                      coverage[i - 1] >= minCoverage, coverage[i + 1] >= minCoverage,
                      coverage[i - width] >= minCoverage, coverage[i + width] >= minCoverage else { continue }
                let gx = Double(image[i + 1] - image[i - 1])
                let gy = Double(image[i + width] - image[i - width])
                energy += gx * gx + gy * gy
                total += Double(image[i])
                counted += 1
            }
        }

        guard counted > 0 else { return 0 }
        let mean = total / Double(counted)
        guard mean > 0 else { return 0 }
        return Float(energy / Double(counted) / (mean * mean))
    }

    // MARK: - Reconstruction

    private func reconstruct(stack: inout [Float], grouping: Grouping,
                             scanWidth: Int, scanHeight: Int,
                             edgeShift: Float, radius: Float) -> [Float] {

        let scanPixels = scanWidth * scanHeight
        var accumulator = [Float](repeating: 0, count: scanPixels)
        var coverage = [Float](repeating: 0, count: scanPixels)

        accumulate(stack: &stack, grouping: grouping, scanWidth: scanWidth, scanHeight: scanHeight,
                   edgeShift: edgeShift, radius: radius, bilinear: true,
                   accumulator: &accumulator, coverage: &coverage)

        // Rescale to the intensity a plain BF sum would have given, so the
        // numbers stay comparable with the app's own integrating detector.
        var maximumCoverage: Float = 0
        for value in coverage where value > maximumCoverage { maximumCoverage = value }

        var result = [Float](repeating: 0, count: scanPixels)
        for i in 0..<scanPixels {
            result[i] = coverage[i] > 0 ? accumulator[i] * maximumCoverage / coverage[i] : 0
        }
        return result
    }
}
