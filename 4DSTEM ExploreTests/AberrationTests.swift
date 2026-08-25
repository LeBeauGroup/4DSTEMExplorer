//
//  AberrationTests.swift
//  4DSTEM ExploreTests
//
//  What acBF measures has to survive the journey into the metadata file and out
//  the other side into a reconstruction. Every step of that is silent when
//  wrong — the numbers stay plausible and the probe is simply not the one that
//  was measured — so each is pinned here.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Testing
@testable import _DSTEM_Explorer

@Suite("Aberrations written for phaser")
struct AberrationTests {

    /// As acBF lays out its vector: width 1 for m == 0, an (a, b) pair otherwise.
    private let refined = [
        Aberration(n: 1, m: 0, a: -250.0),          // C1 defocus
        Aberration(n: 1, m: 2, a: 12.5, b: -3.0),   // A1 astigmatism
        Aberration(n: 2, m: 1, a: 400.0, b: 90.0),  // B2 coma
        Aberration(n: 3, m: 0, a: -12000.0)         // C3 spherical
    ]

    @Test("a symmetric term has no sine half")
    func symmetricTermsHaveNoImaginaryPart() {
        #expect(Aberration(n: 1, m: 0, a: -250.0).b == 0)
        // Supplied anyway, it is discarded rather than written out.
        #expect(Aberration(n: 3, m: 0, a: 1, b: 99).b == 0)
    }

    @Test("C1 is written as defocus, in metres, and nowhere else")
    func defocusIsWrittenOnce() throws {
        // The probe model adds defocus/2·θ² *and* the aberration surface, whose
        // (1, 0) term is exactly C1·θ²/2. A C1 in both places is applied twice.
        let metres = try #require(refined.defocusMetres)
        #expect(abs(metres - -2.5e-8) <= 1e-20)

        let rest = refined.phaserAberrations
        #expect(!rest.contains { ($0["nm"] as? String) == "10" })
        #expect(rest.count == 3)
    }

    @Test("positive stays overfocus")
    func defocusSignIsPreserved() throws {
        // Both conventions call positive overfocus, so only the unit changes.
        #expect(try #require([Aberration(n: 1, m: 0, a: 250.0)].defocusMetres) > 0)
        #expect(try #require([Aberration(n: 1, m: 0, a: -250.0)].defocusMetres) < 0)
    }

    @Test("the order travels as one nm field, a character per index")
    func orderIsOneField() {
        #expect(Aberration(n: 0, m: 1, a: 1).nm == "01")
        #expect(Aberration(n: 1, m: 2, a: 1, b: 2).nm == "12")
        #expect(Aberration(n: 5, m: 0, a: 1).nm == "50")

        let b2 = Aberration(n: 2, m: 1, a: 400.0, b: 90.0).dictionary
        #expect(b2["nm"] as? String == "21")
        #expect(b2["re"] as? Double == 400.0)
        #expect(b2["im"] as? Double == 90.0)
        #expect(b2.count == 3)
        // Never under a coefficient's name: the reader trebles a named b2
        // (C_21 = 3·B2) and quadruples b4 and d4.
        #expect(b2["b2"] == nil)
    }

    @Test("an nm string that is not exactly two digits is refused")
    func ambiguousOrdersAreRefused() {
        // "123" is (1, 23) or (12, 3) with nothing to say which.
        let bad: [[String: Any]] = [
            ["nm": "123", "re": 1.0],
            ["nm": "1", "re": 1.0],
            ["nm": "", "re": 1.0],
            ["nm": "1x", "re": 1.0],
            ["nm": 12, "re": 1.0],          // a number, not the string form
        ]
        #expect(Aberration.list(bad).isEmpty)
    }

    @Test("the older two-field form is still read")
    func legacyTwoFieldFormIsAccepted() throws {
        // A plugin bundle is built separately from the host and may be older
        // than it; a stale plugin should not have its measurement dropped.
        let old = try #require(Aberration(["n": 1, "m": 2, "re": 12.5, "im": -3.0]))
        #expect(old == Aberration(n: 1, m: 2, a: 12.5, b: -3.0))
        #expect(old.nm == "12")
    }

    @Test("what a plugin sends is what the host reads")
    func roundTripsThroughThePluginBoundary() {
        let wire = refined.map { $0.dictionary }
        #expect(Aberration.list(wire) == refined)
    }

    @Test("malformed terms are dropped rather than guessed at")
    func malformedTermsAreRefused() {
        // The Krivanek constraints the reader itself enforces: m ≤ n + 1, and
        // n + 1 − m even. A term breaking them is rejected downstream.
        let bad: [[String: Any]] = [
            ["n": 1, "m": 1, "re": 1.0],
            ["n": 1, "m": 5, "re": 1.0],
            ["n": 2, "re": 1.0],
            ["m": 2, "re": 1.0],
            ["n": 1, "m": 2, "re": Double.nan],
        ]
        #expect(Aberration.list(bad).isEmpty)
        #expect(Aberration.list(nil).isEmpty)
        // While a valid one with the imaginary half omitted is kept.
        #expect(Aberration.list([["n": 1, "m": 2, "re": 5.0]]).count == 1)
    }

    @Test("ordering is stable, so the files diff cleanly")
    func orderingIsStable() {
        let shuffled = [Aberration(n: 3, m: 0, a: 1),
                        Aberration(n: 1, m: 2, a: 2, b: 3),
                        Aberration(n: 2, m: 1, a: 4, b: 5)]
        let order = shuffled.phaserAberrations.compactMap { $0["nm"] as? String }
        #expect(order == ["12", "21", "30"])
    }

    @Test("a zero coefficient is not a measurement")
    func zeroTermsAreOmitted() {
        #expect([Aberration(n: 1, m: 2, a: 0, b: 0),
                 Aberration(n: 3, m: 0, a: 5)].phaserAberrations.count == 1)
        #expect([Aberration(n: 1, m: 0, a: 0)].defocusMetres == nil)
    }
}
