//
//  MetadataExportTests.swift
//  4DSTEM ExploreTests
//
//  Exporting a calibration for a RAW dataset. Two properties matter and neither
//  is visible by inspection: an export must not drop what the acquisition
//  recorded, and re-exporting an unchanged calibration must give back the file
//  it came from rather than a file that merely looks similar.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Testing
import Foundation
@testable import _DSTEM_Explorer

@Suite("EMPAD metadata export")
struct MetadataExportTests {

    private let raw = URL(fileURLWithPath: "/data/scan_x128_y128.raw")

    /// A calibration matching the imported document below.
    private let matching = Calibrations(scan_step: 0.02, diff_step: 0.7,
                                        voltage: 200, scanRotationDegrees: nil,
                                        scanCorrection: nil, detectorFlips: nil)

    /// As an acquisition writes it: the fields the application models, plus a
    /// good deal it does not.
    private var imported: [String: Any] {
        [
            "file_type": "empad_metadata",
            "version": "2.0",
            "name": "aq3_10nm_20Mx",
            "raw_filename": "scan_x128_y128.raw",
            "voltage": 200000.0,
            "scan_shape": [128, 128],
            "scan_step": [2e-11, 2e-11],
            "scan_fov": [2.56e-9, 2.56e-9],
            "diff_step": 0.7,
            // None of the following is modelled by ScanMetadata.
            "exposure_time": 0.001,
            "beam_current": 3.2e-11,
            "adu": 380.0,
            "author": "acquisition",
            "time": "2026-08-01T10:00:00.000Z",
            "time_unix": 1785931200.0,
            "has_bg": true,
            "empad_version": 2,
        ]
    }

    @Test("an unchanged calibration exports the file it came from, unaltered")
    func unchangedExportIsIdentical() throws {
        let out = try EMPADMetadataWriter.metadata(url: raw, scanWidth: 128, scanHeight: 128,
                                                   calibrations: matching, basedOn: imported)
        #expect(out.count == imported.count)
        for (key, value) in imported {
            #expect(EMPADMetadataWriter.equivalent(out[key], value), "\(key) changed")
        }
        // Specifically: no timestamp of its own, and no note claiming a change.
        #expect(out["time"] as? String == "2026-08-01T10:00:00.000Z")
        #expect(out["notes"] == nil)
    }

    @Test("and serialises byte for byte the same")
    func unchangedExportSerialisesIdentically() throws {
        let a = try EMPADMetadataWriter.json(url: raw, scanWidth: 128, scanHeight: 128,
                                             calibrations: matching, basedOn: imported)
        let b = try JSONSerialization.data(withJSONObject: imported,
                                           options: [.prettyPrinted, .sortedKeys])
        #expect(a == b)
    }

    @Test("a Float round trip is not mistaken for an edit")
    func floatRoundTripIsNotAChange() throws {
        // The application stores the step as Float and writes a Double, so
        // 2e-11 comes back very slightly different. Compared exactly, every
        // export of an untouched file would rewrite it.
        let step = Double(Float(0.02)) * 1e-9
        #expect(step != 2e-11)                       // the round trip really does move it
        #expect(EMPADMetadataWriter.equivalent(2e-11, step))
    }

    @Test("a real change is written, and the acquisition's fields survive it")
    func changedExportKeepsUnmodelledFields() throws {
        let edited = Calibrations(scan_step: 0.02, diff_step: 1.4,   // diff_step changed
                                  voltage: 200, scanRotationDegrees: nil,
                                  scanCorrection: nil, detectorFlips: nil)
        let out = try EMPADMetadataWriter.metadata(url: raw, scanWidth: 128, scanHeight: 128,
                                                   calibrations: edited, basedOn: imported)
        #expect(EMPADMetadataWriter.equivalent(out["diff_step"], 1.4))
        // Everything the acquisition recorded is still there.
        for key in ["exposure_time", "beam_current", "adu", "author", "has_bg", "empad_version"] {
            #expect(EMPADMetadataWriter.equivalent(out[key], imported[key]), "\(key) was dropped")
        }
        // The acquisition time is not replaced with the time of export.
        #expect(out["time"] as? String == "2026-08-01T10:00:00.000Z")
        // And the change is recorded.
        #expect((out["notes"] as? String)?.contains("4DSTEM Explorer") == true)
    }

