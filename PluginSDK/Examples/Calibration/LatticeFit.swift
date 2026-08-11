//
//  LatticeFit.swift
//  4DSTEM Explorer — Calibration
//
//  Finds a lattice in an image and works out what maps it onto a known one.
//
//  The measurement is always the same: locate two independent periodicities and
//  express them as vectors in pixels. What differs is where they come from. A
//  diffraction pattern already *is* a reciprocal-space map, so its Bragg spots
//  are the vectors, found directly. A real-space image has to be transformed
//  first, and its Fourier peaks are the vectors.
//
//  Everything here is pure arithmetic on arrays — no host, no 4D data — so the
//  parts that are easy to get wrong can be checked against lattices with known
//  distortions planted in them.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Accelerate

// MARK: - Vectors and matrices

/// A 2×2 matrix, stored by column so that `columns.0` is the image of (1, 0).
///
/// Storing lattice vectors as columns rather than rows is not a detail. A basis
/// written as rows produces the transpose of the map you want, and the result
/// still looks plausible — symmetric distortions come out right and only shear
/// is wrong — which makes the mistake hard to catch by eye.
struct Matrix2: Equatable {

    var a: Double, b: Double     // first column  (x, y)
    var c: Double, d: Double     // second column (x, y)

    init(a: Double, b: Double, c: Double, d: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d
    }

    /// From two column vectors.
    init(columns first: (x: Double, y: Double), _ second: (x: Double, y: Double)) {
        a = first.x; b = first.y
        c = second.x; d = second.y
    }

    static let identity = Matrix2(a: 1, b: 0, c: 0, d: 1)

    var determinant: Double { return a * d - b * c }

    var inverse: Matrix2? {
        let det = determinant
        guard abs(det) > 1e-15 else { return nil }
        return Matrix2(a: d / det, b: -b / det, c: -c / det, d: a / det)
    }

    var transposed: Matrix2 { return Matrix2(a: a, b: c, c: b, d: d) }

    /// `self` applied after `other`.
    func times(_ other: Matrix2) -> Matrix2 {
        return Matrix2(a: a * other.a + c * other.b,
                       b: b * other.a + d * other.b,
                       c: a * other.c + c * other.d,
                       d: b * other.c + d * other.d)
    }

    func apply(_ v: (x: Double, y: Double)) -> (x: Double, y: Double) {
        return (a * v.x + c * v.y, b * v.x + d * v.y)
    }

    /// First column.
    var firstColumn: (x: Double, y: Double) { return (a, b) }
    /// Second column.
    var secondColumn: (x: Double, y: Double) { return (c, d) }
}

@inline(__always) func vectorLength(_ v: (x: Double, y: Double)) -> Double {
    return (v.x * v.x + v.y * v.y).squareRoot()
}

/// Angle from `u` to `v`, in degrees, signed and in (-180, 180].
func angleBetween(_ u: (x: Double, y: Double), _ v: (x: Double, y: Double)) -> Double {
    let cross = u.x * v.y - u.y * v.x
    let dot = u.x * v.x + u.y * v.y
    return atan2(cross, dot) * 180 / .pi
}

// MARK: - Polar decomposition

/// A calibration matrix split into the parts a user can act on.
struct CalibrationDecomposition {

    /// The full map from pixels to physical units.
    let transform: Matrix2
    /// Rotation of the map, in degrees, counter-clockwise.
    let rotationDegrees: Double
    /// Geometric mean pixel size, in whatever unit the known lattice used.
    let meanPixelSize: Double
    /// Pixel size along the two principal axes of the symmetric part.
    let principalPixelSizes: (Double, Double)
    /// Direction of the first principal axis, degrees from +x.
    let principalAxisDegrees: Double
    /// Departure from isotropy: (max - min) / mean of the principal sizes.
    let anisotropy: Double
    /// Departure from orthogonality, in degrees. Zero for an undistorted raster.
    let shearDegrees: Double
    /// The rotation factor, `R` in `A = R · D`. Orthogonal, determinant +1.
    let rotation: Matrix2
    /// The distortion factor, `D` in `A = R · D`. Symmetric and positive
    /// definite, and it carries the scale: `D = meanPixelSize · correction`.
    ///
    /// Splitting this way is what makes the two halves independently meaningful.
    /// A rotation is a choice of reference frame — harmless, and undone by a
    /// scan-rotation setting. A distortion is a property of the instrument, and
    /// is what actually corrupts a measurement. Reporting a single matrix that
    /// mixes them lets a large rotation disguise a small distortion, and a
    /// "correction" that is really a rotation looks alarming when nothing is
    /// wrong.
    let distortion: Matrix2
    /// The distortion's shape alone, normalised to unit determinant. This is the
    /// form EMPAD-style `scan_correction` matrices take, and it is the identity
    /// exactly when the raster is square and orthogonal — whatever the rotation.
    let correction: Matrix2

