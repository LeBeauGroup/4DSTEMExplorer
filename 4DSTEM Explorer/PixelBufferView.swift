import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import QuartzCore

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


final class NearestNeighborNSImageView: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .none
        super.draw(dirtyRect)
    }
}

struct PatternView: NSViewRepresentable {
    let pattern: NSImage

    func makeNSView(context: Context) -> NearestNeighborNSImageView {
        let v = NearestNeighborNSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.imageAlignment = .alignCenter
        return v
    }

    func updateNSView(_ nsView: NearestNeighborNSImageView, context: Context) {
        nsView.image = pattern
    }
}

