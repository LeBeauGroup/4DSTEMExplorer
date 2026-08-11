//
//  DetectorVariancePlugin.swift
//  4DSTEM Explorer — example plugin
//
//  For every probe position, measures how uneven the intensity is inside a
//  detector aperture — the normalised variance used in fluctuation electron
//  microscopy. Demonstrates the full-stack shape of plugin: sweep every probe
//  position through the fast copy path, report progress, honour cancellation,
//  and return one value per position as a computed image.
//

import Foundation

@objc(DetectorVariancePlugin)
public final class DetectorVariancePlugin: NSObject, FDSPlugin {

    public var pluginIdentifier: String { return "group.lebeau.4dstem.plugin.detectorvariance" }
    public var pluginName: String { return "Detector Variance Map" }
    public var pluginSummary: String { return "Variance of the intensity inside a detector aperture, mapped over the scan. Bright where the pattern within the aperture is structured, dark where it is uniform." }
    public var pluginAPIVersion: Int { return 1 }

    public var pluginParameters: [[String: Any]] {
        return [
            FDSParameter.integer("detector", label: "Detector", defaultValue: 1, minimum: 1, maximum: 32,
                                 help: "Which detector's aperture to measure inside, numbered as in the Detectors table."),
            FDSParameter.toggle("normalize", label: "Normalise by mean²", defaultValue: true,
                                help: "Divides the variance by the squared mean, giving the dose-independent quantity usually plotted in fluctuation EM."),
            FDSParameter.integer("stride", label: "Scan stride", defaultValue: 1, minimum: 1, maximum: 16,
                                 help: "Sample every nth probe position. Use a larger value for a quick preview of a big scan.")
        ]
    }

    public func run(host: FDSHostContext, parameters: [String: Any]) -> [String: Any]? {

        let scanWidth = host.scanWidth
        let scanHeight = host.scanHeight
        let patternPixels = host.patternPixelCount
        guard scanWidth > 0, scanHeight > 0, patternPixels > 0 else {
            return FDSResult.failure("No 4D dataset is open.")
        }

        let detectorNumber = (parameters["detector"] as? NSNumber)?.intValue ?? 1
        let detectorIndex = detectorNumber - 1
        guard detectorIndex >= 0, detectorIndex < host.detectorCount else {
            return FDSResult.failure("Detector \(detectorNumber) does not exist; the dataset has \(host.detectorCount).")
        }
        guard let maskData = host.detectorMaskData(at: detectorIndex) else {
            return FDSResult.failure("Could not build the mask for detector \(detectorNumber).")
        }

        let mask = FDSFloatArray(maskData)
        guard mask.count == patternPixels else {
            return FDSResult.failure("Detector mask is \(mask.count) values but patterns are \(patternPixels).")
        }

        // Precompute the pixel offsets inside the aperture so the inner loop
        // touches only those, rather than testing the mask every time.
        var indices = [Int]()
        indices.reserveCapacity(patternPixels / 4)
        for i in 0..<patternPixels where mask[i] > 0.5 {
            indices.append(i)
        }
        guard indices.count > 1 else {
            return FDSResult.failure("Detector \(detectorNumber) covers \(indices.count) pixel(s); variance needs at least two.")
        }
        host.log("Detector \(detectorNumber) covers \(indices.count) of \(patternPixels) pattern pixels.")

        let normalize = (parameters["normalize"] as? NSNumber)?.boolValue ?? true
        let stride = max(1, (parameters["stride"] as? NSNumber)?.intValue ?? 1)

        let outWidth = (scanWidth + stride - 1) / stride
        let outHeight = (scanHeight + stride - 1) / stride
        var output = [Float](repeating: 0, count: outWidth * outHeight)

        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: patternPixels)
        defer { buffer.deallocate() }

        let inverseCount = 1.0 / Double(indices.count)
        var position = 0
        var outputRow = 0

        for row in Swift.stride(from: 0, to: scanHeight, by: stride) {
            // Cancellation is checked per scan row: often enough to feel
            // responsive, rarely enough not to cost anything.
            if host.isCancelled { return nil }

            position = outputRow * outWidth
            for column in Swift.stride(from: 0, to: scanWidth, by: stride) {
                guard host.copyPattern(row: row, column: column, into: buffer, capacity: patternPixels) else {
                    position += 1
                    continue
                }

                var sum = 0.0
                var sumSquares = 0.0
                for index in indices {
                    let value = Double(buffer[index])
                    sum += value
                    sumSquares += value * value
                }

                let mean = sum * inverseCount
                let variance = max(0.0, sumSquares * inverseCount - mean * mean)

                if normalize {
                    output[position] = mean > 0 ? Float(variance / (mean * mean)) : 0
                } else {
                    output[position] = Float(variance)
                }
                position += 1
            }

            outputRow += 1
            host.reportProgress(Double(outputRow) / Double(outHeight))
        }

        let label = normalize ? "normalised variance" : "variance"
        return FDSResult.scanImage(
            output, rows: outHeight, columns: outWidth,
            title: "Detector \(detectorNumber) Variance — \(host.fileName)",
            message: "Intensity \(label) over \(indices.count) aperture pixels" + (stride > 1 ? ", scan stride \(stride)." : ".")
        )
    }
}
