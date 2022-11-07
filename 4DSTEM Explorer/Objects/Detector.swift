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
    var size:NSSize

    
    override init() {
        shape = DetectorShape.bf
        type = DetectorType.integrating
        
        radii = DetectorRadii(inner: 0, outer: 10)
        center = NSPoint(x: CGFloat(empadSize.width)/2.0, y: CGFloat(empadSize.height)/2.0)
        size = NSSize(width: 128, height: 128)
        
    }
    
    init(shape:DetectorShape, type:DetectorType, center:NSPoint, radii:DetectorRadii, size:NSSize) {
        self.type = type
        self.shape = shape
        
        self.size = size
        
        self.radii = radii
        self.center = center
    }
    
    func detectorMask() -> Matrix {
        let apFact = ApertureFactory(size: size)
        let mask:Matrix

        // fix negative mask radius
        let outer = abs(Float(radii!.outer));
        let inner = abs(Float(radii!.inner));

        switch shape {
        case DetectorShape.bf:
            mask = apFact.bf(radius: outer, center: center)
        case DetectorShape.adf:
            mask = apFact.adf(inner: inner, center: center)
        case DetectorShape.af:
            // fix swapped inner and outer mask
            mask = apFact.af(inner: min(inner, outer), outer: max(inner, outer), center: center)
        default:
            mask = Matrix.init(empadSize.height-2, empadSize.width)
//            detectorArray.append(onesMatrix)
        }
        return mask
    }
}
