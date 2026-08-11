//
//  EMDReader.swift
//  4DSTEM Explorer
//
//  EMD (Electron Microscopy Dataset) files — HDF5 containers written by
//  py4DSTEM, emdfile, and Berkeley-style EMD writers.
//
//  Built on the vendored HDF5Kit (see HDF5Kit/README.md), so layout and
//  compression are libhdf5's problem rather than ours: contiguous or chunked,
//  gzip, szip, shuffle, whatever the writer chose.
//
//  Two things are done by hand rather than through HDF5Kit:
//
//  * Group listing uses `H5Lget_name_by_idx`. HDF5Kit's `objectNames()` calls
//    `H5Gget_num_objs`, an HDF5 1.6 API deprecated since 1.8 that a build
//    without deprecated symbols does not export.
//  * The stack is read a slab at a time rather than in one call, so the load
//    keeps its progress bar and Cancel button and needs no second copy of the
//    data in memory.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

enum EMDError: LocalizedError {
    case notReadable(String)
    case noFourDimensionalDataset(String)
    case unsupportedSampleFormat(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReadable(let name):
            return "\(name) could not be opened as an HDF5 file."
        case .noFourDimensionalDataset(let detail):
            return "This EMD file has no four-dimensional dataset. \(detail)"
        case .unsupportedSampleFormat(let detail):
            return "The dataset holds \(detail), which cannot be read as intensities."
        case .readFailed(let detail):
            return "The dataset could not be read: \(detail)."
        }
    }
}

struct EMDDataset {
    /// Probe positions.
    var scanWidth: Int
    var scanHeight: Int
    /// Detector pixels.
    var patternWidth: Int
    var patternHeight: Int

    var calibrations: Calibrations?
    var datasetPath: String
    /// For the status line and logs.
    var summary: String

    var totalPatterns: Int { return scanWidth * scanHeight }
    var patternPixels: Int { return patternWidth * patternHeight }
}

enum EMDReader {

    // MARK: - Inspection

    /// Finds the 4D stack and its calibrations. The returned `File` stays open
    /// so the caller can hand it straight to `read`.
    static func inspect(url: URL) throws -> (dataset: EMDDataset, file: HDF5File) {
        guard let file = HDF5File.open(url.path, mode: .readOnly) else {
            throw EMDError.notReadable(url.lastPathComponent)
        }

        let paths = datasetPaths(in: file)
        guard !paths.isEmpty else {
            throw EMDError.noFourDimensionalDataset("It contains no datasets at all.")
        }

        // Prefer the largest 4D dataset. emdfile files carry small 4D odds and
        // ends alongside the stack, and the stack is always the big one. Going
        // by shape rather than by name covers emdfile, Berkeley EMD and
        // anything else that stores the stack as one 4D array.
        var best: (path: String, extent: [Int])?
        var others: [(String, [Int])] = []

        for path in paths {
            guard let dataset = file.openDataset(path) else { continue }
            let extent = dataset.extent
            guard extent.count == 4, extent.allSatisfy({ $0 > 0 }) else {
                others.append((path, extent))
                continue
            }
            let count = extent.reduce(1, *)
            if best == nil || count > best!.extent.reduce(1, *) {
                best = (path, extent)
            }
        }

        guard let target = best else {
            let listed = others
                .sorted { $0.1.reduce(1, *) > $1.1.reduce(1, *) }
                .prefix(4)
                .map { "\($0.0) \($0.1.map(String.init).joined(separator: "×"))" }
                .joined(separator: ", ")
            throw EMDError.noFourDimensionalDataset("It contains \(listed).")
        }

        guard let dataset = file.openDataset(target.path) else {
            throw EMDError.notReadable(url.lastPathComponent)
        }
        guard let nativeType = readableType(of: dataset) else {
            throw EMDError.unsupportedSampleFormat(describe(dataset.type))
        }

        // emdfile stores [Rx, Ry, Qx, Qy]: scan axes first, then detector axes.
        // That is already the layout the app wants — one whole pattern per
        // probe position, contiguous — so nothing needs transposing.
        let extent = target.extent
        let calibrations = readCalibrations(file: file, datasetPath: target.path)

        var summary = "\(extent[1]) × \(extent[0]) scan of \(extent[3]) × \(extent[2]) patterns"
        summary += ", \(describe(dataset.type))"
        if let chunk = dataset.chunkSize {
            summary += ", chunked \(chunk.map(String.init).joined(separator: "×"))"
        }
        // Say what was and was not calibrated: a missing diffraction step is
        // usually a reciprocal-space axis with no beam voltage to convert it.
        switch (calibrations?.scan_step, calibrations?.diff_step) {
        case let (scan?, diff?):
            summary += String(format: ", %.4g nm/px scan, %.4g mrad/px", scan, diff)
        case let (scan?, nil):
            summary += String(format: ", %.4g nm/px scan, diffraction uncalibrated", scan)
        case let (nil, diff?):
            summary += String(format: ", scan uncalibrated, %.4g mrad/px", diff)
        case (nil, nil):
            summary += ", uncalibrated"
        }
        _ = nativeType

        let described = EMDDataset(
            scanWidth: extent[1], scanHeight: extent[0],
            patternWidth: extent[3], patternHeight: extent[2],
            calibrations: calibrations,
            datasetPath: target.path,
            summary: summary
        )
        return (described, file)
    }

