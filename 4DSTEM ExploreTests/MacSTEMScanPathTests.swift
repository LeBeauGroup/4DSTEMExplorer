//
//  MacSTEMScanPathTests.swift
//  4DSTEM ExploreTests
//
//  Recomputing a macSTEM scan path from the acquisition's own metadata.
//
//  The orders pinned here were taken from macSTEM itself — `stem.scan.paths`
//  and `stem.scan.spiral`, run over the same sizes — rather than worked out
//  again, because the arithmetic is not the risk. The risk is a convention: the
//  Hilbert construction's choice of which coordinate is the row, the order the
//  interleaved sub-rasters are taken in, which way the square spiral winds.
//  Each of those is invisible in the number of points and decides whether the
//  image comes out transposed, mirrored, or scrambled in a way that still
//  looks like a micrograph.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Testing
import Foundation
@testable import _DSTEM_Explorer

@Suite("macSTEM scan path")
struct MacSTEMScanPathTests {

    private func path(_ pattern: String, canvas: Int, kept: [Int]? = nil,
                      settle: Int? = nil, points: Int? = nil) throws -> MacSTEMScanPath {
        let read = try MacSTEMScanPath.interpretation(pattern: pattern, canvas: canvas,
                                                      kept: kept, settle: settle,
                                                      points: points, source: "metadata.toml")
        guard case .computed(let path)? = read else {
            throw Failure.notComputed(String(describing: read))
        }
        return path
    }

    private enum Failure: Error { case notComputed(String) }

    // MARK: - The orders themselves

