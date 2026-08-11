//
//  PowerCepstrumPlugin.swift
//  4DSTEM Explorer — example plugin
//
//  Exit-wave power cepstrum (EWPC) and strain mapping.
//
//  What the transform does
//  -----------------------
//  A nanobeam diffraction pattern is, to a good approximation, the lattice
//  factor multiplied by everything else — the probe, the structure factor, the
//  dynamical scattering. Taking a logarithm turns that product into a sum, and
//  Fourier transforming the log separates the periodic part from the smooth
//  part:
//
//      EWPC(r) = | FFT{ log( I(k) + ε ) } |
//
//  The result lives in a space with the units of length, and its peaks sit at
//  the *real-space* interatomic vectors of the illuminated volume. Measuring
//  where those peaks are gives the local lattice directly.
//
//  Why bother, when you could fit the Bragg disks
//  ---------------------------------------------
//  Disk fitting needs disks that are separated, round and unsaturated. The
//  cepstrum does not care: overlapping disks, strong dynamical contrast and a
//  large convergence angle all leave the *positions* of the cepstral peaks
//  alone, because they change the amplitude of the diffraction pattern rather
//  than its periodicity. That is what makes this work on thick or strongly
//  scattering specimens where disk fitting falls apart.
//
//  Method: Padgett et al., Ultramicroscopy 214 (2020) 112994,
//  doi:10.1016/j.ultramic.2020.112994. See PowerCepstrum.bib for the full
//  reference list, which the app shows and exports.
//

import Foundation
import Accelerate

@objc(PowerCepstrumPlugin)
public final class PowerCepstrumPlugin: NSObject, FDSPlugin {

    public var pluginIdentifier: String { return "group.lebeau.4dstem.plugin.powercepstrum" }
    public var pluginName: String { return "Power Cepstrum (EWPC)" }
    public var pluginSummary: String {
        return "Fourier transforms the log of each diffraction pattern. The peaks of the result sit at real-space lattice vectors, so tracking them maps strain — and unlike disk fitting it survives overlapping disks and dynamical scattering."
    }
    public var pluginAPIVersion: Int { return 1 }
    public var pluginSupportsLiveUpdate: Bool { return true }

    // MARK: Cache
    //
    // Runs are serialised and never re-entrant, so no locking is needed. The
    // expensive part is one FFT per probe position; switching which strain
    // component is displayed must not pay for that again.

    private struct AnalysisKey: Equatable {
        var fileName: String
        var scanWidth: Int, scanHeight: Int
        var patternWidth: Int, patternHeight: Int
        var padded: Int
        var logFloorFraction: Double
        var windowed: Bool
        var squared: Bool
        var stride: Int
    }

    private struct StrainKey: Equatable {
        var analysis: AnalysisKey
        var peak1: [Int]
        var peak2: [Int]
        var searchRadius: Int
    }

    private var cachedAnalysisKey: AnalysisKey?
    private var cachedMeanCepstrum: [Float] = []
    private var cachedPeaks: [CepstralPeak] = []

    private var cachedStrainKey: StrainKey?
    private var cachedStrain: StrainField?

    /// Seeds the voltage from the open dataset's calibration when it has one,
    /// so it does not have to be typed a second time.
    public func parameters(for host: FDSHostContext) -> [[String: Any]] {
        let kilovolts = host.accelerationKilovolts
        guard kilovolts > 0 else { return pluginParameters }
        return pluginParameters.map { parameter -> [String: Any] in
            guard parameter[FDSParameterKey.identifier] as? String == "voltage" else { return parameter }
            var seeded = parameter
            seeded[FDSParameterKey.defaultValue] = NSNumber(value: kilovolts)
            return seeded
        }
    }

