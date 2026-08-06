//
//  FourDSTEMPluginAPI.swift
//  4DSTEM Explorer — Plugin SDK
//
//  This single file defines the entire contract between 4DSTEM Explorer and a
//  plugin bundle. It is compiled into BOTH the host application and every
//  plugin, so it must stay self-contained: only Foundation types cross the
//  boundary.
//
//  Why dictionaries instead of shared model classes:
//  a plugin bundle and the host each get their own copy of this file. Two
//  copies of an @objc *class* would register the same Objective-C class name
//  twice, which the runtime resolves arbitrarily. @objc *protocols* are unified
//  by name and are safe, so the contract is protocols plus plain
//  NSDictionary/NSData payloads. That also means an older plugin keeps working
//  against a newer host as long as the keys it uses still exist.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

// MARK: - Versioning

/// Bumped when a change to this contract is not backwards compatible.
/// A plugin reporting a `pluginAPIVersion` greater than this is refused.
public let FDSPluginAPIVersion: Int = 1

// MARK: - Parameter descriptor keys
//
// A plugin describes its parameters as an array of dictionaries. The host
// builds a settings sheet from them and hands the chosen values back to
// `run(host:parameters:)` keyed by `FDSParameterKey.identifier`.

public struct FDSParameterKey {
    /// String. Required. Key under which the value is passed back to `run`.
    public static let identifier = "id"
    /// String. Shown next to the control. Falls back to `identifier`.
    public static let label = "label"
    /// String. One of the `FDSParameterType` values. Defaults to `number`.
    public static let type = "type"
    /// NSNumber or String. Used until the user changes it.
    public static let defaultValue = "default"
    /// NSNumber. Lower bound for `number` / `integer`.
    public static let minimum = "min"
    /// NSNumber. Upper bound for `number` / `integer`.
    public static let maximum = "max"
    /// [String]. Options for `choice`. The selected option is passed back as a String.
    public static let choices = "choices"
    /// String. Explanatory text shown under the control.
    public static let help = "help"
}

public struct FDSParameterType {
    /// Passed back as NSNumber (Double).
    public static let number = "number"
    /// Passed back as NSNumber (Int).
    public static let integer = "integer"
    /// Passed back as NSNumber (Bool).
    public static let toggle = "toggle"
    /// Passed back as String, one of `choices`.
    public static let choice = "choice"
    /// Passed back as String.
    public static let text = "text"
    /// A push button rather than a value. Passed back as NSNumber (Bool),
    /// true only on the run that the press started and false on every other,
    /// so it reads as "do this now" rather than as a setting.
    public static let button = "button"
}

// MARK: - Result keys
//
// A plugin returns a dictionary describing one result. `FDSResultKey.type`
// decides how the host presents it.

public struct FDSResultKey {
    /// String. Required. One of the `FDSResultType` values.
    public static let type = "type"
    /// String. Window title. Defaults to the plugin's name.
    public static let title = "title"

    // Image results (`scanImage` and `pattern`)

    /// NSNumber (Int). Row count of `values`.
    public static let rows = "rows"
    /// NSNumber (Int). Column count of `values`.
    public static let columns = "columns"
    /// NSData holding `rows * columns` Float32 values, row-major.
    public static let values = "values"
    /// NSData holding `rows * columns * 4` UInt8 RGBA samples, row-major.
    /// Optional. When present the host displays this instead of a grayscale
    /// render of `values`; `values` is still used for the numeric TIFF export.
    public static let colorValues = "colorValues"

    // Plot results

    /// NSData holding Float32 x coordinates.
    public static let plotX = "x"
    /// NSData holding Float32 y coordinates, same count as `plotX`.
    public static let plotY = "y"
    /// Dictionary describing a calibration the plugin has measured, keyed with
    /// `FDSCalibrationKey`. Optional.
    ///
    /// A plugin cannot change the host's state on its own, and should not be
    /// able to: a calibration alters how every subsequent number in the
    /// application is interpreted. Offering one in the result instead lets the
    /// host present it and apply it only when the user says so.
    public static let calibration = "calibration"

    /// String. Horizontal axis label.
    public static let xLabel = "xLabel"
    /// String. Vertical axis label.
    public static let yLabel = "yLabel"

