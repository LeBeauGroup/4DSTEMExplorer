//
//  Constants.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/27/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation



let empadSize = IntSize(width: 128, height: 130)

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

func TIFFheader(_ url: URL)throws ->[String:Any] {
    
    var properties = [String:Any]()
    var fh:FileHandle?
    
    do{
        try fh =  FileHandle.init(forReadingFrom: url)
        
    }catch{
        throw FileReadError.invalidTiff
    }
    
    var endianTest = Int16(0)
    var bigEndian = true

    
    fh?.readData(ofLength: 2).withUnsafeBytes{(ptr: UnsafePointer<Int16>) in
        endianTest = ptr.pointee
        
    }
    
    if endianTest == Int16(0x4D4D){
        bigEndian = true
    }else if endianTest == Int16(0x4949){
        bigEndian = false
    }else{
        throw FileReadError.invalidTiff
    }
    
    var versionTest = Int16(0)

    fh?.readData(ofLength: 2).withUnsafeBytes{(ptr: UnsafePointer<Int16>) in
        
        var pointee = ptr.pointee
        
        if bigEndian{
            pointee = pointee.bigEndian
        }
        
        versionTest = pointee
    }
    
    if versionTest != Int16(42){
        throw FileReadError.invalidTiff
    }
    
    var firstIFD:Int32 = 0
    
    fh?.readData(ofLength: 4).withUnsafeBytes{(ptr: UnsafePointer<Int32>) in
        var pointee = ptr.pointee
        if bigEndian{
            pointee = pointee.bigEndian
        }
        
        firstIFD = pointee
    }
    
    fh?.seek(toFileOffset: UInt64(firstIFD))
    
    var IFDcount:Int16 = 0
    
    fh?.readData(ofLength: 2).withUnsafeBytes{(ptr: UnsafePointer<Int16>) in
        var pointee = ptr.pointee
        if bigEndian{
            pointee = pointee.bigEndian
        }
        
        IFDcount = pointee
    }
    
    print(IFDcount)
    

    for i in 0..<IFDcount{
        
        var fieldTag:UInt16 = 0
        var fieldType:UInt16 = 0
        var fieldCount:UInt32 = 0
        var fieldValue:UInt32 = 0
        
        fh?.readData(ofLength: 2).withUnsafeBytes{(ptr: UnsafePointer<UInt16>) in
            var pointee = ptr.pointee
            if bigEndian{
                pointee = pointee.bigEndian
            }
            
            fieldTag = pointee
        }
        
        fh?.readData(ofLength: 2).withUnsafeBytes{(ptr: UnsafePointer<UInt16>) in
            var pointee = ptr.pointee
            if bigEndian{
                pointee = pointee.bigEndian
            }
            
            fieldType = pointee
        }
    
        
        fh?.readData(ofLength: 4).withUnsafeBytes{(ptr: UnsafePointer<UInt32>) in
            var pointee = ptr.pointee
            if bigEndian{
                pointee = pointee.bigEndian
            }
            
            fieldCount = pointee
        }
        
        var value:Any?
        
        let currentOffset = fh?.offsetInFile

        var fieldOffset:UInt64 = currentOffset!

        if fieldCount > 1{
            fh?.readData(ofLength: 4).withUnsafeBytes{(ptr: UnsafePointer<UInt32>) in
                var pointee = ptr.pointee
                if bigEndian{
                    pointee = pointee.bigEndian
                }
                fieldOffset = UInt64(pointee)
            }
        }
        
        fh?.seek(toFileOffset: fieldOffset)
        
        switch fieldType{
        case 1:
            // byte
            fh?.readData(ofLength: Int(fieldCount)).withUnsafeBytes{(ptr: UnsafePointer<UInt8>) in
                var pointee = ptr.pointee
                if bigEndian{
                    pointee = pointee.bigEndian
                }
                value = pointee
            }
        case 2:
            // ascii (offset to string given in IFD)
//                var asciiOffset:UInt32 = 0
//                fh?.readData(ofLength: 4).withUnsafeBytes{(ptr: UnsafePointer<UInt32>) in
//                    var pointee = ptr.pointee
//                    if bigEndian{
//                        pointee = pointee.bigEndian
//                    }
//                    asciiOffset = pointee
//                }
            
            fh?.readData(ofLength: Int(fieldCount)).withUnsafeBytes{(ptr: UnsafePointer<CChar>) in

                value = String(cString: ptr)
                
            }
            

        case 3:
            // short
            fh?.readData(ofLength: Int(fieldCount)*2).withUnsafeBytes{(ptr: UnsafePointer<Int16>) in
                var pointee = ptr.pointee
                if bigEndian{
                    pointee = pointee.bigEndian
                }
                value = pointee
            }
//            fh?.seek(toFileOffset: (fh?.offsetInFile)! + UInt64(2))
            
        case 4:
            // long
        fh?.readData(ofLength: Int(fieldCount)*4).withUnsafeBytes{(ptr: UnsafePointer<Int32>) in
            var pointee = ptr.pointee
            if bigEndian{
                pointee = pointee.bigEndian
            }
            value = pointee
            }
        case 5:
            // rational
            
            var numerator:Int32 = 0
            fh?.readData(ofLength: Int(fieldCount)*4).withUnsafeBytes{(ptr: UnsafePointer<Int32>) in
                var pointee = ptr.pointee
                if bigEndian{
                    pointee = pointee.bigEndian
                }
                numerator = pointee
            }
            var denominator:Int32 = 0
            fh?.readData(ofLength: Int(fieldCount)*4).withUnsafeBytes{(ptr: UnsafePointer<Int32>) in
                var pointee = ptr.pointee
                if bigEndian{
                    pointee = pointee.bigEndian
                }
                denominator = pointee
            }
            
            value = Float(numerator)/Float(denominator)
            
        default:
            continue
        }
        
        fh?.seek(toFileOffset: currentOffset! + 4)


        
        var label:String
        switch fieldTag{
        case 256:
            label = "ImageWidth"
        case 257:
            label = "ImageHeight"
        case 270:
            label = "ImageDescription"
        case 50839:
            label = "FirstImageOffset"
            value = fieldOffset + UInt64(fieldCount)
            
        default:
            continue
        }
        
        
        if value != nil{
            properties[label] = value!
        }

        
    }
    
    return properties
    
}


