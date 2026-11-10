//
//  ScanPath.swift
//  4DSTEM Explorer
//
//  Where every frame of an EMPAD RAW file was taken.
//
//  An EMPAD writes frames in the order it was triggered and nothing else: the
//  file is a stack, not a map. For a plain raster that is the same thing, since
//  frame k is probe position k. For any other scan — macSTEM drives Hilbert
//  curves, interleaved sub-rasters, spirals — it is not, and read as a raster
//  the scan comes out as noise with the right histogram.
//
//  macSTEM saves the answer beside the data, as `scan_positions.npz`, and says
//  what it means in its own `description` field:
//
//      Position of every frame of the raw file, in acquisition order; NaN: not
//      at a scan position (frame 0, an extra trigger, and any padding after the
//      path). Relative to the centre of the field of view, in the scan frame
//      (before scan rotation; see metadata.toml).
//
//  Per frame, in acquisition order, is exactly the indexing a reader needs, so
//  this is read rather than recomputed from the pattern's name. That matters
//  more than it looks: the trigger sequence has a settling frame at the front
//  and padding at the back, neither of which is a probe position, so frame k
//  is *not* the path's point k. The positions already account for it; a
//  reimplementation of the pattern would have to rediscover it.
//
//  Two shapes of scan arrive here, and they need different arithmetic:
//
//  - A path that visits each probe position once — hilbert, interleaved, a
//    serpentine — records positions that sit exactly on a pixel grid. The grid
//    can be recovered from the positions alone, so these read on their own.
//  - A path that does not — a round or cav spiral, a fibonacci or Lissajous
//    sweep — records where the beam actually was, in metres, on no grid at all.
//    Those are gridded onto the canvas the path was drawn on, by the same
//    recipe every scanned-probe field settled on: spread each sample through a
//    kernel, accumulate the weights beside the data, divide at the end. See
//    `Gridding`. The canvas itself is in `metadata.toml` (`scan_path.n` and
//    `field_of_view`), not in the archive — see `Canvas`.
//
//  Neither is the same thing as the shape of the file. macSTEM triggers a
//  path's points out over whatever rectangle of triggers holds them, so a
//  128-canvas spiral can be written to disk as 128×100 frames and still
//  reconstruct as a 128×128 image — a disc inscribed in a square. The frame
//  count and the position count are separate numbers throughout.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Accelerate

enum ScanPathError: LocalizedError {
    case unreadable(String)
    case notAnArchive(String)
    case compressed(String)
    case missingPositions(String)
    case unsupportedArray(String, String)
    case offGrid(String)
    case outsideCanvas(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "\(name) could not be read."
        case .notAnArchive(let name):
            return "\(name) is not an NPZ archive."
        case .compressed(let name):
            return "\(name) is a compressed NPZ, which cannot be read yet. Save it with numpy.savez rather than savez_compressed."
        case .missingPositions(let name):
            return "\(name) holds no x and y positions."
        case .unsupportedArray(let name, let detail):
            return "\(name) stores positions as \(detail), which is not supported."
        case .offGrid(let name):
            return "\(name) records positions that do not fall on a pixel grid — a spiral or other off-grid pattern. Placing those needs the field of view and path size from the acquisition's metadata.toml, which was not found beside it. Load Metadata… first, then choose the path again."
        case .outsideCanvas(let detail):
            return "The scan positions do not fit the field of view the metadata describes (\(detail))."
        }
    }
}

/// The scan path of one acquisition: for every frame of the RAW file, the
/// probe position or positions it belongs at.
struct ScanPath {

    /// The scan the path covers, in probe positions.
    let extent: IntSize

    /// Per frame of the RAW file, the nearest probe position as an index into a
    /// row-major `extent` image, or -1 for a frame that is not at a scan
    /// position (the settling frame, the padding after the last point).
    ///
    /// This is the whole answer for a path that visits each position once. For
    /// anything else see `spread`, which is what the reader actually applies.
    let destinations: [Int32]

    /// How each frame's pattern is distributed over probe positions, and what
    /// every position has to be divided by afterwards.
    ///
    /// Nil when the path is a bijection — each frame its own position, nothing
    /// shared and nothing to weigh — which is the common case and the one worth
    /// keeping fast.
    let spread: Spread?

