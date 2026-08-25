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
    /// String. What one value *is* — "counts", "mrad", "Å⁻¹", "e⁻".
    ///
    /// Shown beside the number when the pointer is over a pixel. A readout of
    /// `1.234` says nothing about whether that is an intensity, an angle or a
    /// tilt; the plugin is the only thing that knows, so it is the plugin that
    /// says.
    public static let valueLabel = "valueLabel"
    /// Array of dictionaries keyed by `FDSDatasetKey`: extra arrays to write
    /// when the result is exported as data.
    ///
    /// A displayed result is one image. A measurement often produces several
    /// related arrays that belong in the same file — the same quantity on two
    /// grids, two components of one vector — and forcing the user to export each
    /// separately and reassemble them is how the relationship between them gets
    /// lost. A plugin cannot write the file itself: it has no save panel, and in
    /// a sandboxed application it has no permission. So it declares what belongs
    /// in the file and the host writes it.
    public static let datasets = "datasets"
    /// Dictionary of JSON-encodable values recording how the result was
    /// produced. Written into the exported file verbatim.
    public static let provenance = "provenance"
    /// Filename extension to suggest for a data export, without the dot.
    public static let exportExtension = "exportExtension"
    /// Array of dictionaries keyed by `FDSShapeKey`: geometry to draw over the
    /// image, in image-pixel coordinates.
    public static let overlayShapes = "overlayShapes"

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

    /// How the patterns this host is serving were oriented when the file was
    /// read: `[flip_y, flip_x, transpose]`, EMPAD metadata's `det_flips`.
    ///
    /// Patterns come through `patternData` and `copyPattern` with these already
    /// applied, so this is not something to apply again — it is what a plugin
    /// composes its own finding with before offering an absolute answer back.
    @objc var detectorFlips: [NSNumber] { get }

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
    /// NSNumber, scan rotation in degrees.
    public static let scanRotationDegrees = "scanRotationDegrees"
    /// Array of four NSNumbers, row-major, in the sense `[x', y'] = M · [x, y]`:
    /// `[m00, m01, m10, m11]`. Unit determinant — the scale belongs in the scan
    /// step, and a matrix carrying both would double-count it.
    public static let scanCorrection = "scanCorrection"
    /// Array of three NSNumbers (Bool), `[flip_y, flip_x, transpose]`: how the
    /// raw diffraction patterns must be oriented when the file is read. This is
    /// EMPAD metadata's `det_flips`, in its order and meaning.
    ///
    /// Absolute, not a delta. A plugin that finds the detector mirrored composes
    /// its finding with `FDSHostContext.detectorFlips` and offers the result, so
    /// the host never has to know what a given plugin meant by "flip".
    public static let detectorFlips = "detectorFlips"
    /// Array of dictionaries, one per measured aberration coefficient:
    /// `["nm": String, "re": Double, "im": Double]`.
    ///
    /// `nm` carries the Krivanek order as one character per index — "12" is
    /// (n = 1, m = 2), "01" is (n = 0, m = 1). Character separation rather than
    /// a delimiter, which works because both indices are single digits: the
    /// radial order is capped at 6 and `m` never exceeds `n + 1`.
    ///
    /// Values are in **ångström**, in the **detector frame** — the frame chi is
    /// evaluated in, not the scan frame. `re` and `im` are the cosine- and
    /// sine-like halves of the pair; a symmetric term (m == 0) has `im` 0.
    ///
    /// Never offered under a coefficient's name. Downstream, phaser's
    /// convenience names apply a scale factor to four terms — C_21 = 3·B2,
    /// C_32 = 3·S3, C_41 = 4·B4, C_43 = 4·D4 — so a coefficient offered by name
    /// would arrive multiplied.
    public static let aberrations = "aberrations"
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
                                       scanRotationDegrees: Double? = nil,
                                       scanCorrectionRowMajor: [Double]? = nil,
                                       detectorFlips: [Bool]? = nil,
                                       aberrations: [[String: Any]]? = nil,
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
        if let value = scanRotationDegrees, value.isFinite {
            calibration[FDSCalibrationKey.scanRotationDegrees] = NSNumber(value: value)
        }
        if let matrix = scanCorrectionRowMajor, matrix.count == 4,
           matrix.allSatisfy({ $0.isFinite }) {
            calibration[FDSCalibrationKey.scanCorrection] = matrix.map { NSNumber(value: $0) }
        }
        if let flips = detectorFlips, flips.count == 3 {
            calibration[FDSCalibrationKey.detectorFlips] = flips.map { NSNumber(value: $0) }
        }
        if let terms = aberrations, !terms.isEmpty {
            calibration[FDSCalibrationKey.aberrations] = terms
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
                                 title: String? = nil, message: String? = nil,
                                 valueLabel: String? = nil) -> [String: Any] {
        return image(FDSResultType.scanImage, values, rows, columns, title, message, valueLabel)
    }

    /// A diffraction pattern. `values.count` must be `rows * columns`.
    public static func pattern(_ values: [Float], rows: Int, columns: Int,
                               title: String? = nil, message: String? = nil,
                               valueLabel: String? = nil) -> [String: Any] {
        return image(FDSResultType.pattern, values, rows, columns, title, message, valueLabel)
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
                              _ title: String?, _ message: String?,
                              _ valueLabel: String? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            FDSResultKey.type: type,
            FDSResultKey.rows: rows,
            FDSResultKey.columns: columns,
            FDSResultKey.values: floatData(values)
        ]
        if let title = title { dict[FDSResultKey.title] = title }
        if let message = message { dict[FDSResultKey.message] = message }
        if let valueLabel = valueLabel { dict[FDSResultKey.valueLabel] = valueLabel }
        return dict
    }

    private static func floatData(_ values: [Float]) -> Data {
        return values.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
    }
}

