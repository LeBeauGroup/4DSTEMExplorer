//
//  ACBFZeroingTests.swift
//  4DSTEM ExploreTests
//
//  "Zero Aberrations" cleared the coefficient vector and then let the three
//  controls write their old values straight back over it, so defocus and
//  astigmatism returned instantly and the sliders never moved. Only the higher
//  orders — which have no control to restore them — actually cleared, which is
//  why the button looked half-broken rather than dead.
//
//  ACBFAberrations.swift is compiled into this bundle directly: it lives in the
//  plugin SDK rather than the application, so `@testable import` cannot reach
//  it.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Testing

@Suite("acBF zeroing")
struct ACBFZeroingTests {

    /// Order 2: defocus and astigmatism have controls, coma and threefold do not.
    private let orders = ACBFOrders(maxOrder: 2)

    /// Everything non-zero, the way it looks after Refine All.
    private var refined: [Double] {
        (0..<orders.coefficientCount).map { Double($0 + 1) * 37.5 }
    }

    @Test("zeroing clears the terms that have controls, not just the ones without")
    func zeroingClearsControlBackedTerms() throws {
        let ci = try #require(orders.defocusIndex)
        let (ia, ib) = try #require(orders.astigmatismIndices)
        let stored = refined

        // The controls hold the values being cleared — that is the whole point,
        // since the button is pressed precisely when they are non-zero.
        let out = orders.coefficients(storedIn: stored,
                                      defocus: stored[ci],
                                      astigmatismA: stored[ia],
                                      astigmatismB: stored[ib],
                                      zeroingAll: true)
        #expect(out[ci] == 0)
        #expect(out[ia] == 0)
        #expect(out[ib] == 0)
        #expect(out.allSatisfy { $0 == 0 })
        #expect(out.count == orders.coefficientCount)
    }

    @Test("every order clears, not only the ones without controls",
          arguments: 1...4)
    func zeroingClearsEveryOrder(order: Int) {
        let o = ACBFOrders(maxOrder: order)
        let stored = (0..<o.coefficientCount).map { Double($0 + 1) }
        let out = o.coefficients(storedIn: stored, defocus: 500, astigmatismA: 60,
                                 astigmatismB: -20, zeroingAll: true)
        #expect(out.count == o.coefficientCount)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test("the controls still win when not zeroing")
    func controlsWinOtherwise() throws {
        // This is what makes dragging defocus refocus the image live, rather
        // than being overridden by whatever was last refined.
        let ci = try #require(orders.defocusIndex)
        let (ia, ib) = try #require(orders.astigmatismIndices)
        let stored = refined

        let out = orders.coefficients(storedIn: stored, defocus: -1234,
                                      astigmatismA: 11, astigmatismB: -22,
                                      zeroingAll: false)
        #expect(out[ci] == -1234)
        #expect(out[ia] == 11)
        #expect(out[ib] == -22)

        // Refinement is the only thing that sets the higher orders, so a slider
        // drag must not discard them.
        let higher = (0..<out.count).filter { $0 != ci && $0 != ia && $0 != ib }
        #expect(!higher.isEmpty)
        #expect(higher.allSatisfy { out[$0] == stored[$0] })
    }

    @Test("a control that is absent leaves its coefficient alone")
    func absentControlsChangeNothing() {
        let stored = refined
        let out = orders.coefficients(storedIn: stored, defocus: nil,
                                      astigmatismA: nil, astigmatismB: nil,
                                      zeroingAll: false)
        #expect(out == stored)
    }

    @Test("a vector of the wrong length cannot index off the end")
    func wrongLengthIsSurvivable() throws {
        // The caller resizes on (n, m) before this runs, so a mismatch should
        // not happen — but it must not be a crash if it ever does.
        let grown = ACBFOrders(maxOrder: 3)
        let short = [Double](repeating: 5, count: 2)
        let up = grown.coefficients(storedIn: short, defocus: 100,
                                    astigmatismA: nil, astigmatismB: nil,
                                    zeroingAll: false)
        #expect(up.count == grown.coefficientCount)
        #expect(up[try #require(grown.defocusIndex)] == 100)

        let long = [Double](repeating: 9, count: grown.coefficientCount + 40)
        let down = grown.coefficients(storedIn: long, defocus: nil,
                                      astigmatismA: nil, astigmatismB: nil,
                                      zeroingAll: false)
        #expect(down.count == grown.coefficientCount)

        let zeroed = grown.coefficients(storedIn: short, defocus: 1,
                                        astigmatismA: 2, astigmatismB: 3,
                                        zeroingAll: true)
        #expect(zeroed.count == grown.coefficientCount)
        #expect(zeroed.allSatisfy { $0 == 0 })
    }
}
