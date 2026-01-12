//
//  interactive.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 1/8/26.
//  Copyright © 2026 The LeBeau Group. All rights reserved.
//

import SwiftUI
import AppKit

class CustomScrollView: NSScrollView {
    override func layout() {
        super.layout()
        
        // Mark all subviews for redrawing as they are scaled
        
        if let dv = self.documentView {
            for subview in dv.subviews {
                subview.setNeedsDisplay(subview.bounds)
            }
        }

    }
}

extension Notification.Name {
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
}
    
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

// 1. The SwiftUI Wrapper
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    @Binding var lastPoint:CGPoint?
    @Binding var marquee: CGRect?
    @Binding var selectionMode: InteractiveMarkerView.SelectionMode
    var isFirstLoad: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        
        let clip = CenteringClipView(frame: NSRect.zero)
        clip.drawsBackground = false
        scrollView.contentView = clip
        
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        
        
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1.0
        scrollView.maxMagnification = 20.0
        
        NotificationCenter.default.addObserver(forName: .zoomIn, object: nil, queue: .main) { _ in
            let newZoom = min(scrollView.magnification*1.25, scrollView.maxMagnification)
            scrollView.setMagnification(newZoom, centeredAt: .zero)
        }
        NotificationCenter.default.addObserver(forName: .zoomOut, object: nil, queue: .main) { _ in
            let newZoom = max(scrollView.magnification/1.25, scrollView.minMagnification)
            scrollView.setMagnification(newZoom, centeredAt: .zero)
        }
        
        NotificationCenter.default.addObserver(forName: .zoomOut, object: nil, queue: .main) { _ in
            let newZoom = max(scrollView.magnification/1.25, scrollView.minMagnification)
            scrollView.setMagnification(newZoom, centeredAt: .zero)
        }
        
        // Create the internal interactive view
        let interactiveView = InteractiveMarkerView(image: image, marquee: $marquee, selectionMode: $selectionMode, lastPoint: $lastPoint)

        scrollView.documentView = interactiveView
        
        if isFirstLoad{
            DispatchQueue.main.async {
                // This fits the documentView (your image container) perfectly into the scroll view
                scrollView.magnify(toFit: scrollView.documentView?.frame ?? .zero)
            }
            context.coordinator.isFirstLoad = false
        }
        

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        
        guard let container = nsView.documentView as? InteractiveMarkerView else { return }

        // 1. Detect if the image object has actually changed
        if container.image != image {
            container.updateImage(image)
            
            // 2. Reset first load flag to trigger auto-zoom for the new image
//            context.coordinator.isFirstLoad = true
            
            // 3. Clear existing selection for the new image
            marquee = nil
        }

        
//        if isFirstLoad{
//            DispatchQueue.main.async {
//                // This fits the documentView (your image container) perfectly into the scroll view
//                nsView.magnify(toFit: nsView.documentView?.frame ?? .zero)
//            }
//            context.coordinator.isFirstLoad = false
//        }
//            
        
        // Sync markers if they change from external SwiftUI buttons/logic
        if let docView = nsView.documentView as? InteractiveMarkerView {
            docView.updateSelectionMode(selectionMode)
            docView.updateLastPoint(lastPoint)
        }
    }
    
    class Coordinator: NSObject {
          var parent: ZoomableImageView
          var isFirstLoad = true
          weak var scrollView: NSScrollView?

          init(_ parent: ZoomableImageView) {
              self.parent = parent
              super.init()
          }

          func setup(_ scrollView: NSScrollView) {
              self.scrollView = scrollView
              
              // Listen for global zoom notifications
              NotificationCenter.default.addObserver(forName: .zoomIn, object: nil, queue: .main) { _ in
                  let newZoom = min(scrollView.magnification*1.25, scrollView.maxMagnification)
                  scrollView.setMagnification(newZoom, centeredAt: .zero)
                  if let dv = scrollView.documentView{
                      for sv in dv.subviews{
                          sv.needsDisplay = true
                      }
                  }
              }
              NotificationCenter.default.addObserver(forName: .zoomOut, object: nil, queue: .main) { _ in
                  let newZoom = max(scrollView.magnification/1.25, scrollView.minMagnification)
                  scrollView.setMagnification(newZoom, centeredAt: .zero)
              }
          }

          
          deinit {
              NotificationCenter.default.removeObserver(self)
          }
      }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}

// 2. The Custom AppKit View to handle clicks and drawing
class InteractiveMarkerView: NSView {
    private var startPoint: NSPoint?
    private var marqueeView = MarqueeShapeView()
    private var imageView:NSImageView
    private var selectionBinding: Binding<CGRect?>
    private var isDraggingExisting = false
    private var dragOffset: NSSize = .zero
    
