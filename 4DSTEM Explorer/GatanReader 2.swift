//
//  GatanReader.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 7/16/25.
//  Copyright © 2025 The LeBeau Group. All rights reserved.
//

import Foundation

enum DM4Error: Error {
    case invalidHeader
    case invalidRootDirectory
    case readError
    case unknownTagByte
    case unknownTagType(UInt64)
    case invalidGroupTag
    case invalidGroupType
    case invalidTagInfo
    case unimplemented(String)
    case invalidArrayTag
    case invalidGroupArray
    case typeMismatch
}

enum DM4TagNode {
    case tag(DM4Tag)
    case directory(DM4TagDirectory)
}

struct DM4Tag {
    let name: String?
    let tlength: UInt64  // total bytes in tag including %%%% (new for DM4)
    let info: [UInt64]//   info(ninfo) ninfo*i8be   array of ninfo integers, contains tag data type(s) for tag values info(1) = tag data type (see tag data types below)
    let dataOffset: UInt64

}

struct DM4TagDirectory {
    let name: String?
    let sortf: Bool
    let closef: Bool
    var children: [DM4TagNode]
    let count: Int
}

enum DM4TagDataType: UInt8 {
    
    case skip          = 0x00 // skip
    case int16         = 0x02  // signed short
    case int32         = 0x03  // signed long
    case uint16OrStr   = 0x04  // unsigned short or unicode string
    case uint32        = 0x05  // unsigned long
    case float32       = 0x06  // float
    case float64       = 0x07  // double
    case float8       = 12  // double
    case boolean       = 0x08  // boolean (i1)
    case char          = 0x09  // character (a1)
    case int8          = 0x0A  // i1
    case int64        = 0x0B  // i8* (possibly signed)
    case group         = 0x0F  // struct or grouped data
    case string        = 0x12  // a (string)
    case array         = 0x14  // array or group of data

    var description: String {
        switch self {
        case .skip: return "Skip"
        case .int16: return "Int16"
        case .int32: return "Int32"
        case .uint16OrStr: return "UInt16 or Unicode String"
        case .uint32: return "UInt32"
        case .float32: return "Float32"
        case .float64: return "Float64"
        case .boolean: return "Bool"
        case .char: return "Char"
        case .float8: return "Float8"
        case .int8: return "Int8"
        case .int64: return "UInt64"
        case .group: return "Group/Struct"
        case .string: return "String"
        case .array: return "Array/Group"
        }
    }
}

enum ValueType:UInt8 {
    case int16 = 2
    case float32 = 6
    case uint8 = 9
    case int32 = 3

    var byteSize: Int {
        switch self {
        case .int16: return MemoryLayout<Int16>.size
        case .int32: return MemoryLayout<Int32>.size
        case .float32: return MemoryLayout<Float>.size
        case .uint8: return MemoryLayout<UInt8>.size
        }
    }

    func convert<T>(buffer: UnsafeRawBufferPointer, count: Int, bigEndian: Bool, as type: T.Type) -> [T]? {
        switch self {
        case .int16 where type == Int16.self:
            return buffer.bindMemory(to: Int16.self).prefix(count).map {
                bigEndian ? Int16(bigEndian: $0) : Int16(littleEndian: $0)
            } as? [T]
        case .int32 where type == Int32.self:
            return buffer.bindMemory(to: Int32.self).prefix(count).map {
                bigEndian ? Int32(bigEndian: $0) : Int32(littleEndian: $0)
            } as? [T]
        case .float32 where type == Float.self:
            return buffer.bindMemory(to: UInt32.self).prefix(count).map {
                let bits = bigEndian ? UInt32(bigEndian: $0) : UInt32(littleEndian: $0)
                return Float(bitPattern: bits)
            } as? [T]
        case .uint8 where type == UInt8.self:
            return buffer.bindMemory(to: UInt8.self).prefix(count).map { $0 } as? [T]
        default:
            return nil
        }
    }
}



class DM4File {
    private let fh: FileHandle
    private let isLittleEndian: Bool
    private(set) var root: DM4TagNode
    
