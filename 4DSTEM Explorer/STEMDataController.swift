//
//  STEMData.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/21/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Cocoa
import Accelerate

enum FileReadError: Error {
    case invalidTiff
    case invalidRaw
    case invalidDimensions
    case notDiffractionSI
}

enum DataType {
    case uint32
    case float32
    case int16
    case uint8
    case uint16
    case bool
    case unknown // for default handling

    /// The candidates the RAW reader considers, most likely first.
    static let rawCandidates: [DataType] = [.float32, .uint16, .int16, .uint8, .uint32]

    /// The first RAW candidate of this size. Sizes do not identify a type —
    /// int16 and uint16 share one — so the reader's own order decides, which is
    /// the order it has always used.
    static func rawCandidate(elementSize: Int) -> DataType? {
        return rawCandidates.first { $0.elementSize == elementSize }
    }

    var elementSize: Int {
        switch self {
        case .uint32: return MemoryLayout<UInt32>.size
        case .float32: return MemoryLayout<Float32>.size
        case .int16: return MemoryLayout<Int16>.size
        case .uint8: return MemoryLayout<UInt8>.size
        case .uint16: return MemoryLayout<UInt16>.size
        case .bool: return MemoryLayout<Bool>.size
        case .unknown: return MemoryLayout<Float32>.size
        }
    }
}


protocol STEMDataControllerDelegate:class {
    func didFinishLoadingData()->(pattern:NSImage?, virtual:NSImage?)
    func didFailLoadingData(_ error: Error)
}

extension STEMDataControllerDelegate {
    func didFailLoadingData(_ error: Error) { }
}

protocol STEMDataControllerProgressDelegate:class {
    func cancel(_ sender:Any)
}

/// A 2×2 scan correction, in the sense `[x', y'] = M · [x, y]`.
///
/// Stored row-major because that is how it is written and read — EMPAD metadata
/// records `scan_correction` as `[[m00, m01], [m10, m11]]` with exactly this
/// meaning, and keeping one convention from the file through to the arithmetic
/// removes the transpose that otherwise has to be remembered at each boundary.
struct ScanCorrection: Equatable {
    var m00: Float, m01: Float
    var m10: Float, m11: Float

    static let identity = ScanCorrection(m00: 1, m01: 0, m10: 0, m11: 1)

    var isIdentity: Bool {
        return abs(m00 - 1) < 1e-6 && abs(m11 - 1) < 1e-6
            && abs(m01) < 1e-6 && abs(m10) < 1e-6
    }

    /// Row-major, as the JSON records it.
    var rows: [[Float]] { return [[m00, m01], [m10, m11]] }

    init(m00: Float, m01: Float, m10: Float, m11: Float) {
        self.m00 = m00; self.m01 = m01; self.m10 = m10; self.m11 = m11
    }

    init?(rowMajor values: [Float]) {
        guard values.count == 4, values.allSatisfy({ $0.isFinite }) else { return nil }
        self.init(m00: values[0], m01: values[1], m10: values[2], m11: values[3])
    }
}

/// How the raw diffraction patterns are oriented on the detector.
///
/// This is EMPAD metadata's `det_flips`, in its order and its meaning: the
/// operations to apply when *reading* the raw file, `(flip_y, flip_x, transpose)`.
/// The application's own RAW transforms are the same three flags, so the two are
/// the same quantity and are kept as one rather than converted between.
///
/// `(true, false, false)` is the usual EMPAD orientation and the application's
/// default, which is why it is named rather than left as a bare triple.
struct DetectorFlips: Equatable {
    var flipY: Bool
    var flipX: Bool
    var transpose: Bool

    static let empadDefault = DetectorFlips(flipY: true, flipX: false, transpose: false)
    /// Deliberately not called `none`. This type is almost always held as
    /// `DetectorFlips?`, and in that context `.none` is `Optional.none` — so
    /// `detectorFlips: .none` would silently mean "not recorded" rather than
    /// "recorded as unflipped", which are opposite things to a reader that
    /// defaults a missing field to flipping in y.
    static let unflipped = DetectorFlips(flipY: false, flipX: false, transpose: false)

    /// As the JSON records it: `[flip_y, flip_x, transpose]`.
    var triple: [Bool] { return [flipY, flipX, transpose] }

    init(flipY: Bool, flipX: Bool, transpose: Bool) {
        self.flipY = flipY; self.flipX = flipX; self.transpose = transpose
    }

    init?(triple values: [Bool]) {
        guard values.count == 3 else { return nil }
        self.init(flipY: values[0], flipX: values[1], transpose: values[2])
    }