    // Text results

    /// String. Body of a `text` result.
    public static let text = "text"

    // Diagnostics — valid alongside any type

    /// String. Presented as a failure; no result window is opened.
    public static let error = "error"
    /// String. Short note shown beneath the result.
    public static let message = "message"

    /// [String: Any]. Parameter values to write back into the controls, keyed by
    /// `FDSParameterKey.identifier`. Lets a plugin that *measures* something —
    /// a focus search, say — leave the control sitting at the value it found so
    /// the user can explore from there. Ignored for parameters that do not
    /// exist. Writing back a value does not itself trigger another run.
    public static let parameters = "parameters"
}

public struct FDSResultType {
    /// A value per probe position. `rows`/`columns` should match the scan.
    public static let scanImage = "scanImage"
    /// A diffraction pattern. `rows`/`columns` should match the detector.
    public static let pattern = "pattern"
    /// An x/y line plot.
    public static let plot = "plot"
    /// Plain text, monospaced.
    public static let text = "text"
}

// MARK: - Detector descriptor keys
//
// Keys of the dictionary returned by `FDSHostContext.detectorInfo(at:)`.

public struct FDSDetectorKey {
    /// String. User-assigned name.
    public static let name = "name"
    /// String. `bf`, `adf`, `af`, `point` or `custom`.
    public static let shape = "shape"
    /// String. `integrate`, `com` or `dpc`.
    public static let mode = "mode"
    /// NSNumber (Double). Detector pixels.
    public static let innerRadius = "innerRadius"
    /// NSNumber (Double). Detector pixels.
    public static let outerRadius = "outerRadius"
    /// NSNumber (Double). Column of the detector centre, in detector pixels.
    public static let centerX = "centerX"
    /// NSNumber (Double). Row of the detector centre, in detector pixels.
    public static let centerY = "centerY"
    /// NSNumber (Bool). Whether the detector is currently selected in the UI.
    public static let selected = "selected"
}

// MARK: - Host context

/// The view onto the open dataset that the host hands to a running plugin.
///
/// Every call is made from the background queue the plugin runs on. The 4D
/// stack is guaranteed to stay resident and unmodified for the duration of
/// `run(host:parameters:)`.
@objc(FDSHostContext)
public protocol FDSHostContext: NSObjectProtocol {

    // MARK: Geometry

    /// Contract version implemented by this host.
    @objc var apiVersion: Int { get }

    /// Probe positions per scan row.
    @objc var scanWidth: Int { get }
    /// Number of scan rows.
    @objc var scanHeight: Int { get }
    /// Detector pixels per pattern row.
    @objc var patternWidth: Int { get }
    /// Number of pattern rows.
    @objc var patternHeight: Int { get }
    /// `patternWidth * patternHeight`.
    @objc var patternPixelCount: Int { get }

    /// Name of the open file, or an empty string.
    @objc var fileName: String { get }
    /// Full path of the open file, or an empty string.
    @objc var filePath: String { get }

    /// Scan step in nanometres per probe position, or 0 when uncalibrated.
    @objc var scanStepNanometers: Double { get }
    /// Diffraction step in milliradians per detector pixel, or 0 when uncalibrated.
    @objc var diffractionStepMilliradians: Double { get }
    /// Accelerating voltage in kilovolts, or 0 when the host does not know it.
    /// Plugins needing a wavelength should fall back to their own default
    /// rather than treating 0 as a voltage.
    @objc var accelerationKilovolts: Double { get }

    // MARK: Pattern access

    /// The diffraction pattern at a probe position as `patternPixelCount`
    /// Float32 values, row-major. Returns nil for out-of-range coordinates.
    ///
    /// This allocates. When iterating the whole stack prefer
    /// `copyPattern(row:column:into:capacity:)`.
    @objc func patternData(row: Int, column: Int) -> Data?

    /// Copies the pattern at a probe position into a caller-owned buffer.
    /// `capacity` must be at least `patternPixelCount`. Returns false and
    /// leaves the buffer untouched if the coordinates or capacity are invalid.
    @objc func copyPattern(row: Int, column: Int, into buffer: UnsafeMutablePointer<Float>, capacity: Int) -> Bool

