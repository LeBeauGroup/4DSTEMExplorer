import SwiftUI
import AppKit

public struct ZoomableComputedImageView: NSViewRepresentable {
    public let image: NSImage
    public var minZoom: CGFloat = 0.1
    public var maxZoom: CGFloat = 8.0
    @Binding public var zoom: CGFloat

    public init(image: NSImage, minZoom: CGFloat = 0.1, maxZoom: CGFloat = 8.0, zoom: Binding<CGFloat>) {
        self.image = image
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self._zoom = zoom
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = minZoom
        scrollView.maxMagnification = maxZoom

        let visibleSize = scrollView.contentView.bounds.size
        let container = NSView(frame: NSRect(origin: .zero, size: visibleSize))
        container.wantsLayer = false

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: .zero))
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.image = image
        container.addSubview(imageView)

        scrollView.documentView = container
        let clampedZoom = clamp(zoom, minZoom, maxZoom)
        scrollView.magnification = clampedZoom

        context.coordinator.scrollView = scrollView
        context.coordinator.containerView = container
        context.coordinator.imageView = imageView
        context.coordinator.updateImage(image)
        context.coordinator.layoutForCurrentZoom(centerPreserving: false)

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Update image if different instance or size changed
        if context.coordinator.imageView?.image !== image || context.coordinator.imageSize != image.size {
            context.coordinator.updateImage(image)
        }

        let clampedZoom = clamp(zoom, minZoom, maxZoom)
        if abs(scrollView.magnification - clampedZoom) > 0.0001 {
            scrollView.magnification = clampedZoom
        }
        context.coordinator.layoutForCurrentZoom(centerPreserving: true)
    }

    private func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        return Swift.min(Swift.max(value, minValue), maxValue)
    }

    public class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var containerView: NSView?
        weak var imageView: NSImageView?
        var parent: ZoomableComputedImageView

        var imageSize: CGSize = .zero
        var displaySize: CGSize = .zero
        private var lastScaledSize: CGSize = .zero

        init(parent: ZoomableComputedImageView) {
            self.parent = parent
            super.init()
        }

        func updateImage(_ image: NSImage) {
            DispatchQueue.main.async {
                self.imageView?.image = image
                self.imageSize = image.size
            }
        }

        private func computeAspectFitSize(containerSize: CGSize, imageSize: CGSize) -> CGSize {
            guard imageSize.width > 0 && imageSize.height > 0 && containerSize.width > 0 && containerSize.height > 0 else {
                return .zero
            }
            let widthRatio = containerSize.width / imageSize.width
            let heightRatio = containerSize.height / imageSize.height
            let scale = min(widthRatio, heightRatio)
            return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        }

        func layoutForCurrentZoom(centerPreserving: Bool) {
            guard
                let scroll = scrollView,
                let container = containerView,
                let imageView = imageView
            else { return }

            DispatchQueue.main.async {
                let visibleSize = scroll.contentView.bounds.size
                if !visibleSize.equalTo(container.frame.size) {
                    container.frame = NSRect(origin: .zero, size: visibleSize)
                }

                let baseSize = self.computeAspectFitSize(containerSize: visibleSize, imageSize: self.imageSize)
                if baseSize == .zero {
                    self.lastScaledSize = .zero
                    imageView.frame = NSRect(origin: .zero, size: .zero)
                    return
                }

                let magnification = scroll.magnification
                let scaledSize = CGSize(width: baseSize.width * magnification, height: baseSize.height * magnification)

                var newOrigin = CGPoint.zero

                if scaledSize.width < visibleSize.width {
                    newOrigin.x = (visibleSize.width - scaledSize.width) / 2
                }
                if scaledSize.height < visibleSize.height {
                    newOrigin.y = (visibleSize.height - scaledSize.height) / 2
                }

                let oldScaledSize = self.lastScaledSize
                self.lastScaledSize = scaledSize

                if centerPreserving,
                   oldScaledSize.width > 0, oldScaledSize.height > 0,
                   scaledSize.width > visibleSize.width || scaledSize.height > visibleSize.height
                {
                    // Preserve content center in document coordinates
                    let oldDocVisible = scroll.contentView.bounds
                    let oldCenter = CGPoint(x: oldDocVisible.midX, y: oldDocVisible.midY)

                    // Scale ratio from old scaled size to new scaled size
                    let scaleRatioWidth = scaledSize.width / oldScaledSize.width
                    let scaleRatioHeight = scaledSize.height / oldScaledSize.height

                    let newCenter = CGPoint(x: oldCenter.x * scaleRatioWidth, y: oldCenter.y * scaleRatioHeight)

                    var newOriginX = newCenter.x - visibleSize.width / 2
                    var newOriginY = newCenter.y - visibleSize.height / 2

                    // Clamp newOrigin within document bounds
                    let docWidth = container.bounds.width
                    let docHeight = container.bounds.height

                    newOriginX = max(0, min(newOriginX, docWidth - visibleSize.width))
                    newOriginY = max(0, min(newOriginY, docHeight - visibleSize.height))

                    // Set imageView frame before scrolling
                    imageView.frame = NSRect(origin: newOrigin, size: scaledSize)

                    let newOriginPoint = CGPoint(x: newOriginX, y: newOriginY)
                    scroll.contentView.scroll(to: newOriginPoint)
                    scroll.reflectScrolledClipView(scroll.contentView)
                } else {
                    imageView.frame = NSRect(origin: newOrigin, size: scaledSize)
                }

                // Update parent's zoom binding if differs
                if abs(self.parent.zoom - magnification) > 0.0001 {
                    DispatchQueue.main.async {
                        self.parent.zoom = magnification
                    }
                }
            }
        }
    }
}
