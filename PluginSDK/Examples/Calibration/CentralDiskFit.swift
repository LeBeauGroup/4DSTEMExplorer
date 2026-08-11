//
//  CentralDiskFit.swift
//  4DSTEM Explorer — Calibration
//
//  Calibrating the detector from the bright-field disc.
//
//  The undiffracted beam lands on the detector as a disc whose edge sits at the
//  convergence semi-angle. Measure its radius in pixels and the angle per pixel
//  follows from one division. That is the whole method, and its appeal is that
//  it works on the datasets the lattice method struggles with: at atomic
//  resolution the diffracted discs overlap the bright-field disc and each other,
//  so a single pattern often has no cleanly separated reflections to fit a
//  lattice to — but it always has a central disc, and the disc is the brightest,
//  sharpest-edged thing in the pattern.
//
//  Two ways in, because two different things are known at different microscopes:
//
//    * a known convergence semi-angle α gives `α / R` directly;
//    * a known camera length L and detector pixel pitch p give `p / L` without
//      the disc at all — the disc then measures α instead, which is worth having
//      as a check on both numbers.
//
//  The radius is taken at half height on a radial profile rather than by
//  thresholding and counting pixels. A threshold has to be chosen, and the
//  answer moves with it; the half-height point of an edge does not, which is why
//  it is the conventional definition. Sub-pixel by interpolating across the one
//  bin the crossing falls in.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

struct CentralDiskMeasurement {

    /// Disc centre in detector pixels.
    let centre: (x: Double, y: Double)
    /// Radius in detector pixels, taken at the steepest point of the fall.
    let radius: Double
    /// Where the profile crosses half of (plateau − background), when it does.
    ///
    /// Kept alongside because the two agreeing is the sign of a clean edge, and
    /// the two disagreeing says diffracted discs are sitting under the rim —
    /// worth telling the user rather than quietly resolving.
    let halfHeightRadius: Double?

    /// How far the half-height radius sits from the steepest-descent one, as a
    /// fraction. Small on a clean disc.
    var edgeDisagreement: Double {
        guard let half = halfHeightRadius, radius > 0 else { return 0 }
        return abs(half - radius) / radius
    }
    /// Width of the edge in pixels: the full width at half maximum of the
    /// gradient peak.
    ///
    /// Not the 90%-to-10% span, which was the first thing tried and is wrong on
    /// real data. Outside a real disc there is diffuse scattering that falls
    /// away slowly, so the 10% level is reached far out and the span reads tens
    /// of pixels for an edge that is genuinely sharp — a warning that would fire
    /// on nearly every pattern and teach the user to ignore it. The gradient
    /// peak is confined to the edge itself and does not care what the intensity
    /// does further out.
    let edgeWidth: Double

    /// Mean intensity well inside the disc, and well outside it.
    let plateau: Double
    let background: Double

    /// Azimuthal mean against radius, one entry per pixel of radius. Kept for
    /// display: the profile is how a user judges whether the edge that was
    /// found is the edge they meant.
    let profile: [Float]

    /// How far the disc stands above the background, 0…1. Near zero there is no
    /// disc to measure and the radius means nothing.
    var contrast: Double {
        guard plateau > 0 else { return 0 }
        return max(0, min(1, (plateau - background) / plateau))
    }

    /// True when the edge is sharp enough for the radius to be worth quoting.
    var isSharp: Bool { return edgeWidth < max(4, radius * 0.25) }
}

enum CentralDiskFit {

