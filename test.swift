import AppKit
import SwiftUI

extension Notification.Name {
    static let requestZoomableScrollViewFit = Notification.Name("requestZoomableScrollViewFit")
    static let viewportDidChange = Notification.Name("viewportDidChange")
}

/// EnhancedZoomableNSScrollView
/// - Accepts a binding to magnification so SwiftUI buttons can control zoom.
/// - Coordinator reports magnification changes back to SwiftUI.
/// - Button-driven zoom animates smoothly and disables at bounds.
///

final class CenteringClipView: NSClipView {
override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var constrainedClipViewBounds = super.constrainBoundsRect(proposedBounds)
    
    guard let documentView = documentView else {
        return constrainedClipViewBounds
    }
    
    let documentViewFrame = documentView.frame
    
    // Center horizontally if the document view is narrower than the clip view
    if documentViewFrame.width < proposedBounds.width {
        constrainedClipViewBounds.origin.x = floor((proposedBounds.width - documentViewFrame.width) / -2.0)
    }
    
    // Center vertically if the document view is shorter than the clip view
    if documentViewFrame.height < proposedBounds.height {
        constrainedClipViewBounds.origin.y = floor((proposedBounds.height - documentViewFrame.height) / -2.0)
    }
    
    return constrainedClipViewBounds
}
}

struct EnhancedZoomableNSScrollView: NSViewRepresentable {
    let image: NSImage
    @Binding var magnification: CGFloat
    @Binding var selectionRectInImage: CGRect?

    // optional configuration
    var minMagnification: CGFloat = 0
    var maxMagnification: CGFloat = 1.0
    var animationDuration: TimeInterval = 0.0

    var onRequestFit: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = minMagnification
        scrollView.maxMagnification = maxMagnification
        scrollView.drawsBackground = false

        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = true
        imageView.frame = CGRect(origin: .zero, size: image.size)
        imageView.isEditable = false

