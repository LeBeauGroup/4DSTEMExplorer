// DigitalMicrographReader.swift
// Swift port of RosettaSciIO's DM3/DM4 file reader
// Compatible with macOS (no iOS-specific features)

import Foundation

// MARK: - BinaryReader Extension

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
struct LazyDataReference {
    let offset: Int
    let size: Int
    let type: Int
}

// DigitalMicrographReader.swift
// Swift port of RosettaSciIO's DM3/DM4 file reader
// Compatible with macOS (no iOS-specific features)

import Foundation
import Accelerate

enum DMReaderError: Error {
    case unsupportedVersion(Int)
    case invalidTagDelimiter(String)
    case unknownTagID(Int)
    case unsupportedDataType(Int)
}

class DigitalMicrographReader {
    var dmVersion: Int?
    var endian: Endianness = .big
    var tagsDict: [String: Any] = [:]
    private var reader: BinaryReader
    
    init(fileURL: URL) throws {
        let fileData = try Data(contentsOf: fileURL)
        self.reader = BinaryReader(data: fileData)
        
        try self.parseFile()
    }
    
    func parseFile() throws {
        try parseHeader()
        tagsDict = ["root": [:]]
        let (_, _, numberOfRootTags) = try parseTagGroup()
        
        if var rootGroup = tagsDict["root"] as? [String: Any] {
            try parseTags(ntags: numberOfRootTags, groupName: "root", groupDict: &rootGroup)
            tagsDict["root"] = rootGroup
        }
        //        try parseTags(ntags: numberOfRootTags, groupName: "root", groupDict: &tagsDict["root"] as! inout [String: Any])
    }
    
    private func parseHeader() throws {
        dmVersion = Int(try reader.readInt32(endian: .big))
        guard dmVersion == 3 || dmVersion == 4 else {
            throw DMReaderError.unsupportedVersion(dmVersion ?? -1)
        }
        
        let filesizeB = try readLOrQ()
        let isLittleEndian = try reader.readInt32(endian: .big) != 0
        self.endian = isLittleEndian ? .little : .big
        
        print("DM version: \(dmVersion!)")
        print("File size: \(filesizeB) bytes")
        print("Endian: \(endian)")
    }
    
    private func parseTags(ntags: Int, groupName: String, groupDict: inout [String: Any]) throws {
        for _ in 0..<ntags {
            
            let tagHeader = try parseTagHeader()
            var tagName = tagHeader.tagName.replacingOccurrences(of: ".", with: "")
            var unnamedCounter = 0
            
            if tagName.isEmpty {
                tagName = "TagGroup\(unnamedCounter)"
                unnamedCounter += 1
            }
            
            //            print(tagName)
            switch tagHeader.tagID {
            case 21: // DATA
                if groupName == "ImageData" && tagName == "Data" {
                    try checkDataTagDelimiter()
                    let infoarraySize = try readLOrQ()
                    
                    let enclos = try readLOrQ()
                    let dtype = try readLOrQ()
                    let size = try readLOrQ() // or compute from other metadata if needed
                    let dataOffset = reader.offset
                    let reference = LazyDataReference(offset: dataOffset, size: size, type: dtype)
                    groupDict[tagName] = reference
                    
                    // Skip reading actual data
                    let elementSize = elementByteSize(for: dtype)
                    reader.offset += size * elementSize
                } else {
                    try checkDataTagDelimiter()
                    let infoarraySize = try readLOrQ()
                    let data = try parseDataTag(infoarraySize: infoarraySize)
                    groupDict[tagName] = data
                }
                
            case 20: // GROUP
                var subGroup: [String: Any] = [:]
                let (_, _, ntags) = try parseTagGroup(sizeField: true)
                try parseTags(ntags: ntags, groupName: tagName, groupDict: &subGroup)
                groupDict[tagName] = subGroup
                
            default:
                throw DMReaderError.unknownTagID(Int(tagHeader.tagID))
            }
        }
    }
    
    func elementByteSize(for type: Int) -> Int {
        switch type {
        case 2, 4: return 2  // int16, uint16
        case 3, 6, 5: return 4  // int32, float32, packed
        case 7, 12: return 8  // float64, double
        case 11: return 8  // int64
        default: return 1
        }
    }
    
