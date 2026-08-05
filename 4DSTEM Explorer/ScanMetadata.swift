//
//  ScanMetadata.swift
//  4DSTEM Explorer
//
//  Reads the JSON sidecar that accompanies a RAW scan.
//
//  A RAW file is just pixels: no dimensions, no calibration. Acquisition
//  software usually writes the rest alongside it, and typing those numbers back
//  in by hand is both tedious and a good way to introduce an error. This reads
//  the EMPAD-style metadata written by py4DSTEM's EMPAD tooling, and is
//  tolerant enough to be useful with near relatives of it.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

struct ScanMetadata {

    var scanWidth: Int?
    var scanHeight: Int?
    /// Nanometres per probe position.
    var scanStepNanometres: Float?
    /// Milliradians per detector pixel.
    var diffractionStepMilliradians: Float?
    /// Accelerating voltage in kilovolts.
    var voltageKilovolts: Float?
    /// Convergence semi-angle in milliradians, when recorded.
    var convergenceMilliradians: Float?
    /// The RAW file this metadata was written for, if it says.
    var rawFilename: String?

    /// One line describing what was found, for the panel.
    var summary: String {
        var parts: [String] = []
        if let w = scanWidth, let h = scanHeight { parts.append("\(w)×\(h) scan") }
        if let step = scanStepNanometres { parts.append(String(format: "%.4g nm/px", step)) }
        if let step = diffractionStepMilliradians { parts.append(String(format: "%.4g mrad/px", step)) }
        if let volts = voltageKilovolts { parts.append(String(format: "%.0f kV", volts)) }
        if let angle = convergenceMilliradians { parts.append(String(format: "%.1f mrad conv.", angle)) }
        return parts.isEmpty ? "No usable fields found." : parts.joined(separator: ", ")
    }

    var isEmpty: Bool {
        return scanWidth == nil && scanStepNanometres == nil
            && diffractionStepMilliradians == nil && voltageKilovolts == nil
    }

    // MARK: - Reading

    enum ReadError: LocalizedError {
        case unreadable(String)
        case notJSON(String)
        case nothingUseful(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):   return "\(name) could not be read."
            case .notJSON(let name):      return "\(name) is not a JSON file."
            case .nothingUseful(let name):
                return "\(name) has no scan size or calibration in it. Expected fields such as scan_shape, scan_step, diff_step and voltage."
            }
        }
    }

    static func read(url: URL) throws -> ScanMetadata {
        let name = url.lastPathComponent
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable(name) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ReadError.notJSON(name)
        }

        var metadata = ScanMetadata()
        metadata.rawFilename = root["raw_filename"] as? String

        // Scan size. `scan_shape` is [x, y]; some writers use separate keys.
        if let shape = numbers(root["scan_shape"]), shape.count >= 2 {
            metadata.scanWidth = Int(shape[0])
            metadata.scanHeight = Int(shape[1])
        } else if let w = number(root["scan_x"]), let h = number(root["scan_y"]) {
            metadata.scanWidth = Int(w)
            metadata.scanHeight = Int(h)
        }

        // Scan step. EMPAD metadata is SI, so this arrives in metres; the
        // magnitude tells the two apart unambiguously, since a step of 5e-11 nm
        // or 0.05 m is not a thing anyone means.
        if let step = numbers(root["scan_step"])?.first ?? number(root["scan_step"]) {
            metadata.scanStepNanometres = lengthInNanometres(step)
        }
        if metadata.scanStepNanometres == nil,
           let fov = numbers(root["scan_fov"])?.first, let width = metadata.scanWidth, width > 0 {
            // Fall back to the field of view divided by the number of positions.
            metadata.scanStepNanometres = lengthInNanometres(fov / Double(width))
        }

        // Diffraction step. Already an angle in this format; radians would be
        // three orders smaller than any sane per-pixel milliradian value.
        if let step = number(root["diff_step"]) ?? number(root["diffraction_step"]) {
            metadata.diffractionStepMilliradians = step < 1e-3 ? Float(step * 1000) : Float(step)
        }

        if let volts = number(root["voltage"]) ?? number(root["accelerating_voltage"])
            ?? number(root["beam_energy"]) {
            metadata.voltageKilovolts = kilovolts(volts)
        }

        if let angle = number(root["conv_angle"]) ?? number(root["convergence_angle"])
            ?? number(root["semiangle"]) {
            metadata.convergenceMilliradians = angle < 1e-3 ? Float(angle * 1000) : Float(angle)
        }

        guard !metadata.isEmpty else { throw ReadError.nothingUseful(name) }
        return metadata
    }

    // MARK: - Coercion

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func numbers(_ value: Any?) -> [Double]? {
        guard let array = value as? [Any] else { return nil }
        let converted = array.compactMap { number($0) }
        return converted.isEmpty ? nil : converted
    }

    /// A length written in metres, nanometres or ångström, in nanometres.
    /// The scale is inferred from the magnitude because the JSON does not say.
    private static func lengthInNanometres(_ value: Double) -> Float? {
        guard value > 0, value.isFinite else { return nil }
        if value < 1e-7 { return Float(value * 1e9) }      // metres
        if value < 1e-4 { return Float(value * 1e6) }      // millimetres
        if value > 100 { return Float(value / 10.0) }      // ångström
        return Float(value)                                // already nanometres
    }

    private static func kilovolts(_ value: Double) -> Float? {
        guard value > 0, value.isFinite else { return nil }
        return value >= 1000 ? Float(value / 1000) : Float(value)
    }
}
