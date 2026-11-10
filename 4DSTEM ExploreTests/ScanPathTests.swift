//
//  ScanPathTests.swift
//  4DSTEM ExploreTests
//
//  Reading the scan path macSTEM saves beside an EMPAD acquisition.
//
//  The fixture is a real `numpy.savez` archive — a 4x4 serpentine with a
//  settling frame at the front — written by numpy and embedded here, so the ZIP
//  and .npy parsing is tested against what numpy actually emits rather than
//  against this reader's idea of it.
//
//  The numbers in the acquisition test were taken from the positions with
//  numpy, independently of this code, and are what a regression in the grid
//  arithmetic would move.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import _DSTEM_Explorer

@Suite("EMPAD scan path")
struct ScanPathTests {

    /// A 4x4 serpentine from numpy: frame 0 is the settling frame (NaN), then
    /// row 0 left to right, row 1 right to left, and so on.
    private static let serpentineNPZ =
        "UEsDBBQAAAAAAAAAIQDdBoJGCAEAAAgBAAAFABQAeC5ucHkBABAACAEAAAAAAAAIAQAAAAAAAJNO" +
        "VU1QWQEAdgB7J2Rlc2NyJzogJzxmOCcsICdmb3J0cmFuX29yZGVyJzogRmFsc2UsICdzaGFwZSc6" +
        "ICgxNywpLCB9ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg" +
        "ICAgICAgICAgICAKAAAAAAAA+H+V1iboCy4hvpXWJugLLhG+AAAAAAAAAACV1iboCy4RPpXWJugL" +
        "LhE+AAAAAAAAAACV1iboCy4RvpXWJugLLiG+ldYm6AsuIb6V1iboCy4RvgAAAAAAAAAAldYm6Asu" +
        "ET6V1iboCy4RPgAAAAAAAAAAldYm6AsuEb6V1iboCy4hvlBLAwQUAAAAAAAAACEAV7kn/QgBAAAI" +
        "AQAABQAUAHkubnB5AQAQAAgBAAAAAAAACAEAAAAAAACTTlVNUFkBAHYAeydkZXNjcic6ICc8Zjgn" +
        "LCAnZm9ydHJhbl9vcmRlcic6IEZhbHNlLCAnc2hhcGUnOiAoMTcsKSwgfSAgICAgICAgICAgICAg" +
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCgAAAAAAAPh/ldYm" +
        "6AsuIb6V1iboCy4hvpXWJugLLiG+ldYm6AsuIb6V1iboCy4RvpXWJugLLhG+ldYm6AsuEb6V1ibo" +
        "Cy4RvgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAldYm6AsuET6V1iboCy4RPpXWJugL" +
        "LhE+ldYm6AsuET5QSwMEFAAAAAAAAAAhAONxNqKEAAAAhAAAAAkAFAB1bml0cy5ucHkBABAAhAAA" +
        "AAAAAACEAAAAAAAAAJNOVU1QWQEAdgB7J2Rlc2NyJzogJzxVMScsICdmb3J0cmFuX29yZGVyJzog" +
        "RmFsc2UsICdzaGFwZSc6ICgpLCB9ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg" +
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAKbQAAAFBLAwQUAAAAAAAAACEAf7FTwqgAAACoAAAA" +
        "CwAUAHBhdHRlcm4ubnB5AQAQAKgAAAAAAAAAqAAAAAAAAACTTlVNUFkBAHYAeydkZXNjcic6ICc8" +
        "VTEwJywgJ2ZvcnRyYW5fb3JkZXInOiBGYWxzZSwgJ3NoYXBlJzogKCksIH0gICAgICAgICAgICAg" +
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCnMAAABlAAAA" +
        "cgAAAHAAAABlAAAAbgAAAHQAAABpAAAAbgAAAGUAAABQSwMEFAAAAAAAAAAhADsajgG4AAAAuAAA" +
        "AAwAFAByYXdfZmlsZS5ucHkBABAAuAAAAAAAAAC4AAAAAAAAAJNOVU1QWQEAdgB7J2Rlc2NyJzog" +
        "JzxVMTQnLCAnZm9ydHJhbl9vcmRlcic6IEZhbHNlLCAnc2hhcGUnOiAoKSwgfSAgICAgICAgICAg" +
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKcwAAAGMA" +
        "AABhAAAAbgAAAF8AAAB4AAAANAAAAF8AAAB5AAAANAAAAC4AAAByAAAAYQAAAHcAAABQSwECFAMU" +
        "AAAAAAAAACEA3QaCRggBAAAIAQAABQAAAAAAAAAAAAAAgAEAAAAAeC5ucHlQSwECFAMUAAAAAAAA" +
        "ACEAV7kn/QgBAAAIAQAABQAAAAAAAAAAAAAAgAE/AQAAeS5ucHlQSwECFAMUAAAAAAAAACEA43E2" +
        "ooQAAACEAAAACQAAAAAAAAAAAAAAgAF+AgAAdW5pdHMubnB5UEsBAhQDFAAAAAAAAAAhAH+xU8Ko" +
        "AAAAqAAAAAsAAAAAAAAAAAAAAIABPQMAAHBhdHRlcm4ubnB5UEsBAhQDFAAAAAAAAAAhADsajgG4" +
        "AAAAuAAAAAwAAAAAAAAAAAAAAIABIgQAAHJhd19maWxlLm5weVBLBQYAAAAABQAFABABAAAYBQAA" +
        "AAA="

