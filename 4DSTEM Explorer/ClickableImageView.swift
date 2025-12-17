import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

struct ClickableImageView: NSViewRepresentable {
    let pixelBuffer: CVPixelBuffer
    let onClick: (Int, Int) -> Void
    let onDrag: ((Int, Int) -> Void)?
    let onArrowKey: ((Int, Int) -> Void)? // (di, dj)

    func makeNSView(context: Context) -> NSImageView {
        let v = ClickableNSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.imageAlignment = .alignCenter
        v.wantsLayer = true
        v.acceptsFirstResponderFlag = true

        v.eventHandler = { event, view in
            switch event {
            case .mouseDown(let point):
                view.window?.makeFirstResponder(view)
                context.coordinator.handlePoint(point, in: view)
            case .mouseDragged(let point):
                context.coordinator.handlePoint(point, in: view)
            case .mouseUp:
                break
            default:
                break
            }
        }

        v.keyHandler = { event, view in
            if case let .arrow(dx, dy) = event {
                context.coordinator.handleArrow(dx: dx, dy: dy)
            }
        }

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        v.addGestureRecognizer(click)

        return v
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rep = NSCIImageRep(ciImage: ciImage)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        nsView.image = img
        context.coordinator.imageSize = rep.size
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onClick: onClick, onDrag: onDrag, onArrowKey: onArrowKey)
    }

    final class Coordinator: NSObject {
        var onClick: (Int, Int) -> Void
        var onDrag: ((Int, Int) -> Void)?
        var onArrowKey: ((Int, Int) -> Void)?
        var imageSize: CGSize = .zero

        init(onClick: @escaping (Int, Int) -> Void,
             onDrag: ((Int, Int) -> Void)? = nil,
             onArrowKey: ((Int, Int) -> Void)? = nil) {
            self.onClick = onClick
            self.onDrag = onDrag
            self.onArrowKey = onArrowKey
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? NSImageView else { return }
            let locationInView = gesture.location(in: view)
            if let (i, j) = map(locationInView, in: view) {
                onClick(i, j)
            }
        }

        func handlePoint(_ locationInView: CGPoint, in view: NSImageView) {
            if let (i, j) = map(locationInView, in: view) {
                if let onDrag = onDrag {
                    onDrag(i, j)
                } else {
                    onClick(i, j)
                }
            }
        }

        func handleArrow(dx: Int, dy: Int) {
            onArrowKey?(dy, dx) // map to (di, dj)
        }

        private func map(_ locationInView: CGPoint, in view: NSImageView) -> (Int, Int)? {
            guard let image = view.image, image.size.width > 0, image.size.height > 0 else { return nil }

            let bounds = view.bounds
            let imageAspect = image.size.width / image.size.height
            let viewAspect = bounds.width / bounds.height

            var drawRect = bounds
            if imageAspect > viewAspect {
                let drawHeight = bounds.width / imageAspect
                drawRect = CGRect(x: 0, y: (bounds.height - drawHeight) / 2.0, width: bounds.width, height: drawHeight)
            } else {
                let drawWidth = bounds.height * imageAspect
                drawRect = CGRect(x: (bounds.width - drawWidth) / 2.0, y: 0, width: drawWidth, height: bounds.height)
            }

            guard drawRect.width > 0 && drawRect.height > 0 else { return nil }

            let nx = (locationInView.x - drawRect.minX) / drawRect.width
            let ny = (locationInView.y - drawRect.minY) / drawRect.height
            if nx < 0 || nx > 1 || ny < 0 || ny > 1 { return nil }

            let px = Int((nx * image.size.width).rounded())
            let py = Int(((1 - ny) * image.size.height).rounded())

            return (py, px) // (i, j)
        }
    }
}

private enum ClickEvent {
    case mouseDown(CGPoint)
    case mouseDragged(CGPoint)
    case mouseUp
    case arrow(dx: Int, dy: Int)
}

private final class ClickableNSImageView: NSImageView {
    var eventHandler: ((ClickEvent, NSImageView) -> Void)?
    var keyHandler: ((ClickEvent, NSImageView) -> Void)?

    var acceptsFirstResponderFlag: Bool = false
    override var acceptsFirstResponder: Bool { acceptsFirstResponderFlag }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        eventHandler?(.mouseDown(point), self)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        eventHandler?(.mouseDragged(point), self)
    }

    override func mouseUp(with event: NSEvent) {
        eventHandler?(.mouseUp, self)
    }

    override func keyDown(with event: NSEvent) {
        guard let handler = keyHandler else { return }
        switch event.keyCode {
        case 123: handler(.arrow(dx: -1, dy: 0), self) // left
        case 124: handler(.arrow(dx: 1, dy: 0), self)  // right
        case 125: handler(.arrow(dx: 0, dy: 1), self)  // down (increase i)
        case 126: handler(.arrow(dx: 0, dy: -1), self) // up (decrease i)
        default: super.keyDown(with: event)
        }
    }
}

