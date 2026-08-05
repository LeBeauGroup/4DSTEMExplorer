//
//  ACBFAberrations.swift
//  4DSTEM Explorer — Aberration-Corrected Bright Field
//
//  The optics: a Krivanek (n, m) expansion of the aberration function, the
//  displacement field that follows from it, and the frame transform between the
//  detector and the scan.
//
//  Everything here is a pure function of numbers. Nothing touches the host, the
//  4D data or the GPU, which is what makes it checkable against a reference
//  implementation term by term.
//
//  Units, fixed once so the rest of the plugin need not think about them:
//
//      k          Å⁻¹        spatial frequency / detector coordinate
//      λ          Å          electron wavelength
//      α = k·λ    rad        scattering angle
//      C_nm       Å          aberration coefficients
//      χ          rad        the aberration function
//      shift      Å          image displacement, = ∇_k χ / 2π
//
//  This is an independent implementation of the standard aberration expansion
//  and of the bright-field transfer used by aberration-corrected BF. It was
//  written from the physics and checked numerically against the published
//  method; no source from any GPL/LGPL project was copied into it.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

// MARK: - Order table

/// The (n, m) terms of the aberration expansion, in a fixed order.
///
/// For each radial order `n` the allowed azimuthal orders are `m = (n+1) mod 2,
/// (n+1) mod 2 + 2, … , n+1`, so `n + 1 - m` is always even and every radial
/// power below is an integer. `m == 0` terms are rotationally symmetric and
/// carry one coefficient; the rest carry a Cartesian pair (a, b) equivalent to
/// a magnitude and an azimuth.
struct ACBFOrders {

    struct Key {
        let n: Int
        let m: Int
        /// Index of this term's first coefficient in the flat vector.
        let offset: Int
        /// 1 for symmetric terms, 2 for the (a, b) pairs.
        let width: Int
        let name: String
    }

    let maxOrder: Int
    let keys: [Key]
    let coefficientCount: Int

    init(maxOrder: Int) {
        let order = max(1, min(6, maxOrder))
        self.maxOrder = order

        var keys: [Key] = []
        var offset = 0
        for n in 1...order {
            var m = (n + 1) % 2
            while m <= n + 1 {
                let width = (m == 0) ? 1 : 2
                keys.append(Key(n: n, m: m, offset: offset, width: width,
                                name: ACBFOrders.name(n: n, m: m)))
                offset += width
                m += 2
            }
        }
        self.keys = keys
        self.coefficientCount = offset
    }

    /// Krivanek notation, with the common name where one exists.
    private static func name(n: Int, m: Int) -> String {
        switch (n, m) {
        case (1, 0): return "C1 defocus"
        case (1, 2): return "A1 twofold astigmatism"
        case (2, 1): return "B2 axial coma"
        case (2, 3): return "A2 threefold astigmatism"
        case (3, 0): return "C3 spherical"
        case (3, 2): return "S3 star"
        case (3, 4): return "A3 fourfold astigmatism"
        case (4, 1): return "B4 coma"
        case (4, 3): return "D4 three lobe"
        case (4, 5): return "A4 fivefold astigmatism"
        case (5, 0): return "C5 spherical"
        default:     return m == 0 ? "C\(n)" : "A\(n),\(m)"
        }
    }

    /// Labels for every entry of the flat coefficient vector.
    var coefficientLabels: [String] {
        var labels: [String] = []
        for key in keys {
            if key.width == 1 {
                labels.append(key.name)
            } else {
                labels.append(key.name + " a")
                labels.append(key.name + " b")
            }
        }
        return labels
    }

    /// Index of the defocus coefficient, which several routines single out.
    var defocusIndex: Int? {
        return keys.first { $0.n == 1 && $0.m == 0 }?.offset
    }

    /// Indices of the twofold astigmatism pair.
    var astigmatismIndices: (Int, Int)? {
        guard let key = keys.first(where: { $0.n == 1 && $0.m == 2 }) else { return nil }
        return (key.offset, key.offset + 1)
    }
}

// MARK: - The aberration function

