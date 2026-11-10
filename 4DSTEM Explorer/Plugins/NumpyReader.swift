//
//  NumpyReader.swift
//  4DSTEM Explorer
//
//  Reading a .npy array, and a .npz archive of them, so an array written by a
//  Python script can be handed straight to the application without a conversion
//  step in between. The counterpart to NumpyWriter.
//
//  Two formats, one inside the other. A .npy file is a short header — a Python
//  dict literal naming the dtype, the storage order and the shape — followed by
//  the raw elements. A .npz file is an ordinary ZIP archive whose members are
//  .npy files, which is why most of this is a small ZIP reader.
//
//  The ZIP is read from its central directory at the end of the file rather
//  than by walking the local headers from the front. It costs a seek and it is
//  the only correct way: when an archive is written to a stream the local
//  header carries zeroes for the compressed and uncompressed sizes, with the
//  real values following the data in a descriptor, and `zipfile` — which is
//  what numpy writes through — does exactly that often enough to matter.
//
//  Not supported, and each refused by name rather than misread: ZIP64 (numpy
//  only writes it past 4 GB, which no array read here approaches), encryption,
//  compression methods other than stored and deflate, and structured or
//  object dtypes, which have no fixed element width.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Compression

enum NumpyReader {

    /// One array, as read.
    struct Array: Equatable {
        /// The member name inside a .npz, with the `.npy` suffix removed. Empty
        /// for a bare .npy file.
        var name: String
        /// Dimensions, slowest-varying first. Empty for a 0-d array, which is
        /// how numpy stores a lone scalar — `np.savez(units='m')` writes one.
        var shape: [Int]
        /// A numeric array's elements, in C order. Empty for a text array.
        ///
        /// Double rather than a per-dtype case because every numeric dtype this
        /// reads fits one exactly, with a single exception — a 64-bit integer
        /// beyond 2^53 — and nothing an array of scan positions or probe
        /// coordinates holds comes close to that. Keeping one representation
        /// means the callers do not each have to switch over five widths.
        var numbers: [Double]
        /// A text array's elements. Empty for a numeric array.
        ///
        /// Read because the files this exists for are self-describing: the scan
        /// positions written alongside a RAW scan carry their units, the name of
        /// the raw file and the name of the pattern as text members of the same
        /// archive, and ignoring them would mean asking the user for things the
        /// file already says.
        var strings: [String]

        var count: Int { return numbers.isEmpty ? strings.count : numbers.count }

        /// The sole element of a 0-d or one-element text array.
        var scalarString: String? {
            return strings.count == 1 ? strings[0] : nil
        }