    /// Splits `T` into a rotation and a symmetric stretch, `T = R · S`.
    ///
    /// The rotation is what a scan-rotation setting would undo; the symmetric
    /// part is the distortion proper. Keeping them apart matters because a pure
    /// rotation is harmless to a strain measurement while a shear is not.
    init?(transform T: Matrix2) {
        guard abs(T.determinant) > 1e-15 else { return nil }
        self.transform = T

        // S = sqrt(TᵀT), from the eigen-decomposition of the symmetric TᵀT.
        let tt = T.transposed.times(T)
        let trace = tt.a + tt.d
        let det = tt.determinant
        let gap = max(0, trace * trace / 4 - det).squareRoot()
        let eigen1 = trace / 2 + gap
        let eigen2 = trace / 2 - gap
        guard eigen1 > 0, eigen2 > 0 else { return nil }

        let s1 = eigen1.squareRoot()      // principal stretches
        let s2 = eigen2.squareRoot()

        // Eigenvector for eigen1 of the symmetric 2×2 [[a, c], [c, d]].
        let axis: (x: Double, y: Double)
        if abs(tt.c) > 1e-15 {
            axis = (eigen1 - tt.d, tt.c)
        } else {
            axis = tt.a >= tt.d ? (1, 0) : (0, 1)
        }
        let axisLength = max(vectorLength(axis), 1e-300)
        let ux = axis.x / axisLength, uy = axis.y / axisLength

        // S = s1 · uuᵀ + s2 · vvᵀ with v ⟂ u.
        let S = Matrix2(a: s1 * ux * ux + s2 * uy * uy,
                        b: (s1 - s2) * ux * uy,
                        c: (s1 - s2) * ux * uy,
                        d: s1 * uy * uy + s2 * ux * ux)
        guard let inverseS = S.inverse else { return nil }
        let R = T.times(inverseS)

        rotationDegrees = atan2(R.b, R.a) * 180 / .pi
        meanPixelSize = (s1 * s2).squareRoot()
        principalPixelSizes = (s1, s2)
        principalAxisDegrees = atan2(uy, ux) * 180 / .pi
        anisotropy = meanPixelSize > 0 ? (s1 - s2) / meanPixelSize : 0

        // How far the transformed axes depart from a right angle.
        let xAxis = T.apply((1, 0))
        let yAxis = T.apply((0, 1))
        shearDegrees = 90 - abs(angleBetween(xAxis, yAxis))

        // A = R · D exactly, with D the symmetric stretch S.
        rotation = R
        distortion = S
        let scale = meanPixelSize
        correction = scale > 0
            ? Matrix2(a: S.a / scale, b: S.b / scale, c: S.c / scale, d: S.d / scale)
            : S
    }

    /// The same split, with the rotation reduced into the lattice's fundamental
    /// domain.
    ///
    /// A lattice cannot tell you which of its symmetry-equivalent vectors is
    /// "the first one". For a square lattice, the basis the fit happens to
    /// return may be any of four, and the four differ by 90° — so an entirely
    /// unrotated raster reports 90°, or 180°, as readily as 0°. Left alone, that
    /// number is worse than useless in a metadata file: it says the scan was
    /// turned a quarter turn when it was not, and anything downstream that acts
    /// on it will rotate a correct dataset.
    ///
    /// Reducing means re-labelling the ideal basis by a symmetry operation. If
    /// `A = R·D`, then labelling it through a rotation `Rs` of the lattice's own
    /// point group gives `A·Rs = (R·Rs)·(Rsᵀ·D·Rs)` — still a rotation times a
    /// symmetric positive-definite factor, so it is an equally valid
    /// decomposition of an equally valid fit. The distortion keeps its
    /// eigenvalues, so anisotropy and mean pixel size are untouched; only its
    /// principal axes turn with the frame, which is what they should do.
    ///
    /// Among those equivalents the one closest to zero rotation is chosen. That
    /// is a convention, not a measurement — with a symmetric lattice and no
    /// independent knowledge of the crystal's orientation, the absolute rotation
    /// is simply not observable, and the smallest one is the only honest
    /// representative.
    init?(transform T: Matrix2, lattice: KnownLattice) {
        var best: CalibrationDecomposition? = nil
        for degrees in lattice.rotationalSymmetryDegrees {
            let radians = degrees * .pi / 180
            let cosine = cos(radians), sine = sin(radians)
            // Columns: rotating the ideal frame by +degrees.
            let Rs = Matrix2(a: cosine, b: sine, c: -sine, d: cosine)
            guard let candidate = CalibrationDecomposition(transform: T.times(Rs)) else { continue }
            if best == nil || abs(candidate.rotationDegrees) < abs(best!.rotationDegrees) {
                best = candidate
            }
        }
        guard let reduced = best else { return nil }
        self = reduced
    }
}

// MARK: - Known lattice

/// The lattice the user says they are looking at.
struct KnownLattice {
    /// Spacing of the first set of planes, in Å.
    let d1: Double
    /// Spacing of the second set, in Å.
    let d2: Double
    /// Angle between the two lattice vectors, in degrees.
    let angleDegrees: Double

