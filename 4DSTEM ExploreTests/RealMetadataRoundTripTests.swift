//
//  RealMetadataRoundTripTests.swift
//  4DSTEM ExploreTests
//
//  A real EMPAD sidecar, embedded verbatim. The synthetic fixture in
//  MetadataExportTests is tidier than anything an instrument writes: this one
//  carries explicit JSON nulls, a scan step with more digits than Float can
//  hold, and eleven fields the application does not model. All three are ways
//  a round trip goes wrong without looking wrong.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Testing
import Foundation
@testable import _DSTEM_Explorer

@Suite("A real acquisition sidecar")
struct RealMetadataRoundTripTests {

    /// As written by the microscope, unedited.
    static let json = """
    {"adu": 580.0, "author": null, "beam_current": 3e-11,
     "bg_unix": 1787698869.291719, "camera_length": 0.4575, "conv_angle": 25.0,
     "crop": null, "defocus": 1e-08, "det_flips": [true, false, false],
     "det_rotation": 0.0, "diff_step": 0.6718065573770492, "empad_version": 1,
     "exposure_time": 0.001, "file_type": "empad_metadata", "has_bg": true,
     "name": "acquisition_7", "notes": null,
     "orig_path": "/home/empad/empad_projects/20260824/acquisition_7",
     "post_exposure_time": 0.0, "raw_filename": "scan_x128_y128.raw",
     "scan_correction": null, "scan_fov": [6.778247519042817e-09, 6.778247519042817e-09],
     "scan_positions": null, "scan_rotation": 0.0, "scan_shape": [128, 128],
     "scan_step": [5.2955058742522006e-11, 5.2955058742522006e-11],
     "time": "2026-08-25T19:27:16.325168", "time_unix": 1787700436.325168,
     "version": "2.0", "voltage": 300000.0}
    """

    private func document() throws -> [String: Any] {
        let data = Data(Self.json.utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Written to a temporary file so the real reader is exercised, not a
    /// shortcut around it.
    private func read() throws -> ScanMetadata {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acquisition_7_\(UUID().uuidString).json")
        try Data(Self.json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try ScanMetadata.read(url: url)
    }

    @Test("the reader gets the calibration out of it")
    func readsTheCalibration() throws {
        let m = try read()
        #expect(m.scanWidth == 128)
        #expect(m.scanHeight == 128)
        #expect(m.voltageKilovolts == 300)
        // 5.2955e-11 m per position, in nanometres. Compared relatively: the
        // value is held as Float, whose ~7 significant digits put the absolute
        // error near 3e-9 — larger than a tight absolute bound would allow, and
        // not an error in the reading.
        let step = Double(try #require(m.scanStepNanometres))
        #expect(abs(step - 0.052955058742522) / 0.052955058742522 < 1e-6)
        let diff = try #require(m.diffractionStepMilliradians)
        #expect(abs(Double(diff) - 0.6718065573770492) < 1e-6)
        #expect(m.detectorFlips == [true, false, false])
        #expect(m.originalJSON != nil)
    }

    @Test("re-exporting it unchanged reproduces it exactly")
    func unchangedRoundTripIsExact() throws {
        let m = try read()
        let doc = try document()
        // The calibration the application would hold, having just read it.
        let calibrations = BatchDiscovery.calibrations(from: m)

        let out = try EMPADMetadataWriter.metadata(
            url: URL(fileURLWithPath: "/data/scan_x128_y128.raw"),
            scanWidth: 128, scanHeight: 128,
            calibrations: calibrations, basedOn: doc)

        #expect(out.count == doc.count)
        for (key, value) in doc {
            #expect(EMPADMetadataWriter.equivalent(out[key], value), "\(key) was altered")
        }
        // Serialised, it is the same file.
        let a = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        let b = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        #expect(a == b)
    }

    @Test("the Float round trip alone does not count as an edit")
    func floatPrecisionDoesNotTriggerARewrite() throws {
        // 5.2955058742522006e-11 has more digits than Float carries. Stored and
        // returned it becomes 5.295505747199059e-11 — a relative shift of 2e-8,
        // far below anything that could be a real recalibration, and the reason
        // the comparison is a tolerance rather than equality.
        let stored = Float(5.2955058742522006e-11 * 1e9)
        let returned = Double(stored) * 1e-9
        #expect(returned != 5.2955058742522006e-11)
        #expect(EMPADMetadataWriter.equivalent(5.2955058742522006e-11, returned))
    }

    @Test("nulls and unmodelled fields survive a real change")
    func aRealChangeKeepsEverythingElse() throws {
        let m = try read()
        let doc = try document()
        var edited = BatchDiscovery.calibrations(from: m)
        edited = Calibrations(scan_step: edited.scan_step, diff_step: 1.25,
                              voltage: edited.voltage,
                              scanRotationDegrees: edited.scanRotationDegrees,
                              scanCorrection: edited.scanCorrection,
                              detectorFlips: edited.detectorFlips)

        let out = try EMPADMetadataWriter.metadata(
            url: URL(fileURLWithPath: "/data/scan_x128_y128.raw"),
            scanWidth: 128, scanHeight: 128,
            calibrations: edited, basedOn: doc)

        #expect(EMPADMetadataWriter.equivalent(out["diff_step"], 1.25))
        // Everything the instrument recorded and this application knows nothing
        // about is still there.
        for key in ["adu", "beam_current", "camera_length", "conv_angle", "det_rotation",
                    "empad_version", "exposure_time", "post_exposure_time", "bg_unix",
                    "has_bg", "orig_path", "defocus"] {
            #expect(EMPADMetadataWriter.equivalent(out[key], doc[key]), "\(key) was dropped")
        }
        // Explicit nulls are not turned into missing keys.
        for key in ["author", "crop", "scan_positions", "scan_correction"] {
            #expect(out[key] != nil, "\(key) disappeared")
        }
        // The acquisition time is not replaced with the time of export.
        #expect(out["time"] as? String == "2026-08-25T19:27:16.325168")
    }
}
