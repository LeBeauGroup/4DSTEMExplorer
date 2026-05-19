//
//  Matrix.swift
//  Ronchigram
//
//  Created by James LeBeau on 5/19/17.
//  Copyright © 2017 The Handsome Microscopist. All rights reserved.
//

import Foundation
import Cocoa
import Accelerate


//MARK: - Constants
struct MatrixConstant {
    static let elementwise = "element-wise"
    static let product = "product"
}

struct MatrixOutput {
    static let uint16 = 16
    static let uint8 = 8
    static let float = 32
}

enum MatrixType{
    case real
    case complex
}

infix operator .*


class ValueError: Error, CustomStringConvertible {
    let description: String
    
    init(_ description: String) {
        self.description = description
    }
}


class Matrix: CustomStringConvertible, NSCopying{
    
    
    func copy(with zone: NSZone? = nil) -> Any {
        let copy = Matrix.init(self.rows, self.columns)
        copy.real = self.real
        
        
        copy.imag? = self.imag!
        
        return copy
    }
    

    
    //MARK: - Properties
    let rows:Int
    let columns:Int
    let type:MatrixType
    
    var size:NSSize{
        get{
            return NSSize(width: columns, height: rows)
        }
    }
    
    var real:Array<Float>
    var imag:Array<Float>?
    
    var count: Int {
        return rows*columns
    }
    var complex: Bool {
        if (imag as [Float]?) != nil{
            return true
        }else{
            return false
        }
        
    }
    
    var max:Complex {
        
        var maxValue = Complex(0,0)
        let length = vDSP_Length(count)

        let clipped = self.clip(min: -Float32.greatestFiniteMagnitude, max: Float32.greatestFiniteMagnitude)

        vDSP_maxv(clipped.real, 1, &maxValue.a, length)
        if type != .real{
            vDSP_maxv(clipped.imag!, 1, &maxValue.b, length)
        }

        return maxValue
    }

    var min:Complex {
        
        var minValue = Complex(0,0)
        let length = vDSP_Length(count)
        
        let clipped = self.clip(min: -Float32.greatestFiniteMagnitude, max: Float32.greatestFiniteMagnitude)

        vDSP_minv(clipped.real, 1, &minValue.a, length)
        if type != .real {
            vDSP_minv(clipped.imag!, 1, &minValue.b, length)
        }

        return minValue
    }
    
    
    // this currently doesn't really make sense

    
    
//MARK: - Initializers

    init(meshIndicesAlong:Int, _ rows:Int, _ columns:Int) {

        self.real = Array.init(repeating: 0.0, count: rows*columns)

        self.rows = rows
        self.columns = columns
        self.type = .real
        
        for i in 0..<rows{
            for j in 0..<columns{
                
                let index = i*columns+j
                if meshIndicesAlong == 1{
                    real[index] = Float(i)
                }else{
                    real[index] = Float(j)
                }
                
            }
        }
        
    }
    
    init(array:[Float], _ rows:Int, _ columns:Int, type:MatrixType? = .real) {
        
        if type == .complex{
            self.type = .complex
            self.rows = rows
            self.columns = columns
            
            self.real = Array.init(repeating: 0.0, count: rows*columns)
            self.imag = Array.init(repeating: 0.0, count: rows*columns)
            
            for i in 0..<rows*columns{
                self.imag![i] = array[i]
            }
            

            
        }else{
            self.real = Array.init(repeating: 0.0, count: rows*columns)
            
            for i in 0..<rows*columns{
                self.real[i] = array[i]
            }
            
            self.rows = rows
            self.columns = columns
            self.type = .real
        }
        
    }
    
    
    
    init(_ rows:Int, _ columns:Int, _ type:MatrixType? = .real){
               
        self.rows = rows
        self.columns = columns
        
            if let newType = type{
                
                
                if(newType == .real){
                    self.type = newType

                    real = Array(repeating: Float(0), count: rows*columns)
                    imag = nil
                }else if (newType == .complex){
                    self.type = newType

                    real = Array(repeating: Float(0), count: rows*columns)
                    imag = Array(repeating: Float(0), count: rows*columns)
                    
                }else{
                    self.type = .real
                    
                    real = Array(repeating: Float(0), count: rows*columns)
                    imag = nil
                }
                
            }else{
                self.type = .real
                
                real = Array(repeating: Float(0), count: rows*columns)
                imag = nil
        }
        

        
    }
    
    
    //MARK: - Matrix setters
    
