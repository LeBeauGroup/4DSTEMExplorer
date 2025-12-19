import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

struct ZoomableClickableImageView: NSViewRepresentable {
    // Input image
    let pixelBuffer: CVPixelBuffer

    // Zoom bounds and initial zoom
    var minZoom: CGFloat = 0.1
    var maxZoom: CGFloat = 8.0
    @Binding var zoom: CGFloat // external binding to observe/control zoom

    // Events
    let onClick: (Int, Int) -> Void
    let onDrag: ((Int, Int) -> Void)?
    let onMouseUp: ((Int, Int) -> Void)?
    let onArrowKey: ((Int, Int) -> Void)? // (di, dj)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = minZoom
        scroll.maxMagnification = maxZoom
        scroll.magnification = max(minZoom, min(maxZoom, zoom))
        scroll.verticalScrollElasticity = .automatic
        scroll.horizontalScrollElasticity = .automatic

        // Document view: a container that hosts the image view
        let container = NSView()
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = true
        container.frame = .zero

        // Image view
        let imageView = ClickableNSImageView()
        imageView.imageScaling = .scaleNone // we will size the image view ourselves
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.acceptsFirstResponderFlag = true
        imageView.translatesAutoresizingMaskIntoConstraints = true

        // Wire events to coordinator
        imageView.eventHandler = { event, view in
            context.coordinator.handle(event: event, in: view)
        }
        imageView.keyHandler = { event, view in
            context.coordinator.handleKey(event: event, in: view)
        }