    /// The pattern currently shown in the Pattern panel — a single position, or
    /// the average over the marquee when one is active.
    @objc var currentPatternData: Data? { get }

    /// The computed image currently shown, as `scanHeight * scanWidth` Float32
    /// values, row-major. Nil when nothing has been computed yet.
    @objc var currentScanImageData: Data? { get }

    /// Row of the point selection, or -1 when a marquee is active instead.
    @objc var selectedRow: Int { get }
    /// Column of the point selection, or -1 when a marquee is active instead.
    @objc var selectedColumn: Int { get }

    /// Marquee origin column in scan coordinates, or -1 when no marquee is active.
    @objc var selectionColumn: Int { get }
    /// Marquee origin row in scan coordinates, or -1 when no marquee is active.
    @objc var selectionRow: Int { get }
    /// Marquee width in probe positions, or 0 when no marquee is active.
    @objc var selectionWidth: Int { get }
    /// Marquee height in probe positions, or 0 when no marquee is active.
    @objc var selectionHeight: Int { get }

    // MARK: Detectors

    /// Number of detectors configured in the UI.
    @objc var detectorCount: Int { get }
    /// Geometry and mode of a detector, keyed by `FDSDetectorKey`.
    @objc func detectorInfo(at index: Int) -> [String: Any]?
    /// A detector's mask as `patternPixelCount` Float32 values (1 inside,
    /// 0 outside), row-major and aligned with `patternData(row:column:)`.
    @objc func detectorMaskData(at index: Int) -> Data?

    // MARK: Progress and diagnostics

    /// Drives the progress bar. `fraction` is clamped to 0...1.
    @objc func reportProgress(_ fraction: Double)

    /// True once the user has pressed Cancel. Long-running plugins should poll
    /// this and return early — a nil return is treated as a cancellation.
    @objc var isCancelled: Bool { get }

    /// Writes a line to the run log, shown if the plugin reports an error.
    @objc func log(_ message: String)
}

// MARK: - Plugin

/// Implemented by the principal class of a plugin bundle.
///
/// The class must be an `NSObject` subclass with an accessible `init()`, and
/// its Objective-C name must be listed as `NSPrincipalClass` in the bundle's
/// Info.plist. Mark the class `@objc(YourClassName)` so the name is stable
/// regardless of the module it is built in.
@objc(FDSPlugin)
public protocol FDSPlugin: NSObjectProtocol {

    /// Reverse-DNS identifier, unique across installed plugins.
    @objc var pluginIdentifier: String { get }

    /// Name shown in the Plugins menu.
    @objc var pluginName: String { get }

    /// One-line description shown in the parameter sheet. Optional.
    @objc optional var pluginSummary: String { get }

    /// Contract version this plugin was written against. Optional; assumed 1.
    /// A plugin declaring a version newer than the host's is not loaded.
    @objc optional var pluginAPIVersion: Int { get }

    /// Parameters to prompt for before running, described with
    /// `FDSParameterKey`. Optional; omit or return an empty array to run
    /// immediately with no sheet.
    @objc optional var pluginParameters: [[String: Any]] { get }

    /// Parameters tailored to the open dataset, used in place of
    /// `pluginParameters` when implemented. Optional.
    ///
    /// `pluginParameters` is read once at load time with no dataset in hand, so
    /// it cannot know what units the file carries. This is called each time the
    /// controls are built, which lets a plugin ask for a defocus in nanometres
    /// when the file is calibrated and fall back to pixels when it is not,
    /// rather than presenting one and reporting the other.
    @objc optional func parameters(for host: FDSHostContext) -> [[String: Any]]

    /// Whether the plugin needs a dataset open. Optional; defaults to true.
    @objc optional var pluginRequiresData: Bool { get }

    /// Opt in to a single window holding the controls and the result together,
    /// re-running as the user adjusts a parameter. Optional; defaults to false,
    /// which gives the sheet-then-window flow.
    ///
    /// Only claim this if repeated runs are quick. The same instance is reused
    /// and `run` is never called re-entrantly, so cache the expensive part —
    /// keyed on the parameters it actually depends on — and rebuild it only
    /// when those change. Poll `isCancelled` often: the host cancels the run in
    /// flight as soon as the user moves a control again.
    @objc optional var pluginSupportsLiveUpdate: Bool { get }

