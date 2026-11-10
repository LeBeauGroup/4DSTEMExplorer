//
//  MacSTEMScanPath.swift
//  4DSTEM Explorer
//
//  The scan path of a macSTEM acquisition, worked out from its metadata.
//
//  macSTEM drives the beam along a pattern rather than a raster — a Hilbert
//  curve, interleaved sub-rasters, a square spiral — and the EMPAD writes the
//  frames in the order it was triggered and nothing else. Read as a raster such
//  a scan comes out as noise with the right histogram, so the reader has to be
//  told the order.
//
//  It can be told twice over. `scan_positions.npz`, where it exists, holds the
//  position of every frame and is a record of what actually happened. But the
//  patterns here are functions of their name and the size of the image they
//  were drawn on, and the acquisition's own `metadata.toml` records both:
//
//      [instruments.scan_engine]
//      service = "macSTEM"
//      pattern = "hilbert"
//
//      [instruments.scan_engine.scan_path]
//      pattern = "hilbert"
//      n = 128
//      points = 16384
//      kept = [128, 128]
//      settle = 1
//
//  So for those patterns the path need not be chosen, or even saved: it can be
//  recomputed, which is what this does — the same curve macSTEM walks, laid out
//  over the triggers the EMPAD keeps.
//
//  Not every pattern can be. A spiral, a Fibonacci sweep or a Lissajous figure
//  puts the beam between probe positions, and its geometry depends on numbers
//  the metadata does not record (the pitch, the density, the weave), so those
//  still need their positions file. A random order depends on NumPy's own
//  generator. Each is refused by name, with the reason, rather than guessed at:
//  a scan placed by the wrong rule still produces a full image of the right
//  size, and nothing on screen says it is wrong.
//
//  Checked against the one acquisition here that has a positions file as well:
//  over a 128² Hilbert scan the order below agrees with all 16,383 recorded
//  positions exactly, and predicts the same single scan position — (127, 0),
//  the curve's last point — that the recorded positions leave empty.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

/// A macSTEM path scan, and the order its frames go back in.
struct MacSTEMScanPath: Equatable {

    /// A pattern whose point order follows from its name and the size of the
    /// image it was drawn on.
    enum Pattern: Equatable {
        /// Every position once, along a Hilbert curve.
        case hilbert
        /// Every position once, as `step` × `step` interleaved sub-rasters:
        /// every step-th position of every step-th row, then the same shifted
        /// one along. Neighbours in the image are visited a whole sub-raster
        /// apart in time, which is the point of it.
        case interleaved(step: Int)
        /// Every position once, along a square spiral from the centre outwards.
        case squareSpiral
    }

    /// Which pattern, when it is one that can be recomputed.
    let pattern: Pattern
    /// What the file called it, which is what the panel should call it too.
    let name: String
    /// `scan_path.n`: the path was drawn on an `n` × `n` image, and that image
    /// — not the grid of triggers below — is the scan.
    let canvas: Int
    /// `scan_path.kept`: the rectangle of triggers the EMPAD kept, which is the
    /// shape of the RAW file. A path of N points is given a grid of at least N
    /// triggers, so this is usually the canvas and need not be.
    let keptWidth: Int
    let keptHeight: Int
    /// `scan_path.settle`: triggers at the start of each line the beam spends
    /// settling. See `placement()` for what it means for the file.
    let settle: Int
    /// `scan_path.points`, when the file states it: the number of points in the
    /// pattern. Checked against the number computed, not relied upon.
    let declaredPoints: Int?
    /// The metadata file this came from, for the note and the log.
    let source: String

    /// The largest canvas entertained. A scan this far across does not exist,
    /// and the number comes from a file, so it is bounded before it is used to
    /// size an allocation.
    static let largestCanvas = 8192

    /// The scan this path reconstructs: the canvas, which is square.
    var scanWidth: Int { return canvas }
    var scanHeight: Int { return canvas }

    /// What to call the resulting order, in the picker and in the log.
    var label: String { return "\(name), computed from \(source)" }

    // MARK: - Reading the metadata

