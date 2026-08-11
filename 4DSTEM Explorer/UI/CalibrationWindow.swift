//
//  CalibrationWindow.swift
//  4DSTEM Explorer
//
//  The one place a calibration is entered, measured, or read.
//
//  Calibration is not a side activity: it decides what every distance in the
//  application means, and every number written to a metadata file. It used to be
//  split between a small panel that could type three of the values and a plugin
//  that could measure two of them, which meant no single view ever showed what
//  the calibration actually was. This window is the whole of it — current state,
//  manual entry, and both measurements — so that the answer to "what is this
//  dataset calibrated as" has one place to be looked up.
//
//  The measurements themselves are in CalibrationMeasurement.swift and
//  ScanRotationMeasurement.swift, shared with the example plugins so the numbers
//  cannot differ between the two routes.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import SwiftUI
import AppKit

// MARK: - Model

final class CalibrationWindowModel: ObservableObject {

    /// Manual fields, held as text so a half-typed number is not destroyed.
    @Published var scanStep: String = ""
    @Published var diffStep: String = ""
    @Published var voltage: String = ""
    @Published var scanRotation: String = ""

    /// Lattice measurement controls, shared by both lattice measurements: the
    /// known cell is the same cell whichever space it is measured in.
    @Published var d1: String = "3.905"
    @Published var d2: String = "3.905"
    @Published var latticeAngle: String = "90"
    @Published var windowName: String = "Hann"
    @Published var padFactor: Double = 2
    @Published var excludeRadius: Double = 6
    @Published var peakCount: Double = 60
    @Published var peakThreshold: Double = 0.02
    @Published var minimumAngle: Double = 20

    /// How the diffraction step is measured. The disc is the default because
    /// most atomic-resolution datasets have a clean central disc and overlapping
    /// diffracted ones, which is the case the lattice fit finds hardest.
    enum DiffractionMethod: String, CaseIterable, Identifiable {
        case centralDisc = "Central disc"
        case latticePeaks = "Lattice peaks"
        var id: String { rawValue }
    }
    @Published var diffractionMethod: DiffractionMethod = .centralDisc

    /// What is known about the geometry, which decides what the disc radius
    /// means.
    enum DiscReference: String, CaseIterable, Identifiable {
        case convergenceAngle = "Known convergence angle"
        case cameraGeometry = "Known camera length"
        var id: String { rawValue }
    }
    @Published var discReference: DiscReference = .convergenceAngle
    @Published var convergenceMilliradians: String = ""
    @Published var cameraLengthMillimetres: String = ""
    @Published var pixelPitchMicrometres: String = "150"

    /// What the automatic fit found, when it found anything.
    @Published var disc: CentralDiskMeasurement?

    /// The radius the calibration actually uses, in detector pixels.
    ///
    /// Seeded from the fit and then owned by the user. The fit is a good first
    /// guess and no more: it looks for the steepest fall in an azimuthal median,
    /// which is the rim on a clean pattern and something else entirely when the
    /// first-order discs overlap it, when the beam is defocused, or when a
    /// detector gap runs through the edge. On those patterns the person looking
    /// at the picture can see the rim perfectly well and the algorithm cannot,
    /// so the number is theirs to set — with the profile and the drawn circle
    /// both following it, which is what makes setting it by eye a measurement
    /// rather than a guess.
    @Published var discRadius: Double = 0 { didSet { refreshDiscOverlay() } }

    /// Centre of the rim in use — the fit's, or the middle of the pattern when
    /// there is no fit to take one from.
    @Published var discCentre: (x: Double, y: Double) = (0, 0) {
        didSet { refreshDiscOverlay() }
    }

    /// The shorter side of the pattern, which bounds a sensible radius.
    @Published var discFieldSize: Int = 0

    @Published var discImage: NSImage?
    @Published var discError: String?
    @Published var discMagnification: CGFloat = 1
    @Published var discFitRequest: Int = 0
    @Published var discActualSizeRequest: Int = 0
    @Published var discOverlay: [PluginOverlayShape] = []

    /// True when the radius no longer matches what the fit found.
    var discRadiusIsManual: Bool {
        guard let disc = disc else { return discRadius > 0 }
        return abs(disc.radius - discRadius) > 0.05
    }

    /// Scan-rotation controls.
    @Published var rotationDetector: Int = -1     // -1 is the whole pattern
    @Published var smoothing: Double = 0
    @Published var edgeTrim: Double = 0

    /// What one lattice measurement produced.
    ///
    /// Held per mode rather than shared: the step size and the diffraction step
    /// are separate measurements of separate things, and showing the result of
    /// one under the heading of the other is how a number gets written into the
    /// wrong field.
    struct LatticeOutcome {
        var image: NSImage?
        /// The fit, drawn over the image as geometry rather than burnt into it.
        var overlay: [PluginOverlayShape] = []
        var message: String = ""
        var report: String = ""
        var error: String?
        var offer: CalibrationOffer?
        var isMeasuring = false
        /// Zoom state, kept per tab so each keeps its place.
        var magnification: CGFloat = 1
        var fitRequest: Int = 0
        var actualSizeRequest: Int = 0
    }
    @Published var stepSize = LatticeOutcome()
    @Published var diffractionStep = LatticeOutcome()

    /// Which of the two a call refers to.
    enum LatticeMode {
        case stepSize
        case diffractionStep
        var isDiffraction: Bool { return self == .diffractionStep }
    }

    func outcome(_ mode: LatticeMode) -> LatticeOutcome {
        return mode == .stepSize ? stepSize : diffractionStep
    }
    private func setOutcome(_ mode: LatticeMode, _ value: LatticeOutcome) {
        if mode == .stepSize { stepSize = value } else { diffractionStep = value }
    }