    func loadData(from reference: LazyDataReference) -> [Any] {
        let byteCount = reference.size * elementByteSize(for: reference.type)
        let range = reference.offset..<(reference.offset + byteCount)
        let raw = reader.data.subdata(in: range)
        
        switch reference.type {
        case 2:
            return raw.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        case 4:
            return raw.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        case 6:
            return raw.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        case 12:
            return raw.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        default:
            return []
        }
    }
    
    func parseDataTag(infoarraySize: Int) throws -> Any {
        let enctype = try readLOrQ()
        
        switch enctype {
        case 4:
            // uint16 potentially representing a UTF-16 string
            return try readSimpleData(etype: enctype)
        case 2...14:
            return try readSimpleData(etype: enctype)
            
        case 15:
            let definition = try parseStructDefinition()
            return try readStruct(definition: definition)
            
        case 18:
            let length = try parseStringDefinition()
            return try reader.readString(length: length)
            
        case 20:
            let encEltype = try readLOrQ()
            
            switch encEltype {
            case 4:
                // uint16 potentially representing a UTF-16 string
                let count = try readLOrQ()
                let byteCount = count * MemoryLayout<UInt16>.size
                let range = reader.offset..<(reader.offset + byteCount)
                let raw = reader.data.subdata(in: range)
                reader.offset += byteCount
                let scalars = raw.withUnsafeBytes {
                    Array($0.bindMemory(to: UInt16.self))
                }
                let data = scalars.withUnsafeBufferPointer {
                    Data(buffer: $0)
                }
                if let str = String(data: data, encoding: .utf16LittleEndian) {
                    return str
                } else {
                    return scalars // fallback to raw array
                }
            case 3:
                let count = try readLOrQ()
                let byteCount = count * MemoryLayout<Int32>.size
                let range = reader.offset..<(reader.offset + byteCount)
                let raw = reader.data.subdata(in: range)
                reader.offset += byteCount
                let scalars = raw.withUnsafeBytes {
                    Array($0.bindMemory(to: Int32.self))
                }
                let data = scalars.withUnsafeBufferPointer {
                    Data(buffer: $0)
                }
                return scalars
            case 10:
                // uint16 potentially representing a UTF-16 string
                let count = try readLOrQ()
                let byteCount = count * MemoryLayout<Int8>.size
                let range = reader.offset..<(reader.offset + byteCount)
                let raw = reader.data.subdata(in: range)
                reader.offset += byteCount
                let scalars = raw.withUnsafeBytes {
                    Array($0.bindMemory(to: Int8.self))
                }
                let data = scalars.withUnsafeBufferPointer {
                    Data(buffer: $0)
                }
                
                //                print(scalars)
                
                return scalars // fallback to raw array
                
            case 2...14:
                //                let (size, _) = try parseArrayDefinition()
                let count = try readLOrQ()
                return try readSimpleArray(size: count, etype: encEltype)
                
            case 15:
                
                let definition = try parseStructDefinition()
                let size = try readLOrQ()
                return try readArrayOfStructs(size: size, definition: definition)
                
            case 18:
                let strLen = try parseStringDefinition()
                let size = try readLOrQ()
                return try readArrayOfStrings(size: size, length: strLen)
                
            case 20:
                let (innerSize, innerType) = try parseArrayDefinition()
                let outerSize = try readLOrQ()
                return try readArrayOfArrays(outerSize: outerSize, innerSize: innerSize, etype: innerType)
                
            default:
                throw DMReaderError.unsupportedDataType(encEltype)
            }
            
        default:
            throw DMReaderError.unsupportedDataType(enctype)
        }
    }
    
    func parseStructDefinition() throws -> [Int] {
        _ = try readLOrQ() // total size, ignored here
        let nFields = try readLOrQ()
        var def: [Int] = []
        for _ in 0..<nFields {
            _ = try readLOrQ() // field size, ignored here
            
            def.append(try readLOrQ())
        }
        return def
    }
    
    func parseStringDefinition() throws -> Int {
        return try readLOrQ()
    }
    
