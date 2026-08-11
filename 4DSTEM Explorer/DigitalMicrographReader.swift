// DigitalMicrographReader.swift
// Swift port of RosettaSciIO's DM3/DM4 file reader
// Compatible with macOS

import Foundation

// MARK: - BinaryReader Extension



import Foundation
import Accelerate

//
//struct ImageData: Codable {
//    var dataReference: LazyDataReference?
//    var pixelDepth: Int?
//    var dataType: Int?
//    var dimensions: [Int]?
//    var calibrations: CalibrationSet?
//}
//
//struct CalibrationSet: Codable {
//    var brightness: CalibrationAxis?
//    var dimensions: [CalibrationAxis]?
//}
//
//struct CalibrationAxis: Codable {
//    var origin: Double?
//    var scale: Double?
//    var units: String?
//}


struct LazyDataReference:Codable{
    let offset: Int
    let size: Int
    let type: Int
}

enum DMReaderError: Error {
    case unsupportedVersion(Int)
    case invalidTagDelimiter(String)
    case unknownTagID(Int)
    case unsupportedDataType(Int)
}

/// How stored values become physical ones: `value = (raw - origin) * scale`.
///
/// Digital Micrograph writes counts into an integer type with a fixed pedestal
/// so that negative excursions survive, and records the pedestal and the gain in
/// `ImageData/Calibrations/Brightness`. The numbers are not decorative — a
/// typical 4D dataset stores an offset of order a million against a signal of a
/// few electrons, so data read without this applied is almost entirely pedestal.
/// Anything that takes a ratio or a moment of the pattern — centre of mass, DPC,
/// a normalised bright-field image — is then wrong, not merely mis-scaled.
///
/// The sense is DM's own, the same one its dimension calibrations use: subtract
/// the origin, then multiply by the scale.
struct IntensityCalibration: Equatable {
    var origin: Double
    var scale: Double
    /// What a calibrated value is in, e.g. `e-`.
    var units: String

    /// True when applying this would not change anything.
    var isIdentity: Bool {
        return origin == 0 && scale == 1
    }

    var summary: String {
        let unit = units.isEmpty ? "" : " \(units)"
        return String(format: "(raw − %g) × %g%@", origin, scale, unit as NSString)
    }
}


extension DigitalMicrographReader {

    /// The intensity calibration recorded for one image in the file.
    ///
    /// Returns nil when the file records none, or records one that would not
    /// change anything — there is no point carrying an identity through the read
    /// path, and nil is the honest answer for a file that never said.
    func intensityCalibration(imageTagGroup: String) -> IntensityCalibration? {
        let path = ["root", "ImageList", imageTagGroup, "ImageData", "Calibrations", "Brightness"]
        var node: Any? = tagsDict
        for key in path {
            guard let dictionary = node as? [String: Any] else { return nil }
            node = dictionary[key]
        }
        guard let brightness = node as? [String: Any] else { return nil }

        // A missing or zero scale is not a calibration: multiplying by zero would
        // erase the data, which is never what an absent tag meant.
        guard let scale = DigitalMicrographReader.double(brightness["Scale"]),
              scale.isFinite, scale != 0 else { return nil }
        let origin = DigitalMicrographReader.double(brightness["Origin"]) ?? 0
        guard origin.isFinite else { return nil }

        let calibration = IntensityCalibration(origin: origin, scale: scale,
                                               units: brightness["Units"] as? String ?? "")
        return calibration.isIdentity ? nil : calibration
    }

