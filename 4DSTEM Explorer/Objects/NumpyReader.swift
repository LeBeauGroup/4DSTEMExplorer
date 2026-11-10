//
//  NumpyReader.swift
//  4DSTEM Explorer
//
//  Reads .npy arrays, and the .npz archives that hold several of them.
//
//  The counterpart to `NumpyWriter`, and deliberately a narrow one: enough to
//  read the position arrays and name strings macSTEM saves beside an
//  acquisition, and no more. An .npz is a ZIP of .npy members; numpy's own
//  `savez` stores them uncompressed, which is what lets this get away without
//  an inflate — `savez_compressed` is refused with a message that says so
//  rather than returning something wrong.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

/// An .npz: a ZIP holding one .npy per array.
enum NPZArchive {

    private static let endOfCentralDirectory: UInt32 = 0x0605_4b50
    private static let centralFileHeader: UInt32 = 0x0201_4b50
    private static let localFileHeader: UInt32 = 0x0403_4b50
    private static let stored: UInt16 = 0

    /// Every member, by name ("x.npy"), with its bytes.
    static func members(_ bytes: [UInt8], name: String) throws -> [String: [UInt8]] {
        guard let directory = locateCentralDirectory(bytes) else {
            throw ScanPathError.notAnArchive(name)
        }

        var members: [String: [UInt8]] = [:]
        var cursor = directory

        while cursor + 46 <= bytes.count,
              readUInt32(bytes, cursor) == centralFileHeader {
            let method = readUInt16(bytes, cursor + 10)
            let compressed = Int(readUInt32(bytes, cursor + 20))
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localOffset = Int(readUInt32(bytes, cursor + 42))

            guard cursor + 46 + nameLength <= bytes.count else { break }
            let memberName = asciiText(bytes, from: cursor + 46, count: nameLength)

            guard method == stored else {
                throw ScanPathError.compressed(name)
            }

            // The central directory says where the member's local header is;
            // the data starts past that header, whose own name and extra
            // fields may be a different length from the directory's.
            if localOffset + 30 <= bytes.count,
               readUInt32(bytes, localOffset) == localFileHeader {
                let localNameLength = Int(readUInt16(bytes, localOffset + 26))
                let localExtraLength = Int(readUInt16(bytes, localOffset + 28))
                let start = localOffset + 30 + localNameLength + localExtraLength
                if start + compressed <= bytes.count {
                    members[memberName] = Array(bytes[start..<(start + compressed)])
                }
            }

            cursor += 46 + nameLength + extraLength + commentLength
        }

        guard !members.isEmpty else { throw ScanPathError.notAnArchive(name) }
        return members
    }

    /// The central directory's offset, from the record at the end of the file.
    ///
    /// Searched backwards because the record is followed by a comment of any
    /// length, so its position is not fixed.
    private static func locateCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let earliest = max(0, bytes.count - 22 - 65_535)
        var cursor = bytes.count - 22
        while cursor >= earliest {
            if readUInt32(bytes, cursor) == endOfCentralDirectory {
                let offset = Int(readUInt32(bytes, cursor + 16))
                return offset < bytes.count ? offset : nil
            }
            cursor -= 1
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

/// One .npy member.
enum NPYArray {

    /// The header: where the values start, and what they are.
    private struct Header {
        let descriptor: String
        let valuesAt: Int
        let count: Int
    }

    /// A float64 array, in file order.
    static func doubles(_ bytes: [UInt8], name: String) throws -> [Double] {
        guard let header = parse(bytes) else {
            throw ScanPathError.unsupportedArray(name, "an unreadable .npy header")
        }
        // '<f8' is what numpy writes for float64 on every machine this runs on;
        // '|' and '=' mean the native order, which is also little-endian here.
        guard header.descriptor.hasSuffix("f8") else {
            throw ScanPathError.unsupportedArray(name, "'\(header.descriptor)' rather than float64")
        }
        guard !header.descriptor.hasPrefix(">") else {
            throw ScanPathError.unsupportedArray(name, "big-endian float64")
        }
        guard header.valuesAt + header.count * 8 <= bytes.count else {
            throw ScanPathError.unsupportedArray(name, "fewer values than its shape promises")
        }

        var values = [Double](repeating: 0, count: header.count)
        for i in 0..<header.count {
            var pattern: UInt64 = 0
            let base = header.valuesAt + i * 8
            for byte in 0..<8 {
                pattern |= UInt64(bytes[base + byte]) << (8 * UInt64(byte))
            }
            values[i] = Double(bitPattern: pattern)
        }
        return values
    }

    /// A unicode scalar saved by numpy — a '<U…' of shape () — as a String.
    ///
    /// numpy pads these to their declared width with NUL, which is trimmed.
    static func string(_ bytes: [UInt8]) -> String? {
        guard let header = parse(bytes),
              header.descriptor.contains("U") else { return nil }
        var scalars = String.UnicodeScalarView()
        var cursor = header.valuesAt
        while cursor + 4 <= bytes.count {
            var point: UInt32 = 0
            for byte in 0..<4 {
                point |= UInt32(bytes[cursor + byte]) << (8 * UInt32(byte))
            }
            cursor += 4
            if point == 0 { break }
            guard let scalar = Unicode.Scalar(point) else { break }
            scalars.append(scalar)
        }
        let text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Splits an .npy into its header and its values.
    private static func parse(_ bytes: [UInt8]) -> Header? {
        let magic: [UInt8] = [0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59]   // \x93NUMPY
        guard bytes.count > 10, Array(bytes[0..<6]) == magic else { return nil }

        // Version 1 writes the header's length in two bytes, 2 and 3 in four.
        let major = bytes[6]
        let lengthBytes = major >= 2 ? 4 : 2
        var headerLength = 0
        for byte in 0..<lengthBytes {
            headerLength |= Int(bytes[8 + byte]) << (8 * byte)
        }
        let valuesAt = 8 + lengthBytes + headerLength
        guard valuesAt <= bytes.count else { return nil }

        let text = asciiText(bytes, from: 8 + lengthBytes, count: headerLength)
        guard let descriptor = value(of: "descr", in: text) else { return nil }

        // The shape is a tuple: () is a scalar, (16384,) an array. Its product
        // is how many values follow.
        var count = 1
        if let shape = between("(", ")", in: text, after: "'shape'") {
            let dimensions = shape.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .compactMap { Int($0) }
            count = dimensions.reduce(1, *)
        }

        return Header(descriptor: descriptor, valuesAt: valuesAt, count: count)
    }

    /// The quoted value of `key` in an .npy header dictionary.
    private static func value(of key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "'\(key)'") else { return nil }
        let rest = text[keyRange.upperBound...]
        guard let open = rest.firstIndex(of: "'") else { return nil }
        let after = rest[rest.index(after: open)...]
        guard let close = after.firstIndex(of: "'") else { return nil }
        return String(after[..<close])
    }

    private static func between(_ open: String, _ close: String,
                                in text: String, after marker: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let rest = text[markerRange.upperBound...]
        guard let start = rest.range(of: open),
              let end = rest.range(of: close, range: start.upperBound..<rest.endIndex) else {
            return nil
        }
        return String(rest[start.upperBound..<end.lowerBound])
    }
}

/// A run of bytes as text, for the ASCII that .npy headers and ZIP names are.
private func asciiText(_ bytes: [UInt8], from offset: Int, count: Int) -> String {
    let end = min(bytes.count, offset + count)
    guard offset >= 0, offset < end else { return "" }
    return String(decoding: bytes[offset..<end], as: UTF8.self)
}
