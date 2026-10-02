//
//  BitShuffleLZ4.swift
//  4DSTEM Explorer
//
//  Decodes the "bslz4" chunks DECTRIS detectors write — bitshuffle followed by
//  LZ4 — which libhdf5 cannot read on its own.
//
//  HDF5 filter 32008 is not part of the library; it is a plugin, and without it
//  a read returns nothing at all rather than failing. So the chunks are fetched
//  raw and decoded here. That keeps a binary plugin out of the app bundle,
//  which would otherwise have to be signed, notarised and kept in step with
//  whatever libhdf5 the app links.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Compression

enum BitShuffleLZ4 {

    enum Failure: Error, LocalizedError {
        case truncatedHeader
        case truncatedBlock(index: Int)
        case lz4Failed(block: Int)
        case sizeMismatch(expected: Int, got: Int)

        var errorDescription: String? {
            switch self {
            case .truncatedHeader: return "A compressed chunk is too short to hold its header."
            case .truncatedBlock(let i): return "Compressed block \(i) runs past the end of the chunk."
            case .lz4Failed(let i): return "Block \(i) could not be decompressed."
            case .sizeMismatch(let e, let g): return "A chunk decoded to \(g) bytes where \(e) were expected."
            }
        }
    }

    /// Decodes one chunk.
    ///
    /// Layout, big-endian throughout: eight bytes of total decoded size, four
    /// of block size in bytes, then each block prefixed with its own compressed
    /// length. Blocks are bit-shuffled and then LZ4'd, so they are undone in
    /// the opposite order.
    static func decode(_ chunk: Data, elementSize: Int) throws -> [UInt8] {
        guard chunk.count >= 12 else { throw Failure.truncatedHeader }

        let bytes = [UInt8](chunk)
        func be32(_ at: Int) -> Int {
            return (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16)
                 | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
        }
        var total = 0
        for i in 0..<8 { total = (total << 8) | Int(bytes[i]) }
        let blockBytes = be32(8)

        guard total > 0, blockBytes > 0, elementSize > 0 else {
            throw Failure.sizeMismatch(expected: total, got: 0)
        }

        var out = [UInt8](repeating: 0, count: total)
        var cursor = 12
        var written = 0

        // The trailing block is shorter than the rest and is written the same
        // way, so the loop simply runs until the decoded bytes are accounted
        // for rather than dividing the total by the block size.
        var blockIndex = 0
        while written < total {
            let remaining = total - written
            let thisBlock = min(blockBytes, remaining)
            guard cursor + 4 <= bytes.count else { throw Failure.truncatedBlock(index: blockIndex) }
            let compressed = be32(cursor)
            cursor += 4
            guard compressed > 0, cursor + compressed <= bytes.count else {
                throw Failure.truncatedBlock(index: blockIndex)
            }

            var shuffled = [UInt8](repeating: 0, count: thisBlock)
            let produced: Int = shuffled.withUnsafeMutableBufferPointer { dst in
                bytes.withUnsafeBufferPointer { src in
                    compression_decode_buffer(dst.baseAddress!, thisBlock,
                                              src.baseAddress! + cursor, compressed,
                                              nil, COMPRESSION_LZ4_RAW)
                }
            }
            guard produced == thisBlock else { throw Failure.lz4Failed(block: blockIndex) }
            cursor += compressed

            unshuffle(shuffled, into: &out, at: written,
                      elements: thisBlock / elementSize, elementSize: elementSize)
            written += thisBlock
            blockIndex += 1
        }

        guard written == total else { throw Failure.sizeMismatch(expected: total, got: written) }
        return out
    }

    /// Undoes the bit transpose for one block.
    ///
    /// Forward, bitshuffle treats the block as a matrix of `elements` rows by
    /// `8 * elementSize` columns of bits and transposes it, so that the same bit
    /// of every element ends up adjacent — which is what gives LZ4 long runs to
    /// work with. Undoing it is the transpose back.
    ///
    /// Elements beyond a multiple of eight cannot take part in a bit transpose
    /// and are copied through untouched, exactly as the encoder left them.
    private static func unshuffle(_ input: [UInt8], into out: inout [UInt8], at offset: Int,
                                  elements: Int, elementSize: Int) {
        let transposable = elements - elements % 8
        let bitsPerElement = 8 * elementSize

        if transposable > 0 {
            let planeBytes = transposable / 8
            input.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for bit in 0..<bitsPerElement {
                        let byteInElement = bit >> 3
                        let bitInByte = bit & 7
                        let planeStart = bit * planeBytes
                        for chunk in 0..<planeBytes {
                            let packed = src[planeStart + chunk]
                            guard packed != 0 else { continue }
                            let firstElement = chunk << 3
                            for lane in 0..<8 where (packed >> UInt8(lane)) & 1 == 1 {
                                let element = firstElement + lane
                                let index = offset + element * elementSize + byteInElement
                                dst[index] |= UInt8(1 << bitInByte)
                            }
                        }
                    }
                }
            }
        }

        if transposable < elements {
            let tailStart = transposable * elementSize
            let tailBytes = (elements - transposable) * elementSize
            for i in 0..<tailBytes { out[offset + tailStart + i] = input[tailStart + i] }
        }
    }
}