    // MARK: - Reading

    /// Streams the stack into `destination` as Float32, a block of scan rows at
    /// a time. libhdf5 converts whatever the file holds — uint8, uint16, int16,
    /// float64 — into Float on the way in, so there is one path for every
    /// variant and no staging buffer.
    ///
    /// `progress` receives 0...1 and returns false to cancel.
    static func read(_ dataset: EMDDataset, from file: HDF5File,
                     into destination: UnsafeMutablePointer<Float>,
                     progress: (Double) -> Bool) throws {

        guard let handle = file.openDataset(dataset.datasetPath) else {
            throw EMDError.readFailed("the dataset disappeared between opening and reading")
        }

        let patternPixels = dataset.patternPixels
        let rowElements = dataset.scanWidth * patternPixels

        // Enough rows to make each read worth its overhead without holding much.
        let bytesPerRow = rowElements * MemoryLayout<Float>.size
        let rowsPerBlock = max(1, min(dataset.scanHeight, 32 * 1024 * 1024 / max(1, bytesPerRow)))

        var row = 0
        while row < dataset.scanHeight {
            if !progress(Double(row) / Double(dataset.scanHeight)) { return }

            let rows = min(rowsPerBlock, dataset.scanHeight - row)

            let fileSpace = handle.space
            fileSpace.select(start: [row, 0, 0, 0],
                             stride: nil,
                             count: [rows, dataset.scanWidth, dataset.patternHeight, dataset.patternWidth],
                             block: nil)

            let memorySpace = HDF5Dataspace(dims: [rows, dataset.scanWidth,
                                               dataset.patternHeight, dataset.patternWidth])
            memorySpace.selectAll()

            do {
                try handle.read(into: UnsafeMutableRawPointer(destination + row * rowElements),
                                type: .float,
                                memSpace: memorySpace,
                                fileSpace: fileSpace)
            } catch {
                throw EMDError.readFailed("HDF5 rejected the read at scan row \(row) (\(error))")
            }
            row += rows
        }
        _ = progress(1.0)
    }

    // MARK: - Datatype

    /// Whether the samples are numbers libhdf5 can hand back as Float.
    private static func readableType(of dataset: HDF5Dataset) -> HDF5NativeType? {
        // Bound to a local, not used inline: `dataset.type` hands back a fresh
        // object whose deinit closes the handle, so `dataset.type.id` would be
        // read after the type had already been released.
        let type = dataset.type
        switch H5Tget_class(type.id) {
        case H5T_INTEGER, H5T_FLOAT:
            return .float
        default:
            return nil
        }
    }

    private static func describe(_ type: HDF5Datatype) -> String {
        let identifier = type.id
        let size = H5Tget_size(identifier) * 8
        switch H5Tget_class(identifier) {
        case H5T_FLOAT:   return "float\(size)"
        case H5T_INTEGER: return H5Tget_sign(identifier) == H5T_SGN_2 ? "int\(size)" : "uint\(size)"
        case H5T_STRING:  return "text"
        case H5T_COMPOUND: return "compound records"
        default:          return "an unsupported sample type"
        }
    }

    // MARK: - Group listing