    /// Performs the work and returns one result described with `FDSResultKey`.
    ///
    /// Called on a background queue. Return nil to signal cancellation, or a
    /// dictionary carrying `FDSResultKey.error` to report a failure.
    /// Do not touch AppKit from here.
    @objc func run(host: FDSHostContext, parameters: [String: Any]) -> [String: Any]?
}

// MARK: - Convenience builders
//
// Sugar over the dictionary contract. Nothing here crosses the bundle
// boundary — these just build the dictionaries described above.

/// Keys of the calibration dictionary a plugin may return.
///
/// Every entry is optional; only those present are applied, so a plugin that
/// measures the scan step alone does not have to invent a diffraction step.
public struct FDSCalibrationKey {
    /// NSNumber, nanometres per probe position.
    public static let scanStepNanometers = "scanStepNanometers"
    /// NSNumber, milliradians per detector pixel.
    public static let diffractionStepMilliradians = "diffractionStepMilliradians"
    /// NSNumber, accelerating voltage in kilovolts.
    public static let accelerationKilovolts = "accelerationKilovolts"
    /// String. One line describing what is being offered, shown to the user
    /// before they accept it.
    public static let summary = "summary"
}

extension FDSResult {

    /// Attaches a calibration the host may offer to apply.
    ///
    /// Pass only what was measured; a nil leaves that part of the host's
    /// calibration alone rather than clearing it.
    public static func withCalibration(_ result: [String: Any],
                                       scanStepNanometers: Double? = nil,
                                       diffractionStepMilliradians: Double? = nil,
                                       accelerationKilovolts: Double? = nil,
                                       summary: String? = nil) -> [String: Any] {
        var calibration: [String: Any] = [:]
        if let value = scanStepNanometers, value.isFinite, value > 0 {
            calibration[FDSCalibrationKey.scanStepNanometers] = NSNumber(value: value)
        }
        if let value = diffractionStepMilliradians, value.isFinite, value > 0 {
            calibration[FDSCalibrationKey.diffractionStepMilliradians] = NSNumber(value: value)
        }
        if let value = accelerationKilovolts, value.isFinite, value > 0 {
            calibration[FDSCalibrationKey.accelerationKilovolts] = NSNumber(value: value)
        }
        if let summary = summary { calibration[FDSCalibrationKey.summary] = summary }
        guard calibration.count > (summary == nil ? 0 : 1) else { return result }

        var dict = result
        dict[FDSResultKey.calibration] = calibration
        return dict
    }
}

public struct FDSParameter {

    public static func number(_ id: String, label: String, defaultValue: Double,
                              minimum: Double? = nil, maximum: Double? = nil,
                              help: String? = nil) -> [String: Any] {
        return build(id, label, FDSParameterType.number, defaultValue as NSNumber,
                     minimum as NSNumber?, maximum as NSNumber?, nil, help)
    }

    public static func integer(_ id: String, label: String, defaultValue: Int,
                               minimum: Int? = nil, maximum: Int? = nil,
                               help: String? = nil) -> [String: Any] {
        return build(id, label, FDSParameterType.integer, defaultValue as NSNumber,
                     minimum as NSNumber?, maximum as NSNumber?, nil, help)
    }

    public static func toggle(_ id: String, label: String, defaultValue: Bool,
                              help: String? = nil) -> [String: Any] {
        return build(id, label, FDSParameterType.toggle, defaultValue as NSNumber,
                     nil, nil, nil, help)
    }

    public static func choice(_ id: String, label: String, choices: [String],
                              defaultValue: String? = nil,
                              help: String? = nil) -> [String: Any] {
        return build(id, label, FDSParameterType.choice,
                     (defaultValue ?? choices.first ?? "") as NSString,
                     nil, nil, choices, help)
    }

    public static func text(_ id: String, label: String, defaultValue: String = "",
                            help: String? = nil) -> [String: Any] {
        return build(id, label, FDSParameterType.text, defaultValue as NSString,
                     nil, nil, nil, help)
    }