    var summary: String {
        var parts: [String] = []
        if flipY { parts.append("flip y") }
        if flipX { parts.append("flip x") }
        if transpose { parts.append("transpose") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}

/// Where each stored frame belongs in the raster.
///
/// The result of resolving a `ScanPath` against a scan size, and what the read
/// loop actually works from.
struct ScanPlacement: Equatable {
    /// `slots[k]` is the row-major scan position of the k-th stored frame, or
    /// nil for a frame that was not taken at a scan position at all.
    ///
    /// That second case is real and not an error: a scan controller writes a
    /// frame while the beam is settling or flying back, and the positions file
    /// records it as NaN. Such a frame is read — it occupies its place in the
    /// file and everything after it depends on that — and then discarded.
    var slots: [Int?]
    /// Scan positions that no frame landed on. They are left as zero.
    var unfilled: Int
    /// What this came from, for the panel and for the log.
    var label: String
    /// How each frame is spread over scan positions, for an off-grid path.
    ///
    /// Nil for every path that puts each frame on a position of its own, which
    /// is all of them but the spirals: `slots` is then the whole answer and
    /// the read copies. Set, the read accumulates each frame into every
    /// position its kernel reaches and divides by the weight at the end, and
    /// `slots` is only the nearest position, for counting. See `GriddedScan`.
    ///
    /// Declared last so the memberwise initialiser can leave it out.
    var spread: GriddedScan.Spread? = nil

    /// How many frames the file is expected to hold.
    ///
    /// The raster does not answer this. A scan with settling frames in it has
    /// more frames than positions, and reading `width × height` of them would
    /// stop short and leave the tail of the scan empty.
    var frameCount: Int { return slots.count }

    /// How many frames are placed, rather than discarded.
    var placedCount: Int { return slots.reduce(0) { $1 == nil ? $0 : $0 + 1 } }

    /// Nothing to do: the k-th frame is already the k-th scan position.
    var isIdentity: Bool {
        guard unfilled == 0, spread == nil else { return false }
        for (index, slot) in slots.enumerated() where slot != index { return false }
        return true
    }
}

/// The order in which the stored frames were acquired across the raster.
///
/// A RAW file is a bare sequence of diffraction patterns. Nothing in it records
/// which probe position each one came from, so the reader has to be told — and
/// it used to assume one answer without asking: a row-major raster with every
/// row written in the same direction. That is the common case, not the only
/// one. A scan controller that does not fly back writes alternate rows in
/// reverse, one stepping along the slow axis first writes columns, and a
/// space-filling scan — a Hilbert curve, say — writes an order that cannot be
/// named at all, only enumerated.
///
/// Getting it wrong is quiet, which is the reason this is worth choosing
/// explicitly. A serpentine scan read as a raster still produces a complete
/// image of the right size and the right statistics; every other row is simply
/// mirrored. On a featureless region, or at a magnification where the scan is
/// finer than the features, that can pass for the real thing.
///
/// The ordering is applied as the file is read, so everything downstream — the
/// pattern at (i, j), the computed images, the plugins, the exports — sees a
/// plain row-major raster and needs to know nothing about any of this. The
/// cost is that changing the path means reading the file again, which is the
/// same bargain the detector transforms already make.
enum ScanPath: Equatable {
    /// Row-major, every row in the same direction. The usual case, and what
    /// the reader assumed before this was a choice.
    case raster
    /// Row-major, alternate rows reversed. Row 0 runs forwards.
    case snake
    /// Column-major, every column in the same direction.
    case columnRaster
    /// Column-major, alternate columns reversed. Column 0 runs downwards.
    case columnSnake
    /// An order that has to be enumerated, from a scan-positions file.
    case explicit(ScanPlacement)

    /// The four orders that can be named rather than enumerated.
    static let namedCases: [ScanPath] = [.raster, .snake, .columnRaster, .columnSnake]

    /// For the picker and the status line.
    var name: String {
        switch self {
        case .raster:       return "Raster (row by row)"
        case .snake:        return "Snake (alternate rows reversed)"
        case .columnRaster: return "Raster (column by column)"
        case .columnSnake:  return "Snake (alternate columns reversed)"
        case .explicit(let placement):
            return placement.label.isEmpty ? "From positions file" : placement.label
        }
    }

    /// The value written to, and read back from, a metadata sidecar.
    ///
    /// Nil for an explicit order: it cannot be reconstructed from a name, and
    /// writing a marker a reader cannot act on would be worse than writing
    /// nothing — it would look like the path had been recorded.
    var metadataName: String? {
        switch self {
        case .raster:       return "raster"
        case .snake:        return "snake"
        case .columnRaster: return "column_raster"
        case .columnSnake:  return "column_snake"
        case .explicit:     return nil
        }
    }

    /// How many frames the file holds, when the path knows.
    ///
    /// Only an explicit path does. The named ones say nothing beyond the
    /// raster, which the caller already has.
    var frameCount: Int? {
        switch self {
        case .explicit(let placement): return placement.frameCount
        default: return nil
        }
    }

    /// Reads a path out of whatever a sidecar happened to call it.
    ///
    /// Matching is by substring on a normalised string rather than against a
    /// fixed vocabulary, for the same reason the rest of the metadata reader
    /// works by synonym: writers agree on the idea and disagree on the spelling.
    /// A string naming no order at all returns nil, so an unrecognised value —
    /// `hilbert`, which no name can express — leaves the choice where the user
    /// put it instead of silently becoming a raster.
    init?(metadataName raw: String) {
        let text = raw.lowercased().filter { $0.isLetter }
        guard !text.isEmpty else { return nil }

        let serpentine = ["snake", "serpentine", "boustrophedon", "zigzag",
                          "bidirectional", "backandforth"]
        let columnwise = ["column", "columnmajor", "vertical", "fortran"]
        let rowwise = ["raster", "row", "rowmajor", "horizontal", "unidirectional",
                       "linear", "sequential"]

        let isSerpentine = serpentine.contains { text.contains($0) }
        let isColumnwise = columnwise.contains { text.contains($0) }

        if isSerpentine {
            self = isColumnwise ? .columnSnake : .snake
        } else if isColumnwise {
            self = .columnRaster
        } else if rowwise.contains(where: { text.contains($0) }) {
            self = .raster
        } else {
            return nil
        }
    }

    /// Where each stored frame goes, over a raster of the given size.
    ///
    /// A named order is a full permutation by construction. An explicit one is
    /// checked: an index outside the raster, or two frames claiming the same
    /// position, means the path and the scan do not belong together, and
    /// finding that out here is a great deal better than reading the file into
    /// a scrambled image. Positions nothing lands on are permitted and counted
    /// — a scan can genuinely miss one — and left as zero.
    func placement(width: Int, height: Int) throws -> ScanPlacement {
        guard width > 0, height > 0 else { throw Failure.emptyRaster }
        let count = width * height

        func named(_ slots: [Int]) -> ScanPlacement {
            return ScanPlacement(slots: slots.map { Optional($0) }, unfilled: 0, label: name)
        }

        switch self {
        case .raster:
            return named(Swift.Array(0..<count))

        case .snake:
            return named((0..<count).map { k in
                let y = k / width
                let i = k % width
                let x = y.isMultiple(of: 2) ? i : width - 1 - i
                return y * width + x
            })

        case .columnRaster:
            return named((0..<count).map { k in
                let x = k / height
                let y = k % height
                return y * width + x
            })

        case .columnSnake:
            return named((0..<count).map { k in
                let x = k / height
                let i = k % height
                let y = x.isMultiple(of: 2) ? i : height - 1 - i
                return y * width + x
            })

        case .explicit(let placement):
            // A gridded path spreads frames over shared positions on purpose,
            // and counted its own empty ones when it was gridded.
            if let spread = placement.spread {
                guard spread.totals.count == count else {
                    throw Failure.outOfRange(position: spread.totals.count, limit: count)
                }
                return placement
            }
            var seen = [Bool](repeating: false, count: count)
            for slot in placement.slots {
                guard let slot = slot else { continue }
                guard slot >= 0, slot < count else {
                    throw Failure.outOfRange(position: slot, limit: count)
                }
                guard !seen[slot] else {
                    throw Failure.repeated(position: slot, x: slot % width, y: slot / width)
                }
                seen[slot] = true
            }
            var checked = placement
            checked.unfilled = seen.reduce(0) { $1 ? $0 : $0 + 1 }
            return checked
        }
    }

    enum Failure: LocalizedError, Equatable {
        case emptyRaster
        case noRaster
        case outOfRange(position: Int, limit: Int)
        case repeated(position: Int, x: Int, y: Int)
        case noPositions(String)
        case lopsided(String, x: Int, y: Int)
        case tooFewPositions(String, found: Int)
        case notAGrid(String, axis: String, found: Int, expected: Int)

        var errorDescription: String? {
            switch self {
            case .emptyRaster:
                return "The scan has no positions in it."
            case .noRaster:
                return "Enter the scan size before choosing a positions file, or let the file fill it in."
            case .outOfRange(let position, let limit):
                return "The positions file puts a frame at scan position \(position), which is outside the scan — the last position is \(limit - 1)."
            case .repeated(_, let x, let y):
                return "The positions file puts two frames at (\(x), \(y)). Each scan position can hold only one."
            case .noPositions(let name):
                return "\(name) has no x and y arrays in it. A scan-positions file holds one position per frame of the raw file, in acquisition order."
            case .lopsided(let name, let x, let y):
                return "\(name) has \(x) x values and \(y) y values; a position needs both."
            case .tooFewPositions(let name, let found):
                return found == 0
                    ? "\(name) records no frame as being at a scan position — every position in it is NaN."
                    : "\(name) records only \(found) frame\(found == 1 ? "" : "s") as being at a scan position, which is not enough to work out the raster."
            case .notAGrid(let name, let axis, let found, let expected):
                return "\(name) spreads its frames over \(found) distinct \(axis) position\(found == 1 ? "" : "s"), but the scan is \(expected) wide along \(axis). The file and the scan size do not describe the same scan."
            }
        }
    }
}

/// A scan-positions file: where every frame of a RAW scan was actually taken.
///
/// This is what acquisition writes alongside a scan whose order cannot be
/// named — the `.npz` holding `x` and `y`, one entry per frame of the raw file
/// in acquisition order, with the units, the raw file's name and the pattern's
/// name as text members of the same archive. A NaN position marks a frame that
/// was not at a scan position at all.
///
/// The positions are physical, relative to the centre of the field of view, in
/// the scan frame and before any scan rotation. Nothing here needs them to be:
/// the placement only depends on where each frame sits on the grid, which is
/// why it is worked out by normalising the extent rather than by trusting the
/// units. The units are read all the same, because the spacing they give is the
/// scan step, and that is a calibration the user would otherwise type in.
struct ScanPositions: Equatable {

    /// Metres, in acquisition order. NaN where the frame was not at a scan
    /// position.
    var x: [Double]
    var y: [Double]
    /// The pattern's own name, when the file gives one — `hilbert`, `snake`.
    /// Shown rather than interpreted: a name is not a placement, and the arrays
    /// are the authority on where the frames went.
    var pattern: String?
    /// The raw file these positions belong to, when the file says. Checked
    /// against the file being opened, because a positions file paired with the
    /// wrong scan is the one mistake here that produces a plausible image.
    var rawFile: String?
    /// The file's own account of itself, if it has one.
    var summaryText: String?
    /// The positions file's name.
    var label: String
    /// The unit the positions were written in, as the file spells it.
    ///
    /// Declared last so the memberwise initialiser can leave it out: it is set
    /// after the rest by `interpret`, which has to look it up separately.
    var unit: String? = nil
    /// The image the path was drawn on, from the `metadata.toml` beside the
    /// positions file, when there is one. Only an off-grid path needs it: it
    /// is the only way to turn the metres such a path records into probe
    /// positions. See `GriddedScan.Canvas`.
    var canvas: GriddedScan.Canvas? = nil

    var frameCount: Int { return x.count }

    /// Frames that were at a scan position.
    var placedCount: Int {
        var total = 0
        for index in 0..<x.count where x[index].isFinite && y[index].isFinite { total += 1 }
        return total
    }

    // MARK: Reading

    /// The member names the x and y arrays answer to.
    ///
    /// `x`/`y` first, as written by the acquisition this exists for, then the
    /// spellings a script is likely to have used instead.
    private static let xNames = ["x", "x_m", "xs", "pos_x", "positions_x", "scan_x", "px"]
    private static let yNames = ["y", "y_m", "ys", "pos_y", "positions_y", "scan_y", "py"]

    static func read(contentsOf url: URL) throws -> ScanPositions {
        let name = url.lastPathComponent
        let arrays = try NumpyReader.arrays(contentsOf: url)
        var positions = try interpret(arrays, label: name)
        positions.canvas = GriddedScan.Canvas.beside(file: url)
        return positions
    }

    // MARK: Off the grid

    /// The positions gridded onto the canvas, when they are off the probe
    /// lattice — a round or cav spiral, a fibonacci sweep.
    ///
    /// Nil for a path on the lattice, which `placement` places exactly, one
    /// frame to a position, and nil without a canvas, which leaves an off-grid
    /// file to fail the grid check with its own explanation.
    func offGridScan() throws -> GriddedScan? {
        guard let canvas = canvas else { return nil }
        // Gridded in metres, which is what the canvas measures in.
        let metres = (nanometresPerUnit ?? 1e9) * 1e-9
        let scan = try GriddedScan.grid(x: x.map { $0 * metres }, y: y.map { $0 * metres },
                                        canvas: canvas, pattern: pattern ?? "",
                                        rawFilename: rawFile, name: label)
        return scan.onGrid ? nil : scan
    }

    static func interpret(_ arrays: [NumpyReader.Array], label: String) throws -> ScanPositions {
        func numeric(_ names: [String]) -> [Double]? {
            for wanted in names {
                if let hit = arrays.first(where: { $0.name.lowercased() == wanted && !$0.numbers.isEmpty }) {
                    return hit.numbers
                }
            }
            return nil
        }
        func text(_ names: [String]) -> String? {
            for wanted in names {
                if let hit = arrays.first(where: { $0.name.lowercased() == wanted }),
                   let value = hit.scalarString, !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        var xs = numeric(xNames)
        var ys = numeric(yNames)

        // A single two-column array, which is how a script that did not write
        // separate members would have stored the same thing.
        if xs == nil || ys == nil {
            let candidates = ["positions", "position", "xy", "coords", "coordinates",
                              "scan_positions", "points"]
            for wanted in candidates {
                guard let hit = arrays.first(where: { $0.name.lowercased() == wanted }),
                      hit.shape.count == 2, !hit.numbers.isEmpty else { continue }
                let (rows, columns) = (hit.shape[0], hit.shape[1])
                if columns == 2 {
                    xs = (0..<rows).map { hit.numbers[$0 * 2] }
                    ys = (0..<rows).map { hit.numbers[$0 * 2 + 1] }
                } else if rows == 2 {
                    xs = Swift.Array(hit.numbers[0..<columns])
                    ys = Swift.Array(hit.numbers[columns..<(2 * columns)])
                } else {
                    continue
                }
                break
            }
        }

        guard let x = xs, let y = ys else { throw ScanPath.Failure.noPositions(label) }
        guard x.count == y.count else {
            throw ScanPath.Failure.lopsided(label, x: x.count, y: y.count)
        }
        guard !x.isEmpty else { throw ScanPath.Failure.noPositions(label) }

        // Whatever the file says it measured in. Only the spacing depends on
        // it, and an unrecognised unit leaves the spacing unreported rather
        // than reported wrongly.
        let unit = text(["units", "unit", "length_unit"])

        var positions = ScanPositions(x: x, y: y,
                                      pattern: text(["pattern", "scan_pattern", "path",
                                                     "scan_path", "order"]),
                                      rawFile: text(["raw_file", "rawfile", "raw_filename",
                                                     "data_file", "filename"]),
                                      summaryText: text(["description", "notes", "comment"]),
                                      label: label)
        positions.unit = unit
        return positions
    }

    /// Nanometres per unit of the stored positions, when the unit is one this
    /// recognises.
    private var nanometresPerUnit: Double? {
        guard let unit = unit?.lowercased()
            .trimmingCharacters(in: .whitespaces) else { return nil }
        switch unit {
        case "m", "metre", "meter", "metres", "meters":     return 1e9
        case "mm", "millimetre", "millimeter":              return 1e6
        case "um", "µm", "\u{03bc}m", "micron", "microns", "micrometre", "micrometer":
            return 1e3
        case "nm", "nanometre", "nanometer":                return 1
        case "a", "å", "ang", "angstrom", "angstroms", "\u{212b}":
            return 0.1
        case "pm", "picometre", "picometer":                return 1e-3
        default:                                            return nil
        }
    }

    // MARK: The grid

    /// The distinct coordinates along one axis, and the spacing between them.
    ///
    /// Clustered rather than compared exactly. The positions come back from a
    /// scan controller as whatever the arithmetic produced, so the values on
    /// one column of the grid agree to about a part in 10^8 and not to the last
    /// bit, and counting exact duplicates would find a thousand columns where
    /// there are a hundred.
    private static func axis(_ values: [Double]) -> (count: Int, step: Double, minimum: Double)? {
        let finite = values.filter { $0.isFinite }.sorted()
        guard let first = finite.first, let last = finite.last else { return nil }
        let extent = last - first
        guard extent > 0 else { return (1, 0, first) }

        // Anything closer than this is the same grid line seen twice.
        let tolerance = extent * 1e-6
        var distinct = [first]
        for value in finite where value - distinct[distinct.count - 1] > tolerance {
            distinct.append(value)
        }
        guard distinct.count > 1 else { return (1, 0, first) }
        return (distinct.count, extent / Double(distinct.count - 1), first)
    }

    /// The raster the positions imply, when they imply one.
    ///
    /// Preferred over this: the `raw_file` name, which states the raster
    /// outright in the `scan_x128_y128` convention the rest of the application
    /// already reads. This is the fallback for a file that does not name one.
    func inferredRaster() -> (width: Int, height: Int)? {
        // An off-grid path is drawn on its canvas, not on the rectangle of
        // triggers the raw file's name records: a 128-canvas spiral is written
        // as 128×100 frames and is still a 128×128 scan.
        if let canvas = canvas, (try? offGridScan()) != nil {
            return (canvas.side, canvas.side)
        }
        if let raw = rawFile, let size = ScanMetadata.dimensions(fromFilename: raw) {
            return size
        }
        guard let xAxis = Self.axis(x), let yAxis = Self.axis(y),
              xAxis.count > 1 || yAxis.count > 1 else { return nil }
        return (xAxis.count, yAxis.count)
    }

    /// The scan step the positions imply, in nanometres per probe position.
    ///
    /// Nil unless the file named a unit this recognises and the grid has more
    /// than one line along the axis — a step cannot be measured from a single
    /// position, and a wrong one is worse than none.
    func inferredScanStepNanometres() -> Double? {
        // Off the grid there are no grid lines to measure; the canvas pitch is
        // the step.
        if let canvas = canvas, (try? offGridScan()) != nil {
            return canvas.pitchX * 1e9
        }
        guard let scale = nanometresPerUnit,
              let xAxis = Self.axis(x), xAxis.count > 1, xAxis.step > 0 else { return nil }
        return xAxis.step * scale
    }

    /// Where every frame goes on a raster of the given size.
    ///
    /// Each position is turned into a grid index by normalising it against the
    /// extent the positions themselves cover, rather than by dividing by a
    /// nominal step. The scan's corners are in the file, so the extent is
    /// exact; a nominal step is not, and over a hundred-odd columns a relative
    /// error of 10^-3 in it is enough to walk the last column into the next row.
    func placement(width: Int, height: Int) throws -> ScanPlacement {
        guard width > 0, height > 0 else { throw ScanPath.Failure.emptyRaster }

        // Off the lattice: gridded onto the canvas instead, and only onto the
        // canvas, which is the scan.
        if let scan = try offGridScan() {
            guard scan.extent.width == width else {
                throw ScanPath.Failure.notAGrid(label, axis: "x", found: scan.extent.width,
                                                expected: width)
            }
            guard scan.extent.height == height else {
                throw ScanPath.Failure.notAGrid(label, axis: "y", found: scan.extent.height,
                                                expected: height)
            }
            let named = pattern.map { "\($0) (\(label))" } ?? label
            return ScanPlacement(slots: scan.destinations.map { $0 >= 0 ? Int($0) : nil },
                                 unfilled: scan.blank,
                                 label: "\(named), gridded",
                                 spread: scan.spread)
        }

        guard let xAxis = Self.axis(x), let yAxis = Self.axis(y) else {
            throw ScanPath.Failure.tooFewPositions(label, found: 0)
        }
        let placed = placedCount
        guard placed > 0 else { throw ScanPath.Failure.tooFewPositions(label, found: 0) }

        // The file's own grid has to be the one asked for. Checked rather than
        // assumed: a positions file from a different scan is the mistake that
        // would otherwise produce a complete, plausible and wrong image.
        guard xAxis.count == width else {
            throw ScanPath.Failure.notAGrid(label, axis: "x", found: xAxis.count, expected: width)
        }
        guard yAxis.count == height else {
            throw ScanPath.Failure.notAGrid(label, axis: "y", found: yAxis.count, expected: height)
        }

        var slots = [Int?](repeating: nil, count: x.count)
        for frame in 0..<x.count {
            let px = x[frame], py = y[frame]
            guard px.isFinite, py.isFinite else { continue }     // not at a scan position
            let column = width == 1 ? 0
                : Int(((px - xAxis.minimum) / xAxis.step).rounded())
            let row = height == 1 ? 0
                : Int(((py - yAxis.minimum) / yAxis.step).rounded())
            guard column >= 0, column < width, row >= 0, row < height else {
                throw ScanPath.Failure.outOfRange(position: row * width + column,
                                                  limit: width * height)
            }
            slots[frame] = row * width + column
        }

        let placement = ScanPlacement(slots: slots, unfilled: 0,
                                      label: pattern.map { "\($0) (\(label))" } ?? label)
        // Run through the common check, which counts the positions nothing
        // landed on and refuses two frames claiming one.
        return try ScanPath.explicit(placement).placement(width: width, height: height)
    }
}

struct Calibrations{
    let scan_step:Float?          // nm per probe position
    let diff_step:Float?          // mrad per detector pixel
    /// Accelerating voltage in kilovolts. Not used for the scale bar, but it is
    /// what turns a reciprocal-space calibration into an angle, and plugins ask
    /// for it rather than making the user type it again.
    let voltage:Float?
    /// Scan rotation in degrees, when it is known.
    let scanRotationDegrees:Float?
    /// The shape of the raster, with the mean scale divided out.
    ///
    /// Held apart from `scan_step` for the same reason the calibration is
    /// reported as `A = R · D`: the step is a scale and the correction is a
    /// shape, and folding a non-square raster into a single number misreports
    /// every distance measured along its axes.
    let scanCorrection:ScanCorrection?
    /// How the patterns are oriented on the detector.
    ///
    /// Seeded from the transforms the file was actually read with, so it starts
    /// out describing what is on screen rather than a guess. A measurement that
    /// finds the detector mirrored relative to the scan can correct it.
    let detectorFlips:DetectorFlips?
    /// The order the frames were read in, when it was not a plain raster.
    ///
    /// Held here, alongside the detector orientation, because it is the same
    /// kind of fact: not a measured quantity but a statement about how the file
    /// was interpreted, which an export has to carry or the next reader will
    /// interpret it differently.
    let scanPath:ScanPath?
    /// Measured aberration coefficients, Krivanek (n, m), ångström, detector
    /// frame. Empty when nothing has measured them.
    let aberrations:[Aberration]

    init(scan_step: Float?, diff_step: Float?, voltage: Float? = nil,
         scanRotationDegrees: Float? = nil, scanCorrection: ScanCorrection? = nil,
         detectorFlips: DetectorFlips? = nil, scanPath: ScanPath? = nil,
         aberrations: [Aberration] = []) {
        self.scan_step = scan_step
        self.diff_step = diff_step
        self.voltage = voltage
        self.scanRotationDegrees = scanRotationDegrees
        self.scanCorrection = scanCorrection
        self.detectorFlips = detectorFlips
        self.scanPath = scanPath
        self.aberrations = aberrations
    }
}


class STEMDataController: NSObject {
    
    // Notification posted when a new displayable NSImage is ready
    static let imageDidUpdateNotification = Notification.Name("STEMDataController.imageDidUpdate")
    // Optional cache for latest rendered image (used by observers)
    private(set) var lastRenderedImage: NSImage?
    
    var filePath:URL?
    var imageSize:IntSize = IntSize(width: 0, height: 0)
    var fh:FileHandle?
    
    var calibrations:Calibrations?
    
    weak var delegate:STEMDataControllerDelegate?
    weak var progressdelegate:STEMDataControllerProgressDelegate?
    
    // Defaults until a file is opened. `patternSize` is the image, so it never
    // includes the metadata rows — it used to be initialised to 128x130, which
    // is the size of a stored frame, not of a pattern.
    var detectorSize = IntSize(width: EMPADLayout.first.columns,
                               height: EMPADLayout.first.storedRows)
    var patternSize = IntSize(width: EMPADLayout.first.columns,
                              height: EMPADLayout.first.rows)
    
    var providedRawImageSize: IntSize? = nil
    /// Set from the file when it records one, and applied as the data is read so
    /// that everything downstream sees physical values. Nil for formats that
    /// store calibrated values already.
    private(set) var intensityCalibration: IntensityCalibration? = nil
    /// Which microscope, at what voltage, in what mode — when the file says.
    /// Used to file and find calibrations in the library.
    private(set) var instrument: InstrumentIdentity? = nil
    /// Indicated magnification, when the file records it.
    private(set) var magnification: Double? = nil
    var rawFlipRows: Bool = true
    var rawFlipCols: Bool = false
    var rawTranspose: Bool = false
    /// The order the stored frames map onto the raster in. Applied as the file
    /// is read, so a non-raster scan arrives already unscrambled.
    var rawScanPath: ScanPath = .raster
    
    var patternPixels:Int{
        get{
            return Int(patternSize.width * patternSize.height)
        }
    }
    
    var imagePixels:Int{
        get{
            return Int(imageSize.width*imageSize.height)
        }
    }
    
    
    var detectorPixels:Int{
        get{
            return Int(detectorSize.width*detectorSize.height)
        }
    }
    private func navigateDict(_ metadata:[String:Any],_ keyPath:[String]) -> [String:Any]{
        var temp = metadata
        for key in keyPath{
            if let dict = temp[key] as! [String:Any]?{
                temp = dict
            }
            
        }
        
        return temp
    }
    
    func setRawImageSize(width: Int, height: Int) {
        self.providedRawImageSize = IntSize(width: width, height: height)
    }

    func setRawTransforms(flipRows: Bool, flipCols: Bool, transpose: Bool) {
        self.rawFlipRows = flipRows
        self.rawFlipCols = flipCols
        self.rawTranspose = transpose
    }

    func setRawScanPath(_ path: ScanPath) {
        self.rawScanPath = path
    }

    /// The order the frames currently in memory were placed in.
    ///
    /// Recorded by the read path for the same reason `appliedDetectorFlips` is:
    /// what the loader did is a fact about the buffer, and deriving it a second
    /// time somewhere else is how the two come to disagree.
    private(set) var appliedScanPath: ScanPath = .raster

    /// A DM dimension, whatever integer width the file wrote it as.
    ///
    /// The original read only accepted `UInt32`; a file writing its dimensions
    /// as `Int32` or `UInt16` silently contributed nothing, leaving a zero in
    /// that slot and a dataset that looked like it had no scan.
    static func dimension(_ value: Any?) -> UInt32? {
        let number: Double?
        switch value {
        case let v as UInt32: return v
        case let v as Int:    number = Double(v)
        case let v as Int32:  number = Double(v)
        case let v as UInt16: number = Double(v)
        case let v as Int16:  number = Double(v)
        case let v as NSNumber: number = v.doubleValue
        default: number = nil
        }
        guard let n = number, n > 0, n <= Double(UInt32.max) else { return nil }
        return UInt32(n)
    }

    /// The orientation the patterns currently in memory were read with.
    ///
    /// Recorded by the read path rather than worked out again from the file
    /// extension. Deriving it a second time invites the derivation to disagree
    /// with what the loader actually did — which it did: this used to answer
    /// "unflipped" for anything that was not a .raw, while the loader applies the
    /// flip flags to every format except EMD.
    private(set) var appliedDetectorFlips: DetectorFlips = .unflipped

    var currentDetectorFlips: DetectorFlips { return appliedDetectorFlips }

    var fileStream:InputStream?
    
    var patternPointer:UnsafeMutablePointer<Float32>?

    // Held between inspecting an EMD file and reading it.
    private var emdFile:HDF5File?
    private var emdDataset:EMDDataset?

    // ARINA. The detector records how many frames it wrote but never their
    // arrangement, and a full scan is far too large to hold, so the raster and
    // the reduction are decided before the file is opened and set here.
    var arinaRaster: IntSize? = nil
    var arinaFactor: Int = 1
    var arinaReduction: ArinaReduction = .stride
    private var arinaDataset: ArinaDataset?
    
    var dwi: DispatchWorkItem?

    /// Stops the bulk read, if one is running.
    func cancelLoad() {
        dwi?.cancel()
    }


    
    override init() {
        super.init()
    }
    
    func indexFor(_ i:Int,_ j:Int)->Int{
        
        return i*imageSize.width+j
        
    }
    
    func pattern(_ i:Int, _ j:Int)->Matrix?{
        
        var matrix:Matrix?
        
        if patternPointer != nil{
            
            var patternIndex = 0
            
            if i >= 0 && j >= 0{
                patternIndex =  self.indexFor(i, j)
            }
        
            let selectedPatternPointer = patternPointer! + (patternPixels)*patternIndex
            
            // Convert pointer to array
            let patternArray = Array(UnsafeBufferPointer(start: selectedPatternPointer, count: patternPixels))
            matrix = Matrix.init(array: patternArray, patternSize.height, patternSize.width)
        }
        
        return matrix
        
    }
    
    private func convertToFloat(
        dataType: DataType,
        sourceData: Data,
        destinationBuffer: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        sourceData.withUnsafeBytes { raw in
            switch dataType {
            case .int16:
                vDSP_vflt16(raw.bindMemory(to: Int16.self).baseAddress!, 1,
                            destinationBuffer, 1, vDSP_Length(count))

            case .uint16:
                vDSP_vflt16(raw.bindMemory(to: UInt16.self).baseAddress!, 1,
                            destinationBuffer, 1, vDSP_Length(count))

            case .uint32:
                vDSP_vflt32(raw.bindMemory(to: UInt32.self).baseAddress!, 1,
                            destinationBuffer, 1, vDSP_Length(count))

            case .uint8, .bool:
                vDSP_vfltu8(raw.bindMemory(to: UInt8.self).baseAddress!, 1,
                            destinationBuffer, 1, vDSP_Length(count))

            default: // assuming Float32
                guard let base = raw.bindMemory(to: Float32.self).baseAddress else {
                    // If we can't get a baseAddress (e.g., zero-length), do nothing safely.
                    return
                }
                destinationBuffer.update(from: base, count: count)
            }
        }
    }

    
    func readTiffInfo(_ props:[String:Any]) throws{
        
        // {TIFF} key contains a dictionary with imageJ string containing the width and height info (\nslices and \nframes)
        
        let pixelWidth:Int
        let pixelHeight:Int

        if let test = props["ImageWidth"] as? Int32{
            pixelWidth = Int(test)
        }else{
            throw FileReadError.invalidTiff
        }
        
        if let test = props["ImageHeight"] as? Int32{
            pixelHeight = Int(test)

        }else{
            throw FileReadError.invalidTiff
        }

        
        if let imageDescription = props["ImageDescription"] as? String{
            
            detectorSize = IntSize(width: pixelWidth, height: pixelHeight)
            patternSize = detectorSize
            
            var width:String = ""
            var height:String = ""
            
            let patWidth = "(?<=\\nslices=)[0-9]+"
            let patHeight = "(?<=\\nframes=)[0-9]+"
            
            
            var regex = try! NSRegularExpression(pattern: patWidth, options: [])
            var matches = regex.matches(in: imageDescription, options: [], range: NSRange(location: 0, length: imageDescription.count))
            
            if matches.count == 0{
                throw FileReadError.invalidTiff
            }

            
            if let match = matches.first {
                let range = match.range(at:0)
                if let swiftRange = Range(range, in: imageDescription as String) {
                    width = String(imageDescription[swiftRange])
                }
            }
            
            regex = try! NSRegularExpression(pattern: patHeight, options: [])
            matches = regex.matches(in: imageDescription, options: [], range: NSRange(location: 0, length: imageDescription.count))
            
            
            if let match = matches.first {
                let range = match.range(at:0)
                if let swiftRange = Range(range, in: imageDescription as String) {
                    height = String(imageDescription[swiftRange])
                }
            }
            
            self.imageSize.width = Int(width)!
            self.imageSize.height = Int(height)!
            
        }else{
            throw FileReadError.invalidTiff
        }
        
    }
    
    
    // MARK: - File read
    
    
    func waitForFileDownload(at url: URL, timeout: TimeInterval = 15.0, stableDuration: TimeInterval = 1.5) -> Bool {
        let start = Date()
        var lastSize: Int64 = -1
        var stableStart: Date? = nil

        while Date().timeIntervalSince(start) < timeout {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                if let fileSize = attrs[.size] as? Int64 {
                    if fileSize == lastSize {
                        if stableStart == nil {
                            stableStart = Date()
                        } else if Date().timeIntervalSince(stableStart!) >= stableDuration {
                            // File size hasn't changed for long enough; assume download complete
                            return true
                        }
                    } else {
                        stableStart = nil
                        lastSize = fileSize
                    }
                }
            } catch {
                // File not yet readable
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return false
    }
    
    func waitUntilDropboxFileIsReadable(at url: URL, timeout: TimeInterval = 10.0) -> Bool {
        let start = Date()
        while true {
            do {
                _ = try Data(contentsOf: url)
                return true  // File is readable
            } catch {
                // Possibly still downloading
            }

            if Date().timeIntervalSince(start) > timeout {
                return false  // Timed out
            }

            // Sleep a bit to avoid CPU spinning
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
    func waitUntilFileIsDownloaded(at url: URL, timeout: TimeInterval = 10.0) -> Bool {
        let start = Date()
        while !isFileFullyDownloaded(at: url) {
            if Date().timeIntervalSince(start) > timeout {
#if DEBUG
                print("Timeout waiting for file to download")
#endif
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1)) // Avoid CPU hog
        }
        return true
    }
    
    func isDropboxFile(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("Dropbox")
    }

    func isFileFullyDownloaded(at url: URL) -> Bool {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                                  .ubiquitousItemDownloadingStatusKey])
            guard resourceValues.isUbiquitousItem == true else {
                return true  // Not a cloud file, assume it's local
            }

            return resourceValues.ubiquitousItemDownloadingStatus == .current
        } catch {
#if DEBUG
            print("Failed to check file status: \(error)")
#endif
            return false
        }
    }
    
    func forceDownloadDropboxFile(at url: URL) -> Bool {
        let startTime = Date()
        let timeout: TimeInterval = 15.0
        var lastSize: Int64 = -1
        var stableStart: Date? = nil

        while Date().timeIntervalSince(startTime) < timeout {
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                // Optional: check size stability for completeness
                let size = Int64(data.count)
                if size == lastSize {
                    if stableStart == nil {
                        stableStart = Date()
                    } else if Date().timeIntervalSince(stableStart!) > 2.0 {
                        return true // Size is stable → likely fully downloaded
                    }
                } else {
                    lastSize = size
                    stableStart = nil
                }
            } catch {
                // Triggers Dropbox download behind the scenes
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return false
    }
    
    /// Asks whatever sync client owns the file to bring it down.
    ///
    /// Coordinated access is the trigger, not the read: a plain `read()` on a
    /// Dropbox placeholder succeeds, returns zero bytes and fetches nothing,
    /// whereas announcing the read through `NSFileCoordinator` makes the client
    /// materialise the file first. Measured on a 2.2 GB placeholder: the plain
    /// read returned instantly with nothing, the coordinated one took 81 seconds
    /// and produced the file.
    ///
    /// Blocks for the length of the download. Callers must not be on the main
    /// thread.
    func nudgeDownload(url: URL) {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { _ in
            // No-op — the coordinated access itself is the trigger.
        }
#if DEBUG
        if let error = error { NSLog("[open] coordination failed: %@", error.localizedDescription) }
#endif
    }
    
    func openFile(url: URL) throws {
        
        
//        if isDropboxFile(url) {
            // The nudge has already happened, in FileMaterializer, before this
            // was called — where it could be watched and cancelled. Doing it
            // again here is a no-op on a local file, and is left only so that a
            // direct call to `openFile` still fetches rather than reading an
            // empty placeholder.
            nudgeDownload(url: url)
            // ...
//        } else if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
//#if DEBUG
//            print("Detected iCloud file")
//#endif
//            // Use `startDownloadingUbiquitousItem(at:)` and check download status
//        } else {
//#if DEBUG
//            print("Not iCloud or Dropbox")
//#endif
//        }
       
        
        let ext = url.pathExtension.lowercased()
        let typeIdentifier = UTTypeCreatePreferredIdentifierForTag(
            kUTTagClassFilenameExtension,
            ext as CFString,
            nil
        )?.takeRetainedValue()

        let isTIFF = typeIdentifier.map { UTTypeConformsTo($0, kUTTypeTIFF) } ?? false
        let isMRC = ext == "mrc"
        let isDM = ext == "dm4" || ext == "dm3"
        let isRaw = ext == "raw"
        let isEMD = ext == "emd" || ext == "h5" || ext == "hdf5"
        // Decided by looking inside: the extension is shared with py4DSTEM, EMD
        // and anything else, and only the structure tells them apart.
        let isArina = isEMD && ArinaReader.looksLikeArina(url: url)
        

        var dataType: DataType = .unknown
        var firstImageOffset: UInt64
        var additionalRows:Int = 0

        // Cleared up front rather than in each branch: this is instance state,
        // and a format that records no intensity calibration must not silently
        // inherit the one belonging to whatever was opened before it.
        self.intensityCalibration = nil
        self.instrument = nil
        self.magnification = nil
    
        if isTIFF {
            dataType = .float32
            let props: [String: Any]
            do {
                try props = TIFFheader(url)
                try readTiffInfo(props)
                firstImageOffset = props["FirstImageOffset"] as! UInt64
            } catch {
                throw FileReadError.invalidTiff
            }
        } else if isMRC {
            dataType = .int16
            
            let (header, feiHeader) = try loadMRCHeader(from: url)
//            let header = try readMRCHeader(from: url)
//            let feiHeader = try readFEI1ExtendedHeaders(from: url)
            firstImageOffset = UInt64(1024 + header!.nsymbt)
            self.detectorSize = IntSize(width: Int(header!.nx), height: Int(header!.nx))
            self.patternSize = detectorSize
            
            self.imageSize = IntSize(width: Int(feiHeader!.scanSizeRight), height: Int(feiHeader!.scanSizeBottom))
        } else if isArina {
            self.emdFile = nil
            self.emdDataset = nil
            self.arinaDataset = nil
            self.calibrations = nil

            let dataset = try ArinaReader.inspect(
                url: url,
                raster: arinaRaster.map { (width: $0.width, height: $0.height) },
                factor: arinaFactor,
                reduction: arinaReduction)

            // The frames are uint16 counts, converted to Float as they are
            // decoded; nothing downstream sees the stored type.
            dataType = .float32
            firstImageOffset = 0
            self.detectorSize = IntSize(width: dataset.patternWidth, height: dataset.patternHeight)
            self.patternSize = detectorSize
            self.imageSize = IntSize(width: dataset.scanWidth, height: dataset.scanHeight)
            self.calibrations = dataset.calibrations
            self.arinaDataset = dataset
            NSLog("[ARINA] %@ — %@", url.lastPathComponent, dataset.summary)
        } else if isEMD {
            self.emdFile = nil
            self.emdDataset = nil
            self.arinaDataset = nil
            self.calibrations = nil

            let (dataset, file) = try EMDReader.inspect(url: url)

            // libhdf5 converts whatever the file holds into Float on read, so
            // the sample format never reaches the streaming path below.
            dataType = .float32
            firstImageOffset = 0
            self.detectorSize = IntSize(width: dataset.patternWidth, height: dataset.patternHeight)
            self.patternSize = detectorSize
            self.imageSize = IntSize(width: dataset.scanWidth, height: dataset.scanHeight)
            self.calibrations = dataset.calibrations
            self.emdFile = file
            self.emdDataset = dataset
#if DEBUG
            NSLog("[EMD] %@ — %@", dataset.datasetPath, dataset.summary)
#endif
        } else if isDM{
            
            let dm4 = try DigitalMicrographReader(fileURL: url)
            var metadata = dm4.tagsDict
            
            firstImageOffset = 0
                        
//            let keysToSampling = ["root", "ImageList", "TagGroup0", "ImageTags", "SI", "Acquisition", "Spatial Sampling"]
//            
//
//        
//            let sampling = navigateDict(metadata, keysToSampling)
            
            let keysImageList = ["root", "ImageList"]
            
            let imageList  = navigateDict(metadata, keysImageList)
            
            var tagGroup:String? = nil
            
            for (key, _) in imageList {
                let keyToImage = ["root", "ImageList", "\(key)"]
                let imageDict  = navigateDict(metadata, keyToImage)
                
                if let name = imageDict["Name"] as? String{
                    if name == "Diffraction SI"{
                        tagGroup = key
                        break
                    }
                }
            }
            
            guard let tg = tagGroup else {
                throw FileReadError.notDiffractionSI
                }
                //
            let keysToData = ["root", "ImageList", tg, "ImageData", "Data"]
            
            //            let keysToDetector = ["root", "ImageList", "TagGroup1", "ImageTags",  "Acquisition", "Parameters", "Detector"]
            
            let keysToSize = ["root", "ImageList", tg, "ImageData", "Dimensions"]
            
            //            let keysToPixelDepth = ["root", "ImageList", "TagGroup1", "ImageData"]
            
            let data = navigateDict(metadata, keysToData)
            //            let pixelDepth = navigateDictToInt(metadata, keysToPixelDepth)
            
            //            let detector = navigateDict(metadata, keysToDetector)
            let sizes = navigateDict(metadata, keysToSize)
            
            if let dtypeNumber = data["datatype"] as? Int{
                switch dtypeNumber{
                case 2:
                    dataType = .int16
                case 4:
                    dataType = .uint16
                case 5:
                    dataType = .uint32
                case 8:
                    dataType = .bool
                case 10:
                    dataType = .uint8
                default:
                    dataType = .int16
                    
                }
            }
            
            
            
            // The four dimensions, read by the index in each tag's name.
            //
            // Three things here were crashes or silent corruption waiting:
            //
            //   * the slot was taken from the *last digit character* of the name,
            //     so `TagGroup10` wrote slot 0 — quietly overwriting the detector
            //     width with a scan dimension. The whole trailing run of digits
            //     is parsed instead.
            //   * the slot was used to index a fixed four-element array with no
            //     bounds check, so anything above three was a fatal "Index out of
            //     range" rather than an error the user could act on.
            //   * `navigateDict` returns its *parent* when a key is missing, so a
            //     file without `ImageData/Dimensions` reached this loop with some
            //     unrelated dictionary's keys and wrote whatever they happened to
            //     end in.
            //
            // A dataset that does not resolve to exactly four dimensions is not
            // one this reader can open, and saying so beats guessing.
            var sizesArray: [UInt32] = Array(repeating: 0, count: 4)
            var seenSlots = Set<Int>()

            for sizeKey in sizes.keys {
                let digits = String(sizeKey.reversed().prefix { $0.isNumber }.reversed())
                guard !digits.isEmpty, let slot = Int(digits) else { continue }
                guard let value = STEMDataController.dimension(sizes[sizeKey]) else { continue }
                guard slot >= 0, slot < sizesArray.count else {
                    // A fifth dimension, or a name this reader misread. Either
                    // way the four it expects are no longer trustworthy.
                    throw FileReadError.invalidDimensions
                }
                sizesArray[slot] = value
                seenSlots.insert(slot)
            }

            guard seenSlots == [0, 1, 2, 3], sizesArray.allSatisfy({ $0 > 0 }) else {
                throw FileReadError.invalidDimensions
            }

            guard let dataOffset = data["offset"] as? Int, dataOffset >= 0 else {
                throw FileReadError.invalidDimensions
            }
            firstImageOffset = UInt64(dataOffset)
            self.detectorSize = IntSize(width: Int(sizesArray[0]), height: Int(sizesArray[1]))
            self.patternSize = detectorSize
            
            self.imageSize = IntSize(width: Int(sizesArray[2]), height: Int(sizesArray[3]))

            // The pedestal and gain that turn the stored integers into electrons.
            self.intensityCalibration = dm4.intensityCalibration(imageTagGroup: tg)

            let described = dm4.instrumentDescription(imageTagGroup: tg)
            self.magnification = dm4.magnification(imageTagGroup: tg)

            // And the axis calibrations, which DM records alongside them.
            let dm = dm4.scanCalibration(imageTagGroup: tg,
                                         patternPixels: self.patternSize.width)
            if dm.scanStepNanometres != nil || dm.diffractionStepMilliradians != nil
                || dm.voltageKilovolts != nil {
                self.calibrations = Calibrations(
                    scan_step: dm.scanStepNanometres.map { Float($0) },
                    diff_step: dm.diffractionStepMilliradians.map { Float($0) },
                    voltage: dm.voltageKilovolts.map { Float($0) })
            } else {
                self.calibrations = nil
            }
            if !described.microscope.isEmpty || (dm.voltageKilovolts ?? 0) > 0 {
                self.instrument = InstrumentIdentity(microscope: described.microscope,
                                                     kilovolts: dm.voltageKilovolts ?? 0,
                                                     mode: described.mode)
            }
#if DEBUG
            NSLog("[DM] %@ — scan %@ nm/px, diffraction %@ mrad/px, %@ kV%@",
                  tg,
                  dm.scanStepNanometres.map { String(format: "%.6g", $0) } ?? "—",
                  dm.diffractionStepMilliradians.map { String(format: "%.6g", $0) } ?? "—",
                  dm.voltageKilovolts.map { String(format: "%.0f", $0) } ?? "—",
                  dm.diffractionNeedsVoltage ? " (reciprocal axis, but no voltage recorded)" : "")
#endif
        

        } else {
            dataType = .float32
            firstImageOffset = 0
            // EMPAD's own layout until the file says otherwise. For RAW that
            // decision is made below, once its length is known.
            var layout = EMPADLayout.first
            self.detectorSize = IntSize(width: layout.columns, height: layout.storedRows)
            self.patternSize = IntSize(width: layout.columns, height: layout.rows)
            additionalRows = layout.metadataRows

            if isRaw {
                self.imageSize = providedRawImageSize ?? IntSize(width: 0, height: 0)

                // Which EMPAD wrote this. Nothing in the file says so, but the
                // two generations write different numbers of bytes for the same
                // raster, so its length does — see EMPADLayout. Decided here,
                // before anything is read, because every offset below depends
                // on how many rows a frame occupies.
                let fileBytes = (try? FileManager.default
                    .attributesOfItem(atPath: url.path))
                    .flatMap { ($0[.size] as? NSNumber)?.intValue } ?? 0
                let elementSizes = DataType.rawCandidates.map { $0.elementSize }

                // The raster comes from whatever the caller was given — a
                // sidecar, or the scan_xN_yN convention in the name — and with
                // it the choice is a division rather than a guess.
                //
                // What the division actually needs is the number of frames in
                // the file, which is the raster only when every frame is at a
                // scan position. A positions file states the frame count, so it
                // takes precedence: with settling frames in the file, dividing
                // by the raster gives a non-integral number of bytes per frame
                // and the layout is rejected for being the wrong one.
                let scanPixels = rawScanPath.frameCount
                    ?? (providedRawImageSize.map { $0.width * $0.height })
                    ?? ScanMetadata.dimensions(fromFilename: url.lastPathComponent)
                        .map { $0.width * $0.height }
                    ?? 0

                if let chosen = EMPADLayout.choose(fileSize: fileBytes,
                                                   scanPixels: scanPixels,
                                                   elementSizes: elementSizes) {
                    layout = chosen.layout
                    dataType = DataType.rawCandidate(elementSize: chosen.elementSize) ?? .float32
                } else if scanPixels == 0,
                          let inferred = EMPADLayout.infer(fileSize: fileBytes, elementSize: 4) {
                    layout = inferred
                }

                self.detectorSize = IntSize(width: layout.columns, height: layout.storedRows)
                self.patternSize = IntSize(width: layout.columns, height: layout.rows)
                additionalRows = layout.metadataRows
                // Logged in every build, not just debug ones. Which generation
                // a file was read as is the first thing worth knowing when
                // patterns come out looking sheared, and it is not recoverable
                // after the fact from anything the user can see.
                NSLog("[RAW] %@ — read as %@: %d×%d per frame, %d metadata row(s), %@",
                      url.lastPathComponent, layout.name,
                      layout.columns, layout.rows, layout.metadataRows,
                      scanPixels > 0 ? "raster known" : "raster inferred from length")
            }
        }

        let elementSize = dataType.elementSize
        


        let detectorPixels = self.detectorPixels
        let patternPixels = self.patternPixels
        let imagePixels = self.imagePixels

        if isRaw {
            do {
                let attrib = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = (attrib[.size] as? NSNumber)?.intValue ?? 0

                // Only validate when we know image dimensions
                if imagePixels > 0 {
                    let basePixelsPerImage = (self.patternSize.height + additionalRows) * self.patternSize.width
                    // A path with settling or fly-back frames, or one gridded
                    // from an off-grid spiral, stores more frames than the scan
                    // has positions, so the file is as long as the path says,
                    // not as the raster does.
                    let storedImages = rawScanPath.frameCount ?? imagePixels
                    let totalPixels = basePixelsPerImage * storedImages

                    let candidates = DataType.rawCandidates
                    var matched = false
                    for cand in candidates {
                        let expectedBytes = totalPixels * cand.elementSize
                        if fileSize == expectedBytes {
                            dataType = cand
                            matched = true
                            break
                        }
                    }
                    if !matched {
                        throw FileReadError.invalidDimensions
                    }
                }
                // Derive image dimensions for RAW if not already set
                let bytesPerImage = (self.patternSize.height + additionalRows) * self.patternSize.width * dataType.elementSize
                if bytesPerImage > 0 {
                    let totalImages = fileSize / bytesPerImage

                    // If image size hasn't been set yet, try to parse from filename or infer
                    if self.imageSize.width == 0 || self.imageSize.height == 0 {
                        if let provided = self.providedRawImageSize {
                            self.imageSize = provided
                        } else {
                            let name = url.lastPathComponent
                            var inferredW: Int? = nil
                            var inferredH: Int? = nil

                            // Try to parse numbers following 'x' and 'y' like original workflow
                            if let regex = try? NSRegularExpression(pattern: "(?<=[xXyY])[0-9]+", options: []) {
                                let s = name as NSString
                                let matches = regex.matches(in: name, options: [], range: NSRange(location: 0, length: s.length))
                                if let first = matches.first {
                                    inferredW = Int(s.substring(with: first.range))
                                }
                                if matches.count > 1, let last = matches.last {
                                    inferredH = Int(s.substring(with: last.range))
                                }
                            }

                            if let w = inferredW, let h = inferredH {
                                self.imageSize = IntSize(width: w, height: h)
                            } else {
                                let root = Int(Double(totalImages).squareRoot())
                                if root * root == totalImages {
                                    self.imageSize = IntSize(width: root, height: root)
                                } else {
                                    self.imageSize = IntSize(width: totalImages, height: 1)
                                }
                            }
                        }
                    }
                }
            } catch let fileReadError as FileReadError {
                throw fileReadError
            } catch {
                throw FileReadError.invalidRaw
            }
        }


        let width = self.patternSize.width
        let height = self.patternSize.height
        let totalPatternPixels = (height + additionalRows) * width
    
        
        let totalImages = self.imageSize.width * self.imageSize.height
        guard totalImages > 0 else {
            throw FileReadError.invalidDimensions
        }

        // The row flip is an EMPAD RAW convention. EMD files store the stack in
        // the orientation they mean, and the transforms are instance state left
        // over from whatever was opened last, so don't apply them here.
        // Captured before the work item so the background read never touches
        // instance state that the main thread could be changing.
        let intensity = self.intensityCalibration

        let doFlipRows = isEMD ? false : rawFlipRows
        let doFlipCols = isEMD ? false : rawFlipCols
        let doTranspose = isEMD ? false : rawTranspose
        self.appliedDetectorFlips = DetectorFlips(flipY: doFlipRows, flipX: doFlipCols,
                                                  transpose: doTranspose)

        // Where each frame goes.
        //
        // Restricted to RAW, which is the only format the panel offers a scan
        // path for. The transforms above are instance state that any format
        // inherits from whatever was opened last; a scan path must not be,
        // because it is tied to one file's raster. Left to leak, a snake path
        // chosen for an 80×80 scan would either scramble the next DM file or —
        // more likely, its raster being a different size — refuse to open it
        // at all, for a reason nothing on screen would explain.
        //
        // Resolved here, on the calling thread, so a path that does not fit the
        // scan is thrown from `openFile` like any other bad geometry rather than
        // surfacing from a background queue half way through a read.
        let scanPath: ScanPath = isRaw ? self.rawScanPath : .raster
        self.appliedScanPath = scanPath
        // Nil for a plain raster, and resolved not at all in that case. A
        // raster's placement is the identity, so building it would mean
        // allocating and then walking an array of one Int per scan position —
        // a million of them for a 1024x1024 scan — to discover that the k-th
        // frame is the k-th position, which is where the read starts from
        // anyway.
        let placement: ScanPlacement?
        if scanPath == .raster {
            placement = nil
        } else {
            let resolved = try scanPath.placement(width: self.imageSize.width,
                                                  height: self.imageSize.height)
            placement = resolved.isIdentity ? nil : resolved
        }

        // How many frames to read, which is not the same as how many scan
        // positions there are.
        //
        // A positions file knows: it has one entry per frame of the raw file,
        // settling and fly-back frames included, and those make the file longer
        // than the raster. Reading `width × height` of them would stop short,
        // leaving the end of the scan empty, and — because the surplus frames
        // are interleaved rather than appended — put everything after the first
        // of them in the wrong place.
        let storedFrames = placement?.frameCount ?? totalImages

        if let placement = placement {
            NSLog("[RAW] %@ — scan path %@: %d frame(s), %d placed, %d scan position(s) left empty",
                  url.lastPathComponent, placement.label, placement.frameCount,
                  placement.placedCount, placement.unfilled)
        }

        let batchSize = 64
        let totalBatches = (storedFrames + batchSize - 1) / batchSize


        let nc = NotificationCenter.default

        dwi = DispatchWorkItem {
            let fail: (Error) -> Void = { error in
                DispatchQueue.main.async {
                    self.delegate?.didFailLoadingData(error)
                }
            }

            // ARINA is read frame by frame, decoding each chunk itself,
            // because the compression it uses is not one libhdf5 can undo.
            if let dataset = self.arinaDataset {
                do {
                    try self.readArina(dataset, url: url,
                                       patternPixels: patternPixels,
                                       totalImages: totalImages, nc: nc)
                } catch {
                    fail(error)
                    return
                }
                if self.dwi?.isCancelled ?? false { return }
                DispatchQueue.main.async(execute: DispatchWorkItem {
                    _ = self.delegate?.didFinishLoadingData()
                })
                return
            }

            // EMD goes through libhdf5 rather than the raw byte stream below,
            // so that chunking, compression and sample format are its problem.
            if let hdf5 = self.emdFile, let dataset = self.emdDataset {
                do {
                    try self.readEMD(hdf5, dataset,
                                     patternPixels: patternPixels,
                                     totalImages: totalImages,
                                     nc: nc)
                } catch {
                    fail(error)
                    return
                }
                if self.dwi?.isCancelled ?? false { return }
                DispatchQueue.main.async(execute: DispatchWorkItem {
                    _ = self.delegate?.didFinishLoadingData()
                    nc.post(name: .fileLoaded, object: nil)
                })
                return
            }

            self.openFileHandle(url: url)
            guard let fileHandle = self.fh else {
                fail(FileReadError.invalidRaw)
                return
            }

            self.patternPointer?.deallocate()
            self.patternPointer = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels * totalImages)

            // Zeroed only when some scan position will not be written to.
            //
            // `allocate` hands back uninitialised memory, which a raster read
            // overwrites in full. A positions file need not: a scan can miss a
            // position, and what that position would otherwise show is whatever
            // the allocator had lying there — not a black pixel but arbitrary
            // floats, including the previous dataset's. The memset is a pass
            // over the buffer, which is why it is skipped when the placement
            // covers everything.
            if let placement = placement, placement.unfilled > 0 || placement.spread != nil {
                self.patternPointer!.initialize(repeating: 0,
                                                count: patternPixels * totalImages)
            }

            // An off-grid path spreads one frame over several scan positions,
            // so the frame is assembled here first and then added into each of
            // them. Nil for every other path, whose frames are built straight
            // into place, which is both faster and exact.
            let spread = placement?.spread
            let gridBuffer: UnsafeMutablePointer<Float32>? = spread != nil
                ? UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
                : nil
            defer { gridBuffer?.deallocate() }

            let floatTempBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: detectorPixels * batchSize)
            defer { floatTempBuffer.deallocate() }

            // Pre-allocate a single pattern-sized buffer for transpose; reused each image
            let transposeBuf: UnsafeMutablePointer<Float32>? = doTranspose
                ? UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
                : nil
            defer { transposeBuf?.deallocate() }

            // Output dimensions after optional transpose
            let outH = doTranspose ? width  : height
            let outW = doTranspose ? height : width

            fileHandle.seek(toFileOffset: firstImageOffset)
            let fracComplete = max(1, Int(Double(storedFrames) * 0.05))

            for batchIndex in 0..<totalBatches {
                if self.dwi?.isCancelled ?? false { return }

                let imagesInBatch = min(batchSize, storedFrames - batchIndex * batchSize)
                let readSize = imagesInBatch * (totalPatternPixels) * elementSize

                let batchData = fileHandle.readData(ofLength: readSize)
                guard batchData.count == readSize else {
                    fail(FileReadError.invalidDimensions)
                    return
                }

                let count = imagesInBatch * totalPatternPixels

                self.convertToFloat(dataType: dataType, sourceData: batchData, destinationBuffer: floatTempBuffer, count: count)

                // Applied here, on the whole batch, before anything looks at a
                // value. This is the one place every stored sample passes
                // through, so doing it here means patterns, detectors, computed
                // images and plugins all see physical units without any of them
                // having to know the file format.
                //
                // `(raw - origin) * scale` as one pass: D = A * scale + (-origin * scale).
                if let intensity = intensity, !intensity.isIdentity {
                    var scale = Float(intensity.scale)
                    var bias = Float(-intensity.origin * intensity.scale)
                    vDSP_vsmsa(floatTempBuffer, 1, &scale, &bias,
                               floatTempBuffer, 1, vDSP_Length(count))
                }


                for img in 0..<imagesInBatch {
                    let globalIndex = batchIndex * batchSize + img
                    if globalIndex >= storedFrames { break }

                    // The one place the scan path acts.
                    //
                    // No two frames share a slot — that was checked before the
                    // read started — so the writes landing out of order is of
                    // no consequence. A frame the positions file marks as not
                    // being at a scan position has no slot at all: it has to be
                    // read, because the frames after it lie beyond it in the
                    // file, and then it is dropped.
                    let slot: Int
                    if let placement = placement {
                        guard let destination = placement.slots[globalIndex] else {
                            if globalIndex % fracComplete == 0 {
                                DispatchQueue.main.async {
                                    nc.post(name: .taskProgressUpdated,
                                            object: Double(globalIndex)/Double(storedFrames))
                                }
                            }
                            continue
                        }
                        slot = destination
                    } else {
                        slot = globalIndex
                    }
                    let outPointer = gridBuffer ?? (self.patternPointer! + slot * patternPixels)
                    let srcPointer = floatTempBuffer + img * (totalPatternPixels)

                    // Determine the source for row operations (possibly transposed)
                    let rowSrc: UnsafeMutablePointer<Float32>
                    if doTranspose, let tb = transposeBuf {
                        // vDSP_mtrans: transposes height×width → width×height (row-major)
                        vDSP_mtrans(srcPointer, 1, tb, 1, vDSP_Length(height), vDSP_Length(width))
                        rowSrc = tb
                    } else {
                        rowSrc = srcPointer
                    }

                    // Copy rows (with optional vertical flip) then reverse each row for horizontal flip
                    for row in 0..<outH {
                        let destRow = doFlipRows ? outH - 1 - row : row
                        let dst = outPointer + destRow * outW
                        let src = rowSrc + row * outW
                        dst.update(from: src, count: outW)
                        if doFlipCols {
                            vDSP_vrvrs(dst, 1, vDSP_Length(outW))
                        }
                    }

                    // Gridding: add this frame into every scan position its
                    // kernel reaches, weighted by how near it fell. The
                    // weights were totalled per position when the path was
                    // gridded, and divide back out once the file is through.
                    if let spread = spread, let gridBuffer = gridBuffer {
                        spread.place(frame: gridBuffer, index: globalIndex,
                                     stride: patternPixels, into: self.patternPointer!)
                    }

                    if globalIndex % fracComplete == 0 {
                        DispatchQueue.main.async {
                            nc.post(name: .taskProgressUpdated, object: Double(globalIndex)/Double(storedFrames))
                        }
                    }
                }
            }

            // The density compensation, once the last frame is in.
            if let spread = spread {
                spread.normalise(self.patternPointer!, stride: patternPixels,
                                 positions: totalImages)
            }

            DispatchQueue.main.async(execute: DispatchWorkItem {
                if doTranspose {
                    self.patternSize = IntSize(width: self.patternSize.height, height: self.patternSize.width)
                }
                _ = self.delegate?.didFinishLoadingData()
                nc.post(name: .fileLoaded, object: nil)
//                self.progressdelegate?.didFinishLoadingData()

//                // Produce a default integrated preview for the viewer (safe detector covering full pattern)
//                let fullDetector = Detector()
//                let previewMatrix = self.integrating(fullDetector, strideLength: 1)
//                #if DEBUG
//                NSLog("[STEMDataController] Creating preview image: matrix size %dx%d", previewMatrix.columns, previewMatrix.rows)
//                #endif
//                if let img = self.nsImage(from: previewMatrix) {
//                    #if DEBUG
//                    NSLog("[STEMDataController] Preview NSImage created (w: %f, h: %f). Posting imageDidUpdateNotification…", img.size.width, img.size.height)
//                    #endif
//                    self.lastRenderedImage = img
//                    NotificationCenter.default.post(name: STEMDataController.imageDidUpdateNotification, object: self, userInfo: ["image": img])
//                } else {
//                    #if DEBUG
//                    NSLog("[STEMDataController] Failed to create NSImage from preview matrix")
//                    #endif
//                }
            })
        }

        DispatchQueue.global().async(execute: dwi!)
    }
    
    /// Decodes an ARINA scan into the pattern buffer, reducing it on the way.
    private func readArina(_ dataset: ArinaDataset, url: URL,
                           patternPixels: Int, totalImages: Int,
                           nc: NotificationCenter) throws {

        let total = patternPixels * totalImages
        guard total > 0 else { throw FileReadError.invalidDimensions }

        self.patternPointer?.deallocate()
        self.patternPointer = UnsafeMutablePointer<Float32>.allocate(capacity: total)

        try ArinaReader.read(dataset, url: url, reduction: dataset.scanBinning > 1
                                ? self.arinaReduction : .bin,
                             into: self.patternPointer!) { [weak self] fraction in
            guard let self = self else { return false }
            if self.dwi?.isCancelled ?? false { return false }
            DispatchQueue.main.async { nc.post(name: .taskProgressUpdated, object: fraction) }
            return true
        }
    }

    /// Streams an EMD stack into the pattern buffer, reporting progress and
    /// honouring cancellation between slabs.
    private func readEMD(_ file: HDF5File, _ dataset: EMDDataset,
                         patternPixels: Int, totalImages: Int,
                         nc: NotificationCenter) throws {

        let total = patternPixels * totalImages
        guard total > 0 else { throw FileReadError.invalidDimensions }

        self.patternPointer?.deallocate()
        self.patternPointer = UnsafeMutablePointer<Float32>.allocate(capacity: total)

        try EMDReader.read(dataset, from: file, into: self.patternPointer!) { [weak self] fraction in
            guard let self = self else { return false }
            if self.dwi?.isCancelled ?? false { return false }
            DispatchQueue.main.async { nc.post(name: .taskProgressUpdated, object: fraction) }
            return true
        }
    }

    func openFileHandle(url:URL){
       
        let bufferStream:FileHandle?
        
        do{
            try bufferStream = FileHandle.init(forReadingFrom: url)
            self.fh = bufferStream
            
        }catch{
#if DEBUG
            print("error creating file handle")
#endif
        }
    }
   

    func averagePattern(rect:NSRect)->Matrix{
        
        let patternPixels = self.patternPixels
        
        // Allocate a mutable buffer for accumulation to avoid dangling pointers
        let adderPointer = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
        adderPointer.initialize(repeating: 0.0, count: patternPixels)
        
        let starti = Int(rect.origin.y)
        let startj = Int(rect.origin.x)
        
        let endi = starti + Int(floor(rect.size.height))
        let endj = startj + Int(floor(rect.size.width))
        var strideDirectioni = 1
        var strideDirectionj = 1

        if starti > endi{
            strideDirectioni = -1
        }

        if startj > endj{
            strideDirectionj = -1
        }
        
        
        var patternCount = 0
        
        for i in stride(from: starti, through: endi, by: strideDirectioni){
            
            for j in stride(from: startj, through: endj, by: strideDirectionj){
                
                let nextPatternPointer = self.patternPointer!+(i*self.imageSize.width+j)*patternPixels
                
                vDSP_vadd(adderPointer, 1, nextPatternPointer, 1, adderPointer, 1, UInt(patternPixels))
                
                patternCount += 1
                }
        }
        
        
        // +1 may be needed for correct average to be inclusive
        var avgScaleFactor = 1.0/Float(patternCount)
        
        vDSP_vsmul(adderPointer, 1, &avgScaleFactor, adderPointer, 1, UInt(patternPixels))
        
        // Materialize result array safely and deallocate buffer
        let adderArray = Array(UnsafeBufferPointer(start: adderPointer, count: patternPixels))
        adderPointer.deinitialize(count: patternPixels)
        adderPointer.deallocate()
        
        return Matrix.init(array: adderArray, patternSize.height, patternSize.width)

        
    }
    
    func dpc(_ detector: Detector, strideLength: Int = 1, lrud: Int = 0) -> Matrix {

        let detectorMask = detector.detectorMask()
        // Matrix(meshIndicesAlong:) uses 0 for x/column indices and 1 for y/row indices.
        // DPC uses lrud = 1 for left-right (x split) and 0 for up-down (y split),
        // so convert explicitly here instead of relying on matching integer values.
        let meshAxis = (lrud == 1) ? 0 : 1
        let indices = Matrix(meshIndicesAlong: meshAxis, patternSize.height, patternSize.width)

        // Split the detector into two complementary halves for differential phase contrast.
        // The DPC signal = leftOrDown intensity − rightOrUp intensity.
        //
        //   Horizontal DPC (lrud == 1): left  half (x < center.x) vs right half (x > center.x)
        //   Vertical DPC   (lrud == 0): lower half (y > center.y) vs upper half (y < center.y)
        //                               (y increases downward in image coordinates)
        let leftOrDownMask: Matrix
        let rightOrUpMask: Matrix

        if lrud == 1 {
            leftOrDownMask = indices < Float(detector.center.x)  // left half of detector
            rightOrUpMask  = indices > Float(detector.center.x)  // right half of detector
        } else {
            leftOrDownMask = indices > Float(detector.center.y)  // lower half of detector
            rightOrUpMask  = indices < Float(detector.center.y)  // upper half of detector
        }

        let (strideWidth, strideHeight) = strideSize(imageSize, strideLength)

        var outArray = [Float](repeating: 0.0, count: strideWidth * strideHeight)

        let patternPixels = self.patternPixels

        // Pre-multiply each directional half mask by the detector aperture mask
        let leftOrDownDetectorMask = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
        let rightOrUpDetectorMask  = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
        let leftOrDownIntensity    = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
        let rightOrUpIntensity     = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)

        vDSP_vmul(detectorMask.real, 1, leftOrDownMask.real, 1, leftOrDownDetectorMask, 1, UInt(patternPixels))
        vDSP_vmul(detectorMask.real, 1, rightOrUpMask.real,  1, rightOrUpDetectorMask,  1, UInt(patternPixels))

        let leftOrDownSum = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
        let rightOrUpSum  = UnsafeMutablePointer<Float32>.allocate(capacity: 1)

        var pos = 0

        for i in stride(from: 0, to: self.imageSize.height, by: strideLength) {
            for j in stride(from: 0, to: self.imageSize.width, by: strideLength) {

                let patternPointer = self.patternPointer! + (i * self.imageSize.width + j) * patternPixels

                // Apply each masked detector half to the diffraction pattern
                vDSP_vmul(leftOrDownDetectorMask, 1, patternPointer, 1, leftOrDownIntensity, 1, UInt(patternPixels))
                vDSP_vmul(rightOrUpDetectorMask,  1, patternPointer, 1, rightOrUpIntensity,  1, UInt(patternPixels))

                // Sum the intensities in each half
                vDSP_sve(leftOrDownIntensity, 1, leftOrDownSum, UInt(patternPixels))
                vDSP_sve(rightOrUpIntensity,  1, rightOrUpSum,  UInt(patternPixels))

                // Horizontal DPC: R-L; Vertical DPC: D-U
                outArray[pos] = lrud == 1
                    ? rightOrUpSum.pointee - leftOrDownSum.pointee
                    : leftOrDownSum.pointee - rightOrUpSum.pointee
                pos += 1
            }
        }

        return Matrix(array: outArray, strideHeight, strideWidth)
    }
    
    func com(_ detector:Detector,strideLength:Int = 1, xy:COMAxis = .x)->Matrix{
    
        let mask = detector.detectorMask()
        
        let group = DispatchGroup()
        group.enter()
    
        let (strideWidth, strideHeight) = strideSize(imageSize, strideLength)
        
        var outArray = [Float].init(repeating: 0.0, count: Int(strideWidth*strideHeight))

        let indices = Matrix.init(meshIndicesAlong: xy.rawValue, patternSize.height, patternSize.width)
        
        var shifted = indices.real
                
        let c:Float
        if xy == .x {
            c = Float(detector.center.x)
        }else {
            c = Float(detector.center.y)
        }
        
        vDSP_vsadd(shifted, 1, [-c], &shifted, 1, vDSP_Length(shifted.count))

        DispatchQueue.global(qos: .userInteractive).sync {
        
            let patternPixels = self.patternPixels
            let maskPatternProduct = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
            let indexWeighted = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
            
            let pixelSum = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
            
            var pos = 0
            
            for i in stride(from: 0, to: self.imageSize.height, by: strideLength){
                for j in stride(from: 0, to: self.imageSize.width, by: strideLength){
                
                    let nextPatternPointer = self.patternPointer!+(i*self.imageSize.width+j)*patternPixels
                    
                    vDSP_vmul(mask.real, 1, nextPatternPointer, 1, maskPatternProduct, 1, UInt(patternPixels))
                    
                    vDSP_vmul(maskPatternProduct, 1, shifted, 1, indexWeighted, 1, UInt(patternPixels))
                    
                    vDSP_sve(maskPatternProduct, 1, pixelSum, UInt(patternPixels))

                    let intSum = pixelSum.pointee
                    
            
                    vDSP_sve(indexWeighted, 1, pixelSum, UInt(patternPixels))

                    outArray[pos] = pixelSum.pointee/intSum
                    pos += 1
                }
            }
            maskPatternProduct.deallocate()

            group.leave()

        }
        
        
        group.wait()
        
        return Matrix.init(array: outArray, strideHeight, strideWidth)
    }
    
    /// The image a one-pixel detector forms, read directly.
    ///
    /// The general path below would find the same number by multiplying the
    /// whole pattern by a mask that is zero everywhere except one pixel and
    /// summing the result — sixteen thousand multiplies and sixteen thousand
    /// adds, per probe position, to fetch a value already sitting at a known
    /// offset. Reading it is what makes a point detector cheap enough to compute
    /// over the whole scan while the crosshair is being dragged, instead of on a
    /// subsampled grid.
    private func pointImage(atPatternIndex index: Int, strideLength: Int) -> Matrix {
        let (strideWidth, strideHeight) = strideSize(imageSize, strideLength)
        var outArray = [Float](repeating: 0, count: strideWidth * strideHeight)

        guard let base = patternPointer, index >= 0, index < patternPixels else {
            return Matrix(array: outArray, strideHeight, strideWidth)
        }

        let pixels = patternPixels
        let width = imageSize.width
        var pos = 0
        for i in stride(from: 0, to: imageSize.height, by: strideLength) {
            for j in stride(from: 0, to: width, by: strideLength) {
                outArray[pos] = base[(i * width + j) * pixels + index]
                pos += 1
            }
        }
        return Matrix(array: outArray, strideHeight, strideWidth)
    }

    /// The single pattern pixel a point detector selects, or nil when this is
    /// not a point detector or its geometry does not match the loaded patterns.
    ///
    /// The rounding is `ApertureFactory.point`'s, so the fast path and the mask
    /// it replaces always choose the same pixel; a detector built against a
    /// different pattern size falls through to the general path rather than
    /// indexing with a stale geometry.
    private func pointPatternIndex(for detector: Detector) -> Int? {
        guard detector.shape == .point else { return nil }
        guard Int(detector.size.width) == patternSize.width,
              Int(detector.size.height) == patternSize.height else { return nil }
        let x = Int(detector.center.x.rounded())
        let y = Int(detector.center.y.rounded())
        guard x >= 0, x < patternSize.width, y >= 0, y < patternSize.height else { return nil }
        return y * patternSize.width + x
    }

    func integrating(_ detector:Detector,strideLength:Int = 1) ->Matrix{

        if let index = pointPatternIndex(for: detector) {
            return pointImage(atPatternIndex: index, strideLength: strideLength)
        }

        let mask = detector.detectorMask()
        
//        let group = DispatchGroup()
//        group.enter()
        
        let (strideWidth, strideHeight) = strideSize(imageSize, strideLength)
        
        var outArray = [Float].init(repeating: 0.0, count: strideWidth*strideHeight)
        
//        DispatchQueue.global(qos: .default).sync {
        
//            let patternPixels = UInt(self.patternPixels)
        let c = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)

            let pixelSum = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
            
            var pos = 0

            for i in stride(from: 0, to: self.imageSize.height, by: strideLength){
                for j in stride(from: 0, to: self.imageSize.width, by: strideLength){
                   
                    let nextPatternPointer = self.patternPointer!+(i*self.imageSize.width+j)*patternSize.width*patternSize.height
                    
                    vDSP_vmul(mask.real, 1, nextPatternPointer, 1, c, 1, UInt(patternPixels))
                    
                    vDSP_sve(c, 1, pixelSum, UInt(patternPixels))
                    
                    outArray[pos] = pixelSum[0]
                    pos += 1
                }
            }
            
            c.deallocate()
            
//            group.leave()
//        }
//        
//        group.wait()
//        
        
        return Matrix.init(array: outArray, Int(strideHeight), Int(strideWidth))
        
    }
    
