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
        let types = try parseTagTypes(from: info)
        
        var values: [Any] = []
        for type in types {
            
            
            if type == .skip {
                continue
            }
            
            let value = try readValue(of: type, from: fh)
            values.append(value)
        }
        
        print(values)

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
            String(Unicode)
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


//
//func printDir(_ dir: DM4TagDir, indent: String = "") {
//    print(indent + "📁 " + (dir.name ?? "(root)"))
//    for tag in dir.namedTags.values {
//        print(indent + "   📄 " + (tag.name ?? "(no-name)") + " info: \(tag.info)")
//    }
//    for sub in dir.namedSubdirs.values {
//        printDir(sub, indent: indent + "    ")
//    }
//}



//let tags = try dm.readDirectory()
//
//
//if let tag = tags.first(where: { $0.name == "Data" }) {
//    let pixels: [UInt16] = try dm.readTagData(tag, as: UInt16.self)
//    // Then convert to Float32 pointer
//}

//class DM4File {
//    private let fh: FileHandle
//    private let isLittleEndian: Bool
//    private let ntags: UInt64
//    private(set) var root: DM4TagNode
//
//
//    init(url: URL) throws {
//        fh = try FileHandle(forReadingFrom: url)
//
//        // Read header
//        try fh.seek(toOffset: 0)
//        let version = try Self.readUInt32(from: fh)
//        _ = try Self.readUInt64(from: fh)
//        let bo = try Self.readUInt32(from: fh)
//        isLittleEndian = (bo == 1)
//        print("DM4 version \(version); littleEndian = \(isLittleEndian)")
//
//        // Position at start of Root Tag Directory
//        try fh.seek(toOffset: 16)
//        guard let flags = try fh.read(upToCount: 2), flags.count == 2 else {
//            throw DM4Error.invalidRootDirectory
//        }
//        let sorted = flags[0] != 0
//        let closed = flags[1] != 0
//        ntags = try Self.readUInt64(from: fh)
//        print("Root dir: sorted=\(sorted), closed=\(closed), ntags=\(ntags)")
//
//
//
//
//        var rootChildren = [DM4TagNode]()
//
//        while let child = try self.buildTagStructure() {
//            rootChildren.append(child)
//        }
//
//        let rootDirectory = DM4TagDirectory(name: "root", sortf: false, closef: false, children: rootChildren)
//        self.root = .directory(rootDirectory)
//
//        printTagTree(self.root)
//
//
//
//
//    }
//
//    deinit {
//        try? fh.close()
//    }
//
//    func printTagTree(_ node: DM4TagNode, indent: String = "") {
//        switch node {
//        case .tag(let tag):
//            let tagName = tag.name ?? "<unnamed>"
//            print("\(indent)- Tag: \(tagName), offset: \(tag.dataOffset), length: \(tag.tlength), types: \(tag.info)")
//
//        case .directory(let dir):
//            let dirName = dir.name ?? "<unnamed>"
//            print("\(indent)+ Directory: \(dirName) [sorted: \(dir.sortf), closed: \(dir.closef)]")
//
//            for child in dir.children {
//                printTagTree(child, indent: indent + "  ")
//            }
//        }
//    }
//
//    private static func readUInt8(from fh: FileHandle, bigEndian: Bool = true) throws -> UInt8 {
//        let raw = try fh.read(upToCount: 1) ?? Data()
//        var v: UInt8 = 0
//        withUnsafeMutableBytes(of: &v) { dest in raw.withUnsafeBytes { dest.copyMemory(from: $0) } }
//        return bigEndian ? v.bigEndian : v.littleEndian
//    }
//
//    private static func readUInt64(from fh: FileHandle, bigEndian: Bool = true) throws -> UInt64 {
//        let raw = try fh.read(upToCount: 8) ?? Data()
//        var v: UInt64 = 0
//        withUnsafeMutableBytes(of: &v) { dest in raw.withUnsafeBytes { dest.copyMemory(from: $0) } }
//        return bigEndian ? v.bigEndian : v.littleEndian
//    }
//
//    private static func readUInt32(from fh: FileHandle, bigEndian: Bool = true) throws -> UInt32 {
//        let raw = try fh.read(upToCount: 4) ?? Data()
//        var v: UInt32 = 0
//        withUnsafeMutableBytes(of: &v) { dest in raw.withUnsafeBytes { dest.copyMemory(from: $0) } }
//        return bigEndian ? v.bigEndian : v.littleEndian
//    }
//
//    private func readTagDirectory() throws -> DM4TagDirectory {
//
//        let name: String?
//        let info:  [UInt64] = [UInt64]()
//        let dataOffset: UInt64 = 0
//        let totalLength: UInt64 = 0
//
//        // Read name length (2 bytes BE)
//        let nameLenData = try fh.read(upToCount: 2) ?? Data()
//        var nameLen: UInt16 = 0
//        withUnsafeMutableBytes(of: &nameLen) { dest in
//            nameLenData.withUnsafeBytes { src in
//                dest.copyMemory(from: src)
//            }
//        }
//
//        nameLen = nameLen.bigEndian
//
//
//        //
//        // Read name
//        if nameLen > 0 {
//            let rawName = try fh.read(upToCount: Int(nameLen)) ?? Data()
//            name = String(decoding: rawName, as: UTF8.self)
//        } else {
//            name = nil
//        }
//
//        //        print(name ?? nil)
//
//        //
//        // Read total tag length (tlen)
//        let tlen = try Self.readUInt64(from: fh, bigEndian: true)
//
//        //        if name == "DocumentObjectList"{
//        guard let flags = try fh.read(upToCount: 2), flags.count == 2 else {
//            throw DM4Error.invalidRootDirectory
//        }
//        let sorted = flags[0] != 0
//        let closed = flags[1] != 0
//
//        let dtags = try Self.readUInt64(from: fh, bigEndian: true)
//
////        print(name, sorted, closed, dtags)
//
//        try fh.read(upToCount: Int(tlen-2-8))
//
//        return DM4TagDirectory(name: name, sortf: sorted, closef: closed, children: [])
//
//    }
//
//    private func readTag() throws -> DM4Tag {
//
//
//        let name: String?
//        let info:  [UInt64] = [UInt64]()
//        let dataOffset: UInt64 = 0
//        let totalLength: UInt64 = 0
//
//        // Read name length (2 bytes BE)
//        let nameLenData = try fh.read(upToCount: 2) ?? Data()
//        var nameLen: UInt16 = 0
//        withUnsafeMutableBytes(of: &nameLen) { dest in
//            nameLenData.withUnsafeBytes { src in
//                dest.copyMemory(from: src)
//            }
//        }
//
//        nameLen = nameLen.bigEndian
//        //        print(nameLen)
//
//        //
//        // Read name
//        if nameLen > 0 {
//            let rawName = try fh.read(upToCount: Int(nameLen)) ?? Data()
//            name = String(decoding: rawName, as: UTF8.self)
//        } else {
//            name = nil
//        }
//
//        //
//        // Read total tag length (tlen)
//        let tlen = try Self.readUInt64(from: fh, bigEndian: true)
//        //
//        //        // Skip the "%%%%" bytes
//        //        _ = try fh.read(upToCount: 4)
//
//        try fh.read(upToCount: Int(tlen))
//
//        return DM4Tag(name: name, tlength: tlen, info: info, dataOffset: dataOffset)
//
//    }
//
//
//
//
//
//    //    function build_tree(path):
//    //        node = create_node(name=basename(path), type="directory" or "file")
//    //
//    //        if is_directory(path):
//    //            node.children = []
//    //            for item in list_directory(path):
//    //                child_path = join(path, item)
//    //                child_node = build_tree(child_path)
//    //                node.children.append(child_node)
//    //        else:
//    //            node.children = null  // or [] if you want to unify types
//    //
//    //        return node
//
//
//    private func buildTagStructure() throws -> DM4TagNode? {
//        let tagByte = try Self.readUInt8(from: fh, bigEndian: false)
//
//        if tagByte == 0 {
//            return nil  // End tag marker
//        } else if tagByte == 20 {
//            // Directory
//            var directory = try readTagDirectory()
//            directory.children = []
//
//            while let child = try buildTagStructure() {
//                directory.children.append(child)
//            }
//
//            return .directory(directory)
//        } else if tagByte == 21 {
//            // Tag
//
//            let tag = try readTag()
//            return .tag(tag)
//        }
//
//        return nil
//    }
//}
//
////    func parseAllTags() throws -> [DM4Tag] {
////        var tags = [DM4Tag]()
////        while true {
////            guard let t = try readTag() else { break }
////            let bytesRead = 1 + 2 + UInt64(t.name?.utf8.count ?? 0) + 8 + 4 + 8 + UInt64(t.info.count) * 8
////            let skip = t.tlen >= bytesRead ? t.tlen - bytesRead : 0
////            let nextOffset = t.dataOffset + skip
////            try fh.seek(toOffset: nextOffset)
////
////            tags.append(DM4Tag(name: t.name, info: t.info, dataOffset: t.dataOffset, tlen: t.tlen))
////        }
////        return tags
////    }
