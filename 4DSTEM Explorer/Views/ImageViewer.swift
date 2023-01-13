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

    required init?(coder: NSCoder) {
        super.init(coder: coder)

        self.imageScaling = .scaleNone
    }

    override var isFlipped:Bool {
        return true
        
    }
//    lazy var popover: NSPopover! = {
//        let popover = NSPopover()
////        popover.appearance = NSAppearance.
//        popover.animates = true
//        popover.behavior = .transient
//        return popover
//    }()
    weak var delegate:ImageViewerDelegate?

    var selectMode:SelectMode = .point
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
    var matrix: Matrix?
    var maxDisplay:Float?
    var minDisplay:Float?
    var selectionRect:NSRect?
    private var lastDragLocation:NSPoint?
    private var isSelectionMoving:Bool = false
    private var isSelectionNew:Bool = true
    var selectionIsHidden:Bool = false

    let selectionFillColor:NSColor = NSColor.red.withAlphaComponent(0.25)
    
    /*
    var matrix:Matrix{
        get{
            return matrixStorage!
        }
        set(newMatrix){
            
            let imageRep:NSBitmapImageRep? = newMatrix.uInt8ImageRep()
            let newImage = NSImage()
            
            selectionRect = nil
            
            if imageRep != nil{
                newImage.addRepresentation(imageRep!)
                self.image = newImage
                matrixStorage = newMatrix
            }
        }
    }
    */
    
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
        
        self.window?.makeFirstResponder(self)
        
        if selectionIsHidden {
            return
        }
        
        let testPoint = (self.convert(event.locationInWindow, from:nil))
        
        if selectionRect == nil {
            isSelectionNew = true
//            selectMode = .point
            selectionRect = NSRect(origin: testPoint, size: CGSize(width: 0, height: 0))
        }
        
        switch selectMode{
        case .point:
            
            // setup a test area for point (do not want to have a 1 pixel sensitivity )
            var pointRect = selectionRect!
            pointRect.origin.x -= 2
            pointRect.origin.y -= 2
            
            pointRect.size.width = 4
            pointRect.size.height = 4
            
            // check if test point is hit
            if !pointRect.contains(testPoint){
                isSelectionNew = true
//                selectMode = .point
                selectionRect = NSRect(origin: testPoint, size: CGSize(width: 0, height: 0))

            }
            
            delegate?.averagePatternInRect(scaledRect)
        case .marquee:
            
            var pointRect = selectionRect!
            pointRect.origin.x -= 2
            pointRect.origin.y -= 2
            
            pointRect.size.width = 4
            pointRect.size.height = 4
            
            if !isPointInSelectionRect(testPoint){
                isSelectionNew = true
                isSelectionMoving = false
                selectionRect = nil
                //                selectMode = .point
                selectionRect = NSRect(origin: testPoint, size: CGSize(width: 1, height: 1))
                
            }else{
                lastDragLocation = testPoint
                isSelectionMoving = true
            }

            
            delegate?.averagePatternInRect(scaledRect)
        case .none:
            return
//        default:
//            if !isPointInSelectionRect(testPoint){
//
//                isSelectionNew = true
//                selectionRect = nil
////                selectMode = .point
//
//                selectionRect = NSRect(origin: testPoint, size: CGSize(width: 0, height: 0))
//
//
//                lastDragLocation = testPoint
//                isSelectionMoving = false
//
//            }else {
//                lastDragLocation = testPoint
//                isSelectionMoving = true
//
//            }
//
//            delegate?.averagePatternInRect(scaledRect)

            
        }
        
        
        
        self.needsDisplay = true
        
        
    }
    
    
    
    func moveOriginInBounds(_ point:NSPoint){
        // checks to see if the point is in bounds, if not bring it back (testing for origin of selectrion rect
        
        var origin = point
        
        guard let imageSize = self.image?.size else { return }
        guard var selRect = self.selectionRect else { return }
        
        if origin.x < 0 {
            origin.x = 0
        } else if origin.x + selRect.width > imageSize.width - 1 {
            origin.x = imageSize.width - 1 - selRect.width
            if selectMode == .marquee{
                origin.x += 1
            }
        }
        
        if origin.y < 0 {
            origin.y = 0
        } else if origin.y + selRect.height > imageSize.height - 1 {
            origin.y = imageSize.height - 1 - selRect.height
            if selectMode == .marquee{
                origin.y += 1
            }
        }

        selRect.origin.x = origin.x
        selRect.origin.y = origin.y
        self.selectionRect = selRect
    }
    
    
    override func keyDown(with event: NSEvent) {
        
        let ch = event.charactersIgnoringModifiers! as NSString
        var rate:CGFloat = 1.0
        
        if selectMode == .none{
            return
        }
        
        if selectionRect == nil{
            return
        }
        
        if ch.length == 1{
            let keyChar: Int = Int(ch.character(at: 0))
            
            if event.modifierFlags.contains(.shift){
                rate = 5.0
            }
            
        
            
            var origin:NSPoint = (selectionRect?.origin)!


            switch keyChar {
            case NSUpArrowFunctionKey:
                origin.y -= rate
            case NSDownArrowFunctionKey:
               origin.y += rate
            case NSLeftArrowFunctionKey:
                origin.x -= rate
            case NSRightArrowFunctionKey:
                origin.x += rate
            default:
                super.keyDown(with: event)
                
            }
            
            moveOriginInBounds(origin)
            
            
            delegate?.averagePatternInRect(scaledRect)
            self.needsDisplay = true
            
            
        }
        
        
    }
    
    override func mouseDragged(with event: NSEvent) {
       
        if selectionIsHidden {
            return
        }
        
        let testPoint = (self.convert(event.locationInWindow, from:nil))
        let scaleFactor = (self.image?.size.width)!/frame.width

    
        if true
        {
            
//            if testPoint.distanceTo(selectionRect!.origin) > 2 && isSelectionNew{
//                selectMode = .marquee
//            }
            
            switch selectMode{
            case .marquee:
                
                var newRect = selectionRect!
                
                if isSelectionMoving{
                
                    var newOrigin = (selectionRect?.origin)!
                    
                    newOrigin.x += testPoint.x-(lastDragLocation?.x)!
                    newOrigin.y += testPoint.y-(lastDragLocation?.y)!
                    
                    moveOriginInBounds(newOrigin)
                    
                }else{
                    newRect.size.width = testPoint.x-(selectionRect?.origin.x)!
                    newRect.size.height = testPoint.y-(selectionRect?.origin.y)!
                    selectionRect = newRect

                    
                }
                
                
                lastDragLocation = testPoint

                delegate?.averagePatternInRect(scaledRect)
                
            case .point:
                
                var newOrigin = (selectionRect?.origin)!
                
                newOrigin.x += testPoint.x-(selectionRect?.origin.x)!
                newOrigin.y += testPoint.y-(selectionRect?.origin.y)!

                moveOriginInBounds(newOrigin)

                var selectedPattern = (selectionRect?.origin)!
                
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
                
                
                delegate?.averagePatternInRect(scaledRect)

                
//                delegate?.selectPatternAt(i, j)
                
                
                
            default:
                return
            }
            

                
       
        
        self.needsDisplay = true

//            if selectionRect == nil{
            

//            }
        }
        
    }
    