/// Evaluates χ and its gradient for a set of coefficients.
///
/// Both quantities are built from the same two ingredients: the radial power
/// α^(n+1-m) and the Cartesian pair (Xₘ, Yₘ) = Re, Im of (αx + i·αy)^m. Writing
/// them once and differentiating analytically keeps the shift field exactly
/// consistent with the phase it comes from — a finite-difference gradient would
/// not be, and the reconstruction is sensitive to that.
struct ACBFAberrationFunction {

    let orders: ACBFOrders
    let wavelength: Double      // Å

    init(orders: ACBFOrders, wavelength: Double) {
        self.orders = orders
        self.wavelength = wavelength
    }

    /// Re, Im of (αx + i·αy)^m for m = 0 … maxOrder + 1.
    ///
    /// Tabulated rather than advanced alongside the term loop: `m` restarts at
    /// every radial order, so a running product would be stale from the second
    /// order onwards.
    private func cartesianPowers(ax: Double, ay: Double) -> (x: [Double], y: [Double]) {
        let count = orders.maxOrder + 2
        var x = [Double](repeating: 0, count: count + 1)
        var y = [Double](repeating: 0, count: count + 1)
        x[0] = 1; y[0] = 0
        for m in 0..<count {
            x[m + 1] = x[m] * ax - y[m] * ay
            y[m + 1] = x[m] * ay + y[m] * ax
        }
        return (x, y)
    }

    /// χ at one detector coordinate, in radians.
    ///
    /// - Parameters:
    ///   - kx, ky: spatial frequency in Å⁻¹.
    ///   - coefficients: flat vector in Å, `orders.coefficientCount` long.
    func chi(kx: Double, ky: Double, coefficients: [Double]) -> Double {
        let ax = kx * wavelength
        let ay = ky * wavelength
        let alphaSquared = ax * ax + ay * ay
        let multiplier = 2 * Double.pi / wavelength

        let power = cartesianPowers(ax: ax, ay: ay)
        var total = 0.0

        for key in orders.keys {
            let radial = pow(alphaSquared, Double(key.n + 1 - key.m) / 2)
            let scale = radial / Double(key.n + 1) * multiplier

            if key.width == 1 {
                total += coefficients[key.offset] * scale * power.x[key.m]
            } else {
                total += coefficients[key.offset]     * scale * power.x[key.m]
                total += coefficients[key.offset + 1] * scale * power.y[key.m]
            }
        }
        return total
    }

    /// The image displacement produced by these aberrations at one detector
    /// coordinate, in Å. This is ∇_k χ / 2π — the quantity tcBF shifts by.
    func shift(kx: Double, ky: Double, coefficients: [Double]) -> (dx: Double, dy: Double) {
        let basis = shiftBasis(kx: kx, ky: ky)
        var dx = 0.0, dy = 0.0
        for i in 0..<orders.coefficientCount {
            dx += coefficients[i] * basis.dx[i]
            dy += coefficients[i] * basis.dy[i]
        }
        return (dx, dy)
    }