    /// Real-space basis, as columns, in Å. The first vector is placed along +x;
    /// only relative geometry is knowable from an image, so the absolute
    /// orientation is a free choice and this one keeps the arithmetic readable.
    var basis: Matrix2 {
        let radians = angleDegrees * .pi / 180
        return Matrix2(columns: (d1, 0), (d2 * cos(radians), d2 * sin(radians)))
    }

    /// Rotations that map this lattice onto itself, in degrees.
    ///
    /// In two dimensions only orders 1, 2, 3, 4 and 6 are possible, and every
    /// lattice has the 180° one whatever its shape. The rest depend on the cell:
    /// equal spacings at 90° give the square lattice's four-fold axis, and equal
    /// spacings at 60° or 120° give the hexagonal six-fold.
    ///
    /// These are the operations under which a measured basis is indistinguishable
    /// from the ideal one, which is exactly the ambiguity in the fitted rotation.
    var rotationalSymmetryDegrees: [Double] {
        // Loose tolerances on purpose: these are numbers a person typed, so
        // 3.905 and 3.9050001 must both count as equal, and 119.9° as hexagonal.
        let equalSides = abs(d1 - d2) <= 1e-6 * max(d1, d2)
        let angle = abs(angleDegrees)
        func isNear(_ value: Double) -> Bool { return abs(angle - value) < 0.05 }

        if equalSides && isNear(90) {
            return [0, 90, 180, 270]
        }
        if equalSides && (isNear(60) || isNear(120)) {
            return [0, 60, 120, 180, 240, 300]
        }
        return [0, 180]
    }
}

// MARK: - Peaks

struct LatticePeak {
    /// Position relative to the centre, in pixels of the source image.
    let x: Double
    let y: Double
    /// Peak height, for ranking.
    let intensity: Double

    var length: Double { return (x * x + y * y).squareRoot() }
    var vector: (x: Double, y: Double) { return (x, y) }
}

// MARK: - Fitting

enum LatticeFit {

    /// Finds peaks in an image already in reciprocal space.
    ///
    /// - Parameters:
    ///   - image: row-major, `rows * columns` values.
    ///   - centre: the origin peaks are measured from — the undiffracted beam
    ///     for a diffraction pattern, the DC term for a power spectrum.
    ///   - minimumRadius: excludes the origin itself, which is always the
    ///     brightest thing present and is not a lattice vector.
    ///   - maximumRadius: 0 for no limit.
    ///   - relativeThreshold: peaks below this fraction of the strongest are
    ///     treated as noise and dropped.
    ///   - count: how many peaks to keep, **shortest first**.
    ///
    /// Keeping the shortest rather than the strongest is deliberate. The
    /// primitive vectors of a lattice are its shortest independent ones, so
    /// discarding by intensity can throw away the very peaks being looked for.
    /// That is not hypothetical: in a diffraction pattern whose reflections are
    /// of comparable brightness, "the N strongest" is an arbitrary subset, and
    /// picking it silently yields a lattice several times too coarse — with a
    /// calibration that looks perfectly reasonable.
    ///   - locateIn: the image sub-pixel positions are fitted in. Detection and
    ///     localisation want different things: a background-flattened spectrum
    ///     decides what counts as a peak, because significance is local, but
    ///     dividing by a radial background shifts the maximum — the median in a
    ///     peak's own annulus is raised by that peak's skirt, and dividing by
    ///     the bump moves the vertex. Positions are therefore fitted in the
    ///     unflattened spectrum, which is unbiased. Defaults to `image` when the
    ///     two are the same.
    static func findPeaks(image: [Float], rows: Int, columns: Int,
                          centre: (x: Double, y: Double),
                          minimumRadius: Double, maximumRadius: Double,
                          count: Int, relativeThreshold: Double = 0.02,
                          locateIn: [Float]? = nil) -> [LatticePeak] {

        let positions = (locateIn?.count == rows * columns) ? locateIn! : image

        guard rows > 2, columns > 2, image.count >= rows * columns else { return [] }

        let maxR = maximumRadius > 0 ? maximumRadius : Double(max(rows, columns))
        var candidates: [LatticePeak] = []

        // A local maximum over the 8-neighbourhood. Cheap, and adequate because
        // the peaks being looked for are the dominant features by construction.
        for y in 1..<(rows - 1) {
            for x in 1..<(columns - 1) {
                let value = image[y * columns + x]
                guard value.isFinite else { continue }

                let dx = Double(x) - centre.x
                let dy = Double(y) - centre.y
                let r = (dx * dx + dy * dy).squareRoot()
                guard r >= minimumRadius, r <= maxR else { continue }

                // A maximum over the 8-neighbourhood that is not merely a
                // plateau. The second condition is what stops a featureless
                // image being read as a lattice: on flat ground every pixel is
                // "no lower than its neighbours", so without it the search
                // returns adjacent pixels at the exclusion radius and reports a
                // confident calibration from nothing. Ties are still allowed, so
                // a genuine peak whose summit spans two pixels — ordinary in
                // integer counts from a direct detector — is not lost.
                var isPeak = true
                var hasLowerNeighbour = false
                for oy in -1...1 {
                    for ox in -1...1 where !(ox == 0 && oy == 0) {
                        let neighbour = image[(y + oy) * columns + (x + ox)]
                        if neighbour > value { isPeak = false; break }
                        if neighbour < value { hasLowerNeighbour = true }
                    }
                    if !isPeak { break }
                }
                guard isPeak, hasLowerNeighbour else { continue }

                // Sub-pixel position by a parabola through each axis. Fitting
                // the logarithm linearises a Gaussian peak, which is what these
                // are to a good approximation, and removes the bias a plain
                // parabola shows on a peaked profile.
                let refined = refine(image: positions, rows: rows, columns: columns, x: x, y: y)
                candidates.append(LatticePeak(x: refined.x - centre.x,
                                              y: refined.y - centre.y,
                                              intensity: Double(value)))
            }
        }

        // Drop noise, then keep the shortest survivors. Nothing positive means
        // nothing was found, whatever the array length says.
        let strongest = candidates.map { $0.intensity }.max() ?? 0
        guard strongest > 0 else { return [] }
        let floor = strongest * max(0, relativeThreshold)
        var significant = candidates.filter { $0.intensity >= floor }
        significant.sort { $0.length < $1.length }
        return Array(significant.prefix(max(count, 0)))
    }