    @Test("a Hilbert curve follows macSTEM's own construction")
    func hilbert() throws {
        // 4 x 4: the whole order, as macSTEM produces it.
        #expect(try path("hilbert", canvas: 4).points()
                == [0, 1, 5, 4, 8, 12, 13, 9, 10, 14, 15, 11, 7, 6, 2, 3])
        // 3 x 3: not a power of two, so the curve of the next one up is walked
        // and the points outside the image are skipped.
        #expect(try path("hilbert", canvas: 3).points() == [0, 1, 4, 3, 6, 7, 8, 5, 2])
        #expect(try path("hilbert", canvas: 1).points() == [0])
    }

    @Test("interleaved sub-rasters are taken in macSTEM's order")
    func interleaved() throws {
        // 8 x 8 with the default step of 4: sixteen 2 x 2 sub-rasters, each
        // every fourth position of every fourth row.
        #expect(try path("interleaved", canvas: 8).points() == [
            0, 4, 32, 36, 1, 5, 33, 37, 2, 6, 34, 38, 3, 7, 35, 39,
            8, 12, 40, 44, 9, 13, 41, 45, 10, 14, 42, 46, 11, 15, 43, 47,
            16, 20, 48, 52, 17, 21, 49, 53, 18, 22, 50, 54, 19, 23, 51, 55,
            24, 28, 56, 60, 25, 29, 57, 61, 26, 30, 58, 62, 27, 31, 59, 63])
    }

    @Test("a square spiral winds clockwise from the centre")
    func squareSpiral() throws {
        #expect(try path("spiral", canvas: 4).points()
                == [5, 6, 10, 9, 8, 4, 0, 1, 2, 3, 7, 11, 15, 14, 13, 12])
        // An odd size starts on the middle position rather than beside it.
        #expect(try path("spiral", canvas: 3).points() == [4, 5, 8, 7, 6, 3, 0, 1, 2])
    }

    @Test("every computable pattern visits each scan position exactly once",
          arguments: ["hilbert", "interleaved", "spiral"])
    func permutation(pattern: String) throws {
        for canvas in [1, 2, 3, 5, 8, 13, 16, 64] {
            let points = try path(pattern, canvas: canvas).points()
            #expect(points.count == canvas * canvas)
            #expect(Set(points).count == canvas * canvas)
            #expect(points.allSatisfy { $0 >= 0 && $0 < canvas * canvas })
        }
    }

    @Test("the declared point count is checked, not trusted")
    func pointsChecked() throws {
        // A canvas and a point count that do not belong together: the metadata
        // is describing a different acquisition, and placing the frames anyway
        // would give a full image of the wrong scan.
        #expect(throws: MacSTEMScanPath.Failure.pointsDisagree("hilbert", declared: 4096,
                                                               computed: 16384)) {
            try path("hilbert", canvas: 128, points: 4096).points()
        }
    }

    // MARK: - Laying the path over the frames

    @Test("the path starts after the settling frames")
    func settling() throws {
        let placement = try path("hilbert", canvas: 4, kept: [4, 4], settle: 1).placement()
        // 16 frames for 16 positions, but the first holds no point, so the
        // curve's last point is never written and one position stays empty.
        #expect(placement.frameCount == 16)
        #expect(placement.slots[0] == nil)
        #expect(placement.placedCount == 15)
        #expect(Array(placement.slots[1...4]) == [0, 1, 5, 4].map { Optional($0) })

        let checked = try path("hilbert", canvas: 4, kept: [4, 4], settle: 1)
            .placement(width: 4, height: 4)
        #expect(checked.unfilled == 1)
    }

    @Test("with nothing to settle the frames are the path")
    func noSettling() throws {
        let placement = try path("hilbert", canvas: 4, kept: [4, 4], settle: 0)
            .placement(width: 4, height: 4)
        #expect(placement.placedCount == 16)
        #expect(placement.unfilled == 0)
        #expect(placement.slots.compactMap { $0 } == (try path("hilbert", canvas: 4).points()))
    }

    @Test("a trigger grid larger than the path pads the end")
    func padding() throws {
        // A path of 9 points written over a 4 x 4 grid of triggers: the frames
        // past the ninth hold nothing.
        let placement = try path("hilbert", canvas: 3, kept: [4, 4], settle: 1)
            .placement(width: 3, height: 3)
        #expect(placement.frameCount == 16)
        #expect(placement.placedCount == 9)
        #expect(placement.unfilled == 0)
        #expect(placement.slots.suffix(6).allSatisfy { $0 == nil })
    }

    @Test("a scan size the path cannot cover is refused")
    func rasterChecked() throws {
        let hilbert = try path("hilbert", canvas: 128, kept: [128, 128], settle: 1)
        #expect(throws: MacSTEMScanPath.Failure.rasterDisagrees("hilbert", width: 64,
                                                                height: 256, canvas: 128)) {
            try hilbert.placement(width: 64, height: 256)
        }
    }

    // MARK: - Patterns that cannot be recomputed

    @Test("a raster and a serpentine are orders the reader already has")
    func named() throws {
        #expect(try MacSTEMScanPath.interpretation(pattern: "raster", canvas: 128, kept: nil,
                                                   settle: nil, points: nil, source: "")
                == .named(.raster))
        #expect(try MacSTEMScanPath.interpretation(pattern: "serpentine", canvas: 128, kept: nil,
                                                   settle: nil, points: nil, source: "")
                == .named(.snake))
    }

    @Test("an off-grid pattern says so rather than being approximated",
          arguments: ["round spiral", "cav spiral", "fibonacci", "lissajous"])
    func offGrid(pattern: String) throws {
        #expect(throws: MacSTEMScanPath.Failure.offGrid(pattern)) {
            try path(pattern, canvas: 128)
        }
    }

    @Test("an order that does not follow from the metadata says so")
    func notDerivable() throws {
        // Both are real macSTEM patterns. Neither is a function of its name and
        // its size, and a wrong order is not visible afterwards, so neither is
        // attempted.
        #expect(throws: (any Error).self) { try path("random", canvas: 128) }
        #expect(throws: (any Error).self) { try path("interleaved raster", canvas: 128) }
        #expect(throws: MacSTEMScanPath.Failure.patternUnknown("sawtooth")) {
            try path("sawtooth", canvas: 128)
        }
    }

    @Test("a pattern with no canvas cannot be drawn")
    func noCanvas() throws {
        #expect(throws: MacSTEMScanPath.Failure.noCanvas("hilbert")) {
            try MacSTEMScanPath.interpretation(pattern: "hilbert", canvas: nil, kept: [128, 128],
                                               settle: 1, points: nil, source: "")
        }
    }

    @Test("no pattern at all is not a failure")
    func silent() throws {
        #expect(try MacSTEMScanPath.interpretation(pattern: nil, canvas: 128, kept: nil,
                                                   settle: nil, points: nil, source: "") == nil)
        #expect(try MacSTEMScanPath.interpretation(pattern: "  ", canvas: 128, kept: nil,
                                                   settle: nil, points: nil, source: "") == nil)
    }
}

@Suite("macSTEM metadata")
struct MacSTEMMetadataTests {

    /// The tables macSTEM writes that bear on the scan path, taken from a real
    /// `metadata.toml` and trimmed to them.
    private static let acquisition = """
    [acquisition]
    name = "acquisition_5"
    timestamp = "2026-11-09T22:35:18.887972+00:00"

    [scan]
    frame_count = 16384
    dtype = "float32"
    width = 128
    height = 128
    scan_count = 1

    [instruments.ostech_ps01]
    pid_k = 3.0

    [instruments.scan_engine]
    service = "macSTEM"
    address = "192.168.6.1:47690"
    revstem = false
    pattern = "hilbert"
    field_of_view = [
        7.668711656441716e-08,
        7.668711656441716e-08,
    ]
    scan_rotation = -1.404793422929302

    [instruments.scan_engine.scan_path]
    pattern = "hilbert"
    n = 128
    points = 16384
    kept = [
        128,
        128,
    ]
    settle = 1
    positions = "Scan Path in macSTEM's file (x, y px of the path image, trigger order)"

    [raw_file]
    filename = "acquisition_5.raw"
    """