    @Test("with no imported document it still writes a complete one")
    func exportWithoutImportedMetadata() throws {
        let out = try EMPADMetadataWriter.metadata(url: raw, scanWidth: 128, scanHeight: 128,
                                                   calibrations: matching, basedOn: nil)
        #expect(out["file_type"] as? String == "empad_metadata")
        #expect(out["raw_filename"] as? String == "scan_x128_y128.raw")
        #expect(EMPADMetadataWriter.equivalent(out["voltage"], 200000.0))
        #expect(out["time"] != nil)          // nothing to preserve, so it stamps one
        #expect(out["notes"] != nil)
    }

    @Test("the export is named after the metadata, not the raster")
    func namedAfterTheImportedMetadata() {
        // Acquisition software names the two differently, and a calibration
        // written under the raster's name cannot be paired with its source.
        let meta = URL(fileURLWithPath: "/data/aq3_10nm_20Mx.json")
        #expect(EMPADMetadataWriter.suggestedFilename(for: raw, metadataURL: meta)
                == "aq3_10nm_20Mx_calib.json")
        // Without one, the data's name is all there is.
        #expect(EMPADMetadataWriter.suggestedFilename(for: raw, metadataURL: nil)
                == "scan_x128_y128_calib.json")
    }

    @Test("re-exporting a calibration does not double the suffix")
    func calibSuffixIsNotDoubled() {
        let meta = URL(fileURLWithPath: "/data/aq3_10nm_20Mx_calib.json")
        #expect(EMPADMetadataWriter.suggestedFilename(for: raw, metadataURL: meta)
                == "aq3_10nm_20Mx_calib.json")
    }

    @Test("equivalence does not confuse a Bool with a number")
    func boolsAreNotNumbers() {
        // NSNumber bridges both, so `true` would otherwise equal 1.
        #expect(!EMPADMetadataWriter.equivalent(true, 1))
        #expect(!EMPADMetadataWriter.equivalent(1, true))
        #expect(EMPADMetadataWriter.equivalent(true, true))
        #expect(!EMPADMetadataWriter.equivalent(true, false))
    }

    // MARK: Importing into an already-open dataset

    @Test("an import applies what the file says")
    func importAppliesRecordedFields() throws {
        var metadata = ScanMetadata()
        metadata.scanStepNanometres = 0.025
        metadata.voltageKilovolts = 300
        let incoming = BatchDiscovery.calibrations(from: metadata)
        #expect(incoming.scan_step == 0.025)
        #expect(incoming.voltage == 300)
    }

    @Test("and leaves alone what the file is silent about")
    func importDoesNotClearUnmentionedFields() throws {
        // A sidecar recording only the voltage should not discard a diffraction
        // step measured this morning. The merge is what the menu action does.
        let current = Calibrations(scan_step: 0.02, diff_step: 0.7, voltage: 200,
                                   scanRotationDegrees: 12.5, scanCorrection: nil,
                                   detectorFlips: nil,
                                   aberrations: [Aberration(n: 1, m: 0, a: -250)])
        var metadata = ScanMetadata()
        metadata.voltageKilovolts = 300
        let incoming = BatchDiscovery.calibrations(from: metadata)

        let merged = Calibrations(
            scan_step: incoming.scan_step ?? current.scan_step,
            diff_step: incoming.diff_step ?? current.diff_step,
            voltage: incoming.voltage ?? current.voltage,
            scanRotationDegrees: incoming.scanRotationDegrees ?? current.scanRotationDegrees,
            scanCorrection: incoming.scanCorrection ?? current.scanCorrection,
            detectorFlips: incoming.detectorFlips ?? current.detectorFlips,
            aberrations: current.aberrations)

        #expect(merged.voltage == 300)             // taken from the file
        #expect(merged.scan_step == 0.02)          // kept
        #expect(merged.diff_step == 0.7)           // kept
        #expect(merged.scanRotationDegrees == 12.5)
        // Aberrations are measured here, never carried in a sidecar's fields,
        // so an import must not drop them.
        #expect(merged.aberrations.count == 1)
    }

    @Test("equivalence compares nested arrays element by element")
    func nestedValuesCompare() {
        #expect(EMPADMetadataWriter.equivalent([2e-11, 2e-11], [2e-11, 2e-11]))
        #expect(!EMPADMetadataWriter.equivalent([2e-11, 2e-11], [2e-11, 4e-11]))
        #expect(!EMPADMetadataWriter.equivalent([2e-11], [2e-11, 2e-11]))
        #expect(EMPADMetadataWriter.equivalent([[1.0, 0.0], [0.0, 1.0]],
                                               [[1.0, 0.0], [0.0, 1.0]]))
    }
}
