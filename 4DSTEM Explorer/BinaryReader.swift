//
//  BinaryReader.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 7/28/25.
//  Copyright © 2025 The LeBeau Group. All rights reserved.
//

import Foundation

enum BinaryReaderError: Error {
    case stringDecodingFailed
}

struct BinaryReader {
    let data: Data
    var offset: Int = 0

    enum Endian {
        case little
        case big
    }

    mutating func readUInt8() throws -> UInt8 {
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16(endian: Endian) throws -> UInt16 {
        let range = offset..<(offset+2)
        defer { offset += 2 }
        let value = data.subdata(in: range).withUnsafeBytes { $0.load(as: UInt16.self) }
        return endian == .little ? UInt16(littleEndian: value) : UInt16(bigEndian: value)
    }
    
    mutating func readInt16(endian: Endian) throws -> Int16 {
        let range = offset..<(offset+2)
        defer { offset += 2 }
        let value = data.subdata(in: range).withUnsafeBytes { $0.load(as: Int16.self) }
        return endian == .little ? Int16(littleEndian: value) : Int16(bigEndian: value)
    }

    
    mutating func readUInt32(endian: Endian) throws -> UInt32 {
        let range = offset..<(offset+4)
        defer { offset += 4 }
        let value = data.subdata(in: range).withUnsafeBytes { $0.load(as: UInt32.self) }
        return endian == .little ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
    }

    mutating func readInt32(endian: Endian) throws -> Int32 {
        let range = offset..<(offset+4)
        defer { offset += 4 }
        let value = data.subdata(in: range).withUnsafeBytes { $0.load(as: Int32.self) }
        return endian == .little ? Int32(littleEndian: value) : Int32(bigEndian: value)
    }

    mutating func readInt64(endian: Endian) throws -> Int64 {
        let range = offset..<(offset+8)
        defer { offset += 8 }
        let value = data.subdata(in: range).withUnsafeBytes { $0.load(as: Int64.self) }
        return endian == .little ? Int64(littleEndian: value) : Int64(bigEndian: value)
    }

    mutating func readFloat32(endian: Endian) throws -> Float32 {
        let range = offset..<(offset+4)
        defer { offset += 4 }
        let value = data.subdata(in: range).withUnsafeBytes { $0.load(as: Float32.self) }
        return endian == .little ? Float32(bitPattern: value.bitPattern.littleEndian) : value
    }
    
    mutating func readFloat64(endian: Endian) throws -> Double {
        let range = offset..<(offset+8)
        defer { offset += 8 }
        let value = data.subdata(in: range).withUnsafeBytes { $0.load(as: Double.self) }
        return endian == .little ? Double(bitPattern: value.bitPattern.littleEndian) : value
    }
    
    mutating func readDouble(endian: Endian) throws -> Double {
        let range = offset..<(offset+8)
        defer { offset += 8 }
        let value = data.subdata(in: range).withUnsafeBytes { $0.load(as: Double.self) }
        return endian == .little ? Double(bitPattern: value.bitPattern.littleEndian) : value
    }

    mutating func readString(length: Int) throws -> String {
        let range = offset..<(offset + length)
        let rawData = data.subdata(in: range)
        offset += length

        if let utf8 = String(data: rawData, encoding: .utf8) {
            return utf8
        } else if let latin1 = String(data: rawData, encoding: .isoLatin1) {
            return latin1
        } else {
            throw BinaryReaderError.stringDecodingFailed
        }
    }
}
