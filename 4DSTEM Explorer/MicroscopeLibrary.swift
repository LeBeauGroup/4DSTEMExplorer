//
//  MicroscopeLibrary.swift
//  4DSTEM Explorer
//
//  What the user knows about their instruments, kept so it need not be
//  rediscovered for every dataset.
//
//  This is not the calibration history. `CalibrationLibrary` records what was
//  measured from a particular file; this records the properties of the hardware
//  — which detectors are fitted, what one electron reads as on each, and what
//  angle a detector pixel subtends at each camera length the microscope offers.
//  Those are facts about the instrument, established once and used thereafter.
//
//  The shape separates the hardware from its behaviour. A detector is fitted to
//  a microscope, not to a voltage — it is one piece of equipment whether the gun
//  is run at 200 kV or 300 kV — so detectors are listed once, on the microscope,
//  with the properties that do not change: its name and its pixel pitch.
//
//  What that detector *does* is another matter, and that is where the voltage
//  comes in. The counts it returns per electron scale with the beam energy, and
//  the camera lengths are calibrated per voltage because the projector system is.
//  So each voltage carries one set of readings per detector, referring back to
//  the detector it describes rather than redefining it.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

/// One camera length that somebody has actually calibrated.
struct CameraLengthCalibration: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What the microscope calls it, in millimetres. This is a label as much as
    /// a length — the nominal value and the true one rarely agree, which is the
    /// whole reason this table exists.
    var nominalMillimetres: Double
    /// The measured angle per detector pixel.
    var diffractionStepMilliradians: Double
    var note: String = ""
}

/// How a diffraction step was arrived at, so the caller can say.
enum DiffractionStepSource: Equatable {
    case measured(nominal: Double)
    case interpolated(between: Double, and: Double)
    case scaled(from: Double)

    var describe: String {
        switch self {
        case .measured(let l):
            return String(format: "measured at %.4g mm", l)
        case .interpolated(let a, let b):
            return String(format: "interpolated between %.4g and %.4g mm", a, b)
        case .scaled(let l):
            return String(format: "scaled from the %.4g mm calibration", l)
        }
    }
}

/// A detector fitted to a microscope: the part that does not change with the
/// beam energy.
struct DetectorProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Detector"
    /// Physical pixel pitch. A property of the sensor, so it lives here rather
    /// than being restated at every voltage.
    var pixelPitchMicrometres: Double?
}

/// What one detector does at one accelerating voltage.
struct DetectorCalibration: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The detector these readings describe.
    var detectorID: UUID
    /// Counts per electron, which scales with the beam energy and so belongs to
    /// the voltage rather than to the detector.
    var countsPerElectron: Double?
    /// Calibrated camera lengths at this voltage.
    var cameraLengths: [CameraLengthCalibration] = []

    /// The angle per pixel at a camera length.
    ///
    /// Exact where it has been measured. Between two measured lengths the step
    /// is interpolated against 1/L rather than against L, because that is the
    /// relationship the geometry has — the angle a pixel subtends is its pitch
    /// divided by the distance, so the step falls as the reciprocal of the
    /// length and a straight line through L would sag between the points.
    ///
    /// With a single calibration the same relationship extrapolates it: the
    /// product of step and length is the pitch, and the pitch does not change
    /// when the projector lenses do.
    func diffractionStep(atCameraLength length: Double)
        -> (milliradians: Double, source: DiffractionStepSource)? {

        guard length > 0 else { return nil }
        let points = cameraLengths
            .filter { $0.nominalMillimetres > 0 && $0.diffractionStepMilliradians > 0 }
            .sorted { $0.nominalMillimetres < $1.nominalMillimetres }
        guard !points.isEmpty else { return nil }

        if let exact = points.first(where: {
            abs($0.nominalMillimetres - length) <= 1e-6 * Swift.max(1, length)
        }) {
            return (exact.diffractionStepMilliradians, .measured(nominal: exact.nominalMillimetres))
        }

        if let upper = points.firstIndex(where: { $0.nominalMillimetres > length }), upper > 0 {
            let a = points[upper - 1], b = points[upper]
            let x0 = 1 / a.nominalMillimetres, x1 = 1 / b.nominalMillimetres
            let t = (1 / length - x0) / (x1 - x0)
            let value = a.diffractionStepMilliradians
                + t * (b.diffractionStepMilliradians - a.diffractionStepMilliradians)
            return (value, .interpolated(between: a.nominalMillimetres, and: b.nominalMillimetres))
        }

        // Outside the calibrated range, including the single-point case. The
        // step times the length is a constant, so one point sets it.
        let nearest = points.min {
            abs(log($0.nominalMillimetres / length)) < abs(log($1.nominalMillimetres / length))
        }!
        let value = nearest.diffractionStepMilliradians * nearest.nominalMillimetres / length
        return (value, .scaled(from: nearest.nominalMillimetres))
    }

    var summary: String {
        var parts: [String] = []
        if let adu = countsPerElectron { parts.append(String(format: "%.4g counts/e⁻", adu)) }
        parts.append(cameraLengths.isEmpty
                     ? "no camera lengths"
                     : "\(cameraLengths.count) camera length\(cameraLengths.count == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}

/// One accelerating voltage, and what each detector does at it.
struct VoltageProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var kilovolts: Double = 200
    var calibrations: [DetectorCalibration] = []

    var label: String { return String(format: "%.4g kV", kilovolts) }

    func calibration(for detector: DetectorProfile.ID) -> DetectorCalibration? {
        return calibrations.first { $0.detectorID == detector }
    }
}

/// An instrument, and the detectors fitted to it.
struct MicroscopeProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Microscope"
    /// Fitted once, used at every voltage.
    var detectors: [DetectorProfile] = []
    var voltages: [VoltageProfile] = []

    func voltage(nearest kilovolts: Double) -> VoltageProfile? {
        return voltages.min { abs($0.kilovolts - kilovolts) < abs($1.kilovolts - kilovolts) }
    }

    func detector(named name: String) -> DetectorProfile? {
        let wanted = MicroscopeLibrary.normalise(name)
        return detectors.first { MicroscopeLibrary.normalise($0.name) == wanted }
    }
}