    private func fixture() throws -> URL {
        let data = try #require(Data(base64Encoded: ScanPathTests.serpentineNPZ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan_positions_\(UUID().uuidString).npz")
        try data.write(to: url)
        return url
    }

    @Test("a serpentine's frames are placed along alternating rows")
    func serpentine() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = try ScanPath.read(url: url)
        #expect(path.extent.width == 4)
        #expect(path.extent.height == 4)
        #expect(path.destinations == [-1, 0, 1, 2, 3, 7, 6, 5, 4, 8, 9, 10, 11, 15, 14, 13, 12])
        #expect(path.placed == 16)
        #expect(path.skipped == 1)
    }

    @Test("the archive's own description of itself is read")
    func names() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = try ScanPath.read(url: url)
        #expect(path.pattern == "serpentine")
        #expect(path.rawFilename == "scan_x4_y4.raw")
    }

    @Test("a settling frame is not a probe position")
    func settlingFrameIsSkipped() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = try ScanPath.read(url: url)
        // The frame count and the position count are the same, so a raster
        // reading would place all 17 and be wrong by one everywhere.
        #expect(path.destinations.count == 17)
        #expect(path.destinations[0] == -1)
        #expect(path.isRaster == false)
    }

    @Test("every position is covered exactly once")
    func coversTheGridOnce() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = try ScanPath.read(url: url)
        let placed = path.destinations.filter { $0 >= 0 }.map { Int($0) }
        #expect(Set(placed).count == placed.count)
        #expect(Set(placed) == Set(0..<16))
    }

    @Test("a file that is not an archive is refused rather than misread")
    func rejectsNonArchive() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not_an_npz_\(UUID().uuidString).npz")
        try Data("this is not a zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ScanPathError.self) { _ = try ScanPath.read(url: url) }
    }

    // MARK: - Off-grid patterns

    /// A round spiral from numpy: 60 points on an 8x8 canvas, triggered out
    /// over a 10x7 rectangle — 70 frames, a settling frame at the front and
    /// nine of padding at the back. Nothing about it sits on a pixel grid, and
    /// the file it came from is not square, which is the pair that has to work.
    private static let spiralNPZ =
        "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" +
        "J3NoYXBlJzogKCksIH0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg" +
        "ICAgICAgICAgICAgICAgICAgIAptAAAAUEsDBBQAAAAAAAAAIQBC/XEKvAAAALwAAAAMABQAcmF3" +
        "X2ZpbGUubnB5AQAQALwAAAAAAAAAvAAAAAAAAACTTlVNUFkBAHYAeydkZXNjcic6ICc8VTE1Jywg" +
        "J2ZvcnRyYW5fb3JkZXInOiBGYWxzZSwgJ3NoYXBlJzogKCksIH0gICAgICAgICAgICAgICAgICAg" +
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCnMAAABjAAAAYQAAAG4A" +
        "AABfAAAAeAAAADEAAAAwAAAAXwAAAHkAAAA3AAAALgAAAHIAAABhAAAAdwAAAFBLAwQUAAAAAAAA" +
        "ACEAYjtyYLAAAACwAAAACwAUAHBhdHRlcm4ubnB5AQAQALAAAAAAAAAAsAAAAAAAAACTTlVNUFkB" +
        "AHYAeydkZXNjcic6ICc8VTEyJywgJ2ZvcnRyYW5fb3JkZXInOiBGYWxzZSwgJ3NoYXBlJzogKCks" +
        "IH0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg" +
        "ICAgICAgCnIAAABvAAAAdQAAAG4AAABkAAAAIAAAAHMAAABwAAAAaQAAAHIAAABhAAAAbAAAAFBL" +
        "AwQUAAAAAAAAACEAgOtDh+wBAADsAQAADwAUAGRlc2NyaXB0aW9uLm5weQEAEADsAQAAAAAAAOwB" +
        "AAAAAAAAk05VTVBZAQB2AHsnZGVzY3InOiAnPFU5MScsICdmb3J0cmFuX29yZGVyJzogRmFsc2Us" +
        "ICdzaGFwZSc6ICgpLCB9ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg" +
        "ICAgICAgICAgICAgICAgICAgIApQAAAAbwAAAHMAAABpAAAAdAAAAGkAAABvAAAAbgAAACAAAABv" +
        "AAAAZgAAACAAAABlAAAAdgAAAGUAAAByAAAAeQAAACAAAABmAAAAcgAAAGEAAABtAAAAZQAAACAA" +
        "AABvAAAAZgAAACAAAAB0AAAAaAAAAGUAAAAgAAAAcgAAAGEAAAB3AAAAIAAAAGYAAABpAAAAbAAA" +
        "AGUAAAAsAAAAIAAAAGkAAABuAAAAIAAAAGEAAABjAAAAcQAAAHUAAABpAAAAcwAAAGkAAAB0AAAA" +
        "aQAAAG8AAABuAAAAIAAAAG8AAAByAAAAZAAAAGUAAAByAAAAOwAAACAAAABOAAAAYQAAAE4AAAA6" +
        "AAAAIAAAAG4AAABvAAAAdAAAACAAAABhAAAAdAAAACAAAABhAAAAIAAAAHMAAABjAAAAYQAAAG4A" +
        "AAAgAAAAcAAAAG8AAABzAAAAaQAAAHQAAABpAAAAbwAAAG4AAAAuAAAAUEsBAhQDFAAAAAAAAAAh" +
        "AJI+Z9qwAgAAsAIAAAUAAAAAAAAAAAAAAIABAAAAAHgubnB5UEsBAhQDFAAAAAAAAAAhAGu6Gc6w" +
        "AgAAsAIAAAUAAAAAAAAAAAAAAIAB5wIAAHkubnB5UEsBAhQDFAAAAAAAAAAhAONxNqKEAAAAhAAA" +
        "AAkAAAAAAAAAAAAAAIABzgUAAHVuaXRzLm5weVBLAQIUAxQAAAAAAAAAIQBC/XEKvAAAALwAAAAM" +
        "AAAAAAAAAAAAAACAAY0GAAByYXdfZmlsZS5ucHlQSwECFAMUAAAAAAAAACEAYjtyYLAAAACwAAAA" +
        "CwAAAAAAAAAAAAAAgAGHBwAAcGF0dGVybi5ucHlQSwECFAMUAAAAAAAAACEAgOtDh+wBAADsAQAA" +
        "DwAAAAAAAAAAAAAAgAF0CAAAZGVzY3JpcHRpb24ubnB5UEsFBgAAAAAGAAYATQEAAKEKAAAAAA=="

    private func spiralFixture() throws -> URL {
        let data = try #require(Data(base64Encoded: ScanPathTests.spiralNPZ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spiral_positions_\(UUID().uuidString).npz")
        try data.write(to: url)
        return url
    }

    /// The canvas the spiral was drawn on, as metadata.toml would give it.
    private func spiralCanvas() throws -> ScanPath.Canvas {
        return try #require(ScanPath.Canvas(side: 8,
                                            fieldOfViewMetres: [8.0e-9, 8.0e-9]))
    }

    @Test("an off-grid path is refused rather than guessed at")
    func offGridNeedsACanvas() throws {
        let url = try spiralFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        // No metadata beside it and none supplied: the positions give no pitch
        // to recover, and inventing one would reorder the scan into nonsense.
        #expect(throws: ScanPathError.self) { _ = try ScanPath.read(url: url) }
    }

    @Test("a spiral is gridded onto the canvas its metadata describes")
    func spiralIsGridded() throws {
        let url = try spiralFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = try ScanPath.read(url: url, canvas: try spiralCanvas())
        #expect(path.onGrid == false)
        #expect(path.gridding == .kaiserBessel(width: 2))
        #expect(path.pattern == "round spiral")

        // Counted from the positions with numpy, independently of this code.
        #expect(path.extent.width == 8)
        #expect(path.extent.height == 8)
        #expect(path.placed == 60)
        #expect(path.filled == 50)
        #expect(path.blank == 14)

        let spread = try #require(path.spread)
        #expect(spread.cells.count == 243)
        let weights = spread.weights.reduce(0) { $0 + Double($1) }
        #expect(abs(weights - 90.844547) < 1e-3)
        // Every weight is accounted for in the divisors, or the normalisation
        // would not undo the kernel.
        let totals = spread.totals.reduce(0) { $0 + Double($1) }
        #expect(abs(totals - weights) < 1e-3)
    }

    @Test("a non-square trigger rectangle reconstructs as the square canvas")
    func nonSquareFile() throws {
        let url = try spiralFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = try ScanPath.read(url: url, canvas: try spiralCanvas())
        // 70 frames came off the detector — a 10x7 rectangle of triggers — and
        // they belong in an 8x8 image. The two counts are not the same number
        // and neither one may be used for the other.
        #expect(path.destinations.count == 70)
        #expect(path.extent.width * path.extent.height == 64)
        #expect(path.rawFilename == "scan_x10_y7.raw")
    }

    @Test("nearest-position gridding averages the frames that share one")
    func nearestAverages() throws {
        let url = try spiralFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = try ScanPath.read(url: url, canvas: try spiralCanvas(),
                                     gridding: .nearest)
        #expect(path.filled == 31)
        #expect(path.overwritten == 29)
        // A spiral starts at the centre, so its first frames all land on the
        // one position and have to be averaged rather than overwritten.
        #expect(Array(path.destinations.prefix(6)) == [-1, 36, 36, 36, 36, 36])
        let spread = try #require(path.spread)
        // Ten of the sixty frames land on the middle position, and the divisor
        // is what turns them into an average of ten rather than whichever one
        // happened to be read last.
        #expect(spread.totals[36] == 10)
        #expect(path.needsAccumulation)
    }

    @Test("a grid path is placed exactly, and never gridded")
    func gridPathIsNotBlurred() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = try ScanPath.read(url: url)
        // The serpentine *is* the probe lattice. A window over it would spread
        // every frame across its neighbours for nothing, so the automatic
        // choice has to come out as the exact one.
        #expect(path.onGrid)
        #expect(path.gridding == .nearest)
        #expect(path.spread == nil)
        #expect(path.needsAccumulation == false)
        #expect(path.filled == 16)
        #expect(path.blank == 0)
    }

    @Test("the spread accumulates and divides back to a weighted average")
    func spreadIsAWeightedAverage() throws {
        let url = try spiralFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = try ScanPath.read(url: url, canvas: try spiralCanvas())
        let spread = try #require(path.spread)

        // Walked exactly as the reader walks it, with frame k standing in for
        // a pattern of constant value k, so each position should come out as
        // the weighted mean of the frames that reached it. What this pins is
        // the contract the reader depends on: that `starts` indexes `cells`
        // and `weights` together, frame by frame.
        var accumulated = [Double](repeating: 0, count: 64)
        for frame in 0..<path.destinations.count {
            let first = Int(spread.starts[frame])
            let last = Int(spread.starts[frame + 1])
            for contribution in first..<last {
                accumulated[Int(spread.cells[contribution])]
                    += Double(spread.weights[contribution]) * Double(frame)
            }
        }
        for position in 0..<64 where spread.totals[position] >= ScanPath.Spread.floor {
            accumulated[position] /= Double(spread.totals[position])
        }

        // Computed from the positions with numpy, independently of this code.
        #expect(abs(Double(spread.totals[36]) - 11.166958) < 1e-4)
        #expect(abs(accumulated[36] - 7.083178) < 1e-4)
        #expect(abs(accumulated[35] - 12.510596) < 1e-4)
        #expect(abs(accumulated[28] - 17.247200) < 1e-4)
        // The corners of a square canvas are outside a round spiral, so they
        // are untouched rather than extrapolated into.
        #expect(spread.totals[0] == 0)
        #expect(spread.totals[63] == 0)
    }

    @Test("a field of view in the wrong units is refused, not applied")
    func rejectsMismatchedCanvas() throws {
        let url = try spiralFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        // Nanometres where the positions are metres: every position collapses
        // into the middle pixel, which is a plausible-looking scan of nothing.
        let wrong = try #require(ScanPath.Canvas(side: 8,
                                                 fieldOfViewMetres: [8.0, 8.0]))
        #expect(throws: ScanPathError.self) {
            _ = try ScanPath.read(url: url, canvas: wrong)
        }
    }

    // MARK: - Looking at it

    /// Reconstructs a scan from one value per frame, through the reader's own
    /// `place` and `normalise` rather than a copy of them, and writes it out
    /// as a PNG so the result can be looked at and not just asserted on.
    ///
    /// One value per frame stands in for a whole diffraction pattern: placing
    /// and then integrating the detector is the same arithmetic as integrating
    /// and then placing, both being linear, so a virtual image built this way
    /// is exactly the one the app would show.
    @discardableResult
    private func reconstruct(_ path: ScanPath, values: (Int) -> Float,
                             png name: String? = nil) throws -> [Float] {
        let positions = path.extent.width * path.extent.height
        var image = [Float](repeating: 0, count: positions)
        image.withUnsafeMutableBufferPointer { buffer in
            if let spread = path.spread {
                for frame in 0..<path.destinations.count {
                    var value = values(frame)
                    spread.place(frame: &value, index: frame, stride: 1,
                                 into: buffer.baseAddress!)
                }
                spread.normalise(buffer.baseAddress!, stride: 1, positions: positions)
            } else {
                for frame in 0..<path.destinations.count
                where path.destinations[frame] >= 0 {
                    buffer[Int(path.destinations[frame])] = values(frame)
                }
            }
        }
        if let name = name {
            let url = try write(image, width: path.extent.width,
                                height: path.extent.height, scale: 16, name: name)
            print("wrote \(url.path)")
        }
        return image
    }

    /// A grey PNG, magnified so a small canvas is legible.
    private func write(_ values: [Float], width: Int, height: Int,
                       scale: Int, name: String) throws -> URL {
        let low = values.filter { $0 != 0 }.min() ?? 0
        let high = values.max() ?? 1
        let span = max(high - low, .leastNormalMagnitude)
        var pixels = [UInt8](repeating: 0, count: width * scale * height * scale)
        for y in 0..<(height * scale) {
            for x in 0..<(width * scale) {
                let value = values[(y / scale) * width + (x / scale)]
                pixels[y * width * scale + x] = value == 0 ? 0
                    : UInt8(max(0, min(255, ((value - low) / span) * 200 + 55)))
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).png")
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width * scale, height: height * scale, bitsPerComponent: 8,
            bitsPerPixel: 8, bytesPerRow: width * scale,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test("gridding a flat field gives back a flat field")
    func griddingPreservesAConstantField() throws {
        let url = try spiralFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = try ScanPath.read(url: url, canvas: try spiralCanvas())
        let image = try reconstruct(path, values: { _ in 7 },
                                    png: "scanpath-constant")

        // The one property the whole scheme rests on: whatever the weights
        // are, dividing by their sum has to give the value back. If it does
        // not, the kernel is printing its own shape onto every flat region of
        // every spiral — a ring pattern that looks like sample contrast.
        let spread = try #require(path.spread)
        for position in 0..<image.count
        where spread.totals[position] >= ScanPath.Spread.floor {
            #expect(abs(image[position] - 7) < 1e-4)
        }
        // And it is a real reconstruction, not an empty one.
        #expect(image.filter { $0 != 0 }.count == path.filled)
    }

    @Test("the kernel keeps to its own window")
    func griddingStaysLocal() throws {
        let url = try spiralFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = try ScanPath.read(url: url, canvas: try spiralCanvas())
        // Frames landing on the left half carry 1, the right half 0, so the
        // reconstruction is a step with the kernel's own width across it.
        let image = try reconstruct(path, values: { frame in
            let place = Int(path.destinations[frame])
            return place >= 0 && place % 8 < 4 ? 1 : 0
        }, png: "scanpath-step")

        let spread = try #require(path.spread)
        for position in 0..<image.count
        where spread.totals[position] >= ScanPath.Spread.floor {
            let column = position % 8
            // A two-pixel window reaches one position either side of the seam,
            // so columns 3 and 4 may be mixed and nothing further out may be.
            if column <= 2 { #expect(image[position] > 0.999) }
            if column >= 5 { #expect(image[position] < 0.001) }
            #expect(image[position] >= -0.001 && image[position] <= 1.001)
        }
    }

    // Four real acquisitions — hilbert, interleaved, fibonacci and cav spiral,
    // 70,912 frames in all — were checked frame by frame against numpy while
    // this was written, and every destination matched. None of that runs from
    // here: the test host is an app bundle, and reading a scan off an external
    // volume or the Desktop from one waits on a macOS privacy prompt that never
    // arrives under xcodebuild, so the suite hung rather than failed. Those
    // checks belong in a command-line binary built against these same files.
}