    public var pluginParameters: [[String: Any]] {
        return [
            FDSParameter.choice("output", label: "Return",
                                choices: ["Mean cepstrum", "Cepstrum at selection",
                                          "Strain εxx", "Strain εyy", "Shear εxy", "Rotation",
                                          "Peak amplitude", "Peak report"],
                                help: "Start with Mean cepstrum to see where the peaks are, then switch to a strain component."),
            FDSParameter.number("logFloor", label: "Log floor (fraction of max)", defaultValue: 0.001,
                                minimum: 0.000001, maximum: 0.5,
                                help: "The ε in log(I + ε), as a fraction of the mean pattern's maximum. It stops empty pixels dominating the logarithm; too large flattens the pattern and weakens the peaks."),
            FDSParameter.toggle("window", label: "Apodise before transforming", defaultValue: true,
                                help: "Tapers the pattern to zero at the detector edge. Without it the sharp cut-off adds a cross through the cepstrum that can bury nearby peaks."),
            FDSParameter.integer("padding", label: "Zero-pad factor", defaultValue: 2, minimum: 1, maximum: 4,
                                 help: "Transform size relative to the detector. Higher interpolates the cepstrum more finely, which helps locate peaks, at the cost of time and memory."),
            FDSParameter.choice("scale", label: "Cepstrum scale", choices: ["Amplitude", "Power (squared)"],
                                help: "Amplitude is |FFT{log I}|, the usual EWPC convention. Power squares it, which sharpens peaks and suppresses the background."),
            FDSParameter.integer("stride", label: "Scan stride", defaultValue: 1, minimum: 1, maximum: 16,
                                 help: "Sample every nth probe position. Raise it for a quick look at a large scan."),
            FDSParameter.integer("searchRadius", label: "Peak search radius (px)", defaultValue: 4,
                                 minimum: 2, maximum: 24,
                                 help: "How far from its reference position a peak is followed at each probe position. Large enough to track the strain, small enough not to jump to a neighbour."),
            FDSParameter.integer("peak1X", label: "Peak 1 x (0 = auto)", defaultValue: 0, minimum: -512, maximum: 512),
            FDSParameter.integer("peak1Y", label: "Peak 1 y", defaultValue: 0, minimum: -512, maximum: 512),
            FDSParameter.integer("peak2X", label: "Peak 2 x (0 = auto)", defaultValue: 0, minimum: -512, maximum: 512),
            FDSParameter.integer("peak2Y", label: "Peak 2 y", defaultValue: 0, minimum: -512, maximum: 512),
            FDSParameter.number("voltage", label: "Accelerating voltage (kV)", defaultValue: 200,
                                minimum: 0, maximum: 1000,
                                help: "Only used to quote cepstral distances in ångström. 0 leaves them in pixels. Strain is a ratio and never depends on this."),
        ]
    }

    // MARK: - Run

