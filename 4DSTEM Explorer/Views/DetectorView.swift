//
//  DetectorView.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/27/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Cocoa

let controlRadius:CGFloat = 3.5

protocol DetectorViewDelegate: class {
}


class DetectorView: NSView {

    override var isFlipped:Bool {
        return true
        
    }
    
    weak var delegate: DetectorViewDelegate?

    
    let strokeSize:CGFloat = 2

    var locationType:String = "detector"
    var selectionIsHidden:Bool = false
    
    var detectorShape:DetectorShape = DetectorShape.bf
    var detectorType:DetectorType = DetectorType.integrating
    var radii:DetectorRadii?
    var lastDragLocation:NSPoint = NSPoint(x: 0, y: 0)
    let apFact = ApertureFactory()
    
    var center = NSPoint(x:0, y:0)
    var frameCenter:NSPoint{
        get{
            return  NSPoint(x: frame.origin.x + frame.width/2, y: frame.origin.y+frame.height/2)
        }
        
    }
    
    var detectorCenter:NSPoint{
        get{
            let convertedCenter = convertPointToImageCoordinates(center)


            
            print(convertedCenter)
//            convertedCenter.x += radii!.outer-strokeSize/(2/self.scaleFactor())
//            convertedCenter.y += radii!.outer-strokeSize/(2/self.scaleFactor())

            return convertedCenter
        }
    }
    var detector:Detector {
        get{
                    
            
            let imageView = (self.superview as! NSImageView)

            
            return Detector(shape: detectorShape, type: detectorType, center: convertPointToImageCoordinates(center), radii: radii!, size:imageView.image!.size)
        }
        set(newDetector){
            
            self.detectorShape = newDetector.shape
            self.detectorType = newDetector.type
            self.radii = newDetector.radii!
            
            frame.origin = NSPoint(x: 0, y: 0)
            frame.size = (self.superview?.frame.size)!
                
            center = convertPointToFrameCoordinates(newDetector.center)
            
            self.needsDisplay = true
            
        }
    }

    
    
