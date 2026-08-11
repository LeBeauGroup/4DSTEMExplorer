//
//  CalibrationLibrary.swift
//  4DSTEM Explorer
//
//  Calibrations kept between sessions, so a measurement made once does not have
//  to be made again on the next dataset from the same instrument.
//
//  Filed under microscope → accelerating voltage → mode, because that is what
//  the transferable parts of a calibration actually depend on. The angle between
//  the scan and detector axes, the shape of the raster, and the orientation of
//  the patterns are properties of the instrument in a given configuration: they
//  are the same tomorrow as today, and the same for every dataset taken that
//  way. Measuring them again on each file is work the instrument has already
//  answered.
//
//  The scan step is the exception, and it is treated as one throughout. It is
//  nanometres per probe position, which depends on the magnification — a setting
//  that changes between datasets taken minutes apart in the same configuration.
//  It is stored, because it is worth recording what a given magnification gave,
//  but it is never applied by default, and the reason is said plainly wherever
//  the choice is offered. A step size carried silently onto a dataset at another
//  magnification would be wrong by exactly the ratio of the two, and nothing
//  downstream could tell.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

// MARK: - Instrument identity

/// What a calibration is filed under.
///
/// The mode is deliberately free text. Which knobs matter differs by instrument
/// — camera length for one, projector setting or a named preset for another —
/// and a fixed set of fields would fit whichever microscope it was designed
/// against and no other. What matters is that the same words are used for the
/// same configuration, which the file supplies when it knows and the user
/// supplies when it does not.
struct InstrumentIdentity: Equatable, Codable {
    var microscope: String
    var kilovolts: Double
    var mode: String

    var isEmpty: Bool {
        return microscope.trimmingCharacters(in: .whitespaces).isEmpty && kilovolts <= 0
    }

    /// Case- and spacing-insensitive, so "Titan " and "titan" are one microscope.
    static func normalise(_ text: String) -> String {
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether two identities describe the same configuration.
    ///
    /// The voltage is compared with a tolerance rather than for equality: it
    /// arrives as volts divided by a thousand from one file and as a typed
    /// integer from another, and 299.99 and 300 are not two accelerating
    /// voltages.
    func matches(_ other: InstrumentIdentity) -> Bool {
        return InstrumentIdentity.normalise(microscope) == InstrumentIdentity.normalise(other.microscope)
            && abs(kilovolts - other.kilovolts) < 0.5
            && InstrumentIdentity.normalise(mode) == InstrumentIdentity.normalise(other.mode)
    }

    /// Same instrument and voltage, but not necessarily the same mode.
    func matchesInstrument(_ other: InstrumentIdentity) -> Bool {
        return InstrumentIdentity.normalise(microscope) == InstrumentIdentity.normalise(other.microscope)
            && abs(kilovolts - other.kilovolts) < 0.5
    }

    var display: String {
        var parts: [String] = []
        if !microscope.isEmpty { parts.append(microscope) }
        if kilovolts > 0 { parts.append(String(format: "%.0f kV", kilovolts)) }
        if !mode.isEmpty { parts.append(mode) }
        return parts.isEmpty ? "unnamed" : parts.joined(separator: " · ")
    }
}

// MARK: - A stored calibration

struct SavedCalibration: Codable, Identifiable, Equatable {

    var id: UUID = UUID()
    var identity: InstrumentIdentity

    /// Nanometres per probe position. Magnification-dependent — see the note at
    /// the top of this file.
    var scanStepNanometres: Double?
    /// Milliradians per detector pixel.
    var diffractionStepMilliradians: Double?
    var scanRotationDegrees: Double?
    /// Row-major, unit determinant.
    var scanCorrectionRowMajor: [Double]?
    /// `[flip_y, flip_x, transpose]`.
    var detectorFlips: [Bool]?

    /// Free text, and the magnification when it was known: a stored step size is
    /// only interpretable alongside the magnification it was measured at.
    var note: String = ""
    var magnification: Double?

    var savedAt: Date = Date()
    var sourceFile: String = ""

