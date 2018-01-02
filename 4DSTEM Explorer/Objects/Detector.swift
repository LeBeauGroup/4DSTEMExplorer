//
//  Detector.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/29/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

enum DetectorShape {
    case point
    case bf
    case af
    case adf
    case custom
}

enum DetectorType{
    case integrating
    case dpc
    case com
}

class Detector: NSObject {
    
    let type:DetectorType
    let shape:DetectorShape
    var radii:DetectorRadii?
    var scaleFactor:Float = 1
    var center:NSPoint

    
    override init() {
        shape = DetectorShape.bf
        type = DetectorType.integrating
        
        radii = DetectorRadii(inner: 0, outer: 10)
        center = NSPoint(x: CGFloat(empadSize.width)/2.0, y: CGFloat(empadSize.height)/2.0)
        
    }
    init(shape:DetectorShape, type:DetectorType, center:NSPoint, radii:DetectorRadii) {
        self.type = type
        self.shape = shape
        
        self.radii = radii
        self.center = center
    }
    
    func detectorMask() -> Matrix {
        
        let apFact = ApertureFactory()
        
        let mask:Matrix
        
        var detectorArray = [Matrix].init()
        
        switch shape {
        case DetectorShape.bf:
          
            mask =   apFact.bf(radius: Float(radii!.outer), center: center)
//            detectorArray.append(bfMatrix)
            case DetectorShape.adf:
            mask = apFact.adf(inner: Float(radii!.inner), center: center)
        case DetectorShape.af:
            mask = apFact.af(inner: Float(radii!.inner), outer: Float(radii!.outer), center: center)
        default:
            mask = Matrix.init(empadSize.height-2, empadSize.width)
//            detectorArray.append(onesMatrix)
        }
        
        return mask
        
    }
    
}