    /// Locates the bright-field disc.
    ///
    /// Returns nil when there is no disc: a pattern that is flat, empty, or all
    /// one value has no edge to find, and inventing a radius for it would put a
    /// plausible-looking number into a calibration.
    static func measure(image: [Float], rows: Int, columns: Int) -> CentralDiskMeasurement? {

        guard rows > 8, columns > 8, image.count >= rows * columns else { return nil }

        // Background from the border, which is outside any sensible disc. A
        // median, not a mean: a hot pixel or a diffracted disc clipping the
        // corner would drag a mean and leave the half-height point wrong.
        var border: [Float] = []
        border.reserveCapacity(2 * (rows + columns))
        for x in 0..<columns {
            border.append(image[x])
            border.append(image[(rows - 1) * columns + x])
        }
        for y in 0..<rows {
            border.append(image[y * columns])
            border.append(image[y * columns + columns - 1])
        }
        border.sort()
        let background = Double(border[border.count / 2])

        // Plateau from a high percentile rather than the maximum, which is a
        // single hot pixel as often as it is the disc.
        var sorted = image.prefix(rows * columns).sorted()
        let plateau = Double(sorted[Int(Double(sorted.count) * 0.99)])
        guard plateau > background else { return nil }
        let half = (plateau + background) / 2

        // Centre: the centroid of everything above half height. Iterated, because
        // the first estimate is pulled off by any diffracted disc that is also
        // above half height, and each pass restricts the region further.
        var cx = Double(columns - 1) / 2
        var cy = Double(rows - 1) / 2
        var limit = Double(min(rows, columns))

        for _ in 0..<6 {
            var sum = 0.0, sumX = 0.0, sumY = 0.0
            for y in 0..<rows {
                for x in 0..<columns {
                    let value = Double(image[y * columns + x])
                    guard value > half else { continue }
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    guard dx * dx + dy * dy <= limit * limit else { continue }
                    let weight = value - background
                    sum += weight; sumX += weight * Double(x); sumY += weight * Double(y)
                }
            }
            guard sum > 0 else { return nil }
            let newX = sumX / sum, newY = sumY / sum
            let moved = ((newX - cx) * (newX - cx) + (newY - cy) * (newY - cy)).squareRoot()
            cx = newX; cy = newY
            // Tighten the search region toward the disc, then stop once it stops
            // moving. Not a fixed number of passes: a centred disc converges on
            // the first, and an off-centre one takes a few.
            limit = max(4, limit * 0.75)
            if moved < 0.01 { break }
        }

        // Azimuthal mean against radius.
        let maximumRadius = Int(min(min(cx, Double(columns - 1) - cx),
                                    min(cy, Double(rows - 1) - cy)).rounded(.down))
        guard maximumRadius >= 4 else { return nil }

        // The azimuthal *median*, not the mean.
        //
        // Diffracted discs overlap the bright-field disc in exactly the datasets
        // this method exists for. A mean over an annulus just outside the edge
        // includes whatever fraction of it those discs cover, so the profile does
        // not fall to background where the disc really ends and the half-height
        // crossing lands too far out. A median ignores a minority of bright
        // directions, which is what the overlapping discs are — the same reason
        // the background above is a median of the border.
        var samples = [[Float]](repeating: [], count: maximumRadius + 1)
        for y in 0..<rows {
            for x in 0..<columns {
                let dx = Double(x) - cx, dy = Double(y) - cy
                let r = (dx * dx + dy * dy).squareRoot()
                let bin = Int(r.rounded())
                guard bin <= maximumRadius else { continue }
                samples[bin].append(image[y * columns + x])
            }
        }
        var count = [Double](repeating: 0, count: maximumRadius + 1)
        var median = [Double](repeating: 0, count: maximumRadius + 1)
        for i in 0...maximumRadius {
            count[i] = Double(samples[i].count)
            guard !samples[i].isEmpty else { continue }
            samples[i].sort()
            let n = samples[i].count
            median[i] = n % 2 == 1
                ? Double(samples[i][n / 2])
                : (Double(samples[i][n / 2 - 1]) + Double(samples[i][n / 2])) / 2
        }
        // Bins can be empty, and bin 0 usually is: a disc centred between
        // pixels — which a 128-pixel detector's centre at 63.5 always is — has
        // no pixel within half a pixel of its middle. Treating an empty bin as
        // background would put a background reading at the very centre of the
        // disc and make every level crossing meaningless, so empties are carried
        // as "no value" and skipped rather than filled in.
        var profile = [Float](repeating: 0, count: maximumRadius + 1)
        var filled = [Bool](repeating: false, count: maximumRadius + 1)
        for i in 0...maximumRadius where count[i] > 0 {
            profile[i] = Float(median[i])
            filled[i] = true
        }
        // For display, an empty bin reads as its nearest filled neighbour rather
        // than as a hole in the curve.
        for i in 0...maximumRadius where !filled[i] {
            var nearest: Float? = nil
            for d in 1...maximumRadius {
                if i - d >= 0, filled[i - d] { nearest = profile[i - d]; break }
                if i + d <= maximumRadius, filled[i + d] { nearest = profile[i + d]; break }
            }
            profile[i] = nearest ?? Float(background)
        }

        // The plateau is what the profile actually reads near the middle, which
        // is a better level to take half of than a percentile of the whole image.
        let inner = max(1, maximumRadius / 8)
        var innerSum = 0.0, innerCount = 0.0
        for i in 0..<inner where filled[i] { innerSum += Double(profile[i]); innerCount += 1 }
        guard innerCount > 0 else { return nil }
        let plateauLevel = innerSum / innerCount
        guard plateauLevel > background else { return nil }

        /// First outward crossing of a level, interpolated within the bin.
        ///
        /// Walks only over bins that actually hold a measurement; an empty one is
        /// not a crossing, it is an absence.
        func crossing(_ level: Double) -> Double? {
            guard plateauLevel > level else { return nil }
            var lastIndex: Int? = nil
            for i in 0...maximumRadius where filled[i] {
                guard let previousIndex = lastIndex else {
                    // The first filled bin must be inside the disc, or the level
                    // was already crossed before the profile began.
                    if Double(profile[i]) <= level { return nil }
                    lastIndex = i
                    continue
                }
                if Double(profile[i]) <= level {
                    let previous = Double(profile[previousIndex]), current = Double(profile[i])
                    let span = previous - current
                    guard span > 0 else { return Double(i) }
                    let t = (previous - level) / span
                    return Double(previousIndex) + t * Double(i - previousIndex)
                }
                lastIndex = i
            }
            return nil
        }

        let step = plateauLevel - background
        let halfHeight = crossing(background + step * 0.5)

        // The radius is the steepest point of the fall, not the half-height one.
        //
        // The two agree on a clean disc — for any symmetric edge the steepest
        // point is the half-height point. They part company when diffracted
        // discs lay a pedestal under the rim, which is the normal case at atomic
        // resolution: half of (plateau − background) is then a level the profile
        // reaches somewhere past the true edge, and the radius comes out too
        // large by however strong the pedestal is. The steepest point does not
        // move, because adding a slowly varying pedestal does not change where
        // the profile falls fastest.
        let indices = (0...maximumRadius).filter { filled[$0] }
        guard indices.count >= 5 else { return nil }

        var steepestIndex = -1
        var steepest = 0.0
        var gradients = [Int: Double]()
        for position in 1..<(indices.count - 1) {
            let before = indices[position - 1], here = indices[position], after = indices[position + 1]
            let span = Double(after - before)
            guard span > 0 else { continue }
            // Negative because the disc falls; the steepest fall is the largest.
            let gradient = (Double(profile[before]) - Double(profile[after])) / span
            gradients[here] = gradient
            if gradient > steepest { steepest = gradient; steepestIndex = here }
        }
        guard steepestIndex > 0, steepest > 0 else { return nil }

        // Edge width: where the gradient falls to half its peak on each side.
        func gradientCrossing(step: Int) -> Double? {
            var previousIndex = steepestIndex
            var index = steepestIndex + step
            while let value = gradients[index] {
                if value <= steepest / 2 {
                    let previous = gradients[previousIndex] ?? steepest
                    let span = previous - value
                    guard span > 0 else { return Double(index) }
                    let t = (previous - steepest / 2) / span
                    return Double(previousIndex) + t * Double(index - previousIndex)
                }
                previousIndex = index
                index += step
            }
            return nil
        }
        let leftHalf = gradientCrossing(step: -1)
        let rightHalf = gradientCrossing(step: 1)
        let fwhm: Double
        switch (leftHalf, rightHalf) {
        case let (l?, r?): fwhm = r - l
        // Only one side found: the peak runs off the end of the profile, so
        // double the half we have rather than reporting a width that is missing
        // a side and looks sharper than it is.
        case let (l?, nil): fwhm = 2 * (Double(steepestIndex) - l)
        case let (nil, r?): fwhm = 2 * (r - Double(steepestIndex))
        case (nil, nil):    fwhm = Double(maximumRadius)
        }

        // Sub-pixel by fitting a parabola through the steepest gradient and its
        // two neighbours — the same refinement the lattice peaks get.
        var radius = Double(steepestIndex)
        if let left = gradients[steepestIndex - 1], let right = gradients[steepestIndex + 1] {
            let denominator = left - 2 * steepest + right
            if abs(denominator) > 1e-12 {
                let shift = 0.5 * (left - right) / denominator
                if abs(shift) <= 1 { radius = Double(steepestIndex) + shift }
            }
        }
        guard radius >= 2 else { return nil }

        return CentralDiskMeasurement(centre: (x: cx, y: cy),
                                      radius: radius,
                                      halfHeightRadius: halfHeight,
                                      edgeWidth: max(0, fwhm),
                                      plateau: plateauLevel,
                                      background: background,
                                      profile: profile)
    }