    /// Which fields this entry actually carries.
    var availableFields: [CalibrationField] {
        var fields: [CalibrationField] = []
        if scanStepNanometres != nil { fields.append(.scanStep) }
        if diffractionStepMilliradians != nil { fields.append(.diffractionStep) }
        if scanRotationDegrees != nil { fields.append(.scanRotation) }
        if scanCorrectionRowMajor != nil { fields.append(.scanCorrection) }
        if detectorFlips != nil { fields.append(.detectorFlips) }
        return fields
    }

    var isEmpty: Bool { return availableFields.isEmpty }

    var summary: String {
        var parts: [String] = []
        if let v = scanStepNanometres { parts.append(String(format: "%.5g nm/px", v)) }
        if let v = diffractionStepMilliradians { parts.append(String(format: "%.5g mrad/px", v)) }
        if let v = scanRotationDegrees { parts.append(String(format: "%+.3f°", v)) }
        if scanCorrectionRowMajor != nil { parts.append("correction") }
        if detectorFlips != nil { parts.append("orientation") }
        return parts.isEmpty ? "nothing stored" : parts.joined(separator: " · ")
    }
}

/// One value a stored calibration can carry.
enum CalibrationField: String, CaseIterable, Identifiable, Codable {
    case scanStep
    case diffractionStep
    case scanRotation
    case scanCorrection
    case detectorFlips

    var id: String { return rawValue }

    var label: String {
        switch self {
        case .scanStep:        return "Step size"
        case .diffractionStep: return "Diffraction step"
        case .scanRotation:    return "Scan rotation"
        case .scanCorrection:  return "Scan correction"
        case .detectorFlips:   return "Detector orientation"
        }
    }

    /// Whether this survives a change of magnification.
    ///
    /// Everything here is a property of the instrument in a configuration except
    /// the step size, which is a property of the magnification as well. That
    /// difference is the whole reason applying is per-field rather than
    /// wholesale.
    var isInstrumentProperty: Bool {
        return self != .scanStep
    }

    var caveat: String? {
        switch self {
        case .scanStep:
            return "depends on magnification, not just the instrument"
        default:
            return nil
        }
    }
}

// MARK: - The library

final class CalibrationLibrary: ObservableObject {

    static let shared = CalibrationLibrary()

    /// Where the library lives in the preferences.
    static let defaultsKey = "CalibrationLibrary"

    @Published private(set) var entries: [SavedCalibration] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = defaults.data(forKey: CalibrationLibrary.defaultsKey) else { return }
        // A library that fails to decode is left alone rather than replaced with
        // an empty one: losing every saved calibration because a newer build
        // wrote a field this one does not know is not an acceptable trade.
        guard let decoded = try? JSONDecoder().decode([SavedCalibration].self, from: data) else {
            NSLog("[Calibration] the stored library could not be read; leaving it untouched")
            return
        }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: CalibrationLibrary.defaultsKey)
    }

    // MARK: Editing

    /// Adds an entry, replacing any existing one for the same configuration.
    ///
    /// Replacing rather than accumulating: two calibrations for one microscope
    /// at one voltage in one mode are two answers to a question with one answer,
    /// and keeping both leaves the user to guess which is current.
    @discardableResult
    func save(_ entry: SavedCalibration) -> SavedCalibration {
        var stored = entry
        stored.savedAt = Date()
        if let index = entries.firstIndex(where: { $0.identity.matches(entry.identity) }) {
            stored.id = entries[index].id
            entries[index] = stored
        } else {
            entries.append(stored)
        }
        sort()
        persist()
        return stored
    }

    func remove(_ entry: SavedCalibration) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func removeAll() {
        entries.removeAll()
        persist()
    }

    private func sort() {
        entries.sort {
            let a = $0.identity, b = $1.identity
            if InstrumentIdentity.normalise(a.microscope) != InstrumentIdentity.normalise(b.microscope) {
                return InstrumentIdentity.normalise(a.microscope) < InstrumentIdentity.normalise(b.microscope)
            }
            if a.kilovolts != b.kilovolts { return a.kilovolts < b.kilovolts }
            return InstrumentIdentity.normalise(a.mode) < InstrumentIdentity.normalise(b.mode)
        }
    }

    // MARK: Lookup

    /// The entry for exactly this configuration, if there is one.
    func exactMatch(for identity: InstrumentIdentity) -> SavedCalibration? {
        return entries.first { $0.identity.matches(identity) }
    }

    /// Entries from the same microscope at the same voltage, in any mode.
    ///
    /// Offered separately from the exact match because a different mode is a
    /// different camera length or projector setting: its diffraction step does
    /// not carry over, even though its scan correction very likely does.
    func otherModes(for identity: InstrumentIdentity) -> [SavedCalibration] {
        return entries.filter {
            $0.identity.matchesInstrument(identity) && !$0.identity.matches(identity)
        }
    }

    /// Grouped for display: microscope, then voltage, then the entries.
    func grouped() -> [(microscope: String, voltages: [(kilovolts: Double, entries: [SavedCalibration])])] {
        var byMicroscope: [String: [SavedCalibration]] = [:]
        for entry in entries {
            byMicroscope[entry.identity.microscope, default: []].append(entry)
        }
        return byMicroscope.keys.sorted { $0.lowercased() < $1.lowercased() }.map { microscope in
            let group = byMicroscope[microscope] ?? []
            var byVoltage: [Double: [SavedCalibration]] = [:]
            for entry in group { byVoltage[entry.identity.kilovolts, default: []].append(entry) }
            let voltages = byVoltage.keys.sorted().map { kv in
                (kilovolts: kv,
                 entries: (byVoltage[kv] ?? []).sorted { $0.identity.mode.lowercased() < $1.identity.mode.lowercased() })
            }
            return (microscope: microscope, voltages: voltages)
        }
    }
}

