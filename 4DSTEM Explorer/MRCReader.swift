//
//  MRCReader.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 3/25/25.
//  Copyright © 2025 The LeBeau Group. All rights reserved.
//

import Foundation

/// A minimal struct for the first part of the MRC2014 header.
/// For a complete definition, refer to MRC2014 specifications.
struct MRCHeader {
    // These are the first 10 32-bit integers:
    var nx: Int32       // Number of columns (fastest changing dimension)
    var ny: Int32       // Number of rows
    var nz: Int32       // Number of sections (z dimension)
    var mode: Int32     // Type of data (0=int8,1=int16,2=float32, etc.)
    var nxStart: Int32
    var nyStart: Int32
    var nzStart: Int32
    var mx: Int32       // Grid size in x
    var my: Int32       // Grid size in y
    var mz: Int32       // Grid size in z

    // Next 6 floats (cella, cellb)
    var xlen: Float     // cell dimension in x (Å or nm depending on context)
    var ylen: Float
    var zlen: Float
    var alpha: Float
    var beta: Float
    var gamma: Float

    // Next 3 ints (mapc, mapr, maps)
    var mapc: Int32
    var mapr: Int32
    var maps: Int32

    // Next 3 floats (dmin, dmax, dmean)
    var dmin: Float
    var dmax: Float
    var dmean: Float

    // Next int (ispg) and int (nsymbt)
    var ispg: Int32
    var nsymbt: Int32

    // There are many other fields in the 1024-byte header,
    // but we'll define just a few more for illustration.
    // ...
    // Offsets up to 1024 can contain more data, e.g., extra space,
    // "MAP " signature, "MACHST" bytes, etc.

    // A simple initializer that extracts fields from a 1024-byte header.
    init?(data: Data) {
        guard data.count >= 1024 else {
            return nil
        }
        // Read in a safe manner using `withUnsafeBytes`.
        let headerValues = data.withUnsafeBytes { ptr -> (Int32, Int32, Int32, Int32,
                                                          Int32, Int32, Int32, Int32,
                                                          Int32, Int32, Float, Float,
                                                          Float, Float, Float, Float,
                                                          Int32, Int32, Int32, Float,
                                                          Float, Float, Int32, Int32)?
            in
            guard ptr.count >= 1024 else {
                return nil
            }
            
            // Use the pointer’s baseAddress plus known offsets.
            // Each Int32 is 4 bytes, each Float is 4 bytes.
            // We’ll rely on sequential reading for clarity.
            
            let base = ptr.bindMemory(to: UInt8.self).baseAddress!
            
            // Helper to read an Int32 at a certain offset
            func readInt32(at offset: Int) -> Int32 {
                let val = base.advanced(by: offset).withMemoryRebound(to: Int32.self, capacity: 1) {
                    $0.pointee
                }
                return Int32(littleEndian: val)
            }

            // Helper to read a Float at a certain offset
            func readFloat(at offset: Int) -> Float {
                let val = base.advanced(by: offset).withMemoryRebound(to: Float.self, capacity: 1) {
                    $0.pointee
                }
                // On most platforms, Float in Swift is IEEE 754 single-precision,
                // so no separate endianness swap is typically needed beyond reading the bytes as little-endian.
                return val
            }

            // Offsets in bytes (4 bytes each for Int32/Float):
            let nx      = readInt32(at: 0)
            let ny      = readInt32(at: 4)
            let nz      = readInt32(at: 8)
            let mode    = readInt32(at: 12)
            let nxStart = readInt32(at: 16)
            let nyStart = readInt32(at: 20)
            let nzStart = readInt32(at: 24)
            let mx      = readInt32(at: 28)
            let my      = readInt32(at: 32)
            let mz      = readInt32(at: 36)
            
            let xlen    = readFloat(at: 40)
            let ylen    = readFloat(at: 44)
            let zlen    = readFloat(at: 48)
            let alpha   = readFloat(at: 52)
            let beta    = readFloat(at: 56)
            let gamma   = readFloat(at: 60)
            
            let mapc    = readInt32(at: 64)
            let mapr    = readInt32(at: 68)
            let maps    = readInt32(at: 72)
            
            let dmin    = readFloat(at: 76)
            let dmax    = readFloat(at: 80)
            let dmean   = readFloat(at: 84)
            
            let ispg    = readInt32(at: 88)
            let nsymbt  = readInt32(at: 92)

            return (nx, ny, nz, mode,
                    nxStart, nyStart, nzStart, mx,
                    my, mz, xlen, ylen, zlen, alpha,
                    beta, gamma, mapc, mapr, maps,
                    dmin, dmax, dmean, ispg, nsymbt)
        }
        
        guard let values = headerValues else {
            return nil
        }
        
        self.nx       = values.0
        self.ny       = values.1
        self.nz       = values.2
        self.mode     = values.3
        self.nxStart  = values.4
        self.nyStart  = values.5
        self.nzStart  = values.6
        self.mx       = values.7
        self.my       = values.8
        self.mz       = values.9
        self.xlen     = values.10
        self.ylen     = values.11
        self.zlen     = values.12
        self.alpha    = values.13
        self.beta     = values.14
        self.gamma    = values.15
        self.mapc     = values.16
        self.mapr     = values.17
        self.maps     = values.18
        self.dmin     = values.19
        self.dmax     = values.20
        self.dmean    = values.21
        self.ispg     = values.22
        self.nsymbt   = values.23
    }
}

/// A convenience container for a loaded MRC volume:
/// - header: parsed metadata
/// - volumeData: the raw 3D data buffer (in floats for simplicity)
struct MRCVolume {
    var header: MRCHeader
    var volumeData: [Float]   // Flattened 3D array: [z][y][x]
}

/// Reads an MRC file from disk, returns `MRCVolume` if successful.
func loadMRCFile(from url: URL) throws -> MRCVolume {
    // Read the entire file into memory
    let fileData = try Data(contentsOf: url)
    
    // Parse header (first 1024 bytes)
    guard let header = MRCHeader(data: fileData) else {
        throw NSError(domain: "MRCReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid MRC header"])
    }
    
    // The data portion starts right after the 1024-byte header plus any extended header (nsymbt).
    let extendedHeaderSize = Int(header.nsymbt)
    let dataStart = 1024 + extendedHeaderSize
    
    guard fileData.count >= dataStart else {
        throw NSError(domain: "MRCReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "File too small for extended header"])
    }

    // The data dimensions
    let nx = Int(header.nx)
    let ny = Int(header.ny)
    let nz = Int(header.nz)

    // Data type depends on `header.mode`
    // For brevity, we only show how to handle mode = 2 (float32).
    // If your file can have other modes, you'd need additional logic.
    guard header.mode == 2 else {
        throw NSError(domain: "MRCReader", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported MRC mode: \(header.mode). Only float32 supported in this example."])
    }

    // Each voxel is 4 bytes if mode == 2.
    let voxelCount = nx * ny * nz
    let dataSizeNeeded = voxelCount * MemoryLayout<Float>.size

    // Make sure the file has enough bytes for the entire data array
    guard fileData.count >= dataStart + dataSizeNeeded else {
        throw NSError(domain: "MRCReader", code: 4, userInfo: [NSLocalizedDescriptionKey: "File too small for all voxel data"])
    }

    // Extract the raw float32 volume data
    let volumeBytes = fileData[dataStart ..< dataStart + dataSizeNeeded]
    
    // Convert those bytes to [Float]
    let volumeArray = volumeBytes.withUnsafeBytes {
        Array($0.bindMemory(to: Float.self))
    }
    
    return MRCVolume(header: header, volumeData: volumeArray)
}