    public func run(host: FDSHostContext, parameters: [String: Any]) -> [String: Any]? {

        let scanWidth = host.scanWidth
        let scanHeight = host.scanHeight
        let patternWidth = host.patternWidth
        let patternHeight = host.patternHeight
        guard scanWidth > 0, scanHeight > 0, patternWidth > 1, patternHeight > 1 else {
            return FDSResult.failure("No 4D dataset is open.")
        }

        let output = parameters["output"] as? String ?? "Mean cepstrum"
        let logFloorFraction = Swift.max(1e-6, (parameters["logFloor"] as? NSNumber)?.doubleValue ?? 0.001)
        let windowed = (parameters["window"] as? NSNumber)?.boolValue ?? true
        let padFactor = Swift.max(1, Swift.min(4, (parameters["padding"] as? NSNumber)?.intValue ?? 2))
        let squared = (parameters["scale"] as? String ?? "").hasPrefix("Power")
        let stride = Swift.max(1, (parameters["stride"] as? NSNumber)?.intValue ?? 1)
        let searchRadius = Swift.max(2, (parameters["searchRadius"] as? NSNumber)?.intValue ?? 4)
        let voltage = (parameters["voltage"] as? NSNumber)?.doubleValue ?? 200

        // The transform size: the next power of two at or above the detector,
        // times the padding factor. vDSP's radix-2 FFT needs a power of two,
        // and a square keeps the two axes on the same scale.
        let base = nextPowerOfTwo(Swift.max(patternWidth, patternHeight))
        let padded = base * padFactor
        guard padded <= 4096 else {
            return FDSResult.failure("A \(padded)×\(padded) transform is too large. Lower the zero-pad factor.")
        }

        // A cepstral peak is about this many samples across: the transform size
        // over the detector size, which is the pad factor.
        let peakWidth = Swift.max(1, padded / nextPowerOfTwo(Swift.max(patternWidth, patternHeight)))

        let key = AnalysisKey(fileName: host.fileName,
                              scanWidth: scanWidth, scanHeight: scanHeight,
                              patternWidth: patternWidth, patternHeight: patternHeight,
                              padded: padded, logFloorFraction: logFloorFraction,
                              windowed: windowed, squared: squared, stride: stride)

        // 1. Mean cepstrum, and the peaks in it. Cached — everything downstream
        //    refers to these reference positions.
        if key != cachedAnalysisKey {
            guard let engine = CepstrumEngine(size: padded) else {
                return FDSResult.failure("Could not set up a \(padded)-point FFT.")
            }
            guard let floor = meanPatternFloor(host: host, fraction: Float(logFloorFraction)) else {
                return nil   // cancelled
            }
            guard let mean = meanCepstrum(host: host, engine: engine, floor: floor,
                                          windowed: windowed, squared: squared, stride: stride) else {
                return nil   // cancelled
            }
            cachedMeanCepstrum = mean
            cachedPeaks = findPeaks(mean, size: padded, limit: 12, spacing: peakWidth)
            cachedAnalysisKey = key
            cachedStrainKey = nil          // reference moved; strain must follow
            cachedStrain = nil
        }

        let calibration = CepstralCalibration(padded: padded,
                                              diffractionStepMilliradians: host.diffractionStepMilliradians,
                                              kilovolts: voltage)

        switch output {
        case "Mean cepstrum":
            return cepstrumResult(cachedMeanCepstrum, padded: padded, host: host,
                                  title: "Mean Power Cepstrum",
                                  message: peakSummary(cachedPeaks, calibration: calibration)
                                      + " " + settingsNote(padded: padded, windowed: windowed,
                                                           squared: squared, stride: stride))

        case "Cepstrum at selection":
            guard let engine = CepstrumEngine(size: padded) else {
                return FDSResult.failure("Could not set up the FFT.")
            }
            guard let floor = meanPatternFloor(host: host, fraction: Float(logFloorFraction)) else { return nil }
            let row = host.selectedRow >= 0 ? host.selectedRow : scanHeight / 2
            let column = host.selectedColumn >= 0 ? host.selectedColumn : scanWidth / 2
            var buffer = [Float](repeating: 0, count: host.patternPixelCount)
            guard buffer.withUnsafeMutableBufferPointer({
                host.copyPattern(row: row, column: column, into: $0.baseAddress!, capacity: $0.count)
            }) else {
                return FDSResult.failure("Could not read the pattern at the selected position.")
            }
            var single = [Float](repeating: 0, count: padded * padded)
            buffer.withUnsafeBufferPointer {
                engine.transform(pattern: $0.baseAddress!, width: patternWidth, height: patternHeight,
                                 floor: floor, windowed: windowed, squared: squared, into: &single)
            }
            let peaks = findPeaks(single, size: padded, limit: 8, spacing: peakWidth)
            return cepstrumResult(single, padded: padded, host: host,
                                  title: "Power Cepstrum at (x \(column), y \(row))",
                                  message: peakSummary(peaks, calibration: calibration))

        case "Peak report":
            guard !cachedPeaks.isEmpty else {
                return FDSResult.failure("No cepstral peaks were found. Try a smaller log floor, or check that the patterns show lattice fringes.")
            }
            return FDSResult.text(peakReport(cachedPeaks, calibration: calibration, host: host,
                                             padded: padded, windowed: windowed,
                                             squared: squared, stride: stride),
                                  title: "Cepstral Peaks — \(host.fileName)")

        default:
            break
        }

        // 2. Strain needs two reference peaks: either the ones asked for or the
        //    two strongest that are not parallel.
        let requested1 = [(parameters["peak1X"] as? NSNumber)?.intValue ?? 0,
                          (parameters["peak1Y"] as? NSNumber)?.intValue ?? 0]
        let requested2 = [(parameters["peak2X"] as? NSNumber)?.intValue ?? 0,
                          (parameters["peak2Y"] as? NSNumber)?.intValue ?? 0]

        var reference1: (x: Double, y: Double)
        var reference2: (x: Double, y: Double)
        var chosenAutomatically = false

        if requested1 == [0, 0] || requested2 == [0, 0] {
            guard let pair = automaticPair(cachedPeaks) else {
                return FDSResult.failure("Could not find two independent cepstral peaks automatically. Run \"Peak report\", pick two that are not parallel, and enter their coordinates.")
            }
            reference1 = (pair.0.x, pair.0.y)
            reference2 = (pair.1.x, pair.1.y)
            chosenAutomatically = true
        } else {
            reference1 = (Double(requested1[0]), Double(requested1[1]))
            reference2 = (Double(requested2[0]), Double(requested2[1]))
        }

        let cross = reference1.x * reference2.y - reference1.y * reference2.x
        guard abs(cross) > 1e-6 else {
            return FDSResult.failure("The two peaks are parallel, so they do not define a lattice. Pick a second peak in a different direction.")
        }

        let strainKey = StrainKey(analysis: key,
                                  peak1: [Int(reference1.x.rounded()), Int(reference1.y.rounded())],
                                  peak2: [Int(reference2.x.rounded()), Int(reference2.y.rounded())],
                                  searchRadius: searchRadius)

        if strainKey != cachedStrainKey || cachedStrain == nil {
            guard let engine = CepstrumEngine(size: padded) else {
                return FDSResult.failure("Could not set up the FFT.")
            }
            guard let floor = meanPatternFloor(host: host, fraction: Float(logFloorFraction)) else { return nil }
            guard let field = mapStrain(host: host, engine: engine, floor: floor,
                                        windowed: windowed, squared: squared, stride: stride,
                                        padded: padded,
                                        reference1: reference1, reference2: reference2,
                                        searchRadius: searchRadius, peakSpacing: peakWidth) else {
                return nil   // cancelled
            }
            cachedStrain = field
            cachedStrainKey = strainKey
        }
        guard let field = cachedStrain else {
            return FDSResult.failure("The strain map could not be built.")
        }

        let values: [Float]
        let title: String
        switch output {
        case "Strain εxx": values = field.exx;      title = "εxx"
        case "Strain εyy": values = field.eyy;      title = "εyy"
        case "Shear εxy":  values = field.exy;      title = "εxy"
        case "Rotation":   values = field.rotation; title = "Lattice rotation"
        default:           values = field.amplitude; title = "Cepstral peak amplitude"
        }

        var note = ""
        if chosenAutomatically {
            note = String(format: "Peaks chosen automatically at (%.0f, %.0f) and (%.0f, %.0f). ",
                          reference1.x, reference1.y, reference2.x, reference2.y)
        }
        note += String(format: "%@ Reference lattice %@ and %@. %d of %d positions tracked.",
                       output == "Rotation" ? "Rotation in milliradians." : "Strain relative to the scan mean, dimensionless.",
                       calibration.describe(reference1), calibration.describe(reference2),
                       field.tracked, field.total)
        if field.tracked < field.total {
            note += " Positions where a peak reached the edge of its search radius are left at zero — widen the radius if there are many."
        }
        note += " " + settingsNote(padded: padded, windowed: windowed, squared: squared, stride: stride)

        return FDSResult.scanImage(values, rows: field.rows, columns: field.columns,
                                   title: "\(title) — \(host.fileName)", message: note)
    }