    /// The pattern names macSTEM writes, and what can be done with each.
    ///
    /// Matched on the name as written, normalised, rather than by substring:
    /// "spiral", "round spiral" and "cav spiral" are three different patterns
    /// and only the first can be recomputed, so a substring match on "spiral"
    /// would be worse than no match at all.
    private enum Known {
        /// An order the reader already has a name for, and does not need this
        /// machinery to reproduce.
        case named(ScanPath)
        case computable(Pattern)
        /// Off the probe lattice: the geometry needs numbers the metadata does
        /// not carry.
        case offGrid
        /// A real order, but not one that follows from the metadata.
        case notDerivable(String)
    }

    private static func known(_ raw: String) -> Known? {
        switch raw.lowercased().filter({ $0.isLetter }) {
        case "raster":
            return .named(.raster)
        case "serpentine":
            return .named(.snake)
        case "hilbert":
            return .computable(.hilbert)
        case "interleaved":
            // macSTEM's own default, and the only step it uses: nothing passes
            // another, and the step is not written down, so a scan made with a
            // different one would be placed wrongly and silently. If a `step`
            // ever appears in the metadata, read it here.
            return .computable(.interleaved(step: 4))
        case "spiral":
            return .computable(.squareSpiral)
        case "roundspiral", "cavspiral", "fibonacci", "lissajous":
            return .offGrid
        case "random":
            return .notDerivable("a random order, which depends on NumPy's own generator")
        case "interleavedraster":
            return .notDerivable("an interleaved line raster, whose pass order is not recorded")
        default:
            return nil
        }
    }

    /// What a macSTEM `metadata.toml` says the scan order was.
    enum Interpretation: Equatable {
        /// An order the reader already has a name for: a plain raster, or a
        /// serpentine. Nothing needs recomputing.
        case named(ScanPath)
        /// An order recomputed from the pattern and the canvas.
        case computed(MacSTEMScanPath)
    }

    /// Reads the scan order out of the fields of a macSTEM `metadata.toml`.
    ///
    /// Nil when the file names no pattern at all. Throws when it names one that
    /// cannot be reproduced: that the file says "cav spiral" and the answer is
    /// "choose the positions file" is worth saying, and is not the same as the
    /// file being silent.
    ///
    /// - Parameters:
    ///   - pattern: `scan_path.pattern`, or the scan engine's `pattern`.
    ///   - canvas: `scan_path.n`.
    ///   - kept: `scan_path.kept`, `[width, height]`. Defaulted to the canvas
    ///     when absent, which is what it is for every even canvas.
    ///   - settle: `scan_path.settle`. Absent is none.
    ///   - points: `scan_path.points`, for checking.
    ///   - source: the file's name, for the note.
    static func interpretation(pattern: String?, canvas: Int?, kept: [Int]?,
                               settle: Int?, points: Int?,
                               source: String) throws -> Interpretation? {
        guard let raw = pattern?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard let known = MacSTEMScanPath.known(raw) else {
            throw Failure.patternUnknown(raw)
        }

        let shape: Pattern
        switch known {
        case .named(let path):         return .named(path)
        case .offGrid:                 throw Failure.offGrid(raw)
        case .notDerivable(let what):  throw Failure.notDerivable(raw, what)
        case .computable(let pattern): shape = pattern
        }

        guard let canvas = canvas, canvas > 0,
              canvas <= MacSTEMScanPath.largestCanvas else {
            throw Failure.noCanvas(raw)
        }
        let grid: (width: Int, height: Int)
        if let kept = kept, kept.count >= 2, kept[0] > 0, kept[1] > 0 {
            grid = (kept[0], kept[1])
        } else {
            grid = (canvas, canvas)
        }

        return .computed(MacSTEMScanPath(pattern: shape, name: raw, canvas: canvas,
                                         keptWidth: grid.width, keptHeight: grid.height,
                                         settle: max(0, settle ?? 0),
                                         declaredPoints: points, source: source))
    }

    // MARK: - The order itself

    /// Every point of the pattern, in the order the beam visits them, as
    /// row-major indices into the `canvas` × `canvas` scan.
    ///
    /// Ported from macSTEM's own `stem.scan.paths` and `stem.scan.spiral`
    /// rather than rederived, including which of the two coordinates it treats
    /// as the row: that choice is invisible in a square scan's point count and
    /// decides whether the image comes out transposed.
    func points() throws -> [Int] {
        let order: [Int]
        switch pattern {
        case .hilbert:
            order = MacSTEMScanPath.hilbert(canvas)
        case .interleaved(let step):
            order = MacSTEMScanPath.interleaved(canvas, step: step)
        case .squareSpiral:
            order = MacSTEMScanPath.squareSpiral(canvas)
        }

        // Every pattern here visits each position exactly once, so the count is
        // known in advance and a mismatch means the port is wrong, not that the
        // file is unusual.
        guard order.count == canvas * canvas else {
            throw Failure.incomplete(name, covered: order.count, of: canvas * canvas)
        }
        // The file's own count, checked rather than trusted. It disagrees when
        // the metadata and the pattern describe different scans — which is the
        // one way this can go wrong without looking wrong.
        if let declared = declaredPoints, declared != order.count {
            throw Failure.pointsDisagree(name, declared: declared, computed: order.count)
        }
        return order
    }

