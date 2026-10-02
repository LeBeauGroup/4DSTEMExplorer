//
//  SingleElectronHistogramPlugin.swift
//  4DSTEM Explorer — example plugin
//
//  Single-electron event histogram for direct electron detectors.
//
//  What it measures
//  ----------------
//  A primary electron landing on a direct detector deposits charge that spreads
//  over a small group of neighbouring pixels. Reading any one of those pixels
//  tells you little; the quantity that is quantised — and therefore useful for
//  calibrating gain — is the *sum* over the whole cluster.
//
//  So the plugin: thresholds each diffraction pattern well above the read noise,
//  groups the surviving pixels into contiguous clusters, integrates each cluster,
//  and histograms those integrals. The first peak is the mean signal of one
//  electron; peaks at 2× and 3× are coincident events.
//
//  Why an annular detector is required
//  -----------------------------------
//  Individual events can only be separated where the dose is sparse enough that
//  charge clouds rarely overlap. Inside the bright-field disc the occupancy is
//  orders of magnitude too high, and clusters merge into a continuum that has no
//  single-electron peak at all. The plugin therefore insists on an annular
//  detector, which geometrically excludes the disc.
//

import Foundation

@objc(SingleElectronHistogramPlugin)
public final class SingleElectronHistogramPlugin: NSObject, FDSPlugin {

    public var pluginIdentifier: String { return "group.lebeau.4dstem.plugin.singleelectronhistogram" }
    public var pluginName: String { return "Single-Electron Histogram" }
    public var pluginSummary: String {
        return "Finds individual electron events on an annular detector, integrates each charge cluster, and histograms the totals. The first peak is the single-electron level. Needs an ADF or annular detector so the bright-field disc is excluded."
    }
    public var pluginAPIVersion: Int { return 1 }

    /// Cap on stored event integrals, ~24 MB. Beyond this the histogram is built
    /// from the events collected so far and the result says so.
    private let eventCap = 6_000_000

    /// How many patterns to sample when estimating the noise floor.
    private let noiseSampleTarget = 256

    public var pluginParameters: [[String: Any]] {
        return [
            FDSParameter.integer("detector", label: "Detector", defaultValue: 0, minimum: 0, maximum: 32,
                                 help: "0 uses the selected annular detector. Otherwise give a detector number from the Detectors table. It must be ADF or annular — a bright-field detector cannot resolve single events."),
            FDSParameter.number("thresholdSigma", label: "Threshold (σ above noise)", defaultValue: 4.0, minimum: 1, maximum: 20,
                                help: "A pixel joins a cluster when it exceeds the noise floor by this many standard deviations. Lower picks up more of each charge cloud but starts admitting noise."),
            FDSParameter.choice("connectivity", label: "Cluster connectivity", choices: ["8 (include diagonals)", "4 (orthogonal only)"],
                                help: "Which neighbours count as part of the same charge cloud."),
            FDSParameter.integer("maxClusterSize", label: "Largest cluster (px)", defaultValue: 12, minimum: 1, maximum: 200,
                                 help: "Clusters bigger than this are discarded as coincident events or X-ray hits rather than single electrons."),
            FDSParameter.toggle("excludeEdgeEvents", label: "Discard events at the detector edge", defaultValue: true,
                                help: "A cloud straddling the edge of the aperture is only partly measured and would bias the histogram low."),
            FDSParameter.integer("bins", label: "Histogram bins", defaultValue: 128, minimum: 16, maximum: 1024),
            FDSParameter.integer("stride", label: "Scan stride", defaultValue: 1, minimum: 1, maximum: 16,
                                 help: "Sample every nth probe position. Raise it for a quick look at a large scan."),
            FDSParameter.choice("output", label: "Return", choices: ["Electron histogram", "Counted ADF image", "Cluster size histogram"],
                                help: "Counted ADF image maps events per probe position — a counted, dose-efficient dark-field image.")
        ]
    }

    // MARK: - Run

