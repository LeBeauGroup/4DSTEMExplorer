//
//  Functions.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 1/10/18.
//  Copyright © 2018 The LeBeau Group. All rights reserved.
//

import Foundation

extension NSPoint{
    
    func distanceTo(_ point:NSPoint) -> CGFloat{
        
        let x2:Float = Float((x-point.x)*(x-point.x))
        let y2:Float = Float((y-point.y)*(y-point.y))
        
        let distance = CGFloat(sqrtf(x2+y2))
        
        return distance
        
    }
    
}