    /// Every dataset path in the file, depth first.
    ///
    /// `H5Lget_name_by_idx` and `H5Oget_info_by_name` rather than HDF5Kit's
    /// `objectNames()`, which uses APIs deprecated since HDF5 1.8.
    private static func datasetPaths(in file: HDF5File) -> [String] {
        var found: [String] = []
        walk(parent: file.id, prefix: "", depth: 0, into: &found)
        return found
    }

    private static func walk(parent: hid_t, prefix: String, depth: Int, into found: inout [String]) {
        guard depth < 32 else { return }        // hard links can form cycles

        var info = H5G_info_t()
        guard H5Gget_info(parent, &info) >= 0 else { return }

        let defaultPropertyList = hid_t(H5P_DEFAULT)

        for index in 0..<info.nlinks {
            let length = H5Lget_name_by_idx(parent, ".", H5_INDEX_NAME, H5_ITER_INC,
                                            hsize_t(index), nil, 0, defaultPropertyList)
            guard length > 0 else { continue }

            var buffer = [CChar](repeating: 0, count: length + 1)
            H5Lget_name_by_idx(parent, ".", H5_INDEX_NAME, H5_ITER_INC,
                               hsize_t(index), &buffer, length + 1, defaultPropertyList)
            let name = String(cString: buffer)
            let path = prefix + "/" + name

            // Names are resolved relative to `parent`, so pass the link name
            // rather than the accumulated path.
            var objectInfo = H5O_info2_t()
            guard name.withCString({ H5Oget_info_by_name3(parent, $0, &objectInfo,
                                                          UInt32(H5O_INFO_BASIC), defaultPropertyList) }) >= 0
            else { continue }

            switch objectInfo.type {
            case H5O_TYPE_GROUP:
                let child = name.withCString { H5Gopen2(parent, $0, defaultPropertyList) }
                if child >= 0 {
                    walk(parent: child, prefix: path, depth: depth + 1, into: &found)
                    H5Gclose(child)
                }
            case H5O_TYPE_DATASET:
                found.append(path)
            default:
                break
            }
        }
    }

    // MARK: - Calibration

    /// Reads the dimension scales beside the data.
    ///
    /// emdfile writes `dim0`…`dim3` next to `data`, each a two-element array
    /// `[origin, origin + step]` with a `units` attribute. dim0/dim1 are the
    /// scan axes, dim2/dim3 the detector axes.
    private static func readCalibrations(file: HDF5File, datasetPath: String) -> Calibrations? {
        let parent = String(datasetPath[datasetPath.startIndex..<(datasetPath.range(of: "/", options: .backwards)?.lowerBound ?? datasetPath.endIndex)])

        func step(_ name: String) -> (value: Double, units: String)? {
            guard let scale = file.openDoubleDataset(parent + "/" + name),
                  let values = try? scale.read(), values.count >= 2 else { return nil }
            let delta = abs(values[1] - values[0])
            guard delta > 0, delta.isFinite else { return nil }
            return (delta, stringAttribute("units", on: scale.id) ?? "")
        }

        let volts = accelerationVoltage(file: file)
        let wavelength = volts.flatMap { electronWavelength(volts: $0) }

        var scanStep: Float?
        var diffStep: Float?
        if let scan = step("dim0") ?? step("dim1") {
            scanStep = nanometres(scan.value, units: scan.units)
        }
        if let diff = step("dim2") ?? step("dim3") {
            // Reciprocal-space steps only become angles once the electron
            // wavelength is known, so the accelerating voltage is looked up
            // rather than assumed.
            diffStep = milliradians(diff.value, units: diff.units, wavelengthAngstroms: wavelength)
        }

        // py4DSTEM often leaves the dimension scales as bare pixel indices and
        // keeps the real numbers in its Calibration metadata instead, so a file
        // whose dims say "pixels" is not uncalibrated — it is calibrated
        // somewhere else.
        if scanStep == nil, let size = scalar(file: file, named: "R_pixel_size") {
            scanStep = nanometres(size, units: text(file: file, named: "R_pixel_units") ?? "")
        }
        if diffStep == nil, let size = scalar(file: file, named: "Q_pixel_size") {
            diffStep = milliradians(size, units: text(file: file, named: "Q_pixel_units") ?? "",
                                    wavelengthAngstroms: wavelength)
        }

        let kilovolts = volts.map { Float($0 / 1000.0) }
        if scanStep == nil && diffStep == nil && kilovolts == nil { return nil }
        // An EMD carries its patterns in the orientation it means them to be
        // read; the RAW flip flags are not applied to it, so no flips is the
        // honest record rather than the application's RAW default.
        return Calibrations(scan_step: scanStep, diff_step: diffStep, voltage: kilovolts,
                            detectorFlips: .unflipped)
    }

