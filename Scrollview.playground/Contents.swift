
import SwiftUI
import AppKit
import PlaygroundSupport


struct ZoomableNSScrollView: NSViewRepresentable {
    let image: NSImage

    // MARK: - Coordinator
    class Coordinator: NSObject {
        var parent: ZoomableNSScrollView
        weak var scrollView: NSScrollView?
        weak var imageView: NSImageView?

        init(_ parent: ZoomableNSScrollView) {
            self.parent = parent
        }

        @MainActor @objc func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            // Toggle between fit-to-screen and 1:1 on double click
            if scrollView.magnification > 1.01 {
                scrollView.setMagnification(1.0, centeredAt: recognizer.location(in: scrollView.contentView))
            } else {
                scrollView.setMagnification(min(max(2.0, scrollView.minMagnification), scrollView.maxMagnification), centeredAt: recognizer.location(in: scrollView.contentView))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 4.0
        scrollView.drawsBackground = false

        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.canDrawSubviewsIntoLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = true
        imageView.frame = CGRect(origin: .zero, size: image.size)
        imageView.isEditable = false
        imageView.allowsCutCopyPaste = false

        // enable gesture recognizers
        imageView.addGestureRecognizer(NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick(_:))))

        scrollView.documentView = imageView
        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }

        // Fit the image to the visible content size while preserving aspect ratio
        let contentSize = nsView.contentView.bounds.size
        if contentSize.width <= 0 || contentSize.height <= 0 { return }

        let imgSize = image.size
        let widthRatio = contentSize.width / imgSize.width
        let heightRatio = contentSize.height / imgSize.height
        let fitScale = min(widthRatio, heightRatio)
        // Size the imageView to the scaled image size
        let scaledSize = CGSize(width: imgSize.width * fitScale, height: imgSize.height * fitScale)
        imageView.frame = CGRect(origin: .zero, size: scaledSize)

        // Clamp magnification within allowed range
        nsView.magnification = max(nsView.minMagnification, min(nsView.magnification, nsView.maxMagnification))

        // Center document view if smaller than content
        let contentBounds = nsView.contentView.bounds
        let docRect = imageView.frame
        let offsetX = max((contentBounds.width - docRect.width) / 2.0, 0)
        let offsetY = max((contentBounds.height - docRect.height) / 2.0, 0)
        imageView.setFrameOrigin(NSPoint(x: offsetX, y: offsetY))
    }
}

// macOS SwiftUI example usage

struct MacContentView: View {
var body: some View {
VStack(spacing: 12) {
Text("Pinch/trackpad zoom or double‑click to toggle zoom")
.font(.headline)
.padding(.top)


    let nsImage = NSImage(named: "scan_x100_y100_Int.png")!
    ZoomableNSScrollView(image: nsImage)
    .frame(minWidth: 100, minHeight: 100)
    .border(Color.gray, width: 1)
    .padding()




Spacer()
}
.padding()
}
}

PlaygroundPage.current.setLiveView(
    MacContentView()
        .frame(width: 200, height: 200)
)