    /// Mutates one field of a mode's outcome in place.
    func modify(_ mode: LatticeMode, _ change: (inout LatticeOutcome) -> Void) {
        var state = outcome(mode)
        change(&state)
        setOutcome(mode, state)
    }

    /// Requests zoom-to-fit / 1:1 on a tab's image.
    func bumpFit(_ mode: LatticeMode) { modify(mode) { $0.fitRequest += 1 } }
    func bumpActualSize(_ mode: LatticeMode) { modify(mode) { $0.actualSizeRequest += 1 } }

    @Published var rotationImage: NSImage?
    @Published var rotationReport: String = ""
    @Published var rotationError: String?
    @Published var rotationOffer: (rotationDegrees: Double, flips: [Bool]?, summary: String)?
    @Published var rotationCurve: [Double] = []
    @Published var isMeasuringRotation = false
    @Published var rotationProgress: Double = 0

    /// The correction and orientation, which have no text field: they come from
    /// a measurement or from the file, never from typing.
    @Published private(set) var scanCorrection: ScanCorrection?
    @Published private(set) var detectorFlips: DetectorFlips?

    // MARK: Library

    @Published var library = CalibrationLibrary.shared
    /// The configuration the current calibration will be filed under.
    @Published var saveMicroscope: String = ""
    @Published var saveKilovolts: String = ""
    @Published var saveMode: String = ""
    @Published var saveNote: String = ""
    /// Which fields a selected entry would write.
    @Published var fieldsToApply: Set<CalibrationField> = []
    @Published var selectedEntry: SavedCalibration?
    @Published var libraryMessage: String?

    /// True once anything has been typed or measured. Until then the window is
    /// only displaying the calibration, and reloading it when the file changes
    /// is right; afterwards, reloading would silently discard the user's work.
    @Published private(set) var isEditing = false

    /// Rising counter per mode, so a slow measurement that finishes after a
    /// newer one has started is discarded rather than overwriting it. Dragging a
    /// slider starts several; only the last one's answer is the current one.
    private var latticeGeneration: [LatticeMode: Int] = [:]
    private var latticeWork: [LatticeMode: DispatchWorkItem] = [:]

    private let calibrationEngine = CalibrationEngine()
    private let rotationEngine = ScanRotationEngine()
    private unowned let model: DataViewModel

    init(model: DataViewModel) {
        self.model = model
        load(from: model.calibrations)
        loadIdentity()
    }

    /// Fills the save form from the file, when it says.
    ///
    /// A DM file records the microscope, the voltage and the imaging mode; other
    /// formats record none of it, and the fields are left for the user to type.
    /// Pre-filling matters more than it looks: entries are matched by these
    /// strings, so a name typed slightly differently each time files the same
    /// configuration under several headings.
    func loadIdentity() {
        let identity = model.dataController.instrument
        saveMicroscope = identity?.microscope ?? ""
        saveKilovolts = identity.map { $0.kilovolts > 0 ? String(format: "%.0f", $0.kilovolts) : "" }
            ?? (Double(voltage).map { String(format: "%.0f", $0) } ?? "")
        saveMode = identity?.mode ?? ""
    }

    /// What the save form describes.
    var saveIdentity: InstrumentIdentity {
        return InstrumentIdentity(microscope: saveMicroscope.trimmingCharacters(in: .whitespaces),
                                  kilovolts: Double(saveKilovolts) ?? Double(voltage) ?? 0,
                                  mode: saveMode.trimmingCharacters(in: .whitespaces))
    }

    /// The stored entry for exactly this dataset's configuration, if any.
    var matchForThisDataset: SavedCalibration? {
        let identity = saveIdentity
        guard !identity.isEmpty else { return nil }
        return library.exactMatch(for: identity)
    }

    /// Entries from the same instrument and voltage in other modes.
    var otherModesForThisDataset: [SavedCalibration] {
        let identity = saveIdentity
        guard !identity.isEmpty else { return [] }
        return library.otherModes(for: identity)
    }

    /// Stores what is currently in the window.
    func saveToLibrary() {
        let identity = saveIdentity
        guard !identity.microscope.isEmpty else {
            libraryMessage = "Give the microscope a name — it is what the calibration is filed under."
            return
        }
        guard identity.kilovolts > 0 else {
            libraryMessage = "Set the accelerating voltage before saving."
            return
        }
        let entry = SavedCalibration(identity: identity,
                                     calibrations: pendingCalibration(),
                                     magnification: model.dataController.magnification,
                                     sourceFile: model.selectedURL?.lastPathComponent ?? "",
                                     note: saveNote)
        guard !entry.isEmpty else {
            libraryMessage = "There is nothing to save yet — measure or enter a value first."
            return
        }
        let replacing = library.exactMatch(for: identity) != nil
        library.save(entry)
        libraryMessage = replacing
            ? "Replaced the stored calibration for \(identity.display)."
            : "Saved as \(identity.display)."
    }

    /// Selects an entry and ticks the fields it makes sense to apply.
    func select(_ entry: SavedCalibration) {
        selectedEntry = entry
        fieldsToApply = entry.defaultFieldsToApply
        libraryMessage = nil
    }

    /// Writes the selected entry's ticked fields into the window's fields.
    func applySelectedEntry() {
        guard let entry = selectedEntry else { return }
        let merged = entry.applied(to: pendingCalibration(), fields: fieldsToApply)
        load(from: merged)
        isEditing = true
        let names = fieldsToApply.map { $0.label }.sorted().joined(separator: ", ")
        libraryMessage = names.isEmpty
            ? "Nothing was ticked, so nothing changed."
            : "Loaded \(names). Press Apply to put it into the dataset."
    }

    func delete(_ entry: SavedCalibration) {
        library.remove(entry)
        if selectedEntry?.id == entry.id { selectedEntry = nil }
        libraryMessage = "Deleted \(entry.identity.display)."
    }