    private func settingsNote(padded: Int, windowed: Bool, squared: Bool, stride: Int) -> String {
        var parts = ["\(padded)×\(padded) transform"]
        parts.append(squared ? "power" : "amplitude")
        if windowed { parts.append("apodised") }
        if stride > 1 { parts.append("scan stride \(stride)") }
        return "(" + parts.joined(separator: ", ") + ")."
    }
}

// MARK: - The transform

/// Computes |FFT{log(I + ε)}| for one diffraction pattern.
///
/// Held across calls because `vDSP_create_fftsetup` is expensive and the
/// buffers are reused for every probe position.
private final class CepstrumEngine {

    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var real: [Float]
    private var imag: [Float]
    private var apodisation: [Float] = []
    private var apodisationSize = (width: 0, height: 0)

    init?(size: Int) {
        n = size
        log2n = vDSP_Length(round(log2(Double(size))))
        guard size == (1 << Int(log2n)),
              let created = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        setup = created
        real = [Float](repeating: 0, count: size * size)
        imag = [Float](repeating: 0, count: size * size)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// A Hann taper in each axis. Without it the detector's sharp edge
    /// transforms into a cross of sidelobes through the middle of the cepstrum,
    /// which sits exactly where the low-order peaks are.
    private func apodisationWeights(width: Int, height: Int) -> [Float] {
        if apodisationSize == (width, height) { return apodisation }
        var weights = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let wy = 0.5 - 0.5 * cos(2 * Double.pi * Double(y) / Double(Swift.max(1, height - 1)))
            for x in 0..<width {
                let wx = 0.5 - 0.5 * cos(2 * Double.pi * Double(x) / Double(Swift.max(1, width - 1)))
                weights[y * width + x] = Float(wx * wy)
            }
        }
        apodisation = weights
        apodisationSize = (width, height)
        return weights
    }

    /// `output` is n×n with zero quefrency at the centre.
    func transform(pattern: UnsafePointer<Float>, width: Int, height: Int,
                   floor: Float, windowed: Bool, squared: Bool,
                   into output: inout [Float]) {

        let count = n * n
        var zero: Float = 0
        vDSP_vfill(&zero, &real, 1, vDSP_Length(count))
        vDSP_vfill(&zero, &imag, 1, vDSP_Length(count))

        // log(I + ε) over the detector, written into the corner of the padded
        // array. The origin only sets a phase, and only the magnitude is kept.
        let pixels = width * height
        var logged = [Float](repeating: 0, count: pixels)
        var offset = floor
        vDSP_vsadd(pattern, 1, &offset, &logged, 1, vDSP_Length(pixels))
        var elements = Int32(pixels)
        vvlogf(&logged, logged, &elements)

        // Remove the mean first: the logarithm has a large offset, and left in
        // it becomes a delta at zero quefrency that swamps everything nearby.
        var mean: Float = 0
        vDSP_meanv(logged, 1, &mean, vDSP_Length(pixels))
        var negativeMean = -mean
        vDSP_vsadd(logged, 1, &negativeMean, &logged, 1, vDSP_Length(pixels))

        if windowed {
            let weights = apodisationWeights(width: width, height: height)
            vDSP_vmul(logged, 1, weights, 1, &logged, 1, vDSP_Length(pixels))
        }

        for row in 0..<height {
            logged.withUnsafeBufferPointer { source in
                real.withUnsafeMutableBufferPointer { destination in
                    memcpy(destination.baseAddress! + row * n,
                           source.baseAddress! + row * width,
                           width * MemoryLayout<Float>.size)
                }
            }
        }

        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                            imagp: imagBuffer.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, 0, log2n, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, realBuffer.baseAddress!, 1, vDSP_Length(count))
            }
        }
        if squared {
            vDSP_vsq(real, 1, &real, 1, vDSP_Length(count))
        }

        // Put zero quefrency in the middle, where it is easier to look at and
        // where peak coordinates are naturally signed.
        let half = n / 2
        for y in 0..<n {
            let sourceRow = ((y + half) % n) * n
            let destinationRow = y * n
            for x in 0..<n {
                output[destinationRow + x] = real[sourceRow + (x + half) % n]
            }
        }
    }
}

// MARK: - Peaks

private struct CepstralPeak {
    var x: Double          // relative to the centre, in cepstral pixels
    var y: Double
    var amplitude: Float
    var radius: Double { return (x * x + y * y).squareRoot() }
}

/// Where a cepstral pixel sits in real space.
private struct CepstralCalibration {
    let padded: Int
    let angstromsPerPixel: Double     // 0 when the wavelength is unknown