    func parseArrayDefinition() throws -> (Int, Int) {
        let encEltype = try readLOrQ()
        let length = try readLOrQ()
        print("Array of \(length) elements of type \(encEltype)")
        return (length, encEltype)
    }
    
    func readArrayOfStructs(size: Int, definition: [Int]) throws -> [[Any]] {
        var result: [[Any]] = []
        for _ in 0..<size {
            result.append(try readStruct(definition: definition))
        }
        return result
    }
    
    func readArrayOfArrays(outerSize: Int, innerSize: Int, etype: Int) throws -> [[Any]] {
        var result: [[Any]] = []
        for _ in 0..<outerSize {
            var inner: [Any] = []
            for _ in 0..<innerSize {
                inner.append(try readSimpleData(etype: etype))
            }
            result.append(inner)
        }
        return result
    }
    
    func readStruct(definition: [Int]) throws -> [Any] {
        var values: [Any] = []
        
        for dtype in definition {
            switch dtype {
            case 2...14:
                values.append(try readSimpleData(etype: dtype))
            default:
                throw DMReaderError.unsupportedDataType(dtype)
            }
        }
        return values
    }
    
    func readSimpleArray(size: Int, etype: Int) throws -> [Any] {
        var array: [Any] = []
        print("Array size: \(size)")
        for _ in 0..<size {
            array.append(try readSimpleData(etype: etype))
        }
        return array
    }
    
    func readArrayOfStrings(size: Int, length: Int) throws -> [String] {
        var result: [String] = []
        for _ in 0..<size {
            result.append(try reader.readString(length: length))
        }
        return result
    }
    
    private func readSimpleData(etype: Int) throws -> Any {
        switch etype {
        case 2:
            return try reader.readInt16(endian: endian.swift)
        case 3:
            return try reader.readInt32(endian: endian.swift)
            
        case 4:
            return try reader.readUInt16(endian: endian.swift)
        case 5:
            // Packed complex float32 placeholder (actual handling requires FFT unpacking)
            return try reader.readUInt32(endian: endian.swift)
        case 6:
            return try reader.readFloat32(endian: endian.swift)
        case 7:
            return try reader.readDouble(endian: endian.swift)
        case 8:
            let val = try reader.readUInt8()
            return val != 0
        case 10:
            return try reader.readUInt16(endian: endian.swift)
        case 11:
            return try reader.readInt64(endian: endian.swift)
        case 12:
            return try reader.readDouble(endian: endian.swift)
        default:
            throw DMReaderError.unsupportedDataType(etype)
        }
    }
    
    private func parseTagHeader() throws -> (tagID: UInt8, tagName: String) {
        let tagID = try reader.readUInt8()
        let tagNameLength = try reader.readInt16(endian: .big)
        let tagName = try reader.readString(length: Int(tagNameLength))
        return (tagID, tagName)
    }
    
    private func parseTagGroup(sizeField: Bool = false) throws -> (Bool, Bool, Int) {
        let isSorted = try reader.readUInt8() != 0
        let isOpen = try reader.readUInt8() != 0
        if dmVersion == 4 && sizeField {
            _ = try readLOrQ()
        }
        let nTags = try readLOrQ()
        return (isSorted, isOpen, nTags)
    }
    
    private func checkDataTagDelimiter() throws {
        if dmVersion == 4 {
            reader.offset += 8
        }
        let delimiter = try reader.readString(length: 4)
        if delimiter != "%%%%" {
            throw DMReaderError.invalidTagDelimiter(delimiter)
        }
    }
    
    private func readLOrQ() throws -> Int {
        if dmVersion == 4 {
            return Int(try reader.readInt64(endian: .big))
        } else {
            return Int(try reader.readInt32(endian: .big))
        }
    }
    
    func imageList() -> [String:Any?]{
        let imageList = (tagsDict["root"] as! [String:Any?])["ImageList"] as? [String:Any?] ?? [:]
        return imageList
    }
}

enum Endianness {
    case little
    case big

    var swift: BinaryReader.Endian {
        return self == .little ? .little : .big
    }
}

struct ImageObject {
    var metadata: [String: Any]
    var dataSize: Int
    var fileHandle: FileHandle
    var dataOffset: UInt64
    