    enum SelectionMode { case point, marquee }
    private var selectionModeBinding: Binding<SelectionMode>
    private var lastPointBinding: Binding<CGPoint?>
    
    var image: NSImage?
    
    private enum DragMode { case none, move, resize(MarqueeShapeView.HandlePosition) }
    private var dragMode: DragMode = .none
    private var lastDragPoint: NSPoint?

    init(image:NSImage,  marquee: Binding<CGRect?>, selectionMode: Binding<SelectionMode>, lastPoint: Binding<CGPoint?>) {
        self.selectionBinding = marquee
        self.selectionModeBinding = selectionMode
        self.lastPointBinding = lastPoint
        
        self.image = image
        imageView = NSImageView(image: image)
        imageView.frame = NSRect(origin: .zero, size: image.size)

        super.init(frame: .zero)
          
        self.frame = imageView.frame
        self.addSubview(imageView)
        
          // Setup Image
            

          
          
          // Add hidden marquee overlay
          marqueeView.isHidden = true
          self.addSubview(marqueeView)
      }
//    
//    init(imageName: String, markers: Binding<[CGPoint]>) {
//        self.imageName = imageName
//        self.markersBinding = markers
//        super.init(frame: .zero)
//        setupView()
//    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Capture click, convert coordinates, and update SwiftUI state
    override func mouseDown(with event: NSEvent) {
        
        let clickPoint = self.convert(event.locationInWindow, from: nil)
        
        // Point mode: record single point and hide marquee
        if selectionModeBinding.wrappedValue == .point {
            lastPointBinding.wrappedValue = clickPoint
            marqueeView.isHidden = true
            // Remove any existing marker subviews and draw only the last point
            self.subviews.filter { $0 is MarkerCircle }.forEach { $0.removeFromSuperview() }
            drawMarker(at: clickPoint)
            return
        }
        
        if !marqueeView.isHidden {
            // Convert to marquee's local coordinates for handle hit testing
            let localPointInMarquee = marqueeView.convert(clickPoint, from: self)
            if let handle = marqueeView.handleHitTest(localPointInMarquee) {
                dragMode = .resize(handle)
                lastDragPoint = clickPoint
                return
            } else if marqueeView.frame.contains(clickPoint) {
                // Click inside selection but not on a handle: move
                dragMode = .move
                isDraggingExisting = true
                dragOffset = NSSize(width: clickPoint.x - marqueeView.frame.origin.x,
                                    height: clickPoint.y - marqueeView.frame.origin.y)
                return
            }
        }
        // Start a new selection (marquee mode only)
        if selectionModeBinding.wrappedValue == .marquee {
            // Clear any existing selected point when entering marquee interaction
            lastPointBinding.wrappedValue = nil
            self.subviews.filter { $0 is MarkerCircle }.forEach { $0.removeFromSuperview() }
            dragMode = .resize(.bottomRight)
            isDraggingExisting = false
            startPoint = clickPoint
            lastDragPoint = clickPoint
            marqueeView.frame = NSRect(origin: clickPoint, size: .zero)
            marqueeView.isHidden = false
        }
    }
    
    func updateImage(_ newImage: NSImage) {
         self.image = newImage
        
        print(newImage.size)
        let scaledSize = NSSize(width: newImage.size.width , height: newImage.size.height)
        let newFrame = NSRect(origin: .zero, size: scaledSize)
         
         // Resize both the image view and the container to match the new pixels

         imageView.image = newImage
         imageView.frame = newFrame
         self.frame = newFrame
         
         // Hide the marquee as it's no longer valid for the new image
         marqueeView.isHidden = true
     }
    