    init(padded: Int, diffractionStepMilliradians: Double, kilovolts: Double) {
        self.padded = padded
        guard diffractionStepMilliradians > 0, kilovolts > 0 else {
            angstromsPerPixel = 0
            return
        }
        // λ from the accelerating voltage, then Δk = θ/λ per detector pixel.
        // The transform's conjugate step is 1/(N·Δk).
        let volts = kilovolts * 1000
        let lambda = 12.2639 / (volts + 0.97845e-6 * volts * volts).squareRoot()   // Å
        let deltaK = (diffractionStepMilliradians / 1000.0) / lambda               // 1/Å
        angstromsPerPixel = deltaK > 0 ? 1.0 / (Double(padded) * deltaK) : 0
    }

    var calibrated: Bool { return angstromsPerPixel > 0 }

    func describe(_ vector: (x: Double, y: Double)) -> String {
        let length = (vector.x * vector.x + vector.y * vector.y).squareRoot()
        if calibrated {
            return String(format: "(%.1f, %.1f) px = %.3f Å", vector.x, vector.y, length * angstromsPerPixel)
        }
        return String(format: "(%.1f, %.1f) px", vector.x, vector.y)
    }
}

extension PowerCepstrumPlugin {

    fileprivate func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result <<= 1 }
        return result
    }

    /// ε for log(I + ε), taken from the mean pattern rather than each pattern
    /// so the transform is the same everywhere in the scan.
    fileprivate func meanPatternFloor(host: FDSHostContext, fraction: Float) -> Float? {
        let pixels = host.patternPixelCount
        var accumulator = [Float](repeating: 0, count: pixels)
        var buffer = [Float](repeating: 0, count: pixels)
        let strideY = Swift.max(1, host.scanHeight / 16)
        let strideX = Swift.max(1, host.scanWidth / 16)
        var sampled = 0

        for row in 0..<host.scanHeight where row % strideY == 0 {
            if host.isCancelled { return nil }
            for column in 0..<host.scanWidth where column % strideX == 0 {
                let read = buffer.withUnsafeMutableBufferPointer {
                    host.copyPattern(row: row, column: column, into: $0.baseAddress!, capacity: $0.count)
                }
                guard read else { continue }
                vDSP_vadd(accumulator, 1, buffer, 1, &accumulator, 1, vDSP_Length(pixels))
                sampled += 1
            }
        }
        guard sampled > 0 else { return nil }
        var maximum: Float = 0
        vDSP_maxv(accumulator, 1, &maximum, vDSP_Length(pixels))
        maximum /= Float(sampled)
        // Never zero: log(0) is not a number the rest of this can survive.
        return Swift.max(maximum * fraction, .leastNormalMagnitude)
    }

    fileprivate func meanCepstrum(host: FDSHostContext, engine: CepstrumEngine, floor: Float,
                                  windowed: Bool, squared: Bool, stride: Int) -> [Float]? {
        let count = engine.n * engine.n
        var total = [Float](repeating: 0, count: count)
        var single = [Float](repeating: 0, count: count)
        var buffer = [Float](repeating: 0, count: host.patternPixelCount)
        var used = 0

        var index = 0
        let rows = Swift.stride(from: 0, to: host.scanHeight, by: stride).map { $0 }
        for row in rows {
            if host.isCancelled { return nil }
            for column in Swift.stride(from: 0, to: host.scanWidth, by: stride) {
                let read = buffer.withUnsafeMutableBufferPointer {
                    host.copyPattern(row: row, column: column, into: $0.baseAddress!, capacity: $0.count)
                }
                guard read else { continue }
                buffer.withUnsafeBufferPointer {
                    engine.transform(pattern: $0.baseAddress!,
                                     width: host.patternWidth, height: host.patternHeight,
                                     floor: floor, windowed: windowed, squared: squared, into: &single)
                }
                vDSP_vadd(total, 1, single, 1, &total, 1, vDSP_Length(count))
                used += 1
            }
            index += 1
            host.reportProgress(0.45 * Double(index) / Double(Swift.max(1, rows.count)))
        }
        guard used > 0 else { return nil }
        var scale = 1 / Float(used)
        vDSP_vsmul(total, 1, &scale, &total, 1, vDSP_Length(count))
        return total
    }

    /// Local maxima, strongest first, with the central peak excluded.
    fileprivate func findPeaks(_ cepstrum: [Float], size: Int, limit: Int,
                               spacing: Int = 1) -> [CepstralPeak] {
        let centre = size / 2
        // Zero quefrency carries the pattern's own autocorrelation and is
        // always the tallest thing present; it says nothing about the lattice.
        let exclusion = Swift.max(3.0, Double(size) * 0.02)

        var candidates: [CepstralPeak] = []
        for y in 1..<(size - 1) {
            for x in 1..<(size - 1) {
                let dx = Double(x - centre), dy = Double(y - centre)
                guard (dx * dx + dy * dy).squareRoot() > exclusion else { continue }
                let value = cepstrum[y * size + x]
                guard value > cepstrum[y * size + x - 1], value >= cepstrum[y * size + x + 1],
                      value > cepstrum[(y - 1) * size + x], value >= cepstrum[(y + 1) * size + x] else { continue }
                let refined = refine(cepstrum, size: size, aroundX: x, y: y, spacing: spacing)
                candidates.append(CepstralPeak(x: refined.x - Double(centre),
                                               y: refined.y - Double(centre),
                                               amplitude: value))
            }
        }
        candidates.sort { $0.amplitude > $1.amplitude }

        // Keep only well-separated maxima: a broad peak produces a cluster.
        var kept: [CepstralPeak] = []
        let minimumSeparation = Swift.max(3.0, Double(size) * 0.015)
        for candidate in candidates {
            if kept.contains(where: { hypot($0.x - candidate.x, $0.y - candidate.y) < minimumSeparation } ) { continue }
            kept.append(candidate)
            if kept.count >= limit { break }
        }
        return kept
    }

    /// Sub-pixel peak position from a parabola through the log of the three
    /// samples straddling the maximum, in each axis.
    ///
    /// This replaced an intensity-weighted centroid, which looked reasonable
    /// and was quietly wrong: a fixed window centred on the integer maximum
    /// truncates the peak asymmetrically once it sits off-centre, dragging the
    /// estimate back toward the window. That shrinks every displacement by a
    /// roughly constant factor, so strain came out ~17 % low — a scale error a
    /// common-mode reference cannot remove. Taking the log first makes the fit
    /// exact for a Gaussian peak and near enough for the real one.
    fileprivate func refine(_ image: [Float], size: Int, aroundX x: Int, y: Int,
                            spacing: Int = 1) -> (x: Double, y: Double) {

        func vertex(_ before: Float, _ centre: Float, _ after: Float) -> Double {
            // Guard the logarithm, and the flat case where there is no vertex.
            let epsilon = Float.leastNormalMagnitude
            let l0 = Double(log(Swift.max(before, epsilon)))
            let l1 = Double(log(Swift.max(centre, epsilon)))
            let l2 = Double(log(Swift.max(after, epsilon)))
            let denominator = l0 - 2 * l1 + l2
            guard abs(denominator) > 1e-12 else { return 0 }
            let delta = 0.5 * (l0 - l2) / denominator
            // A vertex more than one step away means the maximum is not the
            // sample it was taken around; trust the sample instead.
            return abs(delta) <= 1 ? delta : 0
        }

        // The samples straddling the maximum must span the peak, not sit on its
        // flat top. Zero-padding widens the peak in samples by exactly the pad
        // factor, so the step has to widen with it — with a fixed step of one,
        // the fitted scale drifts with the padding and strain reads several
        // percent low at pad 4.
        let step = Swift.max(1, spacing)
        guard x >= step, x < size - step, y >= step, y < size - step else {
            return (Double(x), Double(y))
        }
        let dx = vertex(image[y * size + x - step], image[y * size + x], image[y * size + x + step])
        let dy = vertex(image[(y - step) * size + x], image[y * size + x], image[(y + step) * size + x])
        return (Double(x) + dx * Double(step), Double(y) + dy * Double(step))
    }

    /// Intensity-weighted centroid, kept for the initial peak survey where
    /// robustness matters more than the last fraction of a pixel.
    fileprivate func centroid(_ image: [Float], size: Int, aroundX x: Int, y: Int,
                              radius: Int) -> (x: Double, y: Double) {
        var weight = 0.0, sumX = 0.0, sumY = 0.0
        // Subtracting the window's own floor stops a bright background pulling
        // the centroid toward the middle of the window.
        var background = Float.greatestFiniteMagnitude
        for dy in -radius...radius {
            for dx in -radius...radius {
                let px = x + dx, py = y + dy
                guard px >= 0, px < size, py >= 0, py < size else { continue }
                background = Swift.min(background, image[py * size + px])
            }
        }
        for dy in -radius...radius {
            for dx in -radius...radius {
                let px = x + dx, py = y + dy
                guard px >= 0, px < size, py >= 0, py < size else { continue }
                let value = Double(Swift.max(0, image[py * size + px] - background))
                weight += value
                sumX += value * Double(px)
                sumY += value * Double(py)
            }
        }
        guard weight > 0 else { return (Double(x), Double(y)) }
        return (sumX / weight, sumY / weight)
    }

    /// The two strongest peaks that are not parallel, so they span a lattice.
    fileprivate func automaticPair(_ peaks: [CepstralPeak]) -> (CepstralPeak, CepstralPeak)? {
        guard let first = peaks.first else { return nil }
        for candidate in peaks.dropFirst() {
            let cross = first.x * candidate.y - first.y * candidate.x
            let sine = abs(cross) / Swift.max(1e-9, first.radius * candidate.radius)
            if sine > 0.25 { return (first, candidate) }      // at least ~15° apart
        }
        return nil
    }
}

