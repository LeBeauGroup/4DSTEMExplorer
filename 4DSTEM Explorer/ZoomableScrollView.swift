import SwiftUI
import AppKit

struct ZoomableScrollView<Content: View>: NSViewRepresentable {
    @Binding private var magnification: CGFloat
    private var content: Content
    private let minZoomScale: CGFloat
    private let maxZoomScale: CGFloat

    init(magnification: Binding<CGFloat>, minZoomScale: CGFloat = 1.0, maxZoomScale: CGFloat = 4.0, @ViewBuilder content: () -> Content) {
        self._magnification = magnification
        self.minZoomScale = minZoomScale
        self.maxZoomScale = maxZoomScale
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = minZoomScale
        scrollView.maxMagnification = maxZoomScale
        scrollView.magnification = magnification

        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        // Start with the content's fitting size; will be updated in updateNSView as needed
        let initialSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = []
        scrollView.documentView = hostingView

        // Use gesture recognizer to handle magnification since NSScrollView has no delegate property
        let magnifyRecognizer = NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMagnifyGesture(_:)))
        scrollView.addGestureRecognizer(magnifyRecognizer)
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let hostingView = nsView.documentView as? NSHostingView<Content> {
            hostingView.rootView = content
        }
        nsView.magnification = magnification
        if let hostingView = nsView.documentView as? NSHostingView<Content> {
            // Ask the hosting view for its best size and scale it by magnification
            let baseSize = hostingView.fittingSize
            let scaledSize = NSSize(width: max(baseSize.width * magnification, nsView.contentView.bounds.width + 1),
                                    height: max(baseSize.height * magnification, nsView.contentView.bounds.height + 1))
            if hostingView.frame.size != scaledSize {
                hostingView.frame.size = scaledSize
            }
        }
        context.coordinator.scrollView = nsView
        if nsView.magnification < minZoomScale {
            nsView.magnification = minZoomScale
        } else if nsView.magnification > maxZoomScale {
            nsView.magnification = maxZoomScale
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: ZoomableScrollView
        weak var scrollView: NSScrollView?

        init(_ parent: ZoomableScrollView) {
            self.parent = parent
        }

        @objc func handleMagnifyGesture(_ recognizer: NSMagnificationGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            switch recognizer.state {
            case .began, .changed:
                // Apply incremental magnification while clamping to min/max
                let current = scrollView.magnification
                let proposed = current + recognizer.magnification
                let clamped = min(max(proposed, parent.minZoomScale), parent.maxZoomScale)
                if clamped != current {
                    scrollView.magnification = clamped
                    parent.magnification = clamped
                }
                // Reset recognizer's magnification so changes are incremental
                recognizer.magnification = 0
            case .ended, .cancelled, .failed:
                parent.magnification = scrollView.magnification
            default:
                break
            }
        }
    }
}
