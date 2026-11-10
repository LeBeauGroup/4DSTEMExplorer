//
//  NumpyReaderTests.swift
//  4DSTEM ExploreTests
//
//  Reading .npy and .npz. The fixtures below are not hand-written: they are the
//  exact bytes `numpy.savez` and `numpy.savez_compressed` produced for small
//  arrays, base64'd so the test needs no files on disk. That is the point of
//  them — a reader checked against its own idea of the format proves nothing,
//  and the details this gets wrong when it is wrong (the header padding, where
//  the member data starts, UTF-32 text, big-endian ints, Fortran order) are all
//  decided by the writer, not by us.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Testing
import Foundation
@testable import _DSTEM_Explorer

@Suite("NPY and NPZ input")
struct NumpyReaderTests {

    /// `np.savez(x=…, y=…, units='nm', pattern='snake', raw_file='scan_x2_y2.raw')`,
    /// stored uncompressed, which is what `savez` does.
    private static let stored =
          "UEsDBBQAAAAAAAAAIQA910B4oAAAAKAAAAAFABQAeC5ucHkBABAAoAAAAAAAAACgAAAAAAAAAJNOVU1QWQEAdgB7J2Rlc2NyJzog"
        + "JzxmOCcsICdmb3J0cmFuX29yZGVyJzogRmFsc2UsICdzaGFwZSc6ICg0LCksIH0gICAgICAgICAgICAgICAgICAgICAgICAgICAg"
        + "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKAAAAAAAAAAAAAAAAAAAAQAAAAAAAAABAAAAAAAAAAABQSwMEFAAAAAAA"
        + "AAAhAFnz2lOgAAAAoAAAAAUAFAB5Lm5weQEAEACgAAAAAAAAAKAAAAAAAAAAk05VTVBZAQB2AHsnZGVzY3InOiAnPGY4JywgJ2Zv"
        + "cnRyYW5fb3JkZXInOiBGYWxzZSwgJ3NoYXBlJzogKDQsKSwgfSAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg"
        + "ICAgICAgICAgICAgICAgICAgICAgIAoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAQFBLAwQUAAAAAAAAACEAdzEzR4gA"
        + "AACIAAAACQAUAHVuaXRzLm5weQEAEACIAAAAAAAAAIgAAAAAAAAAk05VTVBZAQB2AHsnZGVzY3InOiAnPFUyJywgJ2ZvcnRyYW5f"
        + "b3JkZXInOiBGYWxzZSwgJ3NoYXBlJzogKCksIH0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg"
        + "ICAgICAgICAgICAgICAgIApuAAAAbQAAAFBLAwQUAAAAAAAAACEA6cSRgJQAAACUAAAACwAUAHBhdHRlcm4ubnB5AQAQAJQAAAAA"
        + "AAAAlAAAAAAAAACTTlVNUFkBAHYAeydkZXNjcic6ICc8VTUnLCAnZm9ydHJhbl9vcmRlcic6IEZhbHNlLCAnc2hhcGUnOiAoKSwg"
        + "fSAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCnMAAABuAAAAYQAA"
        + "AGsAAABlAAAAUEsDBBQAAAAAAAAAIQDRkOLMuAAAALgAAAAMABQAcmF3X2ZpbGUubnB5AQAQALgAAAAAAAAAuAAAAAAAAACTTlVN"
        + "UFkBAHYAeydkZXNjcic6ICc8VTE0JywgJ2ZvcnRyYW5fb3JkZXInOiBGYWxzZSwgJ3NoYXBlJzogKCksIH0gICAgICAgICAgICAg"
        + "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCnMAAABjAAAAYQAAAG4AAABfAAAAeAAAADIA"
        + "AABfAAAAeQAAADIAAAAuAAAAcgAAAGEAAAB3AAAAUEsBAhQDFAAAAAAAAAAhAD3XQHigAAAAoAAAAAUAAAAAAAAAAAAAAIABAAAA"
        + "AHgubnB5UEsBAhQDFAAAAAAAAAAhAFnz2lOgAAAAoAAAAAUAAAAAAAAAAAAAAIAB1wAAAHkubnB5UEsBAhQDFAAAAAAAAAAhAHcx"
        + "M0eIAAAAiAAAAAkAAAAAAAAAAAAAAIABrgEAAHVuaXRzLm5weVBLAQIUAxQAAAAAAAAAIQDpxJGAlAAAAJQAAAALAAAAAAAAAAAA"
        + "AACAAXECAABwYXR0ZXJuLm5weVBLAQIUAxQAAAAAAAAAIQDRkOLMuAAAALgAAAAMAAAAAAAAAAAAAACAAUIDAAByYXdfZmlsZS5u"
        + "cHlQSwUGAAAAAAUABQAQAQAAOAQAAAAA"