// MARK: - Strain

private struct StrainField {
    var rows: Int
    var columns: Int
    var exx: [Float]
    var eyy: [Float]
    var exy: [Float]
    var rotation: [Float]        // milliradians
    var amplitude: [Float]
    var tracked: Int
    var total: Int
}

extension PowerCepstrumPlugin {

    /// Follows two cepstral peaks across the scan and turns each pair of
    /// vectors into a deformation gradient.
    ///
    /// The cepstral peaks sit at real-space lattice vectors, so the matrix they
    /// form *is* the local lattice — no reciprocal-space inversion, which is
    /// what makes this so direct compared with fitting Bragg disks.
    fileprivate func mapStrain(host: FDSHostContext, engine: CepstrumEngine, floor: Float,
                               windowed: Bool, squared: Bool, stride: Int, padded: Int,
                               reference1: (x: Double, y: Double),
                               reference2: (x: Double, y: Double),
                               searchRadius: Int, peakSpacing: Int) -> StrainField? {

        let columns = (host.scanWidth + stride - 1) / stride
        let rows = (host.scanHeight + stride - 1) / stride
        let total = rows * columns

        var a11 = [Double](repeating: 0, count: total)   // peak 1, measured
        var a12 = [Double](repeating: 0, count: total)
        var a21 = [Double](repeating: 0, count: total)   // peak 2
        var a22 = [Double](repeating: 0, count: total)
        var valid = [Bool](repeating: false, count: total)
        var amplitude = [Float](repeating: 0, count: total)

        var cepstrum = [Float](repeating: 0, count: padded * padded)
        var buffer = [Float](repeating: 0, count: host.patternPixelCount)
        let centre = padded / 2

        var outputRow = 0
        for row in Swift.stride(from: 0, to: host.scanHeight, by: stride) {
            if host.isCancelled { return nil }
            var position = outputRow * columns

            for column in Swift.stride(from: 0, to: host.scanWidth, by: stride) {
                defer { position += 1 }
                let read = buffer.withUnsafeMutableBufferPointer {
                    host.copyPattern(row: row, column: column, into: $0.baseAddress!, capacity: $0.count)
                }
                guard read else { continue }
                buffer.withUnsafeBufferPointer {
                    engine.transform(pattern: $0.baseAddress!,
                                     width: host.patternWidth, height: host.patternHeight,
                                     floor: floor, windowed: windowed, squared: squared, into: &cepstrum)
                }

                guard let first = track(cepstrum, size: padded, centre: centre,
                                        near: reference1, radius: searchRadius, spacing: peakSpacing),
                      let second = track(cepstrum, size: padded, centre: centre,
                                         near: reference2, radius: searchRadius, spacing: peakSpacing) else { continue }

                a11[position] = first.x
                a12[position] = first.y
                a21[position] = second.x
                a22[position] = second.y
                amplitude[position] = first.amplitude
                valid[position] = true
            }

            outputRow += 1
            host.reportProgress(0.45 + 0.5 * Double(outputRow) / Double(Swift.max(1, rows)))
        }

        // The reference lattice is the mean over everything tracked, so strain
        // reads relative to the scan itself rather than to the peak positions
        // picked off the mean cepstrum, which are quantised by the search.
        var mean = [Double](repeating: 0, count: 4)
        var tracked = 0
        for index in 0..<total where valid[index] {
            mean[0] += a11[index]; mean[1] += a12[index]
            mean[2] += a21[index]; mean[3] += a22[index]
            tracked += 1
        }
        guard tracked >= 4 else { return nil }
        for i in 0..<4 { mean[i] /= Double(tracked) }

        // The lattice vectors are the COLUMNS of the reference matrix:
        //
        //     M0 = [ a1x  a2x ]        a1 = (mean[0], mean[1])
        //          [ a1y  a2y ]        a2 = (mean[2], mean[3])
        //
        // With columns, M = F·M0 and F = M·M0⁻¹ is the deformation gradient in
        // xy. Laying the vectors out as rows instead gives A0·Fᵀ·A0⁻¹ — the
        // deformation expressed in the lattice's own basis, which silently
        // reports strain against whichever peaks happened to be picked rather
        // than against x and y.
        let r00 = mean[0], r01 = mean[2]
        let r10 = mean[1], r11 = mean[3]
        let determinant = r00 * r11 - r01 * r10
        guard abs(determinant) > 1e-9 else { return nil }
        let i00 =  r11 / determinant, i01 = -r01 / determinant
        let i10 = -r10 / determinant, i11 =  r00 / determinant

        var exx = [Float](repeating: 0, count: total)
        var eyy = [Float](repeating: 0, count: total)
        var exy = [Float](repeating: 0, count: total)
        var rotation = [Float](repeating: 0, count: total)

        for index in 0..<total where valid[index] {
            // Same column layout for the local lattice, then F = M · M0⁻¹.
            let m00 = a11[index], m01 = a21[index]
            let m10 = a12[index], m11 = a22[index]
            let f00 = m00 * i00 + m01 * i10
            let f01 = m00 * i01 + m01 * i11
            let f10 = m10 * i00 + m11 * i10
            let f11 = m10 * i01 + m11 * i11

            // Symmetric part minus identity is the small-strain tensor; the
            // antisymmetric part is the rigid rotation.
            exx[index] = Float(f00 - 1)
            eyy[index] = Float(f11 - 1)
            exy[index] = Float(0.5 * (f01 + f10))
            rotation[index] = Float(0.5 * (f10 - f01) * 1000.0)   // mrad
        }

        return StrainField(rows: rows, columns: columns,
                           exx: exx, eyy: eyy, exy: exy, rotation: rotation,
                           amplitude: amplitude, tracked: tracked, total: total)
    }