    override func mouseDragged(with event: NSEvent) {
        let currentPoint = self.convert(event.locationInWindow, from: nil)
        if selectionModeBinding.wrappedValue == .point {
            return
        }
        let imageBounds = self.bounds // Assuming view matches image size

        switch dragMode {
        case .move:
            // MOVE MODE: Update origin while keeping marquee within image bounds
            var newOrigin = NSPoint(x: currentPoint.x - dragOffset.width,
                                    y: currentPoint.y - dragOffset.height)
            
            // Clamp origin so the entire box stays inside the image
            newOrigin.x = max(0, min(imageBounds.width - marqueeView.frame.width, newOrigin.x))
            newOrigin.y = max(0, min(imageBounds.height - marqueeView.frame.height, newOrigin.y))
            
            marqueeView.setFrameOrigin(newOrigin)
            selectionBinding.wrappedValue = marqueeView.frame
            
        case .resize(let handle):
            // RESIZE MODE: Adjust the rect edges based on handle and drag delta
            var rect = marqueeView.frame
            if let start = startPoint, case .resize(.bottomRight) = dragMode, marqueeView.isHidden == false && marqueeView.frame.size == .zero {
                // Only on the very first drag after mouseDown, anchor at the start point once
                rect = NSRect(origin: start, size: .zero)
            }
            let originalRect = rect
            let deltaX = currentPoint.x - (lastDragPoint?.x ?? currentPoint.x)
            let deltaY = currentPoint.y - (lastDragPoint?.y ?? currentPoint.y)
            
            func clampToBounds(_ r: NSRect) -> NSRect {
                var r = r
                if r.origin.x < 0 {
                    r.size.width += r.origin.x
                    r.origin.x = 0
                }
                if r.origin.y < 0 {
                    r.size.height += r.origin.y
                    r.origin.y = 0
                }
                if r.maxX > imageBounds.width {
                    r.size.width = imageBounds.width - r.origin.x
                }
                if r.maxY > imageBounds.height {
                    r.size.height = imageBounds.height - r.origin.y
                }
                return r
            }
            
            var newOrigin = rect.origin
            var newSize = rect.size
            
            switch handle {
            case .topLeft:
                newOrigin.x += deltaX
                newSize.width -= deltaX
                newSize.height += deltaY
                
                // Adjust origin.y for top edge
                newSize.height = max(1, newSize.height)
                newSize.width = max(1, newSize.width)
                
                if newOrigin.x >= rect.maxX-1 {
                    newOrigin.x = rect.maxX-1
                }

                
            case .top:
                newSize.height += deltaY
//                newSize.height = max(0, newSize.height)
               // newOrigin.y = rect.maxY - newSize.height
                
            case .topRight:
                newSize.width += deltaX
                newSize.height += deltaY
                newSize.width = max(0, newSize.width)
                newSize.height = max(0, newSize.height)
//                newOrigin.y = rect.maxY - newSize.height
                
            case .right:
                newSize.width += deltaX
                newSize.width = max(0, newSize.width)
                
            case .bottomRight:
                newSize.width += deltaX
                newOrigin.y += deltaY
                newSize.height -= deltaY
                newSize.width = max(0, newSize.width)
                newSize.height = max(0, newSize.height)
                if newSize.height == 0 {
                    newOrigin.y = rect.maxY
                }
                
            case .bottom:
                newOrigin.y += deltaY
                newSize.height -= deltaY
                newSize.height = max(0, newSize.height)
                if newSize.height == 0 {
                    newOrigin.y = rect.maxY
                }
                
            case .bottomLeft:
                newOrigin.x += deltaX
                newOrigin.y += deltaY
                newSize.width -= deltaX
                newSize.height -= deltaY
                newSize.width = max(0, newSize.width)
                newSize.height = max(0, newSize.height)
                if newSize.height == 0 {
                    newOrigin.y = rect.maxY
                }
                
            case .left:
                newOrigin.x += deltaX
                newSize.width -= deltaX
                newSize.width = max(0, newSize.width)
            }

            // Build tentative rect from origin/size
            var newRect = NSRect(origin: newOrigin, size: newSize)

            // Normalize rect so width and height are positive without forcing a minimum size
            if newRect.size.width < 0 {
                newRect.origin.x += newRect.size.width
                newRect.size.width = -newRect.size.width
            }
            if newRect.size.height < 0 {
                newRect.origin.y += newRect.size.height
                newRect.size.height = -newRect.size.height
            }

            // Clamp to image bounds without collapsing to a single point
            newRect = clampToBounds(newRect)
            
            marqueeView.frame = newRect
            selectionBinding.wrappedValue = newRect
            
            lastDragPoint = currentPoint
            
        case .none:
            break
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        dragMode = .none
        isDraggingExisting = false
        startPoint = nil
        lastDragPoint = nil
        // Optional: marqueeView.isHidden = true // Hide after selection
    }


    func updateMarkers(_ newMarkers: [CGPoint]) {
        // Remove old visual markers and redraw from the updated list
        self.subviews.filter { $0 is MarkerCircle }.forEach { $0.removeFromSuperview() }
        for point in newMarkers {
            drawMarker(at: point)
        }
    }

    private func drawMarker(at point: NSPoint) {
        let markerSize = 2.0
        let offset = markerSize / 2.0
        let marker = MarkerCircle(frame: NSRect(x: point.x - offset, y: point.y - offset, width: markerSize, height: markerSize))
        self.addSubview(marker)
    }
    
    func clampPoint(_ point: NSPoint, to rect: NSRect) -> NSPoint {
        return NSPoint(
            x: max(rect.minX, min(rect.maxX, point.x)),
            y: max(rect.minY, min(rect.maxY, point.y))
        )
    }
    
    func updateSelectionMode(_ mode: SelectionMode) {
        selectionModeBinding.wrappedValue = mode
        if mode == .point {
            // Hide marquee when switching to point mode
            marqueeView.isHidden = true
        } else {
            // In marquee mode: hide any selected point marker
            lastPointBinding.wrappedValue = nil
            self.subviews.filter { $0 is MarkerCircle }.forEach { $0.removeFromSuperview() }
        }
        needsDisplay = true
    }

    func updateLastPoint(_ point: CGPoint?) {
        lastPointBinding.wrappedValue = point
        // Redraw single marker if provided
        self.subviews.filter { $0 is MarkerCircle }.forEach { $0.removeFromSuperview() }
        if let p = point {
            drawMarker(at: p)
        }
    }
}

// Simple Marker Subview
class MarkerCircle: NSView {
    override func draw(_ dirtyRect: NSRect) {
            NSColor.red.setFill()
            NSBezierPath(ovalIn: bounds).fill()
    }
}

class MarqueeShapeView: NSView {
    enum HandlePosition: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
    var baseHandleSize: CGFloat = 8
    var handlesEnabled: Bool = true
    
