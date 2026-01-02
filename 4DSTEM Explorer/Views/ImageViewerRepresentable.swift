import SwiftUI
import AppKit

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let docView = self.documentView else { return rect }
        let docFrame = docView.frame
        if docFrame.width < rect.width {
            rect.origin.x = floor((docFrame.width - rect.width) / 2.0)
        }
        if docFrame.height < rect.height {
            rect.origin.y = floor((docFrame.height - rect.height) / 2.0)
        }
        return rect
    }
    override var isFlipped: Bool { true }
}

final class ZoomContainerView: NSView {
    // No longer applying layer-based scaling; leave zoom at 1.0.
    var zoom: CGFloat = 1.0
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.anchorPoint = CGPoint(x: 0, y: 0)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.anchorPoint = CGPoint(x: 0, y: 0)
    }
}

// SwiftUI wrapper for ImageViewer inside an NSScrollView with a centering clip view
struct ImageViewerRepresentable: NSViewRepresentable {
    @EnvironmentObject var model: DataViewModel
    var imageView: ImageViewer?
    // Optional callback to observe magnification changes without touching the model
    var onMagnificationChanged: ((CGFloat) -> Void)?
    
    // External triggers from toolbar/buttons; bump the ID to perform action
    var zoomToFitRequestID: UUID?
    var zoomInRequestID: UUID?
    var zoomOutRequestID: UUID?

    @MainActor
    final class Coordinator: NSObject, ImageViewerDelegate {
        var parent: ImageViewerRepresentable
        var currentScale: Double = 1.0
        weak var scrollView: NSScrollView?
        private func notifyMagnificationChanged(_ value: CGFloat) {
            parent.onMagnificationChanged?(value)
        }

        init(parent: ImageViewerRepresentable) { self.parent = parent }

        func averagePatternInRect(_ rect: NSRect?) {
            guard let model = parent.model as DataViewModel? else { return }
            guard let rect = rect else {
                model.selectionRect = nil
                model.updatePatternForCurrentSelection(interactive: false)
                return
            }
            // NSImageView is flipped here (ImageViewer overrides isFlipped = true),
            // map to image coordinates: x -> j, y -> i
            let imgW = CGFloat(max(model.imageWidth, 1))
            let imgH = CGFloat(max(model.imageHeight, 1))
            var r = rect
            // Clamp to image bounds
            if r.width < 0 { r.origin.x += r.width; r.size.width = -r.width }
            if r.height < 0 { r.origin.y += r.height; r.size.height = -r.height }
            r.origin.x = max(0, min(r.origin.x, imgW - 1))
            r.origin.y = max(0, min(r.origin.y, imgH - 1))
            r.size.width = max(0, min(r.size.width, imgW - r.origin.x))
            r.size.height = max(0, min(r.size.height, imgH - r.origin.y))
            model.selectionRect = r
            model.selectionMode = .marquee
            model.updatePatternForCurrentSelection(interactive: true)
        }

        func selectPatternAt(_ i: Int, _ j: Int) {
            guard let model = parent.model as DataViewModel? else { return }
            model.selectionMode = .point
            model.select(i: i, j: j)
        }

        @objc
        func handleMagnify(_ gr: NSMagnificationGestureRecognizer) {
            guard let scrollView = (gr.view?.enclosingScrollView) else { return }

            // Multiplicative/exponential scaling applied to NSScrollView.magnification
            let k: CGFloat = 0.8 // tune 0.6...1.2 to taste
            let delta = gr.magnification
            let current = scrollView.magnification
            let proposed = current * exp(k * delta)
            let clamped = min(max(proposed, scrollView.minMagnification), scrollView.maxMagnification)

            if clamped != current {
                scrollView.magnification = clamped
                currentScale = Double(clamped)
                notifyMagnificationChanged(clamped)
            }

            // Reset so magnification changes are incremental
            gr.magnification = 0
        }
        
        func zoom(by factor: CGFloat) {
            guard let scrollView else { return }
            let current = scrollView.magnification
            let proposed = current * factor
            let clamped = min(max(proposed, scrollView.minMagnification), scrollView.maxMagnification)
            if clamped != current {
                scrollView.magnification = clamped
                currentScale = Double(clamped)
                notifyMagnificationChanged(clamped)
            }
        }

        func zoomIn() { zoom(by: 1.25) }
        func zoomOut() { zoom(by: 0.8) }

