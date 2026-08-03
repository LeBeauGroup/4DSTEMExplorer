//
//  PluginResult.swift
//  4DSTEM Explorer
//
//  Parsing and validation of the dictionary a plugin returns.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import AppKit

struct PluginResultPayload {

    enum Kind {
        case scanImage
        case pattern
        case plot
        case text
    }

    let kind: Kind
    let title: String
    let message: String?
    let pluginName: String
    let fileRoot: String

    // Image results
    var rows: Int = 0
    var columns: Int = 0
    var values: [Float] = []
    var rgba: [UInt8]? = nil

    // Plot results
    var x: [Float] = []
    var y: [Float] = []
    var xLabel: String = ""
    var yLabel: String = ""

    // Text results
    var text: String = ""

    /// Filename stem offered in the save panel: `<file>_<plugin>`.
    var suggestedFileName: String {
        let plugin = PluginResultPayload.sanitize(pluginName)
        if fileRoot.isEmpty { return plugin }
        return "\(fileRoot)_\(plugin)"
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalars)
    }
}

/// Outcome of reading a plugin's return value. `.failure` carries text meant
/// for the user; an empty string means the plugin cancelled and nothing should
/// be shown.
enum PluginResultOutcome {
    case success(PluginResultPayload)
    case failure(String)
}

enum PluginResultParser {

    /// Turns a plugin's return value into something presentable, or explains
    /// why it cannot be presented. Nil input means the plugin cancelled.
    static func parse(_ dictionary: [String: Any]?,
                      pluginName: String,
                      fileRoot: String) -> PluginResultOutcome {

        guard let dictionary = dictionary else {
            return .failure("")   // cancelled; caller stays silent
        }

        if let error = dictionary[FDSResultKey.error] as? String, !error.isEmpty {
            return .failure(error)
        }

        guard let typeName = dictionary[FDSResultKey.type] as? String else {
            return .failure("The plugin returned a result without a \"\(FDSResultKey.type)\" entry.")
        }

        let title = (dictionary[FDSResultKey.title] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? pluginName
        let message = (dictionary[FDSResultKey.message] as? String).flatMap { $0.isEmpty ? nil : $0 }

        switch typeName {
        case FDSResultType.scanImage, FDSResultType.pattern:
            let kind: PluginResultPayload.Kind = (typeName == FDSResultType.scanImage) ? .scanImage : .pattern
            guard let rows = intValue(dictionary[FDSResultKey.rows]),
                  let columns = intValue(dictionary[FDSResultKey.columns]),
                  rows > 0, columns > 0 else {
                return .failure("The plugin returned an image result without positive \"rows\" and \"columns\".")
            }
            let values = floatArray(dictionary[FDSResultKey.values])
            guard values.count == rows * columns else {
                return .failure("The plugin returned \(values.count) values for a \(rows)×\(columns) image (expected \(rows * columns)).")
            }

            var payload = PluginResultPayload(kind: kind, title: title, message: message,
                                              pluginName: pluginName, fileRoot: fileRoot)
            payload.rows = rows
            payload.columns = columns
            payload.values = values

            if let colorData = dictionary[FDSResultKey.colorValues] as? Data {
                let expected = rows * columns * 4
                if colorData.count == expected {
                    payload.rgba = [UInt8](colorData)
                } else {
                    // Fall back to the grayscale render rather than refusing
                    // the whole result over a bad optional field.
                    NSLog("[Plugins] %@ supplied %d colour bytes, expected %d — ignoring.",
                          pluginName, colorData.count, expected)
                }
            }
            return .success(payload)

        case FDSResultType.plot:
            let x = floatArray(dictionary[FDSResultKey.plotX])
            let y = floatArray(dictionary[FDSResultKey.plotY])
            guard !y.isEmpty else {
                return .failure("The plugin returned a plot with no y values.")
            }
            guard x.isEmpty || x.count == y.count else {
                return .failure("The plugin returned \(x.count) x values and \(y.count) y values.")
            }

            var payload = PluginResultPayload(kind: .plot, title: title, message: message,
                                              pluginName: pluginName, fileRoot: fileRoot)
            payload.x = x.isEmpty ? (0..<y.count).map { Float($0) } : x
            payload.y = y
            payload.xLabel = dictionary[FDSResultKey.xLabel] as? String ?? ""
            payload.yLabel = dictionary[FDSResultKey.yLabel] as? String ?? ""
            return .success(payload)

        case FDSResultType.text:
            var payload = PluginResultPayload(kind: .text, title: title, message: message,
                                              pluginName: pluginName, fileRoot: fileRoot)
            payload.text = dictionary[FDSResultKey.text] as? String ?? ""
            return .success(payload)

        default:
            return .failure("The plugin returned an unknown result type \"\(typeName)\".")
        }
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let number = any as? NSNumber { return number.intValue }
        if let int = any as? Int { return int }
        return nil
    }

    private static func floatArray(_ any: Any?) -> [Float] {
        if let data = any as? Data {
            return FDSFloatArray(data)
        }
        if let numbers = any as? [NSNumber] {
            return numbers.map { $0.floatValue }
        }
        return []
    }
}

// MARK: - Rendering and export

extension PluginResultPayload {

    /// Matrix view of an image result, used for statistics and float TIFF export.
    var matrix: Matrix? {
        guard kind == .scanImage || kind == .pattern, rows > 0, columns > 0 else { return nil }
        return Matrix(array: values, rows, columns)
    }

    /// Display image: the plugin's own colouring if it supplied one, otherwise
    /// the same 2–98 % grayscale stretch the app uses elsewhere.
    func makeImage() -> NSImage? {
        guard rows > 0, columns > 0 else { return nil }

        if let rgba = rgba, rgba.count == rows * columns * 4 {
            guard let provider = CGDataProvider(data: Data(rgba) as CFData),
                  let cgImage = CGImage(
                      width: columns, height: rows,
                      bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: columns * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false,
                      intent: .defaultIntent
                  ) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: columns, height: rows))
        }

        guard let cgImage = matrix?.uInt8ImageRep()?.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: columns, height: rows))
    }

    /// min / max / mean over the finite values of an image result.
    var statistics: (min: Float, max: Float, mean: Float, finite: Int)? {
        guard kind == .scanImage || kind == .pattern, !values.isEmpty else { return nil }
        var minValue = Float.greatestFiniteMagnitude
        var maxValue = -Float.greatestFiniteMagnitude
        var sum: Double = 0
        var finite = 0
        for value in values where value.isFinite {
            minValue = Swift.min(minValue, value)
            maxValue = Swift.max(maxValue, value)
            sum += Double(value)
            finite += 1
        }
        guard finite > 0 else { return nil }
        return (minValue, maxValue, Float(sum / Double(finite)), finite)
    }
}
