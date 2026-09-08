//
//  EMPADMetadataWriter.swift
//  4DSTEM Explorer
//
//  Writes the calibration out as EMPAD metadata JSON.
//
//  The schema is `EmpadMetadata` version 2.0 as phaser defines it
//  (phaser/io/empad.py). Writing what that reader expects — rather than
//  something of our own that merely resembles it — is the whole point: the file
//  is only useful if the tool at the other end loads it without adjustment.
//
//  Two things about that schema are easy to get wrong and are handled here
//  rather than left to the caller:
//
//    * it is SI throughout. Voltage is volts, not kilovolts; scan step and field
//      of view are metres, not nanometres. Angles are the exception — convergence
//      and diffraction step are milliradians, and rotations are degrees.
//    * `scan_correction` means `[x', y'] = scan_correction @ [x, y]`, so it is
//      written row-major.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

enum EMPADMetadataWriter {

    /// Fields the schema requires and that cannot be invented.
    enum MissingField: LocalizedError {
        case noFile
        case noScanShape
        case noScanStep
        case noVoltage

        var errorDescription: String? {
            switch self {
            case .noFile:
                return "No dataset is open."
            case .noScanShape:
                return "The scan dimensions are not known."
            case .noScanStep:
                return "There is no scan step. Calibrate the dataset first — the metadata format requires it."
            case .noVoltage:
                return "There is no accelerating voltage. Set it in Calibrate — the metadata format requires it."
            }
        }
    }

    /// Builds the metadata dictionary.
    ///
    /// - Parameters:
    ///   - url: the open dataset, used for the experiment name and the raw
    ///     filename the metadata refers to.
    ///   - scanWidth, scanHeight: the raster, in probe positions.
    ///   - calibrations: what the application currently believes.
    ///   - basedOn: the metadata document this dataset was opened with, when
    ///     there was one. The export starts from it so that everything the
    ///     acquisition recorded and this application does not model — exposure,
    ///     beam current, the single-electron level — survives a round trip
    ///     instead of being quietly dropped.
    static func metadata(url: URL?, scanWidth: Int, scanHeight: Int,
                         calibrations: Calibrations?,
                         basedOn imported: [String: Any]? = nil) throws -> [String: Any] {

        guard let url = url else { throw MissingField.noFile }
        guard scanWidth > 0, scanHeight > 0 else { throw MissingField.noScanShape }
        guard let stepNanometres = calibrations?.scan_step, stepNanometres > 0 else {
            throw MissingField.noScanStep
        }
        guard let kilovolts = calibrations?.voltage, kilovolts > 0 else {
            throw MissingField.noVoltage
        }

        // The metadata names the raw file it belongs to. When a .raw was opened
        // that is the file itself; otherwise the reader's own convention for the
        // name is the best available answer.
        let rawFilename: String
        if url.pathExtension.lowercased() == "raw" {
            rawFilename = url.lastPathComponent
        } else {
            rawFilename = "scan_x\(scanWidth)_y\(scanHeight).raw"
        }

        let stepMetres = Double(stepNanometres) * 1e-9

        // Everything the imported document held, with the calibration laid over
        // it. Starting from an empty dictionary instead would drop every field
        // this type does not model.
        var metadata: [String: Any] = imported ?? [:]

        // Whether anything was actually altered. A re-export of an unchanged
        // calibration should reproduce the file it came from, so every write
        // goes through `set`, which compares before assigning.
        var changed = false
        func set(_ key: String, _ value: Any) {
            guard !equivalent(metadata[key], value) else { return }
            metadata[key] = value
            changed = true
        }

        // `scan_shape`, `scan_fov` and `scan_step` are all (x, y) in this schema.
        set("file_type", "empad_metadata")
        set("version", "2.0")
        set("raw_filename", rawFilename)
        set("voltage", Double(kilovolts) * 1000.0)          // volts, not kilovolts
        set("scan_shape", [scanWidth, scanHeight])
        set("scan_step", [stepMetres, stepMetres])          // metres per probe position
        set("scan_fov", [stepMetres * Double(scanWidth),
                         stepMetres * Double(scanHeight)])
        // The experiment's own name, if it had one, is more informative than a
        // filename and is not ours to replace.
        if (metadata["name"] as? String)?.isEmpty != false {
            set("name", url.deletingPathExtension().lastPathComponent)
        }

        if let diffStep = calibrations?.diff_step, diffStep > 0 {
            set("diff_step", Double(diffStep))              // already mrad/px
        }
        // Written whenever it is known, including zero: an explicit 0 says the
        // rotation was measured and found to be nothing, which is not the same
        // as the field being absent.
        if let rotation = calibrations?.scanRotationDegrees, rotation.isFinite {
            set("scan_rotation", Double(rotation))
        }
        if let correction = calibrations?.scanCorrection {
            set("scan_correction", correction.rows.map { $0.map { Double($0) } })
        }
        // Written whenever it is known, all-false included: `(false, false,
        // false)` is a real orientation, and omitting it lets the reader fall
        // back to its own default of (true, false, false) — silently flipping
        // every pattern in y.
        if let flips = calibrations?.detectorFlips {
            set("det_flips", flips.triple)
        }

        // Aberrations, as measured by the acBF plugin.
        //
        // Split deliberately across two fields. `defocus` already exists in the
        // schema, documented in metres and converted back to ångström on the
        // way in, so C1 goes there. Everything else goes in the `aberrations`
        // list, each term carrying its Krivanek order as a two-character `nm`
        // field — "12" is (n = 1, m = 2). The schema tolerates extra keys, so
        // this rides along without disturbing a reader that does not know about
        // it yet.
        //
        // C1 appears in exactly one of the two. The probe model adds
        // `defocus/2·θ²` *and* the aberration surface, whose (1, 0) term is
        // exactly `C1·θ²/2`, so a C1 written in both places is applied twice.
        if let aberrations = calibrations?.aberrations, !aberrations.isEmpty {
            if let defocusMetres = aberrations.defocusMetres {
                set("defocus", defocusMetres)
            }
            let rest = aberrations.phaserAberrations
            if !rest.isEmpty { set("aberrations", rest) }
        }

        // Nothing was altered, so the document that came in is the document that
        // goes out — byte for byte, once serialised. Adding a timestamp or a
        // provenance note here would make an export that changed nothing look
        // like a change.
        if let imported = imported, !changed { return imported }

        // `time` is the *acquisition* time in this schema, so it is written only
        // when the source had none. Stamping the export's own time over an
        // imported one would claim the data was taken the moment it was
        // recalibrated.
        let hasTime = !(metadata["time"] == nil || metadata["time"] is NSNull)
            || !(metadata["time_unix"] == nil || metadata["time_unix"] is NSNull)
        if !hasTime {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let now = Date()
            metadata["time"] = formatter.string(from: now)
            metadata["time_unix"] = now.timeIntervalSince1970
        }

        // Any note the acquisition left is kept; ours is appended rather than
        // written over it.
        let provenance = "Calibration written by 4DSTEM Explorer."
        if let existing = metadata["notes"] as? String, !existing.isEmpty {
            metadata["notes"] = existing.contains(provenance)
                ? existing
                : "\(existing) · \(provenance)"
        } else {
            metadata["notes"] = provenance
        }

        return metadata
    }