    /// Where every frame of the RAW file belongs.
    ///
    /// The EMPAD is triggered over a grid of `(kept + settle) × (kept + 1)`
    /// points and keeps `kept` of them: it drops the first line, which the beam
    /// spends settling, and the first `settle` triggers of every line after it.
    /// macSTEM then puts the pattern's points on the triggers that survive, in
    /// order, so kept frame *k* is the pattern's point *k*.
    ///
    /// Except that it is point *k* − `settle`. The acquisition checked here has
    /// `settle = 1`, and its recorded positions put the pattern's first point in
    /// frame 1, calling frame 0 "an extra trigger"; the last point then falls
    /// off the end of the file, and the recorded positions leave exactly one
    /// scan position empty, as this does. One acquisition cannot separate
    /// "`settle` frames early" from "always one frame early" — they agree at
    /// `settle = 1` — but `settle` is the quantity that explains it, and it
    /// gives back macSTEM's own arithmetic when there is no settling to do.
    /// Either way the consequence is visible rather than silent: the frames that
    /// hold no point, and the positions that get none, are both counted and
    /// shown.
    func placement() throws -> ScanPlacement {
        let order = try points()
        let frames = keptWidth * keptHeight
        guard frames > settle else {
            throw Failure.noFrames(name, frames: frames, settle: settle)
        }
        guard frames >= order.count else {
            throw Failure.tooFewTriggers(name, frames: frames, points: order.count)
        }

        var slots = [Int?](repeating: nil, count: frames)
        for frame in settle..<frames {
            let point = frame - settle
            guard point < order.count else { break }    // padding after the path
            slots[frame] = order[point]
        }
        // `unfilled` is counted by `ScanPath.explicit`, which is also where the
        // order is checked against the raster the user is opening with.
        return ScanPlacement(slots: slots, unfilled: 0, label: label)
    }

    /// The placement, checked against the scan the user is opening with.
    ///
    /// The canvas is not negotiable: the pattern covers it exactly, so a raster
    /// of any other size cannot hold the path and the mismatch means the
    /// metadata belongs to a different acquisition. Saying so is a good deal
    /// better than placing the frames anyway.
    func placement(width: Int, height: Int) throws -> ScanPlacement {
        guard width == canvas, height == canvas else {
            throw Failure.rasterDisagrees(name, width: width, height: height,
                                          canvas: canvas)
        }
        return try ScanPath.explicit(try placement()).placement(width: width,
                                                                height: height)
    }

    /// The order as a `ScanPath` the reader can be given.
    func scanPath() throws -> ScanPath {
        return .explicit(try placement())
    }

    // MARK: - The patterns

    /// (x, y) of the cells of a 2ⁿ square along the Hilbert curve, the classic
    /// index-to-coordinates construction, with the points outside an `n` × `n`
    /// image skipped — so a size that is not a power of two walks the curve of
    /// the next one up and makes a few longer moves at the edges.
    ///
    /// macSTEM scans `(row, column) = (y, x)`, so the index is `y * n + x`.
    private static func hilbert(_ n: Int) -> [Int] {
        var order = 0
        while (1 << order) < n { order += 1 }
        let side = 1 << order

        var out: [Int] = []
        out.reserveCapacity(n * n)
        for d in 0..<(side * side) {
            var x = 0, y = 0, t = d, s = 1
            while s < side {
                let rx = 1 & (t / 2)
                let ry = 1 & (t ^ rx)
                // Rotate the quadrant where needed.
                if ry == 0 {
                    if rx == 1 {
                        x = s - 1 - x
                        y = s - 1 - y
                    }
                    swap(&x, &y)
                }
                x += s * rx
                y += s * ry
                t /= 4
                s *= 2
            }
            guard x < n, y < n else { continue }
            out.append(y * n + x)
        }
        return out
    }