    /// The calibration the window currently describes, without applying it.
    func pendingCalibration() -> Calibrations {
        return Calibrations(scan_step: Float(scanStep),
                            diff_step: Float(diffStep),
                            voltage: Float(voltage),
                            scanRotationDegrees: Float(scanRotation),
                            scanCorrection: scanCorrection,
                            detectorFlips: detectorFlips)
    }

    /// True once anything has been typed or measured.

    /// Marks the window as holding unsaved edits.
    func noteEdit() { isEditing = true }

    func load(from calibrations: Calibrations?) {
        func text(_ value: Float?, _ format: String = "%g") -> String {
            guard let value = value else { return "" }
            return String(format: format, value)
        }
        scanStep = text(calibrations?.scan_step)
        diffStep = text(calibrations?.diff_step)
        voltage = text(calibrations?.voltage, "%.0f")
        scanRotation = text(calibrations?.scanRotationDegrees, "%.4g")
        scanCorrection = calibrations?.scanCorrection
        detectorFlips = calibrations?.detectorFlips
        isEditing = false
    }

    // MARK: Current state, for display

    var correctionSummary: String {
        guard let c = scanCorrection else { return "not set" }
        if c.isIdentity { return "square raster (identity)" }
        return String(format: "[%.5f  %.5f ; %.5f  %.5f]", c.m00, c.m01, c.m10, c.m11)
    }

    var flipsSummary: String {
        return detectorFlips?.summary ?? "not set"
    }

    /// The configured detectors, for the centre-of-mass picker.
    var detectorNames: [String] { return model.detectorNames }

    /// The voltage a measurement should use — what is typed now, not what was
    /// saved, so correcting it and re-measuring works without applying first.
    private var kilovolts: Double {
        return Double(voltage) ?? Double(model.calibrations?.voltage ?? 0)
    }

    // MARK: Lattice measurement

    func latticeSettings(_ mode: LatticeMode) -> CalibrationSettings {
        var s = CalibrationSettings()
        s.isDiffraction = mode.isDiffraction
        s.d1 = Double(d1) ?? 0
        s.d2 = Double(d2) ?? 0
        s.latticeAngleDegrees = Double(latticeAngle) ?? 0
        s.windowName = windowName
        s.padFactor = Int(padFactor)
        s.excludeRadius = excludeRadius
        s.peakCount = Int(peakCount)
        s.peakThreshold = peakThreshold
        s.minimumAngle = minimumAngle
        return s
    }

