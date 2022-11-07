/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information
    
    Abstract:
    Contains the definition for `CenteringClipView` which is a specialized clip view subclass to center its document.
*/

import Cocoa

struct Zoom {
    static let factor: CGFloat  = 1.414214
    
    static let minSize: NSSize = NSSize(width: 400, height: 400)
}

extension Notification.Name {
    public static let RescaleEvent = Notification.Name("RescaleEvent")
}

class CenteringClipView: NSClipView
{
    var autoscale: Bool = true
    
    @IBAction func updateAutoscale(_ sender: Any? = nil) {
        self.autoscale = !self.isScrolling()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)

        // disable autoscaling upon manual scaling
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.updateAutoscale(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: self.enclosingScrollView
        )
    }

    // autoscaling
    override func layout() {
        if self.autoscale {
            self.zoomToFit(shrink: false)
        }

        super.layout()
    }

    // zoom in, growing the window if there's space on the screen
    func zoomIn(by: CGFloat? = nil, grow: Bool = true) {
        let by = by ?? Zoom.factor
        let scrollView = self.enclosingScrollView!

        // store old image size (in window coords) if possible
        let oldSize = self.documentView.flatMap({ docView in
            self.window?.contentView?.convert(docView.visibleRect, from: self)
        })
        scrollView.magnification *= by

        self.autoscale = false // assume we're scrolling post-magnification
        guard grow else { return }

        // to attempt to grow, we need a window and screen
        guard let window = self.window else { return }
        guard let screen = window.screen else { return }
        guard let oldSize = oldSize else { return }

        // available space below window
        let avail = NSSize(
            width: screen.visibleFrame.maxX - window.frame.maxX,
            height: window.frame.minY - screen.visibleFrame.minY
        )
        // space needed for resizing (keeping scrolling fixed, in window coords)
        var needed = NSSize(
            width: oldSize.width * (by - 1),
            height: oldSize.height * (by - 1)
        )
        // subtract unused space in clip view
        needed.width -= max(0, self.frame.width - oldSize.width)
        needed.height -= max(0, self.frame.height - oldSize.height)

        if avail.width > needed.width && avail.height > needed.height {
            window.setContentSize(NSSize(
                width: window.frame.width + max(0, needed.width),
                height: window.frame.height + max(0, needed.height)
            ))
            autoscale = !self.isScrolling()
        } else {
            // not enough room, so we're definitely scrolling
            autoscale = false
        }
    }

    // zoom out, shrinking if there's space to reclaim
    func zoomOut(by: CGFloat? = nil, shrink: Bool = true) {
        let by = by ?? Zoom.factor
        self.enclosingScrollView!.magnification /= by

        guard shrink else { autoscale = !self.isScrolling(); return }

        shrinkToImage()
    }

    func isScrolling() -> Bool {
        let contentFrame = self.documentView!.bounds
        return (
            contentFrame.width > self.bounds.width + 1 ||
            contentFrame.height > self.bounds.height + 1
        )
    }

    func zoomToFit(rect: NSRect? = nil, shrink: Bool = false) {
        self.autoscale = true
        self.enclosingScrollView!.magnify(toFit: rect ?? self.documentView!.frame)
        
        if shrink {
            self.shrinkToImage();
            self.shrinkToImage(); // ugly hack
        }
    }

    // center image in self
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let contentView = self.documentView {
            if (rect.width > contentView.frame.width) {
                rect.origin.x += (contentView.frame.width - rect.width) / 2
            }

            if (rect.height > contentView.frame.height) {
                rect.origin.y += (contentView.frame.height - rect.height) / 2
            }
        }

        return rect
    }

    // shrink the enclosing window to neatly fit the image
    func shrinkToImage() {
        guard let windowView = window?.contentView else { return }
        let windowFrame = windowView.frame
        
        guard let contentView = self.documentView else { return }
        let contentFrame = contentView.bounds

        // convert minimum size to content (post-zoom) coordinates
        let minSize = windowView.convert(Zoom.minSize, to: self)

        // get excess space in content coordinates, and convert to window coords
        let shrink = windowView.convert(NSSize(
            width: max(0, self.bounds.width - max(minSize.width, contentFrame.width)),
            height: max(0, self.bounds.height - max(minSize.height, contentFrame.height))
        ), from: self)

        var oldHoldingPriority: NSLayoutConstraint.Priority? = nil
        let splitView = self.enclosingScrollView?.superview as? NSSplitView
        if let splitView = splitView, shrink.width > 0 {
            oldHoldingPriority = splitView.holdingPriorityForSubview(at: 1)
            splitView.setHoldingPriority(NSLayoutConstraint.Priority(50.0), forSubviewAt: 1)
        }
        //(splitView.subviews[1] as! NSSplitViewItem).holdingPriority = NSLayoutConstraint.Priority(50.0)

        // and update window size
        window!.setContentSize(NSSize(width: windowFrame.width - shrink.width, height: windowFrame.height - shrink.height))
        windowView.needsLayout = true
        windowView.layoutSubtreeIfNeeded()
        autoscale = !self.isScrolling()

        if let priority = oldHoldingPriority, let splitView = splitView {
            splitView.setHoldingPriority(priority, forSubviewAt: 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // notify scale bar when we draw
        NotificationCenter.default.post(Notification(name: .RescaleEvent, object: self))

        super.draw(dirtyRect)
    }
}
