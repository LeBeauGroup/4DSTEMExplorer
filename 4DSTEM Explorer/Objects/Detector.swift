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

/// How the masks of several detectors are combined into one.
///
/// This is arithmetic on the masks, not on the images they produce. For an
/// integrating detector the two agree for add and subtract (the sum is linear),
/// and working on the mask means the result is a detector like any other: it
/// can be integrated, or have a centre of mass or a DPC taken across it, in one
/// pass over the data.
enum DetectorMath: String, CaseIterable, Hashable {
    /// The masks summed: overlapping regions count twice.
    case add
    /// The first mask minus the rest: a signed mask, so the image is the first
    /// detector's intensity less the others'.
    case subtract
    /// The masks multiplied: only where every detector overlaps.
    case multiply

    var title: String {
        switch self {
        case .add: return "Add"
        case .subtract: return "Subtract"
        case .multiply: return "Multiply"
        }
    }

    var symbol: String {
        switch self {
        case .add: return "+"
        case .subtract: return "\u{2212}"
        case .multiply: return "\u{00D7}"
        }
    }

    func combine(_ masks: [[Float]]) -> [Float] {
        guard var result = masks.first else { return [] }
        for mask in masks.dropFirst() {
            guard mask.count == result.count else { continue }
            switch self {
            case .add:      for i in result.indices { result[i] += mask[i] }
            case .subtract: for i in result.indices { result[i] -= mask[i] }
            case .multiply: for i in result.indices { result[i] *= mask[i] }
            }
        }
        return result
    }
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

    /// When set, this detector has no geometry of its own: its mask is the
    /// parts' masks combined. The parts are the live detectors, so a part that
    /// moves or resizes changes this one with it.
    var combination: (math: DetectorMath, parts: [Detector])?

    
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

        if let combination, !combination.parts.isEmpty {
            let masks = combination.parts.map { $0.detectorMask() }
            let result = Matrix(Int(size.height), Int(size.width))
            let combined = combination.math.combine(masks.map { $0.real })
            if combined.count == result.real.count {
                result.real = combined
            }
            return result
        }

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

