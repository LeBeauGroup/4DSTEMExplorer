//
//  ScanRotationPlugin.swift
//  4DSTEM Explorer — Scan Rotation
//
//  The plugin face of the scan-rotation measurement.
//
//  This is an example, not the shipping path: the application measures the scan
//  rotation in its own calibration window, from the same engine. What is left
//  here is the adapter — parameters in, results out — which is what makes it
//  worth keeping as an example, since it shows a whole-stack measurement driven
//  through the plugin API with none of the measurement living here.
//
//  ScanRotationMeasurement.swift turns the stack into a centre-of-mass field and
//  the answer into text; CurlMinimisation.swift does the arithmetic. Both are
//  compiled into the application as well, so there is one copy of each.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Accelerate

@objc(ScanRotationPlugin)
public final class ScanRotationPlugin: NSObject, FDSPlugin {

    public override init() { super.init() }

    private let engine = ScanRotationEngine()

    public var pluginIdentifier: String { return "group.lebeau.4dstem.plugin.scanrotation" }
    public var pluginName: String { return "Scan Rotation" }
    public var pluginAPIVersion: Int { return FDSPluginAPIVersion }
    public var pluginRequiresData: Bool { return true }
    public var pluginSupportsLiveUpdate: Bool { return true }

    public var pluginSummary: String {
        return "Measures the angle between the scan and detector axes by minimising "
             + "the curl of the centre-of-mass field."
    }

    private static let wholePattern = "Whole pattern"

    // MARK: - Parameters

    public var pluginParameters: [[String: Any]] {
        return [
            FDSParameter.choice("detector", label: "Centre of mass over",
                                choices: [ScanRotationPlugin.wholePattern],
                                help: "Which detector pixels contribute. Restricting to the bright-field disc is usual: outside it the signal is weak, and its noise enters the derivative undiminished while carrying no field information."),
            FDSParameter.choice("output", label: "Return",
                                choices: ["Rotation report", "Curl vs angle", "Divergence map", "Curl map"],
                                help: "The report has the number. Curl vs angle shows how sharply it is defined — a shallow curve means the data does not determine the angle. The maps show the corrected field: divergence should look like the atomic columns, curl like noise."),
            FDSParameter.number("smoothing", label: "Smoothing (probe positions)", defaultValue: 0,
                                minimum: 0, maximum: 10,
                                help: "Gaussian blur applied to the centre-of-mass maps before differentiating. Differentiation amplifies noise, and shot noise has no preferred direction, so it buries the minimum rather than biasing it. Raise this until the curl-versus-angle curve has a clear trough."),
            FDSParameter.integer("edgeTrim", label: "Ignore scan edge (positions)", defaultValue: 0,
                                 minimum: 0, maximum: 64,
                                 help: "Drops this many probe positions from every edge. The start of each row carries the flyback transient, which is not a measurement of the specimen and has a strong artificial gradient along the fast-scan direction.")
        ]
    }

    public func parameters(for host: FDSHostContext) -> [[String: Any]] {
        var tailored = pluginParameters
        // Offer the detectors the user has actually configured. A bright-field
        // disc is the usual choice and is offered first when one exists, because
        // the whole-pattern default is the one most likely to give a shallow,
        // noise-dominated minimum.
        var choices: [String] = []
        for index in 0..<host.detectorCount {
            guard let info = host.detectorInfo(at: index) else { continue }
            let shape = (info[FDSDetectorKey.shape] as? String) ?? "detector"
            let name = (info[FDSDetectorKey.name] as? String).flatMap { $0.isEmpty ? nil : $0 }
            choices.append("Detector \(index + 1) (\(name ?? shape))")
        }
        choices.append(ScanRotationPlugin.wholePattern)

        for index in tailored.indices
        where tailored[index][FDSParameterKey.identifier] as? String == "detector" {
            tailored[index] = FDSParameter.choice(
                "detector", label: "Centre of mass over",
                choices: choices,
                defaultValue: choices.first ?? ScanRotationPlugin.wholePattern,
                help: "Which detector pixels contribute. Restricting to the bright-field disc is usual: outside it the signal is weak, and its noise enters the derivative undiminished while carrying no field information.")
        }
        return tailored
    }

    // MARK: - Run