    /// A push button. `run` sees true for the run the press started, false
    /// otherwise — use it for an action, not for a mode the user leaves set.
    public static func button(_ id: String, label: String, help: String? = nil) -> [String: Any] {
        return build(id, label, FDSParameterType.button, NSNumber(value: false),
                     nil, nil, nil, help)
    }

    private static func build(_ id: String, _ label: String, _ type: String,
                              _ defaultValue: Any,
                              _ minimum: NSNumber?, _ maximum: NSNumber?,
                              _ choices: [String]?, _ help: String?) -> [String: Any] {
        var dict: [String: Any] = [
            FDSParameterKey.identifier: id,
            FDSParameterKey.label: label,
            FDSParameterKey.type: type,
            FDSParameterKey.defaultValue: defaultValue
        ]
        if let minimum = minimum { dict[FDSParameterKey.minimum] = minimum }
        if let maximum = maximum { dict[FDSParameterKey.maximum] = maximum }
        if let choices = choices { dict[FDSParameterKey.choices] = choices }
        if let help = help { dict[FDSParameterKey.help] = help }
        return dict
    }
}

public struct FDSResult {

    /// One value per probe position. `values.count` must be `rows * columns`.
    public static func scanImage(_ values: [Float], rows: Int, columns: Int,
                                 title: String? = nil, message: String? = nil) -> [String: Any] {
        return image(FDSResultType.scanImage, values, rows, columns, title, message)
    }

    /// A diffraction pattern. `values.count` must be `rows * columns`.
    public static func pattern(_ values: [Float], rows: Int, columns: Int,
                               title: String? = nil, message: String? = nil) -> [String: Any] {
        return image(FDSResultType.pattern, values, rows, columns, title, message)
    }

    public static func plot(x: [Float], y: [Float],
                            title: String? = nil,
                            xLabel: String? = nil, yLabel: String? = nil,
                            message: String? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            FDSResultKey.type: FDSResultType.plot,
            FDSResultKey.plotX: floatData(x),
            FDSResultKey.plotY: floatData(y)
        ]
        if let title = title { dict[FDSResultKey.title] = title }
        if let xLabel = xLabel { dict[FDSResultKey.xLabel] = xLabel }
        if let yLabel = yLabel { dict[FDSResultKey.yLabel] = yLabel }
        if let message = message { dict[FDSResultKey.message] = message }
        return dict
    }

    public static func text(_ body: String, title: String? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            FDSResultKey.type: FDSResultType.text,
            FDSResultKey.text: body
        ]
        if let title = title { dict[FDSResultKey.title] = title }
        return dict
    }

    public static func failure(_ message: String) -> [String: Any] {
        return [FDSResultKey.error: message]
    }

    /// Attaches an RGBA rendering to an image result built above.
    /// `rgba.count` must be `rows * columns * 4`.
    public static func withColor(_ result: [String: Any], rgba: [UInt8]) -> [String: Any] {
        var dict = result
        dict[FDSResultKey.colorValues] = Data(bytes: rgba, count: rgba.count)
        return dict
    }

    private static func image(_ type: String, _ values: [Float], _ rows: Int, _ columns: Int,
                              _ title: String?, _ message: String?) -> [String: Any] {
        var dict: [String: Any] = [
            FDSResultKey.type: type,
            FDSResultKey.rows: rows,
            FDSResultKey.columns: columns,
            FDSResultKey.values: floatData(values)
        ]
        if let title = title { dict[FDSResultKey.title] = title }
        if let message = message { dict[FDSResultKey.message] = message }
        return dict
    }

    private static func floatData(_ values: [Float]) -> Data {
        return values.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
    }
}

/// Reads `Data` payloads coming back from the host as `[Float]`.
public func FDSFloatArray(_ data: Data?) -> [Float] {
    guard let data = data, data.count >= MemoryLayout<Float>.size else { return [] }
    let count = data.count / MemoryLayout<Float>.size
    var out = [Float](repeating: 0, count: count)
    out.withUnsafeMutableBytes { (dest: UnsafeMutableRawBufferPointer) -> Void in
        data.copyBytes(to: dest.bindMemory(to: UInt8.self), count: count * MemoryLayout<Float>.size)
    }
    return out
}