    /// What macSTEM called the pattern — "hilbert", "cav spiral", … Carried for
    /// the interface to show; nothing here depends on it.
    let pattern: String

    /// The RAW file the positions were recorded for, if the archive named one.
    /// Checked against the file being opened rather than assumed.
    let rawFilename: String?

    /// Whether the positions are the probe lattice, rather than samples taken
    /// somewhere across it. True of a raster, a serpentine, a Hilbert curve, an
    /// interleaved sub-raster; false of every spiral.
    let onGrid: Bool

    /// How the positions were put onto the grid.
    let gridding: Gridding

    /// Frames that land somewhere.
    let placed: Int

    /// Frames that do not (NaN, or off the canvas).
    let skipped: Int

    /// Probe positions that come out of this with a pattern in them.
    let filled: Int

    /// Frames that share their nearest probe position with another frame.
    ///
    /// Zero for a path that visits each position once. An off-grid path is
    /// under no such obligation — a constant-angle spiral puts hundreds of
    /// frames in the pixel at its centre — and those frames are averaged
    /// rather than discarded.
    let overwritten: Int

    /// Positions no frame reaches, which stay blank in the reconstruction.
    var blank: Int { return max(0, extent.width * extent.height - filled) }

    /// Whether the reader has to accumulate and divide rather than copy each
    /// frame into place. False for a bijection, where the copy is exact.
    var needsAccumulation: Bool { return spread != nil }

    var summary: String {
        var parts = [pattern.isEmpty ? "scan path" : pattern]
        parts.append("\(extent.width)×\(extent.height)")
        parts.append("\(placed) frames placed")
        if skipped > 0 { parts.append("\(skipped) not at a position") }
        if case .kaiserBessel(let width) = gridding {
            parts.append(String(format: "gridded, %g px Kaiser–Bessel", width))
        } else if overwritten > 0 {
            parts.append("\(overwritten) averaged into a shared position")
        }
        if blank > 0 {
            parts.append("\(blank) \(blank == 1 ? "position" : "positions") with no frame")
        }
        return parts.joined(separator: ", ")
    }

    /// Whether this path is just a row-major raster, in which case reordering
    /// is a copy and the caller may skip it.
    var isRaster: Bool {
        return spread == nil && placed == destinations.count
            && destinations.enumerated().allSatisfy { Int($0.element) == $0.offset }
    }

    // MARK: - Gridding

    /// How a frame's position becomes one or more probe positions.
    ///
    /// Non-raster scans are an old problem in every scanned-probe field, and
    /// the settled answer is gridding: spread each sample over the pixels near
    /// it with a compact kernel, accumulate the kernel weights alongside the
    /// data, and divide at the end. The division is what compensates for
    /// uneven sampling density — MRI calls it gridding the ones, and it is the
    /// reason a spiral's heavily oversampled centre does not simply come out
    /// brighter than its rim. There is no deapodisation step here because
    /// nothing is Fourier transformed afterwards: dividing each pixel by the
    /// weight that landed on it removes the kernel's roll-off directly.
    ///
    /// The electron-microscopy version of this is the same arithmetic with a
    /// box kernel — assign each sample to its nearest pixel and average what
    /// lands together — which is `nearest`.
    enum Gridding: Equatable {
        /// Decide from the positions: `nearest` for a path that is already the
        /// probe lattice, `standard` for one that is not.
        case automatic
        /// One probe position per frame, averaging frames that share one.
        case nearest
        /// A Kaiser–Bessel window `width` probe positions across.
        case kaiserBessel(width: Double)

        /// Two positions across. Wide enough to close the gaps a spiral leaves
        /// between its arms — on macSTEM's 128² fibonacci and cav spiral scans
        /// it fills the sampled disc and nothing beyond it — and no wider,
        /// since every extra pixel of window is resolution given away.
        static let standard = Gridding.kaiserBessel(width: 2)
    }

