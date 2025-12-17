import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

struct ClickablePixelBufferView: NSViewRepresentable {
    let pixelBuffer: CVPixelBuffer
    let onClick: (Int, Int) -> Void

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.imageAlignment = .alignCenter
        v.wantsLayer = true

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
        Coordinator(onClick: onClick)
    }

    final class Coordinator: NSObject {
        var onClick: (Int, Int) -> Void
        var imageSize: CGSize = .zero

        init(onClick: @escaping (Int, Int) -> Void) {
            self.onClick = onClick
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? NSImageView else { return }
            let locationInView = gesture.location(in: view)

            guard let image = view.image, image.size.width > 0, image.size.height > 0 else { return }

            // Map view coordinates to image pixel coordinates
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

            guard drawRect.width > 0 && drawRect.height > 0 else { return }

            let nx = (locationInView.x - drawRect.minX) / drawRect.width
            let ny = (locationInView.y - drawRect.minY) / drawRect.height
            if nx < 0 || nx > 1 || ny < 0 || ny > 1 { return }

            let px = Int((nx * image.size.width).rounded())
            let py = Int(((1 - ny) * image.size.height).rounded())

            onClick(py, px) // Note: (i, j) -> (row, col)
        }
    }
}