    // MARK: - What the radius means

    /// Milliradians per detector pixel from a known convergence semi-angle.
    ///
    /// The disc edge is at the convergence semi-angle by definition, so the
    /// angle per pixel is that angle divided by the radius in pixels.
    static func step(convergenceMilliradians: Double, radiusPixels: Double) -> Double? {
        guard convergenceMilliradians > 0, radiusPixels > 0,
              convergenceMilliradians.isFinite, radiusPixels.isFinite else { return nil }
        return convergenceMilliradians / radiusPixels
    }

    /// Milliradians per detector pixel from the camera geometry.
    ///
    /// `p / L` in consistent units. With the pitch in micrometres and the length
    /// in millimetres the thousands cancel exactly, which is why those are the
    /// units asked for: `mrad/px = pitch[µm] / L[mm]`.
    ///
    /// This does not use the disc at all. It is the independent route, and its
    /// value is that comparing the two says whether either is trustworthy.
    static func step(cameraLengthMillimetres: Double, pixelPitchMicrometres: Double) -> Double? {
        guard cameraLengthMillimetres > 0, pixelPitchMicrometres > 0,
              cameraLengthMillimetres.isFinite, pixelPitchMicrometres.isFinite else { return nil }
        return pixelPitchMicrometres / cameraLengthMillimetres
    }