    func set(_ i:Int,_ j:Int,_ value:Any){
 
        let index = columns*i+j

        switch value {
            case let complexValue as Complex:
            
                real[index] = complexValue.a
                imag?[index] = complexValue.b
        case let floatValue as (Float, Float?):
            if let imagPart = floatValue.1{
                imag?[index] = imagPart
            }
            real[index] = floatValue.0

        case let floatValue as Float:
                real[index] = floatValue
            case let intValue as Int:
                real[index] = Float(intValue)
            case let doubleValue as Double:
                real[index] = Float(doubleValue)
            default:
                print("not a valid type")
        }
    }
    
    func get(_ i:Int,_ j:Int)->(Float, Float?){
        
    
        let index = columns*i+j
        
        
        if type == .complex{
            return (real[index], imag![index])
            
        }else{
            return (real[index], nil)
        }
    
    
    }
    
    func mean(_ rect:CGRect?)->Float{
        if let selRect = rect {
            // Convert CGFloat bounds to integer index ranges, clamped to matrix bounds
            let minRow = floor(selRect.minY)
            let maxRowInclusive = floor(selRect.maxY)
            let minCol = floor(selRect.minX)
            let maxColInclusive = floor(selRect.maxX)

            // Ensure valid non-empty ranges
            if minRow <= maxRowInclusive && minCol <= maxColInclusive {
                let iRange: Range<Int> = Int(minRow)..<(Int(maxRowInclusive))
                let jRange: Range<Int> = Int(minCol)..<(Int(maxColInclusive))
                let sub = subMatrix(iRange, jRange)
                
                return sub.mean()
            }
        }
        return 0.0
    }
    
    private func mean()->Float{
        
        return self.sum()/Float(rows*columns)
        
    }
    
    func sum() -> Float {
        var sumValue = Float()
        let length:vDSP_Length = UInt(self.count)
        
        vDSP_sve(self.real, 1, &sumValue, length)
        
        return sumValue
    }

    func quantiles(_ quantiles: Array<Float>) throws -> Array<Float> {
        guard self.type == .real else {
            throw ValueError("'quantiles' only works on real-valued data.")
        }
        var sorted = self.real
        vDSP.sort(&sorted, sortOrder: .ascending)
        sorted = sorted.filter { !$0.isNaN && !$0.isInfinite }
        
        if sorted.count == 0 {
            return [0, 0]
        }
//        guard sorted.count > 0 else {
//            throw ValueError("No valid values in matrix.")
//        }

        let rough_indices = vDSP.multiply(Float(sorted.count - 1), quantiles)
        var lower_indices = Array<Int32>(repeating: 0, count: quantiles.count)
        vDSP.convertElements(of: rough_indices, to: &lower_indices, rounding: .towardZero)
    
        return zip(lower_indices, rough_indices).map { lower_i, rough_i in
            if lower_i + 1 >= sorted.count {
                return sorted[Int(lower_i)]
            }
            let t = rough_i - Float(lower_i)
            return t * sorted[Int(lower_i)] + (1-t) * sorted[Int(lower_i) + 1]
        }
    }

    func clip(min: Float, max: Float) -> Matrix {
        let out = self.copy() as! Matrix
        var min = min
        var max = max
        vDSP_vclip(&self.real, 1, &min, &max, &out.real, 1, vDSP_Length(self.count))
        if self.type != .real {
            vDSP_vclip(&self.imag!, 1, &min, &max, &out.imag!, 1, vDSP_Length(self.count))
        }
        return out
    }
    
    
    func subMatrix(_ iRange: Range<Int>, _ jRange: Range<Int>) -> Matrix{
        
        let subMat = Matrix.init(iRange.count, jRange.count)
        
        let parentI = Array(iRange)
        let parentJ = Array(jRange)
        
        for i in 0..<iRange.count{
            for j in 0..<jRange.count{
                
                subMat.set(i, j, self.get(parentI[i],parentJ[j]))
            }
        }
        
        return subMat
        
    }
    
    func sameSize(_ compareMatrix:Matrix)->Bool{
        
        if self.count == compareMatrix.count {
            return true
        }else{
            return false
        }
        
        
    }
    