    init(url: URL) throws {
        fh = try FileHandle(forReadingFrom: url)
        
        // ───── Header ─────
        try fh.seek(toOffset: 0)
        let version = try DM4File.readUInt32(from: fh)
        _ = try DM4File.readUInt64(from: fh)
        let bo = try DM4File.readUInt32(from: fh)
        isLittleEndian = (bo == 1)
        print("DM4 version \(version); littleEndian = \(isLittleEndian)")
        
        // ───── Root Metadata ─────
        try fh.seek(toOffset: 16)
        guard let flags = try fh.read(upToCount: 2), flags.count == 2 else {
            throw DM4Error.invalidRootDirectory
        }
        let sorted = flags[0] != 0
        let closed = flags[1] != 0
        let ntags:Int = try Int(DM4File.readUInt64(from: fh))
        
        // ───── Build Tree ─────
        self.root = try DM4File.buildRoot(from: fh, sorted: sorted, closed: closed,count:ntags)
    }
    
    // MARK: - Private Tree Builder
    private class func buildRoot(from fh: FileHandle, sorted: Bool, closed: Bool, count: Int) throws -> DM4TagNode {
        var children: [DM4TagNode] = []
        
       
        while let child = try buildTagStructure(from: fh) {
            children.append(child)
        }
        
        let rootDir = DM4TagDirectory(
            name: "Root",
            sortf: sorted,
            closef: closed,
            children: children,
            count: count
        )
        
        return .directory(rootDir)
    }
    
    // MARK: - Recursive Parser
    private class func buildTagStructure(from fh: FileHandle) throws -> DM4TagNode? {
        let tagByte = try readUInt8(from: fh, bigEndian: false)
        
        switch tagByte {
        case 0:
            return nil
        case 20:
            var dir = try readTagDirectory(from: fh)
            
            dir.children = []
            let count =  dir.count
            
            
            for _ in 0..<count{
                if let child = try buildTagStructure(from: fh){
//                    let newChild = try readTag(from: fh)
                    dir.children.append(child)
                }
            }


            
            return .directory(dir)
            
        case 21:
            let tag = try readTag(from: fh)
            print(tag.name)
            
            return .tag(tag)
            
        default:
            throw DM4Error.unknownTagByte
        }
    }
    
    // MARK: - Static Parsers
    private class func readTagDirectory(from fh: FileHandle) throws -> DM4TagDirectory {
        var name: String?
           let info:  [UInt64] = [UInt64]()
           let dataOffset: UInt64 = 0
           let totalLength: UInt64 = 0
   
           // Read name length (2 bytes BE)
        
            let nameLen = try readUInt16(from: fh)

           // Read name
           if nameLen > 0 {
               let rawName = try fh.read(upToCount: Int(nameLen)) ?? Data()
               name = String(decoding: rawName, as: UTF8.self)
           } else {
               name = nil
           }
        

           // Read total tag length (tlen)
           let tlen = try Self.readUInt64(from: fh)
   
           //        if name == "DocumentObjectList"{
           guard let flags = try fh.read(upToCount: 2), flags.count == 2 else {
               throw DM4Error.invalidRootDirectory
           }
           let sorted = flags[0] != 0
           let closed = flags[1] != 0
   
           let count = try Self.readUInt64(from: fh)
        
        if name == nil && count > 0{
            name = "TagGroup"
        }
   
  
//           try fh.read(upToCount: Int(tlen-2-8))
   
        return DM4TagDirectory(name: name, sortf: sorted, closef: closed, children: [], count:Int(count))
    }
    
    private class func readTag(from fh: FileHandle) throws -> DM4Tag {
        // ───── Tag Name ─────
        
        let dataOffset = try fh.offset()
//        let nameLenData = try fh.read(upToCount: 2) ?? Data()
//        var nameLen: UInt16 = 0
 
        var nameLen:UInt16 = try readUInt16(from: fh)
//        withUnsafeMutableBytes(of: &nameLen) { dest in
//            nameLenData.withUnsafeBytes { src in
//                dest.copyMemory(from: src)
//            }
//        }
//        nameLen = nameLen.bigEndian

        let name: String?
        if nameLen > 0 {
            let rawName = try fh.read(upToCount: Int(nameLen)) ?? Data()
            name = String(decoding: rawName, as: UTF8.self)
        } else {
            name = nil
        }

        // ───── Total Tag Length ─────
        let tlength = try readUInt64(from: fh)

        // Skip "%%%%" marker (4 bytes)
        _ = try fh.read(upToCount: 4)
        

        // ───── Info Block ─────
        let ninfo = try Int(readUInt64(from: fh))
        let info = try readUInt64Array(from: fh, count: ninfo, bigEndian: true)
        
        
//
//
//        for infoValue in info {
//
//            let typeCode = infoValue
//            let type = DM4TagDataType(rawValue: UInt8(typeCode))
//
////            print("Read tag: \(name ?? "<unnamed>"), type: \(typd?.description)")
//
//        }