    /// Re-measures shortly after a control stops moving.
    ///
    /// Debounced rather than run on every value: a slider emits a change per
    /// pixel of travel, and starting a transform for each would queue work far
    /// faster than it completes. The delay is short enough that letting go of a
    /// slider feels immediate.
    func scheduleMeasure(_ mode: LatticeMode) {
        latticeWork[mode]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.measureLattice(mode) }
        latticeWork[mode] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func measureLattice(_ mode: LatticeMode) {
        let generation = (latticeGeneration[mode] ?? 0) + 1
        latticeGeneration[mode] = generation

        var state = outcome(mode)
        state.error = nil
        state.offer = nil

        let settings = latticeSettings(mode)
        let source = mode.isDiffraction
            ? model.currentPatternFloats()
            : model.currentScanImageFloats()
        guard let source = source else {
            state.error = CalibrationError.noImage(isDiffraction: mode.isDiffraction).localizedDescription
            setOutcome(mode, state)
            return
        }

        state.isMeasuring = true
        setOutcome(mode, state)
        let identity = model.selectedURL?.lastPathComponent ?? ""
        let kv = kilovolts
        let engine = calibrationEngine

        // Off the main thread: a padded transform on a large image is seconds,
        // and the window must stay responsive enough to cancel.
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<(CalibrationResult, CalibrationOverlay, String, CalibrationOffer?), Error>
            do {
                let result = try engine.measure(image: source.image, rows: source.rows,
                                                columns: source.columns,
                                                identity: identity, settings: settings)
                let overlay = engine.overlay(result, excludeRadius: settings.excludeRadius)
                let report = engine.report(result, fileName: identity, kilovolts: kv)
                outcome = .success((result, overlay, report, engine.offer(result, kilovolts: kv)))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                // A newer measurement has started; this answer is stale.
                guard self.latticeGeneration[mode] == generation else { return }
                var state = self.outcome(mode)
                state.isMeasuring = false
                switch outcome {
                case .failure(let error):
                    state.error = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    state.image = nil
                    state.overlay = []
                    state.report = ""
                    state.offer = nil
                case .success(let (_, overlay, report, offer)):
                    // The picture is the data alone; the fit goes over it as
                    // geometry, so a marker never joins the values it marks.
                    state.image = CalibrationWindowModel.greyscaleImage(overlay.values,
                                                                        width: overlay.columns,
                                                                        height: overlay.rows)
                    state.overlay = PluginOverlayShape.list(overlay.shapes)
                    state.message = overlay.message
                    state.report = report
                    state.offer = offer
                }
                self.setOutcome(mode, state)
            }
        }
    }

    /// Writes the lattice measurement into the manual fields, where it can be
    /// seen and edited before being applied. Nothing reaches the application's
    /// calibration until Apply.
    func adoptLattice(_ mode: LatticeMode) {
        guard let offer = outcome(mode).offer else { return }
        isEditing = true
        if let step = offer.scanStepNanometres { scanStep = String(format: "%g", step) }
        if let step = offer.diffractionStepMilliradians { diffStep = String(format: "%g", step) }
        if let rows = offer.scanCorrectionRowMajor {
            scanCorrection = ScanCorrection(rowMajor: rows.map { Float($0) })
        }
    }

    // MARK: Central disc

    /// The step the disc supports, and the cross-check it implies.
    ///
    /// Reads `discRadius`, which is the radius on screen — the fitted one until
    /// the user moves it. Reading the fit here instead would calibrate from a
    /// circle other than the one the user is looking at.
    var discOutcome: (step: Double, derived: String)? {
        let radius = discRadius
        guard radius > 0 else { return nil }
        let origin = discRadiusIsManual ? "hand-set" : "fitted"
        switch discReference {
        case .convergenceAngle:
            guard let alpha = Double(convergenceMilliradians), alpha > 0,
                  let step = CentralDiskFit.step(convergenceMilliradians: alpha,
                                                 radiusPixels: radius) else { return nil }
            return (step, String(format: "%.5g mrad over a %.2f px %@ radius.",
                                 alpha, radius, origin))
        case .cameraGeometry:
            guard let length = Double(cameraLengthMillimetres), length > 0,
                  let pitch = Double(pixelPitchMicrometres), pitch > 0,
                  let step = CentralDiskFit.step(cameraLengthMillimetres: length,
                                                 pixelPitchMicrometres: pitch) else { return nil }
            // The disc is not used to get the step here, so it checks it instead.
            let alpha = CentralDiskFit.convergenceMilliradians(step: step, radiusPixels: radius)
            return (step, alpha.map {
                String(format: "%.5g µm pixels at %.4g mm. The %.2f px %@ radius then implies a convergence angle of %.3f mrad — check that against the microscope.",
                       pitch, length, radius, origin, $0)
            } ?? "")
        }
    }

    /// Runs the automatic fit and seeds the radius from it.
    ///
    /// A failed fit is not the end of the panel. The pattern is still shown and
    /// the rim still starts somewhere sensible, because a pattern the fit cannot
    /// read is exactly the pattern where the user needs to place the rim
    /// themselves — refusing to draw anything would leave them with a warning
    /// and no way to act on it.
    func measureDisc() {
        discError = nil
        disc = nil
        discImage = nil
        discOverlay = []
        guard let source = model.currentPatternFloats() else {
            discError = CalibrationError.noImage(isDiffraction: true).localizedDescription
            discFieldSize = 0
            discRadius = 0
            return
        }

        // The picture is the data alone; the rim goes over it as geometry, so
        // the circle sits at its true sub-pixel radius and stays sharp when the
        // view is zoomed in on the edge.
        let display = CentralDiskFit.display(image: source.image,
                                             rows: source.rows, columns: source.columns)
        discImage = CalibrationWindowModel.greyscaleImage(display,
                                                          width: source.columns,
                                                          height: source.rows)
        discFieldSize = min(source.rows, source.columns)

        let found = CentralDiskFit.measure(image: source.image,
                                           rows: source.rows, columns: source.columns)
        disc = found
        if let found = found {
            discCentre = found.centre
            discRadius = found.radius
        } else {
            discError = "No central disc could be found automatically. Set the radius by hand against the pattern, or select a probe position where the beam is on the detector."
            discCentre = (x: Double(source.columns - 1) / 2, y: Double(source.rows - 1) / 2)
            discRadius = Double(discFieldSize) / 4
        }
        refreshDiscOverlay()
    }

    /// Puts the radius back to what the automatic fit found.
    func resetDiscRadius() {
        guard let disc = disc else { return }
        discCentre = disc.centre
        discRadius = disc.radius
    }

    private func refreshDiscOverlay() {
        guard discImage != nil, discRadius > 0 else {
            discOverlay = []
            return
        }
        // The edge band belongs to the fitted rim, so it is only drawn while the
        // radius is still the fitted one. Carrying it along to a hand-set radius
        // would show a measured sharpness around a circle it was not measured
        // at, which is a claim the data does not support.
        let edge = discRadiusIsManual ? 0 : (disc?.edgeWidth ?? 0)
        discOverlay = PluginOverlayShape.list(
            CentralDiskFit.overlayShapes(centre: discCentre, radius: discRadius,
                                         edgeWidth: edge, measurement: disc))
    }

    /// Writes the disc measurement into the diffraction step field.
    func adoptDisc() {
        guard let outcome = discOutcome else { return }
        isEditing = true
        diffStep = String(format: "%g", outcome.step)
    }

    // MARK: Scan rotation

    func measureRotation() {
        rotationError = nil
        rotationOffer = nil

        guard let geometry = model.rotationGeometry() else {
            rotationError = ScanRotationError.scanTooSmall.localizedDescription
            return
        }
        guard geometry.scanWidth >= 5, geometry.scanHeight >= 5 else {
            rotationError = ScanRotationError.scanTooSmall.localizedDescription
            return
        }

        var settings = ScanRotationSettings()
        settings.smoothing = smoothing
        settings.edgeTrim = Int(edgeTrim)
        settings.detectorIndex = rotationDetector >= 0 ? rotationDetector : nil

        let mask = settings.detectorIndex.flatMap { model.detectorMaskFloats(at: $0) }
        let identity = model.selectedURL?.path ?? ""
        let flips = model.dataController.currentDetectorFlips.triple
        let detectorName = rotationDetector >= 0
            ? (model.detectors.indices.contains(rotationDetector)
               ? model.detectors[rotationDetector].name : "detector")
            : "whole pattern"
        let engine = rotationEngine
        let provider = model.patternProvider()

        isMeasuringRotation = true
        rotationProgress = 0

        DispatchQueue.global(qos: .userInitiated).async {
            guard let measured = engine.centreOfMassField(
                    geometry: geometry, mask: mask, identity: identity,
                    detectorIndex: settings.detectorIndex,
                    provider: provider,
                    progress: { value in
                        DispatchQueue.main.async { self.rotationProgress = value }
                    }) else {
                DispatchQueue.main.async {
                    self.isMeasuringRotation = false
                    self.rotationError = ScanRotationError.noSignal.localizedDescription
                }
                return
            }
            do {
                let (field, solution) = try engine.solve(measured, settings: settings)
                let report = engine.report(solution, field: field, fileName: identity,
                                           detectorName: detectorName, settings: settings,
                                           currentFlips: flips)
                let map = engine.map(field, solution: solution, wantCurl: false)
                let offer = engine.offer(solution, currentFlips: flips)
                DispatchQueue.main.async {
                    self.isMeasuringRotation = false
                    self.rotationProgress = 1
                    self.rotationReport = report
                    self.rotationCurve = solution.curlVersusAngle
                    self.rotationOffer = offer
                    self.rotationImage = CalibrationWindowModel.greyscale(map.values,
                                                                          width: map.columns,
                                                                          height: map.rows)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isMeasuringRotation = false
                    self.rotationError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    func adoptRotation() {
        guard let offer = rotationOffer else { return }
        isEditing = true
        scanRotation = String(format: "%.4g", offer.rotationDegrees)
        if let flips = offer.flips { detectorFlips = DetectorFlips(triple: flips) }
    }

    // MARK: Apply

    /// Everything shown, written into the application's calibration.
    ///
    /// A blank field clears that value rather than leaving the old one behind:
    /// the window shows the whole calibration, so what it shows is what it means.
    func apply() {
        model.calibrations = pendingCalibration()
    }

    func clearCorrection() { scanCorrection = nil; isEditing = true }

    // MARK: Images

    static func image(rgba: [UInt8], width: Int, height: Int) -> NSImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        var data = rgba
        guard let provider = CGDataProvider(data: Data(bytes: &data, count: data.count) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8,
                               bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    static func greyscaleImage(_ values: [Float], width: Int, height: Int) -> NSImage? {
        return greyscale(values, width: width, height: height)
    }

    private static func greyscale(_ values: [Float], width: Int, height: Int) -> NSImage? {
        guard width > 0, height > 0, values.count >= width * height else { return nil }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let span = max(maximum - minimum, .leastNormalMagnitude)
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let level = UInt8(max(0, min(255, (values[i] - minimum) / span * 255)))
            rgba[i * 4] = level; rgba[i * 4 + 1] = level; rgba[i * 4 + 2] = level
        }
        return image(rgba: rgba, width: width, height: height)
    }
}

// MARK: - View

struct CalibrationWindowView: View {

    @ObservedObject var model: CalibrationWindowModel
    let onClose: () -> Void

    // One tab per quantity, named for what it calibrates rather than for where
    // it looks. Which image a measurement reads is a detail of how it works; the
    // field it fills in is what the user came here for, and naming the tabs after
    // the fields is what makes the connection obvious.
    private enum Tab: String, CaseIterable {
        case values = "Values"
        case stepSize = "Step Size"
        case diffractionStep = "Diffraction Step"
        case rotation = "Scan Rotation"
        case library = "Library"
    }
    @State private var tab: Tab = .values

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView {
                switch tab {
                case .values:          valuesTab
                case .stepSize:        latticeTab(.stepSize)
                case .diffractionStep: diffractionTab
                case .rotation:        rotationTab
                case .library:         libraryTab
                }
            }
            .frame(minHeight: 320)

            Divider()

            HStack {
                Text("Nothing is applied until you press Apply.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { model.apply(); onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    // MARK: Values

    private var valuesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The calibration of this dataset. Blank means not set.")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                row("Step size", $model.scanStep, "nm per probe position")
                row("Diffraction step", $model.diffStep, "mrad per detector pixel")
                row("Voltage", $model.voltage, "kV")
                row("Scan rotation", $model.scanRotation, "degrees, scan against detector")
            }

            Divider()

            // Neither of these is typed: a 2x2 matrix and three orientation
            // flags are measured or read from the file, and a text field for
            // them would only be a way to enter them wrongly.
            GridRow {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Scan correction").frame(width: 130, alignment: .leading)
                        Text(model.correctionSummary).font(.system(.body, design: .monospaced))
                        if model.scanCorrection != nil {
                            Button("Clear") { model.clearCorrection() }.buttonStyle(.link)
                        }
                    }
                    HStack {
                        Text("Detector orientation").frame(width: 130, alignment: .leading)
                        Text(model.flipsSummary)
                    }
                }
            }

            Text("The scan correction is the raster's shape with the scale divided out, and the detector orientation is EMPAD's det_flips. Both are measured or read from the file rather than typed, and both are written to exported metadata.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func row(_ label: String, _ text: Binding<String>, _ unit: String) -> some View {
        GridRow {
            Text(label).frame(width: 130, alignment: .leading)
            TextField("", text: text)
                .frame(width: 120)
                .onChange(of: text.wrappedValue) { _, _ in model.noteEdit() }
            Text(unit).foregroundStyle(.secondary)
        }
    }

    // MARK: Diffraction step

    /// The diffraction step, by whichever of the two methods is selected.
    @ViewBuilder
    private var diffractionTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Measure from", selection: $model.diffractionMethod) {
                ForEach(CalibrationWindowModel.DiffractionMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.diffractionMethod) { _, method in
                if method == .centralDisc { model.measureDisc() }
                else { model.measureLattice(.diffractionStep) }
            }

            switch model.diffractionMethod {
            case .centralDisc:  centralDiscSection
            case .latticePeaks: latticeTab(.diffractionStep)
            }
        }
        .padding(model.diffractionMethod == .centralDisc ? 16 : 0)
        .padding(.top, model.diffractionMethod == .centralDisc ? 0 : 16)
        .onAppear {
            if model.diffractionMethod == .centralDisc && model.disc == nil {
                model.measureDisc()
            }
        }
    }

    @ViewBuilder
    private var centralDiscSection: some View {
        Text("The bright-field disc's edge sits at the convergence semi-angle, so its radius in pixels gives the angle per pixel directly. This works where the lattice fit struggles — at atomic resolution the diffracted discs overlap and a single pattern often has no separated reflections.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Text("Where the discs overlap very heavily — first-order discs as bright as the central one and closer than two radii — the rim is covered in every direction and cannot be recovered from the pattern at all. Calibrate on vacuum, or on a position with less overlap, when that is the case.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Picker("Known", selection: $model.discReference) {
            ForEach(CalibrationWindowModel.DiscReference.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.radioGroup)

        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            switch model.discReference {
            case .convergenceAngle:
                GridRow {
                    Text("Convergence").frame(width: 130, alignment: .leading)
                    TextField("semi-angle", text: $model.convergenceMilliradians).frame(width: 80)
                    Text("mrad").foregroundStyle(.secondary)
                }
            case .cameraGeometry:
                GridRow {
                    Text("Camera length").frame(width: 130, alignment: .leading)
                    TextField("", text: $model.cameraLengthMillimetres).frame(width: 80)
                    Text("mm").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Detector pixel").frame(width: 130, alignment: .leading)
                    TextField("", text: $model.pixelPitchMicrometres).frame(width: 80)
                    Text("µm").foregroundStyle(.secondary)
                }
            }
        }

        if let image = model.discImage {
            PluginZoomableImage(image: image,
                                overlay: model.discOverlay,
                                magnification: $model.discMagnification,
                                fitRequest: $model.discFitRequest,
                                actualSizeRequest: $model.discActualSizeRequest)
                .frame(minHeight: 260)
            HStack(spacing: 8) {
                Button("Fit") { model.discFitRequest += 1 }
                Button("1:1") { model.discActualSizeRequest += 1 }
                Spacer()
                Text(String(format: "centre (%.1f, %.1f)",
                            model.discCentre.x, model.discCentre.y))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            discRadiusControl

            if let disc = model.disc {
                RadialProfile(values: disc.profile, radius: model.discRadius)
                    .frame(height: 80)
                Text(model.discRadiusIsManual
                     ? "Azimuthal median against radius. The red line is the radius you have set — put it where the fall is, which is where the disc ends."
                     : "Azimuthal median against radius. The red line is the fitted rim, taken at the steepest point of the fall — which is where the disc ends even when overlapping discs raise the level just outside it.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let error = model.discError {
            Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
        // The fit's own diagnostics describe the fitted rim. Once the radius has
        // been moved they are about a circle no longer in use, so they go —
        // leaving them up would have the panel warning about a measurement the
        // user has already replaced.
        if let disc = model.disc, !model.discRadiusIsManual {
            if !disc.isSharp {
                Text(String(format: "⚠︎ The edge is %.1f px wide, which is broad for a disc of radius %.1f. The pattern may be defocused, or the discs may be overlapping too heavily for the rim to be found. Treat the radius with suspicion.", disc.edgeWidth, disc.radius))
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if disc.edgeDisagreement > 0.05, let half = disc.halfHeightRadius {
                Text(String(format: "The half-height radius is %.2f px against %.2f at the steepest point — a gap that means diffracted discs are sitting under the rim. The steeper measure is the one used, and is the one to trust here.", half, disc.radius))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let outcome = model.discOutcome {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.5g mrad per detector pixel", outcome.step))
                        .font(.callout)
                    Text(outcome.derived).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Use as Diffraction Step") { model.adoptDisc() }
            }
        } else if model.disc != nil {
            Text(model.discReference == .convergenceAngle
                 ? "Enter the convergence semi-angle to turn the radius into an angle per pixel."
                 : "Enter the camera length and the detector's pixel pitch.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
    }

    /// The radius in use, adjustable.
    ///
    /// A slider and a field together rather than either alone. The slider is for
    /// finding the rim — dragging it while watching the circle move over the
    /// pattern is the whole point, and it is how a rim the fit missed gets set.
    /// The field is for the cases where the number is already known, or where
    /// the last hundredth of a pixel matters and a slider cannot express it.
    @ViewBuilder
    private var discRadiusControl: some View {
        // Half the shorter side: a disc bigger than that does not fit on the
        // detector, so there is nothing above it worth being able to select.
        let upper = max(4.0, Double(model.discFieldSize) / 2)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Disc radius").frame(width: 130, alignment: .leading)
                Slider(value: $model.discRadius, in: 1...upper)
                TextField("", value: $model.discRadius,
                          format: .number.precision(.fractionLength(2)))
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                Text("px").foregroundStyle(.secondary)
                Button("Reset") { model.resetDiscRadius() }
                    .disabled(model.disc == nil || !model.discRadiusIsManual)
            }
            if model.discRadiusIsManual, let disc = model.disc {
                Text(String(format: "Set by hand. The automatic fit found %.2f px, drawn in blue for comparison.", disc.radius))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if model.disc != nil {
                Text("From the automatic fit. Drag to move the rim if it has landed on the wrong edge — zoom in on the circle to judge it.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Lattice

    /// Both lattice measurements, which differ only in which image they read and
    /// therefore which controls apply.
    @ViewBuilder
    private func latticeTab(_ mode: CalibrationWindowModel.LatticeMode) -> some View {
        let state = model.outcome(mode)
        let isDiffraction = mode.isDiffraction

        VStack(alignment: .leading, spacing: 12) {
            Text(isDiffraction
                 ? "Calibrates the detector — milliradians per detector pixel — from the spacing of Bragg reflections in the pattern on screen. Select a probe position first."
                 : "Calibrates the scan — nanometres per probe position — from the periodicity of the computed image on screen. Compute an image with a detector first.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Known spacings").frame(width: 130, alignment: .leading)
                    latticeField($model.d1, mode)
                    Text("×")
                    latticeField($model.d2, mode)
                    Text("Å at")
                    latticeField($model.latticeAngle, mode, width: 55)
                    Text("°")
                }
            }

            DisclosureGroup("Peak search") {
                VStack(alignment: .leading, spacing: 6) {
                    // The window and the padding shape the power spectrum, which
                    // only the real-space measurement computes. A diffraction
                    // pattern is already reciprocal space, so showing them here
                    // would be offering controls that do nothing.
                    if !isDiffraction {
                        Picker("Window", selection: $model.windowName) {
                            ForEach(CalibrationEngine.windowNames, id: \.self) { Text($0).tag($0) }
                        }
                        .onChange(of: model.windowName) { _, _ in model.scheduleMeasure(mode) }
                        liveSlider("Transform padding", $model.padFactor, 1...8, "%.0f", mode)
                    }
                    liveSlider("Ignore within (px)", $model.excludeRadius, 0...100, "%.0f", mode)
                    liveSlider("Peaks to consider", $model.peakCount, 2...300, "%.0f", mode)
                    liveSlider("Peak threshold", $model.peakThreshold, 0...0.5, "%.3f", mode)
                    liveSlider("Minimum vector angle (°)", $model.minimumAngle, 1...89, "%.0f", mode)
                }
                .padding(.top, 4)
            }

            // The picture, zoomable and panning the way the computed-image panel
            // does. It is the reason the controls are live: the exclusion radius
            // and the peak threshold are set by watching what they include.
            if let image = state.image {
                PluginZoomableImage(image: image,
                                    overlay: state.overlay,
                                    magnification: binding(mode, \.magnification),
                                    fitRequest: binding(mode, \.fitRequest),
                                    actualSizeRequest: binding(mode, \.actualSizeRequest))
                    .frame(minHeight: 260)
                HStack(spacing: 8) {
                    Button("Fit") { model.bumpFit(mode) }
                    Button("1:1") { model.bumpActualSize(mode) }
                    if state.isMeasuring { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(state.message).font(.footnote).foregroundStyle(.secondary)
                }
            } else if state.isMeasuring {
                HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 120)
            }

            if let error = state.error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let offer = state.offer {
                HStack(alignment: .firstTextBaseline) {
                    Text(offer.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(isDiffraction ? "Use as Diffraction Step" : "Use as Step Size") {
                        model.adoptLattice(mode)
                    }
                }
            } else if isDiffraction, !state.report.isEmpty {
                // The only reason a diffraction measurement succeeds but offers
                // nothing is a missing voltage, and saying so beats a blank space.
                Text("Measured, but the diffraction step needs the accelerating voltage to become an angle. Set it on the Values tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.report.isEmpty {
                DisclosureGroup("Full report") {
                    Text(state.report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .onAppear {
            // Measure on arrival, so the tab opens showing something rather
            // than waiting to be asked.
            if state.image == nil && !state.isMeasuring { model.measureLattice(mode) }
        }
    }

    /// A lattice parameter field that re-measures when it changes.
    private func latticeField(_ text: Binding<String>,
                              _ mode: CalibrationWindowModel.LatticeMode,
                              width: CGFloat = 70) -> some View {
        TextField("", text: text)
            .frame(width: width)
            .onChange(of: text.wrappedValue) { _, _ in
                model.noteEdit()
                model.scheduleMeasure(mode)
            }
    }

    private func liveSlider(_ label: String, _ value: Binding<Double>,
                            _ range: ClosedRange<Double>, _ format: String,
                            _ mode: CalibrationWindowModel.LatticeMode) -> some View {
        HStack {
            Text(label).frame(width: 170, alignment: .leading)
            Slider(value: value, in: range)
                .onChange(of: value.wrappedValue) { _, _ in model.scheduleMeasure(mode) }
            Text(String(format: format, value.wrappedValue))
                .font(.system(.body, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
        }
    }

    /// Binds one field of a per-mode outcome, so the zoom state lives with the
    /// tab it belongs to.
    private func binding<Value>(_ mode: CalibrationWindowModel.LatticeMode,
                                _ path: WritableKeyPath<CalibrationWindowModel.LatticeOutcome, Value>)
        -> Binding<Value> {
        return Binding(
            get: { model.outcome(mode)[keyPath: path] },
            set: { newValue in model.modify(mode) { $0[keyPath: path] = newValue } })
    }

    // MARK: Rotation

    private var rotationTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finds the angle between the scan and detector axes by minimising the curl of the centre-of-mass field. Needs no known lattice, and reads the whole 4D stack.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Centre of mass over", selection: $model.rotationDetector) {
                Text("Whole pattern").tag(-1)
                ForEach(Array(model.detectorNames.enumerated()), id: \.offset) { index, name in
                    Text(name).tag(index)
                }
            }

            slider("Smoothing (positions)", $model.smoothing, 0...10, "%.1f")
            slider("Ignore scan edge", $model.edgeTrim, 0...32, "%.0f")

            HStack {
                Button(model.isMeasuringRotation ? "Measuring…" : "Measure") {
                    model.measureRotation()
                }
                .disabled(model.isMeasuringRotation)
                if model.isMeasuringRotation {
                    ProgressView(value: model.rotationProgress).frame(width: 120)
                }
                if model.rotationOffer != nil {
                    Button("Use this") { model.adoptRotation() }
                }
                Spacer()
            }

            if let error = model.rotationError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let offer = model.rotationOffer {
                Text(offer.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !model.rotationCurve.isEmpty {
                CurlCurve(values: model.rotationCurve)
                    .frame(height: 90)
                Text("RMS curl against angle. A real measurement has an obvious trough.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let image = model.rotationImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 220)
                Text("Divergence of the corrected field — the atomic columns should be bright. If they are dark, add 180°.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.rotationReport.isEmpty {
                DisclosureGroup("Full report") {
                    Text(model.rotationReport)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: Library

    private var libraryTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Calibrations kept between sessions, filed under microscope, accelerating voltage and mode. The scan rotation, scan correction and detector orientation are properties of the instrument in a configuration, so a measurement made once carries to every dataset taken the same way.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("This dataset") {
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        GridRow {
                            Text("Microscope").frame(width: 90, alignment: .leading)
                            TextField("name of the instrument", text: $model.saveMicroscope)
                        }
                        GridRow {
                            Text("Voltage").frame(width: 90, alignment: .leading)
                            HStack {
                                TextField("", text: $model.saveKilovolts).frame(width: 70)
                                Text("kV").foregroundStyle(.secondary)
                            }
                        }
                        GridRow {
                            Text("Mode").frame(width: 90, alignment: .leading)
                            TextField("camera length, imaging mode, or whatever distinguishes it",
                                      text: $model.saveMode)
                        }
                        GridRow {
                            Text("Note").frame(width: 90, alignment: .leading)
                            TextField("optional", text: $model.saveNote)
                        }
                    }
                    HStack {
                        Button("Save Current Calibration") { model.saveToLibrary() }
                        if model.matchForThisDataset != nil {
                            Text("replaces the entry already stored for this configuration")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .padding(8)
            }

            if let message = model.libraryMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let match = model.matchForThisDataset {
                GroupBox("Stored for this configuration") {
                    entryRow(match, highlighted: true)
                        .padding(6)
                }
            }
            if !model.otherModesForThisDataset.isEmpty {
                GroupBox("Same instrument and voltage, other modes") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.otherModesForThisDataset) { entry in
                            entryRow(entry, highlighted: false)
                        }
                        Text("A different mode is a different camera length or projector setting, so its diffraction step does not carry over — but its scan correction and orientation usually do.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }
            }

            if let entry = model.selectedEntry {
                GroupBox("Load \(entry.identity.display)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entry.availableFields) { field in
                            Toggle(isOn: Binding(
                                get: { model.fieldsToApply.contains(field) },
                                set: { on in
                                    if on { model.fieldsToApply.insert(field) }
                                    else { model.fieldsToApply.remove(field) }
                                })) {
                                    HStack(spacing: 6) {
                                        Text(field.label)
                                        if let caveat = field.caveat {
                                            Text("— \(caveat)")
                                                .font(.footnote).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                        }
                        if entry.scanStepNanometres != nil {
                            // Said here rather than only in a tooltip: this is
                            // the one field that can be wrong by a large factor
                            // while looking entirely reasonable.
                            Text(entry.magnification.map {
                                String(format: "The stored step size was measured at ×%.0f. It is left unticked because nanometres per probe position follows the magnification, not the instrument.", $0)
                            } ?? "The stored step size is left unticked because nanometres per probe position follows the magnification, not the instrument.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button("Load Ticked Values") { model.applySelectedEntry() }
                            Button("Cancel") { model.selectedEntry = nil }
                            Spacer()
                        }
                    }
                    .padding(6)
                }
            }

            if model.library.entries.isEmpty {
                Text("Nothing saved yet.").foregroundStyle(.secondary)
            } else {
                GroupBox("All saved calibrations") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.library.grouped(), id: \.microscope) { group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.microscope.isEmpty ? "unnamed" : group.microscope)
                                    .font(.headline)
                                ForEach(group.voltages, id: \.kilovolts) { voltage in
                                    Text(String(format: "%.0f kV", voltage.kilovolts))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                        .padding(.leading, 10)
                                    ForEach(voltage.entries) { entry in
                                        entryRow(entry, highlighted: false)
                                            .padding(.leading, 20)
                                    }
                                }
                            }
                        }
                    }
                    .padding(6)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func entryRow(_ entry: SavedCalibration, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.identity.mode.isEmpty ? "(no mode)" : entry.identity.mode)
                    .fontWeight(highlighted ? .semibold : .regular)
                Text(entry.summary).font(.footnote).foregroundStyle(.secondary)
                if !entry.note.isEmpty {
                    Text(entry.note).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Load…") { model.select(entry) }
            Button {
                model.delete(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this stored calibration")
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, _ format: String) -> some View {
        HStack {
            Text(label).frame(width: 170, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(.body, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// The radial profile with the fitted rim marked.
private struct RadialProfile: View {
    let values: [Float]
    let radius: Double

    var body: some View {
        GeometryReader { geometry in
            let maximum = values.max() ?? 1
            let minimum = values.min() ?? 0
            let span = max(maximum - minimum, .leastNonzeroMagnitude)
            let width = geometry.size.width
            // The axis covers the rim as well as the profile. The radius is
            // now the user's to set and can be dragged past everything that was
            // measured; scaling to the profile alone would let the red line
            // leave the plot, so the control would appear to stop responding at
            // exactly the point where it needs watching.
            let extent = max(Double(values.count - 1), radius, 1)
            let x: (Double) -> Double = { r in width * r / extent }
            ZStack {
                Path { path in
                    for (index, value) in values.enumerated() {
                        let px = x(Double(index))
                        let py = geometry.size.height * Double(1 - (value - minimum) / span)
                        if index == 0 { path.move(to: CGPoint(x: px, y: py)) }
                        else { path.addLine(to: CGPoint(x: px, y: py)) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
                Path { path in
                    path.move(to: CGPoint(x: x(radius), y: 0))
                    path.addLine(to: CGPoint(x: x(radius), y: geometry.size.height))
                }
                .stroke(Color.red, lineWidth: 1)
            }
        }
        .background(Color.secondary.opacity(0.08))
    }
}

/// The curl-versus-angle curve, drawn small. It exists to be judged by shape —
/// a deep trough or none — not read off, so it carries no axes.
private struct CurlCurve: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let maximum = values.max() ?? 1
            let minimum = values.min() ?? 0
            let span = max(maximum - minimum, .leastNonzeroMagnitude)
            Path { path in
                for (index, value) in values.enumerated() {
                    let x = geometry.size.width * Double(index) / Double(max(values.count - 1, 1))
                    let y = geometry.size.height * (1 - (value - minimum) / span)
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
        .background(Color.secondary.opacity(0.08))
    }
}
