//
//  Constants.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/27/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation



struct IntSize {
    var width:Int
    var height:Int
    
    init(width:Int, height:Int) {
        self.width = width
        self.height = height
    }
}

struct DetectorRadii {
    var inner:CGFloat
    var outer:CGFloat
    
    init(inner:CGFloat, outer:CGFloat) {
        self.inner = inner
        self.outer = outer
    }
}


let empadSize = IntSize(width: 128, height: 130)