// MARK: - The library

final class MicroscopeLibrary: ObservableObject {

    static let shared = MicroscopeLibrary()

    static let defaultsKey = "MicroscopeLibrary"

    @Published var microscopes: [MicroscopeProfile] = [] {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private var loading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        guard let data = defaults.data(forKey: MicroscopeLibrary.defaultsKey) else { return }
        // A library that will not decode is left where it is rather than
        // replaced with an empty one. Someone's accumulated knowledge of their
        // instruments is not worth losing to a field a newer build added.
        guard let decoded = try? JSONDecoder().decode([MicroscopeProfile].self, from: data) else {
            NSLog("[Microscopes] the stored library could not be read; leaving it untouched")
            return
        }
        loading = true
        microscopes = decoded
        loading = false
    }

    private func persist() {
        guard !loading, let data = try? JSONEncoder().encode(microscopes) else { return }
        defaults.set(data, forKey: MicroscopeLibrary.defaultsKey)
    }

    // MARK: Lookup

    /// The angle per pixel this instrument gives, for whoever is calibrating.
    ///
    /// Everything is matched by name, case and spacing ignored, because the
    /// name in a file's metadata and the name someone typed into the library
    /// will not otherwise agree.
    func diffractionStep(microscope: String, kilovolts: Double, detector: String,
                         cameraLengthMillimetres: Double)
        -> (milliradians: Double, source: DiffractionStepSource)? {

        guard let scope = self.microscope(named: microscope),
              let fitted = scope.detector(named: detector),
              let voltage = scope.voltage(nearest: kilovolts),
              abs(voltage.kilovolts - kilovolts) <= 1,
              let readings = voltage.calibration(for: fitted.id)
        else { return nil }
        return readings.diffractionStep(atCameraLength: cameraLengthMillimetres)
    }

    /// Counts per electron for a detector at a voltage.
    func countsPerElectron(microscope: String, kilovolts: Double,
                           detector: String) -> Double? {
        guard let scope = self.microscope(named: microscope),
              let fitted = scope.detector(named: detector),
              let voltage = scope.voltage(nearest: kilovolts),
              abs(voltage.kilovolts - kilovolts) <= 1
        else { return nil }
        return voltage.calibration(for: fitted.id)?.countsPerElectron
    }

    func microscope(named name: String) -> MicroscopeProfile? {
        let wanted = MicroscopeLibrary.normalise(name)
        guard !wanted.isEmpty else { return nil }
        return microscopes.first { MicroscopeLibrary.normalise($0.name) == wanted }
    }

    /// The readings for a detector at a voltage, created empty if this pair has
    /// not been described yet.
    ///
    /// Made on demand rather than when a detector is added: a scope with four
    /// detectors and three voltages would otherwise start with twelve empty
    /// rows, eleven of which nobody intends to fill in.
    func ensureCalibration(microscope: Int, voltage: Int,
                           detector: DetectorProfile.ID) -> Int {
        if let existing = microscopes[microscope].voltages[voltage]
            .calibrations.firstIndex(where: { $0.detectorID == detector }) {
            return existing
        }
        microscopes[microscope].voltages[voltage].calibrations
            .append(DetectorCalibration(detectorID: detector))
        return microscopes[microscope].voltages[voltage].calibrations.count - 1
    }

    /// Drops every reading referring to a detector that no longer exists.
    func forgetCalibrations(microscope: Int, detector: DetectorProfile.ID) {
        for v in microscopes[microscope].voltages.indices {
            microscopes[microscope].voltages[v].calibrations.removeAll { $0.detectorID == detector }
        }
    }

    static func normalise(_ text: String) -> String {
        return text.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }
}