    /// The unweighted (C = 1) displacement basis at one detector coordinate.
    /// Precomputing this per virtual detector turns every later shift into a dot
    /// product, which is what makes a defocus sweep cheap.
    func shiftBasis(kx: Double, ky: Double) -> (dx: [Double], dy: [Double]) {
        let ax = kx * wavelength
        let ay = ky * wavelength
        let alphaSquared = ax * ax + ay * ay
        // Guards the α = 0 pixel, where the radial derivative of a term with
        // n + 1 - m == 2 is finite but written as 0 · (α²)⁻¹·⁰.
        let safeSquared = alphaSquared + 1e-12

        var dx = [Double](repeating: 0, count: orders.coefficientCount)
        var dy = [Double](repeating: 0, count: orders.coefficientCount)
        let power = cartesianPowers(ax: ax, ay: ay)

        for key in orders.keys {
            let powerX = power.x[key.m], powerY = power.y[key.m]
            // The azimuthal derivative of (αx + i·αy)^m needs the m-1 power.
            let previousX = key.m > 0 ? power.x[key.m - 1] : 0
            let previousY = key.m > 0 ? power.y[key.m - 1] : 0

            let degree = key.n + 1 - key.m
            let p = Double(degree) / 2
            let inverse = Double(key.n + 1)

            // d/dα of α^degree, split into its x and y components.
            var radialX = 0.0, radialY = 0.0
            if degree > 0 {
                let common = Double(degree) * pow(safeSquared, p - 1)
                radialX = common * ax
                radialY = common * ay
            }
            let radialBase = pow(alphaSquared, p)

            if key.width == 1 {
                dx[key.offset] = radialX * powerX / inverse
                dy[key.offset] = radialY * powerX / inverse
            } else {
                let azimuthal = Double(key.m) * radialBase
                // a: the Xₘ component. ∂Xₘ/∂αx = m·Xₘ₋₁, ∂Xₘ/∂αy = −m·Yₘ₋₁.
                dx[key.offset]     = (radialX * powerX + azimuthal * previousX) / inverse
                dy[key.offset]     = (radialY * powerX - azimuthal * previousY) / inverse
                // b: the Yₘ component. ∂Yₘ/∂αx = m·Yₘ₋₁, ∂Yₘ/∂αy = m·Xₘ₋₁.
                dx[key.offset + 1] = (radialX * powerY + azimuthal * previousY) / inverse
                dy[key.offset + 1] = (radialY * powerY + azimuthal * previousX) / inverse
            }
        }
        return (dx, dy)
    }

    /// The unweighted phase basis, for the same reason as `shiftBasis`.
    func chiBasis(kx: Double, ky: Double) -> [Double] {
        let ax = kx * wavelength
        let ay = ky * wavelength
        let alphaSquared = ax * ax + ay * ay
        let multiplier = 2 * Double.pi / wavelength

        var basis = [Double](repeating: 0, count: orders.coefficientCount)
        let power = cartesianPowers(ax: ax, ay: ay)

        for key in orders.keys {
            let scale = pow(alphaSquared, Double(key.n + 1 - key.m) / 2)
                / Double(key.n + 1) * multiplier
            basis[key.offset] = scale * power.x[key.m]
            if key.width == 2 { basis[key.offset + 1] = scale * power.y[key.m] }
        }
        return basis
    }
}

// MARK: - Aperture

/// The bright-field aperture, optionally with a cosine-tapered edge.
///
/// A hard edge rings in the reconstruction because the transfer is truncated
/// mid-oscillation; the taper trades a little resolution for that. `rolloff` is
/// the width of the transition in milliradians, and 0 restores the hard edge.
@inline(__always)
func acbfAperture(alpha: Double, maxAlphaMilliradians: Double, rolloffMilliradians: Double) -> Double {
    let cutoff = maxAlphaMilliradians / 1000
    if rolloffMilliradians <= 0 {
        return alpha <= cutoff ? 1 : 0
    }
    let rolloff = rolloffMilliradians / 1000
    if alpha > cutoff { return 0 }
    if alpha < cutoff - rolloff { return 1 }
    return 0.5 * (1 + cos(Double.pi * (alpha - cutoff + rolloff) / rolloff))
}

// MARK: - Frames

/// How detector coordinates map onto the scan.
///
/// The order matters and is fixed: flip rows, flip columns, transpose, then
/// rotate. Anything else and a fitted rotation means something different
/// depending on which flips happen to be set.
struct ACBFCoordinateTransform: Equatable {
    var flipRows: Bool = false
    var flipColumns: Bool = false
    var transpose: Bool = false
    /// Counter-clockwise, in degrees.
    var rotationDegrees: Double = 0

    /// Maps one detector coordinate into the scan frame.
    func apply(kx: Double, ky: Double, includeRotation: Bool = true) -> (kx: Double, ky: Double) {
        var x = kx, y = ky
        if flipRows { y = -y }
        if flipColumns { x = -x }
        if transpose { swap(&x, &y) }
        if includeRotation && rotationDegrees != 0 {
            let theta = rotationDegrees * Double.pi / 180
            let c = cos(theta), s = sin(theta)
            let rotatedX = x * c - y * s
            let rotatedY = x * s + y * c
            x = rotatedX; y = rotatedY
        }
        return (x, y)
    }

