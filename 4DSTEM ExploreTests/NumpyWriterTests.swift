//
//  NumpyWriterTests.swift
//  4DSTEM ExploreTests
//
//  The .npy container, and the tilt map laid out the way a ptychographic
//  reconstruction reads it. The bytes were checked against numpy itself and
//  against phaser's own loader while this was written; what is pinned here is
//  everything that check would have caught.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Testing
import Foundation
@testable import _DSTEM_Explorer

@Suite("NPY output")
struct NumpyWriterTests {

    private func header(_ data: Data) -> String {
        let length = Int(data[8]) | (Int(data[9]) << 8)
        return String(decoding: data[10..<(10 + length)], as: UTF8.self)
    }

    @Test("the magic and version identify it as a v1.0 file")
    func magicAndVersion() throws {
        let data = try #require(NumpyWriter.float32([1, 2, 3, 4], shape: [2, 2]))
        #expect(Array(data.prefix(6)) == [0x93] + Array("NUMPY".utf8))
        #expect(data[6] == 1 && data[7] == 0)
    }

    @Test("the array data starts on a 64-byte boundary",
          arguments: [[128, 128, 2], [7, 5, 2], [1, 1, 2], [3]])
    func dataIsAligned(shape: [Int]) throws {
        // NumPy loads an unaligned file but cannot memory-map it cleanly, and
        // some readers refuse it. The padding is the whole reason the header
        // has trailing spaces.
        let count = shape.reduce(1, *)
        let data = try #require(NumpyWriter.float32([Float](repeating: 0, count: count), shape: shape))
        let offset = data.count - count * 4
        #expect(offset % 64 == 0)
        #expect(data[data.count - count * 4 - 1] == 0x0a)   // header ends in a newline
    }

    @Test("the header declares little-endian float32, C order, and the shape")
    func headerContents() throws {
        let data = try #require(NumpyWriter.float32([Float](repeating: 0, count: 70), shape: [7, 5, 2]))
        let text = header(data)
        #expect(text.contains("'descr': '<f4'"))
        #expect(text.contains("'fortran_order': False"))
        #expect(text.contains("'shape': (7, 5, 2)"))
    }

    @Test("a one-dimensional shape keeps Python's trailing comma")
    func oneDimensionalShapeIsATuple() throws {
        // `(3)` is the number three in Python; `(3,)` is a tuple of one.
        let data = try #require(NumpyWriter.float32([1, 2, 3], shape: [3]))
        #expect(header(data).contains("'shape': (3,)"))
    }

    @Test("a shape that does not match the values is refused")
    func mismatchedShapeIsRefused() {
        #expect(NumpyWriter.float32([1, 2, 3], shape: [2, 2]) == nil)
        #expect(NumpyWriter.float32([], shape: [0, 2]) == nil)
        #expect(NumpyWriter.float32([1], shape: []) == nil)
    }

    @Test("the values are written C-ordered, little-endian")
    func valuesRoundTrip() throws {
        let values: [Float] = [1.5, -2.25, 3.75, 0]
        let data = try #require(NumpyWriter.float32(values, shape: [2, 2]))
        let payload = data.suffix(values.count * 4)
        let read = payload.withUnsafeBytes { raw -> [Float] in
            (0..<values.count).map { i in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            }
        }
        #expect(read == values)
    }

    // MARK: The tilt map

    private func payload(scanGrid: Bool) -> PluginResultPayload {
        // ty and tx are deliberately unalike, so a swapped pair cannot pass.
        let rows = 3, columns = 4
        var ty = [Float](), tx = [Float]()
        for r in 0..<rows {
            for c in 0..<columns {
                ty.append(Float(r) * 10 + Float(c))
                tx.append(-(Float(r) + Float(c) * 100))
            }
        }
        let prefix = scanGrid ? "scan" : "binned"
        var p = PluginResultPayload(kind: .scanImage, title: "Sample tilt", message: nil,
                                    pluginName: "Sample Tilt", fileRoot: "scan_x4_y3",
                                    calibration: nil)
        p.datasets = [
            PluginDataset(name: "\(prefix)/tilt_x", values: tx, rows: rows, columns: columns,
                          units: "mrad", note: nil),
            PluginDataset(name: "\(prefix)/tilt_y", values: ty, rows: rows, columns: columns,
                          units: "mrad", note: nil),
        ]
        return p
    }

    @Test("the tilt map is (rows, columns, 2) with y first")
    func tiltMapIsYThenX() throws {
        let out = try #require(PluginResultExporter.tiltMapNPY(payload(scanGrid: true)))
        #expect(out.rows == 3 && out.columns == 4)
        #expect(header(out.data).contains("'shape': (3, 4, 2)"))

        // Element (2, 1): ty = 21, tx = -102. Reversed, they would be -102 and 21.
        let values = out.data.suffix(3 * 4 * 2 * 4)
        let read = values.withUnsafeBytes { raw -> [Float] in
            (0..<24).map { i in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            }
        }
        let index = (2 * 4 + 1) * 2
        #expect(read[index] == 21)        // ty
        #expect(read[index + 1] == -102)  // tx
    }

    @Test("the binned grid is used only when there is no scan grid")
    func fallsBackToBinned() throws {
        // The plugin attaches scan/ only when it differs from binned/; when it
        // is absent, binned already is the scan grid.
        #expect(PluginResultExporter.tiltMapNPY(payload(scanGrid: false)) != nil)
    }

    @Test("a result with no tilt datasets offers nothing")
    func nonTiltResultIsRefused() {
        var p = PluginResultPayload(kind: .scanImage, title: "Radial profile", message: nil,
                                    pluginName: "Radial Profile", fileRoot: "scan",
                                    calibration: nil)
        p.datasets = [PluginDataset(name: "profile", values: [1, 2, 3], rows: 1, columns: 3,
                                    units: nil, note: nil)]
        #expect(PluginResultExporter.tiltMapNPY(p) == nil)
        // Which is what keeps the menu item off results that are not tilt maps.
    }

    @Test("mismatched tilt_x and tilt_y dimensions are refused")
    func mismatchedPairIsRefused() {
        var p = PluginResultPayload(kind: .scanImage, title: "Sample tilt", message: nil,
                                    pluginName: "Sample Tilt", fileRoot: "scan",
                                    calibration: nil)
        p.datasets = [
            PluginDataset(name: "scan/tilt_x", values: [1, 2, 3, 4], rows: 2, columns: 2,
                          units: "mrad", note: nil),
            PluginDataset(name: "scan/tilt_y", values: [1, 2], rows: 1, columns: 2,
                          units: "mrad", note: nil),
        ]
        #expect(PluginResultExporter.tiltMapNPY(p) == nil)
    }
}