    /// Reads a string attribute off any object.
    ///
    /// HDF5Kit only offers attribute helpers on `GroupType`, and `units` hangs
    /// off the dimension-scale *dataset*, so this goes to the C API. Both
    /// storage forms appear in the wild: emdfile writes variable-length
    /// strings, some writers use fixed-length.
    private static func stringAttribute(_ name: String, on objectID: hid_t) -> String? {
        let attribute = name.withCString { H5Aopen(objectID, $0, hid_t(H5P_DEFAULT)) }
        guard attribute >= 0 else { return nil }
        defer { H5Aclose(attribute) }

        let type = H5Aget_type(attribute)
        guard type >= 0 else { return nil }
        defer { H5Tclose(type) }

        if H5Tis_variable_str(type) > 0 {
            var cString: UnsafeMutablePointer<CChar>?
            let read = withUnsafeMutablePointer(to: &cString) { pointer -> herr_t in
                return H5Aread(attribute, type, UnsafeMutableRawPointer(pointer))
            }
            guard read >= 0, let cString = cString else { return nil }
            let value = String(cString: cString)
            // HDF5 allocated the buffer, so HDF5 has to release it.
            let space = H5Aget_space(attribute)
            if space >= 0 {
                var copy: UnsafeMutablePointer<CChar>? = cString
                withUnsafeMutablePointer(to: &copy) { pointer in
                    _ = H5Treclaim(type, space, hid_t(H5P_DEFAULT), UnsafeMutableRawPointer(pointer))
                }
                H5Sclose(space)
            }
            return value
        }

        let size = H5Tget_size(type)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard H5Aread(attribute, type, &buffer) >= 0 else { return nil }
        return String(cString: buffer)
    }

    /// First scalar dataset in the file whose name matches, wherever it sits.
    /// Names are looked up rather than paths because writers disagree on where
    /// the calibration group lives.
    private static func scalar(file: HDF5File, named name: String) -> Double? {
        for path in datasetPaths(in: file) where (path as NSString).lastPathComponent == name {
            guard let dataset = file.openDoubleDataset(path),
                  let values = try? dataset.read(),
                  let first = values.first, first.isFinite, first != 0 else { continue }
            return first
        }
        return nil
    }

    /// Same, for a string dataset. Both fixed- and variable-length appear in
    /// the wild, and HDF5Kit only offers attribute helpers on groups, so this
    /// goes to the C API.
    private static func text(file: HDF5File, named name: String) -> String? {
        for path in datasetPaths(in: file) where (path as NSString).lastPathComponent == name {
            let dataset = path.withCString { H5Dopen2(file.id, $0, hid_t(H5P_DEFAULT)) }
            guard dataset >= 0 else { continue }
            defer { H5Dclose(dataset) }
            let type = H5Dget_type(dataset)
            guard type >= 0 else { continue }
            defer { H5Tclose(type) }

            if H5Tis_variable_str(type) > 0 {
                var pointer: UnsafeMutablePointer<CChar>?
                let status = withUnsafeMutablePointer(to: &pointer) {
                    H5Dread(dataset, type, hid_t(H5S_ALL), hid_t(H5S_ALL), hid_t(H5P_DEFAULT),
                            UnsafeMutableRawPointer($0))
                }
                guard status >= 0, let pointer = pointer else { continue }
                let value = String(cString: pointer)
                let space = H5Dget_space(dataset)
                if space >= 0 {
                    var copy: UnsafeMutablePointer<CChar>? = pointer
                    withUnsafeMutablePointer(to: &copy) {
                        _ = H5Treclaim(type, space, hid_t(H5P_DEFAULT), UnsafeMutableRawPointer($0))
                    }
                    H5Sclose(space)
                }
                return value
            }

            let size = H5Tget_size(type)
            guard size > 0 else { continue }
            var buffer = [CChar](repeating: 0, count: size + 1)
            guard H5Dread(dataset, type, hid_t(H5S_ALL), hid_t(H5S_ALL), hid_t(H5P_DEFAULT), &buffer) >= 0
            else { continue }
            return String(cString: buffer)
        }
        return nil
    }