    /// The convergence semi-angle a measured radius implies, given a step.
    ///
    /// The inverse of the first form, and the reason the camera-length route is
    /// worth offering: it turns the disc from the thing being used into a check
    /// on the geometry that was assumed.
    static func convergenceMilliradians(step: Double, radiusPixels: Double) -> Double? {
        guard step > 0, radiusPixels > 0 else { return nil }
        return step * radiusPixels
    }
}

// MARK: - Drawing

extension CentralDiskFit {

    /// The pattern, log scaled, for display.
    ///
    /// Log because a diffraction pattern spans orders of magnitude and a linear
    /// rendering shows the central disc and nothing else — including not showing
    /// the diffracted discs whose presence is exactly what has to be judged when
    /// reading the fit.
    static func display(image: [Float], rows: Int, columns: Int) -> [Float] {
        var out = [Float](repeating: 0, count: rows * columns)
        var minimum = Float.greatestFiniteMagnitude
        for i in 0..<(rows * columns) where image[i] < minimum { minimum = image[i] }
        let shift = minimum < 0 ? -minimum : 0
        for i in 0..<(rows * columns) {
            out[i] = log(max(image[i] + shift, 0) + 1)
        }
        return out
    }

    /// The rim in use, as geometry for the host to draw.
    ///
    /// Geometry rather than pixels poked into a copy of the data: the rim of a
    /// disc is a circle of a particular sub-pixel radius, and rounding it onto
    /// the pattern's own grid throws away exactly the precision the measurement
    /// went to such trouble to obtain. Drawn this way the circle sits where the
    /// fit says, at every zoom and in an export — which is what makes setting
    /// the radius by eye possible at all, since judging a rim against a diffuse
    /// edge means zooming into it.
    ///
    /// - Parameters:
    ///   - radius: the radius actually being used, which is the automatic one
    ///     until the user overrides it.
    ///   - measurement: the fit, when there was one. Its own radius is drawn
    ///     faintly whenever it differs from `radius`, so an override is visibly
    ///     an override rather than a silent replacement — the user can see how
    ///     far they have moved and put it back by eye.
    ///   - edgeWidth: the band either side of the rim, so the sharpness of the
    ///     edge is visible rather than only reported as a number.
    static func overlayShapes(centre: (x: Double, y: Double), radius: Double,
                              edgeWidth: Double = 0,
                              measurement: CentralDiskMeasurement? = nil) -> [[String: Any]] {
        var shapes: [[String: Any]] = []
        let x = centre.x, y = centre.y
        guard radius > 0 else { return shapes }

        let half = edgeWidth / 2
        if half > 0.25, radius - half > 0 {
            let faint: FDSShape.Colour = (0.47, 0.47, 1.0, 0.85)
            shapes.append(FDSShape.circle(x: x, y: y, radius: radius - half,
                                          colour: faint, lineWidth: 1))
            shapes.append(FDSShape.circle(x: x, y: y, radius: radius + half,
                                          colour: faint, lineWidth: 1))
        }

        // What the fit said, when that is no longer what is being used.
        if let found = measurement, abs(found.radius - radius) > 0.05 {
            let ghost: FDSShape.Colour = (0.35, 0.85, 1.0, 0.6)
            shapes.append(FDSShape.circle(x: found.centre.x, y: found.centre.y,
                                          radius: found.radius, colour: ghost, lineWidth: 1))
            shapes.append(FDSShape.label(String(format: "auto %.2f", found.radius),
                                         x: found.centre.x - found.radius * 0.7071,
                                         y: found.centre.y + found.radius * 0.7071 + 13,
                                         colour: ghost, fontSize: 10))
        }

        // The rim in use.
        shapes.append(FDSShape.circle(x: x, y: y, radius: radius,
                                      colour: FDSShape.red, lineWidth: 2))

        // The centre, so an off-centre rim is obvious at a glance.
        shapes.append(FDSShape.cross(x: x, y: y, radius: max(6, radius * 0.12),
                                     colour: FDSShape.red, lineWidth: 1.5))

        shapes.append(FDSShape.label(String(format: "r = %.2f px", radius),
                                     x: x + radius * 0.7071 + 3,
                                     y: y - radius * 0.7071 - 3,
                                     colour: FDSShape.red, fontSize: 11))
        return shapes
    }
}
