//
//  PluginCalibration.swift
//  4DSTEM Explorer
//
//  A calibration a plugin has offered, and what it takes to accept one.
//
//  A plugin cannot change the application's state, and should not be able to. A
//  calibration is not an ordinary result: it changes how every subsequent number
//  in the application is read — every distance in a reconstruction, every
//  defocus, every strain pixel size. So a plugin returns one as a proposal, the
//  host shows what is being proposed, and it takes effect only when the user
//  accepts it.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

/// A calibration offered by a plugin. Every field is optional: a plugin that
/// measured only the scan step offers only that, and accepting it leaves the
/// rest of the calibration alone rather than clearing it.
struct PluginCalibration {

    /// Nanometres per probe position.
    let scanStepNanometers: Float?
    /// Milliradians per detector pixel.
    let diffractionStepMilliradians: Float?
    /// Accelerating voltage in kilovolts.
    let accelerationKilovolts: Float?
    /// Scan rotation in degrees.
    let scanRotationDegrees: Float?
    /// The raster's shape, mean scale divided out, row-major.
    let scanCorrection: ScanCorrection?
    /// How the patterns should be oriented on the detector.
    let detectorFlips: DetectorFlips?
    /// The plugin's own one-line description of what it is offering.
    let summary: String?

    init?(_ value: Any?) {
        guard let dictionary = value as? [String: Any] else { return nil }

        func number(_ key: String) -> Float? {
            guard let raw = (dictionary[key] as? NSNumber)?.floatValue,
                  raw.isFinite, raw > 0 else { return nil }
            return raw
        }
        let scan = number(FDSCalibrationKey.scanStepNanometers)
        let diffraction = number(FDSCalibrationKey.diffractionStepMilliradians)
        let voltage = number(FDSCalibrationKey.accelerationKilovolts)

        let rotation = (dictionary[FDSCalibrationKey.scanRotationDegrees] as? NSNumber)?.floatValue
        let correction = (dictionary[FDSCalibrationKey.scanCorrection] as? [NSNumber])
            .flatMap { ScanCorrection(rowMajor: $0.map { $0.floatValue }) }
        let flips = (dictionary[FDSCalibrationKey.detectorFlips] as? [NSNumber])
            .flatMap { DetectorFlips(triple: $0.map { $0.boolValue }) }

        // A dictionary with nothing usable in it is not an offer.
        guard scan != nil || diffraction != nil || voltage != nil
                || rotation != nil || correction != nil || flips != nil else { return nil }

        scanStepNanometers = scan
        diffractionStepMilliradians = diffraction
        accelerationKilovolts = voltage
        scanRotationDegrees = rotation.flatMap { $0.isFinite ? $0 : nil }
        scanCorrection = correction
        detectorFlips = flips
        summary = (dictionary[FDSCalibrationKey.summary] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What accepting this would change, written out for the confirmation.
    ///
    /// Shows the current value beside the new one: a calibration is easy to
    /// accept by reflex, and seeing what it replaces is what makes the decision
    /// a real one.
    func changes(from current: Calibrations?) -> [String] {
        var lines: [String] = []
        func line(_ label: String, _ new: Float?, _ old: Float?, _ format: String, _ unit: String) {
            guard let new = new else { return }
            if let old = old, abs(old - new) < abs(new) * 1e-6 {
                lines.append("\(label): unchanged at \(String(format: format, new)) \(unit)")
            } else if let old = old {
                lines.append("\(label): \(String(format: format, old)) → \(String(format: format, new)) \(unit)")
            } else {
                lines.append("\(label): \(String(format: format, new)) \(unit) (was not set)")
            }
        }
        line("Scan step", scanStepNanometers, current?.scan_step, "%.5g", "nm/px")
        line("Diffraction step", diffractionStepMilliradians, current?.diff_step, "%.5g", "mrad/px")
        line("Voltage", accelerationKilovolts, current?.voltage, "%.0f", "kV")
        line("Scan rotation", scanRotationDegrees, current?.scanRotationDegrees, "%.3f", "°")
        if let correction = scanCorrection {
            lines.append(String(format: "Scan correction: [%.5f %.5f; %.5f %.5f]%@",
                                correction.m00, correction.m01, correction.m10, correction.m11,
                                correction.isIdentity ? " (square raster)" : ""))
        }
        if let flips = detectorFlips {
            if let old = current?.detectorFlips, old == flips {
                lines.append("Detector orientation: unchanged at \(flips.summary)")
            } else if let old = current?.detectorFlips {
                lines.append("Detector orientation: \(old.summary) → \(flips.summary)")
                lines.append("  (recorded for export; reopen the file to see the patterns re-oriented)")
            } else {
                lines.append("Detector orientation: \(flips.summary) (was not set)")
            }
        }
        return lines
    }

    /// This calibration merged over the existing one, leaving untouched
    /// anything it does not carry.
    func applied(to current: Calibrations?) -> Calibrations {
        return Calibrations(scan_step: scanStepNanometers ?? current?.scan_step,
                            diff_step: diffractionStepMilliradians ?? current?.diff_step,
                            voltage: accelerationKilovolts ?? current?.voltage,
                            scanRotationDegrees: scanRotationDegrees ?? current?.scanRotationDegrees,
                            scanCorrection: scanCorrection ?? current?.scanCorrection,
                            detectorFlips: detectorFlips ?? current?.detectorFlips)
    }
}
