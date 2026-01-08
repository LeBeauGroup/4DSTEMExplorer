//
//  interactive.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 1/8/26.
//  Copyright © 2026 The LeBeau Group. All rights reserved.
//

import SwiftUI
import AppKit

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
    @Binding var markers: [CGPoint]
    @Binding var marquee: CGRect?
    
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
        
        // Create the internal interactive view
        let interactiveView = InteractiveMarkerView(image: image, markers: $markers, marquee: $marquee)

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
            docView.updateMarkers(markers)
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
    var markersBinding: Binding<[CGPoint]>
    private var startPoint: NSPoint?
    private var marqueeView = MarqueeShapeView()
    private var imageView:NSImageView
    private var selectionBinding: Binding<CGRect?>
    private var isDraggingExisting = false
    private var dragOffset: NSSize = .zero
    
    var image: NSImage?
    
    init(image:NSImage, markers: Binding<[CGPoint]>, marquee: Binding<CGRect?>) {
          self.selectionBinding = marquee
        self.markersBinding = markers
        
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
        
        // 1. Check if we clicked inside the existing marquee
        if !marqueeView.isHidden && marqueeView.frame.contains(clickPoint) {
            isDraggingExisting = true
            // 2. Calculate offset so the box doesn't jump to the mouse point
            dragOffset = NSSize(width: clickPoint.x - marqueeView.frame.origin.x,
                                height: clickPoint.y - marqueeView.frame.origin.y)
        } else {
            // 3. Start a new selection
            isDraggingExisting = false
            startPoint = clickPoint
            marqueeView.frame = NSRect(origin: clickPoint, size: .zero)
            marqueeView.isHidden = false
        }
        
//        startPoint = self.convert(event.locationInWindow, from: nil)
//        marqueeView.frame = .zero
//        marqueeView.isHidden = false
//        
//        var point = self.convert(event.locationInWindow, from: nil)
        
//        point.x += 5.0
//        point.y += 5.0
        
//        print(point)
//        
//        markersBinding.wrappedValue.append(point)
//
//        drawMarker(at: point)
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
               let imageBounds = self.bounds // Assuming view matches image size

               if isDraggingExisting {
                   // MOVE MODE: Update origin while keeping marquee within image bounds
                   var newOrigin = NSPoint(x: currentPoint.x - dragOffset.width,
                                           y: currentPoint.y - dragOffset.height)
                   
                   // Clamp origin so the entire box stays inside the image
                   newOrigin.x = max(0, min(imageBounds.width - marqueeView.frame.width, newOrigin.x))
                   newOrigin.y = max(0, min(imageBounds.height - marqueeView.frame.height, newOrigin.y))
                   
                   marqueeView.setFrameOrigin(newOrigin)
               } else {
                   // DRAW MODE: Update size using clamping logic from previous step
                   guard let start = startPoint else { return }
                   let clampedCurrent = clampPoint(currentPoint, to: imageBounds)
                   
                   let newRect = NSRect(
                       x: min(start.x, clampedCurrent.x),
                       y: min(start.y, clampedCurrent.y),
                       width: abs(clampedCurrent.x - start.x),
                       height: abs(clampedCurrent.y - start.y)
                   )
                   marqueeView.frame = newRect
               }
               
               // Update SwiftUI state during drag for live feedback
               selectionBinding.wrappedValue = marqueeView.frame
        
    }
    
    override func mouseUp(with event: NSEvent) {
        isDraggingExisting = false
        startPoint = nil
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
        if let mag = self.enclosingScrollView?.magnification{
            let markerSize = 2.0
            let offset = markerSize/(2.0)
            let marker = MarkerCircle(frame: NSRect(x: point.x-offset, y: point.y-offset, width: markerSize, height: markerSize))
            
            self.addSubview(marker)
        }
    
        
    
    }
    
    func clampPoint(_ point: NSPoint, to rect: NSRect) -> NSPoint {
        return NSPoint(
            x: max(rect.minX, min(rect.maxX, point.x)),
            y: max(rect.minY, min(rect.maxY, point.y))
        )
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
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        NSColor.controlAccentColor.setStroke()
        if let mag = self.enclosingScrollView?.magnification{
            path.lineWidth = 2.0/mag
        } else {
            path.lineWidth = 1.0
        }
        path.fill()
        path.stroke()
    }
}

