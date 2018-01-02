//
//  ImageViewer.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/27/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Cocoa

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
        var selectedPattern = (self.convert(event.locationInWindow, from:nil))
        let scaleFactor = (self.image?.size.width)!/frame.width
        
        selectedPattern.x *= scaleFactor
        selectedPattern.y *= scaleFactor
        
        NotificationCenter.default.post(name: Notification.Name("patternChanged"), object: selectedPattern)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
 
        
//        self.layer?.contents = self.image?.layerContents(forContentsScale: 0.5)

    }
    
}
