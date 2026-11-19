//
//  DetectorMathTests.swift
//  4DSTEM ExploreTests
//
//  A detector built from others has to follow them, and the arithmetic on the
//  masks has to be the arithmetic it says it is.
//
//  Copyright © 2026 The LeBeau Group. All rights reserved.
//

import Testing
import Foundation
import CoreGraphics
@testable import _DSTEM_Explorer

@Suite("Detector math")
struct DetectorMathTests {

    private func disc(_ x: CGFloat, _ r: Float) -> Detector {
        Detector(shape: .bf, type: .integrating, center: NSPoint(x: x, y: 16),
                 params: [.innerRadius: 0, .outerRadius: r], size: NSSize(width: 32, height: 32))
    }

    private func combined(_ op: DetectorMath, _ parts: [Detector]) -> Matrix {
        let d = Detector(shape: .custom, type: .integrating, center: .zero, params: [:],
                         size: NSSize(width: 32, height: 32))
        d.combination = (op, parts)
        return d.detectorMask()
    }

    @Test("add, subtract and multiply act on the masks pixel by pixel")
    func arithmetic() {
        let a = disc(12, 6), b = disc(20, 6)
        let ma = a.detectorMask().real, mb = b.detectorMask().real
        #expect(combined(.add, [a, b]).real == zip(ma, mb).map { $0 + $1 })
        #expect(combined(.subtract, [a, b]).real == zip(ma, mb).map { $0 - $1 })
        #expect(combined(.multiply, [a, b]).real == zip(ma, mb).map { $0 * $1 })
        // The discs overlap, so the product is non-empty and smaller than either.
        let product = combined(.multiply, [a, b]).real.reduce(0, +)
        #expect(product > 0 && product < ma.reduce(0, +))
    }

    @Test("a combined detector follows a source that moves")
    func linked() {
        let a = disc(12, 6), b = disc(20, 6)
        let before = combined(.add, [a, b]).real
        a.center = NSPoint(x: 8, y: 16)
        let d = Detector(shape: .custom, type: .integrating, center: .zero, params: [:],
                         size: NSSize(width: 32, height: 32))
        d.combination = (.add, [a, b])
        let first = d.detectorMask().real
        b.center = NSPoint(x: 24, y: 16)
        #expect(first != before)
        #expect(d.detectorMask().real != first)
    }

    @Test("the model makes the detector, shows the sources, and removes dependants")
    func model() {
        let m = DataViewModel()
        m.addDetector()
        let ids = Set(m.detectors.map(\.id))
        m.addMathDetector(.subtract, from: ids)

        #expect(m.detectors.count == 3)
        let made = m.detectors.last!
        #expect(made.math?.op == .subtract)
        #expect(made.math?.sources == m.detectors.prefix(2).map(\.id))
        #expect(made.name.contains("\u{2212}"))
        #expect(m.selectedDetectorIDs == [made.id])
        // Only the sources are drawn, never the math detector itself.
        #expect(Set(m.overlayDetectors.map(\.id)) == ids)

        // One detector is not enough to combine.
        let before = m.detectors.count
        m.addMathDetector(.add, from: [m.detectors[0].id])
        #expect(m.detectors.count == before)

        // Removing a source takes what was built from it.
        m.selectedDetectorIDs = [m.detectors[0].id]
        m.removeSelectedDetector()
        #expect(!m.detectors.contains { $0.math != nil })
        #expect(m.detectors.count == 1)
    }
}
