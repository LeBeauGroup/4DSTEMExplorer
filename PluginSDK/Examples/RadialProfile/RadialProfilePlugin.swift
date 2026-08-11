//
//  RadialProfilePlugin.swift
//  4DSTEM Explorer — example plugin
//
//  Azimuthally averages the diffraction pattern currently on screen and plots
//  intensity against scattering angle. Demonstrates the simplest shape of
//  plugin: read one thing from the host, return one result, no stack sweep.
//

import Foundation

@objc(RadialProfilePlugin)
public final class RadialProfilePlugin: NSObject, FDSPlugin {

    public var pluginIdentifier: String { return "group.lebeau.4dstem.plugin.radialprofile" }
    public var pluginName: String { return "Radial Profile" }
    public var pluginSummary: String { return "Azimuthal average of the diffraction pattern currently shown in the Pattern panel." }
    public var pluginAPIVersion: Int { return 1 }

    public var pluginParameters: [[String: Any]] {
        return [
            FDSParameter.integer("bins", label: "Bins", defaultValue: 128, minimum: 8, maximum: 2048,
                                 help: "Number of radial bins between the centre and the edge of the pattern."),
            FDSParameter.choice("center", label: "Centre on", choices: ["Detector", "Pattern centre"],
                                help: "Detector uses the centre of the first detector; Pattern centre uses the geometric middle."),
            FDSParameter.toggle("logScale", label: "Log intensity", defaultValue: false)
        ]
    }

    public func run(host: FDSHostContext, parameters: [String: Any]) -> [String: Any]? {

        guard let pattern = host.currentPatternData else {
            return FDSResult.failure("No diffraction pattern is displayed. Click a point in the computed image first.")
        }

        let width = host.patternWidth
        let height = host.patternHeight
        let values = FDSFloatArray(pattern)
        guard width > 0, height > 0, values.count == width * height else {
            return FDSResult.failure("The displayed pattern is \(values.count) values but the detector is \(width)×\(height).")
        }

        let binCount = max(8, (parameters["bins"] as? NSNumber)?.intValue ?? 128)
        let useLog = (parameters["logScale"] as? NSNumber)?.boolValue ?? false
        let centerChoice = parameters["center"] as? String ?? "Detector"

        var centerX = Double(width) / 2.0
        var centerY = Double(height) / 2.0
        if centerChoice == "Detector", host.detectorCount > 0,
           let info = host.detectorInfo(at: 0),
           let x = info[FDSDetectorKey.centerX] as? Double,
           let y = info[FDSDetectorKey.centerY] as? Double {
            centerX = x
            centerY = y
        }

        // Bin out to the nearest edge so every bin is fully sampled; going to
        // the corners would make the outer bins depend on pattern orientation.
        let maxRadius = min(min(centerX, Double(width) - 1 - centerX),
                            min(centerY, Double(height) - 1 - centerY))
        guard maxRadius > 1 else {
            return FDSResult.failure("The chosen centre (\(String(format: "%.1f, %.1f", centerX, centerY))) is too close to the edge of the pattern.")
        }

        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)
        let scale = Double(binCount) / maxRadius

        for row in 0..<height {
            let dy = Double(row) - centerY
            for column in 0..<width {
                let dx = Double(column) - centerX
                let radius = (dx * dx + dy * dy).squareRoot()
                let bin = Int(radius * scale)
                guard bin < binCount else { continue }
                let value = values[row * width + column]
                guard value.isFinite else { continue }
                sums[bin] += Double(value)
                counts[bin] += 1
            }
        }

        host.reportProgress(0.9)

        // Angular calibration when the file provides one, pixels otherwise.
        let step = host.diffractionStepMilliradians
        let calibrated = step > 0
        let xLabel = calibrated ? "Scattering angle (mrad)" : "Radius (detector pixels)"

        var x = [Float]()
        var y = [Float]()
        x.reserveCapacity(binCount)
        y.reserveCapacity(binCount)

        for bin in 0..<binCount where counts[bin] > 0 {
            let radius = (Double(bin) + 0.5) / scale
            x.append(Float(calibrated ? radius * step : radius))
            let mean = sums[bin] / Double(counts[bin])
            y.append(Float(useLog ? log10(max(mean, Double(Float.leastNormalMagnitude))) : mean))
        }

        guard !y.isEmpty else {
            return FDSResult.failure("No pattern pixels fell inside the radial bins.")
        }

        let position: String
        if host.selectedRow >= 0 {
            position = "probe (x \(host.selectedColumn), y \(host.selectedRow))"
        } else {
            position = "the marquee average"
        }

        return FDSResult.plot(
            x: x, y: y,
            title: "Radial Profile — \(host.fileName)",
            xLabel: xLabel,
            yLabel: useLog ? "log₁₀ mean intensity" : "Mean intensity",
            message: "Centred on \(String(format: "%.1f, %.1f", centerX, centerY)) from \(position). \(y.count) of \(binCount) bins populated."
        )
    }
}