        print(info, ninfo)
        let values = try readTagValues(info: info, from: fh)


        
        return DM4Tag(name: name, tlength: tlength, info: info, dataOffset: dataOffset)
    }
    
    private class func readTagValues(info: [UInt64], from fh: FileHandle) throws -> [Any] {
        var values: [Any] = []
        var i = 0

        while i < info.count {
            guard let type = DM4TagDataType(rawValue: UInt8(info[i])) else {
                throw DM4Error.unknownTagType(info[i])
            }

            switch type {
            case .skip:
                i += 1

            case .uint16OrStr:
                // If there's a count after, treat as UTF-16 string
                if i + 1 < info.count {
                    let charCount = Int(info[i + 1])
                    let byteCount = charCount * 2
                    let raw = try fh.read(upToCount: byteCount) ?? Data()
                    if let str = String(data: raw, encoding: .utf16LittleEndian) {
                        values.append(str)
                    } else {
                        throw DM4Error.unimplemented("UTF-16 string decoding failed")
                    }
                    i += 2
                } else {
                    // Only a single type — treat as single UInt16 value
                    let val = try readUInt16(from: fh)
                    values.append(val)
                    i += 1
                }


            case .group:
                guard i + 2 < info.count else { throw DM4Error.invalidGroupTag }

                let ngroup = Int(info[i + 2])
                let start = i + 3
                let end = start + ngroup * 2

                guard end <= info.count else { throw DM4Error.invalidGroupTag }

                for g in 0..<ngroup {
                    let typeIdx = start + g * 2 + 1
                    guard typeIdx < info.count,
                          let gtype = DM4TagDataType(rawValue: UInt8(info[typeIdx])) else {
                        throw DM4Error.invalidGroupType
                    }
                    let val = try readValue(of: gtype, from: fh)
                    values.append(val)
                }

                i = end
                
            
                
            case .array:
                guard i + 1 < info.count else {
                    throw DM4Error.invalidArrayTag
                }

                let elementKind = UInt8(info[i + 1])

                if elementKind == 0x0F {
                    // ───── Array of Groups ─────
                    guard i + 4 < info.count else {
                        throw DM4Error.invalidGroupArray
                    }

                    let ngroup = Int(info[i + 3])
                    let start = i + 4
                    let groupEnd = start + ngroup * 2

                    guard groupEnd + 1 <= info.count else {
                        throw DM4Error.invalidGroupArray
                    }

                    let narray = Int(info[groupEnd])
                    for _ in 0..<narray {
                        for j in 0..<ngroup {
                            let typeIdx = start + j * 2 + 1
                            guard let gtype = DM4TagDataType(rawValue: UInt8(info[typeIdx])) else {
                                throw DM4Error.invalidGroupType
                            }
                            let val = try readValue(of: gtype, from: fh)
                            values.append(val)
                        }
                    }

                    i = groupEnd + 1

                } else {
                    // ───── Flat Array: [0x14, typeCode, count] ─────
                    guard i + 2 < info.count else {
                        throw DM4Error.invalidArrayTag
                    }

                    let raw = UInt8(info[i + 1])
                    let count = Int(info[i + 2])

                    if count == 0 {
                        return [0]
                        
                    }
                    guard let elementType = DM4TagDataType(rawValue: raw) else {
                        throw DM4Error.unknownTagType(UInt64(raw))
                    }
                    
                    let type = ValueType(rawValue:let sys = Python.import("sys")
                                         
                                         print("Python \(sys.version_info.major).\(sys.version_info.minor)")
                                         print("Python Version: \(sys.version)")
                                         print("Python Encoding: \(sys.getdefaultencoding().upper())")elementType.rawValue)
                    
                    
                    let values:[Int16] = try readArray(from: fh, type: .int16, count: count)

//                    print(values)
//                    for _ in 0..<count {
//                        let val = try readValue(of: elementType, from: fh)
//                        values.append(val)
//                    }

                    i += 3
                }


            default:
                let val = try readValue(of: type, from: fh)
                values.append(val)
                i += 1
            }
        }

