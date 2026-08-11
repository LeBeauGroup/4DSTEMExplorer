//
//  DetectorRadii.swift
//  4DSTEM Explorer
//
//  The rule that keeps an annular detector's two radii apart.
//
//  An extension on the `DetectorRadii` container declared in Constants.swift,
//  not a second type of the same name. Kept in its own file, and free of every
//  other type in the project, so it can be compiled and exercised on its own:
//  the rule is small and entirely about arithmetic at the boundaries, which is
//  exactly the kind of thing that is easy to get subtly wrong and worth
//  checking directly.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import CoreGraphics

/// The inner and outer radii of an annular detector, kept apart.
///
/// The two used to be clamped against each other with `min`, which let them
/// meet: an annulus of zero width, collecting nothing, reached simply by
/// dragging either control far enough. Worse, the inner control could only ever
/// be clamped *down* — its slider ran to the outer radius and no further — so
/// widening the annulus from the inside was impossible and the two got stuck
/// together, with the outer one dragging the inner one along behind it.
///
/// Here neither is capped by the other. Whichever one the user moves goes where
/// they put it, and the other gets out of the way, keeping at least
/// `minimumSeparation` between them. Only when the one being pushed runs out of
/// detector does the moved one give ground.
///
/// A value type with no dependencies so the rule can be exercised on its own,
/// away from the view and the model that use it.
extension DetectorRadii {

    /// The narrowest annulus allowed, in detector pixels. One pixel: enough for
    /// the ring to contain something.
    static let minimumSeparation: CGFloat = 1

    /// The smallest inner radius allowed.
    static let minimumInner: CGFloat = 1

    /// The result of the user moving the inner radius to `value`.
    ///
    /// The outer radius is pushed outwards to keep the gap. If that would take
    /// it past `ceiling` it stops there, and the inner radius settles one gap
    /// inside it — the only case where the radius being dragged does not end up
    /// where it was put.
    static func movingInner(to value: CGFloat, outer: CGFloat,
                            ceiling: CGFloat) -> DetectorRadii {
        let limit = usableCeiling(ceiling)
        let inner = clamp(value, minimumInner, limit - minimumSeparation)
        return DetectorRadii(inner: inner,
                             outer: min(max(outer, inner + minimumSeparation), limit))
    }

    /// The result of the user moving the outer radius to `value`.
    ///
    /// The mirror image: the inner radius is pushed inwards, and stops at the
    /// smallest radius allowed rather than going below it.
    static func movingOuter(to value: CGFloat, inner: CGFloat,
                            ceiling: CGFloat) -> DetectorRadii {
        let limit = usableCeiling(ceiling)
        let outer = clamp(value, minimumInner + minimumSeparation, limit)
        return DetectorRadii(inner: min(inner, outer - minimumSeparation),
                             outer: outer)
    }

    /// Both radii forced into a valid arrangement, for values arriving from
    /// somewhere other than the two controls — a stored detector, or a drag on
    /// the pattern that moves both at once.
    static func settled(inner: CGFloat, outer: CGFloat,
                        ceiling: CGFloat) -> DetectorRadii {
        return movingInner(to: inner,
                           outer: movingOuter(to: outer, inner: inner,
                                              ceiling: ceiling).outer,
                           ceiling: ceiling)
    }

    /// The range the inner control may span. Deliberately *not* bounded by the
    /// outer radius: that bound was what made the inner radius unable to push.
    static func innerRange(ceiling: CGFloat) -> ClosedRange<Double> {
        let limit = usableCeiling(ceiling)
        return Double(minimumInner)...Double(limit - minimumSeparation)
    }

    /// The range the outer control may span.
    static func outerRange(ceiling: CGFloat) -> ClosedRange<Double> {
        let limit = usableCeiling(ceiling)
        return Double(minimumInner + minimumSeparation)...Double(limit)
    }

    /// A ceiling with room for both controls to exist.
    ///
    /// A pattern small enough to leave the two radii nowhere to go would give a
    /// slider an empty or inverted range, which is not a clamped control but a
    /// crash. Real patterns are far larger than this; the floor exists so that
    /// a degenerate one cannot take the window down with it.
    private static func usableCeiling(_ ceiling: CGFloat) -> CGFloat {
        return max(ceiling, minimumInner + 2 * minimumSeparation)
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        return min(max(value, low), high)
    }
}