    /// Where each frame's pattern goes, and what each position is divided by.
    struct Spread {
        /// Frame `k` contributes to `cells[starts[k] ..< starts[k + 1]]` with
        /// the weights at the same offsets. One entry past the last frame.
        let starts: [Int32]
        let cells: [Int32]
        let weights: [Float]

        /// Per probe position, the total weight that landed on it: the
        /// divisor. Zero where nothing did.
        let totals: [Float]

        /// The least weight a position may carry and still be divided by it.
        ///
        /// A pixel the kernel barely grazed would otherwise be a handful of
        /// counts scaled up by a factor of twenty, which is noise presented as
        /// signal. Below this the position is left blank, which is the honest
        /// answer: nothing was measured there.
        static let floor: Float = 1.0 / 16.0

        /// Adds one frame into every probe position its kernel reaches.
        ///
        /// `buffer` holds `stride` floats per probe position, and must start
        /// zeroed. Call this for every frame, then `normalise` once.
        ///
        /// saxpy rather than vDSP_vsma, which is the same arithmetic: measured
        /// over a cav spiral's 101,348 contributions of a 128² frame each,
        /// 0.17 s against 0.46 s. vsma is a three-operand form, so it reads
        /// two arrays and writes a third even where the summand and the
        /// destination are the same memory, as they are here.
        func place(frame: UnsafePointer<Float>, index: Int, stride: Int,
                   into buffer: UnsafeMutablePointer<Float>) {
            guard index >= 0, index + 1 < starts.count else { return }
            for contribution in Int(starts[index])..<Int(starts[index + 1]) {
                let target = buffer + Int(cells[contribution]) * stride
                cblas_saxpy(Int32(stride), weights[contribution], frame, 1, target, 1)
            }
        }

        /// Divides every probe position by the weight that landed on it.
        ///
        /// This is the density compensation, and it is what keeps a spiral's
        /// heavily oversampled centre from simply coming out brighter than its
        /// rim: a position that caught two hundred frames is divided by two
        /// hundred. It doubles as the average over frames that share a
        /// position, and it stands in for the deapodisation the same
        /// arithmetic needs in reciprocal space — dividing each position by
        /// its own weight takes the kernel's roll-off off directly, with
        /// nothing transformed.
        ///
        /// A position the kernel merely grazed is blanked instead. Scaling a
        /// twentieth of one frame up to full brightness would read as a
        /// measurement, and nothing was measured there.
        func normalise(_ buffer: UnsafeMutablePointer<Float>, stride: Int,
                       positions: Int) {
            for position in 0..<min(positions, totals.count) {
                let total = totals[position]
                guard total > 0 else { continue }
                let target = buffer + position * stride
                if total >= Spread.floor {
                    var divisor = total
                    vDSP_vsdiv(target, 1, &divisor, target, 1, vDSP_Length(stride))
                } else {
                    target.update(repeating: 0, count: stride)
                }
            }
        }
    }

    // MARK: - The canvas a path was drawn on

    /// The image an acquisition's scan path was drawn on: a square of `side`
    /// probe positions covering the field of view, centred on it.
    ///
    /// This is the piece the archive does not carry. For a grid path it is not
    /// needed — the positions are the grid — but for anything off-grid it is
    /// the only way to turn metres into probe positions, so it is read from the
    /// `metadata.toml` macSTEM writes in the same folder.
    struct Canvas {
        let side: Int
        let pitchX: Double
        let pitchY: Double

        /// The largest canvas entertained. A scan this far across does not
        /// exist, and the number arrives from a file, so it is bounded before
        /// it is used to size an allocation.
        static let largestSide = 4096

        init?(side: Int?, fieldOfViewMetres fieldOfView: [Double]?) {
            guard let side = side, side > 1, side <= Canvas.largestSide,
                  let extents = fieldOfView,
                  let x = extents.first, x.isFinite, x > 0 else { return nil }
            let y = extents.count > 1 && extents[1].isFinite && extents[1] > 0
                ? extents[1] : x
            self.side = side
            self.pitchX = x / Double(side)
            self.pitchY = y / Double(side)
        }

        init?(_ metadata: ScanMetadata) {
            self.init(side: metadata.scanPathCanvasSide,
                      fieldOfViewMetres: metadata.fieldOfViewMetres)
        }