    public func run(host: FDSHostContext, parameters: [String: Any]) -> [String: Any]? {

        let scanWidth = host.scanWidth
        let scanHeight = host.scanHeight
        let patternWidth = host.patternWidth
        let patternHeight = host.patternHeight
        let patternPixels = host.patternPixelCount

        guard scanWidth > 0, scanHeight > 0, patternPixels > 0 else {
            return FDSResult.failure("No 4D dataset is open.")
        }

        // Everything below works over this, not over the whole scan.
        let region = ScanRegion.from(host: host, scanWidth: scanWidth, scanHeight: scanHeight)
        let regionNote = region.describe(scanWidth: scanWidth, scanHeight: scanHeight)

        // 1. Resolve the detector and enforce the annular requirement.
        let detectorIndex: Int
        switch resolveDetector(host: host, parameters: parameters) {
        case .failure(let reason): return FDSResult.failure(reason)
        case .success(let index): detectorIndex = index
        }

        guard let maskData = host.detectorMaskData(at: detectorIndex) else {
            return FDSResult.failure("Could not build the mask for that detector.")
        }
        let mask = FDSFloatArray(maskData)
        guard mask.count == patternPixels else {
            return FDSResult.failure("Detector mask is \(mask.count) values but patterns are \(patternPixels).")
        }

        var maskedIndices = [Int]()
        maskedIndices.reserveCapacity(patternPixels / 4)
        for i in 0..<patternPixels where mask[i] > 0.5 { maskedIndices.append(i) }
        guard maskedIndices.count >= 16 else {
            return FDSResult.failure("The detector covers only \(maskedIndices.count) pixels — too few to gather event statistics.")
        }

        // `insideMask` gives O(1) neighbour tests in the flood fill.
        var insideMask = [Bool](repeating: false, count: patternPixels)
        for i in maskedIndices { insideMask[i] = true }

        let thresholdSigma = Float((parameters["thresholdSigma"] as? NSNumber)?.doubleValue ?? 4)
        let maxClusterSize = Swift.max(1, (parameters["maxClusterSize"] as? NSNumber)?.intValue ?? 12)
        let excludeEdge = (parameters["excludeEdgeEvents"] as? NSNumber)?.boolValue ?? true
        let binCount = Swift.max(16, (parameters["bins"] as? NSNumber)?.intValue ?? 128)
        let stride = Swift.max(1, (parameters["stride"] as? NSNumber)?.intValue ?? 1)
        let output = parameters["output"] as? String ?? "Electron histogram"
        let diagonal = !(parameters["connectivity"] as? String ?? "").hasPrefix("4")

        // 2. Noise floor from a sample of patterns, so the threshold adapts to
        //    the detector's own offset and read noise rather than being guessed.
        guard let noise = estimateNoise(host: host, maskedIndices: maskedIndices, region: region,
                                        patternPixels: patternPixels,
                                        scanWidth: scanWidth, scanHeight: scanHeight) else {
            return nil   // cancelled
        }
        // A threshold in units of noise where there is noise to measure, and
        // half a quantum where the detector counts instead. The second case is
        // not a degraded version of the first: for a counting detector half way
        // between nought and one electron is exactly the right place to cut,
        // and no number of sigmas would find it.
        let threshold: Float
        if noise.sigma > 0 {
            threshold = noise.background + thresholdSigma * noise.sigma
            host.log(String(format: "Noise floor %.4g, sigma %.4g, threshold %.4g",
                            noise.background, noise.sigma, threshold))
        } else if let quantum = noise.quantum, quantum > 0 {
            threshold = noise.background + quantum * 0.5
            host.log(String(format: "Counting detector: no spread to measure (most pixels read %.4g), so the threshold is half the smallest step above it, %.4g → %.4g",
                            noise.background, quantum, threshold))
        } else {
            return FDSResult.failure("Every pixel inside this aperture holds the same value, so there is nothing to tell an electron from an empty pixel.")
        }

        // 3. Sweep the scan, finding and integrating clusters.
        guard let sweep = collectEvents(host: host, region: region,
                                        maskedIndices: maskedIndices, insideMask: insideMask,
                                        patternWidth: patternWidth, patternHeight: patternHeight,
                                        patternPixels: patternPixels,
                                        scanWidth: scanWidth, scanHeight: scanHeight, stride: stride,
                                        threshold: threshold, background: noise.background,
                                        maxClusterSize: maxClusterSize,
                                        excludeEdge: excludeEdge, diagonal: diagonal) else {
            return nil   // cancelled
        }

        guard !sweep.integrals.isEmpty else {
            return FDSResult.failure(String(format: "No electron events were found above %.4g (noise floor %.4g + %.1fσ). Lower the threshold, or check that this detector sees signal.",
                                            threshold, noise.background, thresholdSigma))
        }

        let sampledProbes = sweep.outputWidth * sweep.outputHeight
        let eventsPerPattern = Double(sweep.totalEvents) / Double(Swift.max(1, sampledProbes))
        let occupancy = eventsPerPattern / Double(maskedIndices.count)

        // 4. Build the requested output.
        switch output {
        case "Counted ADF image":
            return FDSResult.scanImage(
                sweep.eventsPerProbe, rows: sweep.outputHeight, columns: sweep.outputWidth,
                title: "Counted ADF — \(host.fileName)",
                message: String(format: "%d events, %.2f per pattern. Threshold %.4g (%.1fσ above %.4g).%@",
                                sweep.totalEvents, eventsPerPattern, threshold, thresholdSigma, noise.background,
                                strideNote(stride) + regionNote))

        case "Cluster size histogram":
            let maxSize = sweep.clusterSizes.count - 1
            var sizes = [Float](), counts = [Float]()
            for size in 1...Swift.max(1, maxSize) where size < sweep.clusterSizes.count {
                sizes.append(Float(size))
                counts.append(Float(sweep.clusterSizes[size]))
            }
            let mean = meanClusterSize(sweep.clusterSizes)
            return FDSResult.plot(
                x: sizes, y: counts,
                title: "Cluster Sizes — \(host.fileName)",
                xLabel: "Pixels per event",
                yLabel: "Events",
                message: String(format: "%d events, mean %.2f px per charge cloud. A mean near 1 suggests the threshold is too high to capture the full cloud.%@",
                                sweep.totalEvents, mean, regionNote))

        default:
            let histogram = buildHistogram(sweep.integrals, binCount: binCount)
            let peak = singleElectronPeak(centres: histogram.centres, counts: histogram.counts)

            var notes: [String] = []
            notes.append(String(format: "%d events over %d patterns (%.2f per pattern).", sweep.totalEvents, sampledProbes, eventsPerPattern))
            if let peak = peak {
                notes.append(String(format: "Single-electron level ≈ %.4g.", peak))
            } else {
                notes.append("No clear peak — adjust the threshold or gather more events.")
            }
            notes.append(String(format: "Threshold %.4g = %.4g + %.1fσ·%.4g.", threshold, noise.background, thresholdSigma, noise.sigma))
            if sweep.rejectedLarge > 0 {
                notes.append("\(sweep.rejectedLarge) clusters over \(maxClusterSize) px discarded.")
            }
            if sweep.rejectedEdge > 0 {
                notes.append("\(sweep.rejectedEdge) discarded at the aperture edge.")
            }
            if occupancy > 0.02 {
                notes.append(String(format: "Occupancy is %.1f%% of detector pixels — high enough that clouds overlap and the peak will read high. Use a lower dose or a detector further out.", occupancy * 100))
            }
            if sweep.capped {
                notes.append("Event cap reached; histogram covers the first \(sweep.integrals.count) events.")
            }
            notes.append(strideNote(stride).trimmingCharacters(in: .whitespaces))
            notes.append(regionNote.trimmingCharacters(in: .whitespaces))

            return FDSResult.plot(
                x: histogram.centres, y: histogram.counts,
                title: "Single-Electron Histogram — \(host.fileName)",
                xLabel: "Integrated cluster signal",
                yLabel: "Events",
                message: notes.filter { !$0.isEmpty }.joined(separator: " "))
        }
    }