        // Double-click gesture to toggle zoom (uses coordinator)
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick(_:)))
        click.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(click)

        // Pinch/trackpad magnification is handled by NSScrollView.
        // Observe live magnification using NotificationCenter.
        
        scrollView.contentView = CenteringClipView()
        scrollView.contentView.frame = scrollView.frame
        scrollView.documentView = imageView
        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        
        // Add selection overlay layer on top of the image view
        let selectionLayer = CAShapeLayer()
        selectionLayer.fillColor = NSColor.clear.cgColor
        selectionLayer.strokeColor = NSColor.systemRed.cgColor
        selectionLayer.lineWidth = 2.0
        selectionLayer.lineJoin = kCALineJoinMiter
        selectionLayer.lineDashPattern = nil
        imageView.layer?.addSublayer(selectionLayer)
        context.coordinator.selectionLayer = selectionLayer
        
        context.coordinator.startObservingMagnification()
        
        context.coordinator.onRequestFit = { [weak coordinator = context.coordinator] in
            guard let sv = coordinator?.scrollView, let iv = coordinator?.imageView else { return nil }
            let svSize = sv.bounds.size
            let imgSize = iv.image?.size ?? .zero
            guard svSize.width > 0, svSize.height > 0, imgSize.width > 0, imgSize.height > 0 else { return nil }
            let widthRatio = svSize.width / imgSize.width
            let heightRatio = svSize.height / imgSize.height
            return min(widthRatio, heightRatio)
        }

        NotificationCenter.default.addObserver(forName: .requestZoomableScrollViewFit, object: nil, queue: .main) { [weak coordinator = context.coordinator] _ in
            coordinator?.requestFitAndApply()
        }

        NotificationCenter.default.addObserver(forName: Notification.Name("ConvertOverlayPointToImage"), object: nil, queue: .main) { [weak coordinator = context.coordinator] note in
            guard let coord = coordinator, let sv = coord.scrollView, let iv = coord.imageView else { return }
            guard let pointVal = note.userInfo?["point"] as? NSValue,
                  let sizeVal = note.userInfo?["overlaySize"] as? NSValue,
                  let callback = note.userInfo?["result"] as? (CGPoint?) -> Void else { return }

            let overlaySize = sizeVal.sizeValue
            let overlayPoint = pointVal.pointValue

            // 1) Map overlay point to contentView coordinates (AppKit bottom-left)
            let contentBounds = sv.contentView.bounds
            let scaleXContent = contentBounds.width / overlaySize.width
            let scaleYContent = contentBounds.height / overlaySize.height
            let contentPoint = CGPoint(
                x: contentBounds.minX + overlayPoint.x * scaleXContent,
                y: contentBounds.minY + (overlaySize.height - overlayPoint.y) * scaleYContent
            )

            // 2) Convert contentView -> imageView coordinates
            let pointInImageView = iv.convert(contentPoint, from: sv.contentView)

            // 3) Convert imageView coordinates -> intrinsic image coordinates using current scale
            let imgSize = iv.image?.size ?? .zero
            guard imgSize.width > 0, imgSize.height > 0 else { callback(nil); return }
            let scaleXImage = iv.bounds.width / imgSize.width
            let scaleYImage = iv.bounds.height / imgSize.height
            guard scaleXImage > 0, scaleYImage > 0 else { callback(nil); return }

            let intrinsicPoint = CGPoint(
                x: pointInImageView.x / scaleXImage,
                y: pointInImageView.y / scaleYImage
            )
//            print("ConvertOverlayPointToImage (intrinsic): overlay=\(overlayPoint) overlaySize=\(overlaySize) contentBounds=\(contentBounds) iv.bounds=\(iv.bounds) imgSize=\(imgSize) -> image(intrinsic)=\(intrinsicPoint)")
            callback(intrinsicPoint)
        }

        NotificationCenter.default.addObserver(forName: Notification.Name("ConvertImageRectToOverlay"), object: nil, queue: .main) { [weak coordinator = context.coordinator] note in
            guard let coord = coordinator, let sv = coord.scrollView, let iv = coord.imageView else { return }
            guard let rectVal = note.userInfo?["rect"] as? NSValue,
                  let sizeVal = note.userInfo?["overlaySize"] as? NSValue,
                  let callback = note.userInfo?["result"] as? (CGRect?) -> Void else { return }

            let overlaySize = sizeVal.sizeValue
            let rectInImage = rectVal.rectValue

            let imgSize = iv.image?.size ?? .zero
            guard imgSize.width > 0, imgSize.height > 0 else { callback(nil); return }
            let scaleXImage = iv.bounds.width / imgSize.width
            let scaleYImage = iv.bounds.height / imgSize.height
            guard scaleXImage > 0, scaleYImage > 0 else { callback(nil); return }

            // 1) Scale intrinsic image rect into imageView coordinates
            let rectInImageView = CGRect(
                x: rectInImage.minX * scaleXImage,
                y: rectInImage.minY * scaleYImage,
                width: rectInImage.width * scaleXImage,
                height: rectInImage.height * scaleYImage
            )

            // 2) Convert imageView -> contentView coordinates
            let rectInContent = sv.contentView.convert(rectInImageView, from: iv)

            // 3) Map contentView rect into overlay space and flip Y
            let contentBounds = sv.contentView.bounds
            let scaleXContent = overlaySize.width / contentBounds.width
            let scaleYContent = overlaySize.height / contentBounds.height

            let x = (rectInContent.minX - contentBounds.minX) * scaleXContent
            let yTop = (rectInContent.maxY - contentBounds.minY) * scaleYContent
            let y = overlaySize.height - yTop
            let w = rectInContent.width * scaleXContent
            let h = rectInContent.height * scaleYContent

            let rectOverlay = CGRect(x: x, y: y, width: w, height: h)
            print("ConvertImageRectToOverlay (from intrinsic): imageRect=\(rectInImage) overlaySize=\(overlaySize) contentBounds=\(contentBounds) iv.bounds=\(iv.bounds) imgSize=\(imgSize) -> overlayRect=\(rectOverlay)")
            callback(rectOverlay)
        }
        
        NotificationCenter.default.addObserver(forName: .viewportDidChange, object: nil, queue: .main) { [weak coordinator = context.coordinator] _ in
            coordinator?.updateSelectionLayerPath()
        }

        // initialize with binding value (clamped)
        let initial = clamp(magnification, lower: scrollView.minMagnification, upper: scrollView.maxMagnification)
        scrollView.setMagnification(initial, centeredAt: CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY))

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }

        // Update imageView sizing to fit visible area if needed
        let contentSize = nsView.contentView.bounds.size
        if contentSize.width <= 0 || contentSize.height <= 0 { return }

//        let imgSize = image.size
//        let widthRatio = contentSize.width / imgSize.width
//        let heightRatio = contentSize.height / imgSize.height
//        let fitScale = min(widthRatio, heightRatio)

        // Size imageView to the fit size (so "fit" behavior is predictable)