    override init(frame frameRect: NSRect) {
    
        
        super.init(frame: frameRect)
        
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    required init?(coder: NSCoder) {
        //        fatalError("init(coder:) has not been implemented")
        
        super.init(coder: coder)
        
    }
    
    func isPointInItem(_ point:NSPoint)->Bool{
    
        var itemHit = false
        
        // rough test
        
        var detectorRect:NSRect
        
        
        
        switch detectorShape {
        case DetectorShape.adf:
            detectorRect = apertureRect("inner")
        default:
            detectorRect = apertureRect("outer")

        }
        
      
        
        itemHit = NSPointInRect(point, detectorRect)

        let radius = detectorRect.width/2.0
        
        //fine tuning
        if itemHit{
            
            let xdist2 = (point.x-center.x)*(point.x-center.x)
            let ydist2 = (point.y-center.y)*(point.y-center.y)
            
            let dist2 = xdist2+ydist2
            
            if dist2 >= radius*radius{
                itemHit = false
            }
            
            
        }
        
        return itemHit
        
    }
    
    func isPointInControl(_ point:NSPoint)->Bool{
        
        var itemHit = false
        
        // rough test
        
        if detectorShape == DetectorShape.bf{
            if NSPointInRect(point, controlRect("outer")){
                return true
            }
        } else if detectorShape == DetectorShape.af{
            if NSPointInRect(point, controlRect("outer")) || NSPointInRect(point, controlRect("inner")){
                return true
            }
        } else if detectorShape == DetectorShape.adf{
            if  NSPointInRect(point, controlRect("inner")){
                return true
            }
        }

        
        
        //fine tuning
//        if itemHit{
//
//            let xdist2 = (point.x-center.x)*(point.x-center.x)
//            let ydist2 = (point.y-center.y)*(point.y-center.y)
//
//            let dist2 = xdist2+ydist2
//
//            if dist2 >= scaledRadius()*scaledRadius(){
//                itemHit = false
//            }
//
//
//        }
        
        return itemHit
        
    }

    
    override func mouseDown(with event: NSEvent) {
        
        if selectionIsHidden {
            return
        }
        
        self.lastDragLocation = (self.superview?.convert(event.locationInWindow, from: nil))!
        
        if(isPointInControl(lastDragLocation)){
            
            if(NSPointInRect(lastDragLocation, controlRect("outer"))){
                locationType = "outerControl"
            }else if(NSPointInRect(lastDragLocation, controlRect("inner"))){
                locationType = "innerControl"
            }
            
        }else if(isPointInItem(lastDragLocation)){
            locationType = "detector"
        
        }else{
            locationType = "ignore"
        }
        
    }
    
    override func mouseDragged(with event: NSEvent) {
        
        if selectionIsHidden {
            return
        }
        
        let newDragLocation = self.superview?.convert(event.locationInWindow, from: nil)
        
//        if(isPointInControl(lastDragLocation)){
        if locationType == "outerControl" || locationType == "innerControl"{
            
            var newRadii = self.radii
            
            var deltaR:CGFloat = 0.0
            
            
            switch locationType{
            case "innerControl":
                deltaR = lastDragLocation.y - (newDragLocation!.y)

            default:
                deltaR = (newDragLocation!.x)-lastDragLocation.x

            }

            if locationType == "outerControl"{
                newRadii?.outer += deltaR*scaleFactor()

            }else if locationType == "innerControl"{
                newRadii?.inner += deltaR*scaleFactor()

            }

            self.radii = newRadii!
            self.lastDragLocation = newDragLocation!;

            
            NotificationCenter.default.post(name: Notification.Name("detectorIsMoving"), object: 0)
            
//        }else if(isPointInItem(lastDragLocation)){
        }else if locationType == "detector"{
            
            var newCenter = self.center
            newCenter.x += (-self.lastDragLocation.x + (newDragLocation?.x)!)
            newCenter.y += (-self.lastDragLocation.y + (newDragLocation?.y)!)
        
            if visibleRect.minX > newCenter.x || visibleRect.maxX-1 < newCenter.x{
                center.y = newCenter.y
            }else if visibleRect.minY > newCenter.y || visibleRect.maxY-1 < newCenter.y{
                center.x = newCenter.x
            }else{
                center = newCenter
            }
            
            self.lastDragLocation = newDragLocation!

        
            NotificationCenter.default.post(name: Notification.Name("detectorIsMoving"), object: 0)
        }

    }
    
    override func mouseUp(with event: NSEvent) {
        NotificationCenter.default.post(name: Notification.Name("detectorFinishedMoving"), object: 0)

    }
    
    override func draw(_ dirtyRect: NSRect) {
        
        let context = NSGraphicsContext.current?.cgContext
    
        if selectionIsHidden == false{
            
            let whiteColor = NSColor.white.withAlphaComponent(0.5)
           
            context?.setFillColor(whiteColor.cgColor)
            context?.setStrokeColor(NSColor.red.cgColor)
            
            switch detectorShape{
            case DetectorShape.bf:
                drawBf(context!)
            case DetectorShape.af:
                drawAf(context!)
            case DetectorShape.adf:
                drawAdf(context!)
            default:
                drawBf(context!)

            }
            drawCrosshairs(context!)
                drawControls(context!)
        
        }
        
        
    }

    func controlRect(_ ioAngle:String = "outer") -> NSRect {
        
        let radius = scaledRadius(ioAngle)
        var controlOrigin = center
        

        switch ioAngle {
        case "inner":
            controlOrigin.y += -radius  - controlRadius
            controlOrigin.x -= (controlRadius - strokeSize/2)
        default:
            controlOrigin.x += (radius+strokeSize - controlRadius)
            controlOrigin.y -= (controlRadius - strokeSize/2)
        }
        
        let rect = NSRect(origin: controlOrigin, size: NSSize(width: controlRadius*2, height: controlRadius*2))
        
        return rect
    }

    
    func apertureRect(_ ioAngle:String = "outer") -> NSRect {
        
        let radius:CGFloat = scaledRadius(ioAngle)
        let rectWidth = 2*(radius) + 2*strokeSize
        
        let rect = NSRect(origin: apertureOrigin(ioAngle), size: NSSize(width: rectWidth, height: rectWidth))
        
        
        return rect

    }
    
    func apertureOrigin(_ ioAngle:String = "outer") -> NSPoint {
        
        let radius:CGFloat = scaledRadius(ioAngle)

        
        let apOrigin = NSPoint(x:center.x-radius-strokeSize*scaleFactor(), y:center.y-radius-strokeSize*scaleFactor())
        
        return apOrigin
        
    }
    
    func scaledRadius(_ ioAngle:String = "outer") -> CGFloat{
        
        let scaleFactor = self.scaleFactor()
        let radius:CGFloat
        
        if ioAngle == "inner"{
            radius = (radii?.inner)!/scaleFactor
        }else{
            radius = (radii?.outer)!/scaleFactor
        }
            
        return radius
    }


    func drawCrosshairs(_ context: CGContext){
        let redColor = NSColor.red
        
        var crossCenter = center
        crossCenter.x += strokeSize/2
        crossCenter.y += strokeSize/2
        
        let length = CGFloat(3.0)

        let updown = [CGPoint.init(x: crossCenter.x, y: crossCenter.y-length), CGPoint.init(x: crossCenter.x, y: crossCenter.y+length)]
        let leftright =  [CGPoint.init(x: crossCenter.x-length, y: crossCenter.y), CGPoint.init(x: crossCenter.x+length, y: crossCenter.y)]

        context.setLineWidth(1.0)
        context.setFillColor(redColor.cgColor)
        context.addLines(between: updown)
        context.addLines(between: leftright)
        
        context.drawPath(using: .stroke)

        
        
    }
    
    func drawControls(_ context:CGContext){
        
        let whiteColor = NSColor.white
        
        context.setFillColor(whiteColor.cgColor)
//        context.setStrokeColor(NSColor.red.cgColor)
        
        if detectorShape == DetectorShape.bf || detectorShape == DetectorShape.af {
            context.addEllipse(in: controlRect("outer"))
            context.drawPath(using: .eoFillStroke)
        }
        
        if detectorShape == DetectorShape.adf || detectorShape == DetectorShape.af {
            context.addEllipse(in: controlRect("inner"))
            context.drawPath(using: .eoFillStroke)
        }
        
    }

    
    func drawAdf(_ context:CGContext){
        
        context.addRect(frame)
        context.addEllipse(in: apertureRect("inner"))

        context.drawPath(using: .eoFillStroke)

    }
    
    func drawBf(_ context:CGContext){
        
        
        context.addEllipse(in: apertureRect())
        context.drawPath(using: .eoFillStroke)
        


        
    }
    
    func drawAf(_ context:CGContext){
        
        context.addEllipse(in: apertureRect())
        context.addEllipse(in: apertureRect("inner"))
        
        context.drawPath(using: .eoFillStroke)

    }
    
    
    func scaleFactor()->CGFloat{
        
        let imageView = (self.superview as! NSImageView)
        let imageViewSize = imageView.frame.size
        
        let scaleFactor:CGFloat
        
        if let imageSize = imageView.image?.size{
            scaleFactor   = (imageSize.width)/imageViewSize.width
        }else{
            scaleFactor = 1.0
        }
        
        return scaleFactor
        
    }
    
    func convertSizeToFrameCoordinates(_ size:NSSize)-> NSSize{
        
        let scaleFactor = self.scaleFactor()
        let newSize = NSSize(width: (size.width)/scaleFactor, height: (size.height)/scaleFactor)
        return newSize
        
    }
    
    func convertSizeToImageCoordinates(_ size:NSSize)-> NSSize{
        
        let scaleFactor = self.scaleFactor()
        return NSSize(width: (size.width)*scaleFactor, height: (size.height)*scaleFactor)
        
    }

    
    func convertPointToImageCoordinates(_ point:NSPoint)-> NSPoint{

        let scaleFactor = self.scaleFactor()
        let newPoint = NSPoint(x: (point.x)*scaleFactor, y: (point.y)*scaleFactor)
        
        return newPoint

        
    }
    
    func convertPointToFrameCoordinates(_ point:NSPoint)-> NSPoint{
        
        let scaleFactor = self.scaleFactor()
        
        let newPoint = NSPoint(x: (point.x)/scaleFactor, y: (point.y)/scaleFactor)
        
        return newPoint
        
        
    }
    
//    func detector() -> Detector{
//
//        var recentered = frame.origin
//
//        recentered.x += CGFloat(empadSize.width)
//        recentered.x /= 2
//        recentered.y -= CGFloat(empadSize.height-2)
//        recentered.y /= -2
////        print((recentered.x,recentered.y))
//
//        return apFact.adf(inner: Float(self.radius)/2, center: recentered)
//
//    }
}
