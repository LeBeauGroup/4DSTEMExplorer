//
//  PatternView.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/27/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Cocoa

class PatternViewer: NSImageView {
    
    override var isFlipped:Bool {
        return true
        
    }

    var backgroundColor:NSColor
    let detectorView:DetectorView?
    
    var trackingArea : NSTrackingArea?
    
    @IBOutlet weak var patternValue : NSTextField?
    
    override func updateTrackingAreas() {
        if trackingArea != nil {
            self.removeTrackingArea(trackingArea!)
        }
        trackingArea = NSTrackingArea(rect: self.bounds, options: [.mouseMoved, .mouseEnteredAndExited, .enabledDuringMouseDrag, .activeInKeyWindow], owner: self, userInfo: nil)
        self.addTrackingArea(trackingArea!)
    }

    func getImageCoordinate(_ image: NSImage?, _ loc: NSPoint) -> (Int, Int)? {
        image.flatMap{$0.representations.first.map{ imageRep in
            var loc = self.convert(loc, from: nil)
            loc.x = loc.x * CGFloat(imageRep.pixelsWide) / self.bounds.width - 0.5
            loc.y = loc.y * CGFloat(imageRep.pixelsHigh) / self.bounds.height - 0.5
            let x = max(0, min(imageRep.pixelsWide-1, Int(loc.x.rounded())))
            let y = max(0, min(imageRep.pixelsHigh-1, Int(loc.y.rounded())))
            return (x, y)
        }}
    }

    override func mouseMoved(with event: NSEvent) {
        if let (x, y) = getImageCoordinate(self.image, event.locationInWindow) {
            //patternValue?.textColor = NSColor.white
            if let val = self.matrixStorage?.get(y, x) {
                patternValue?.stringValue = "(\(x), \(y)): \(val)"
            } else {
                patternValue?.stringValue = "(\(x), \(y))"
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        patternValue?.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        patternValue?.isHidden = true
    }

    override init(frame frameRect: NSRect) {
        
        backgroundColor = NSColor.lightGray
        detectorView = DetectorView.init()

//        detectorView.isHidden = true
        super.init(frame: frameRect)

        
        self.addSubview(detectorView!)
        

    }
    
    private var matrixStorage:Matrix?
    
    var matrix:Matrix{
        get{
            return matrixStorage!
        }
        set(newMatrix){
            let imageRep:NSBitmapImageRep? = newMatrix.uInt8ImageRep()
            let newImage = NSImage()
            
            if imageRep != nil{
                newImage.addRepresentation(imageRep!)
                self.image = newImage//newMatrix.imageRepresentation(part: "real", format: n, nil, nil)
                matrixStorage = newMatrix
            }
        }
    }
    
    required init?(coder: NSCoder) {
//        fatalError("init(coder:) has not been implemented")
        backgroundColor = NSColor.lightGray
        
//      detectorView.isHidden = true
        
        detectorView = DetectorView.init()

        
        super.init(coder: coder)
        detectorView?.isHidden = true

        self.addSubview(detectorView!)

        let zeros = Matrix.init(128, 128)
        
        let imageRep = zeros.imageRepresentation(part: "real", format: MatrixOutput.uint8, nil,nil)
        
        self.image = imageRep
        
        detectorView!.detector = Detector(shape: DetectorShape.bf, type: DetectorType.integrating, center: NSPoint(x:0,y:0), radii: DetectorRadii(inner: 0, outer: 10),size:NSSize(width: 128, height: 128))
        
        
//       detectorView!.frame = NSRect(origin: CGPoint(x:0, y:0 ) , size: NSSize(width: 80, height: 80))
//        print(self.frame)
        

    
    }
    
//    override func mouseDown(with event: NSEvent) {
////        self.background = NSColor.blue
//
//        self.needsDisplay = true
//    }
//
//    override func mouseDragged(with event: NSEvent) {
//
//
//        let newDragLocation = self.convert(event.locationInWindow, from: nil)
//
//        if(newDragLocation.x >= frame.origin.x && newDragLocation.x <= frame.origin.x+frame.width){
//
//        }
//        //        self.needsDisplay = true
//        //        }
//
//    }
    
    override func draw(_ dirtyRect: NSRect) {
        
        super.draw(dirtyRect)
        
        self.backgroundColor.set()
//        dirtyRect.fill()
        
        

        let outlinePath = NSBezierPath.init(rect: dirtyRect)
        outlinePath.lineWidth = 2.0
        NSColor.black.set()
        outlinePath.stroke()
        
        if (self.isHighlighted) {
            self.drawFocusRingMask();
        }
        

    }
}