/// Keys describing one array attached to a result.
public struct FDSDatasetKey {
    /// String. Path inside the file. Slashes make groups: `binned/tilt_x`.
    public static let name = "name"
    /// Data. Float32 values, row-major, `rows * columns` of them.
    public static let values = "values"
    /// NSNumber (Int).
    public static let rows = "rows"
    /// NSNumber (Int).
    public static let columns = "columns"
    /// String. What one value is — "mrad", "counts".
    public static let units = "units"
    /// String. A sentence about what this array is, written alongside it.
    public static let note = "note"
}

public struct FDSDataset {

    /// One 2-D array to write on export.
    ///
    /// - Parameter name: a path. Slashes become groups in the file, so
    ///   `binned/tilt_x` and `scan/tilt_x` sit in two groups under the same
    ///   name rather than needing two spellings of the same quantity.
    public static func float(_ name: String, _ values: [Float], rows: Int, columns: Int,
                             units: String? = nil, note: String? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            FDSDatasetKey.name: name,
            FDSDatasetKey.rows: rows,
            FDSDatasetKey.columns: columns,
            FDSDatasetKey.values: values.withUnsafeBufferPointer { Data(buffer: $0) }
        ]
        if let units = units { dict[FDSDatasetKey.units] = units }
        if let note = note { dict[FDSDatasetKey.note] = note }
        return dict
    }
}

extension FDSResult {