    /// The same x and y through `np.savez_compressed`, so the deflate path is
    /// exercised rather than assumed.
    private static let compressed =
          "UEsDBBQAAAAIAAAAIQA910B4SwAAAKAAAAAFABQAeC5ucHkBABAAoAAAAAAAAABLAAAAAAAAAJvsF+obEMnIUMZQrZ6SWpxcpG6l"
        + "oG6TZqGuo6Cell9UUpSYF59flJIKEndLzClOBYoXZyQWpAL5GiY6mjoKtQoUAC4GVOCARjMAAFBLAwQUAAAACAAAACEAWfPaU0oA"
        + "AACgAAAABQAUAHkubnB5AQAQAKAAAAAAAAAASgAAAAAAAACb7BfqGxDJyFDGUK2eklqcXKRupaBuk2ahrqOgnpZfVFKUmBefX5SS"
        + "ChJ3S8wpTgWKF2ckFqQC+RomOpo6CrUKFAAuBuzAAUYDAFBLAwQUAAAACAAAACEAdzEzR0kAAACIAAAACQAUAHVuaXRzLm5weQEA"
        + "EACIAAAAAAAAAEkAAAAAAAAAm+wX6hsQychQxlCtnpJanFykbqWgbhNqpK6joJ6WX1RSlJgXn1+UkgoSd0vMKU4FihdnJBakAvka"
        + "mjoKtQoUAa48BgaGXCAGAFBLAQIUAxQAAAAIAAAAIQA910B4SwAAAKAAAAAFAAAAAAAAAAAAAACAAQAAAAB4Lm5weVBLAQIUAxQA"
        + "AAAIAAAAIQBZ89pTSgAAAKAAAAAFAAAAAAAAAAAAAACAAYIAAAB5Lm5weVBLAQIUAxQAAAAIAAAAIQB3MTNHSQAAAIgAAAAJAAAA"
        + "AAAAAAAAAACAAQMBAAB1bml0cy5ucHlQSwUGAAAAAAMAAwCdAAAAhwEAAAAA"