    /// Sub-pixel peak position from a paraboloid fitted to the neighbourhood.
    ///
    /// Two things this does that a pair of one-dimensional fits does not.
    ///
    /// It carries the cross term, so a peak that is elliptical and tilted — which
    /// is exactly what anisotropic or sheared sampling produces, the case this
    /// plugin exists to measure — is not biased by treating its two axes as
    /// independent.
    ///
    /// And it uses the whole neighbourhood rather than three samples per axis,
    /// so noise on any one sample matters less.
    ///
    /// The fit is to the logarithm, which linearises a Gaussian peak; these are
    /// Gaussian to a good approximation, and on a peaked profile a fit to the
    /// raw values pulls the vertex toward the brighter side.
    private static func refine(image: [Float], rows: Int, columns: Int,
                               x: Int, y: Int, radius: Int = 2) -> (x: Double, y: Double) {

        let fallback = (Double(x), Double(y))
        guard x - radius >= 0, x + radius < columns,
              y - radius >= 0, y + radius < rows else { return fallback }

        // f(u,v) = c0 + c1 u + c2 v + c3 u² + c4 uv + c5 v², by least squares.
        var normal = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        var target = [Double](repeating: 0, count: 6)
        var samples = 0

        for dv in -radius...radius {
            for du in -radius...radius {
                let value = image[(y + dv) * columns + (x + du)]
                guard value > 0, value.isFinite else { continue }
                let u = Double(du), v = Double(dv)
                let basis = [1, u, v, u * u, u * v, v * v]
                let observed = Double(log(value))
                for i in 0..<6 {
                    target[i] += basis[i] * observed
                    for j in 0..<6 { normal[i][j] += basis[i] * basis[j] }
                }
                samples += 1
            }
        }
        guard samples >= 6, let c = solve(normal, target) else { return fallback }

        // Vertex: 2c3 u + c4 v = -c1, c4 u + 2c5 v = -c2.
        let a = 2 * c[3], b = c[4], d = 2 * c[5]
        let determinant = a * d - b * b
        guard abs(determinant) > 1e-12 else { return fallback }
        let u = (-c[1] * d + c[2] * b) / determinant
        let v = (-c[2] * a + c[1] * b) / determinant

        // A maximum, not a saddle or a minimum: the Hessian must be negative
        // definite. And the vertex must lie inside the window it was fitted to,
        // or the fit is extrapolating.
        guard a < 0, determinant > 0,
              abs(u) <= Double(radius), abs(v) <= Double(radius) else { return fallback }

        return (Double(x) + u, Double(y) + v)
    }