        // Pinch zoom recognizer (alternative to scroll magnification)
        let magnify = NSMagnificationGestureRecognizer(target: context.coordinator,
                                                       action: #selector(Coordinator.handleMagnify(_:)))
        scroll.addGestureRecognizer(magnify)

        // Click gesture for precise clicks
        let click = NSClickGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleClick(_:)))
        imageView.addGestureRecognizer(click)

        container.addSubview(imageView)
        scroll.documentView = container

        // Store references
        context.coordinator.scrollView = scroll
        context.coordinator.containerView = container
        context.coordinator.imageView = imageView

        // Initial image setup
        context.coordinator.updateImage(with: pixelBuffer)
        context.coordinator.layoutForCurrentZoom()

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Update image if pixel buffer changed
        context.coordinator.updateImage(with: pixelBuffer)

        // Clamp and apply zoom from binding
        let clamped = max(minZoom, min(maxZoom, zoom))
        if scroll.magnification != clamped {
            scroll.magnification = clamped
        }

        // Ensure layout sizes match content and zoom
        context.coordinator.layoutForCurrentZoom()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var parent: ZoomableClickableImageView

        weak var scrollView: NSScrollView?
        weak var containerView: NSView?
        weak var imageView: ClickableNSImageView?

        // Image info
        private(set) var imageSize: CGSize = .zero // pixel size of image
        private(set) var displaySize: CGSize = .zero // point size of imageView (aspect-fit base size)
        private var lastLocationInView: CGPoint?

        init(_ parent: ZoomableClickableImageView) {
            self.parent = parent
        }

        // Convert CVPixelBuffer -> NSImage and set on imageView
        func updateImage(with pixelBuffer: CVPixelBuffer) {
            guard let imageView = imageView else { return }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rep = NSCIImageRep(ciImage: ciImage)
            let img = NSImage(size: rep.size)
            img.addRepresentation(rep)
            imageView.image = img

            imageSize = rep.size
        }

        // Compute a base aspect-fit size for the image view within the container
        private func computeAspectFitSize(containerSize: CGSize, imageSize: CGSize) -> CGSize {
            guard imageSize.width > 0, imageSize.height > 0,
                  containerSize.width > 0, containerSize.height > 0 else {
                return .zero
            }
            let imageAspect = imageSize.width / imageSize.height
            let viewAspect = containerSize.width / containerSize.height

            if imageAspect > viewAspect {
                // Fit width
                let width = containerSize.width
                let height = width / imageAspect
                return CGSize(width: width, height: height)
            } else {
                // Fit height
                let height = containerSize.height
                let width = height * imageAspect
                return CGSize(width: width, height: height)
            }
        }

        func layoutForCurrentZoom() {
            guard let scroll = scrollView,
                  let container = containerView,
                  let imageView = imageView else { return }

            // Ensure container is at least the visible area to allow scrolling
            let visible = scroll.contentView.bounds.size
            if container.frame.size != visible {
                container.frame = CGRect(origin: .zero, size: visible)
            }

            // Base (unmagnified) aspect-fit size within the container
            let baseSize = computeAspectFitSize(containerSize: container.bounds.size, imageSize: imageSize)
            displaySize = baseSize

            // Apply current magnification by sizing the imageView larger
            let scale = scroll.magnification
            let scaledSize = CGSize(width: max(baseSize.width * scale, visible.width + 1),
                                    height: max(baseSize.height * scale, visible.height + 1))

            // Center the image view within the container's coordinate space
            let origin = CGPoint(x: max(0, (visible.width - scaledSize.width) / 2.0),
                                 y: max(0, (visible.height - scaledSize.height) / 2.0))

            imageView.frame = CGRect(origin: origin, size: scaledSize)

            // Update external zoom binding if needed
            if parent.zoom != scale {
                parent.zoom = scale
            }
        }

        // MARK: - Events

        func handle(event: ClickEvent, in view: NSImageView) {
            switch event {
            case .mouseDown(let point):
                view.window?.makeFirstResponder(view)
                lastLocationInView = point
                if let (i, j) = mapToPixel(point, in: view) {
                    if parent.onDrag != nil {
                        parent.onClick(i, j) // anchor for marquee
                    } else {
                        parent.onClick(i, j)
                    }
                }
            case .mouseDragged(let point):
                lastLocationInView = point
                if let (i, j) = mapToPixel(point, in: view) {
                    if let onDrag = parent.onDrag {
                        onDrag(i, j)
                    } else {
                        parent.onClick(i, j)
                    }
                }
            case .mouseUp:
                if let onMouseUp = parent.onMouseUp,
                   let view = self.imageView,
                   let last = lastLocationInView,
                   let (i, j) = mapToPixel(last, in: view) {
                    onMouseUp(i, j)
                }
            case .arrow:
                break // handled in handleKey
            }
        }

        func handleKey(event: ClickEvent, in view: NSImageView) {
            if case let .arrow(dx, dy) = event {
                parent.onArrowKey?(dy, dx) // map to (di, dj)
            }
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? NSImageView else { return }
            let p = gesture.location(in: view)
            if let (i, j) = mapToPixel(p, in: view) {
                parent.onClick(i, j)
            }
        }

        @objc func handleMagnify(_ recognizer: NSMagnificationGestureRecognizer) {
            guard let scroll = scrollView else { return }
            switch recognizer.state {
            case .began, .changed:
                let current = scroll.magnification
                let proposed = current + recognizer.magnification
                let clamped = max(parent.minZoom, min(parent.maxZoom, proposed))
                if clamped != current {
                    scroll.magnification = clamped
                    layoutForCurrentZoom()
                    parent.zoom = clamped
                }
                recognizer.magnification = 0
            case .ended, .cancelled, .failed:
                parent.zoom = scroll.magnification
            default:
                break
            }
        }

        // MARK: - Mapping

        // Map a point in imageView coordinates to pixel (i, j)
        func mapToPixel(_ p: CGPoint, in view: NSImageView) -> (Int, Int)? {
            guard imageSize.width > 0, imageSize.height > 0 else { return nil }
            guard let scroll = scrollView, let container = containerView else { return nil }

            // Determine the base aspect-fit rect within the container (unmagnified)
            let baseSize = computeAspectFitSize(containerSize: container.bounds.size, imageSize: imageSize)

            // The imageView is scaled version of baseSize, centered in container
            let scale = scroll.magnification
            let scaledSize = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
            let origin = CGPoint(x: max(0, (container.bounds.width - scaledSize.width) / 2.0),
                                 y: max(0, (container.bounds.height - scaledSize.height) / 2.0))
            let imageRect = CGRect(origin: origin, size: scaledSize)

            // Convert the point from view (imageView) to container coordinates
            let pInContainer = view.convert(p, to: container)

            // Normalize within imageRect
            guard imageRect.width > 0, imageRect.height > 0 else { return nil }
            let nx = (pInContainer.x - imageRect.minX) / imageRect.width
            let ny = (pInContainer.y - imageRect.minY) / imageRect.height
            if nx < 0 || nx > 1 || ny < 0 || ny > 1 { return nil }

            let px = Int((nx * imageSize.width).rounded())
            let py = Int(((1 - ny) * imageSize.height).rounded())
            return (py, px)
        }
    }
}

// MARK: - Events and ImageView subclass

enum ClickEvent {
    case mouseDown(CGPoint)
    case mouseDragged(CGPoint)
    case mouseUp
    case arrow(dx: Int, dy: Int)
}

 final class ClickableNSImageView: NSImageView {
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