// MARK: - Bridging to the application's calibration

extension SavedCalibration {

    /// Builds an entry from what the application currently believes.
    init(identity: InstrumentIdentity, calibrations: Calibrations?,
         magnification: Double? = nil, sourceFile: String = "", note: String = "") {
        self.init(identity: identity)
        scanStepNanometres = calibrations?.scan_step.map { Double($0) }
        diffractionStepMilliradians = calibrations?.diff_step.map { Double($0) }
        scanRotationDegrees = calibrations?.scanRotationDegrees.map { Double($0) }
        scanCorrectionRowMajor = calibrations?.scanCorrection.map { c in
            [Double(c.m00), Double(c.m01), Double(c.m10), Double(c.m11)]
        }
        detectorFlips = calibrations?.detectorFlips?.triple
        self.magnification = magnification
        self.sourceFile = sourceFile
        self.note = note
    }

    /// This entry's chosen fields written over an existing calibration.
    ///
    /// Fields not chosen are left exactly as they were — loading a stored
    /// diffraction step must not quietly clear a step size that was measured on
    /// this dataset.
    func applied(to current: Calibrations?, fields: Set<CalibrationField>) -> Calibrations {
        let correction: ScanCorrection?
        if fields.contains(.scanCorrection), let rows = scanCorrectionRowMajor {
            correction = ScanCorrection(rowMajor: rows.map { Float($0) }) ?? current?.scanCorrection
        } else {
            correction = current?.scanCorrection
        }

        let flips: DetectorFlips?
        if fields.contains(.detectorFlips), let triple = detectorFlips {
            flips = DetectorFlips(triple: triple) ?? current?.detectorFlips
        } else {
            flips = current?.detectorFlips
        }

        return Calibrations(
            scan_step: fields.contains(.scanStep)
                ? (scanStepNanometres.map { Float($0) } ?? current?.scan_step)
                : current?.scan_step,
            diff_step: fields.contains(.diffractionStep)
                ? (diffractionStepMilliradians.map { Float($0) } ?? current?.diff_step)
                : current?.diff_step,
            voltage: current?.voltage ?? (identity.kilovolts > 0 ? Float(identity.kilovolts) : nil),
            scanRotationDegrees: fields.contains(.scanRotation)
                ? (scanRotationDegrees.map { Float($0) } ?? current?.scanRotationDegrees)
                : current?.scanRotationDegrees,
            scanCorrection: correction,
            detectorFlips: flips)
    }

    /// The fields to tick by default when this entry is loaded.
    ///
    /// Everything the instrument determines, and not the step size.
    var defaultFieldsToApply: Set<CalibrationField> {
        return Set(availableFields.filter { $0.isInstrumentProperty })
    }
}
