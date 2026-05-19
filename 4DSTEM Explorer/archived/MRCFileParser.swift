// FEI1MetadataParser.swift
// Swift module to parse FEI1 Extended Header blocks in MRC2014 files

import Foundation

// MARK: - Bitmask Utility
func isBitSet(_ mask: UInt32, bit: Int) -> Bool {
    return (mask & (1 << bit)) != 0
}

// MARK: - DataReader
struct DataReader {
    var data: Data
    var offset: Int = 0

    mutating func readInt32() -> Int32 {
        defer { offset += 4 }
        return data[offset..<offset+4].withUnsafeBytes { $0.load(as: Int32.self) }
    }

    mutating func readUInt32() -> UInt32 {
        defer { offset += 4 }
        return data[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    mutating func readDouble() -> Double {
        defer { offset += 8 }
        return data[offset..<offset+8].withUnsafeBytes { $0.load(as: Double.self) }
    }

    mutating func readBool() -> Bool {
        defer { offset += 1 }
        return data[offset] != 0
    }

    mutating func readString(_ length: Int) -> String {
        defer { offset += length }
        let slice = data.subdata(in: offset - length..<offset)
        return String(bytes: slice, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters.union(.whitespaces)) ?? ""
    }

    mutating func skip(_ count: Int) {
        offset += count
    }
}

// MARK: - MRC Header
struct MRCHeader {
    var nx: Int32
    var ny: Int32
    var nz: Int32
    var mode: Int32
    var nsymbt: Int32
    var extType: String
}

func readMRCHeader(from url: URL) throws -> MRCHeader {
    let data = try Data(contentsOf: url)
    guard data.count >= 1024 else { throw NSError(domain: "MRC", code: 1, userInfo: [NSLocalizedDescriptionKey: "Header too small"]) }
    var r = DataReader(data: data)

    let nx = r.readInt32()
    let ny = r.readInt32()
    let nz = r.readInt32()
    let mode = r.readInt32()
    r.skip(40) // skip to nsymbt
    r.skip(4 * 6)
    r.skip(12) // xlen, ylen, zlen
    r.skip(12) // alpha, beta, gamma
    r.skip(12) // mapc, mapr, maps
    r.skip(12) // dmin, dmax, dmean
    r.skip(4)  // ispg
    let nsymbt = r.readInt32()
    r.skip(100 + 12) // extra + origin
    r.skip(4)  // MAP
    r.skip(4)  // machst
    r.skip(4)  // rms
    r.skip(4)  // nlabl
    r.skip(80 * 10) // labels

    let extTypeRange = 208..<212 // offset 208: EXTTYP (4 bytes)
    let extType = String(bytes: data.subdata(in: extTypeRange), encoding: .ascii) ?? ""

    return MRCHeader(nx: nx, ny: ny, nz: nz, mode: mode, nsymbt: nsymbt, extType: extType)
}

// MARK: - Data Models (same as before)
struct Gun { var ht: Double; var dose: Double }
struct Stage { var alphaTilt, betaTilt, x, y, z, tiltAxisAngle, dualAxisRotation: Double }
struct PixelSize { var x: Double; var y: Double }
struct Optics {
    var defocus, stemDefocus, appliedDefocus: Double
    var instrumentMode, projectionMode, probeMode: Int32
    var objectiveLensMode, highMagnificationMode: String
    var eftemOn: Bool
    var magnification: Double
}
struct Camera {
    var integrationTime: Double
    var binningWidth, binningHeight: Int32
    var cameraName: String
}
struct ImageShifts {
    var shiftOffsetX, shiftOffsetY, shiftX, shiftY: Double
}
struct EFTEM {
    var slitInserted: Bool
    var slitWidth, accelerationVoltageOffset, driftTubeVoltage, energyShift: Double
}
struct STEM { var detectorName: String; var gain, offset: Double }
struct ScanSettings {
    var dwellTime, frameTime: Double
    var scanSizeLeft, scanSizeTop, scanSizeRight, scanSizeBottom: Int32
    var fullScanFOVX, fullScanFOVY: Double
}
struct EDXMap {
    var element: String
    var energyIntervalLower, energyIntervalHigher: Double
    var method: Int32
}
struct DoseFraction {
    var isDoseFraction: Bool
    var fractionNumber, startFrame, endFrame: Int32
}

struct FEI1MetadataBlock {
    var metadataSize: Int32
    var metadataVersion: Int32
    var bitmask1, bitmask2, bitmask3, bitmask4: UInt32

    var timestamp: Double?
    var microscopeType, dNumber, application, applicationVersion: String?

    var gun: Gun?
    var stage: Stage?
    var pixelSize: PixelSize?
    var optics: Optics?
    var camera: Camera?
    var imageShifts: ImageShifts?
    var eftem: EFTEM?
    var stem: STEM?
    var scanSettings: ScanSettings?
    var edxMap: EDXMap?
    var doseFraction: DoseFraction?
}

// MARK: - Main Metadata Parser
func parseFEI1MetadataBlock(from data: Data) -> FEI1MetadataBlock? {
    guard data.count >= 768 else { return nil }
    var r = DataReader(data: data)

    var m = FEI1MetadataBlock(
        metadataSize: r.readInt32(),
        metadataVersion: r.readInt32(),
        bitmask1: r.readUInt32(), bitmask2: 0, bitmask3: 0, bitmask4: 0
    )

    m.timestamp = isBitSet(m.bitmask1, bit: 0) ? r.readDouble() : { r.skip(8); return nil }()
    m.microscopeType = isBitSet(m.bitmask1, bit: 1) ? r.readString(16) : { r.skip(16); return nil }()
    m.dNumber = isBitSet(m.bitmask1, bit: 2) ? r.readString(16) : { r.skip(16); return nil }()
    m.application = isBitSet(m.bitmask1, bit: 3) ? r.readString(16) : { r.skip(16); return nil }()
    m.applicationVersion = isBitSet(m.bitmask1, bit: 4) ? r.readString(16) : { r.skip(16); return nil }()

    if isBitSet(m.bitmask1, bit: 5) && isBitSet(m.bitmask1, bit: 6) {
        m.gun = Gun(ht: r.readDouble(), dose: r.readDouble())
    } else { r.skip(16) }

    if (7...13).allSatisfy({ isBitSet(m.bitmask1, bit: $0) }) {
        m.stage = Stage(
            alphaTilt: r.readDouble(), betaTilt: r.readDouble(), x: r.readDouble(), y: r.readDouble(),
            z: r.readDouble(), tiltAxisAngle: r.readDouble(), dualAxisRotation: r.readDouble()
        )
    } else { r.skip(56) }

    m.pixelSize = (isBitSet(m.bitmask1, bit: 14) && isBitSet(m.bitmask1, bit: 15)) ? PixelSize(x: r.readDouble(), y: r.readDouble()) : { r.skip(16); return nil }()

    r.skip(297 - r.offset)
    m.bitmask2 = r.readUInt32()
    m.bitmask3 = r.readUInt32()
    m.bitmask4 = r.readUInt32()

    if (22...31).contains(where: { isBitSet(m.bitmask1, bit: $0) }) {
        m.optics = Optics(
            defocus: r.readDouble(), stemDefocus: r.readDouble(), appliedDefocus: r.readDouble(),
            instrumentMode: r.readInt32(), projectionMode: r.readInt32(),
            probeMode: r.readInt32(), objectiveLensMode: r.readString(16), highMagnificationMode: r.readString(16), eftemOn: r.readBool(), magnification: { r.skip(7); return r.readDouble() }()
        )
    } else { r.skip(88) }

    m.camera = isBitSet(m.bitmask2, bit: 16) ? Camera(
        integrationTime: r.readDouble(), binningWidth: r.readInt32(), binningHeight: r.readInt32(), cameraName: r.readString(16)
    ) : { r.skip(32); return nil }()

    m.imageShifts = (12...15).allSatisfy { isBitSet(m.bitmask2, bit: $0) } ? ImageShifts(
        shiftOffsetX: r.readDouble(), shiftOffsetY: r.readDouble(), shiftX: r.readDouble(), shiftY: r.readDouble()
    ) : { r.skip(32); return nil }()

    if (7...11).allSatisfy({ isBitSet(m.bitmask2, bit: $0) }) {
        m.eftem = EFTEM(
            slitInserted: r.readBool(),
            slitWidth: { r.skip(7); return r.readDouble() }(),
            accelerationVoltageOffset: r.readDouble(),
            driftTubeVoltage: r.readDouble(),
            energyShift: r.readDouble()
        )
    } else { r.skip(40) }

    m.stem = isBitSet(m.bitmask3, bit: 7) ? STEM(
        detectorName: r.readString(16), gain: r.readDouble(), offset: r.readDouble()
    ) : { r.skip(40); return nil }()

    m.scanSettings = isBitSet(m.bitmask3, bit: 15) ? ScanSettings(
        dwellTime: r.readDouble(), frameTime: r.readDouble(),
        scanSizeLeft: r.readInt32(), scanSizeTop: r.readInt32(),
        scanSizeRight: r.readInt32(), scanSizeBottom: r.readInt32(),
        fullScanFOVX: r.readDouble(), fullScanFOVY: r.readDouble()
    ) : { r.skip(64); return nil }()

    m.edxMap = isBitSet(m.bitmask3, bit: 23) ? EDXMap(
        element: r.readString(16), energyIntervalLower: r.readDouble(), energyIntervalHigher: r.readDouble(), method: r.readInt32()
    ) : { r.skip(40); return nil }()

    m.doseFraction = isBitSet(m.bitmask3, bit: 27) ? DoseFraction(
        isDoseFraction: r.readBool(),
        fractionNumber: { r.skip(3); return r.readInt32() }(),
        startFrame: r.readInt32(), endFrame: r.readInt32()
    ) : { r.skip(16); return nil }()

    return m
}

func readFEI1ExtendedHeaders(from url: URL) throws -> [FEI1MetadataBlock] {
    let header = try readMRCHeader(from: url)
    
    // Check for correct type and header size
    guard header.extType == "FEI1", header.nsymbt > 0 else {
        print("No FEI1 extended header found.")
        return []
    }

    let fullData = try Data(contentsOf: url)
    let extendedHeaderStart = 1024
    let blockSize = 768
    let blockCount = Int(header.nsymbt) / blockSize

    var metadataBlocks: [FEI1MetadataBlock] = []
    
    for i in 0..<blockCount {
        let offset = extendedHeaderStart + (i * blockSize)
        let blockData = fullData.subdata(in: offset..<offset + blockSize)

        if let metadata = parseFEI1MetadataBlock(from: blockData) {
            metadataBlocks.append(metadata)
        } else {
            print("⚠️ Could not parse metadata block at index \(i)")
        }
    }

    return metadataBlocks
}
