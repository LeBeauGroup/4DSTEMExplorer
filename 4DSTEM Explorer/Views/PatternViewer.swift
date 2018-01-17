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
