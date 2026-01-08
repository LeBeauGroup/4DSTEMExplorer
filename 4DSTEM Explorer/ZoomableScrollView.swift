//
//  Untitled.swift
//  4DSTEM Explorer
//
//  Created by lebeau on 1/4/26.
//  Copyright © 2026 The LeBeau Group. All rights reserved.
//

import SwiftUI
import AppKit

private extension Notification.Name {
//    static let zoomIn = Notification.Name("ZoomableScrollView.ZoomIn")
//    static let zoomOut = Notification.Name("ZoomableScrollView.ZoomOut")
    static let setZoom = Notification.Name("ZoomableScrollView.SetZoom") // userInfo["magnification"] as CGFloat
    static let magnificationDidChange = Notification.Name("ZoomableScrollView.MagnificationDidChange") // userInfo["magnification"] as CGFloat
}

struct ZoomableScrollView<Content: View>: NSViewRepresentable {
    private var content: Content
    
    class ZoomCoordinator {
        weak var scrollView: NSScrollView?
        var observers: [Any] = []

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        func attach(to scrollView: NSScrollView) {
            self.scrollView = scrollView
            let nc = NotificationCenter.default
            let zoomStep: CGFloat = 0.2

            // Observe bounds changes to keep content centered on resize/zoom
            scrollView.contentView.postsBoundsChangedNotifications = true
            let boundsObs = nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
                self?.centerDocumentView()
            }
            observers.append(boundsObs)

            let zoomInObs = nc.addObserver(forName: .zoomIn, object: nil, queue: .main) { [weak self] _ in
                guard let sv = self?.scrollView else { return }
                let newMag = min(sv.maxMagnification, sv.magnification * (1.0 + zoomStep))
                if newMag != sv.magnification { sv.magnification = newMag; self?.postMagnificationDidChange(newMag) }
            }
            let zoomOutObs = nc.addObserver(forName: .zoomOut, object: nil, queue: .main) { [weak self] _ in
                guard let sv = self?.scrollView else { return }
                let newMag = max(sv.minMagnification, sv.magnification * (1.0 - zoomStep))
                if newMag != sv.magnification { sv.magnification = newMag; self?.postMagnificationDidChange(newMag) }
            }
            let setZoomObs = nc.addObserver(forName: .setZoom, object: nil, queue: .main) { [weak self] note in
                guard let sv = self?.scrollView else { return }
                if let value = (note.userInfo?["magnification"] as? NSNumber)?.doubleValue {
                    let target = CGFloat(value)
                    let clamped = min(max(target, sv.minMagnification), sv.maxMagnification)
                    if clamped != sv.magnification { sv.magnification = clamped; self?.postMagnificationDidChange(clamped) }
                }
            }
            observers.append(contentsOf: [zoomInObs, zoomOutObs, setZoomObs])

            // Track live magnification changes triggered by gestures
            let willObs = nc.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification, object: scrollView, queue: .main) { _ in }
            let didObs = nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
                if let mag = self?.scrollView?.magnification { self?.postMagnificationDidChange(mag) }
            }
            observers.append(contentsOf: [willObs, didObs])

            self.centerDocumentView()
        }

        private func postMagnificationDidChange(_ value: CGFloat) {
            NotificationCenter.default.post(name: .magnificationDidChange, object: scrollView, userInfo: ["magnification": value])
        }

        func centerDocumentView() {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let contentSize = sv.contentView.bounds.size
            var frame = doc.frame
            // Calculate origin so that content is centered when smaller than viewport
            let x = max(0, (contentSize.width - frame.size.width) / 2)
            let y = max(0, (contentSize.height - frame.size.height) / 2)
            frame.origin = NSPoint(x: x, y: y)
            doc.setFrameOrigin(frame.origin)
        }
    }

    typealias Coordinator = ZoomCoordinator

    func makeCoordinator() -> Coordinator { Coordinator() }
    
    // Initialize the ZoomableScrollView with your SwiftUI content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        // 1. Set up the NSScrollView
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true // Enable zooming
        scrollView.minMagnification = 1.0
        scrollView.maxMagnification = 5.0 // Set max zoom level
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        
        // 2. Wrap the SwiftUI content in an NSHostingView
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        
        // 3. Set the hosting view as the document view of the scroll view
        scrollView.documentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)

        // Attach the coordinator to manage zoom notifications
        context.coordinator.attach(to: scrollView)
        // Center initially
        context.coordinator.centerDocumentView()

        // 4. Set initial magnification
        scrollView.magnification = 1.0
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Update the hosting view when the SwiftUI content changes
        if let hostingView = nsView.documentView as? NSHostingView<Content> {
            hostingView.rootView = content
            // Update the frame of the document view to match the content size for proper scrolling
            hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
            context.coordinator.centerDocumentView()
        }
    }
}