//        let scaledSize = CGSize(width: imgSize.width * fitScale, height: imgSize.height * fitScale)
//        imageView.frame = CGRect(origin: .zero, size: scaledSize)

        // Apply magnification from binding if it differs from current
        let clamped = clamp(magnification, lower: nsView.minMagnification, upper: nsView.maxMagnification)
        
        
//        imageView.frame = CGRect(origin: .zero, size: scaledSize)
        if abs(nsView.magnification - clamped) > 0.0001 {
            nsView.setMagnification(clamped, centeredAt: CGPoint(x: nsView.contentView.bounds.midX, y: nsView.contentView.bounds.midY))
        }
        

//        if abs(nsView.magnification - clamped) > 0.0001 {
//            // animate the magnification change
//            NSAnimationContext.runAnimationGroup { ctx in
//                ctx.duration = animationDuration
//                nsView.animator().setMagnification(clamped, centeredAt: CGPoint(x: nsView.contentView.bounds.midX, y: nsView.contentView.bounds.midY))
//            }
//        }

        // Ensure coordinator knows the valid range
//        context.coordinator.minMagnification = nsView.minMagnification
//        context.coordinator.maxMagnification = nsView.maxMagnification

        // Update selection overlay layer path
        context.coordinator.updateSelectionLayerPath()
    }

    func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingMagnification()
    }

    private func clamp(_ v: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        return min(max(v, lower), upper)
    }

    class Coordinator: NSObject {
        var parent: EnhancedZoomableNSScrollView
        weak var scrollView: NSScrollView?
        weak var imageView: NSImageView?
        var selectionLayer: CAShapeLayer?
//        var minMagnification: CGFloat = 0.1
//        var maxMagnification: CGFloat = 6.0

        private var liveMagObserver: Any?
        private var endMagObserver: Any?
        private var boundsChangeObserver: Any?

        var onRequestFit: (() -> CGFloat?)?

//        var bumpViewportVersion: (() -> Void)?

        init(_ parent: EnhancedZoomableNSScrollView) {
            self.parent = parent
            super.init()
        }

        func startObservingMagnification() {
            guard let sv = scrollView else { return }
            let center = NotificationCenter.default

            sv.contentView.postsBoundsChangedNotifications = true

//            liveMagObserver = center.addObserver(
//                forName: NSScrollView.didLiveMagnifyNotification,
//                object: sv,
//                queue: .main
//            ) { [weak self] _ in
//                guard let self = self, let sv = self.scrollView else { return }
//                let mag = sv.magnification
//                if abs(self.parent.magnification - mag) > 0.0001 {
//                    self.parent.magnification = mag
//                }
//                NotificationCenter.default.post(name: .viewportDidChange, object: nil)
//            }

            endMagObserver = center.addObserver(
                forName: NSScrollView.didEndLiveMagnifyNotification,
                object: sv,
                queue: .main
            ) { [weak self] _ in
                guard let self = self, let sv = self.scrollView else { return }
                let mag = sv.magnification
                if abs(self.parent.magnification - mag) > 0.0001 {
                    self.parent.magnification = mag
                }
                NotificationCenter.default.post(name: .viewportDidChange, object: nil)
            }
            
            boundsChangeObserver = center.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main) { _ in
                NotificationCenter.default.post(name: .viewportDidChange, object: nil)
            }
        }

        func stopObservingMagnification() {
            let center = NotificationCenter.default
            if let liveMagObserver { center.removeObserver(liveMagObserver) }
            if let endMagObserver { center.removeObserver(endMagObserver) }
            if let boundsChangeObserver { center.removeObserver(boundsChangeObserver) }
            liveMagObserver = nil
            endMagObserver = nil
            boundsChangeObserver = nil
        }

        @objc func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended,
                  let imageView = imageView,
                  let scrollView = imageView.enclosingScrollView else { return }

            let current = scrollView.magnification
            let minMag = scrollView.minMagnification
            let maxMag = scrollView.maxMagnification

            if abs(current - minMag) < 0.001 {
                // Zoom in toward click point
                let locationInView = recognizer.location(in: imageView)
                let target = min(max(current * 2.5, minMag), maxMag)
                scrollView.setMagnification(target, centeredAt: locationInView)
                parent.magnification = target
            } else {
                // Reset to fit/min
                let target = minMag
                scrollView.setMagnification(target, centeredAt: CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY))
                parent.magnification = target
            }
        }
        
        func requestFitAndApply() {
            guard let fit = onRequestFit?() else { return }
            guard let sv = scrollView, let iv = imageView else { return }
            let clamped = min(max(fit, sv.minMagnification), sv.maxMagnification)
            let center = CGPoint(x: iv.bounds.midX, y: iv.bounds.midY)
            sv.setMagnification(clamped, centeredAt: center)
            parent.magnification = clamped
        }
        
        func updateSelectionLayerPath() {
            guard let iv = imageView,
                  let layer = selectionLayer,
                  let imgSize = iv.image?.size,
                  let rectInImage = parent.selectionRectInImage else {
                selectionLayer?.path = nil
                return
            }
            // Compute scaling from intrinsic image to imageView bounds
            let scaleX = iv.bounds.width / imgSize.width
            let scaleY = iv.bounds.height / imgSize.height
            // Map intrinsic image rect into imageView coordinates
            let rectInView = CGRect(x: rectInImage.minX * scaleX,
                                    y: rectInImage.minY * scaleY,
                                    width: rectInImage.width * scaleX,
                                    height: rectInImage.height * scaleY)
            // Update layer frame to match imageView bounds and set path in its local coords
            layer.frame = iv.bounds
            let path = CGMutablePath()
            path.addRect(rectInView)
    
            layer.path = path
        }
    }
}