    var shape: [Int] {
        guard let dims = metadata["ImageDataDimensions"] as? [Int] else {
            return []
        }
        return dims.reversed()
    }
    
    var units: [String] {
        guard let dims = metadata["ImageDataCalibrationsDimension"] as? [[String: Any]] else {
            return []
        }
        return dims.reversed().map { $0["Units"] as? String ?? "" }
    }
    
    var scales: [Double] {
        guard let dims = metadata["ImageDataCalibrationsDimension"] as? [[String: Any]] else {
            return []
        }
        return dims.reversed().map { $0["Scale"] as? Double ?? 1.0 }
    }
    
    var offsets: [Double] {
        guard let dims = metadata["ImageDataCalibrationsDimension"] as? [[String: Any]] else {
            return []
        }
        let origin = dims.reversed().map { $0["Origin"] as? Double ?? 0.0 }
        let scales = self.scales
        return zip(origin, scales).map { -1 * $0 * $1 }
    }
    
    var signalType: String {
        guard let signal = metadata["ImageTagsMetaDataSignal"] as? String else {
            return ""
        }
        switch signal {
        case "EELS": return "EELS"
        case "X-ray": return "EDS_TEM"
        case "CL": return "CL"
        default: return ""
        }
    }
    
    var dtype: String {
        guard let dtypeCode = metadata["ImageDataDataType"] as? Int else {
            return "unknown"
        }
        switch dtypeCode {
        case 1: return "int16"
        case 2: return "float32"
        case 3: return "complex64"
        case 6: return "uint8"
        case 7: return "int32"
        case 10: return "uint16"
        case 11: return "uint32"
        case 12: return "float64"
        case 13: return "complex128"
        case 14: return "bool"
        default: return "unsupported"
        }
    }
    
    func getData() throws -> [Float32] {
        // Placeholder: Replace with actual parsing from file offset
        try fileHandle.seek(toOffset: dataOffset)
        let raw = fileHandle.readData(ofLength: dataSize * MemoryLayout<Float32>.size)
        var result: [Float32] = Array(repeating: 0.0, count: dataSize)
        _ = result.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
        return result
    }
    
    func unpackNewPackedComplex(data: [Float32]) -> [SIMD2<Float>] {
        // Placeholder logic: assumes row-major data
        let rows = shape.first ?? 0
        let cols = shape.count > 1 ? shape[1] : 1
        let halfCols = cols / 2 + 1
        var packed = [SIMD2<Float>]()
        for i in 0..<(data.count / 2) {
            let re = data[i * 2 + 0]
            let im = data[i * 2 + 1]
            packed.append(SIMD2<Float>(re, im))
        }
        // Could add full reconstruction logic here
        return packed
    }
    
    
}

struct DMFileReader {
    static func read(url: URL) throws -> [(image: ImageObject, metadata: [String: Any])] {
        // Open file and parse metadata
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var reader = try DigitalMicrographReader(fileURL: url)
        try reader.parseFile()

        var results: [(ImageObject, [String: Any])] = []

        if let root = reader.tagsDict["root"] as? [String: Any],
           let imageList = root["ImageList"] as? [String: Any] {
            for (_, tagGroup) in imageList {
                if let group = tagGroup as? [String: Any],
                   let imageData = group["ImageData"] as? [String: Any],
                   let dataSize = (imageData["Data"] as? [String: Any])?["size"] as? Int,
                   let dataOffset = (imageData["Data"] as? [String: Any])?["offset"] as? Int {

                    var flatMetadata = [String: Any]()
                    func flatten(prefix: String, dict: [String: Any]) {
                        for (key, val) in dict {
                            if let sub = val as? [String: Any] {
                                flatten(prefix: "\(prefix)\(key)", dict: sub)
                            } else {
                                flatMetadata["\(prefix)\(key)"] = val
                            }
                        }
                    }
                    flatten(prefix: "", dict: group)

                    let image = ImageObject(
                        metadata: flatMetadata,
                        dataSize: dataSize,
                        fileHandle: handle,
                        dataOffset: UInt64(dataOffset)
                    )
                    results.append((image, flatMetadata))
                }
            }
        }

        return results
    }
}
