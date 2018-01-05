//
//  ImageViewer.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/27/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Cocoa
import CoreGraphics

protocol ImageViewerDelegate: class {
    func averagePatternInRect(_ rect:NSRect?)

}

class ImageViewer: NSImageView {

    override var isFlipped:Bool {
        return true
        
    }
    
    weak var delegate:ImageViewerDelegate?
    
    var matrixStorage:Matrix?
    
    var maxDisplay:Float?
    var minDisplay:Float?
    var selectionRect:NSRect?
    
    let selectionFillColor:NSColor = NSColor.red.withAlphaComponent(0.25)
    
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
        
        selectionRect = NSRect(origin: selectedPattern, size: CGSize(width: 0, height: 0))

        
        let scaleFactor = (self.image?.size.width)!/frame.width
        
        selectedPattern.x *= scaleFactor
        selectedPattern.y *= scaleFactor
    
        
    NotificationCenter.default.post(name: Notification.Name("patternChanged"), object: selectedPattern)

        
    }
    
    override func mouseDragged(with event: NSEvent) {
       
        let testPoint = (self.convert(event.locationInWindow, from:nil))
        
        let scaleFactor = (self.image?.size.width)!/frame.width

        if self.visibleRect.contains(testPoint)
        {
            
            var selectedPattern = testPoint
            
            if selectionRect != nil{
                
                var newSize = selectionRect?.size
                
                newSize?.width = testPoint.x-(selectionRect?.origin.x)!
                newSize?.height = testPoint.y-(selectionRect?.origin.y)!
                
                selectionRect!.size = newSize!
                
                var scaledRect = selectionRect
                scaledRect?.origin.x *= scaleFactor
                scaledRect?.origin.y *= scaleFactor
                scaledRect?.size.width *= scaleFactor
                scaledRect?.size.height *= scaleFactor
                
                delegate?.averagePatternInRect(scaledRect)

            }
            


            
        
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
            
        
        self.needsDisplay = true

            if selectionRect == nil{
        NotificationCenter.default.post(name: Notification.Name("patternChanged"), object: selectedPattern)
            }
        }
        
    }
    override func mouseUp(with event: NSEvent) {
    
        let testPoint = (self.convert(event.locationInWindow, from:nil))
        
        if selectionRect != nil{
            if testPoint == selectionRect?.origin{
                selectionRect = nil
            }

        }
        
        self.needsDisplay = true

    }
    
    override func draw(_ dirtyRect: NSRect) {
        
        NSColor.darkGray.set()
        NSBezierPath(rect: dirtyRect).fill()
        
        super.draw(dirtyRect)

        
        if selectionRect != nil{
            selectionFillColor.set()
            let pathSelectionRect = NSBezierPath(rect: selectionRect!)
            
            pathSelectionRect.fill()
            NSColor.red.set()
            pathSelectionRect.stroke()
            
        }
        
        
 
        
//        self.layer?.contents = self.image?.layerContents(forContentsScale: 0.5)

    }
    
}
