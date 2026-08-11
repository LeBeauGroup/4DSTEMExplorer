//
//  PluginOverlay.swift
//  4DSTEM Explorer
//
//  Drawing a plugin's markings with CoreGraphics instead of into its data.
//
//  Markings used to be poked into an RGBA copy of the image: a marker was one
//  pixel wide for ever, so it aliased away when the view was zoomed out and
//  became a single hard dot when zoomed in, and an exported "rendered" image had
//  it burned in at the data's own resolution — a 128-pixel pattern's annotations
//  printed as 128 pixels of annotation.
//
//  Geometry avoids all of that. A shape is expressed in image-pixel coordinates
//  and stroked at whatever scale the context happens to be, so it is crisp in a
//  zoomed view and crisp again in an export upsampled eight times, and the data
//  underneath is never touched.
//
//  Line widths and type sizes are in *points of the output*, not image pixels,
//  and are therefore divided by the scale before use. A line specified in image
//  pixels would be a hairline at low zoom and a slab at high zoom, which is
//  exactly the failing the pixel-poking had.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import CoreGraphics
import AppKit

struct PluginOverlayShape {

    enum Kind: String {
        case circle, line, cross, polyline, polygon, label
    }

    let kind: Kind
    /// Image-pixel coordinates, flat.
    let points: [Double]
    let radius: Double
    let colour: CGColor
    /// In points of the output, not image pixels.
    let lineWidth: Double
    let filled: Bool
    let text: String?
    let fontSize: Double

    /// Parses what a plugin supplied, dropping anything malformed rather than
    /// drawing it wrongly.
    static func list(_ value: Any?) -> [PluginOverlayShape] {
        guard let raw = value as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let name = entry[FDSShapeKey.kind] as? String,
                  let kind = Kind(rawValue: name) else { return nil }
            let points = (entry[FDSShapeKey.points] as? [NSNumber])?.map { $0.doubleValue } ?? []
            guard points.count >= 2, points.count % 2 == 0 else { return nil }

            let components = (entry[FDSShapeKey.colour] as? [NSNumber])?.map { CGFloat($0.doubleValue) }
            let colour: CGColor
            if let c = components, c.count == 4 {
                colour = CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
            } else {
                colour = CGColor(srgbRed: 1, green: 0.19, blue: 0.19, alpha: 1)
            }

            return PluginOverlayShape(
                kind: kind,
                points: points,
                radius: (entry[FDSShapeKey.radius] as? NSNumber)?.doubleValue ?? 0,
                colour: colour,
                lineWidth: (entry[FDSShapeKey.lineWidth] as? NSNumber)?.doubleValue ?? 1.5,
                filled: (entry[FDSShapeKey.filled] as? NSNumber)?.boolValue ?? false,
                text: entry[FDSShapeKey.text] as? String,
                fontSize: (entry[FDSShapeKey.fontSize] as? NSNumber)?.doubleValue ?? 11)
        }
    }
}

enum PluginOverlayRenderer {

    /// Draws shapes into a context whose coordinates are image pixels scaled by
    /// `scale`.
    ///
    /// The context is assumed to be in the image's own orientation with y
    /// increasing downwards, which is how the data is indexed; callers that hand
    /// over a bottom-up context flip it first, once, rather than every shape
    /// having to know.
    static func draw(_ shapes: [PluginOverlayShape], in context: CGContext, scale: CGFloat) {
        guard !shapes.isEmpty, scale > 0 else { return }

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShouldAntialias(true)

        for shape in shapes {
            context.setStrokeColor(shape.colour)
            context.setFillColor(shape.colour)
            // Widths are given in output points, so they must not scale with the
            // image: dividing here cancels the scale the context applies.
            context.setLineWidth(max(CGFloat(shape.lineWidth) / scale, 0.01))

            func point(_ index: Int) -> CGPoint {
                return CGPoint(x: shape.points[index * 2], y: shape.points[index * 2 + 1])
            }

            switch shape.kind {
            case .circle:
                let centre = point(0)
                let r = CGFloat(shape.radius)
                guard r > 0 else { break }
                let rect = CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)
                context.addEllipse(in: rect)
                shape.filled ? context.fillPath() : context.strokePath()

            case .line:
                guard shape.points.count >= 4 else { break }
                context.move(to: point(0))
                context.addLine(to: point(1))
                context.strokePath()

            case .cross:
                let centre = point(0)
                let r = CGFloat(shape.radius)
                guard r > 0 else { break }
                // A gap at the middle, so the cross marks a position without
                // hiding the pixel it is marking — the one place you want to see.
                let gap = min(r * 0.35, 2 / scale)
                context.move(to: CGPoint(x: centre.x - r, y: centre.y))
                context.addLine(to: CGPoint(x: centre.x - gap, y: centre.y))
                context.move(to: CGPoint(x: centre.x + gap, y: centre.y))
                context.addLine(to: CGPoint(x: centre.x + r, y: centre.y))
                context.move(to: CGPoint(x: centre.x, y: centre.y - r))
                context.addLine(to: CGPoint(x: centre.x, y: centre.y - gap))
                context.move(to: CGPoint(x: centre.x, y: centre.y + gap))
                context.addLine(to: CGPoint(x: centre.x, y: centre.y + r))
                context.strokePath()

            case .polyline, .polygon:
                context.move(to: point(0))
                for index in 1..<(shape.points.count / 2) { context.addLine(to: point(index)) }
                if shape.kind == .polygon { context.closePath() }
                shape.filled && shape.kind == .polygon ? context.fillPath() : context.strokePath()

            case .label:
                guard let text = shape.text, !text.isEmpty else { break }
                draw(text, at: point(0), shape: shape, in: context, scale: scale)
            }
        }
        context.restoreGState()
    }

    /// Real text, at a size in output points.
    ///
    /// Drawn through a flipped transform because the context is top-down while
    /// CoreText lays out bottom-up; without it every label appears mirrored.
    private static func draw(_ text: String, at origin: CGPoint, shape: PluginOverlayShape,
                             in context: CGContext, scale: CGFloat) {
        let size = max(CGFloat(shape.fontSize) / scale, 0.5)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor(cgColor: shape.colour) ?? NSColor.red
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: Rendering onto an image

    /// The image with its overlay drawn on, at `scale` times the data's size.
    ///
    /// Upsampling is nearest-neighbour so the data stays honest — every output
    /// pixel is exactly one input pixel, enlarged — while the overlay above it
    /// is drawn as smooth geometry at the output resolution. Interpolating the
    /// data instead would invent values that were never measured, in an image
    /// whose whole purpose is to show what was.
    static func rendered(image: CGImage, shapes: [PluginOverlayShape],
                         scale: CGFloat) -> CGImage? {
        let width = Int((CGFloat(image.width) * scale).rounded())
        let height = Int((CGFloat(image.height) * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Into image-pixel coordinates, top-down, so the shapes' coordinates
        // mean what the plugin meant by them.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(shapes, in: context, scale: scale)

        return context.makeImage()
    }

    /// How much to enlarge a small image so its markings survive export.
    ///
    /// A 128-pixel pattern annotated at its own resolution loses every marking
    /// to a single pixel; enlarged to around a thousand, the same geometry is
    /// drawn with room to be seen. Big images are left alone — there is nothing
    /// to gain and a great deal of file to lose.
    static func exportScale(for image: CGImage, target: Int = 1024) -> CGFloat {
        let longest = max(image.width, image.height)
        guard longest > 0, longest < target else { return 1 }
        return CGFloat(max(1, target / longest))
    }
}