    var description: String{
        
        var outString = ""
        
        var index = 0
        
        for i in 0..<rows{
            for j in 0..<columns{
                
               index = i*columns+j
                
                if type == .complex{
                    
                    var sign:String;
                    let b = imag![index]
                    
                    if(b < 0){
                        sign = "-"
                    }else{
                        sign = "+"
                    }

                    outString = outString + String(format: "%.3f", real[index])
                    outString = outString + sign + String(format: "%.3f", Swift.abs(b)) + "i \t"
                    
                }else{
                    outString = outString + String(format: "%.3f", real[index]) + "\t"

                }
            }
            
            outString = outString + "\n"

        }

        return outString
    }
    
    
    // Scaled from max and min of the original matrix
    func realUint8()->[UInt8]{
        
        var maximum = self.max
        let minimum = self.min
        
        
        if maximum.a == 0 {
            maximum.a = 1
        }
        
        if  maximum.b == 0 {
            maximum.b = 1
            
        }
        
        
        var outUint8:[UInt8] = [UInt8].init(repeating: UInt8(0), count:self.count)
        
        for i in 0..<real.count{
            
            if maximum.a-minimum.a > 0 {
            outUint8[i] = UInt8((real[i]-minimum.a)/(maximum.a-minimum.a)*255)
            }else{
                outUint8[i] = 0
            }
            
        }
        
        return outUint8
        
    }

    func floatImageRep()->NSBitmapImageRep{
        let floatSize = MemoryLayout<Float>.size

        // Create a bitmap image rep configured for 32-bit floating grayscale
        let bitmapFormatInfo = NSBitmapImageRep.Format(rawValue: NSBitmapImageRep.Format.floatingPointSamples.rawValue | NSBitmapImageRep.Format.thirtyTwoBitLittleEndian.rawValue)

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: columns,
            pixelsHigh: rows,
            bitsPerSample: 32,
            samplesPerPixel: 1,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: NSColorSpaceName.calibratedWhite,
            bitmapFormat: bitmapFormatInfo,
            bytesPerRow: columns * floatSize,
            bitsPerPixel: 32
        ) else {
            // As a fallback, return an empty 1x1 rep to avoid crashes
            return NSBitmapImageRep()
        }

        // Copy the raw bytes from `real` into the bitmap's backing buffer safely
        if let dest = bitmapRep.bitmapData {
            let byteCount = rows * columns * floatSize
            real.withUnsafeBytes { src in
                // Ensure we don't read beyond the source buffer
                let count = Swift.min(byteCount, src.count)
                if count > 0 {
                    memcpy(dest, src.baseAddress!, count)
                }
            }
        }

        return bitmapRep
    }
    
    func uInt8ImageRep()->NSBitmapImageRep?{
        
        var out = [UInt8].init()
        if self.count > 0 {
            let bounds = try! self.quantiles([0.02, 0.98])
            
            out = [UInt8].init(repeating: 0, count: real.count)
        
            if bounds[0] != bounds[1] {
                for (i, element) in real.enumerated() {
                    let mag = (element-bounds[0])/(bounds[1]-bounds[0])

                    if mag.isNaN || mag.isInfinite || mag < 0.0 {
                        continue
                    }

                    if mag >= 1.0 {
                        out[i] = 255
                    } else {
                        out[i] = UInt8(floor(mag * 255.0))
                    }
                }
            }
        }
        
        let bitmapRep = NSBitmapImageRep.init(bitmapDataPlanes: nil, pixelsWide: columns, pixelsHigh: rows, bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: NSColorSpaceName.calibratedWhite, bytesPerRow: columns*1, bitsPerPixel: 8)
        
        memmove(bitmapRep?.bitmapData, &out, out.count)

        return bitmapRep
    }
    
    deinit {
//        print("matrix deinit")
    }
    
}

//MARK: - Operations (new matrix)

func >(lhs:Matrix,rhs:Float) -> Matrix {
    
    let outMatrix = Matrix.init(lhs.rows, lhs.columns)
    
    for i in 0..<lhs.rows*lhs.columns{
        
        if lhs.real[i]>rhs{
            outMatrix.real[i] = 1.0
        }
    }
    
    return outMatrix
    
}

func <(lhs:Matrix,rhs:Float) -> Matrix {
    
    let outMatrix = Matrix.init(lhs.rows, lhs.columns)
    
    for i in 0..<lhs.rows*lhs.columns{
        
        if lhs.real[i]<rhs{
            outMatrix.real[i] = 1.0
        }
    }
    
    return outMatrix
    
}



func +(lhs:Matrix,rhs:Matrix) -> Matrix? {
   
    if let newMatrix = validOutputMatrix(lhs, rhs) as Matrix? {
        
        
        let length:vDSP_Length = UInt(newMatrix.count)
        var outReal = newMatrix.real
        
        
        vDSP_vadd(lhs.real, 1, rhs.real, 1, &outReal, 1, length)

        newMatrix.real = outReal;

        
        if newMatrix.type == .complex {
            
            var outImag = newMatrix.imag

            if let lhsImag = lhs.imag as [Float]? {
                vDSP_vadd(lhsImag, 1, outImag!, 1, &outImag!, 1, length)
            }
            
            if let rhsImag = rhs.imag as [Float]? {
                vDSP_vadd(rhsImag, 1, outImag!, 1, &outImag!, 1, length)
            }

        
        newMatrix.imag = outImag;
            
            
        }
        
        return newMatrix
        
        
    }else{
        return nil
    }
        
}