        /// Read from the `metadata.toml` sitting beside `url`, if there is one.
        ///
        /// macSTEM writes the archive and the metadata into the same folder, so
        /// an off-grid path usually needs nothing asked of the user. Only the
        /// two numbers are taken; the fields the panel shows are left to the
        /// metadata the user loads deliberately.
        static func beside(file url: URL) -> Canvas? {
            let sidecar = url.deletingLastPathComponent()
                .appendingPathComponent("metadata.toml")
            guard FileManager.default.fileExists(atPath: sidecar.path),
                  let metadata = try? ScanMetadata.read(url: sidecar) else { return nil }
            return Canvas(metadata)
        }
    }

    // MARK: - Reading

    /// Reads `scan_positions.npz`.
    ///
    /// - Parameters:
    ///   - url: the archive.
    ///   - canvas: the image the path was drawn on, when the acquisition's
    ///     metadata records it. Given, positions are placed on it, which is the
    ///     only thing that works for an off-grid pattern. Omitted, the
    ///     `metadata.toml` beside the archive is tried, and failing that the
    ///     grid is recovered from the positions themselves — which needs the
    ///     path to be on a grid in the first place.
    ///   - gridding: how to turn a position into probe positions. The default
    ///     decides from the path.
    static func read(url: URL, canvas: Canvas? = nil,
                     gridding: Gridding = .automatic) throws -> ScanPath {
        let name = url.lastPathComponent
        // As `ScanMetadata.read` does: the archive is reached through whatever
        // the open panel handed over, which may be a security-scoped URL.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            throw ScanPathError.unreadable(name)
        }
        let bytes = [UInt8](data)
        let members = try NPZArchive.members(bytes, name: name)

        guard let xRaw = members["x.npy"], let yRaw = members["y.npy"] else {
            throw ScanPathError.missingPositions(name)
        }
        let x = try NPYArray.doubles(xRaw, name: name)
        let y = try NPYArray.doubles(yRaw, name: name)
        guard x.count == y.count, !x.isEmpty else {
            throw ScanPathError.missingPositions(name)
        }

        let pattern = members["pattern.npy"].flatMap { NPYArray.string($0) } ?? ""
        let rawFilename = members["raw_file.npy"].flatMap { NPYArray.string($0) }

        let described = canvas ?? Canvas.beside(file: url)
        let grid: Grid
        if let described = described {
            grid = Grid(canvas: described)
        } else {
            grid = try Grid(deriving: x, y: y, name: name)
        }

        // The lattice coordinate of every frame, once: whole numbers are probe
        // positions, and the gridding below measures its distances in it.
        var lattice = [(u: Double, v: Double)]()
        lattice.reserveCapacity(x.count)
        var positions = 0
        var deviation = 0.0
        var columns = Set<Int>()
        var rows = Set<Int>()
        for k in 0..<x.count {
            guard x[k].isFinite, y[k].isFinite else {
                lattice.append((.nan, .nan))
                continue
            }
            positions += 1
            let point = grid.lattice(x: x[k], y: y[k])
            lattice.append(point)
            deviation = max(deviation,
                            max(abs(point.u - point.u.rounded()),
                                abs(point.v - point.v.rounded())))
            columns.insert(Int(point.u.rounded()))
            rows.insert(Int(point.v.rounded()))
        }

        // Is this path the lattice, or samples taken across it? Both tests
        // matter. A spiral's closest position happens to sit two millionths of
        // a pixel from a whole number, so closeness alone is too delicate to
        // decide on; a grid path also uses no more distinct columns than the
        // grid has, while a spiral uses one per point.
        let onGrid = deviation <= 1e-4
            && columns.count <= grid.width && rows.count <= grid.height

        let resolved: Gridding
        switch gridding {
        case .automatic: resolved = onGrid ? .nearest : .standard
        default: resolved = gridding
        }

        var destinations = [Int32](repeating: -1, count: x.count)
        var starts = [Int32](repeating: 0, count: x.count + 1)
        var cells: [Int32] = []
        var weights: [Float] = []
        var totals = [Float](repeating: 0, count: grid.width * grid.height)
        var claimed = Set<Int32>()
        var placed = 0
        var overwritten = 0
        cells.reserveCapacity(x.count * 4)
        weights.reserveCapacity(x.count * 4)

