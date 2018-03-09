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
    
    
//    lazy var popover: NSPopover! = {
//        let popover = NSPopover()
////        popover.appearance = NSAppearance.
//        popover.animates = true
//        popover.behavior = .transient
//        return popover
//    }()
    
    
    
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
    private var lastDragLocation:NSPoint?
    private var isSelectionMoving:Bool = false
    private var isSelectionNew:Bool = true

    let selectionFillColor:NSColor = NSColor.red.withAlphaComponent(0.25)
    
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
        
        self.window?.makeFirstResponder(self)
        
        let testPoint = (self.convert(event.locationInWindow, from:nil))
        
        if selectionRect == nil {
            isSelectionNew = true
            selectionRect = nil
            selectMode = .point
            selectionRect = NSRect(origin: testPoint, size: CGSize(width: 0, height: 0))
        }
        
        switch selectMode{
        case .point:
            
            var pointRect = selectionRect!
            pointRect.origin.x -= 2
            pointRect.origin.y -= 2
            
            pointRect.size.width = 4
            pointRect.size.height = 4
            
    
            if !pointRect.contains(testPoint){
                isSelectionNew = true
                selectionRect = nil
                selectMode = .point
                selectionRect = NSRect(origin: testPoint, size: CGSize(width: 0, height: 0))

            }
            
            delegate?.averagePatternInRect(scaledRect)

        default:
            if !isPointInSelectionRect(testPoint){
                
                isSelectionNew = true
                selectionRect = nil
                selectMode = .point
                
                selectionRect = NSRect(origin: testPoint, size: CGSize(width: 0, height: 0))

                
                lastDragLocation = testPoint
                isSelectionMoving = false

            }else {
                lastDragLocation = testPoint
                isSelectionMoving = true
                
            }
            
            delegate?.averagePatternInRect(scaledRect)

            
        }
        
        
        
        self.needsDisplay = true
        
        
    }
    
    
    
    
    override func keyDown(with event: NSEvent) {
        
        let ch = event.charactersIgnoringModifiers! as NSString
        var rate:CGFloat = 1.0
        // TODO: Also check for shift modifier, add multiplier
        
        if ch.length == 1{
            let keyChar: Int = Int(ch.character(at: 0))
            
            if event.modifierFlags.contains(.shift){
                rate = 5.0
            }
            
            var originy:CGFloat = (selectionRect?.origin.y)!
            var originx:CGFloat = (selectionRect?.origin.x)!

            switch keyChar {
            case NSUpArrowFunctionKey:
                originy -= rate
            case NSDownArrowFunctionKey:
               originy += rate
            case NSLeftArrowFunctionKey:
                originx -= rate
            case NSRightArrowFunctionKey:
                originx += rate
            default:
                print("not arrow")
                super.keyDown(with: event)
                
            }
            
            if originx > {
                
            }
            
           selectionRect?.origin.y = originy
        selectionRect?.origin.x = originx
            
            delegate?.averagePatternInRect(scaledRect)
            self.needsDisplay = true
            
            
        }
        
        
    }
    
    override func mouseDragged(with event: NSEvent) {
       
        let testPoint = (self.convert(event.locationInWindow, from:nil))
        let scaleFactor = (self.image?.size.width)!/frame.width

        if true
        {
            
            if testPoint.distanceTo(selectionRect!.origin) > 2 && isSelectionNew{
                selectMode = .marquee
            }
            
            switch selectMode{
            case .marquee:
                
                var newRect = selectionRect!
                var newSize = selectionRect?.size
                
                if isSelectionMoving{
                
                    var newOrigin = newRect.origin
                    newOrigin.x += testPoint.x-(lastDragLocation?.x)!
                    newOrigin.y += testPoint.y-(lastDragLocation?.y)!
                    
                    if visibleRect.minX > newOrigin.x || visibleRect.maxX-1 < newOrigin.x{
                        newRect.origin.y = newOrigin.y
                    }else if visibleRect.minY > newOrigin.y || visibleRect.maxY-1 < newOrigin.y{
                        newRect.origin.x = newOrigin.x
                    }else{
                        newRect.origin = newOrigin
                    }
                    
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
    
    @objc func stuff(){
        
    }
    
    override func rightMouseDown(with event: NSEvent) {
        
        let story =  NSStoryboard(name: NSStoryboard.Name(rawValue: "Main"), bundle: nil)
        
        let homeViewController:NSViewController = story.instantiateController(withIdentifier: NSStoryboard.SceneIdentifier(rawValue: "ImageRightClickController")) as! NSViewController
        
        let popover = NSPopover.init()
        
        popover.contentViewController = homeViewController
        

        popover.show(relativeTo: self.bounds, of: self, preferredEdge: .minX)
        
        
        //        let pop = NSPopover.init()
//        var menu = NSMenu.init()
//
//        let item = NSMenuItem
//        menu.insertItem(withTitle: "Beep", action: #selector(stuff), keyEquivalent: "", at: 0)
//
//        menu.popUp(positioning: nil, at: self.convert(event.locationInWindow, from:nil), in: self)
//
       // popover.show(relativeTo: self.bounds, of: self, preferredEdge: NSRectEdge.maxY)
    }
    override func mouseUp(with event: NSEvent) {
    
        let testPoint = (self.convert(event.locationInWindow, from:nil))
        
        
        if selectionRect != nil{
            
            isSelectionNew = false

            
            if testPoint.distanceTo(selectionRect!.origin) < 1.5{
                selectMode = .point
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
    
    func changeSelectionRect(){
        
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

            } // end for
        } // end if
        
    }
    
}
