//
//  ArinaReader.swift
//  4DSTEM Explorer
//
//  Reads the native output of a DECTRIS ARINA.
//
//  The detector writes a NeXus master file holding nothing but external links,
//  one per block of frames, to a series of data files beside it. Each block is a
//  3D stack of frames chunked one frame at a time and compressed with
//  "bslz4" — bitshuffle followed by LZ4, HDF5 filter 32008, which is a plugin
//  rather than part of the library. libhdf5 without it does not fail on a read;
//  it returns nothing, which is why the chunks are fetched raw here and decoded
//  by `BitShuffleLZ4` instead.
//
//  Two things the file does not record:
//
//    * The scan raster. It knows only how many frames were triggered, so a
//      square raster is offered and the caller may say otherwise.
//    * Which way round the detector is. The convention in use here flips both
//      detector axes, matching what the group's own analysis does.
//
//  Scans are large — a 1024×1024 raster of 96×96 frames is 19 GB of counts and
//  39 GB once converted to the float the rest of the application works in — so
//  the reader bins the scan as it goes. Binning during the read rather than
//  after is what keeps the full array from ever existing.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

struct ArinaDataset {
    /// Probe positions after binning.
    var scanWidth: Int
    var scanHeight: Int
    /// Detector pixels.
    var patternWidth: Int
    var patternHeight: Int

    /// The raster before binning, as read or as the caller specified.
    var sourceScanWidth: Int
    var sourceScanHeight: Int
    /// Probe positions summed into each output position, per axis.
    var scanBinning: Int

    /// Frames the detector actually wrote.
    var frameCount: Int
    /// `/entry/data/...` paths, in acquisition order.
    var blockPaths: [String]
    /// Frames in each block, parallel to `blockPaths`.
    var blockCounts: [Int]

    var detectorDescription: String
    var compression: String
    var calibrations: Calibrations?
    var summary: String

    var totalPatterns: Int { return scanWidth * scanHeight }
    var patternPixels: Int { return patternWidth * patternHeight }

    /// Bytes the stack will occupy once read.
    var memoryBytes: Int { return totalPatterns * patternPixels * MemoryLayout<Float>.size }
}

enum ArinaError: Error, LocalizedError {
    case notReadable(String)
    case notArina(String)
    case inconsistentFrames(String)
    case rasterMismatch(frames: Int, width: Int, height: Int)
    case decodeFailed(frame: Int, underlying: String)

    var errorDescription: String? {
        switch self {
        case .notReadable(let name):
            return "\(name) could not be opened as an HDF5 file."
        case .notArina(let name):
            return "\(name) does not look like an ARINA master file."
        case .inconsistentFrames(let detail):
            return "The frame blocks do not agree: \(detail)"
        case .rasterMismatch(let frames, let width, let height):
            return "A \(width)×\(height) raster needs \(width * height) frames, but the detector wrote \(frames)."
        case .decodeFailed(let frame, let underlying):
            return "Frame \(frame) could not be decoded: \(underlying)"
        }
    }
}

/// How the scan is reduced on the way in.
enum ArinaReduction: String, CaseIterable, Identifiable {
    /// Sum every f×f group of probe positions into one.
    case bin
    /// Keep every f-th probe position and discard the rest.
    case stride

    var id: String { rawValue }

    var label: String { return self == .bin ? "Bin" : "Stride" }

    var explanation: String {
        switch self {
        case .bin:
            return "Sums each group of probe positions, so nothing is thrown away and the counts per position rise with the square of the factor. Every frame has to be decoded, so it takes as long as the full scan would."
        case .stride:
            return "Keeps one probe position out of every group. Only the positions kept are decoded, so it is as many times faster as the factor squared — at the cost of the counts in the positions skipped."
        }
    }
}


/// Turns off libhdf5's automatic error printing for as long as it is held.
///
/// The library's default is to print a diagnostic stack to stderr whenever a
/// call fails, including calls whose failure is the answer being looked for.
struct HDF5Silence {
    private var function: H5E_auto2_t?
    private var context: UnsafeMutableRawPointer?

    init() {
        H5Eget_auto2(0, &function, &context)
        H5Eset_auto2(0, nil, nil)
    }

    func restore() {
        H5Eset_auto2(0, function, context)
    }
}

enum ArinaReader {

    /// Where the detector's frames live inside the master.
    private static let dataGroup = "/entry/data"
    private static let detectorGroup = "/entry/instrument/detector"

