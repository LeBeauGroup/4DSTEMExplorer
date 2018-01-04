//
//  ImageViewer.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/27/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Cocoa
import CoreGraphics

class ImageViewer: NSImageView {

    override var isFlipped:Bool {
        return true
        
    }
    
    var matrixStorage:Matrix?
    
    var maxDisplay:Float?
    var minDisplay:Float?
    
    var matrix:Matrix{
        get{
            return matrixStorage!
        }
        set(newMatrix){
            self.image = newMatrix.imageRepresentation(part: "real", format: MatrixOutput.uint16, nil, nil)
            matrixStorage = newMatrix
        }
        
    }    
    
    override func mouseDown(with event: NSEvent) {
        
        var selectedPattern = (self.convert(event.locationInWindow, from:nil))
        let scaleFactor = (self.image?.size.width)!/frame.width
        
        selectedPattern.x *= scaleFactor
        selectedPattern.y *= scaleFactor
    
        
    NotificationCenter.default.post(name: Notification.Name("patternChanged"), object: selectedPattern)

        
    }
    
    override func mouseDragged(with event: NSEvent) {
       
        let testPoint = (self.convert(event.locationInWindow, from:nil))
        
        
        if self.visibleRect.contains(testPoint)
        {
            var selectedPattern = testPoint
            let scaleFactor = (self.image?.size.width)!/frame.width
        
        // Check on the x position
        selectedPattern.x *= scaleFactor
        if selectedPattern.x < 0 {
            selectedPattern.x = 0
        }else if  selectedPattern.x > (self.image?.size.width)!-1 {
            selectedPattern.x = (self.image?.size.width)! - 1
        }
        // Check on the y position

        selectedPattern.y *= scaleFactor
        
        if selectedPattern.y < 0 {
            selectedPattern.y = 0
        }else if selectedPattern.y > (self.image?.size.height)!-1 {
            selectedPattern.y = (self.image?.size.height)! - 1
        }
        
        
        print(selectedPattern)
        
        NotificationCenter.default.post(name: Notification.Name("patternChanged"), object: selectedPattern)
        }
        
    }
    
    override func draw(_ dirtyRect: NSRect) {
        
        NSColor.darkGray.set()
        NSBezierPath(rect: dirtyRect).fill()
        
        
        super.draw(dirtyRect)
        
 
        
//        self.layer?.contents = self.image?.layerContents(forContentsScale: 0.5)

    }
    
}
