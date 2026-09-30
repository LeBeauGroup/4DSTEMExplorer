//
//  EMPADLayout.swift
//  4DSTEM Explorer
//
//  How an EMPAD RAW file lays out one diffraction pattern, and how to tell
//  which one wrote a given file.
//
//  The first EMPAD appends two rows of per-frame metadata to every 128×128
//  pattern, so a frame occupies 130 rows and the last two are discarded on
//  read. The second does not: a frame is 128×128 and nothing is discarded.
//
//  Nothing in the file says which it is — there is no header and no magic
//  number. But the two put a different number of bytes on disk for the same
//  scan, and for any raster the sizes they predict differ, so the file's own
//  length settles it. That is better than asking: a checkbox on the open panel
//  is a question most people cannot answer about a file they were handed, and
//  getting it wrong does not fail loudly. It reads the metadata rows as data
//  and shears every pattern by two rows per frame, which looks like a badly
//  aligned detector rather than like a mistake.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

struct EMPADLayout: Equatable {

    /// Pixels across one pattern.
    let columns: Int
    /// Rows of image data in one pattern.
    let rows: Int
    /// Rows written after the image data that are not image data.
    let metadataRows: Int

    /// EMPAD, 128×128 with two rows of per-frame metadata appended.
    static let first = EMPADLayout(columns: 128, rows: 128, metadataRows: 2)
    /// EMPAD2, 128×128 with nothing appended.
    static let second = EMPADLayout(columns: 128, rows: 128, metadataRows: 0)

    /// Tried in this order, so a file that somehow matched both would be read
    /// the way it always has been.
    static let known = [first, second]

    var name: String { return metadataRows > 0 ? "EMPAD" : "EMPAD2" }

    /// Rows actually stored per frame, metadata included.
    var storedRows: Int { return rows + metadataRows }

    func bytesPerPattern(elementSize: Int) -> Int {
        return storedRows * columns * elementSize
    }

    // MARK: - Choosing

    /// The layout and sample type that account for the file exactly.
    ///
    /// With the raster known this is a division, not a guess: a frame is either
    /// 130 rows or 128, and for a given number of frames only one of those
    /// multiplies up to the file's length. The sample type is searched
    /// alongside because a wrong pairing cannot compensate for a wrong layout —
    /// no combination of the two collides, since 65·e₁ = 64·e₂ has no solution
    /// in the element sizes on offer.
    ///
    /// - Parameter scanPixels: number of probe positions, when known. Without
    ///   it the file can only be divided, which is weaker: see `infer`.
    static func choose(fileSize: Int, scanPixels: Int,
                       elementSizes: [Int]) -> (layout: EMPADLayout, elementSize: Int)? {
        guard fileSize > 0, scanPixels > 0 else { return nil }
        for layout in known {
            for elementSize in elementSizes
            where layout.bytesPerPattern(elementSize: elementSize) * scanPixels == fileSize {
                return (layout, elementSize)
            }
        }
        return nil
    }

    /// The layout when the raster is not known, from the file's length alone.
    ///
    /// Weaker, and deliberately conservative. A length divisible by both frame
    /// sizes cannot be resolved by division, so the tie is broken towards a
    /// frame count that is a perfect square — a raster is square far more often
    /// than not — and failing that towards the original EMPAD, which is how
    /// every such file has been read until now.
    static func infer(fileSize: Int, elementSize: Int) -> EMPADLayout? {
        guard fileSize > 0 else { return nil }
        let fitting = known.filter {
            let bytes = $0.bytesPerPattern(elementSize: elementSize)
            return bytes > 0 && fileSize % bytes == 0
        }
        if fitting.count <= 1 { return fitting.first }
        let square = fitting.first {
            let frames = fileSize / $0.bytesPerPattern(elementSize: elementSize)
            let root = Int(Double(frames).squareRoot().rounded())
            return root * root == frames
        }
        return square ?? fitting.first
    }
}