    private func hsvToRGB(h: [Float], s: [Float], v: [Float]) -> [UInt8] {
        // Convert HSV float arrays to RGB UInt8 array (3 components per pixel)
        // h, s, v expected in [0,1]
        // Output RGB in [0,255]
        let count = h.count
        var rgb = [UInt8](repeating: 0, count: count * 3)
        
        for i in 0..<count {
            let hue = h[i] * 6.0
            let saturation = s[i]
            let value = v[i]
            
            let c = value * saturation
            let x = c * (1 - abs(fmod(hue, 2.0) - 1))
            let m = value - c
            
            var r1: Float = 0
            var g1: Float = 0
            var b1: Float = 0
            
            switch Int(hue) {
            case 0:
                r1 = c; g1 = x; b1 = 0
            case 1:
                r1 = x; g1 = c; b1 = 0
            case 2:
                r1 = 0; g1 = c; b1 = x
            case 3:
                r1 = 0; g1 = x; b1 = c
            case 4:
                r1 = x; g1 = 0; b1 = c
            case 5:
                r1 = c; g1 = 0; b1 = x
            default:
                r1 = 0; g1 = 0; b1 = 0
            }
            
            let r = UInt8(max(0, min(255, Int((r1 + m) * 255))))
            let g = UInt8(max(0, min(255, Int((g1 + m) * 255))))
            let b = UInt8(max(0, min(255, Int((b1 + m) * 255))))
            
            rgb[i * 3] = r
            rgb[i * 3 + 1] = g
            rgb[i * 3 + 2] = b
        }
        
        return rgb
    }
    