    /// Gaussian elimination with partial pivoting, for the small normal
    /// equations above.
    private static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = matrix, b = rhs
        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivot][column]) { pivot = row }
            guard abs(a[pivot][column]) > 1e-14 else { return nil }
            if pivot != column { a.swapAt(pivot, column); b.swapAt(pivot, column) }
            for row in (column + 1)..<n {
                let factor = a[row][column] / a[column][column]
                guard factor != 0 else { continue }
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        return x.allSatisfy { $0.isFinite } ? x : nil
    }

    /// Picks the pair of vectors that best generates the observed peaks.
    ///
    /// Simply taking the two shortest is not enough, and neither is taking the
    /// two strongest. A window's sidelobes put spurious maxima just inside the
    /// true first-order peak, so shortest-first locks onto one of those; and
    /// when reflections are of comparable brightness, strongest-first is an
    /// arbitrary subset that may omit the primitive vectors altogether. Both
    /// mistakes yield a confident lattice that is simply wrong.
    ///
    /// What distinguishes the real basis is that every other peak is an integer
    /// combination of it. So candidate pairs are scored by how much of the
    /// observed set they explain, and the most primitive of the best-scoring
    /// pairs is kept. A sidelobe pair explains almost nothing and loses.
    static func primitiveVectors(from peaks: [LatticePeak],
                                 minimumAngle: Double = 20,
                                 tolerance: Double = 0.2)
        -> (Matrix2, LatticePeak, LatticePeak)? {

        let ordered = peaks.filter { $0.length > 0 }.sorted { $0.length < $1.length }
        guard ordered.count >= 2 else { return nil }

        // Only the shortest handful can be primitive; beyond that the pairs are
        // combinations of vectors already considered.
        let candidates = Array(ordered.prefix(12))

        var candidatesScored: [(Matrix2, LatticePeak, LatticePeak, Double, Double)] = []

        for i in 0..<candidates.count {
            for j in (i + 1)..<candidates.count {
                let first = candidates[i]
                var second = candidates[j]

                let angle = abs(angleBetween(first.vector, second.vector))
                guard angle >= minimumAngle, angle <= 180 - minimumAngle else { continue }

                // Right-handed, so the determinant is positive and the recovered
                // rotation is not reflected.
                if first.x * second.y - first.y * second.x < 0 {
                    second = LatticePeak(x: -second.x, y: -second.y, intensity: second.intensity)
                }
                let basis = Matrix2(columns: first.vector, second.vector)
                guard let inverse = basis.inverse else { continue }

                // How much of the observed intensity sits on this lattice?
                //
                // Weighted by intensity rather than counted, so that a scatter
                // of weak noise maxima cannot outvote the real reflections.
                var explained = 0.0
                for peak in ordered {
                    let coordinates = inverse.apply(peak.vector)
                    let dm = abs(coordinates.x - coordinates.x.rounded())
                    let dn = abs(coordinates.y - coordinates.y.rounded())
                    if dm <= tolerance && dn <= tolerance { explained += peak.intensity }
                }

                let area = abs(basis.determinant)
                guard area > 0 else { continue }
                candidatesScored.append((basis, first, second, explained, area))
            }
        }

        guard let bestScore = candidatesScored.map({ $0.3 }).max(), bestScore > 0 else { return nil }

        // Among the pairs that explain essentially everything, take the one with
        // the LARGEST cell.
        //
        // This is the subtle half. Any lattice finer than the true one — half
        // the spacing, say — also has every observed peak on it, so it scores
        // just as well and can never be ruled out by explanatory power alone.
        // Preferring the smaller cell therefore picks a spurious sublattice
        // whenever noise happens to supply a maximum at a half-order position,
        // and reports a spacing that is a clean fraction of the truth. The true
        // basis is the coarsest lattice containing the peaks, so among equals
        // the largest cell is the right answer.
        let contenders = candidatesScored.filter { $0.3 >= bestScore * 0.98 }
        guard let largestArea = contenders.map({ $0.4 }).max(), largestArea > 0 else { return nil }
        let coarsest = contenders.filter { $0.4 >= largestArea * 0.98 }

        // Finally, the shortest pair among those.
        //
        // A lattice has infinitely many bases of the same determinant — (1,0)
        // with (1,1) generates exactly what (1,0) with (0,1) does, explains the
        // same peaks, and encloses the same area — so the two criteria above
        // cannot separate them, and picking arbitrarily returns a skewed basis
        // that describes the right lattice with the wrong vectors. The reduced
        // basis, the one with the shortest vectors, is the canonical choice.
        guard let chosen = coarsest.min(by: {
            let a = $0.1.length * $0.1.length + $0.2.length * $0.2.length
            let b = $1.1.length * $1.1.length + $1.2.length * $1.2.length
            return a < b
        }) else { return nil }
        return (chosen.0, chosen.1, chosen.2)
    }

    /// Re-fits the basis to every peak the lattice explains.
    ///
    /// The pair chosen above comes from two peaks, so the calibration rests on
    /// two measurements however carefully each was located. Every other peak is
    /// an integer combination of the same basis and constrains it too — and the
    /// far ones constrain it best, since the same absolute error in position is
    /// a smaller relative error over a longer vector.
    ///
    /// Given integer indices (m, n) for each peak, position is linear in the
    /// basis, so this is an ordinary least-squares solve. Indices are reassigned
    /// between passes because a better basis can change what a distant peak is
    /// indexed as.
    static func refineBasis(_ basis: Matrix2, peaks: [LatticePeak],
                            tolerance: Double = 0.2, passes: Int = 3) -> Matrix2? {

        var current = basis

        for _ in 0..<max(1, passes) {
            guard let inverse = current.inverse else { return nil }

            // Index every peak the current basis explains.
            var indexed: [(m: Double, n: Double, x: Double, y: Double, w: Double)] = []
            for peak in peaks {
                let coordinates = inverse.apply(peak.vector)
                let m = coordinates.x.rounded(), n = coordinates.y.rounded()
                guard abs(coordinates.x - m) <= tolerance,
                      abs(coordinates.y - n) <= tolerance,
                      m != 0 || n != 0 else { continue }
                // Weighted by intensity: a bright peak's position is far better
                // determined than a faint one's, and weighting them equally lets
                // the noisiest high orders pull an already-good fit off.
                indexed.append((m, n, peak.x, peak.y, max(peak.intensity, 0)))
            }
            // Two peaks is what we started from; fewer than three adds nothing.
            guard indexed.count >= 3 else { return current }

            // The x and y equations share a design matrix and decouple.
            var mm = 0.0, mn = 0.0, nn = 0.0
            var mx = 0.0, nx = 0.0, my = 0.0, ny = 0.0
            for entry in indexed {
                let w = entry.w
                mm += w * entry.m * entry.m
                mn += w * entry.m * entry.n
                nn += w * entry.n * entry.n
                mx += w * entry.m * entry.x
                nx += w * entry.n * entry.x
                my += w * entry.m * entry.y
                ny += w * entry.n * entry.y
            }
            let determinant = mm * nn - mn * mn
            guard abs(determinant) > 1e-12 else { return current }

            let a1x = (nn * mx - mn * nx) / determinant
            let a2x = (mm * nx - mn * mx) / determinant
            let a1y = (nn * my - mn * ny) / determinant
            let a2y = (mm * ny - mn * my) / determinant

            let refined = Matrix2(columns: (a1x, a1y), (a2x, a2y))
            guard refined.inverse != nil else { return current }
            current = refined
        }
        return current
    }

    /// The real-space lattice, in pixels, implied by a reciprocal basis.
    ///
    /// With reciprocal vectors as the columns of `G` in cycles per pixel, the
    /// real-space basis is `(G⁻¹)ᵀ`. The transpose is the part worth stating:
    /// the reciprocal of a sheared lattice is sheared the other way, and
    /// omitting it leaves the distortion mirrored while the spacings stay right.
    static func realSpaceBasis(fromReciprocal G: Matrix2) -> Matrix2? {
        guard let inverse = G.inverse else { return nil }
        return inverse.transposed
    }

    /// The map from image pixels to the known lattice's units.
    ///
    /// `T = A_known · A_measured⁻¹`, both bases held as columns.
    static func transform(measured: Matrix2, known: Matrix2) -> Matrix2? {
        guard let inverse = measured.inverse else { return nil }
        return known.times(inverse)
    }

    /// Pairs the measured vectors with the known ones the sensible way round.
    ///
    /// The two measured vectors arrive shortest-first, but which known spacing
    /// each corresponds to is not knowable from the image alone when the two
    /// differ. Both pairings are tried and the one whose angle better matches
    /// the known lattice is kept, which is right whenever the lattice is not
    /// close to square — and when it is close to square, the choice barely
    /// matters because the two answers nearly coincide.
    static func bestTransform(measured: Matrix2, known: KnownLattice)
        -> (transform: Matrix2, swapped: Bool)? {

        let straight = known.basis
        let swapped = Matrix2(columns: (known.d2, 0),
                              (known.d1 * cos(known.angleDegrees * .pi / 180),
                               known.d1 * sin(known.angleDegrees * .pi / 180)))

        var best: (Matrix2, Bool, Double)?
        for (candidate, isSwapped) in [(straight, false), (swapped, true)] {
            guard let T = transform(measured: measured, known: candidate),
                  let decomposition = CalibrationDecomposition(transform: T) else { continue }
            // The better pairing is the one needing less distortion to explain.
            let cost = abs(decomposition.anisotropy) + abs(decomposition.shearDegrees) / 90
            if best == nil || cost < best!.2 { best = (T, isSwapped, cost) }
        }
        guard let chosen = best else { return nil }
        return (chosen.0, chosen.1)
    }
}