        return values
    }


    
    private class func readValue(of type: DM4TagDataType, from fh: FileHandle) throws -> Any {
        switch type {
        case .skip:
            return ()
        case .int8:
            let byte = try readUInt8(from: fh)
            return Int8(bitPattern: byte)

        case .boolean:
            
            return (try readUInt8(from: fh)) != 0

        case .char:
            let data = try fh.read(upToCount: 1) ?? Data()
            return String(data: data, encoding: .ascii) ?? "?"
            
        case .int16:
            return try readInt16(from: fh, bigEndian: false)

        case .uint16OrStr:
//            String(Unicode)
//
//            return try readUnicode(from: fh)
            return try readUInt16(from: fh)

        case .int32:
            return try readInt32(from: fh)

        case .uint32:
            return try readUInt32(from: fh)

        case .int64:
            return try readInt64(from: fh)

        case .float32:
            return try readFloat32(from: fh)

        case .float64:
            return try readFloat64(from: fh)
        case .float8:
            return try readFloat64(from: fh)

        case .string, .group, .array:
            throw DM4Error.unimplemented("Cannot decode complex type \(type)")
        }
    }
    
    private class func parseTagTypes(from info: [UInt64]) throws -> [DM4TagDataType] {
        var types: [DM4TagDataType] = []
        var i = 0

        while i < info.count {
            let code = UInt8(info[i])

            
            if code == 0x0F {
                // ───── Group ─────
                guard i + 2 < info.count else {
                    throw DM4Error.invalidGroupTag
                }

                let ngroup = Int(info[i + 2])
                let start = i + 3
                let end = start + (ngroup * 2)

                guard end <= info.count else {
                    throw DM4Error.invalidGroupTag
                }

                for j in 0..<ngroup {
                    let typeIndex = start + j * 2 + 1
                    let raw = UInt8(info[typeIndex])
                    guard let type = DM4TagDataType(rawValue: raw) else {
                        throw DM4Error.unknownTagType(UInt64(raw))
                    }
                    types.append(type)
                }

                i = end

            } else if code == 0x14 {
                // ───── Array ─────

                guard i + 1 < info.count else {
                    throw DM4Error.invalidArrayTag
                }

                let elementKind = UInt8(info[i + 1])

                if elementKind == 0x0F {
                    // ───── Array of Groups ─────
                    guard i + 4 < info.count else {
                        throw DM4Error.invalidGroupArray
                    }

                    let ngroup = Int(info[i + 3])
                    let start = i + 4
                    let groupEnd = start + ngroup * 2

                    guard groupEnd + 1 <= info.count else {
                        throw DM4Error.invalidGroupArray
                    }

                    // Parse group field types
                    var groupTypes: [DM4TagDataType] = []
                    for j in 0..<ngroup {
                        let typeIndex = start + j * 2 + 1
                        let raw = UInt8(info[typeIndex])
                        guard let type = DM4TagDataType(rawValue: raw) else {
                            throw DM4Error.unknownTagType(UInt64(raw))
                        }
                        groupTypes.append(type)
                    }

                    let narray = Int(info[groupEnd])
                    for _ in 0..<narray {
                        types.append(contentsOf: groupTypes)
                    }

                    i = groupEnd + 1

                } else {
                    // ───── Simple Array: [20, type, count] ─────
                    guard i + 2 < info.count else {
                        throw DM4Error.invalidArrayTag
                    }

                    let raw = UInt8(info[i + 1])
                    let count = Int(info[i + 2])

                    guard let type = DM4TagDataType(rawValue: raw) else {
                        throw DM4Error.unknownTagType(UInt64(raw))
                    }

                    types.append(contentsOf: Array(repeating: type, count: count))
                    i += 3
                }

            } else {
                // ───── Flat Type ─────
                guard let type = DM4TagDataType(rawValue: code) else {
                    throw DM4Error.unknownTagType(UInt64(code))
                }

                types.append(type)
                i += 1
            }
        }

        return types
    }




    
    private static func readUInt8(from fh: FileHandle, bigEndian: Bool = true) throws -> UInt8 {
        let raw = try fh.read(upToCount: 1) ?? Data()
        var v: UInt8 = 0
        withUnsafeMutableBytes(of: &v) { dest in raw.withUnsafeBytes { dest.copyMemory(from: $0) } }
        return bigEndian ? v.bigEndian : v.littleEndian
    }

    private class func readInt16(from fh: FileHandle, bigEndian: Bool = false) throws -> Int16 {
        let data = try fh.read(upToCount: 2) ?? Data()
        guard data.count == 2 else { throw DM4Error.readError }
        
        let value:Int16
        
        if bigEndian{
            value = Int16(bigEndian: data.withUnsafeBytes { $0.load(as: Int16.self) })
        }else{
            value = Int16(data.withUnsafeBytes { $0.load(as: Int16.self) })
        }
        return value

    }