    /// Attaches arrays and provenance to a result, so the host can offer to
    /// write them as one file.
    public static func withDatasets(_ result: [String: Any],
                                    _ datasets: [[String: Any]],
                                    provenance: [String: Any]? = nil,
                                    exportExtension: String? = nil) -> [String: Any] {
        guard !datasets.isEmpty else { return result }
        var dict = result
        dict[FDSResultKey.datasets] = datasets
        if let provenance = provenance, !provenance.isEmpty {
            dict[FDSResultKey.provenance] = provenance
        }
        if let exportExtension = exportExtension, !exportExtension.isEmpty {
            dict[FDSResultKey.exportExtension] = exportExtension
        }
        return dict
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

// MARK: - Overlays

/// Keys describing one piece of overlay geometry.
///
/// Coordinates are in **image pixels** — the same space as the data — so a shape
/// means the same thing whatever the view is doing. The host draws them with
/// CoreGraphics at whatever scale it is displaying or exporting at, which is why
/// they are geometry rather than pixels: a marker poked into the image is one
/// pixel wide for ever, invisible at a zoomed-out view and a single hard dot at
/// a zoomed-in one, and it is burned into the data on export.
public struct FDSShapeKey {
    /// String: `circle`, `line`, `cross`, `polyline`, `label`.
    public static let kind = "kind"
    /// Array of NSNumber, flat `[x0, y0, x1, y1, …]` in image pixels.
    public static let points = "points"
    /// NSNumber, image pixels.
    public static let radius = "radius"
    /// Array of four NSNumbers, red green blue alpha, each 0…1.
    public static let colour = "colour"
    /// NSNumber. Width in *points on screen*, not image pixels, so a line stays
    /// legible at every zoom instead of growing into a slab.
    public static let lineWidth = "lineWidth"
    /// NSNumber (Bool). Fill rather than stroke.
    public static let filled = "filled"
    /// String, for a label.
    public static let text = "text"
    /// NSNumber. Type size in points on screen.
    public static let fontSize = "fontSize"
}

public struct FDSShape {

    public typealias Colour = (r: Double, g: Double, b: Double, a: Double)

    public static let red: Colour = (1.0, 0.19, 0.19, 1.0)
    public static let amber: Colour = (1.0, 0.75, 0.16, 1.0)
    public static let cyan: Colour = (0.35, 0.85, 1.0, 1.0)

    private static func base(_ kind: String, _ colour: Colour,
                            _ lineWidth: Double) -> [String: Any] {
        return [
            FDSShapeKey.kind: kind,
            FDSShapeKey.colour: [colour.r, colour.g, colour.b, colour.a].map { NSNumber(value: $0) },
            FDSShapeKey.lineWidth: NSNumber(value: lineWidth)
        ]
    }

    public static func circle(x: Double, y: Double, radius: Double,
                              colour: Colour = red, lineWidth: Double = 1.5,
                              filled: Bool = false) -> [String: Any] {
        var shape = base("circle", colour, lineWidth)
        shape[FDSShapeKey.points] = [x, y].map { NSNumber(value: $0) }
        shape[FDSShapeKey.radius] = NSNumber(value: radius)
        shape[FDSShapeKey.filled] = NSNumber(value: filled)
        return shape
    }

    public static func line(x0: Double, y0: Double, x1: Double, y1: Double,
                            colour: Colour = red, lineWidth: Double = 1.5) -> [String: Any] {
        var shape = base("line", colour, lineWidth)
        shape[FDSShapeKey.points] = [x0, y0, x1, y1].map { NSNumber(value: $0) }
        return shape
    }

    /// A cross centred on a point, `radius` image pixels along each arm.
    public static func cross(x: Double, y: Double, radius: Double,
                             colour: Colour = red, lineWidth: Double = 1.5) -> [String: Any] {
        var shape = base("cross", colour, lineWidth)
        shape[FDSShapeKey.points] = [x, y].map { NSNumber(value: $0) }
        shape[FDSShapeKey.radius] = NSNumber(value: radius)
        return shape
    }

    /// A run of connected points, `[x0, y0, x1, y1, …]`.
    public static func polyline(_ points: [Double], colour: Colour = red,
                                lineWidth: Double = 1.5, closed: Bool = false) -> [String: Any] {
        var shape = base(closed ? "polygon" : "polyline", colour, lineWidth)
        shape[FDSShapeKey.points] = points.map { NSNumber(value: $0) }
        return shape
    }

    /// Real text, drawn by the system at the size asked for.
    public static func label(_ text: String, x: Double, y: Double,
                             colour: Colour = red, fontSize: Double = 11) -> [String: Any] {
        var shape = base("label", colour, 0)
        shape[FDSShapeKey.points] = [x, y].map { NSNumber(value: $0) }
        shape[FDSShapeKey.text] = text
        shape[FDSShapeKey.fontSize] = NSNumber(value: fontSize)
        return shape
    }
}

extension FDSResult {

    /// Attaches overlay geometry to an image result.
    ///
    /// Preferred over `withColor` for anything that is a *marking* rather than a
    /// rendering: markings drawn this way scale with the view, print cleanly,
    /// and never enter the exported data.
    public static func withOverlay(_ result: [String: Any],
                                   _ shapes: [[String: Any]]) -> [String: Any] {
        guard !shapes.isEmpty else { return result }
        var dict = result
        dict[FDSResultKey.overlayShapes] = shapes
        return dict
    }
}