// MARK: - Power spectrum

/// Turns a real-space image into a centred power spectrum whose peaks are the
/// reciprocal lattice.
///
/// Three things are done before the transform, and each matters:
///
///   * the mean is removed, so the DC term does not swamp everything near it;
///   * a window is applied, because an image is a finite crop of a lattice and
///     the sharp edge of that crop puts a cross through the middle of the
///     spectrum, right where the low-order peaks are;
///   * the result is padded to a length vDSP's DFT accepts, which also
///     interpolates the spectrum and makes peaks easier to locate.
///
/// The window is a genuine trade and worth choosing deliberately. Tapering
/// suppresses the edge cross and the leakage that can bury a weak peak beside a
/// strong one — but it also broadens every peak, because the spectrum is
/// convolved with the window's own transform. A Hann window roughly doubles the
/// peak width against no window at all.
enum PowerSpectrum {

    /// How the image is tapered before transforming.
    enum Window {
        /// No taper. The narrowest peaks available, at the cost of a bright
        /// cross through the origin from the crop edges — which matters most
        /// for a lattice aligned with the raster, whose peaks sit on those very
        /// axes.
        case none
        /// Cosine taper over the outer `fraction` of each axis, flat in the
        /// middle. Near-rectangular peak width with most of the edge artefact
        /// gone, which is usually what this measurement wants.
        case tukey(fraction: Double)
        /// Fully tapered. Cleanest spectrum, widest peaks.
        case hann

