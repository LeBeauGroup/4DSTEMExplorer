//
//  ScanPathTests.swift
//  4DSTEM ExploreTests
//
//  The order the frames of a RAW file map onto the raster. Entirely arithmetic,
//  and quiet when it is wrong — a serpentine scan read as a raster comes out
//  complete and the right size, with every other row mirrored — which is why
//  the placements are pinned here rather than eyeballed on screen.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Testing
import Foundation
@testable import _DSTEM_Explorer

@Suite("Scan path")
struct ScanPathTests {

    /// 4 wide, 3 high, which is lopsided in both directions and so catches a
    /// width used where a height was meant.
    private func slots(_ path: ScanPath, _ w: Int = 4, _ h: Int = 3) throws -> [Int?] {
        return try path.placement(width: w, height: h).slots
    }

    @Test("a raster is the identity")
    func raster() throws {
        #expect(try slots(.raster) == (0..<12).map { Optional($0) })
        #expect(try ScanPath.raster.placement(width: 5, height: 4).isIdentity)
    }

    @Test("a snake reverses the odd rows")
    func snake() throws {
        #expect(try slots(.snake) == [0, 1, 2, 3, 7, 6, 5, 4, 8, 9, 10, 11].map { Optional($0) })
        #expect(try !ScanPath.snake.placement(width: 5, height: 4).isIdentity)
    }

    @Test("a column order walks down the columns")
    func columns() throws {
        #expect(try slots(.columnRaster) == [0, 4, 8, 1, 5, 9, 2, 6, 10, 3, 7, 11].map { Optional($0) })
        #expect(try slots(.columnSnake) == [0, 4, 8, 9, 5, 1, 2, 6, 10, 11, 7, 3].map { Optional($0) })
    }

    @Test("every named order fills the raster exactly once")
    func namedOrdersArePermutations() throws {
        // The property the read loop relies on: nothing is overwritten and
        // nothing is left holding whatever the allocator had in it.
        for path in ScanPath.namedCases {
            for (w, h) in [(1, 1), (1, 7), (7, 1), (5, 4), (4, 5), (16, 16), (3, 8)] {
                let placement = try path.placement(width: w, height: h)
                let landed = placement.slots.compactMap { $0 }
                #expect(placement.frameCount == w * h)
                #expect(Set(landed).count == w * h)
                #expect(placement.unfilled == 0)
            }
        }
    }

    @Test("a snake is its own inverse")
    func snakeIsAnInvolution() throws {
        // Cheapest check that the row reversal is symmetric rather than off by
        // one: applying it twice has to return to the start.
        for (w, h) in [(5, 4), (8, 3), (1, 6), (6, 1)] {
            let d = try ScanPath.snake.placement(width: w, height: h).slots.map { $0! }
            #expect((0..<(w * h)).allSatisfy { d[d[$0]] == $0 })
        }
    }

    @Test("an empty raster is refused")
    func emptyRaster() {
        #expect(throws: ScanPath.Failure.emptyRaster) {
            try ScanPath.raster.placement(width: 0, height: 4)
        }
    }

    // MARK: Sidecar names

    @Test("a sidecar name is read by what it says, not by an exact match")
    func metadataNames() {
        #expect(ScanPath(metadataName: "raster") == .raster)
        #expect(ScanPath(metadataName: "row-major") == .raster)
        #expect(ScanPath(metadataName: "Serpentine") == .snake)
        #expect(ScanPath(metadataName: "ZigZag") == .snake)
        #expect(ScanPath(metadataName: "boustrophedon") == .snake)
        #expect(ScanPath(metadataName: "column-major") == .columnRaster)
        #expect(ScanPath(metadataName: "vertical serpentine") == .columnSnake)
    }

    @Test("a name that describes no order is left alone")
    func unrecognisedNames() {
        // `hilbert` is the case this whole feature exists for, and the one that
        // must not be guessed at: read as a raster it would produce a complete,
        // plausible, scrambled image. Nil leaves the user's own choice standing.
        #expect(ScanPath(metadataName: "hilbert") == nil)
        #expect(ScanPath(metadataName: "spiral") == nil)
        #expect(ScanPath(metadataName: "") == nil)
        #expect(ScanPath(metadataName: "acquire") == nil)
    }

    @Test("a named order survives a sidecar round trip")
    func roundTrip() {
        for path in ScanPath.namedCases {
            #expect(ScanPath(metadataName: path.metadataName!) == path)
        }
    }

    @Test("an explicit order has no sidecar name")
    func explicitHasNoName() {
        // Writing one would look like the path had been recorded, when a
        // reader could not act on it.
        let placement = ScanPlacement(slots: [0], unfilled: 0, label: "t")
        #expect(ScanPath.explicit(placement).metadataName == nil)
    }
}