private func convertOverlayPointToImage(_ point: CGPoint, overlaySize: CGSize) -> CGPoint? {
    var result: CGPoint?
    NotificationCenter.default.post(name: Notification.Name("ConvertOverlayPointToImage"), object: nil, userInfo: ["point": NSValue(point: point), "overlaySize": NSValue(size: overlaySize), "result": { (p: CGPoint?) in result = p }])
    return result
}

private func convertImageRectToOverlay(_ rectInImage: CGRect?, overlaySize: CGSize) -> CGRect? {
    guard let rectInImage else { return nil }
    var result: CGRect?
    NotificationCenter.default.post(name: Notification.Name("ConvertImageRectToOverlay"), object: nil, userInfo: ["rect": NSValue(rect: rectInImage), "overlaySize": NSValue(size: overlaySize), "result": { (r: CGRect?) in result = r }])
    return result
}

// Removed ConditionalGestureModifier as unused after changes

// SwiftUI container demonstrating buttons wired to the binding
struct EnhancedZoomControlsView: View {
    @State private var magnification: CGFloat = 1.0
    @State private var selectionRectInImage: CGRect? = nil
    let maxMagnification: CGFloat = 20.0
    let minMagnification: CGFloat = 0.1
    let nsImage: NSImage

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button(action: zoomOut) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: [])
                .disabled(magnification <= 0.0001 || magnification <= minMagnification + 0.0001)

                Button(action: fit) {
                    Text("Fit")
                }.keyboardShortcut("=", modifiers: [])

                Button(action: zoomIn) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .keyboardShortcut("+", modifiers: [])
                .disabled(magnification >= 1000 || magnification >= maxMagnification - 0.0001)

                Spacer()

                Text(String(format: "%.2fx", Double(magnification)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            ZStack {
                EnhancedZoomableNSScrollView(
                    image: nsImage,
                    magnification: $magnification,
                    selectionRectInImage: $selectionRectInImage,
                    minMagnification: minMagnification,
                    maxMagnification: maxMagnification,
                    onRequestFit: { fit in
                        self.magnification = fit
                    }
                )

                SelectionInputRepresentable(selectionRectInImage: $selectionRectInImage)

            }
            .frame(minWidth: 400, minHeight: 300)
            .padding()
        }
        .onAppear {
            // initialize magnification to 1.0 (or compute fit later)
            magnification = 1.0
        }
    }

    private func zoomIn() {
        // smooth multiplicative zoom
//        withAnimation(.easeInOut(duration: 0.25)) {
            magnification = min(magnification + 1.25, maxMagnification)
//        }
    }

    private func zoomOut() {
//        withAnimation(.easeInOut(duration: 0.25)) {
            magnification = max(magnification / 1.25, minMagnification)
//        }
    }

    private func fit() {
        NotificationCenter.default.post(name: .requestZoomableScrollViewFit, object: nil)
    }
}

final class SelectionInputView: NSView {
    enum Mode { case none, creating, moving }
    var mode: Mode = .none
    var selectionRectInImageGetter: (() -> CGRect?)?
    var selectionRectInImageSetter: ((CGRect?) -> Void)?
    var overlaySizeProvider: (() -> CGSize)?
    private var moveOffsetInImage: CGPoint = .zero