    private func strideNote(_ stride: Int) -> String {
        return stride > 1 ? " Scan stride \(stride)." : ""
    }

    // MARK: - Detector

    private enum DetectorResolution {
        case success(Int)
        case failure(String)
    }

    private func resolveDetector(host: FDSHostContext, parameters: [String: Any]) -> DetectorResolution {
        let requested = (parameters["detector"] as? NSNumber)?.intValue ?? 0
        guard host.detectorCount > 0 else {
            return .failure("No detectors are configured.")
        }

        func annular(_ shape: String) -> Bool { return shape == "adf" || shape == "af" }

        func describe(_ shape: String) -> String {
            switch shape {
            case "bf":    return "a bright-field disc"
            case "point": return "a single point"
            default:      return "a \(shape) detector"
            }
        }

        if requested > 0 {
            let index = requested - 1
            guard index < host.detectorCount, let info = host.detectorInfo(at: index) else {
                return .failure("Detector \(requested) does not exist; the dataset has \(host.detectorCount).")
            }
            let shape = info[FDSDetectorKey.shape] as? String ?? ""
            guard annular(shape) else {
                return .failure("Detector \(requested) is \(describe(shape)). Single-electron counting needs an annular detector (ADF or AF) so the bright-field disc — where events overlap far too densely to separate — is excluded.")
            }
            if let inner = info[FDSDetectorKey.innerRadius] as? Double, inner < 1 {
                return .failure("Detector \(requested) has an inner radius of \(String(format: "%.1f", inner)) px, so it still covers the bright-field disc. Increase the inner radius past the disc edge.")
            }
            return .success(index)
        }

        // Prefer a selected annular detector, then any annular detector.
        var firstAnnular: Int? = nil
        var sawSelectedNonAnnular: String? = nil

        for index in 0..<host.detectorCount {
            guard let info = host.detectorInfo(at: index) else { continue }
            let shape = info[FDSDetectorKey.shape] as? String ?? ""
            let selected = (info[FDSDetectorKey.selected] as? Bool) ?? false
            if annular(shape) {
                if selected { return .success(index) }
                if firstAnnular == nil { firstAnnular = index }
            } else if selected, sawSelectedNonAnnular == nil {
                sawSelectedNonAnnular = describe(shape)
            }
        }

        if let index = firstAnnular {
            return .success(index)
        }
        if let shape = sawSelectedNonAnnular {
            return .failure("The selected detector is \(shape). Single-electron counting needs an annular detector so the bright-field disc is excluded — set the detector shape to ADF or AF, put its inner radius outside the disc, and run this again.")
        }
        return .failure("No annular detector is configured. Add an ADF or AF detector whose inner radius lies outside the bright-field disc, then run this again.")
    }

