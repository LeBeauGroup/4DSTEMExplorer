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
    func selectPatternAt(_ i:Int, _ j:Int)

}

enum SelectMode {
    case point
    case none
    case marquee
}

class ImageViewer: NSImageView {

    override var isFlipped:Bool {
        return true
        
    }
    
    weak var delegate:ImageViewerDelegate?
    
    var matrixStorage:Matrix?
    var selectMode:SelectMode = .marquee
    var scaledRect:NSRect?{
        get{
            var scaledRect = selectionRect
            let scaling = scaleFactor()
            scaledRect?.origin.x *= scaling
            scaledRect?.origin.y *= scaling
            scaledRect?.size.width *= scaling
            scaledRect?.size.height *= scaling
            
            return scaledRect
        }
    }
    var maxDisplay:Float?
    var minDisplay:Float?
    var selectionRect:NSRect?
    var lastDragLocation:NSPoint?
    var isSelectionMoving:Bool = false

    let selectionFillColor:NSColor = NSColor.red.withAlphaComponent(0.25)
    
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
    
    func isPointInSelectionRect(_ point:NSPoint)->Bool{
        
        var itemHit = false
        
        // rough test
        
        if selectionRect != nil{
            
            var hitRect = selectionRect!
            let hitSize = selectionRect!.size
            
            if hitSize.width < CGFloat(0.0) {
                hitRect.origin.x += hitSize.width
                hitRect.size.width *= CGFloat(-1.0)
            }
            
            if hitSize.height < CGFloat(0.0){
                hitRect.origin.y += hitSize.height
                hitRect.size.height *= CGFloat(-1.0)
            }
            
            itemHit = NSPointInRect(point, hitRect)
        }
        
        return itemHit
            
        }
    
    override func mouseDown(with event: NSEvent) {
        
        
        let testPoint = (self.convert(event.locationInWindow, from:nil))
        
        switch selectMode{
        case .marquee:
            
            if !isPointInSelectionRect(testPoint){
                selectionRect = NSRect(origin: testPoint, size: CGSize(width: 0, height: 0))
                lastDragLocation = testPoint
                isSelectionMoving = false


            } else if isPointInSelectionRect(testPoint){
                lastDragLocation = testPoint
                isSelectionMoving = true
            
            }
            
//            if scaledRect!.width <= 1 && scaledRect!.height <= 1{
//                
//                selectionRect?.size.width += CGFloat(1)
//                selectionRect?.size.height += CGFloat(1)
//
//            }
            
            
            delegate?.averagePatternInRect(scaledRect)
//                delegate?.average(Int(), Int())

        case .point:
            var selectedPattern:NSPoint? = testPoint
            
            selectionRect = NSRect(origin: testPoint, size: CGSize(width: 1, height: 1.0))

            let scaleFactor = (self.image?.size.width)!/frame.width
            
            selectedPattern?.x *= scaleFactor
            selectedPattern?.y *= scaleFactor
            
            
            let i = Int((selectedPattern?.y)!)
            let j = Int((selectedPattern?.x)!)
            
            delegate?.selectPatternAt(i, j)
            
        default:
            selectionRect = NSRect(origin: lastDragLocation!, size: CGSize(width: 0, height: 0))

        }
        
        
        
        self.needsDisplay = true
        
        
    }
    
    override func mouseDragged(with event: NSEvent) {
       
        let testPoint = (self.convert(event.locationInWindow, from:nil))
        
        let scaleFactor = (self.image?.size.width)!/frame.width

        if self.visibleRect.contains(testPoint)
        {
            
            
            switch selectMode{
            case .marquee:
                
                var newRect = selectionRect!
                var newSize = selectionRect?.size
                
                if isSelectionMoving{
                
                    newRect.origin.x += testPoint.x-(lastDragLocation?.x)!
                    newRect.origin.y += testPoint.y-(lastDragLocation?.y)!
                    
//                    selectionRect?.origin = newRect

                }else{
                    newRect.size.width = testPoint.x-(selectionRect?.origin.x)!
                    newRect.size.height = testPoint.y-(selectionRect?.origin.y)!
                    
                    
                }
                
                if visibleRect.contains(newRect){
                    
                    selectionRect = newRect
                    lastDragLocation = testPoint

                }
            
                
//                if scaledRect!.width <= 1 && scaledRect!.height <= 1{
//                    delegate?.selectPatternAt(Int(scaledRect!.origin.y), Int(scaledRect!.origin.x))
//                }else{
                delegate?.averagePatternInRect(scaledRect)
//                }
                
            case .point:
                
                var newOrigin = (selectionRect?.origin)!
                
                
                
                newOrigin.x += testPoint.x-(selectionRect?.origin.x)!
                newOrigin.y += testPoint.y-(selectionRect?.origin.y)!

                
                selectionRect?.origin = newOrigin

                var selectedPattern = newOrigin

                
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
                
                let i = Int(selectedPattern.y)
                let j = Int(selectedPattern.x)
                
//                delegate?.selectPatternAt(i, j)
                
                
                
            default:
                return
            }
            

                
       
        
        self.needsDisplay = true

//            if selectionRect == nil{
            

//            }
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

        let context = NSGraphicsContext.current?.cgContext

        NSColor.darkGray.set()
        NSBezierPath(rect: dirtyRect).fill()
        
        super.draw(dirtyRect)

        switch selectMode {
        case .marquee:
            
            if selectionRect != nil{
                
                selectionFillColor.set()
                let pathSelectionRect = NSBezierPath(rect: selectionRect!)
            
                pathSelectionRect.fill()
                NSColor.red.set()
                pathSelectionRect.lineWidth = 0.5
                pathSelectionRect.stroke()
                
            }
        case .point:
            drawPointSelection(point: selectionRect?.origin, context: context!)
        case .none:
            break
        default:
            break
        }
        
 
    
    }
    
    func scaleFactor()->CGFloat{
        
//        let imageView = (self.superview as! NSImageView)
        let imageViewSize = self.frame.size
        
        let scaleFactor:CGFloat
        
        if let imageSize = self.image?.size{
            scaleFactor   = (imageSize.width)/imageViewSize.width
        }else{
            scaleFactor = 1.0
        }
        
        return scaleFactor
        
    }
    
    func drawPointSelection(point:NSPoint?, context:CGContext){
        
        let strokeWidth = 1.0
        let longOffset = CGFloat(2.0)
        let shortOffset = longOffset * 0.25

        let redColor = NSColor.red
        
        if point != nil{
            var crossCenter:NSPoint = point!
            
            crossCenter.x -= CGFloat(strokeWidth/2.0)
            crossCenter.y -= CGFloat(strokeWidth/2.0)
            
            for i in [(-1.0,0.0), (1.0,0.0), (0.0,-1.0), (0.0,1.0)]{
            
                
                let outerPoint = CGPoint.init(x: crossCenter.x+CGFloat(i.0)*longOffset, y: crossCenter.y+CGFloat(i.1)*longOffset)
                let innerPoint = CGPoint.init(x: crossCenter.x+CGFloat(i.0)*shortOffset, y: crossCenter.y+CGFloat(i.1)*shortOffset)
                
                let line = [outerPoint, innerPoint]
                
                context.setLineWidth(CGFloat(strokeWidth))
                context.setStrokeColor(redColor.cgColor)
                context.addLines(between: line)
                context.drawPath(using: .stroke)

            }
            

            
        }
        
            
            
        
    }
    
}