    private func read(_ text: String, named name: String = "metadata.toml") throws -> ScanMetadata {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try ScanMetadata.read(url: file)
    }

    @Test("a macSTEM acquisition arrives with its scan path already worked out")
    func computed() throws {
        let metadata = try read(Self.acquisition)
        let path = try #require(metadata.macSTEMScanPath)
        #expect(path.name == "hilbert")
        #expect(path.canvas == 128)
        #expect(path.keptWidth == 128 && path.keptHeight == 128)
        #expect(path.settle == 1)
        #expect(metadata.macSTEMScanPathNote == nil)

        // The canvas is the scan, and the field of view divided by it is the
        // step — both without anything being typed in.
        #expect(metadata.scanWidth == 128 && metadata.scanHeight == 128)
        #expect(try #require(metadata.scanStepNanometres).isApproximately(0.5991181))

        // These are the numbers the acquisition's own recorded positions give
        // for the same scan: 16,384 frames, the first of them not at a scan
        // position, and one position — the curve's last point — never reached.
        let placement = try #require(metadata.resolvedScanPath())
            .placement(width: 128, height: 128)
        #expect(placement.frameCount == 16384)
        #expect(placement.placedCount == 16383)
        #expect(placement.unfilled == 1)
        #expect(placement.slots[0] == nil)
        #expect(placement.slots[1] == 0)
        #expect(placement.slots[2] == 128)
    }

    @Test("macSTEM's scan rotation is read as the radians it is")
    func rotationInRadians() throws {
        // macSTEM's instrument interface is in radians throughout. Read as
        // degrees this is −1.4°, which is wrong and entirely plausible.
        let metadata = try read(Self.acquisition)
        #expect(try #require(metadata.scanRotationDegrees).isApproximately(-80.48873))
    }

    @Test("a cooler's PID gain is not mistaken for anything")
    func noFalsePositives() throws {
        // `pid_k` sits in the same file and has been read as a diffraction
        // calibration before now. The path fields are short — `n`, `points`,
        // `kept` — so this is the file to check that against.
        let metadata = try read(Self.acquisition)
        #expect(metadata.diffractionStepMilliradians == nil)
        #expect(metadata.voltageKilovolts == nil)
    }

    @Test("a pattern that cannot be recomputed says which file to load instead")
    func unreproducible() throws {
        let text = Self.acquisition
            .replacingOccurrences(of: "pattern = \"hilbert\"", with: "pattern = \"cav spiral\"")
        let metadata = try read(text)
        #expect(metadata.macSTEMScanPath == nil)
        let note = try #require(metadata.macSTEMScanPathNote)
        #expect(note.contains("cav spiral"))
        #expect(note.contains("scan_positions.npz"))
        // And the scan size still comes through, so the panel is not left empty.
        #expect(metadata.scanWidth == 128)
    }

    @Test("a plain macSTEM raster is read as a raster")
    func plainRaster() throws {
        // Both the engine's pattern and the path table have to go: a raster is
        // not a path scan, so macSTEM writes no path table for one.
        var text = Self.acquisition
            .replacingOccurrences(of: "pattern = \"hilbert\"\nn = 128", with: "x = 0\nn = 128")
        text = text.replacingOccurrences(of: "pattern = \"hilbert\"", with: "pattern = \"raster\"")
        let metadata = try read(text)
        #expect(metadata.macSTEMScanPath == nil)
        #expect(metadata.macSTEMScanPathNote == nil)
        #expect(metadata.scanPath == .raster)
        #expect(metadata.resolvedScanPath() == .raster)
    }

    @Test("metadata from anything but macSTEM is read as it was before")
    func notMacSTEM() throws {
        // An EMPAD2 TOML with a scan_path table would be a different thing
        // entirely, so the macSTEM reading hangs off the engine naming itself.
        let text = Self.acquisition
            .replacingOccurrences(of: "service = \"macSTEM\"", with: "service = \"other\"")
        let metadata = try read(text)
        #expect(metadata.macSTEMScanPath == nil)
        #expect(metadata.macSTEMScanPathNote == nil)
        // Including the scan rotation, which is then the degrees everyone else
        // writes.
        #expect(try #require(metadata.scanRotationDegrees).isApproximately(-1.4047934))
    }
}

private extension Float {
    func isApproximately(_ other: Float, within tolerance: Float = 1e-4) -> Bool {
        return abs(self - other) <= tolerance * Swift.max(1, abs(other))
    }
}
