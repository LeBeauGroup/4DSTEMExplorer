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
    static func metadata(url: URL?, scanWidth: Int, scanHeight: Int,
                         calibrations: Calibrations?) throws -> [String: Any] {

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

        // `scan_shape`, `scan_fov` and `scan_step` are all (x, y) in this schema.
        var metadata: [String: Any] = [
            "file_type": "empad_metadata",
            "version": "2.0",
            "name": url.deletingPathExtension().lastPathComponent,
            "raw_filename": rawFilename,
            "voltage": Double(kilovolts) * 1000.0,          // volts, not kilovolts
            "scan_shape": [scanWidth, scanHeight],
            "scan_step": [stepMetres, stepMetres],          // metres per probe position
            "scan_fov": [stepMetres * Double(scanWidth), stepMetres * Double(scanHeight)]
        ]

        if let diffStep = calibrations?.diff_step, diffStep > 0 {
            metadata["diff_step"] = Double(diffStep)        // already mrad/px
        }
        // Written whenever it is known, including zero: an explicit 0 says the
        // rotation was measured and found to be nothing, which is not the same
        // as the field being absent.
        if let rotation = calibrations?.scanRotationDegrees, rotation.isFinite {
            metadata["scan_rotation"] = Double(rotation)
        }
        if let correction = calibrations?.scanCorrection {
            metadata["scan_correction"] = correction.rows.map { $0.map { Double($0) } }
        }
        // Written whenever it is known, all-false included: `(false, false,
        // false)` is a real orientation, and omitting it lets the reader fall
        // back to its own default of (true, false, false) — silently flipping
        // every pattern in y.
        if let flips = calibrations?.detectorFlips {
            metadata["det_flips"] = flips.triple
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
                metadata["defocus"] = defocusMetres
            }
            let rest = aberrations.phaserAberrations
            if !rest.isEmpty { metadata["aberrations"] = rest }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        metadata["time"] = formatter.string(from: now)
        metadata["time_unix"] = now.timeIntervalSince1970
        metadata["notes"] = "Calibration written by 4DSTEM Explorer."

        return metadata
    }

    /// The metadata as JSON text.
    ///
    /// Sorted keys and pretty printing, because these files get read, diffed and
    /// edited by hand as often as they get parsed.
    static func json(url: URL?, scanWidth: Int, scanHeight: Int,
                     calibrations: Calibrations?) throws -> Data {
        let dictionary = try metadata(url: url, scanWidth: scanWidth,
                                      scanHeight: scanHeight, calibrations: calibrations)
        return try JSONSerialization.data(withJSONObject: dictionary,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// The name to suggest for the file, following the convention of the
    /// calibration sidecars this reads back.
    static func suggestedFilename(for url: URL?) -> String {
        let root = url?.deletingPathExtension().lastPathComponent ?? "scan"
        return "\(root)_calib.json"
    }
}