    public func run(host: FDSHostContext, parameters: [String: Any]) -> [String: Any]? {

        let detectorChoice = parameters["detector"] as? String ?? ScanRotationPlugin.wholePattern
        let output = parameters["output"] as? String ?? "Rotation report"

        var settings = ScanRotationSettings()
        settings.smoothing = (parameters["smoothing"] as? NSNumber)?.doubleValue ?? 0
        settings.edgeTrim = max(0, (parameters["edgeTrim"] as? NSNumber)?.intValue ?? 0)
        settings.detectorIndex = detectorChoice == ScanRotationPlugin.wholePattern
            ? nil : ScanRotationPlugin.detectorIndex(from: detectorChoice)

        guard host.scanWidth >= 5, host.scanHeight >= 5 else {
            return FDSResult.failure(ScanRotationError.scanTooSmall.localizedDescription)
        }

        let geometry = ScanRotationGeometry(scanWidth: host.scanWidth, scanHeight: host.scanHeight,
                                            patternWidth: host.patternWidth,
                                            patternHeight: host.patternHeight)

        // The mask, when a detector was chosen. An absent or wrong-sized mask
        // falls back to the whole pattern rather than failing.
        var mask: [Float]? = nil
        if let index = settings.detectorIndex, let data = host.detectorMaskData(at: index),
           data.count == geometry.patternPixelCount * MemoryLayout<Float>.size {
            mask = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }

        guard let measured = engine.centreOfMassField(
                geometry: geometry, mask: mask, identity: host.filePath,
                detectorIndex: settings.detectorIndex,
                provider: { row, column, buffer, capacity in
                    host.copyPattern(row: row, column: column, into: buffer, capacity: capacity)
                },
                progress: { host.reportProgress($0) },
                isCancelled: { host.isCancelled }) else {
            return host.isCancelled ? nil
                : FDSResult.failure(ScanRotationError.noSignal.localizedDescription)
        }
        if host.isCancelled { return nil }
        host.reportProgress(0.9)

        let field: CoMField
        let solution: ScanRotationSolution
        do {
            (field, solution) = try engine.solve(measured, settings: settings)
        } catch {
            return FDSResult.failure((error as? LocalizedError)?.errorDescription
                                     ?? error.localizedDescription)
        }
        host.reportProgress(1.0)

        let currentFlips = host.detectorFlips.map { $0.boolValue }

        switch output {
        case "Curl vs angle":
            let angles = (0..<360).map { Float($0) }
            let curl = solution.curlVersusAngle.map { Float($0) }
            var result = FDSResult.plot(x: angles, y: curl,
                                        title: "Curl vs angle — \(host.fileName)",
                                        xLabel: "Rotation (°)", yLabel: "RMS curl")
            result[FDSResultKey.text] = String(
                format: "Minimum at %+.3f°%@ — depth %.4f (%@). The rejected handedness bottoms out at %.4g against %.4g here.",
                solution.rotationDegrees,
                solution.transposed ? ", detector mirrored" : "",
                solution.contrast,
                ScanRotationEngine.verdict(solution.contrast) as NSString,
                solution.rejectedResidualCurl, solution.residualCurl)
            return offer(result, solution: solution, currentFlips: currentFlips)

        case "Divergence map", "Curl map":
            let wantCurl = output == "Curl map"
            let map = engine.map(field, solution: solution, wantCurl: wantCurl)
            let name = wantCurl ? "Curl" : "Divergence"
            var result = FDSResult.scanImage(
                map.values, rows: map.rows, columns: map.columns,
                title: "\(name) at \(String(format: "%+.2f", solution.rotationDegrees))° — \(host.fileName)",
                valueLabel: wantCurl ? "curl (detector px per probe position)"
                                     : "divergence (detector px per probe position)")
            result[FDSResultKey.text] = map.message
            return offer(result, solution: solution, currentFlips: currentFlips)

        default:
            let text = engine.report(solution, field: field, fileName: host.fileName,
                                     detectorName: detectorChoice, settings: settings,
                                     currentFlips: currentFlips)
            return offer(FDSResult.text(text, title: "Scan rotation — \(host.fileName)"),
                         solution: solution, currentFlips: currentFlips)
        }
    }

    private static func detectorIndex(from choice: String) -> Int? {
        // "Detector 3 (bf)" -> 2
        let digits = choice.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard let number = Int(digits), number >= 1 else { return nil }
        return number - 1
    }

    /// Hands the angle back so the application can adopt it.
    private func offer(_ dictionary: [String: Any], solution: ScanRotationSolution,
                       currentFlips: [Bool]) -> [String: Any] {
        guard let offered = engine.offer(solution, currentFlips: currentFlips) else {
            return dictionary
        }
        return FDSResult.withCalibration(dictionary,
                                         scanRotationDegrees: offered.rotationDegrees,
                                         detectorFlips: offered.flips,
                                         summary: offered.summary)
    }
}
