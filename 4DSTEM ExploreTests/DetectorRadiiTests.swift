//
//  DetectorRadiiTests.swift
//  4DSTEM ExploreTests
//
//  The rule that keeps an annular detector's two radii apart. Small, entirely
//  about arithmetic at the boundaries, and previously wrong in two ways at
//  once: the radii could meet, and the inner one could never push the outer.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Testing
import CoreGraphics
@testable import _DSTEM_Explorer

@Suite("Annular detector radii")
struct DetectorRadiiTests {

    private let gap = DetectorRadii.minimumSeparation
    private let ceiling: CGFloat = 64        // a 128-pixel detector

    @Test("driving one into the other still leaves an annulus")
    func theTwoNeverMeet() {
        // They used to be clamped against each other and could land equal — an
        // annulus of zero width, collecting nothing.
        let a = DetectorRadii.movingInner(to: 40, outer: 20, ceiling: ceiling)
        #expect(a.outer - a.inner >= gap)
        let b = DetectorRadii.movingOuter(to: 5, inner: 30, ceiling: ceiling)
        #expect(b.outer - b.inner >= gap)
    }

    @Test("the radius being moved goes where it was put")
    func theMovedRadiusIsNotClamped() {
        // The old code clamped the moved one instead of moving the other, so
        // the control stopped responding under the user's finger.
        let a = DetectorRadii.movingInner(to: 40, outer: 20, ceiling: ceiling)
        #expect(a.inner == 40)
        #expect(a.outer == 41)

        let b = DetectorRadii.movingOuter(to: 5, inner: 30, ceiling: ceiling)
        #expect(b.outer == 5)
        #expect(b.inner == 4)
    }

    @Test("the other one is left alone when there is room")
    func noNeedlessPush() {
        let a = DetectorRadii.movingInner(to: 10, outer: 50, ceiling: ceiling)
        #expect(a.inner == 10 && a.outer == 50)
        let b = DetectorRadii.movingOuter(to: 50, inner: 10, ceiling: ceiling)
        #expect(b.inner == 10 && b.outer == 50)
    }

    @Test("only at the edge of the detector does the moved one give ground")
    func theMovedRadiusYieldsOnlyAtTheLimits() {
        let a = DetectorRadii.movingInner(to: ceiling, outer: 20, ceiling: ceiling)
        #expect(a.outer == ceiling)
        #expect(a.inner == ceiling - gap)

        let b = DetectorRadii.movingOuter(to: 0, inner: 30, ceiling: ceiling)
        #expect(b.inner == DetectorRadii.minimumInner)
        #expect(b.outer == DetectorRadii.minimumInner + gap)
    }

    @Test("the control ranges let each one push the other")
    func rangesAllowPushing() {
        // The inner slider used to run 1...outer, which is precisely why it
        // could never widen the annulus from the inside.
        let inner = DetectorRadii.innerRange(ceiling: ceiling)
        let outer = DetectorRadii.outerRange(ceiling: ceiling)
        #expect(inner.upperBound == Double(ceiling - gap))
        #expect(outer.lowerBound == Double(DetectorRadii.minimumInner + gap))
        #expect(inner.lowerBound < inner.upperBound)
        #expect(outer.lowerBound < outer.upperBound)
    }

    @Test("a degenerate detector cannot produce an empty slider range",
          arguments: [CGFloat(0), 0.5, 1, 2])
    func degenerateCeilingsStayUsable(tiny: CGFloat) {
        // An empty or inverted range is a crash, not a clamped control.
        let inner = DetectorRadii.innerRange(ceiling: tiny)
        let outer = DetectorRadii.outerRange(ceiling: tiny)
        #expect(inner.lowerBound < inner.upperBound)
        #expect(outer.lowerBound < outer.upperBound)
    }

    @Test("values arriving from elsewhere are settled too")
    func settledHandlesArbitraryPairs() {
        // A drag on the pattern moves both at once and writes straight to the
        // stored detector; a saved detector may predate the rule entirely.
        for (i, o) in [(CGFloat(30), CGFloat(30)), (50, 10), (0, 0), (100, 200)] {
            let s = DetectorRadii.settled(inner: i, outer: o, ceiling: ceiling)
            #expect(s.outer - s.inner >= gap)
            #expect(s.inner >= DetectorRadii.minimumInner)
            #expect(s.outer <= ceiling)
        }
    }

    @Test("settling something already valid leaves it be")
    func settledIsIdempotentOnValidInput() {
        let s = DetectorRadii.settled(inner: 12, outer: 40, ceiling: ceiling)
        #expect(s.inner == 12 && s.outer == 40)
    }
}