    private var magnifyObserver: NSObjectProtocol?
    private var magnifyEndObserver: NSObjectProtocol?
    private var magnificationObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Remove previous observers if any
        if let o = magnifyObserver { NotificationCenter.default.removeObserver(o) }
        if let o = magnifyEndObserver { NotificationCenter.default.removeObserver(o) }
        magnifyObserver = nil
        magnifyEndObserver = nil
        magnificationObservation = nil

        guard let scrollView = self.enclosingScrollView else { return }

        // Redraw at start and end of magnification gesture
        magnifyObserver = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
        magnifyEndObserver = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }

        magnificationObservation = scrollView.observe(\NSScrollView.magnification, options: [.new]) { [weak self] _, _ in
            self?.needsDisplay = true
        }
    }

    deinit {
        if let o = magnifyObserver { NotificationCenter.default.removeObserver(o) }
        if let o = magnifyEndObserver { NotificationCenter.default.removeObserver(o) }
        magnificationObservation = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        NSColor.controlAccentColor.setStroke()
        let mag = self.enclosingScrollView?.magnification ?? 1.0
        path.lineWidth = 2.0 / mag
        path.fill()
        path.stroke()

        guard handlesEnabled else { return }
        let handleSize = baseHandleSize / mag
        for (_, frame) in handleFrames(for: self.bounds, handleSize: handleSize) {
            let handlePath = NSBezierPath(ovalIn: frame)
            NSColor.controlAccentColor.setFill()
            handlePath.fill()
            NSColor.white.setStroke()
            handlePath.lineWidth = 1.0 / mag
            handlePath.stroke()
        }
    }

    func handleFrames(for rect: NSRect, handleSize: CGFloat) -> [HandlePosition: NSRect] {
        let hs = handleSize
        let half = hs / 2
        let xMin = rect.minX, xMid = rect.midX, xMax = rect.maxX
        let yMin = rect.minY, yMid = rect.midY, yMax = rect.maxY
        return [
            .topLeft: NSRect(x: xMin - half, y: yMax - half, width: hs, height: hs),
            .top: NSRect(x: xMid - half, y: yMax - half, width: hs, height: hs),
            .topRight: NSRect(x: xMax - half, y: yMax - half, width: hs, height: hs),
            .right: NSRect(x: xMax - half, y: yMid - half, width: hs, height: hs),
            .bottomRight: NSRect(x: xMax - half, y: yMin - half, width: hs, height: hs),
            .bottom: NSRect(x: xMid - half, y: yMin - half, width: hs, height: hs),
            .bottomLeft: NSRect(x: xMin - half, y: yMin - half, width: hs, height: hs),
            .left: NSRect(x: xMin - half, y: yMid - half, width: hs, height: hs)
        ]
    }
    // Expects `point` in this view's local coordinate space
    func handleHitTest(_ point: NSPoint) -> HandlePosition? {
        let mag = self.enclosingScrollView?.magnification ?? 1.0
        let handleSize = baseHandleSize / mag
        let frames = handleFrames(for: self.bounds, handleSize: handleSize)
        for (pos, frame) in frames {
            if frame.contains(point) { return pos }
        }
        return nil
    }
}

