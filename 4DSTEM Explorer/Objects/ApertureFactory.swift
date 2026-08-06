//
//  ApertureCreator.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/24/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation


class ApertureFactory: NSObject {

    let width:Int
    let height:Int
    
    override init() {
        
        width = 128
        height = 128

        super.init()
    }
    
    init(size:NSSize) {
        
        width = Int(size.width)
        height = Int(size.height)
        super.init()
    }
    
    /// A detector one pixel across, at `center`.
    ///
    /// The nearest pixel rather than an area: the point detector exists to ask
    /// what a single detector element sees, so rounding to a neighbourhood would
    /// defeat it. A centre that lands outside the detector gives an empty mask
    /// rather than a clamped one, because silently sampling an edge pixel would
    /// look like data.
    func point(center:NSPoint) -> Matrix {

        let mask = Matrix(height, width)

        let j = Int(center.x.rounded())
        let i = Int(center.y.rounded())

        if i >= 0 && i < height && j >= 0 && j < width {
            mask.set(i, j, 1)
        }

        return mask
    }

    func bf(radius:Float, center:NSPoint ) -> Matrix {
        
        let bfMask = Matrix(height, width)
        
        let r2 = radius*radius
        
        for i in 0..<height {
            for j in 0..<width{
            
                let lengthI = (CGFloat(i)-center.y)*(CGFloat(i)-center.y)
                let lengthJ = (CGFloat(j)-center.x)*(CGFloat(j)-center.x)

                let curLength = lengthI + lengthJ
                
                if(curLength <= CGFloat(r2)){
                    bfMask.set(i, j, 1)
                }
            }
        }
        
        return bfMask
    }
    
    func af(inner:Float, outer:Float, center:NSPoint ) -> Matrix {
        
        let afMask = Matrix(height, width)
        
        let inner2 = CGFloat(inner*inner)
        let outer2 = CGFloat(outer*outer)
        
        for i in 0..<height {
            for j in 0..<width{
                
                let lengthI = (CGFloat(i)-center.y)*(CGFloat(i)-center.y)
                let lengthJ = (CGFloat(j)-center.x)*(CGFloat(j)-center.x)
                
                let curLength = lengthI + lengthJ
                
                if(curLength > inner2 && curLength <= outer2 ){
                    afMask.set(i, j, 1)
                }
            }
        }
        
        return afMask
    }
    
    
    func adf(inner:Float, center:NSPoint ) -> Matrix {
        
        
        let mask = Matrix(height, width)

        let inner2 = CGFloat(inner*inner)
        
        
        for i in 0..<height {
            
            for j in 0..<width{
                
                let lengthI = (CGFloat(i)-center.y)*(CGFloat(i)-center.y)
                let lengthJ = (CGFloat(j)-center.x)*(CGFloat(j)-center.x)
                
                let curLength = lengthI + lengthJ
                
                if(curLength > inner2){
                    mask.set(i, j, 1)
                }
            }
        }
        
        return mask
    }
    
    func dpc(radius:Float, center:NSPoint ) -> [Matrix] {
        
        let mask = Matrix(height, width)
        
        var dpcArray = [Matrix]()
        
        let r2 = radius*radius
        
        for i in 0..<height {
            
            for j in 0..<width{
                
                let lengthI = (CGFloat(i)-center.y)*(CGFloat(i)-center.y)
                let lengthJ = (CGFloat(j)-center.x)*(CGFloat(j)-center.x)
                
                let curLength = lengthI + lengthJ
                
                if(curLength > CGFloat(r2)){
                    mask.set(i, j, 1)
                }
            }
        }
        
        dpcArray.append(mask)
        
        return dpcArray
    }
    
    
    
}