    /// Rotates the coefficient vector from the detector frame into the scan
    /// frame. Symmetric terms are invariant; each (a, b) pair rotates by m·θ,
    /// because that pair is the Cartesian form of a magnitude at an azimuth and
    /// an m-fold term repeats every 2π/m.
    func rotateCoefficients(_ coefficients: [Double], orders: ACBFOrders) -> [Double] {
        guard rotationDegrees != 0 else { return coefficients }
        var out = coefficients
        for key in orders.keys where key.width == 2 {
            let theta = Double(key.m) * rotationDegrees * Double.pi / 180
            let c = cos(theta), s = sin(theta)
            let a = coefficients[key.offset]
            let b = coefficients[key.offset + 1]
            out[key.offset]     = a * c - b * s
            out[key.offset + 1] = a * s + b * c
        }
        return out
    }
}

// MARK: - Calibration

/// The physical numbers a reconstruction needs, derived once from the file's
/// calibration and the disc the user picked.
struct ACBFOptics {
    /// Electron wavelength, Å.
    let wavelength: Double
    /// Detector pixel size, Å⁻¹.
    let dk: Double
    /// Convergence semi-angle, mrad.
    let maxAlpha: Double
    /// Aperture edge taper, mrad.
    let rolloff: Double
    /// Scan step, Å.
    let scanStep: Double

    /// Relativistic electron wavelength in ångström for an accelerating voltage
    /// in kilovolts.
    static func wavelength(kilovolts: Double) -> Double {
        let volts = kilovolts * 1000
        return 12.2639 / (volts + 0.97845e-6 * volts * volts).squareRoot()
    }

    /// Builds the optics from what the host knows plus the located disc.
    ///
    /// - Parameters:
    ///   - kilovolts: accelerating voltage.
    ///   - diffractionStepMilliradians: detector calibration, mrad per pixel.
    ///   - discRadiusPixels: bright-field disc radius in detector pixels, which
    ///     fixes the convergence angle.
    ///   - scanStepNanometres: scan calibration.
    init?(kilovolts: Double,
          diffractionStepMilliradians: Double,
          discRadiusPixels: Double,
          scanStepNanometres: Double,
          rolloffMilliradians: Double = 0) {

        guard kilovolts > 0, diffractionStepMilliradians > 0,
              discRadiusPixels > 0, scanStepNanometres > 0 else { return nil }

        self.wavelength = ACBFOptics.wavelength(kilovolts: kilovolts)
        // Δk = Δθ / λ, with Δθ in radians.
        self.dk = (diffractionStepMilliradians / 1000) / wavelength
        self.maxAlpha = discRadiusPixels * diffractionStepMilliradians
        self.rolloff = max(0, rolloffMilliradians)
        self.scanStep = scanStepNanometres * 10
    }

    /// Direct construction, for overrides typed by the user.
    init(wavelength: Double, dk: Double, maxAlpha: Double, rolloff: Double, scanStep: Double) {
        self.wavelength = wavelength
        self.dk = dk
        self.maxAlpha = maxAlpha
        self.rolloff = rolloff
        self.scanStep = scanStep
    }

    /// The coefficient of radial order `n` that contributes exactly one radian
    /// of phase at the edge of the aperture.
    ///
    /// This is the natural unit for that order, and it is what makes a search
    /// over several orders at once well conditioned: expressed this way a
    /// defocus and a C3 are comparable numbers, whereas in ångström they differ
    /// by four orders of magnitude and any optimiser working on the raw vector
    /// is effectively blind to the small ones.
    func coefficientScale(order n: Int) -> Double {
        let edgeAlpha = maxAlpha / 1000
        guard edgeAlpha > 0 else { return 1 }
        return Double(n + 1) * wavelength / (2 * Double.pi * pow(edgeAlpha, Double(n + 1)))
    }

    /// Defocus in Å that produces a given displacement at the disc edge.
    /// Useful only for reporting; the reconstruction works in coefficients.
    func defocus(edgeShiftAngstroms: Double) -> Double {
        let edgeAlpha = maxAlpha / 1000
        guard edgeAlpha > 0 else { return 0 }
        return edgeShiftAngstroms / edgeAlpha
    }
}
