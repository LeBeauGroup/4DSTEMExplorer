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
    var zoom: CGFloat = 1.0 { didSet { applyScale() } }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.anchorPoint = CGPoint(x: 0, y: 0)
        applyScale()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.anchorPoint = CGPoint(x: 0, y: 0)
        applyScale()
    }
    private func applyScale() {
        layer?.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
    }
}

// SwiftUI wrapper for ImageViewer inside an NSScrollView with a centering clip view
struct ImageViewerRepresentable: NSViewRepresentable {
    @EnvironmentObject var model: DataViewModel
    var imageView:ImageViewer?
    

    final class Coordinator: NSObject, ImageViewerDelegate {
        var parent: ImageViewerRepresentable
        var zoom: CGFloat = 1.0
        init(parent: ImageViewerRepresentable) { self.parent = parent }

        func averagePatternInRect(_ rect: NSRect?) {
            // Convert rect in image points to model image-space (i,j) rect if needed
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

        @objc func handleMagnify(_ gr: NSMagnificationGestureRecognizer) {
            guard let scrollView = (gr.view?.enclosingScrollView) else { return }
            guard let container = scrollView.documentView as? ZoomContainerView else { return }
            let delta = gr.magnification + 1.0
            zoom = max(0.1, min(8.0, zoom * delta))
            container.zoom = zoom
            // Update container frame to scaled content size if we can infer from imageView
            if let imageView = container.subviews.first as? ImageViewer, let img = imageView.image {
                let baseSize = img.size
                let scaled = NSSize(width: baseSize.width * zoom, height: baseSize.height * zoom)
                container.setFrameSize(scaled)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
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

        // Magnification gesture
        let mag = NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMagnify(_:)))
        container.addGestureRecognizer(mag)
        
        scrollView.documentView = container
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let container = scrollView.documentView as? ZoomContainerView,
              let imageView = container.subviews.first as? ImageViewer else { return }
        // Update selection mode based on model
//
//        imageView.selectMode = model.selectionMode == .marquee ? .marquee : (model.selectionMode == .point ? .point : .none)
      
        let imageToDisplay = model.nsImage()
        
        if let imageToDisplay {
            let width = imageToDisplay.size.width
            let height = imageToDisplay.size.height
//            let ciImage = CIImage(cvPixelBuffer: pb)
//            let rep = NSCIImageRep(ciImage: ciImage)
            let baseSize = NSSize(width: width, height: height)
//            let nsImage = NSImage(size: baseSize)
//            nsImage.addRepresentation(rep)
            imageView.imageScaling = .scaleNone
            let scaled = NSSize(width: baseSize.width * context.coordinator.zoom, height: baseSize.height * context.coordinator.zoom)
           
//            imageView.needsDisplay = true
            
            imageView.image = imageToDisplay
            
            imageView.frame = NSRect(origin: NSPoint.zero, size: imageToDisplay.size)
          imageView.needsDisplay = true
            
            container.zoom = context.coordinator.zoom
            container.setFrameSize(scaled)
        } else {
            imageView.image = model.nsImage()
            imageView.frame = NSRect(origin: NSPoint.zero, size: model.scanImage?.size ?? NSSize.zero            )
//            container.setFrameSize(model.scanImage?.size ?? NSSize.zero)
        }
        
        

        // Reflect model selection rect if any
        if let r = model.selectionRect {
            imageView.selectionRect = r
        } else {
            imageView.selectionRect = nil
        }
    }
}