        /// The elements as integers, or nil if any of them is not whole.
        ///
        /// A file whose indices were built in floating point still reads,
        /// because 3.0 is an index and 3.5 is a mistake.
        var integers: [Int]? {
            guard !numbers.isEmpty else { return nil }
            var result = [Int]()
            result.reserveCapacity(numbers.count)
            for value in numbers {
                guard value.rounded() == value, value.magnitude < 9.0e15 else { return nil }
                result.append(Int(value))
            }
            return result
        }
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case notNumpy(String)
        case badHeader(String)
        case unsupportedDType(String, String)
        case truncated(String)
        case zip64(String)
        case encrypted(String)
        case unsupportedCompression(String, UInt16)
        case noArrays(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "\(name) could not be read."
            case .notNumpy(let name):
                return "\(name) is not a .npy array or a .npz archive."
            case .badHeader(let name):
                return "\(name) has a header this reader does not understand."
            case .unsupportedDType(let name, let descr):
                return "\(name) holds '\(descr)', which is not a plain integer or floating-point array."
            case .truncated(let name):
                return "\(name) ends before the array does."
            case .zip64(let name):
                return "\(name) is a ZIP64 archive, which this reader does not read. Saving it with numpy below 4 GB avoids ZIP64 entirely."
            case .encrypted(let name):
                return "\(name) is encrypted."
            case .unsupportedCompression(let name, let method):
                return "\(name) uses compression method \(method); only stored and deflate are read. `numpy.savez` and `numpy.savez_compressed` both write one of those."
            case .noArrays(let name):
                return "\(name) has no arrays in it."
            }
        }
    }

    // MARK: - Entry points

    /// Every array in the file, whether it is a .npy or a .npz.
    ///
    /// Decided by what is in the file rather than by its extension: these get
    /// renamed, and a .npy that has been called .npz is not worth a failure.
    static func arrays(contentsOf url: URL) throws -> [Array] {
        let name = url.lastPathComponent
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
        return try arrays(in: [UInt8](data), name: name)
    }

    static func arrays(in bytes: [UInt8], name: String) throws -> [Array] {
        if bytes.starts(with: npyMagic) {
            return [try npy(bytes, name: "", file: name)]
        }
        if bytes.starts(with: [0x50, 0x4b]) {            // "PK"
            return try npz(bytes, name: name)
        }
        throw Failure.notNumpy(name)
    }

    // MARK: - .npy

    private static let npyMagic: [UInt8] = [0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59]   // \x93NUMPY

    /// One array out of .npy bytes.
    ///
    /// - Parameters:
    ///   - member: the name to record on the array — the .npz member it came
    ///     from, or empty for a bare file.
    ///   - file: the name to put in an error message, which is the file the
    ///     user chose rather than the member inside it.
    static func npy(_ bytes: [UInt8], name member: String, file: String) throws -> Array {
        guard bytes.starts(with: npyMagic), bytes.count >= 10 else { throw Failure.notNumpy(file) }

        // Version 1.0 writes the header length in two bytes, 2.0 and 3.0 in
        // four. The difference is the only thing the version changes here: 3.0
        // also promises a UTF-8 header, which a UTF-8 decode of a 1.0 ASCII
        // header reads identically.
        let major = bytes[6]
        let lengthWidth = major >= 2 ? 4 : 2
        let headerStart = 10 + lengthWidth - 2
        guard bytes.count >= headerStart else { throw Failure.truncated(file) }

        let headerLength: Int
        if lengthWidth == 2 {
            headerLength = Int(littleEndian(bytes, at: 8, count: 2))
        } else {
            headerLength = Int(littleEndian(bytes, at: 8, count: 4))
        }
        let bodyStart = headerStart + headerLength
        guard headerLength > 0, bodyStart <= bytes.count else { throw Failure.truncated(file) }

        guard let header = String(bytes: bytes[headerStart..<bodyStart], encoding: .utf8) else {
            throw Failure.badHeader(file)
        }

        guard let descr = capture(#"'descr'\s*:\s*'([^']*)'"#, in: header) else {
            throw Failure.badHeader(file)
        }
        guard let shapeText = capture(#"'shape'\s*:\s*\(([^)]*)\)"#, in: header) else {
            throw Failure.badHeader(file)
        }
        let fortran = capture(#"'fortran_order'\s*:\s*(True|False)"#, in: header) == "True"

        // A trailing comma is how Python spells a one-element tuple, so the
        // empty pieces it leaves behind are dropped rather than read as zeroes.
        let shape = shapeText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }
        guard shape.allSatisfy({ $0 >= 0 }) else { throw Failure.badHeader(file) }

        guard let type = DType(descr) else { throw Failure.unsupportedDType(file, descr) }

        let count = shape.reduce(1, *)
        guard bodyStart + count * type.size <= bytes.count else { throw Failure.truncated(file) }

        // Text and numbers are kept apart rather than coerced into one
        // representation: a unit or a pattern name is not a number that happens
        // to be spelled oddly, and nothing downstream wants it as one.
        var numbers = [Double]()
        var strings = [String]()
        if type.isText {
            strings.reserveCapacity(count)
            for element in 0..<count {
                strings.append(type.text(bytes, at: bodyStart + element * type.size))
            }
        } else {
            numbers.reserveCapacity(count)
            for element in 0..<count {
                numbers.append(type.value(bytes, at: bodyStart + element * type.size))
            }
        }

        // Column-major on disk, C order in memory. Only the 2-D case is
        // rearranged: 1-D is the same either way, and nothing here reads a
        // Fortran-ordered array of higher rank.
        if fortran, shape.count == 2 {
            let (rows, columns) = (shape[0], shape[1])
            if !numbers.isEmpty {
                var reordered = [Double](repeating: 0, count: count)
                for row in 0..<rows {
                    for column in 0..<columns {
                        reordered[row * columns + column] = numbers[column * rows + row]
                    }
                }
                numbers = reordered
            } else {
                var reordered = [String](repeating: "", count: count)
                for row in 0..<rows {
                    for column in 0..<columns {
                        reordered[row * columns + column] = strings[column * rows + row]
                    }
                }
                strings = reordered
            }
        } else if fortran, shape.count > 2 {
            throw Failure.badHeader(file)
        }

        return Array(name: member, shape: shape, numbers: numbers, strings: strings)
    }

    /// A dtype string: byte order, kind, width. `'<i4'`, `'|u1'`, `'>f8'`,
    /// `'<U18'`.
    private struct DType {
        enum Kind { case signed, unsigned, float, unicode, bytes }
        let kind: Kind
        /// Bytes per element, not characters: a `<U18` element is 72 bytes.
        let size: Int
        /// Characters per element, for the text kinds.
        let length: Int
        let littleEndian: Bool

        var isText: Bool { return kind == .unicode || kind == .bytes }

        init?(_ descr: String) {
            var text = Substring(descr)
            var little = true
            if let first = text.first, "<>=|".contains(first) {
                // '>' is big-endian; '=' and '|' both mean native, and every
                // platform this runs on is little-endian.
                little = first != ">"
                text = text.dropFirst()
            }
            guard let kindCharacter = text.first else { return nil }
            switch kindCharacter {
            case "i": kind = .signed
            case "u", "b": kind = .unsigned      // 'b1' is numpy's bool
            case "f": kind = .float
            case "U": kind = .unicode            // UTF-32 code points
            case "S", "a": kind = .bytes         // fixed-width bytes
            default: return nil
            }
            guard let width = Int(text.dropFirst()), width > 0 else { return nil }
            switch kind {
            case .float where width == 4 || width == 8:
                break
            case .signed where [1, 2, 4, 8].contains(width):
                break
            case .unsigned where [1, 2, 4, 8].contains(width):
                break
            case .unicode, .bytes:
                break
            default:
                return nil
            }
            length = width
            // A `U` width counts code points, each stored as four bytes; every
            // other kind's width is already its byte size.
            size = kind == .unicode ? width * 4 : width
            littleEndian = little
        }

        func value(_ bytes: [UInt8], at offset: Int) -> Double {
            let raw = littleEndian
                ? NumpyReader.littleEndian(bytes, at: offset, count: size)
                : NumpyReader.bigEndian(bytes, at: offset, count: size)
            switch kind {
            case .unsigned:
                return Double(raw)
            case .signed:
                // Sign-extend from the stored width.
                let shift = 64 - size * 8
                return Double(Int64(bitPattern: raw << UInt64(shift)) >> Int64(shift))
            case .float:
                return size == 4
                    ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
                    : Double(bitPattern: raw)
            case .unicode, .bytes:
                return .nan
            }
        }

        /// One text element. Both kinds are padded with zeroes to the full
        /// width, which is where the string ends.
        func text(_ bytes: [UInt8], at offset: Int) -> String {
            if kind == .bytes {
                var scalars = [UInt8]()
                for index in 0..<length {
                    let byte = bytes[offset + index]
                    if byte == 0 { break }
                    scalars.append(byte)
                }
                return String(decoding: scalars, as: UTF8.self)
            }
            var characters = String.UnicodeScalarView()
            for index in 0..<length {
                let raw = littleEndian
                    ? NumpyReader.littleEndian(bytes, at: offset + index * 4, count: 4)
                    : NumpyReader.bigEndian(bytes, at: offset + index * 4, count: 4)
                if raw == 0 { break }
                guard let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: raw)) else { continue }
                characters.append(scalar)
            }
            return String(characters)
        }
    }

    // MARK: - .npz

    private static func npz(_ bytes: [UInt8], name: String) throws -> [Array] {
        // The End Of Central Directory record, found by searching back from the
        // end. Its signature can appear inside a trailing comment, so the last
        // occurrence is the one that counts.
        let eocdSignature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let minimumEOCD = 22
        guard bytes.count >= minimumEOCD else { throw Failure.notNumpy(name) }

        var eocd: Int? = nil
        var position = bytes.count - minimumEOCD
        // A ZIP comment is at most 65535 bytes, so there is no reason to look
        // further back than that.
        let floor = max(0, bytes.count - minimumEOCD - 65535)
        while position >= floor {
            if Swift.Array(bytes[position..<position + 4]) == eocdSignature {
                eocd = position
                break
            }
            position -= 1
        }
        guard let end = eocd else { throw Failure.notNumpy(name) }

        // 0xffff entries or a 0xffffffff offset is how a ZIP64 archive looks
        // through a non-ZIP64 reader. Saying so beats reading nonsense.
        let entryCount = Int(littleEndian(bytes, at: end + 10, count: 2))
        let directorySize = Int(littleEndian(bytes, at: end + 12, count: 4))
        let directoryOffset = Int(littleEndian(bytes, at: end + 16, count: 4))
        if entryCount == 0xffff || directoryOffset == 0xffff_ffff || directorySize == 0xffff_ffff {
            throw Failure.zip64(name)
        }
        guard directoryOffset >= 0, directoryOffset + directorySize <= bytes.count else {
            throw Failure.truncated(name)
        }

        var arrays = [Array]()
        var cursor = directoryOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count,
                  Swift.Array(bytes[cursor..<cursor + 4]) == [0x50, 0x4b, 0x01, 0x02] else {
                throw Failure.truncated(name)
            }
            let flags = UInt16(littleEndian(bytes, at: cursor + 8, count: 2))
            let method = UInt16(littleEndian(bytes, at: cursor + 10, count: 2))
            let compressedSize = Int(littleEndian(bytes, at: cursor + 20, count: 4))
            let uncompressedSize = Int(littleEndian(bytes, at: cursor + 24, count: 4))
            let nameLength = Int(littleEndian(bytes, at: cursor + 28, count: 2))
            let extraLength = Int(littleEndian(bytes, at: cursor + 30, count: 2))
            let commentLength = Int(littleEndian(bytes, at: cursor + 32, count: 2))
            let localOffset = Int(littleEndian(bytes, at: cursor + 42, count: 4))

            guard cursor + 46 + nameLength <= bytes.count else { throw Failure.truncated(name) }
            let memberName = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameLength)],
                                    encoding: .utf8) ?? ""
            cursor += 46 + nameLength + extraLength + commentLength

            // Bit 0 is the encryption flag.
            if flags & 0x0001 != 0 { throw Failure.encrypted(name) }
            if compressedSize == 0xffff_ffff || uncompressedSize == 0xffff_ffff {
                throw Failure.zip64(name)
            }
            // A directory entry, which numpy does not write but an archive
            // assembled by hand might.
            if memberName.hasSuffix("/") { continue }

            // The local header's extra field is allowed to differ in length
            // from the central one's, so where the data starts has to be read
            // from the local header rather than assumed.
            guard localOffset + 30 <= bytes.count,
                  Swift.Array(bytes[localOffset..<localOffset + 4]) == [0x50, 0x4b, 0x03, 0x04] else {
                throw Failure.truncated(name)
            }
            let localNameLength = Int(littleEndian(bytes, at: localOffset + 26, count: 2))
            let localExtraLength = Int(littleEndian(bytes, at: localOffset + 28, count: 2))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= bytes.count else { throw Failure.truncated(name) }

            let stored = Swift.Array(bytes[dataStart..<dataStart + compressedSize])
            let member: [UInt8]
            switch method {
            case 0:
                member = stored
            case 8:
                guard let inflated = inflate(stored, to: uncompressedSize) else {
                    throw Failure.truncated(name)
                }
                member = inflated
            default:
                throw Failure.unsupportedCompression(name, method)
            }

            // Anything in the archive that is not an array is skipped rather
            // than refused: `np.savez` writes only .npy members, but an archive
            // someone has added a note to should still load.
            guard member.starts(with: npyMagic) else { continue }
            let label = memberName.hasSuffix(".npy")
                ? String(memberName.dropLast(4))
                : memberName
            arrays.append(try npy(member, name: label, file: name))
        }

        guard !arrays.isEmpty else { throw Failure.noArrays(name) }
        return arrays
    }

    /// Raw DEFLATE, which is what ZIP method 8 holds — no zlib wrapper, which is
    /// exactly what `COMPRESSION_ZLIB` means in this API despite its name.
    private static func inflate(_ bytes: [UInt8], to size: Int) -> [UInt8]? {
        guard size > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: size)
        let written = out.withUnsafeMutableBufferPointer { destination -> Int in
            return bytes.withUnsafeBufferPointer { source in
                compression_decode_buffer(destination.baseAddress!, size,
                                          source.baseAddress!, bytes.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? out : nil
    }

    // MARK: - Bytes

    private static func littleEndian(_ bytes: [UInt8], at offset: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count {
            value |= UInt64(bytes[offset + index]) << UInt64(8 * index)
        }
        return value
    }

    private static func bigEndian(_ bytes: [UInt8], at offset: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count {
            value = value << 8 | UInt64(bytes[offset + index])
        }
        return value
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