    private class func readUInt16(from fh: FileHandle) throws -> UInt16 {
        let data = try fh.read(upToCount: 2) ?? Data()
        guard data.count == 2 else { throw DM4Error.readError }
        return UInt16(bigEndian: data.withUnsafeBytes { $0.load(as: UInt16.self) })
    }

    private class func readInt32(from fh: FileHandle, bigEndian: Bool = false) throws -> Int32 {
        let data = try fh.read(upToCount: 4) ?? Data()
        guard data.count == 4 else { throw DM4Error.readError }
        
        let value:Int32
        
        if bigEndian{
            value = Int32(bigEndian: data.withUnsafeBytes { $0.load(as: Int32.self) })
        }else{
            value = Int32(data.withUnsafeBytes { $0.load(as: Int32.self) })
        }
        return value

    }

    private class func readInt64(from fh: FileHandle) throws -> Int64 {
        let data = try fh.read(upToCount: 8) ?? Data()
        guard data.count == 8 else {
            throw DM4Error.readError
        }

        // Load little-endian Int64 value
        return Int64(littleEndian: data.withUnsafeBytes { $0.load(as: Int64.self) })
    }
    
    private static func readUInt32(from fh: FileHandle, bigEndian: Bool = true) throws -> UInt32 {
        let raw = try fh.read(upToCount: 4) ?? Data()
        var v: UInt32 = 0
        withUnsafeMutableBytes(of: &v) { dest in raw.withUnsafeBytes { dest.copyMemory(from: $0) } }
        return bigEndian ? v.bigEndian : v.littleEndian
    }
    
    private static func readFloat32(from fh: FileHandle) throws -> Float32 {
        let raw = try fh.read(upToCount: 4) ?? Data()
        var v: Float32 = 0
        withUnsafeMutableBytes(of: &v) { dest in raw.withUnsafeBytes { dest.copyMemory(from: $0) } }
        return v
    }
    

    private class func readFloat64(from fh: FileHandle) throws -> Double {
        
        let raw = try fh.read(upToCount: 8) ?? Data()
        var v: Double = 0
        withUnsafeMutableBytes(of: &v) { dest in raw.withUnsafeBytes { dest.copyMemory(from: $0) } }
        return v
    }
    
    

    
    private class func readUInt64(from fh: FileHandle) throws -> UInt64 {
        let data = try fh.read(upToCount: 8) ?? Data()
        guard data.count == 8 else { throw DM4Error.readError }

        let raw = data.withUnsafeBytes { $0.load(as: UInt64.self) }
        return UInt64(bigEndian: raw)
    }
    
    
    private static func readArray<T>(from fh: FileHandle, type: ValueType, count: Int, bigEndian: Bool = false) throws -> [T] {
        let byteCount = count * type.byteSize
        guard let raw = try fh.read(upToCount: byteCount), raw.count == byteCount else {
            throw DM4Error.readError
        }

        let result = raw.withUnsafeBytes { buffer in
            type.convert(buffer: buffer, count: count, bigEndian: bigEndian, as: T.self)
        }

        guard let typed = result else {
            throw DM4Error.typeMismatch
        }

        return typed
    }

    
    private static func readUInt64Array(from fh: FileHandle, count: Int, bigEndian: Bool = true) throws -> [UInt64] {
        let byteCount = count * MemoryLayout<UInt64>.size
        guard let raw = try fh.read(upToCount: byteCount), raw.count == byteCount else {
            throw DM4Error.readError
        }

        var result: [UInt64] = Array(repeating: 0, count: count)
        raw.withUnsafeBytes { rawPtr in
            let base = rawPtr.baseAddress!
            for i in 0..<count {
                let ptr = base.advanced(by: i * 8).assumingMemoryBound(to: UInt64.self)
                result[i] = bigEndian ? ptr.pointee.bigEndian : ptr.pointee.littleEndian
            }
        }

        return result
    }
    

    

    func printTagTree(_ node: DM4TagNode, indent: String = "") {
        switch node {
        case .tag(let tag):
            let tagName = tag.name ?? "<unnamed>"
            print("\(indent)- Tag: \(tagName), offset: \(tag.dataOffset), length: \(tag.tlength), types: \(tag.info)")

        case .directory(let dir):
            let dirName = dir.name ?? "<unnamed>"
            print("\(indent)+ Directory: \(dirName) [sorted: \(dir.sortf), closed: \(dir.closef)]")

            for child in dir.children {
                printTagTree(child, indent: indent + "  ")
            }
        }
    }
}


public extension String {

    var expandingTildeInPath: String {
            return NSString(string: self).expandingTildeInPath
        }

}