        func zoomToFitIfPossible() {
            guard let scrollView = scrollView,
                  let container = scrollView.documentView as? NSView,
                  let imageView = container.subviews.first as? NSImageView else { return }
            // Reuse fit logic inline to avoid needing parent method
            guard let img = imageView.image else { return }
            let imageSize = img.size
            guard imageSize.width > 0, imageSize.height > 0 else { return }
            let clipSize = scrollView.contentView.bounds.size
            guard clipSize.width > 0, clipSize.height > 0 else { return }
            let fitW = clipSize.width / imageSize.width
            let fitH = clipSize.height / imageSize.height
            var fit = min(fitW, fitH)
            fit = min(max(fit, scrollView.minMagnification), scrollView.maxMagnification)
            if scrollView.magnification != fit {
                scrollView.magnification = fit
                currentScale = Double(fit)
                notifyMagnificationChanged(fit)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        context.coordinator.scrollView = scrollView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        // Enable native magnification and panning
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8.0
        scrollView.magnification = 1.0

        let clip = CenteringClipView(frame: NSRect.zero)
        clip.drawsBackground = false
        scrollView.contentView = clip

        let container = ZoomContainerView(frame: NSRect.zero)

        let imageView = ImageViewer(frame: NSRect.zero)
        imageView.imageScaling = .scaleNone
        imageView.delegate = context.coordinator
        imageView.selectionIsHidden = false
        imageView.selectMode = model.selectionMode == .marquee ? .marquee : (model.selectionMode == .point ? .point : .none)
        container.addSubview(imageView)

        // Magnification gesture -> adjust scrollView.magnification
        let mag = NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMagnify(_:)))
        container.addGestureRecognizer(mag)
        
        scrollView.documentView = container
        return scrollView
    }

    private func fitMagnification(scrollView: NSScrollView, container: NSView, imageView: NSImageView, coordinator: Coordinator) {
        guard let img = imageView.image else { return }
        let imageSize = img.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        // Visible area inside the contentView
        let clipSize = scrollView.contentView.bounds.size
        guard clipSize.width > 0, clipSize.height > 0 else { return }

        // Compute fit while preserving aspect
        let fitW = clipSize.width / imageSize.width
        let fitH = clipSize.height / imageSize.height
        var fit = min(fitW, fitH)

        // Clamp to allowed range
        fit = min(max(fit, scrollView.minMagnification), scrollView.maxMagnification)

        // Apply
        if scrollView.magnification != fit {
            scrollView.magnification = fit
            coordinator.currentScale = Double(fit)
            coordinator.parent.onMagnificationChanged?(fit)
        }
//        if CGFloat(scro.currentScale) != fit {
//            currentScale = Double(fit)
//        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let container = scrollView.documentView as? ZoomContainerView,
              let imageView = container.subviews.first as? ImageViewer else { return }

        // Handle external toolbar triggers by observing request IDs
        if let id = zoomToFitRequestID { _ = id; context.coordinator.zoomToFitIfPossible() }
        if let id = zoomInRequestID { _ = id; context.coordinator.zoomIn() }
        if let id = zoomOutRequestID { _ = id; context.coordinator.zoomOut() }

        // Removed sync magnification with model to avoid interference

        // Update the image and set base (unmagnified) sizes; NSScrollView scales visually
        let imageToDisplay = model.nsImage()
        var didSetImage = false
        
        if let imageToDisplay {
            imageView.imageScaling = .scaleNone
            imageView.image = imageToDisplay

            // Base (unmagnified) size
            let baseSize = imageToDisplay.size
            imageView.frame = NSRect(origin: .zero, size: baseSize)

            // Ensure container is at least the base size (document view content size)
            if container.frame.size != baseSize {
                container.setFrameSize(baseSize)
            }

            imageView.needsLayout = true
            imageView.needsDisplay = true
            didSetImage = true
        } else {
            // Fallback content size if needed
            let fallbackImage = model.nsImage()
            imageView.image = fallbackImage
            let fallbackSize = fallbackImage?.size ?? (model.scanImage?.size ?? .zero)
            imageView.frame = NSRect(origin: .zero, size: fallbackSize)
            if container.frame.size != fallbackSize {
                container.setFrameSize(fallbackSize)
            }
            imageView.needsLayout = true
            imageView.needsDisplay = true
        }

        // Auto-fit on first image set or when a zoom-to-fit request occurs
        if didSetImage {
            fitMagnification(scrollView: scrollView, container: container, imageView: imageView, coordinator: context.coordinator)
        }

        // If a request ID changed since last update, perform fit (SwiftUI will call updateNSView on change)
//        _ = model.zoomToFitRequestID
//        if imageView.image != nil {
//            fitMagnification(scrollView: scrollView, container: container, imageView: imageView)
//        }

        // Reflect model selection rect if any
        if let r = model.selectionRect {
            imageView.selectionRect = r
        } else {
            imageView.selectionRect = nil
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