    /// `step` × `step` interleaved sub-rasters, each sub-raster line by line.
    private static func interleaved(_ n: Int, step requested: Int) -> [Int] {
        let step = max(1, min(requested, n))
        var out: [Int] = []
        out.reserveCapacity(n * n)
        for rowOffset in 0..<step {
            for columnOffset in 0..<step {
                for row in stride(from: rowOffset, to: n, by: step) {
                    for column in stride(from: columnOffset, to: n, by: step) {
                        out.append(row * n + column)
                    }
                }
            }
        }
        return out
    }

    /// A square spiral from the centre outwards: one step right, one down, two
    /// left, two up, three right, … so each turn of it is a square. Points
    /// outside the image are skipped, which is what lets it cover one of any
    /// size.
    private static func squareSpiral(_ n: Int) -> [Int] {
        // Right, down, left, up — x is the column and rows run downwards, so
        // the spiral winds clockwise, as macSTEM's does.
        let steps = [(1, 0), (0, 1), (-1, 0), (0, -1)]
        let centre = (n - 1) / 2
        var column = centre, row = centre

        var out: [Int] = []
        out.reserveCapacity(n * n)
        func take() {
            guard out.count < n * n,
                  row >= 0, row < n, column >= 0, column < n else { return }
            out.append(row * n + column)
        }

        take()
        // Segment k is k / 2 + 1 steps in direction k % 4. Enough of them to
        // pass every corner of the image.
        for segment in 0..<(2 * n + 4) {
            let (dx, dy) = steps[segment % 4]
            for _ in 0...(segment / 2) {
                column += dx
                row += dy
                take()
            }
        }
        return out
    }

    // MARK: - Failures

    enum Failure: LocalizedError, Equatable {
        case notRead
        case rasterDisagrees(String, width: Int, height: Int, canvas: Int)
        case patternUnknown(String)
        case offGrid(String)
        case notDerivable(String, String)
        case noCanvas(String)
        case incomplete(String, covered: Int, of: Int)
        case pointsDisagree(String, declared: Int, computed: Int)
        case noFrames(String, frames: Int, settle: Int)
        case tooFewTriggers(String, frames: Int, points: Int)

        /// The advice every one of these ends with. The positions file is the
        /// way round all of them, and it is usually sitting in the same folder.
        private static let instead = "Choose the scan_positions.npz written beside the scan instead."

        var errorDescription: String? {
            switch self {
            case .notRead:
                return "No acquisition metadata has been read. Use Load Metadata\u{2026} to read the metadata.toml written beside the scan."
            case .rasterDisagrees(let name, let width, let height, let canvas):
                return "The \(name) path covers \(canvas)\u{00D7}\(canvas) scan positions, not \(width)\u{00D7}\(height). Either the scan size or the metadata belongs to a different acquisition."
            case .patternUnknown(let name):
                return "The metadata calls the scan path \u{201C}\(name)\u{201D}, which this does not know how to reproduce. \(Failure.instead)"
            case .offGrid(let name):
                return "A \(name) scan puts the beam between scan positions, and the metadata does not record the geometry it was drawn with. \(Failure.instead)"
            case .notDerivable(let name, let what):
                return "The scan path \u{201C}\(name)\u{201D} is \(what), so it cannot be recomputed. \(Failure.instead)"
            case .noCanvas(let name):
                return "The metadata names a \(name) scan path but not the size of the image it was drawn on (scan_path.n). \(Failure.instead)"
            case .incomplete(let name, let covered, let total):
                return "The \(name) path came out covering \(covered) of \(total) scan positions, which means it was not reproduced correctly. \(Failure.instead)"
            case .pointsDisagree(let name, let declared, let computed):
                return "The metadata says the \(name) path has \(declared) points; recomputing it gives \(computed). The metadata and the pattern do not describe the same scan. \(Failure.instead)"
            case .noFrames(let name, let frames, let settle):
                return "The \(name) path's frame grid holds \(frames) frame\(frames == 1 ? "" : "s"), which is not more than the \(settle) spent settling."
            case .tooFewTriggers(let name, let frames, let points):
                return "The \(name) path has \(points) points but the metadata's frame grid holds only \(frames). The metadata and the pattern do not describe the same scan. \(Failure.instead)"
            }
        }
    }
}