    /// Finds a peak near `near`, to sub-pixel precision. Nil when the maximum
    /// lands on the edge of the window, which means the true peak is outside it
    /// and the position would be wrong rather than merely imprecise.
    fileprivate func track(_ cepstrum: [Float], size: Int, centre: Int,
                           near: (x: Double, y: Double), radius: Int, spacing: Int)
        -> (x: Double, y: Double, amplitude: Float)? {

        let originX = centre + Int(near.x.rounded())
        let originY = centre + Int(near.y.rounded())

        var best: Float = -.greatestFiniteMagnitude
        var bestX = originX, bestY = originY
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = originX + dx, y = originY + dy
                guard x >= 1, x < size - 1, y >= 1, y < size - 1 else { continue }
                let value = cepstrum[y * size + x]
                if value > best { best = value; bestX = x; bestY = y }
            }
        }
        guard best > -.greatestFiniteMagnitude else { return nil }
        guard abs(bestX - originX) < radius, abs(bestY - originY) < radius else { return nil }

        let refined = refine(cepstrum, size: size, aroundX: bestX, y: bestY, spacing: spacing)
        return (refined.x - Double(centre), refined.y - Double(centre), best)
    }

    // MARK: - Presentation

    fileprivate func cepstrumResult(_ cepstrum: [Float], padded: Int, host: FDSHostContext,
                                    title: String, message: String) -> [String: Any] {
        // The centre is orders of magnitude above everything else even after
        // the mean is removed; a log display is the only way to see the peaks
        // that matter alongside it.
        var shown = [Float](repeating: 0, count: cepstrum.count)
        var minimum: Float = 0, maximum: Float = 0
        vDSP_minv(cepstrum, 1, &minimum, vDSP_Length(cepstrum.count))
        vDSP_maxv(cepstrum, 1, &maximum, vDSP_Length(cepstrum.count))
        var offset = 1 - minimum
        vDSP_vsadd(cepstrum, 1, &offset, &shown, 1, vDSP_Length(cepstrum.count))
        var elements = Int32(cepstrum.count)
        vvlogf(&shown, shown, &elements)
        _ = maximum

        return FDSResult.pattern(shown, rows: padded, columns: padded,
                                 title: "\(title) — \(host.fileName)",
                                 message: "Shown on a log scale; zero quefrency is at the centre. " + message)
    }

    fileprivate func peakSummary(_ peaks: [CepstralPeak], calibration: CepstralCalibration) -> String {
        guard !peaks.isEmpty else {
            return "No peaks found away from the centre — try a smaller log floor."
        }
        let listed = peaks.prefix(4).map { peak -> String in
            calibration.describe((peak.x, peak.y))
        }.joined(separator: ", ")
        return "Strongest peaks: \(listed)."
    }

    fileprivate func peakReport(_ peaks: [CepstralPeak], calibration: CepstralCalibration,
                                host: FDSHostContext, padded: Int,
                                windowed: Bool, squared: Bool, stride: Int) -> String {
        var report = "Power cepstrum — peaks in the mean\n\n"
        report += "File          \(host.fileName)\n"
        report += "Patterns      \(host.patternWidth) × \(host.patternHeight)\n"
        report += "Transform     \(padded) × \(padded)\(windowed ? ", apodised" : "")\(squared ? ", power" : ", amplitude")\n"
        if calibration.calibrated {
            report += String(format: "Cepstral pixel %.4f Å\n", calibration.angstromsPerPixel)
        } else {
            report += "Cepstral pixel unknown — needs a diffraction calibration and a voltage\n"
        }
        report += "\n"

        if peaks.isEmpty {
            report += "No peaks were found away from the centre.\n\n"
            report += "The transform only shows peaks where the diffraction pattern is\n"
            report += "periodic, so check that the patterns really do show lattice fringes,\n"
            report += "and try a smaller log floor — too large a floor flattens the pattern.\n"
            return report
        }

        report += "  #   x       y      radius   amplitude"
        report += calibration.calibrated ? "   distance\n" : "\n"
        for (index, peak) in peaks.enumerated() {
            report += String(format: "  %-3d %7.2f %7.2f %8.2f %11.4g",
                             index + 1, peak.x, peak.y, peak.radius, Double(peak.amplitude))
            if calibration.calibrated {
                report += String(format: " %9.3f Å", peak.radius * calibration.angstromsPerPixel)
            }
            report += "\n"
        }

        report += "\nPick two that are not parallel and enter their x and y above to map\n"
        report += "strain, or leave the peak boxes at 0 to have the two strongest\n"
        report += "independent peaks chosen automatically.\n"
        return report
    }
}
