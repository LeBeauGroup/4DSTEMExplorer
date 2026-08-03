//
//  PluginHostContext.swift
//  4DSTEM Explorer
//
//  The concrete `FDSHostContext` a plugin sees while it runs.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import AppKit

/// Shared cancellation flag between the UI and the running plugin.
final class PluginRunToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Everything the context needs from the view model, captured on the main
/// thread before the plugin starts so the background run never reads
/// `@Published` state.
struct PluginDataSnapshot {
    var fileName: String
    var filePath: String
    var scanStepNanometers: Double
    var diffractionStepMilliradians: Double
    var selectedRow: Int
    var selectedColumn: Int
    /// The marquee in scan coordinates, or nil when a single point is selected.
    var selectionRect: CGRect?
    var currentPattern: Matrix?
    var currentScanImage: Matrix?
    var detectors: [DetectorConfiguration]
    var selectedDetectorIDs: Set<DetectorConfiguration.ID>
}

final class PluginHostContext: NSObject, FDSHostContext {

    private let dataController: STEMDataController
    private let snapshot: PluginDataSnapshot
    private let token: PluginRunToken
    private let progressHandler: (Double) -> Void
    private let logHandler: (String) -> Void

    /// Masks are the same for every probe position, so a plugin sweeping the
    /// stack pays for `detectorMask()` once per detector.
    private var maskCache: [Int: Data] = [:]
    private let maskLock = NSLock()

    init(dataController: STEMDataController,
         snapshot: PluginDataSnapshot,
         token: PluginRunToken,
         progressHandler: @escaping (Double) -> Void,
         logHandler: @escaping (String) -> Void) {
        self.dataController = dataController
        self.snapshot = snapshot
        self.token = token
        self.progressHandler = progressHandler
        self.logHandler = logHandler
        super.init()
    }

    // MARK: - Geometry

    var apiVersion: Int { return FDSPluginAPIVersion }

    var scanWidth: Int { return dataController.imageSize.width }
    var scanHeight: Int { return dataController.imageSize.height }
    var patternWidth: Int { return dataController.patternSize.width }
    var patternHeight: Int { return dataController.patternSize.height }
    var patternPixelCount: Int { return dataController.patternPixels }

    var fileName: String { return snapshot.fileName }
    var filePath: String { return snapshot.filePath }

    var scanStepNanometers: Double { return snapshot.scanStepNanometers }
    var diffractionStepMilliradians: Double { return snapshot.diffractionStepMilliradians }

    // MARK: - Pattern access

    func patternData(row: Int, column: Int) -> Data? {
        let count = patternPixelCount
        guard count > 0, let base = patternBase(row: row, column: column) else { return nil }
        return Data(buffer: UnsafeBufferPointer(start: base, count: count))
    }

    func copyPattern(row: Int, column: Int, into buffer: UnsafeMutablePointer<Float>, capacity: Int) -> Bool {
        let count = patternPixelCount
        guard count > 0, capacity >= count, let base = patternBase(row: row, column: column) else { return false }
        buffer.update(from: base, count: count)
        return true
    }

    private func patternBase(row: Int, column: Int) -> UnsafeMutablePointer<Float32>? {
        guard let pointer = dataController.patternPointer else { return nil }
        let width = dataController.imageSize.width
        let height = dataController.imageSize.height
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        return pointer + (row * width + column) * dataController.patternPixels
    }

    var currentPatternData: Data? {
        return PluginHostContext.data(from: snapshot.currentPattern)
    }

    var currentScanImageData: Data? {
        return PluginHostContext.data(from: snapshot.currentScanImage)
    }

    var selectedRow: Int { return snapshot.selectedRow }
    var selectedColumn: Int { return snapshot.selectedColumn }

    var selectionColumn: Int { return snapshot.selectionRect.map { Int($0.origin.x) } ?? -1 }
    var selectionRow: Int { return snapshot.selectionRect.map { Int($0.origin.y) } ?? -1 }
    var selectionWidth: Int { return snapshot.selectionRect.map { Int($0.size.width) } ?? 0 }
    var selectionHeight: Int { return snapshot.selectionRect.map { Int($0.size.height) } ?? 0 }

    private static func data(from matrix: Matrix?) -> Data? {
        guard let matrix = matrix, !matrix.real.isEmpty else { return nil }
        return matrix.real.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Detectors

    var detectorCount: Int { return snapshot.detectors.count }

    func detectorInfo(at index: Int) -> [String: Any]? {
        guard index >= 0, index < snapshot.detectors.count else { return nil }
        let config = snapshot.detectors[index]
        return [
            FDSDetectorKey.name: config.name,
            FDSDetectorKey.shape: PluginHostContext.name(for: config.shape),
            FDSDetectorKey.mode: PluginHostContext.name(for: config.calculationMode),
            FDSDetectorKey.innerRadius: Double(config.innerRadius),
            FDSDetectorKey.outerRadius: Double(config.outerRadius),
            FDSDetectorKey.centerX: Double(config.center.x),
            FDSDetectorKey.centerY: Double(config.center.y),
            FDSDetectorKey.selected: snapshot.selectedDetectorIDs.contains(config.id)
        ]
    }

    func detectorMaskData(at index: Int) -> Data? {
        guard index >= 0, index < snapshot.detectors.count else { return nil }

        maskLock.lock()
        if let cached = maskCache[index] {
            maskLock.unlock()
            return cached
        }
        maskLock.unlock()

        let config = snapshot.detectors[index]
        let pW = dataController.patternSize.width
        let pH = dataController.patternSize.height
        guard pW > 0, pH > 0 else { return nil }

        let center = NSPoint(
            x: max(0, min(CGFloat(pW - 1), config.center.x)),
            y: max(0, min(CGFloat(pH - 1), config.center.y))
        )
        let params: [DetectorParameter: Float] = [
            .innerRadius: Float(min(config.innerRadius, config.outerRadius)),
            .outerRadius: Float(config.outerRadius)
        ]
        let detector = Detector(shape: config.shape, type: config.type, center: center,
                                params: params, size: NSSize(width: pW, height: pH))
        let mask = detector.detectorMask()
        guard let data = PluginHostContext.data(from: mask) else { return nil }

        maskLock.lock()
        maskCache[index] = data
        maskLock.unlock()
        return data
    }

    private static func name(for shape: DetectorShape) -> String {
        switch shape {
        case .bf:     return "bf"
        case .adf:    return "adf"
        case .af:     return "af"
        case .point:  return "point"
        case .custom: return "custom"
        }
    }

    private static func name(for mode: CalculationMode) -> String {
        switch mode {
        case .integrate: return "integrate"
        case .com:       return "com"
        case .dpc:       return "dpc"
        }
    }

    // MARK: - Progress and diagnostics

    func reportProgress(_ fraction: Double) {
        progressHandler(min(1.0, max(0.0, fraction)))
    }

    var isCancelled: Bool { return token.isCancelled }

    func log(_ message: String) {
        logHandler(message)
    }
}