    // MARK: - Noise floor

    private struct Noise {
        var background: Float
        var sigma: Float
        /// The smallest step the data actually takes above the background.
        ///
        /// A counting detector is quantised and mostly empty, so more than half
        /// its pixels hold exactly the same value and both the median and the
        /// median absolute deviation come out at zero — there is no spread to
        /// measure because most of the sample is one number. The step between
        /// no electron and one electron is what separates signal from nothing in
        /// that case, and unlike a sigma it survives the data being rescaled.
        var quantum: Float?
    }

    /// Median and MAD-derived sigma over aperture pixels from a sample of
    /// patterns. Robust statistics because a few percent of the pixels carry
    /// electron events, which would inflate an ordinary mean and deviation.
    private func estimateNoise(host: FDSHostContext, maskedIndices: [Int], region: ScanRegion,
                               patternPixels: Int, scanWidth: Int, scanHeight: Int) -> Noise? {

        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: patternPixels)
        defer { buffer.deallocate() }

        let totalProbes = region.positions
        let step = Swift.max(1, totalProbes / noiseSampleTarget)

        var samples = [Float]()
        samples.reserveCapacity(Swift.min(noiseSampleTarget, totalProbes) * maskedIndices.count)

        var probe = 0
        while probe < totalProbes {
            if host.isCancelled { return nil }
            let row = region.row + probe / region.width
            let column = region.column + probe % region.width
            if host.copyPattern(row: row, column: column, into: buffer, capacity: patternPixels) {
                for index in maskedIndices { samples.append(buffer[index]) }
            }
            probe += step
        }

        guard samples.count > 8 else { return nil }
        samples.sort()
        let background = samples[samples.count / 2]

        var deviations = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count { deviations[i] = abs(samples[i] - background) }
        deviations.sort()
        let mad = deviations[deviations.count / 2]

        // The smallest step the data takes away from the background, which is
        // what a quantised detector offers in place of a spread. Taken from the
        // sorted deviations, so it is one pass over data already in hand.
        let quantum = deviations.first { $0 > 0 }

