import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

struct PixelBufferView: NSViewRepresentable {
    let pixelBuffer: CVPixelBuffer

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.imageAlignment = .alignCenter
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rep = NSCIImageRep(ciImage: ciImage)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        nsView.image = img
    }
}