//    override func rightMouseDown(with event: NSEvent) {
//
//        let story =  NSStoryboard(name: NSStoryboard.Name(rawValue: "Main"), bundle: nil)
//
//        let homeViewController:NSViewController = story.instantiateController(withIdentifier: NSStoryboard.SceneIdentifier(rawValue: "ImageRightClickController")) as! NSViewController
//
//        let popover = NSPopover.init()
//
//        popover.contentViewController = homeViewController
//
//
//        popover.show(relativeTo: self.bounds, of: self, preferredEdge: .minX)
//
//
//        //        let pop = NSPopover.init()
////        var menu = NSMenu.init()
////
////        let item = NSMenuItem
////        menu.insertItem(withTitle: "Beep", action: #selector(stuff), keyEquivalent: "", at: 0)
////
////        menu.popUp(positioning: nil, at: self.convert(event.locationInWindow, from:nil), in: self)
////
//       // popover.show(relativeTo: self.bounds, of: self, preferredEdge: NSRectEdge.maxY)
//    }
    
    
    override func mouseUp(with event: NSEvent) {
        if selectionIsHidden {
            return
        }
        if selectionRect != nil {
            isSelectionNew = false
        }
        self.needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        let context = NSGraphicsContext.current?.cgContext

        NSColor.darkGray.set()
        NSBezierPath(rect: dirtyRect).fill()

        // draw image with no interpolation (which works poorly for upsampling very pixelated data)
        context?.interpolationQuality = .none
        super.draw(dirtyRect)
        
        if selectionIsHidden {
            return
        }

        switch selectMode {
        case .marquee:
            if let rect = selectionRect {
                selectionFillColor.set()
                let pathSelectionRect = NSBezierPath(rect: rect)
                pathSelectionRect.fill()

                NSColor.red.set()
                pathSelectionRect.lineWidth = 0.5
                pathSelectionRect.stroke()
            }
        case .point:
            drawPointSelection(point: selectionRect?.origin, context: context!)
        case .none:
            return
        }
    }
    
    func scaleFactor() -> CGFloat {
        return 1.0
    }
    
    func changeSelectionRect(){
        
    }
    
    func drawPointSelection(point:NSPoint?, context:CGContext){
        
        let strokeWidth = 1.0
        let longOffset = CGFloat(2.0)
        let shortOffset = longOffset * 0.25

        let redColor = NSColor.red
        
        if let crossCenter = point {
            for i in [(-1.0,0.0), (1.0,0.0), (0.0,-1.0), (0.0,1.0)] {
                let outerPoint = CGPoint.init(x: crossCenter.x+CGFloat(i.0)*longOffset, y: crossCenter.y+CGFloat(i.1)*longOffset)
                let innerPoint = CGPoint.init(x: crossCenter.x+CGFloat(i.0)*shortOffset, y: crossCenter.y+CGFloat(i.1)*shortOffset)
                
                let line = [outerPoint, innerPoint]
                
                context.setLineWidth(CGFloat(strokeWidth))
                context.setStrokeColor(redColor.cgColor)
                context.addLines(between: line)
                context.drawPath(using: .stroke)

            } // end for
        } // end if
    }
}