    /// Any of DM's numeric tag types as a Double.
    ///
    /// The width varies by tag and by file version, and `as? Double` returns nil
    /// for a Float rather than converting — which would look exactly like the tag
    /// being absent, and silently skip the calibration.
    static func double(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let f = value as? Float { return Double(f) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}

class DigitalMicrographReader {
    var dmVersion: Int?
    var endian: Endianness = .big
    var tagsDict: [String: Any] = [:]
    private var reader: BinaryReader
    
    init(fileURL: URL) throws {
        // Mapped, not copied. Only the tag tree is parsed here — the bulk data
        // is skipped over by offset — so reading a multi-gigabyte file into
        // memory to look at its header was paying for the whole file to learn
        // its shape. Mapping asks the kernel for the pages actually touched.
        let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
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
        
        var unnamedCounter = 0

        for _ in 0..<ntags {
            
            let tagHeader = try parseTagHeader()
            var tagName = tagHeader.tagName.replacingOccurrences(of: ".", with: "")
            
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
                    let reference = ["offset": dataOffset, "size": size, "datatype": dtype]
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

// MARK: - Dimension calibrations

/// One axis of a DM image, as the file records it.
struct DMAxisCalibration {
    /// Pixel index of the axis zero. `value = (pixel - origin) * scale`.
    var origin: Double
    var scale: Double
    /// As written, e.g. `nm` or `1/nm`. Meaningless without it, so it is kept.
    var units: String
}

/// The physical calibration of a 4D dataset, in the units the application uses.
///
/// Each field is nil when the file does not record it, or records it in a unit
/// this does not recognise. Nil is deliberate: a calibration that is wrong by a
/// factor of ten is worse than one that is absent, because nothing downstream
/// can tell it is wrong.
struct DMScanCalibration {
    var scanStepNanometres: Double?
    var diffractionStepMilliradians: Double?
    var voltageKilovolts: Double?
    /// Set when the diffraction axis is calibrated in reciprocal units but the
    /// voltage is missing, so the angle could not be worked out.
    var diffractionNeedsVoltage: Bool = false
    /// How far the recorded beam position sits from the centre of the detector,
    /// in pixels. Zero for a centred pattern.
    var beamOffsetFromCentre: (x: Double, y: Double)?
}

extension DigitalMicrographReader {

    private func tag(_ path: [String]) -> Any? {
        var node: Any? = tagsDict
        for key in path {
            guard let dictionary = node as? [String: Any] else { return nil }
            node = dictionary[key]
        }
        return node
    }

    /// The per-axis calibrations, in the same order as `ImageData/Dimensions`.
    ///
    /// For a 4D STEM dataset that is detector-x, detector-y, scan-x, scan-y —
    /// the order the loader already reads the dimensions in, so the two cannot
    /// disagree about which axis is which.
    func dimensionCalibrations(imageTagGroup: String) -> [DMAxisCalibration] {
        guard let dimensions = tag(["root", "ImageList", imageTagGroup,
                                    "ImageData", "Calibrations", "Dimension"]) as? [String: Any]
        else { return [] }

        // Sorted by tag name so the axes stay in file order; a dictionary gives
        // none, and getting scan and detector the wrong way round would produce
        // two calibrations that each look individually plausible.
        return dimensions.keys.sorted().compactMap { key in
            guard let axis = dimensions[key] as? [String: Any],
                  let scale = DigitalMicrographReader.double(axis["Scale"]) else { return nil }
            return DMAxisCalibration(origin: DigitalMicrographReader.double(axis["Origin"]) ?? 0,
                                     scale: scale,
                                     units: axis["Units"] as? String ?? "")
        }
    }

    /// Microscope name, imaging mode and camera length, as the file records
    /// them — the three things a calibration is filed under.
    ///
    /// The mode is assembled rather than taken from one tag: what makes two
    /// acquisitions comparable is the imaging mode *and* the camera length, and
    /// a diffraction step stored against the mode alone would be applied across
    /// a change of camera length that invalidates it.
    func instrumentDescription(imageTagGroup: String) -> (microscope: String, mode: String) {
        let info = tag(["root", "ImageList", imageTagGroup, "ImageTags", "Microscope Info"])
            as? [String: Any] ?? [:]
        let microscope = (info["Name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var parts: [String] = []
        if let imaging = (info["Imaging Mode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !imaging.isEmpty {
            parts.append(imaging)
        }
        if let length = DigitalMicrographReader.double(info["STEM Camera Length"]), length > 0 {
            parts.append(String(format: "CL %g mm", length))
        }
        return (microscope, parts.joined(separator: " · "))
    }

    /// Indicated magnification, which a stored step size is only meaningful
    /// alongside.
    func magnification(imageTagGroup: String) -> Double? {
        let value = DigitalMicrographReader.double(
            tag(["root", "ImageList", imageTagGroup, "ImageTags",
                 "Microscope Info", "Indicated Magnification"]))
        guard let value = value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Accelerating voltage in kilovolts, when the file records it.
    func voltageKilovolts(imageTagGroup: String) -> Double? {
        let volts = DigitalMicrographReader.double(
            tag(["root", "ImageList", imageTagGroup, "ImageTags", "Microscope Info", "Voltage"]))
        guard let volts = volts, volts.isFinite, volts > 0 else { return nil }
        return volts / 1000
    }

    /// The calibration of a 4D dataset, converted into the application's units.
    ///
    /// - Parameter patternPixels: detector width, used only to say how far the
    ///   recorded beam position is from the middle.
    func scanCalibration(imageTagGroup: String, patternPixels: Int = 0) -> DMScanCalibration {
        var result = DMScanCalibration()
        result.voltageKilovolts = voltageKilovolts(imageTagGroup: imageTagGroup)

        let axes = dimensionCalibrations(imageTagGroup: imageTagGroup)
        guard axes.count >= 4 else { return result }

        // Axes 0 and 1 are the detector, 2 and 3 the scan — the same split the
        // loader makes when it reads the dimensions.
        let detector = axes[0]
        let scan = axes[2]

        if let perPixel = DigitalMicrographReader.nanometres(1, in: scan.units) {
            let step = scan.scale * perPixel
            if step.isFinite, step > 0 { result.scanStepNanometres = step }
        }

        let wavelength = result.voltageKilovolts.map { DigitalMicrographReader.wavelengthNanometres(kilovolts: $0) }
        switch DigitalMicrographReader.diffractionUnit(detector.units) {
        case .angleMilliradians(let perUnit):
            let step = detector.scale * perUnit
            if step.isFinite, step > 0 { result.diffractionStepMilliradians = step }
        case .reciprocalNanometres(let perUnit):
            // q in 1/nm becomes an angle only through the wavelength: θ = qλ.
            if let wavelength = wavelength {
                let step = detector.scale * perUnit * wavelength * 1000
                if step.isFinite, step > 0 { result.diffractionStepMilliradians = step }
            } else {
                result.diffractionNeedsVoltage = true
            }
        case .unknown:
            break
        }

        if patternPixels > 0, axes.count >= 2 {
            let centre = Double(patternPixels) / 2
            result.beamOffsetFromCentre = (x: axes[0].origin - centre, y: axes[1].origin - centre)
        }
        return result
    }

    // MARK: Units

    /// How many nanometres one of `units` is, or nil if it is not a length.
    ///
    /// Returning nil rather than assuming nanometres matters: a file writing µm
    /// would otherwise calibrate a thousand times too fine, and every distance
    /// derived from it would look entirely reasonable.
    static func nanometres(_ value: Double, in units: String) -> Double? {
        switch normalise(units) {
        case "nm", "nanometre", "nanometer":       return value
        case "um", "micron", "micrometre", "micrometer": return value * 1_000
        case "mm":                                  return value * 1_000_000
        case "m", "metre", "meter":                 return value * 1_000_000_000
        case "a", "angstrom", "angstroem":          return value * 0.1
        case "pm", "picometre", "picometer":        return value * 0.001
        default:                                    return nil
        }
    }

    enum DiffractionUnit {
        /// Already an angle; the payload converts it to milliradians.
        case angleMilliradians(Double)
        /// Reciprocal length; the payload converts it to inverse nanometres.
        case reciprocalNanometres(Double)
        case unknown
    }

    static func diffractionUnit(_ units: String) -> DiffractionUnit {
        switch normalise(units) {
        case "mrad", "milliradian", "milliradians": return .angleMilliradians(1)
        case "rad", "radian", "radians":            return .angleMilliradians(1000)
        case "urad", "microradian", "microradians": return .angleMilliradians(0.001)
        case "1/nm", "nm-1", "nm^-1":               return .reciprocalNanometres(1)
        case "1/a", "a-1", "a^-1":                  return .reciprocalNanometres(10)
        case "1/um", "um-1", "um^-1":               return .reciprocalNanometres(0.001)
        case "1/m", "m-1", "m^-1":                  return .reciprocalNanometres(1e-9)
        case "1/pm", "pm-1", "pm^-1":               return .reciprocalNanometres(1000)
        default:                                    return .unknown
        }
    }

    /// Lowercased, stripped of spaces and periods, with the several ways a file
    /// may spell micro and ångström folded together.
    ///
    /// DM writes the micro sign (U+00B5) but Greek mu (U+03BC) renders the same
    /// and appears in files too; likewise Å as one code point or as A plus a
    /// combining ring. Comparing the raw strings makes the calibration depend on
    /// which of two identical-looking characters the vendor happened to use.
    static func normalise(_ units: String) -> String {
        var text = units.lowercased()
        text = text.replacingOccurrences(of: "\u{00B5}", with: "u")   // micro sign
        text = text.replacingOccurrences(of: "\u{03BC}", with: "u")   // greek mu
        text = text.replacingOccurrences(of: "\u{00C5}", with: "a")   // Å
        text = text.replacingOccurrences(of: "\u{212B}", with: "a")   // angstrom sign
        text = text.replacingOccurrences(of: "\u{0227}", with: "a")
        text = text.folding(options: .diacriticInsensitive, locale: nil)
        return text.filter { !$0.isWhitespace && $0 != "." }
    }

    /// Relativistic electron wavelength in nanometres.
    static func wavelengthNanometres(kilovolts: Double) -> Double {
        let volts = kilovolts * 1000
        return 1.226426 / (volts * (1 + 0.9784755e-6 * volts)).squareRoot()
    }
}
