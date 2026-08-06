//
//  Detector.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/29/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

enum DetectorShape: Hashable {
    case point
    case bf
    case af
    case adf
    case custom
}

enum DetectorType: Hashable {
    case integrating
    case dpc
    case com
    case custom
}

enum DetectorParameter:Hashable{
    case innerRadius
    case outerRadius
}

class Detector: NSObject {
    
    let type:DetectorType
    let shape:DetectorShape
    var parameters:[DetectorParameter:Float]
    var scaleFactor:Float = 1
    var center:NSPoint
    var size:NSSize

    
    override init() {
        shape = .bf
        type = .integrating
        
        parameters = [.innerRadius: 0.0, .outerRadius: 10.0]
        center = NSPoint(x: CGFloat(empadSize.width)/2.0, y: CGFloat(empadSize.height)/2.0)
        size = NSSize(width: 128, height: 128)
        
        
    }
    
    
    init(shape:DetectorShape, type:DetectorType, center:NSPoint, params:[DetectorParameter:Float], size:NSSize) {
        self.type = type
        self.shape = shape
        
        self.size = size
        
        parameters = params
        self.center = center
    }
    
    func detectorMask() -> Matrix {
        
        let apFact = ApertureFactory(size: size)
        
        let mask:Matrix
        
//        var detectorArray = [Matrix].init()
        
        switch shape {
        case DetectorShape.point:
            mask = apFact.point(center: center)
        case DetectorShape.bf:
          
            mask =   apFact.bf(radius: parameters[.outerRadius] ?? 0.0, center: center)
//            detectorArray.append(bfMatrix)
            case DetectorShape.adf:
            mask = apFact.adf(inner: parameters[.innerRadius] ?? 0.0, center: center)
        case DetectorShape.af:
            mask = apFact.af(inner: parameters[.innerRadius] ?? 0.0, outer: parameters[.outerRadius] ?? 0.0, center: center)
        default:
            mask = Matrix.init(empadSize.height-2, empadSize.width)
//            detectorArray.append(onesMatrix)
        }
        
        return mask
        
    }
    
}