@Suite("Scan positions")
struct ScanPositionsTests {

    /// A 3×2 snake with a settling frame at the start of each row: the shape of
    /// file this exists for, small enough to write out by hand.
    private func synthetic(step: Double = 2) -> ScanPositions {
        var x: [Double] = [], y: [Double] = []
        for row in 0..<2 {
            x.append(.nan); y.append(.nan)
            let columns = row % 2 == 0 ? Array(0..<3) : Array((0..<3).reversed())
            for column in columns {
                x.append(Double(column) * step)
                y.append(Double(row) * step)
            }
        }
        return ScanPositions(x: x, y: y, pattern: "snake", rawFile: "scan_x3_y2.raw",
                             summaryText: nil, label: "synthetic", unit: "nm")
    }

    @Test("a frame that was not at a scan position is read and discarded")
    func settlingFramesAreDropped() throws {
        let placement = try synthetic().placement(width: 3, height: 2)
        // The settling frames keep their place in the file — everything after
        // them lies beyond them on disk — and are then dropped.
        #expect(placement.slots == [nil, 0, 1, 2, nil, 5, 4, 3])
        #expect(placement.frameCount == 8)
        #expect(placement.placedCount == 6)
        #expect(placement.unfilled == 0)
    }

    @Test("the raster and the step come from the file")
    func geometryIsRead() {
        let positions = synthetic(step: 2)
        #expect(positions.inferredRaster()?.width == 3)
        #expect(positions.inferredRaster()?.height == 2)
        #expect(positions.inferredScanStepNanometres() == 2)
    }

    @Test("the step is reported in nanometres whatever the file measured in")
    func unitsAreHonoured() {
        // The positions this reads are written in metres; a step reported in
        // those would be 5e-10 nm/px, which is not a calibration anyone means.
        var metres = synthetic(step: 2e-9)
        metres.unit = "m"
        #expect(metres.inferredScanStepNanometres() == 2)

        var unknown = synthetic(step: 2)
        unknown.unit = "furlongs"
        #expect(unknown.inferredScanStepNanometres() == nil)
    }

    @Test("a positions file from a different scan is refused")
    func mismatchedRasterIsRefused() {
        // The mistake that would otherwise produce a complete, plausible and
        // entirely wrong image.
        #expect(throws: ScanPath.Failure.self) {
            try synthetic().placement(width: 6, height: 1)
        }
    }

    @Test("two frames on one scan position is refused")
    func collisionsAreRefused() {
        let doubled = ScanPositions(x: [0, 0], y: [0, 0], pattern: nil, rawFile: nil,
                                    summaryText: nil, label: "doubled", unit: "nm")
        #expect(throws: ScanPath.Failure.self) {
            try doubled.placement(width: 1, height: 1)
        }
    }

    @Test("a file recording no positions at all is refused")
    func allNaNIsRefused() {
        let blank = ScanPositions(x: [.nan, .nan], y: [.nan, .nan], pattern: nil,
                                  rawFile: nil, summaryText: nil, label: "blank", unit: nil)
        #expect(throws: ScanPath.Failure.self) {
            try blank.placement(width: 1, height: 1)
        }
    }

    @Test("a scan position nothing landed on is counted, not refused")
    func unvisitedPositionsAreCounted() throws {
        // A scan can genuinely miss a position — the real 128×128 Hilbert scan
        // this was built against misses exactly one. The position is left as
        // zero and reported, rather than the load failing.
        let gappy = ScanPositions(x: [0, 2, 0], y: [0, 0, 2], pattern: nil, rawFile: nil,
                                  summaryText: nil, label: "gappy", unit: "nm")
        let placement = try gappy.placement(width: 2, height: 2)
        #expect(placement.unfilled == 1)
        #expect(placement.slots == [0, 1, 2].map { Optional($0) })
    }

    @Test("positions are read out of a two-column array as well as separate ones")
    func twoColumnLayout() throws {
        let xy = NumpyReader.Array(name: "positions", shape: [4, 2],
                                   numbers: [0, 0, 1, 0, 1, 1, 0, 1], strings: [])
        let positions = try ScanPositions.interpret([xy], label: "xy.npz")
        #expect(positions.frameCount == 4)
        #expect(try positions.placement(width: 2, height: 2).slots
                == [0, 1, 3, 2].map { Optional($0) })
    }

    @Test("an archive with no positions in it says so")
    func noPositions() {
        let stray = NumpyReader.Array(name: "exposure", shape: [1], numbers: [0.1], strings: [])
        #expect(throws: ScanPath.Failure.self) {
            try ScanPositions.interpret([stray], label: "other.npz")
        }
    }
}