    // MARK: - Recognition

    /// Whether this file is an ARINA master.
    ///
    /// Checked by structure rather than by extension: `.h5` is shared with
    /// py4DSTEM, EMD and everything else, and an ARINA master is distinctive —
    /// a detector description, and a data group of nothing but frame blocks.
    static func looksLikeArina(url: URL) -> Bool {
        // Asking whether a link exists in a file that has no such path is a
        // normal question with a normal answer, but libhdf5 prints a stack of
        // diagnostics to stderr before returning it. Since this is called on
        // every HDF5 file the user opens, that would be a wall of noise about
        // nothing.
        let quiet = HDF5Silence()
        defer { quiet.restore() }

        let file = H5Fopen(url.path, UInt32(H5F_ACC_RDONLY), 0)
        guard file >= 0 else { return false }
        defer { H5Fclose(file) }
        guard H5Lexists(file, dataGroup, 0) > 0 else { return false }
        let description = text(file: file, at: "\(detectorGroup)/description") ?? ""
        let compression = text(file: file,
                               at: "\(detectorGroup)/detectorSpecific/compression") ?? ""
        if description.uppercased().contains("ARINA") { return true }
        // A DECTRIS master without the name still gives itself away.
        return compression.lowercased() == "bslz4" && !blockNames(file: file).isEmpty
    }

    // MARK: - Inspection

    /// What the file holds, and what reading it under these settings will cost.
    ///
    /// - Parameters:
    ///   - raster: the scan the caller believes was run. Nil asks for the square
    ///     one implied by the frame count, which is what the detector's own
    ///     metadata supports and nothing more — it records how many frames were
    ///     triggered, never their arrangement.
    ///   - factor: probe positions combined per axis.
    static func inspect(url: URL, raster: (width: Int, height: Int)? = nil,
                        factor: Int = 1,
                        reduction: ArinaReduction = .stride) throws -> ArinaDataset {

        let file = H5Fopen(url.path, UInt32(H5F_ACC_RDONLY), 0)
        guard file >= 0 else { throw ArinaError.notReadable(url.lastPathComponent) }
        defer { H5Fclose(file) }

        let names = blockNames(file: file)
        guard !names.isEmpty else { throw ArinaError.notArina(url.lastPathComponent) }

        var paths: [String] = []
        var counts: [Int] = []
        var width = 0, height = 0

        for name in names {
            let path = "\(dataGroup)/\(name)"
            let dataset = H5Dopen2(file, path, 0)
            guard dataset >= 0 else { continue }
            defer { H5Dclose(dataset) }
            guard let extent = extent(of: dataset), extent.count == 3 else { continue }
            if width == 0 { height = extent[1]; width = extent[2] }
            guard extent[1] == height, extent[2] == width else {
                throw ArinaError.inconsistentFrames(
                    "\(name) holds \(extent[1])×\(extent[2]) frames where the others hold \(height)×\(width)")
            }
            paths.append(path)
            counts.append(extent[0])
        }

        guard !paths.isEmpty, width > 0, height > 0 else {
            throw ArinaError.notArina(url.lastPathComponent)
        }
        let frames = counts.reduce(0, +)

        // The raster. Square unless told otherwise, because that is all the
        // frame count can support on its own.
        var sourceWidth: Int, sourceHeight: Int
        if let raster = raster {
            sourceWidth = raster.width; sourceHeight = raster.height
        } else {
            let side = Int(Double(frames).squareRoot().rounded())
            sourceWidth = side; sourceHeight = side
        }
        guard sourceWidth > 0, sourceHeight > 0, sourceWidth * sourceHeight <= frames else {
            throw ArinaError.rasterMismatch(frames: frames, width: sourceWidth, height: sourceHeight)
        }

        let f = max(1, factor)
        let outWidth = max(1, sourceWidth / f)
        let outHeight = max(1, sourceHeight / f)

        let description = text(file: file, at: "\(detectorGroup)/description") ?? "ARINA"
        let compression = text(file: file,
                               at: "\(detectorGroup)/detectorSpecific/compression") ?? "bslz4"

        var summary = "\(description): \(frames) frames of \(width)×\(height), \(compression)"
        summary += ", \(sourceWidth)×\(sourceHeight) scan"
        if f > 1 {
            summary += " \(reduction == .bin ? "binned" : "strided") \(f)× to \(outWidth)×\(outHeight)"
        }

        return ArinaDataset(scanWidth: outWidth, scanHeight: outHeight,
                            patternWidth: width, patternHeight: height,
                            sourceScanWidth: sourceWidth, sourceScanHeight: sourceHeight,
                            scanBinning: f,
                            frameCount: frames, blockPaths: paths, blockCounts: counts,
                            detectorDescription: description, compression: compression,
                            calibrations: calibrations(file: file, patternWidth: width),
                            summary: summary)
    }