        let window = Kernel(resolved)
        for k in 0..<x.count {
            starts[k] = Int32(cells.count)
            let point = lattice[k]
            guard point.u.isFinite, point.v.isFinite else { continue }

            if let nearest = grid.index(u: point.u, v: point.v) {
                destinations[k] = Int32(nearest)
                placed += 1
                if !claimed.insert(Int32(nearest)).inserted { overwritten += 1 }
            }

            window.contributions(u: point.u, v: point.v, grid: grid) { cell, weight in
                cells.append(Int32(cell))
                weights.append(Float(weight))
                totals[cell] += Float(weight)
            }
        }
        starts[x.count] = Int32(cells.count)

        // A canvas read from metadata is an outside claim about these numbers,
        // so it is checked against them rather than trusted. Both failures seen
        // in practice are loud here: metadata from a different acquisition puts
        // positions off the canvas, and a field of view in the wrong units
        // collapses the whole scan into one pixel.
        if described != nil {
            guard placed * 100 >= positions * 99 else {
                throw ScanPathError.outsideCanvas(
                    "\(positions - placed) of \(positions) positions fall outside "
                    + "\(grid.width)×\(grid.height)")
            }
            guard claimed.count > 1 else {
                throw ScanPathError.outsideCanvas(
                    "every position lands in the same pixel, so the field of view "
                    + "and the positions are not in the same units")
            }
        }

        let filled = totals.reduce(0) { $0 + ($1 >= Spread.floor ? 1 : 0) }
        // Nothing to accumulate when each frame owns its position outright: the
        // reader can copy, which is both faster and exact.
        let isBijection = resolved == .nearest && overwritten == 0
            && weights.allSatisfy { $0 == 1 }
        let spread = isBijection ? nil : Spread(starts: starts, cells: cells,
                                                weights: weights, totals: totals)

        return ScanPath(extent: IntSize(width: grid.width, height: grid.height),
                        destinations: destinations,
                        spread: spread,
                        pattern: pattern,
                        rawFilename: rawFilename,
                        onGrid: onGrid,
                        gridding: resolved,
                        placed: placed,
                        skipped: x.count - placed,
                        filled: filled,
                        overwritten: overwritten)
    }

    /// The archive macSTEM writes beside a RAW file, if it is there.
    ///
    /// Matched by name when the archive records one, so the path of one
    /// acquisition is not quietly applied to another sitting in the same folder.
    static func beside(rawFile url: URL) -> URL? {
        let candidate = url.deletingLastPathComponent()
            .appendingPathComponent("scan_positions.npz")
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }
}

// MARK: - The gridding kernel

/// The window a sample is spread through, and the only place the choice of
/// kernel lives.
private struct Kernel {
    /// Half the window, in probe positions. Zero for nearest-position.
    let radius: Double
    /// The Kaiser–Bessel shape parameter, and `nil` for a box.
    let beta: Double?
    /// 1 / I₀(β), folded in so the peak of the window is 1.
    let normalisation: Double

    init(_ gridding: ScanPath.Gridding) {
        switch gridding {
        case .kaiserBessel(let width) where width > 1:
            // β from the width, after Beatty, Nishimura and Pauly's expression
            // for an oversampling ratio of two — the ratio that reduces to the
            // classic Jackson window. The criterion it optimises is aliasing
            // after the transform, which is not what happens here, but it is
            // the shape the field settled on and it is a good window.
            let b = Double.pi * ((width / 2) * (width / 2) * 2.25 - 0.8).squareRoot()
            self.radius = width / 2
            self.beta = b
            self.normalisation = 1 / besselI0(b)
        default:
            self.radius = 0
            self.beta = nil
            self.normalisation = 1
        }
    }

