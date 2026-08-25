//
//  Aberration.swift
//  4DSTEM Explorer
//
//  A measured aberration coefficient, and how it is written for phaser.
//
//  The acBF plugin refines a Krivanek (n, m) expansion, and phaser's probe model
//  is the same expansion — so the two agree term for term with no conversion,
//  once three things are got right. They are worth stating because each of them
//  is silent when wrong: the numbers stay plausible and the reconstruction is
//  simply of the wrong probe.
//
//  Units. acBF's coefficients are ångström. phaser builds chi in "length units"
//  and forms the probe as exp(2πi/λ · chi) with λ in ångström at that layer, so
//  the values transfer as they are. The one exception is EMPAD metadata's own
//  `defocus` field, documented in metres and multiplied by 1e10 on the way in.
//
//  Frame. acBF evaluates chi at detector coordinates, and so does phaser's
//  make_focused_probe. The detector-frame vector is therefore the one to write —
//  not the scan-frame vector acBF also computes for its own reporting.
//
//  Named terms carry a factor. phaser's convenience names apply a scale to four
//  of them — C_21 = 3·B2, C_32 = 3·S3, C_41 = 4·B4, C_43 = 4·D4 — so writing
//  `{"b2": …}` would treble a coma. Nothing here is written under a name, so
//  no scale factor can be applied behind our backs.
//
//  The order travels as one field, `nm`, a character per index: "12" is
//  (n = 1, m = 2). Note that this is *not* the shape phaser parses today — its
//  explicit form is two integer fields, `n` and `m` — so a reader wanting these
//  coefficients needs to split `nm` first. That is a deliberate choice of this
//  application's file format, not an oversight.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

/// One Krivanek term, in ångström, in the detector frame.
struct Aberration: Equatable {

    /// Radial order.
    let n: Int
    /// Azimuthal order. `n + 1 - m` is always even.
    let m: Int
    /// The cosine-like part, and the sine-like part of the pair.
    ///
    /// A symmetric term (`m == 0`) has no `b`: there is no azimuthal direction
    /// for it to point in, so it is always zero.
    let a: Double
    let b: Double

    init(n: Int, m: Int, a: Double, b: Double = 0) {
        self.n = n
        self.m = m
        self.a = a
        self.b = m == 0 ? 0 : b
    }

    /// True for the (1, 0) term, which EMPAD metadata carries in its own field.
    var isDefocus: Bool { return n == 1 && m == 0 }

    /// Whether this term is worth writing at all.
    var isSignificant: Bool { return a != 0 || b != 0 }

    /// Krivanek C_{n,m}, for display.
    ///
    /// Not the Haider letters. Four of those — B2, S3, B4, D4 — are normalised
    /// differently from the coefficient stored here, so naming a value after
    /// one would misreport it by a factor of three or four.
    var name: String { return "C\(n),\(m)" }

    // MARK: Interchange

    /// The order as a two-character string: one character for `n`, one for `m`.
    ///
    /// `(0, 1)` is "01" and `(1, 2)` is "12", so a term is identified by a
    /// single field instead of two. Character separation rather than a
    /// delimiter, which holds because both orders are single digits: acBF caps
    /// the radial order at 6, and `m` never exceeds `n + 1`, so the largest
    /// pair expressible is "67".
    var nm: String {
        return "\(n)\(m)"
    }

    /// The interchange dictionary, used both across the plugin boundary and in
    /// the metadata file.
    var dictionary: [String: Any] {
        return ["nm": nm, "re": a, "im": b]
    }

    init?(_ value: Any?) {
        guard let d = value as? [String: Any] else { return nil }

        let order: (n: Int, m: Int)
        if let nm = d["nm"] as? String {
            // Exactly two digits. A longer string would be ambiguous — "123"
            // is (1, 23) or (12, 3) with nothing to say which — so it is
            // refused rather than guessed at.
            let digits = Array(nm)
            guard digits.count == 2,
                  let n = digits[0].wholeNumberValue,
                  let m = digits[1].wholeNumberValue else { return nil }
            order = (n, m)
        } else if let n = (d["n"] as? NSNumber)?.intValue,
                  let m = (d["m"] as? NSNumber)?.intValue {
            // The older two-field form. Still accepted on the way in because a
            // plugin bundle is built separately from the host and may be older
            // than it — a stale plugin should not have its measurement dropped.
            order = (n, m)
        } else {
            return nil
        }

        guard order.n >= 0, order.m >= 0, order.m <= order.n + 1,
              (order.n + 1 - order.m) % 2 == 0 else { return nil }
        let a = (d["re"] as? NSNumber)?.doubleValue ?? 0
        let b = (d["im"] as? NSNumber)?.doubleValue ?? 0
        guard a.isFinite, b.isFinite else { return nil }
        self.init(n: order.n, m: order.m, a: a, b: b)
    }

    static func list(_ value: Any?) -> [Aberration] {
        guard let raw = value as? [[String: Any]] else { return [] }
        return raw.compactMap { Aberration($0) }
    }
}

extension Array where Element == Aberration {

    /// C1 in metres, for EMPAD metadata's `defocus` field.
    ///
    /// Positive is overfocus in both conventions, so the only change is the
    /// unit: phaser documents this field in metres and converts it back to
    /// ångström itself.
    var defocusMetres: Double? {
        guard let c1 = first(where: { $0.isDefocus }), c1.a != 0 else { return nil }
        return c1.a * 1e-10
    }

    /// Everything except C1, in phaser's explicit Krivanek form.
    ///
    /// C1 is left out because phaser adds `defocus/2·θ²` *and* the aberration
    /// surface, and the surface's (1, 0) term is exactly `C1·θ²/2` — writing
    /// both would apply the defocus twice.
    var phaserAberrations: [[String: Any]] {
        return filter { !$0.isDefocus && $0.isSignificant }
            .sorted { ($0.n, $0.m) < ($1.n, $1.m) }
            .map { $0.dictionary }
    }
}