    // MARK: - Reading

    /// Fills `destination` with the reduced scan, one pattern after another.
    ///
    /// Frames are walked in the order the detector wrote them, so the files are
    /// read front to back whichever reduction is in use. Striding simply never
    /// asks for the chunks it is going to discard, which is where its speed
    /// comes from — the cost is dominated by decoding, not by seeking.
    static func read(_ dataset: ArinaDataset, url: URL,
                     reduction: ArinaReduction,
                     into destination: UnsafeMutablePointer<Float>,
                     progress: (Double) -> Bool) throws {

        let file = H5Fopen(url.path, UInt32(H5F_ACC_RDONLY), 0)
        guard file >= 0 else { throw ArinaError.notReadable(url.lastPathComponent) }
        defer { H5Fclose(file) }

        let pixels = dataset.patternPixels
        let width = dataset.patternWidth, height = dataset.patternHeight
        let f = max(1, dataset.scanBinning)
        let sourceWidth = dataset.sourceScanWidth, sourceHeight = dataset.sourceScanHeight
        let outWidth = dataset.scanWidth, outHeight = dataset.scanHeight

        destination.update(repeating: 0, count: outWidth * outHeight * pixels)

        var raw = [UInt8](repeating: 0, count: max(1024, pixels * 4))
        var global = 0
        let wanted = sourceWidth * sourceHeight

        for (index, path) in dataset.blockPaths.enumerated() {
            if global >= wanted { break }
            let handle = H5Dopen2(file, path, 0)
            guard handle >= 0 else {
                throw ArinaError.notReadable("\(url.lastPathComponent) → \(path)")
            }
            defer { H5Dclose(handle) }

            for local in 0..<dataset.blockCounts[index] {
                defer { global += 1 }
                guard global < wanted else { break }

                let sourceRow = global / sourceWidth
                let sourceColumn = global % sourceWidth
                if reduction == .stride, sourceRow % f != 0 || sourceColumn % f != 0 { continue }
                let outRow = sourceRow / f, outColumn = sourceColumn / f
                guard outRow < outHeight, outColumn < outWidth else { continue }

                if global % 4096 == 0 {
                    if !progress(Double(global) / Double(wanted)) { return }
                }

                var offset: [hsize_t] = [hsize_t(local), 0, 0]
                var storage: hsize_t = 0
                guard H5Dget_chunk_storage_size(handle, &offset, &storage) >= 0, storage > 0 else {
                    continue        // a frame never written; leave it at zero
                }
                if raw.count < Int(storage) { raw = [UInt8](repeating: 0, count: Int(storage)) }

                var filters: UInt32 = 0
                let status = raw.withUnsafeMutableBytes { buffer -> herr_t in
                    H5Dread_chunk1(handle, 0, &offset, &filters, buffer.baseAddress)
                }
                guard status >= 0 else {
                    throw ArinaError.decodeFailed(frame: global, underlying: "HDF5 refused the chunk")
                }

                let decoded: [UInt8]
                do {
                    decoded = try BitShuffleLZ4.decode(Data(raw[0..<Int(storage)]), elementSize: 2)
                } catch {
                    throw ArinaError.decodeFailed(frame: global,
                                                  underlying: error.localizedDescription)
                }
                guard decoded.count >= pixels * 2 else {
                    throw ArinaError.decodeFailed(frame: global, underlying: "short frame")
                }

                // Both detector axes are flipped, which is the orientation the
                // group's analysis uses. Written as one reversed walk rather
                // than two passes.
                let base = (outRow * outWidth + outColumn) * pixels
                decoded.withUnsafeBytes { bytes in
                    let counts = bytes.bindMemory(to: UInt16.self)
                    for y in 0..<height {
                        let sourceRowStart = y * width
                        let destRowStart = base + (height - 1 - y) * width
                        for x in 0..<width {
                            destination[destRowStart + (width - 1 - x)]
                                += Float(UInt16(littleEndian: counts[sourceRowStart + x]))
                        }
                    }
                }
            }
        }
        _ = progress(1.0)
    }