    /// Calls `body` for every probe position this sample reaches, with the
    /// weight it reaches it with. Separable, as gridding kernels normally are:
    /// the two axes are weighed independently and multiplied.
    func contributions(u: Double, v: Double, grid: Grid,
                       _ body: (Int, Double) -> Void) {
        guard let beta = beta else {
            // The box: the nearest position, weight one. Averaging several
            // frames that land on one position is then what the divisor does.
            if let cell = grid.index(u: u, v: v) { body(cell, 1) }
            return
        }

        let reach = Int(radius.rounded(.up))
        let centreColumn = Int(u.rounded())
        let centreRow = Int(v.rounded())
        for row in (centreRow - reach)...(centreRow + reach) {
            guard row >= 0, row < grid.height else { continue }
            let weightV = profile(v - Double(row), beta: beta)
            guard weightV > 0 else { continue }
            for column in (centreColumn - reach)...(centreColumn + reach) {
                guard column >= 0, column < grid.width else { continue }
                let weightU = profile(u - Double(column), beta: beta)
                guard weightU > 0 else { continue }
                body(row * grid.width + column, weightU * weightV)
            }
        }
    }

    /// A Kaiser–Bessel window does not taper to zero at the edge of its
    /// support — it ends at 1/I₀(β), a tenth of its peak for a two-pixel
    /// window — so whether a sample sitting exactly that far from a position
    /// counts is a real difference, not a rounding detail. A grid path puts
    /// samples exactly one position apart, where the division below lands a
    /// few ulps either side of the edge, so without this slack the same scan
    /// keeps some of those contributions and drops others on nothing more than
    /// floating-point luck.
    private static let slack = 1e-9

    private func profile(_ distance: Double, beta: Double) -> Double {
        guard abs(distance) <= radius + Kernel.slack else { return 0 }
        let scaled = min(1, abs(distance) / radius)
        let argument = beta * (1 - scaled * scaled).squareRoot()
        return besselI0(argument) * normalisation
    }
}

/// The modified Bessel function of the first kind, order zero.
///
/// Summed as it is defined, ∑ ((x/2)ᵏ / k!)². The argument never exceeds the
/// window's β — under seven for any width worth using — where a dozen terms
/// are already at the limit of a Double.
private func besselI0(_ x: Double) -> Double {
    let half = x / 2
    var term = 1.0
    var sum = 1.0
    for k in 1...40 {
        term *= half / Double(k)
        let contribution = term * term
        sum += contribution
        if contribution <= 1e-18 * sum { break }
    }
    return sum
}

// MARK: - The grid the positions fall on

/// Turns a position in metres into a probe position.
///
/// The lattice is the one the grid patterns use, and they pin it exactly:
/// across macSTEM's Hilbert and interleaved scans every recorded position sits
/// on a whole number of pitches from the centre of the field of view, to the
/// last bit of a Double. So probe position *p* is at lattice coordinate *p*,
/// and the position nearest a sample is the nearest whole number — not the
/// pixel a sample falls inside, which would be half a position off.
private struct Grid {
    let width: Int
    let height: Int
    let stepX: Double
    let stepY: Double
    let originX: Double
    let originY: Double

    /// Half a pixel: how far off a grid point a position may sit and still be
    /// taken as that point, when the grid is being recovered from the positions
    /// themselves. They come off a DAC, so in practice they are exact, and
    /// anything further out is a sign that the pitch is wrong rather than that
    /// the beam wandered.
    private static let tolerance = 0.25

    /// The largest grid worth believing in. A pitch derived from floating-point
    /// noise rather than from a real pixel spacing gives a grid millions of
    /// positions across, and allocating one frame per position would take the
    /// machine down long before the arithmetic was questioned.
    private static let largestSide = ScanPath.Canvas.largestSide

    /// The grid the acquisition's own metadata describes.
    ///
    /// Positions are relative to the centre of the field of view, so position
    /// zero is half a canvas to the left of it.
    init(canvas: ScanPath.Canvas) {
        self.width = canvas.side
        self.height = canvas.side
        self.stepX = canvas.pitchX
        self.stepY = canvas.pitchY
        self.originX = -Double(canvas.side) / 2 * canvas.pitchX
        self.originY = -Double(canvas.side) / 2 * canvas.pitchY
    }

