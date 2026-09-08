//
//  NumpyWriter.swift
//  4DSTEM Explorer
//
//  Writing a .npy file, so a measured array can be handed to a Python
//  reconstruction without a conversion step in between.
//
//  The format is small but has one rule that is easy to miss: the header is
//  padded so the array data begins on a 64-byte boundary. NumPy will load a
//  file that ignores this, but memory-mapping it is then unaligned, and some
//  readers reject it outright. The padding is computed here rather than
//  guessed, and checked in the tests against numpy itself.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

enum NumpyWriter {

    /// A little-endian float32 array, version 1.0 of the format.
    ///
    /// - Parameter shape: the dimensions, slowest-varying first. The values are
    ///   C-ordered, which is what `fortran_order: False` promises.
    static func float32(_ values: [Float], shape: [Int]) -> Data? {
        let count = shape.reduce(1, *)
        guard !shape.isEmpty, shape.allSatisfy({ $0 > 0 }), values.count == count else { return nil }

        // A one-element shape still needs its trailing comma — `(2)` is the
        // number two in Python, `(2,)` is a tuple.
        let dimensions = shape.map(String.init).joined(separator: ", ")
        let tuple = shape.count == 1 ? "(\(dimensions),)" : "(\(dimensions))"
        let description = "{'descr': '<f4', 'fortran_order': False, 'shape': \(tuple), }"

        // 6 bytes of magic, 2 of version, 2 of header length: 10 before the
        // header text, which must itself end in a newline.
        let preamble = 10
        let unpadded = preamble + description.utf8.count + 1
        let padding = (64 - unpadded % 64) % 64
        let header = description + String(repeating: " ", count: padding) + "\n"

        var data = Data([0x93])
        data.append(contentsOf: Array("NUMPY".utf8))
        data.append(contentsOf: [0x01, 0x00])                   // version 1.0
        let length = UInt16(header.utf8.count)
        data.append(contentsOf: [UInt8(length & 0xff), UInt8(length >> 8)])   // little-endian
        data.append(contentsOf: Array(header.utf8))

        // Float is already little-endian on every platform this runs on, and
        // the descriptor above says so explicitly.
        values.withUnsafeBufferPointer { buffer in
            data.append(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count)
                .withMemoryRebound(to: UInt8.self) { Data($0) })
        }
        return data
    }
}