/// An off-grid path — a spiral, a fibonacci sweep — gridded onto the canvas the
/// metadata describes, instead of being refused as not a grid.
@Suite("Off-grid scan path")
struct OffGridScanPathTests {

    /// A fibonacci disc on a 16-pixel canvas, 16 nm across, in metres and
    /// relative to the centre, as macSTEM records one; the first frame is a
    /// settling frame (NaN), as in a real file.
    private func fibonacci(points: Int = 180) -> ScanPositions {
        var x: [Double] = [.nan], y: [Double] = [.nan]
        let golden = Double.pi * (3 - 5.0.squareRoot())
        for k in 0..<points {
            let r = 7.5e-9 * (Double(k) + 0.5).squareRoot() / Double(points).squareRoot()
            x.append(r * cos(Double(k) * golden))
            y.append(r * sin(Double(k) * golden))
        }
        var positions = ScanPositions(x: x, y: y, pattern: "fibonacci",
                                      rawFile: "scan_x16_y12.raw", summaryText: nil,
                                      label: "scan_positions.npz")
        positions.unit = "m"
        positions.canvas = GriddedScan.Canvas(side: 16, fieldOfViewMetres: [16e-9, 16e-9])
        return positions
    }

    @Test("an off-grid path is gridded over the canvas, not the trigger rectangle")
    func gridded() throws {
        let positions = fibonacci()
        #expect(positions.inferredRaster()! == (16, 16))
        #expect(abs(positions.inferredScanStepNanometres()! - 1.0) < 1e-9)

        let placement = try positions.placement(width: 16, height: 16)
        #expect(placement.spread != nil)
        #expect(placement.frameCount == 181)
        #expect(placement.slots[0] == nil)              // the settling frame
        #expect(placement.placedCount == 180)
        #expect(!placement.isIdentity)
        // A disc on a square canvas leaves the corners empty, and no more.
        #expect(placement.unfilled > 0 && placement.unfilled < 16 * 16 / 2)
        // And it survives the common check, which would refuse shared positions
        // from any other path.
        #expect(try ScanPath.explicit(placement).placement(width: 16, height: 16) == placement)
    }

    @Test("an off-grid path over the wrong raster is refused, not squeezed")
    func wrongRaster() {
        #expect(throws: ScanPath.Failure.self) {
            try fibonacci().placement(width: 16, height: 12)
        }
    }

    @Test("without a canvas an off-grid path still fails the grid check")
    func noCanvas() {
        var positions = fibonacci()
        positions.canvas = nil
        #expect(throws: ScanPath.Failure.self) {
            try positions.placement(width: 16, height: 16)
        }
    }

    @Test("an on-grid path with a canvas is still placed exactly, one frame to a position")
    func onGridStaysExact() throws {
        var x: [Double] = [], y: [Double] = []
        for row in 0..<16 { for column in 0..<16 {
            x.append((Double(column) - 8) * 1e-9); y.append((Double(row) - 8) * 1e-9)
        } }
        var positions = ScanPositions(x: x, y: y, pattern: "raster", rawFile: nil,
                                      summaryText: nil, label: "grid.npz")
        positions.unit = "m"
        positions.canvas = GriddedScan.Canvas(side: 16, fieldOfViewMetres: [16e-9, 16e-9])
        let placement = try positions.placement(width: 16, height: 16)
        #expect(placement.spread == nil)
        #expect(placement.isIdentity)
    }

    @Test("gridding a uniform scan gives back the same value everywhere it reached")
    func densityCompensation() throws {
        let placement = try fibonacci(points: 600).placement(width: 16, height: 16)
        let spread = try #require(placement.spread)
        let stride = 3
        var buffer = [Float](repeating: 0, count: 16 * 16 * stride)
        let frame = [Float](repeating: 2.5, count: stride)
        buffer.withUnsafeMutableBufferPointer { out in
            frame.withUnsafeBufferPointer { one in
                for k in 0..<placement.frameCount where placement.slots[k] != nil {
                    spread.place(frame: one.baseAddress!, index: k, stride: stride,
                                 into: out.baseAddress!)
                }
                spread.normalise(out.baseAddress!, stride: stride, positions: 16 * 16)
            }
        }
        let reached = buffer.filter { $0 != 0 }
        #expect(!reached.isEmpty)
        #expect(reached.allSatisfy { abs($0 - 2.5) < 1e-4 })
    }
}