    /// The metadata as JSON text.
    ///
    /// Sorted keys and pretty printing, because these files get read, diffed and
    /// edited by hand as often as they get parsed.
    static func json(url: URL?, scanWidth: Int, scanHeight: Int,
                     calibrations: Calibrations?,
                     basedOn imported: [String: Any]? = nil) throws -> Data {
        let dictionary = try metadata(url: url, scanWidth: scanWidth,
                                      scanHeight: scanHeight, calibrations: calibrations,
                                      basedOn: imported)
        return try JSONSerialization.data(withJSONObject: dictionary,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// The name to suggest for the file, following the convention of the
    /// calibration sidecars this reads back.
    /// Whether a value already in the document says the same thing as the one
    /// about to replace it.
    ///
    /// Not `isEqual`. A calibration makes a round trip through Float — the
    /// application stores it that way — and back into a Double for the file, so
    /// a step read as 2e-11 comes back as 2.0000000000000002e-11. Compared
    /// exactly, every export of an untouched file would look like a change and
    /// rewrite it. A relative tolerance at Float's precision accepts the round
    /// trip and still rejects a genuine edit, which is always far larger: the
    /// smallest meaningful change to any of these fields is many orders of
    /// magnitude above it.
    ///
    /// Nulls and booleans are settled before numbers, because JSON parses both
    /// into `NSNumber`-shaped values that a naive test gets wrong in opposite
    /// directions: two explicit nulls look unequal, while `true` and `1` look
    /// equal.
    static func equivalent(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs = lhs else { return rhs == nil || rhs is NSNull }
        guard let rhs = rhs else { return lhs is NSNull }

        // An explicit null equals only another explicit null. A field the
        // instrument wrote as `null` is not the same as one it omitted, and
        // must not read as a change on every export.
        if lhs is NSNull || rhs is NSNull { return lhs is NSNull && rhs is NSNull }

        if isBoolean(lhs) || isBoolean(rhs) {
            guard isBoolean(lhs), isBoolean(rhs) else { return false }
            return (lhs as? Bool) == (rhs as? Bool)
        }

        if let a = lhs as? String, let b = rhs as? String { return a == b }

        if let a = numeric(lhs), let b = numeric(rhs) {
            if a == b { return true }
            if a.isNaN || b.isNaN { return false }
            let scale = Swift.max(abs(a), abs(b))
            return abs(a - b) <= scale * 1e-6
        }

        if let a = lhs as? [Any], let b = rhs as? [Any] {
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { equivalent($0, $1) }
        }
        if let a = lhs as? [String: Any], let b = rhs as? [String: Any] {
            guard a.count == b.count else { return false }
            return a.allSatisfy { equivalent($0.value, b[$0.key]) }
        }
        return false
    }

    /// Whether a value is genuinely a boolean.
    ///
    /// `is Bool` alone is not enough: an `NSNumber` holding 0 or 1 — which is
    /// what JSON's `0` and `1` become — answers yes to it. The stored type is
    /// the only thing that separates a real `true` from the number one, so it
    /// is what gets asked.
    private static func isBoolean(_ value: Any) -> Bool {
        guard value is Bool else { return false }
        guard let number = value as? NSNumber else { return true }
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
    }

    /// A number, but never a boolean.
    private static func numeric(_ value: Any) -> Double? {
        if isBoolean(value) { return nil }
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let f = value as? Float { return Double(f) }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    /// The name to offer when saving.
    ///
    /// Named after the metadata the dataset was opened with, when there was
    /// one, and only after the data otherwise. Acquisition software names the
    /// two differently — `scan_x128_y128.raw` beside `aq3_10nm_20Mx.json` — so
    /// deriving the export from the raster's name produces a file that cannot
    /// be paired with the one it was calibrated from.
    ///
    /// An existing `_calib` is not doubled: re-exporting a calibration should
    /// offer to replace it, not to create `..._calib_calib.json`.
    static func suggestedFilename(for url: URL?, metadataURL: URL? = nil) -> String {
        let source = metadataURL ?? url
        var root = source?.deletingPathExtension().lastPathComponent ?? "scan"
        if root.hasSuffix("_calib") { root.removeLast("_calib".count) }
        return "\(root)_calib.json"
    }
}