    /// The grid the positions themselves describe: the pitch is the smallest
    /// step between neighbouring columns, and the extent follows from how far
    /// they reach.
    ///
    /// This needs the path to touch every row and column, which the patterns
    /// that visit each position once all do. An off-grid path does not, and
    /// gives no pitch to find — the smallest gap between two of its positions
    /// is however close two arbitrary reals happened to fall — so it is
    /// refused here and sent to look for metadata instead.
    init(deriving x: [Double], y: [Double], name: String) throws {
        let finiteX = x.filter { $0.isFinite }
        let finiteY = y.filter { $0.isFinite }
        guard !finiteX.isEmpty, !finiteY.isEmpty else {
            throw ScanPathError.missingPositions(name)
        }

        let step = try Grid.pitch(of: finiteX, or: finiteY, name: name)
        let minX = finiteX.min()!, minY = finiteY.min()!
        let spanX = (finiteX.max()! - minX) / step
        let spanY = (finiteY.max()! - minY) / step
        guard spanX < Double(Grid.largestSide), spanY < Double(Grid.largestSide) else {
            throw ScanPathError.offGrid(name)
        }

        self.width = Int(spanX) + 1
        self.height = Int(spanY) + 1
        self.stepX = step
        self.stepY = step
        self.originX = minX
        self.originY = minY
        guard fits(x: finiteX, y: finiteY) else {
            throw ScanPathError.offGrid(name)
        }
    }

    /// The smallest distance between two distinct coordinates, which for a grid
    /// path is one pixel.
    private static func pitch(of x: [Double], or y: [Double],
                              name: String) throws -> Double {
        for axis in [x, y] {
            let sorted = Set(axis.map { ($0 * 1e15).rounded() }).sorted()
            guard sorted.count > 1 else { continue }
            var smallest = Double.greatestFiniteMagnitude
            for i in 1..<sorted.count {
                smallest = min(smallest, (sorted[i] - sorted[i - 1]) / 1e15)
            }
            if smallest > 0, smallest < .greatestFiniteMagnitude { return smallest }
        }
        throw ScanPathError.offGrid(name)
    }

    /// Whether every position lands on this grid.
    private func fits(x: [Double], y: [Double]) -> Bool {
        for value in x where !onAxis(value, origin: originX, step: stepX, count: width) {
            return false
        }
        for value in y where !onAxis(value, origin: originY, step: stepY, count: height) {
            return false
        }
        return true
    }

    private func onAxis(_ value: Double, origin: Double, step: Double,
                        count: Int) -> Bool {
        let cell = (value - origin) / step
        guard abs(cell - cell.rounded()) <= Grid.tolerance else { return false }
        let index = Int(cell.rounded())
        return index >= 0 && index < count
    }

    /// A position's coordinate on the probe lattice, where whole numbers are
    /// probe positions.
    ///
    /// Divided before the origin is taken off, rather than after: for the
    /// canvas grid the origin is a whole number of pitches, so this way a grid
    /// path's positions come out as whole numbers to the last bit, while
    /// `(x - origin) / step` rounds twice and lands beside them.
    func lattice(x: Double, y: Double) -> (u: Double, v: Double) {
        return (x / stepX - originX / stepX, y / stepY - originY / stepY)
    }

    /// The row-major index of the probe position nearest a lattice coordinate,
    /// or nil if that position is off the grid.
    ///
    /// Ties — a sample exactly between two positions — go to the even one,
    /// which is numpy's rule and so the one that makes this agree with a
    /// reconstruction written in Python. They are not rare or academic: a
    /// constant-angle spiral crosses the middle row of a 128² canvas at
    /// exactly 64.5, 66.5, … and 32 of macSTEM's cav spiral frames land on
    /// one. Rounding away from zero instead would send every one of them to
    /// the higher column, which is a bias rather than a choice. With a kernel
    /// the question does not arise: both positions are equidistant, so both
    /// get the same weight.
    func index(u: Double, v: Double) -> Int? {
        guard u.isFinite, v.isFinite else { return nil }
        let column = u.rounded(.toNearestOrEven)
        let row = v.rounded(.toNearestOrEven)
        guard column >= 0, column < Double(width),
              row >= 0, row < Double(height) else { return nil }
        return Int(row) * width + Int(column)
    }
}