    /// One member per dtype worth worrying about: int16 with negatives, uint32,
    /// float32, a big-endian int32, fixed-width bytes, and a Fortran-ordered
    /// 2-D float64 array.
    private static let mixed =
          "UEsDBBQAAAAAAAAAIQB2SSJjiAAAAIgAAAAFABQAaS5ucHkBABAAiAAAAAAAAACIAAAAAAAAAJNOVU1QWQEAdgB7J2Rlc2NyJzog"
        + "JzxpMicsICdmb3J0cmFuX29yZGVyJzogRmFsc2UsICdzaGFwZSc6ICg0LCksIH0gICAgICAgICAgICAgICAgICAgICAgICAgICAg"
        + "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAK/v///wAAAQBQSwMEFAAAAAAAAAAhAPQbvBSMAAAAjAAAAAUAFAB1Lm5w"
        + "eQEAEACMAAAAAAAAAIwAAAAAAAAAk05VTVBZAQB2AHsnZGVzY3InOiAnPHU0JywgJ2ZvcnRyYW5fb3JkZXInOiBGYWxzZSwgJ3No"
        + "YXBlJzogKDMsKSwgfSAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAoB"
        + "AAAAAgAAAAMAAABQSwMEFAAAAAAAAAAhAKaHdYmIAAAAiAAAAAUAFABmLm5weQEAEACIAAAAAAAAAIgAAAAAAAAAk05VTVBZAQB2"
        + "AHsnZGVzY3InOiAnPGY0JywgJ2ZvcnRyYW5fb3JkZXInOiBGYWxzZSwgJ3NoYXBlJzogKDIsKSwgfSAgICAgICAgICAgICAgICAg"
        + "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAoAAMA/AACAvlBLAwQUAAAAAAAAACEAbfVd6YgAAACI"
        + "AAAABgAUAGJlLm5weQEAEACIAAAAAAAAAIgAAAAAAAAAk05VTVBZAQB2AHsnZGVzY3InOiAnPmk0JywgJ2ZvcnRyYW5fb3JkZXIn"
        + "OiBGYWxzZSwgJ3NoYXBlJzogKDIsKSwgfSAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg"
        + "ICAgICAgICAgIAoAAAABAAABAFBLAwQUAAAAAAAAACEAtjXx14QAAACEAAAABQAUAHMubnB5AQAQAIQAAAAAAAAAhAAAAAAAAACT"
        + "TlVNUFkBAHYAeydkZXNjcic6ICd8UzInLCAnZm9ydHJhbl9vcmRlcic6IEZhbHNlLCAnc2hhcGUnOiAoMiwpLCB9ICAgICAgICAg"
        + "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCmFiYwBQSwMEFAAAAAAAAAAhAAsnYNuw"
        + "AAAAsAAAAAYAFABmMi5ucHkBABAAsAAAAAAAAACwAAAAAAAAAJNOVU1QWQEAdgB7J2Rlc2NyJzogJzxmOCcsICdmb3J0cmFuX29y"
        + "ZGVyJzogVHJ1ZSwgJ3NoYXBlJzogKDIsIDMpLCB9ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg"
        + "ICAgICAgICAgICAgICAKAAAAAAAA8D8AAAAAAAAQQAAAAAAAAABAAAAAAAAAFEAAAAAAAAAIQAAAAAAAABhAUEsBAhQDFAAAAAAA"
        + "AAAhAHZJImOIAAAAiAAAAAUAAAAAAAAAAAAAAIABAAAAAGkubnB5UEsBAhQDFAAAAAAAAAAhAPQbvBSMAAAAjAAAAAUAAAAAAAAA"
        + "AAAAAIABvwAAAHUubnB5UEsBAhQDFAAAAAAAAAAhAKaHdYmIAAAAiAAAAAUAAAAAAAAAAAAAAIABggEAAGYubnB5UEsBAhQDFAAA"
        + "AAAAAAAhAG31XemIAAAAiAAAAAYAAAAAAAAAAAAAAIABQQIAAGJlLm5weVBLAQIUAxQAAAAAAAAAIQC2NfHXhAAAAIQAAAAFAAAA"
        + "AAAAAAAAAACAAQEDAABzLm5weVBLAQIUAxQAAAAAAAAAIQALJ2DbsAAAALAAAAAGAAAAAAAAAAAAAACAAbwDAABmMi5ucHlQSwUG"
        + "AAAAAAYABgA0AQAApAQAAAAA"

    private func read(_ base64: String) throws -> [NumpyReader.Array] {
        let data = try #require(Data(base64Encoded: base64))
        return try NumpyReader.arrays(in: [UInt8](data), name: "fixture.npz")
    }

    private func member(_ arrays: [NumpyReader.Array], _ name: String) throws -> NumpyReader.Array {
        return try #require(arrays.first { $0.name == name })
    }

    @Test("every member of an uncompressed archive is found")
    func storedMembers() throws {
        let arrays = try read(Self.stored)
        #expect(Set(arrays.map { $0.name }) == ["x", "y", "units", "pattern", "raw_file"])
        #expect(try member(arrays, "x").numbers == [0, 2, 2, 0])
        #expect(try member(arrays, "y").numbers == [0, 0, 2, 2])
        #expect(try member(arrays, "x").shape == [4])
    }