        /// The taper for one axis, as a multiplier per sample.
        func weights(count: Int) -> [Float] {
            guard count > 1 else { return [Float](repeating: 1, count: max(count, 0)) }
            var out = [Float](repeating: 1, count: count)
            let last = Double(count - 1)
            switch self {
            case .none:
                break
            case .hann:
                for i in 0..<count {
                    out[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / last))
                }
            case .tukey(let fraction):
                let alpha = Swift.max(0.0, Swift.min(1.0, fraction))
                guard alpha > 0 else { break }
                let taper = alpha * last / 2
                guard taper >= 1 else { break }
                for i in 0..<count {
                    let position = Double(i)
                    if position < taper {
                        out[i] = Float(0.5 - 0.5 * cos(Double.pi * position / taper))
                    } else if position > last - taper {
                        out[i] = Float(0.5 - 0.5 * cos(Double.pi * (last - position) / taper))
                    }
                }
            }
            return out
        }
    }

    /// Lengths vDSP's DFT supports: f · 2ⁿ with f ∈ {1, 3, 5, 15}.
    static func supportedLength(atLeast target: Int) -> Int {
        guard target > 8 else { return 8 }
        var best = Int.max
        for factor in [1, 3, 5, 15] {
            var length = factor * 8
            while length < target { length *= 2 }
            best = Swift.min(best, length)
        }
        return best
    }

    struct Result {
        let values: [Float]        // row-major, magnitude squared
        /// `values` divided by the radially averaged background.
        ///
        /// A real image's spectrum falls steeply away from the origin — the
        /// specimen's non-periodic structure is far brighter than any Bragg
        /// peak — so comparing raw intensities at different radii is
        /// meaningless. Flattening makes a peak's significance local, which is
        /// what "is this a peak" should mean, and is the difference between
        /// finding the lattice and locking onto the low-frequency tail.
        let flattened: [Float]
        let rows: Int
        let columns: Int
        /// Where the DC term sits, in pixels of `values`.
        let centre: (x: Double, y: Double)
        /// Cycles per source pixel, per pixel of this spectrum.
        let frequencyStepX: Double
        let frequencyStepY: Double
    }

    /// The default is the full taper: measured against synthetic lattices it
    /// locates peaks most precisely of the three, and it is the only one that
    /// survives a lattice aligned with the raster, whose peaks sit on the very
    /// axes the untapered edge cross runs along.
    static func make(image: [Float], rows: Int, columns: Int, padFactor: Int = 2,
                     window: Window = .hann) -> Result? {
        guard rows > 4, columns > 4, image.count >= rows * columns else { return nil }

        let paddedRows = supportedLength(atLeast: rows * max(1, padFactor))
        let paddedColumns = supportedLength(atLeast: columns * max(1, padFactor))

        var mean: Float = 0
        vDSP_meanv(image, 1, &mean, vDSP_Length(rows * columns))

        // Separable, so each axis is tapered independently.
        let windowX = window.weights(count: columns)
        let windowY = window.weights(count: rows)

        var real = [Float](repeating: 0, count: paddedRows * paddedColumns)
        var imaginary = [Float](repeating: 0, count: paddedRows * paddedColumns)
        for y in 0..<rows {
            for x in 0..<columns {
                real[y * paddedColumns + x] = (image[y * columns + x] - mean) * windowY[y] * windowX[x]
            }
        }

        guard transform(real: &real, imaginary: &imaginary,
                        rows: paddedRows, columns: paddedColumns) else { return nil }

        // Magnitude squared, shifted so DC lands in the middle.
        var out = [Float](repeating: 0, count: paddedRows * paddedColumns)
        let halfRows = paddedRows / 2, halfColumns = paddedColumns / 2
        for y in 0..<paddedRows {
            let sourceY = (y + halfRows) % paddedRows
            for x in 0..<paddedColumns {
                let sourceX = (x + halfColumns) % paddedColumns
                let re = real[sourceY * paddedColumns + sourceX]
                let im = imaginary[sourceY * paddedColumns + sourceX]
                out[y * paddedColumns + x] = re * re + im * im
            }
        }

        let centre = (x: Double(halfColumns), y: Double(halfRows))
        return Result(values: out,
                      flattened: flatten(out, rows: paddedRows, columns: paddedColumns, centre: centre),
                      rows: paddedRows, columns: paddedColumns,
                      centre: centre,
                      frequencyStepX: 1.0 / Double(paddedColumns),
                      frequencyStepY: 1.0 / Double(paddedRows))
    }

    /// Divides out the radial background.
    ///
    /// The background is the median within each one-pixel annulus rather than
    /// the mean: a mean is pulled up by the very peaks being looked for, so an
    /// annulus carrying a strong reflection would raise its own threshold and
    /// suppress it.
    static func flatten(_ values: [Float], rows: Int, columns: Int,
                        centre: (x: Double, y: Double)) -> [Float] {

        let maximumRadius = Int(ceil((Double(max(rows, columns)) * 0.75))) + 2
        var bins = [[Float]](repeating: [], count: maximumRadius)
        for y in 0..<rows {
            let dy = Double(y) - centre.y
            for x in 0..<columns {
                let dx = Double(x) - centre.x
                let r = Int((dx * dx + dy * dy).squareRoot())
                guard r < maximumRadius else { continue }
                bins[r].append(values[y * columns + x])
            }
        }

        var background = [Float](repeating: 0, count: maximumRadius)
        for r in 0..<maximumRadius where !bins[r].isEmpty {
            var sorted = bins[r]
            sorted.sort()
            background[r] = sorted[sorted.count / 2]
        }
        // A light smoothing across radius, so a single bin cannot carry a notch
        // or a spike of its own into the division.
        if maximumRadius >= 3 {
            var smoothed = background
            for r in 1..<(maximumRadius - 1) {
                smoothed[r] = (background[r - 1] + 2 * background[r] + background[r + 1]) / 4
            }
            background = smoothed
        }
        // Floor the background against the overall scale of the spectrum.
        //
        // Not merely to avoid dividing by zero. On a clean synthetic image the
        // background between peaks *is* transform round-off — a median of 1e-10
        // against peaks of 1e5 — and dividing by that promotes numerical dust
        // into peaks indistinguishable from real ones. A floor proportional to
        // the strongest value keeps the operation scale-free while making it a
        // no-op wherever there is nothing genuine to flatten.
        let strongest = values.max() ?? 1
        let floor = Swift.max(strongest * 1e-8, .leastNormalMagnitude)
        for r in 0..<maximumRadius { background[r] = Swift.max(background[r], floor) }
        let smallest = floor

        // Interpolate between bins rather than dividing by a staircase.
        //
        // A background binned by integer radius is a step function, and dividing
        // by steps manufactures local maxima along every bin boundary — which
        // the peak finder then reports as lattice peaks at radii that are
        // artefacts of the binning. Interpolating removes them.
        var out = [Float](repeating: 0, count: rows * columns)
        for y in 0..<rows {
            let dy = Double(y) - centre.y
            for x in 0..<columns {
                let dx = Double(x) - centre.x
                let r = (dx * dx + dy * dy).squareRoot()
                let level: Float
                let lower = Int(r)
                if lower + 1 < maximumRadius {
                    let t = Float(r - Double(lower))
                    level = background[lower] * (1 - t) + background[lower + 1] * t
                } else {
                    level = lower < maximumRadius ? background[lower] : smallest
                }
                out[y * columns + x] = values[y * columns + x] / Swift.max(level, smallest)
            }
        }
        return out
    }

    /// In-place 2D forward transform, rows then columns.
    private static func transform(real: inout [Float], imaginary: inout [Float],
                                  rows: Int, columns: Int) -> Bool {
        guard let rowSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(columns), .FORWARD),
              let columnSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(rows), .FORWARD)
        else { return false }
        defer {
            vDSP_DFT_DestroySetup(rowSetup)
            vDSP_DFT_DestroySetup(columnSetup)
        }

        var outReal = [Float](repeating: 0, count: max(rows, columns))
        var outImaginary = outReal

        for row in 0..<rows {
            let offset = row * columns
            real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { i in
            outReal.withUnsafeMutableBufferPointer { or in
            outImaginary.withUnsafeMutableBufferPointer { oi in
                vDSP_DFT_Execute(rowSetup, r.baseAddress! + offset, i.baseAddress! + offset,
                                 or.baseAddress!, oi.baseAddress!)
                (r.baseAddress! + offset).update(from: or.baseAddress!, count: columns)
                (i.baseAddress! + offset).update(from: oi.baseAddress!, count: columns)
            }}}}
        }

        var columnReal = [Float](repeating: 0, count: rows)
        var columnImaginary = columnReal
        for column in 0..<columns {
            for row in 0..<rows {
                columnReal[row] = real[row * columns + column]
                columnImaginary[row] = imaginary[row * columns + column]
            }
            columnReal.withUnsafeBufferPointer { cr in
            columnImaginary.withUnsafeBufferPointer { ci in
            outReal.withUnsafeMutableBufferPointer { or in
            outImaginary.withUnsafeMutableBufferPointer { oi in
                vDSP_DFT_Execute(columnSetup, cr.baseAddress!, ci.baseAddress!,
                                 or.baseAddress!, oi.baseAddress!)
            }}}}
            for row in 0..<rows {
                real[row * columns + column] = outReal[row]
                imaginary[row * columns + column] = outImaginary[row]
            }
        }
        return true
    }
}