    var onBegin: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    
    override func draw(_ dirtyRect: NSRect) {
        
        
        super.draw(dirtyRect)
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
//
//        NSColor.darkGray.set()
//        NSBezierPath(rect: dirtyRect).fill()
//
//
            // Selection is rendered by a CAShapeLayer attached to the image view; nothing to draw here.
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let overlaySize = overlaySizeProvider?() else { return }

        // Compute current overlay rect from image rect for hit test
        if let currentImageRect = selectionRectInImageGetter?(),
           let currentOverlayRectRaw = convertImageRectToOverlay(currentImageRect, overlaySize: overlaySize) {
            // Expand rect slightly to make hit testing more forgiving
            let currentOverlayRect = currentOverlayRectRaw.insetBy(dx: -2, dy: -2)
            if currentOverlayRect.contains(p) {
                if let startInImage = convertOverlayPointToImage(p, overlaySize: overlaySize) {
                    moveOffsetInImage = CGPoint(x: startInImage.x - currentImageRect.origin.x,
                                                y: startInImage.y - currentImageRect.origin.y)
                    mode = .moving
                    print("SelectionInputView: begin moving, overlay p=\(p), image start=\(startInImage), offset=\(moveOffsetInImage)")
                    return
                }
            }
        }

        // Otherwise, begin creating
        if let startInImage = convertOverlayPointToImage(p, overlaySize: overlaySize) {
            selectionRectInImageSetter?(CGRect(origin: startInImage, size: .zero))
            mode = .creating
            print("SelectionInputView: begin creating, overlay p=\(p), image start=\(startInImage)")
        } else {
            mode = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let overlaySize = overlaySizeProvider?() else { return }
        switch mode {
        case .creating:
            guard let startRect = selectionRectInImageGetter?(),
                  let currentInImage = convertOverlayPointToImage(p, overlaySize: overlaySize) else { return }
            let s = startRect.origin
            let c = currentInImage
            let rect = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
            selectionRectInImageSetter?(rect)
            print("SelectionInputView: creating drag to image=\(c), rect=\(rect)")
        case .moving:
            guard var rectImage = selectionRectInImageGetter?(),
                  let currentInImage = convertOverlayPointToImage(p, overlaySize: overlaySize) else { return }
            rectImage.origin = CGPoint(x: currentInImage.x - moveOffsetInImage.x,
                                       y: currentInImage.y - moveOffsetInImage.y)
            selectionRectInImageSetter?(rectImage)
            print("SelectionInputView: moving drag to image=\(currentInImage), newOrigin=\(rectImage.origin)")
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        mode = .none
        print("SelectionInputView: end drag")
        onEnd?()
    }
}

struct SelectionInputRepresentable: NSViewRepresentable {
    @Binding var selectionRectInImage: CGRect?

    func makeNSView(context: Context) -> SelectionInputView {
        let v = SelectionInputView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        v.selectionRectInImageGetter = { self.selectionRectInImage }
        v.selectionRectInImageSetter = { newRect in self.selectionRectInImage = newRect }
        v.overlaySizeProvider = { v.bounds.size }
//        v.onBegin = { point in
//            handleBegin(at: point, in: v)
//        }
//        v.onDrag = { point in
//            handleDrag(to: point, in: v)
//        }
//        v.onEnd = {
//            handleEnd(in: v)
//        }
        return v
    }

    func updateNSView(_ nsView: SelectionInputView, context: Context) {
        // Keep overlay size provider up-to-date with the current bounds
        nsView.overlaySizeProvider = { nsView.bounds.size }
    }

    private func handleBegin(at overlayPoint: CGPoint, in view: NSView) {
        guard let startInImage = convertOverlayPointToImage(overlayPoint, overlaySize: view.bounds.size) else { return }
        // Start a zero-sized rect at the start point
        selectionRectInImage = CGRect(origin: startInImage, size: .zero)
    }

    private func handleDrag(to overlayPoint: CGPoint, in view: NSView) {
        guard let startRect = selectionRectInImage,
              let currentInImage = convertOverlayPointToImage(overlayPoint, overlaySize: view.bounds.size) else { return }
        let s = startRect.origin
        let c = currentInImage
        let rect = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
        selectionRectInImage = rect
    }

    private func handleEnd(in view: NSView) {
        // No-op; selectionRectInImage already set during drag
    }
}


#Preview {

    EnhancedZoomControlsView(nsImage: #imageLiteral(resourceName: "scan_x100_y100_Int.png"))

}

