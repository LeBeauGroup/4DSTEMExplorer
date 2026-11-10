//
//  ACBFSignTests.swift
//  4DSTEM ExploreTests
//
//  The sign conventions of the acBF aberration model, pinned.
//
//  Every one of these is silent when it is wrong. A defocus reported with the
//  wrong sign still reconstructs a sharp image — the refinement simply finds
//  the other sign — and the number only becomes wrong when it is read by a
//  person or written into a ptychography input. A rotation with the wrong sense
//  is worse: it is absorbed by the astigmatism azimuth, which is partly
//  degenerate with it, so the fit still converges.
//
//  ACBFAberrations.swift is compiled into this bundle directly, as
//  ACBFZeroingTests notes: it lives in the plugin SDK rather than the
//  application, so `@testable import` cannot reach it.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Testing
import Foundation

@Suite("acBF sign conventions")
struct ACBFSignTests {

    private let wavelength = ACBFOptics.wavelength(kilovolts: 300)
    private var orders: ACBFOrders { ACBFOrders(maxOrder: 1) }
    private var function: ACBFAberrationFunction {
        ACBFAberrationFunction(orders: orders, wavelength: wavelength)
    }

    @Test("chi carries defocus with a positive sign")
    func defocusPhase() {
        // chi = 2*pi/lambda * C1/2 * alpha^2 = pi * C1 * lambda * k^2.
        let c1 = 1000.0
        let k = 0.4
        let expected = Double.pi * c1 * wavelength * k * k
        let chi = function.chi(kx: k, ky: 0, coefficients: [c1, 0, 0])
        #expect(abs(chi - expected) < 1e-9 * abs(expected))
        // And it is the sign of the coefficient, not its magnitude, that flips.
        #expect(function.chi(kx: k, ky: 0, coefficients: [-c1, 0, 0]) == -chi)
    }

    @Test("the correction is the gradient of chi, not its negative")
    func gradientSign() {
        let coefficients = [1234.5, 200, -150]
        let k = (x: 0.37, y: -0.21)
        let h = 1e-6
        let gradientX = (function.chi(kx: k.x + h, ky: k.y, coefficients: coefficients)
                       - function.chi(kx: k.x - h, ky: k.y, coefficients: coefficients)) / (2 * h)
        let gradientY = (function.chi(kx: k.x, ky: k.y + h, coefficients: coefficients)
                       - function.chi(kx: k.x, ky: k.y - h, coefficients: coefficients)) / (2 * h)
        let shift = function.shift(kx: k.x, ky: k.y, coefficients: coefficients)
        #expect(abs(shift.dx - gradientX / (2 * .pi)) < 1e-6 * abs(shift.dx))
        #expect(abs(shift.dy - gradientY / (2 * .pi)) < 1e-6 * abs(shift.dy))
    }

    @Test("a positive defocus sends a sub-beam outwards, which is overfocus")
    func defocusIsOverfocus() {
        // The correction for defocus is +C1 * alpha, radially outwards for a
        // positive C1. That is where the sub-beam at angle alpha sits in the
        // specimen plane, so the crossover is C1 *above* it — the lens is too
        // strong, which is overfocus. The control's help text says as much, and
        // Aberration.defocusMetres hands the same sign to phaser.
        let c1 = 1000.0
        let k = 0.5
        let shift = function.shift(kx: k, ky: 0, coefficients: [c1, 0, 0])
        #expect(abs(shift.dx - c1 * k * wavelength) < 1e-9 * c1 * k * wavelength)
        #expect(shift.dx > 0)
        // Perpendicular to the tilt there is nothing: defocus is isotropic, and
        // a stray term here would be astigmatism.
        #expect(shift.dy == 0)
    }

    @Test("defocus is the one aberration no rotation can hide")
    func defocusIsIsotropic() {
        var transform = ACBFCoordinateTransform()
        let defocus = [500.0, 0, 0]
        for angle in [0.0, 17.0, -94.0, 180.0] {
            transform.rotationDegrees = angle
            #expect(transform.rotateCoefficients(defocus, orders: orders) == defocus)
        }
    }

    @Test("a positive rotation turns counter-clockwise as the pattern is drawn")
    func rotationSense() {
        // +y is the pattern's row offset and rows run downwards, so -y is up:
        // a positive angle takes right to up, which is counter-clockwise on
        // screen, and a negative angle turns clockwise. The textbook matrix
        // turns the other way here, which is why the angle is negated going in.
        var transform = ACBFCoordinateTransform()
        transform.rotationDegrees = 90
        let turned = transform.apply(kx: 1, ky: 0)
        #expect(abs(turned.kx) < 1e-12)
        #expect(abs(turned.ky + 1) < 1e-12)

        // And the other way for a negative angle: right goes to down.
        transform.rotationDegrees = -90
        let back = transform.apply(kx: 1, ky: 0)
        #expect(abs(back.kx) < 1e-12)
        #expect(abs(back.ky - 1) < 1e-12)
    }

    @Test("an m-fold term rotates m times as fast, in the same sense")
    func coefficientRotation() {
        // Twofold astigmatism, pure a, rotated by 45 degrees: m * theta is 90,
        // so it comes out as pure b — negative, for the same reason the
        // coordinate above turns towards -y.
        var transform = ACBFCoordinateTransform()
        transform.rotationDegrees = 45
        let rotated = transform.rotateCoefficients([0, 100, 0], orders: orders)
        #expect(abs(rotated[1]) < 1e-9)
        #expect(abs(rotated[2] + 100) < 1e-9)
    }

    @Test("the flips happen before the rotation")
    func order() {
        // Stated in ACBFCoordinateTransform's own documentation, and worth a
        // test because reversing it changes what a fitted rotation means
        // without changing how well anything fits.
        var transform = ACBFCoordinateTransform()
        transform.flipRows = true
        transform.rotationDegrees = 90
        // (1, 0) flips to (1, 0) — flipRows negates y — then turns to (0, -1).
        let a = transform.apply(kx: 1, ky: 0)
        #expect(abs(a.kx) < 1e-12 && abs(a.ky + 1) < 1e-12)
        // (0, 1) flips to (0, -1), then turns to (-1, 0).
        let b = transform.apply(kx: 0, ky: 1)
        #expect(abs(b.kx + 1) < 1e-12 && abs(b.ky) < 1e-12)
    }
}