    /// The app's scale bar works in nanometres per scan pixel.
    private static func nanometres(_ value: Double, units: String) -> Float? {
        switch normalise(units) {
        case "a", "angstrom", "angstroms", "å", "":
            // Unlabelled dimension scales are Angstroms in py4DSTEM output;
            // assuming nanometres would be off by ten.
            return Float(value / 10.0)
        case "nm", "nanometer", "nanometre", "nanometers", "nanometres":
            return Float(value)
        case "um", "µm", "micron", "microns":
            return Float(value * 1000.0)
        case "pm", "picometer", "picometre":
            return Float(value / 1000.0)
        case "m":
            return Float(value * 1e9)
        default:
            return nil     // pixels, or unrecognised: leave uncalibrated
        }
    }

    /// The app's detector angles are milliradians per detector pixel.
    ///
    /// Writers disagree on how to express the diffraction axis. py4DSTEM often
    /// writes an angle directly; just as often it writes a reciprocal-space
    /// step, which is only an angle once you know the electron wavelength:
    /// θ = λ·q. Without a voltage in the file that conversion is impossible, so
    /// the calibration is left unset rather than being invented.
    private static func milliradians(_ value: Double, units: String,
                                     wavelengthAngstroms: Double?) -> Float? {
        switch normalise(units) {
        case "mrad", "milliradian", "milliradians":
            return Float(value)
        case "rad", "radian", "radians":
            return Float(value * 1000.0)

        case "a^-1", "a-1", "1/a", "å^-1", "å-1", "1/å", "angstrom^-1", "invang", "inv_angstrom":
            guard let lambda = wavelengthAngstroms else { return nil }
            return Float(lambda * value * 1000.0)

        case "nm^-1", "nm-1", "1/nm", "nanometre^-1", "nanometer^-1", "invnm", "inv_nm":
            guard let lambda = wavelengthAngstroms else { return nil }
            return Float((lambda / 10.0) * value * 1000.0)      // λ in nm

        case "pm^-1", "1/pm":
            guard let lambda = wavelengthAngstroms else { return nil }
            return Float((lambda * 100.0) * value * 1000.0)     // λ in pm

        default:
            return nil      // pixels, or something unrecognised
        }
    }

    /// Relativistic electron wavelength in Angstroms.
    ///
    ///     λ = h / sqrt(2·m₀·e·V·(1 + eV / 2m₀c²))
    ///
    /// written in the usual practical form. At 300 kV this gives 0.0197 Å.
    private static func electronWavelength(volts: Double) -> Double? {
        guard volts > 100, volts.isFinite else { return nil }
        return 12.2639 / (volts + 0.97845e-6 * volts * volts).squareRoot()
    }

    /// Accelerating voltage in volts, wherever the writer put it.
    ///
    /// emdfile keeps it at `metadatabundle/calibration/voltage`, but the name
    /// and the units vary between writers, so this searches by name and then
    /// works out whether the number is volts, kilovolts or electronvolts.
    private static func accelerationVoltage(file: HDF5File) -> Double? {
        let wanted = ["voltage", "accelerating_voltage", "acceleration_voltage",
                      "beam_energy", "energy", "high_tension", "ht"]

        for path in datasetPaths(in: file) {
            let leaf = (path as NSString).lastPathComponent.lowercased()
            guard wanted.contains(leaf) else { continue }
            guard let dataset = file.openDoubleDataset(path),
                  let values = try? dataset.read(),
                  let raw = values.first, raw.isFinite, raw > 0 else { continue }

            // 300000 V, 300 kV and 300000 eV all appear in the wild; they are
            // far enough apart in magnitude to tell apart safely.
            if raw >= 1000 { return raw }          // volts (or eV, same number)
            if raw >= 10 { return raw * 1000.0 }   // kilovolts
            return nil                             // too small to be a beam energy
        }
        return nil
    }

    private static func normalise(_ units: String) -> String {
        return units.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