func -(lhs:Matrix,rhs:Matrix) -> Matrix? {
    
    if let newMatrix = validOutputMatrix(lhs, rhs) as Matrix? {
        
        
        let length:vDSP_Length = UInt(newMatrix.count)
        
        var outReal = newMatrix.real
        
        
        vDSP_vsub(rhs.real, 1, lhs.real, 1, &outReal, 1, length)
        
        newMatrix.real = outReal;
        
        
        if newMatrix.type == .complex {
            
            var outImag = newMatrix.imag
            
            if let lhsImag = lhs.imag as [Float]? {
                vDSP_vadd(lhsImag, 1, outImag!, 1, &outImag!, 1, length)
            }
            
            if let rhsImag = rhs.imag as [Float]? {
                vDSP_vsub(rhsImag, 1, outImag!, 1, &outImag!, 1, length)
            }
            
            
            newMatrix.imag = outImag;
            
            
        }
        
        return newMatrix
        
        
    }else{
        return nil
    }
    
    
    
}

func .*(lhs:Matrix,rhs:Matrix) -> Matrix?{
    
    if let newMatrix = validOutputMatrix(lhs, rhs) as Matrix? {
        
        let length:vDSP_Length = UInt(newMatrix.count)
        
        var outReal = newMatrix.real
        
        var temp1 = [Float](repeatElement(0.0, count: newMatrix.count))
        var temp2 = [Float](repeatElement(0.0, count: newMatrix.count))
        
        if lhs.complex && rhs.complex {
            
            var outImag = newMatrix.imag!
            
            // Calculate the real part
            
            vDSP_vmul(rhs.real, 1, lhs.real, 1, &temp1, 1, length)
            vDSP_vmul(rhs.imag!, 1, lhs.imag!, 1, &temp2, 1, length)

            vDSP_vsub(temp2, 1, temp1, 1, &outReal, 1, length)
            
            // Calculate the imag part

            
            vDSP_vmul(rhs.real, 1, lhs.imag!, 1, &temp1, 1, length)
            vDSP_vmul(rhs.imag!, 1, lhs.real, 1, &temp2, 1, length)
            
            vDSP_vadd(temp1, 1, temp2, 1, &outImag, 1, length)
            

            newMatrix.imag = outImag
            newMatrix.real = outReal

    
        }else if lhs.complex{
            
            var outImag = newMatrix.imag!


            vDSP_vmul(rhs.real, 1, lhs.real, 1, &outReal, 1, length)
            vDSP_vmul(rhs.real, 1, lhs.imag!, 1, &outImag, 1, length)

            
            newMatrix.imag = outImag
            newMatrix.real = outReal

        }else if rhs.complex{
            
            var outImag = newMatrix.imag!

            
            vDSP_vmul(rhs.real, 1, lhs.real, 1, &outReal, 1, length)
            vDSP_vmul(rhs.imag!, 1, lhs.real, 1, &outImag, 1, length)

            
            newMatrix.imag = outImag
            newMatrix.real = outReal

            
        }else{
            vDSP_vmul(lhs.real, 1, rhs.real, 1, &outReal, 1, length)
            
            newMatrix.real = outReal

        }
        
        return newMatrix
        
    }else{
        return nil
    }
}

//MARK: - Testing and convenience

func validOutputMatrix(_ mat1:Matrix, _ mat2:Matrix,_ operation:String? = "element-wise")->Matrix?{
    
    var newMatrix:Matrix

    if operation == "element-wise" {
        guard mat1.sameSize(mat2)  else {
            
            print("Matrices are not the same size for element-wise calculation")
            return nil
        }
        
        if mat1.complex || mat2.complex {
            newMatrix = Matrix(mat1.rows, mat1.columns, .complex)
            
        }else{
            newMatrix = Matrix(mat1.rows, mat1.columns)
        }
        
    }else{
        
        if mat1.complex || mat2.complex {
            newMatrix = Matrix(mat1.columns, mat2.rows, .complex)
            
        }else{
            newMatrix = Matrix(mat1.columns, mat2.rows)
        }

        
    }

    return newMatrix
}