    // MARK: - Poking about in the file

    /// Frame blocks, in acquisition order.
    ///
    /// Sorted by name because the master lists them as `data_000001` upwards and
    /// the order is the scan order; HDF5's own link order is not promised to be.
    private static func blockNames(file: hid_t) -> [String] {
        guard H5Lexists(file, dataGroup, 0) > 0 else { return [] }
        let group = H5Gopen2(file, dataGroup, 0)
        guard group >= 0 else { return [] }
        defer { H5Gclose(group) }

        var info = H5G_info_t()
        guard H5Gget_info(group, &info) >= 0 else { return [] }

        var names: [String] = []
        for index in 0..<Int(info.nlinks) {
            let length = H5Lget_name_by_idx(group, ".", H5_INDEX_NAME, H5_ITER_INC,
                                            hsize_t(index), nil, 0, 0)
            guard length > 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(length) + 1)
            guard H5Lget_name_by_idx(group, ".", H5_INDEX_NAME, H5_ITER_INC,
                                     hsize_t(index), &buffer, Int(length) + 1, 0) > 0 else { continue }
            let name = String(cString: buffer)
            if !name.isEmpty { names.append(name) }
        }
        return names.sorted()
    }

    private static func extent(of dataset: hid_t) -> [Int]? {
        let space = H5Dget_space(dataset)
        guard space >= 0 else { return nil }
        defer { H5Sclose(space) }
        let rank = H5Sget_simple_extent_ndims(space)
        guard rank > 0 else { return nil }
        var dims = [hsize_t](repeating: 0, count: Int(rank))
        guard H5Sget_simple_extent_dims(space, &dims, nil) >= 0 else { return nil }
        return dims.map { Int($0) }
    }

    /// A string dataset, fixed or variable length.
    private static func text(file: hid_t, at path: String) -> String? {
        guard H5Lexists(file, path, 0) > 0 else { return nil }
        let dataset = H5Dopen2(file, path, 0)
        guard dataset >= 0 else { return nil }
        defer { H5Dclose(dataset) }
        let type = H5Dget_type(dataset)
        guard type >= 0, H5Tget_class(type) == H5T_STRING else { H5Tclose(type); return nil }
        defer { H5Tclose(type) }

        let memory = H5Tcopy(H5T_C_S1_g)
        defer { H5Tclose(memory) }
        if H5Tis_variable_str(type) > 0 {
            H5Tset_size(memory, size_t.max)
            var pointer: UnsafeMutablePointer<CChar>? = nil
            guard H5Dread(dataset, memory, 0, 0, 0, &pointer) >= 0, let text = pointer else { return nil }
            let value = String(cString: text)
            free(pointer)
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let size = H5Tget_size(type)
        guard size > 0, size < 4096 else { return nil }
        H5Tset_size(memory, size_t(size + 1))
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard H5Dread(dataset, memory, 0, 0, 0, &buffer) >= 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func scalar(file: hid_t, at path: String) -> Double? {
        guard H5Lexists(file, path, 0) > 0 else { return nil }
        let dataset = H5Dopen2(file, path, 0)
        guard dataset >= 0 else { return nil }
        defer { H5Dclose(dataset) }
        var value: Double = 0
        guard H5Dread(dataset, H5T_NATIVE_DOUBLE_g, 0, 0, 0, &value) >= 0 else { return nil }
        return value.isFinite ? value : nil
    }

    /// What the master says about the geometry.
    ///
    /// Only the accelerating voltage is taken. The detector records a camera
    /// length and a pixel pitch, and those do give an angle per pixel — but the
    /// camera length recorded is the microscope's nominal one, which is the
    /// number this application's own calibration exists to replace. Reading it
    /// in as though it were measured would quietly undo that.
    private static func calibrations(file: hid_t, patternWidth: Int) -> Calibrations? {
        var volts: Float? = nil
        if let photon = scalar(file: file, at: "\(detectorGroup)/detectorSpecific/photon_energy"),
           photon > 1000 {
            volts = Float(photon / 1000)
        }
        guard let kilovolts = volts else { return nil }
        return Calibrations(scan_step: nil, diff_step: nil, voltage: kilovolts)
    }
}