        host.reportProgress(0.1)
        // 1.4826 converts the median absolute deviation to a Gaussian sigma.
        return Noise(background: background, sigma: mad * 1.4826, quantum: quantum)
    }

    // MARK: - Event finding

    /// The probe positions to work over.
    ///
    /// A marquee on the computed image means the user has pointed at something,
    /// and on a counted detector that is usually the point: the single-electron
    /// level is a property of the detector, but the event rate is a property of
    /// what the beam is on. Averaging it over a whole scan that includes vacuum
    /// answers a question nobody asked.
    private struct ScanRegion {
        var column: Int, row: Int, width: Int, height: Int
        var positions: Int { return width * height }

        /// The marquee if there is one, clipped to the scan, otherwise all of it.
        static func from(host: FDSHostContext, scanWidth: Int, scanHeight: Int) -> ScanRegion {
            let whole = ScanRegion(column: 0, row: 0, width: scanWidth, height: scanHeight)
            let column = host.selectionColumn, row = host.selectionRow
            let width = host.selectionWidth, height = host.selectionHeight
            guard column >= 0, row >= 0, width > 0, height > 0 else { return whole }

            let x0 = Swift.max(0, Swift.min(column, scanWidth - 1))
            let y0 = Swift.max(0, Swift.min(row, scanHeight - 1))
            let x1 = Swift.min(scanWidth, column + width)
            let y1 = Swift.min(scanHeight, row + height)
            guard x1 > x0, y1 > y0 else { return whole }
            return ScanRegion(column: x0, row: y0, width: x1 - x0, height: y1 - y0)
        }

        var isWholeScan: Bool { return column == 0 && row == 0 }

        func describe(scanWidth: Int, scanHeight: Int) -> String {
            if width == scanWidth && height == scanHeight { return "" }
            return String(format: " Selection only: %d×%d at (%d, %d), %d positions.",
                          width, height, column, row, positions)
        }
    }

    private struct Sweep {
        var integrals: [Float]
        var clusterSizes: [Int]      // indexed by pixel count
        var eventsPerProbe: [Float]
        var outputWidth: Int
        var outputHeight: Int
        var totalEvents: Int
        var rejectedLarge: Int
        var rejectedEdge: Int
        var capped: Bool
    }

    private func collectEvents(host: FDSHostContext, region: ScanRegion,
                               maskedIndices: [Int], insideMask: [Bool],
                               patternWidth: Int, patternHeight: Int, patternPixels: Int,
                               scanWidth: Int, scanHeight: Int, stride: Int,
                               threshold: Float, background: Float, maxClusterSize: Int,
                               excludeEdge: Bool, diagonal: Bool) -> Sweep? {

        let outputWidth = (region.width + stride - 1) / stride
        let outputHeight = (region.height + stride - 1) / stride

        var integrals = [Float]()
        integrals.reserveCapacity(1 << 16)
        var clusterSizes = [Int](repeating: 0, count: maxClusterSize + 2)
        var eventsPerProbe = [Float](repeating: 0, count: outputWidth * outputHeight)

        var totalEvents = 0, rejectedLarge = 0, rejectedEdge = 0, capped = false

        let pattern = UnsafeMutablePointer<Float>.allocate(capacity: patternPixels)
        defer { pattern.deallocate() }

        var above = [Bool](repeating: false, count: patternPixels)
        var visited = [Bool](repeating: false, count: patternPixels)
        var stack = [Int]()
        stack.reserveCapacity(256)
        var cluster = [Int]()
        cluster.reserveCapacity(64)

        let neighbours: [(Int, Int)] = diagonal
            ? [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
            : [(-1, 0), (0, -1), (0, 1), (1, 0)]

        var outputRow = 0
        for row in Swift.stride(from: region.row, to: region.row + region.height, by: stride) {
            if host.isCancelled { return nil }
            var position = outputRow * outputWidth

            for column in Swift.stride(from: region.column,
                                       to: region.column + region.width, by: stride) {
                guard host.copyPattern(row: row, column: column, into: pattern, capacity: patternPixels) else {
                    position += 1
                    continue
                }

                // Only aperture pixels are touched, so clearing is proportional
                // to the aperture rather than the whole detector.
                for index in maskedIndices {
                    above[index] = pattern[index] >= threshold
                    visited[index] = false
                }

                var probeEvents = 0

                for seed in maskedIndices where above[seed] && !visited[seed] {
                    visited[seed] = true
                    stack.removeAll(keepingCapacity: true)
                    cluster.removeAll(keepingCapacity: true)
                    stack.append(seed)

                    var touchesEdge = false

                    while let index = stack.popLast() {
                        cluster.append(index)
                        let r = index / patternWidth
                        let c = index % patternWidth

                        for (dr, dc) in neighbours {
                            let nr = r + dr, nc = c + dc
                            guard nr >= 0, nr < patternHeight, nc >= 0, nc < patternWidth else {
                                touchesEdge = true
                                continue
                            }
                            let neighbour = nr * patternWidth + nc
                            guard insideMask[neighbour] else {
                                // The cloud may continue outside the aperture,
                                // where this run cannot measure it.
                                touchesEdge = true
                                continue
                            }
                            if above[neighbour] && !visited[neighbour] {
                                visited[neighbour] = true
                                stack.append(neighbour)
                            }
                        }
                    }

                    if cluster.count > maxClusterSize {
                        rejectedLarge += 1
                        continue
                    }
                    if excludeEdge && touchesEdge {
                        rejectedEdge += 1
                        continue
                    }

                    // Integrate the cloud: the quantised quantity is the sum
                    // over its pixels, not any single pixel's value. The noise
                    // floor comes off each pixel first — leaving it in would add
                    // the detector's offset once per pixel, making the integral
                    // scale with cluster size rather than deposited charge.
                    var sum: Float = 0
                    for index in cluster { sum += pattern[index] - background }

                    totalEvents += 1
                    probeEvents += 1
                    clusterSizes[Swift.min(cluster.count, clusterSizes.count - 1)] += 1
                    if integrals.count < eventCap {
                        integrals.append(sum)
                    } else {
                        capped = true
                    }
                }

                eventsPerProbe[position] = Float(probeEvents)
                position += 1
            }

            outputRow += 1
            host.reportProgress(0.1 + 0.85 * Double(outputRow) / Double(outputHeight))
        }

        return Sweep(integrals: integrals, clusterSizes: clusterSizes,
                     eventsPerProbe: eventsPerProbe,
                     outputWidth: outputWidth, outputHeight: outputHeight,
                     totalEvents: totalEvents, rejectedLarge: rejectedLarge,
                     rejectedEdge: rejectedEdge, capped: capped)
    }

    // MARK: - Histogram

    private func buildHistogram(_ values: [Float], binCount: Int) -> (centres: [Float], counts: [Float]) {
        var sorted = values
        sorted.sort()

        // Anchored at zero rather than at the smallest event.
        //
        // The quantity on this axis is charge collected, and zero is where it
        // genuinely starts — so the distance from the origin to the first peak
        // is the single-electron level, readable straight off the plot. Starting
        // at the smallest event instead slid the whole axis by an amount that
        // depended on the threshold, which made two runs of the same data
        // impossible to compare.
        let low: Float = 0
        // Trim the extreme tail so a handful of coincidences do not compress the
        // single-electron peak into the first two bins.
        let high = sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.999))]
        let span = (high - low) > 0 ? (high - low) : 1

        var counts = [Float](repeating: 0, count: binCount)
        let scale = Float(binCount) / span
        for value in values {
            var bin = Int((value - low) * scale)
            if bin < 0 { bin = 0 }
            if bin >= binCount { bin = binCount - 1 }   // overflow into the last bin
            counts[bin] += 1
        }

        var centres = [Float](repeating: 0, count: binCount)
        for bin in 0..<binCount {
            centres[bin] = low + (Float(bin) + 0.5) * span / Float(binCount)
        }
        return (centres, counts)
    }

    /// Position of the single-electron peak, refined by a parabola through the
    /// tallest bin and its neighbours. The first bins are skipped: they sit on
    /// the threshold, where partially captured clouds pile up.
    private func singleElectronPeak(centres: [Float], counts: [Float]) -> Float? {
        guard counts.count > 6 else { return nil }
        let start = Swift.max(1, counts.count / 20)

        var best = start
        for bin in start..<counts.count where counts[bin] > counts[best] { best = bin }
        guard counts[best] > 0 else { return nil }

        guard best > 0, best < counts.count - 1 else { return centres[best] }
        let left = counts[best - 1], peak = counts[best], right = counts[best + 1]
        let denominator = left - 2 * peak + right
        guard abs(denominator) > .ulpOfOne else { return centres[best] }

        let delta = 0.5 * (left - right) / denominator
        guard abs(delta) <= 1 else { return centres[best] }
        let width = centres.count > 1 ? centres[1] - centres[0] : 0
        return centres[best] + delta * width
    }

    private func meanClusterSize(_ clusterSizes: [Int]) -> Double {
        var total = 0, weighted = 0
        for (size, count) in clusterSizes.enumerated() where count > 0 {
            total += count
            weighted += size * count
        }
        return total > 0 ? Double(weighted) / Double(total) : 0
    }
}