    @Test("text members are read as text, not as numbers")
    func textMembers() throws {
        // numpy stores these as UTF-32 code points, four bytes each, padded
        // with zeroes to the declared width.
        let arrays = try read(Self.stored)
        #expect(try member(arrays, "units").scalarString == "nm")
        #expect(try member(arrays, "pattern").scalarString == "snake")
        #expect(try member(arrays, "raw_file").scalarString == "scan_x2_y2.raw")
        // A 0-d array, which is how numpy stores a lone scalar.
        #expect(try member(arrays, "units").shape == [])
        #expect(try member(arrays, "units").numbers.isEmpty)
    }

    @Test("a deflated archive reads the same as a stored one")
    func compressedArchive() throws {
        let arrays = try read(Self.compressed)
        #expect(try member(arrays, "x").numbers == [0, 2, 2, 0])
        #expect(try member(arrays, "y").numbers == [0, 0, 2, 2])
    }

    @Test("each dtype comes back with its own values")
    func dtypes() throws {
        let arrays = try read(Self.mixed)
        #expect(try member(arrays, "i").numbers == [-2, -1, 0, 1])      // int16, sign-extended
        #expect(try member(arrays, "u").numbers == [1, 2, 3])           // uint32
        #expect(try member(arrays, "f").numbers == [1.5, -0.25])        // float32
        #expect(try member(arrays, "be").numbers == [1, 256])           // big-endian int32
        #expect(try member(arrays, "s").strings == ["ab", "c"])         // fixed-width bytes
    }

    @Test("a Fortran-ordered array is rearranged into C order")
    func fortranOrder() throws {
        // Stored column by column; every caller here indexes row by row, so
        // reading it as-is would transpose the array silently.
        let arrays = try read(Self.mixed)
        let f2 = try member(arrays, "f2")
        #expect(f2.shape == [2, 3])
        #expect(f2.numbers == [1, 2, 3, 4, 5, 6])
    }

    @Test("what this writes, this reads")
    func roundTripsTheWriter() throws {
        let values: [Float] = [1, -2.5, 3, 4, 0.125, 6]
        let data = try #require(NumpyWriter.float32(values, shape: [2, 3]))
        let array = try NumpyReader.npy([UInt8](data), name: "", file: "round-trip.npy")
        #expect(array.shape == [2, 3])
        #expect(array.numbers == values.map { Double($0) })
    }

    @Test("a file that is neither is refused by name")
    func notNumpy() {
        #expect(throws: NumpyReader.Failure.notNumpy("junk.npz")) {
            try NumpyReader.arrays(in: [0x00, 0x01, 0x02, 0x03], name: "junk.npz")
        }
    }

    @Test("a truncated archive is refused rather than read short")
    func truncated() throws {
        let data = try #require(Data(base64Encoded: Self.stored))
        var bytes = [UInt8](data)
        // Keep the end-of-central-directory record, cut the member data out
        // from under it.
        bytes.removeSubrange(200..<400)
        #expect(throws: (any Error).self) {
            try NumpyReader.arrays(in: bytes, name: "cut.npz")
        }
    }

    @Test("the positions a scan path needs come straight out of the archive")
    func positionsFromArchive() throws {
        // The whole point of the reader: a 2x2 snake with its pattern name and
        // its raw file, read end to end.
        let data = try #require(Data(base64Encoded: Self.stored))
        let arrays = try NumpyReader.arrays(in: [UInt8](data), name: "scan_positions.npz")
        let positions = try ScanPositions.interpret(arrays, label: "scan_positions.npz")
        #expect(positions.frameCount == 4)
        #expect(positions.pattern == "snake")
        #expect(positions.rawFile == "scan_x2_y2.raw")
        #expect(positions.unit == "nm")
        #expect(positions.inferredRaster()?.width == 2)
        #expect(positions.inferredScanStepNanometres() == 2)
        let placement = try positions.placement(width: 2, height: 2)
        #expect(placement.slots == [0, 1, 3, 2].map { Optional($0) })
    }
}