    // MARK: - Rendering helpers for ImageViewerRepresentable
    private func nsImage(from pixelBuffer: CVPixelBuffer) -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rep = NSCIImageRep(ciImage: ciImage)
        let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        img.addRepresentation(rep)
        return img
    }

    private func nsImage(from matrix: Matrix) -> NSImage? {
        let rows = matrix.rows
        let cols = matrix.columns
        var data = matrix.real
        guard rows > 0, cols > 0, !data.isEmpty else { return nil }
        if let minVal = data.min(), let maxVal = data.max(), maxVal > minVal {
            let scale = 255.0 / (maxVal - minVal)
            let offset = -minVal * scale
            vDSP_vsmsa(data, 1, [scale], [offset], &data, 1, vDSP_Length(data.count))
        }
        var u8 = [UInt8](repeating: 0, count: data.count)
        vDSP_vfixu8(data, 1, &u8, 1, vDSP_Length(data.count))
        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(u8) as CFData) else { return nil }
        guard let cg = CGImage(width: cols,
                               height: rows,
                               bitsPerComponent: 8,
                               bitsPerPixel: 8,
                               bytesPerRow: cols,
                               space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider,
                               decode: nil,
                               shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }
        let img = NSImage(size: NSSize(width: cols, height: rows))
        img.addRepresentation(NSBitmapImageRep(cgImage: cg))
        return img
    }
    
    deinit {
        fh?.closeFile()
        patternPointer?.deinitialize()
    }

}

// Needed to ceil the stride size to avoid stride overruns

func strideSize(_ imageSize:IntSize, _ strideLength:Int)->(Int, Int){
    
    let strideWidth = Int(ceil(Double(imageSize.width)/Double(strideLength)))
    let strideHeight = Int(ceil(Double(imageSize.height)/Double(strideLength)))
    
    return (strideWidth, strideHeight)
}





