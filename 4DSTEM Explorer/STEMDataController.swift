//
//  STEMData.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/21/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Cocoa
import Accelerate

enum FileReadError: Error {
    case invalidTiff
    case invalidRaw
    case invalidDimensions
}


protocol STEMDataControllerDelegate:class {
    func didFinishLoadingData()
}
protocol STEMDataControllerProgressDelegate:class {
    func didFinishLoadingData()
}

class STEMDataController: NSObject {
    
    var filePath:URL?
    var imageSize:IntSize = IntSize(width: 0, height: 0)
    var fh:FileHandle?
    
    weak var delegate:STEMDataControllerDelegate?
    weak var progressdelegate:STEMDataControllerProgressDelegate?
    
    var detectorSize:IntSize = empadSize
    var patternSize:IntSize = empadSize
    
    var patternPixels:Int{
        get{
            return Int(patternSize.width * patternSize.height)
        }
    }
    
    var imagePixels:Int{
        get{
            return Int(imageSize.width*imageSize.height)
        }
    }
    
    var detectorPixels:Int{
        get{
            return Int(detectorSize.width*detectorSize.height)
        }
    }
    
    var fileStream:InputStream?
    
    var patternPointer:UnsafeMutablePointer<Float32>?

    
    override init() {
        super.init()
    }
    
    func indexFor(_ i:Int,_ j:Int)->Int{
        
        return i*imageSize.width+j
        
    }
    
    func pattern(_ i:Int, _ j:Int)->Matrix?{
        
        var matrix:Matrix?
        
        if patternPointer != nil{
            
            var patternIndex = 0
            
            if i >= 0 && j >= 0{
                patternIndex =  self.indexFor(i, j)
            }
        
            let selectedPatternPointer = patternPointer! + (patternPixels)*patternIndex
            
            matrix = Matrix.init(pointer: selectedPatternPointer, patternSize.height, patternSize.width)
        }
        
        return matrix
        
    }
    
    func readTiffInfo(_ props:[String:Any]) throws{
        
        // {TIFF} key contains a dictionary with imageJ string containing the width and height info (\nslices and \nframes)
        
        let pixelWidth:Int
        let pixelHeight:Int

        if let test = props["ImageWidth"] as? Int32{
            pixelWidth = Int(test)
        }else{
            throw FileReadError.invalidTiff
        }
        
        if let test = props["ImageHeight"] as? Int32{
            pixelHeight = Int(test)

        }else{
            throw FileReadError.invalidTiff
        }

        
        if let imageDescription = props["ImageDescription"] as? String{
            
            
            detectorSize = IntSize(width: pixelWidth, height: pixelHeight)
            patternSize = detectorSize
            
            var width:String = ""
            var height:String = ""
            
            let patWidth = "(?<=\\nslices=)[0-9]+"
            let patHeight = "(?<=\\nframes=)[0-9]+"
            
            
            var regex = try! NSRegularExpression(pattern: patWidth, options: [])
            var matches = regex.matches(in: imageDescription, options: [], range: NSRange(location: 0, length: imageDescription.count))
            
            if matches.count == 0{
                throw FileReadError.invalidTiff
            }

            
            if let match = matches.first {
                let range = match.range(at:0)
                if let swiftRange = Range(range, in: imageDescription as String) {
                    width = String(imageDescription[swiftRange])
                }
            }
            
            regex = try! NSRegularExpression(pattern: patHeight, options: [])
            matches = regex.matches(in: imageDescription, options: [], range: NSRange(location: 0, length: imageDescription.count))
            
            
            if let match = matches.first {
                let range = match.range(at:0)
                if let swiftRange = Range(range, in: imageDescription as String) {
                    height = String(imageDescription[swiftRange])
                }
            }
            
            self.imageSize.width = Int(width)!
            self.imageSize.height = Int(height)!
            
        }else{
            throw FileReadError.invalidTiff
        }
        
    }
    
    func openTIFF(url:URL) throws {
        
        let options:NSDictionary = NSDictionary.init(object: kCFBooleanTrue, forKey: kCGImageSourceShouldAllowFloat as! NSCopying)

    
        let myImageSource = CGImageSourceCreateWithURL(url as CFURL, options);

        // Read the header info to get the width, height, image properties
        
        let props:[String:Any]
        
        do{
            try props =  TIFFheader(url)
            
        } catch{
            throw FileReadError.invalidTiff
            
        }
        
        do{
            try self.readTiffInfo(props)
        }catch{
            
            throw FileReadError.invalidTiff

        }

        let patternPixels = self.patternPixels
        let floatSize = MemoryLayout<Float32>.size
        let imagePixels = self.imagePixels
        
        let patternBitCount = patternPixels*floatSize
        
        let firstImageOffset = props["FirstImageOffset"] as! UInt64
        
        let nc = NotificationCenter.default
        
        DispatchQueue.global(qos: .userInteractive).async {
            self.openFileHandle(url: url)

        if self.patternPointer != nil{
            self.patternPointer?.deallocate(capacity: patternPixels*imagePixels*floatSize)
        }
        
        self.patternPointer = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels*imagePixels*floatSize)
        
        let fracComplete = Int(Double(imagePixels)*0.05)

            
            self.fh?.seek(toFileOffset: firstImageOffset)

            for i in stride(from: 0, to: self.imageSize.height, by: 1){
                
                autoreleasepool{
                    
                    for j in stride(from: 0, to: self.imageSize.width, by: 1){
                        
                        let curImagePixel = (i*self.imageSize.width+j)
//                      let patternOffset = UInt64(curImagePixel*detectorBitCount)
                        
                        
                        let newPointer = self.patternPointer! + curImagePixel*(patternPixels)
                    
                        
                        var imageData = self.fh?.readData(ofLength: patternBitCount)
                        
                        
                        imageData?.withUnsafeMutableBytes { (i32ptr: UnsafeMutablePointer<UInt32>) in
                            for i in 0..<patternPixels {
                                i32ptr[i] =  i32ptr[i].byteSwapped
                            }
                        }
                        

                        
                        imageData?.withUnsafeMutableBytes{(ptr: UnsafeMutablePointer<Float32>) in
                            
                           newPointer.assign(from: ptr, count: patternPixels)
                            
                        }
                        
                        
                        if(curImagePixel % fracComplete == 0 ){
                            DispatchQueue.main.async {
                                nc.post(name: Notification.Name("updateProgress"), object:curImagePixel)
                            }
                        }
                    }// forj
                } //autorelease
                
            } //fori
            
//            for i in 0..<imagePixels{
//                    autoreleasepool{
//
//                        let newImage = CGImageSourceCreateImageAtIndex(myImageSource!, i, options)
//                    
//                    
//                        let newDataProvider = newImage?.dataProvider
//                        
//                        let newData = newDataProvider!.data! as NSData
//                        
//                        let rawBuffer = newData.bytes//(newData as NSData).bytes
//                        
//                        let floatBuffer =  rawBuffer.bindMemory(to: Float32.self, capacity: patternPixels)
//                        
//                        
//                        let newPointer = self.patternPointer! + i*patternPixels
//                        
//                        newPointer.assign(from: floatBuffer, count: patternPixels)
//                        
//                        
//                        
//                        if(i % fracComplete == 0 ){
//                            DispatchQueue.main.async {
//                                nc.post(name: Notification.Name("updateProgress"), object:i)
//                            }
//                        }
//                    }// autoreleasepool
//                }// for
            
            
            
            DispatchQueue.main.sync {
                self.delegate?.didFinishLoadingData()
                self.progressdelegate?.didFinishLoadingData()
            }
        }
            

//        nc.post(name: Notification.Name("finishedLoadingData"), object: 0)
    }
    
    func openFileHandle(url:URL){
       
        let bufferStream:FileHandle?
        
        do{
            try bufferStream = FileHandle.init(forReadingFrom: url)
            self.fh = bufferStream
            
        }catch{
            print("error creating file handle")
        }
    }

    
    func formatMatrixData() throws {
        
        self.openFileHandle(url: self.filePath!)
        
        self.detectorSize = empadSize
        self.patternSize = detectorSize
        patternSize.height -= 2
        
        let detectorPixels = self.detectorPixels
        let patternPixels = self.patternPixels
        let floatSize = MemoryLayout<Float32>.size
        let imagePixels = self.imagePixels
        
        let dataPixels = patternPixels*imagePixels*floatSize
        
        let detectorBitCount = detectorPixels*floatSize
        let patternBitCount = patternPixels*floatSize
        
        var fileSize = 0
        
        do{
            let attrib = try FileManager.default.attributesOfItem(atPath: (filePath?.path)!)
            fileSize = attrib[.size] as! Int

        }catch{
            throw FileReadError.invalidRaw
        }
        if  fileSize != detectorPixels*imagePixels*floatSize {
                throw FileReadError.invalidDimensions
        }
        
        DispatchQueue.global(qos: .background).async {

            let nc = NotificationCenter.default
            
            if self.patternPointer != nil{
                self.patternPointer?.deallocate(capacity: dataPixels)
            }
            
            self.patternPointer = UnsafeMutablePointer<Float32>.allocate(capacity: dataPixels)
            
            let fracComplete = Int(Double(imagePixels)*0.05)


        
            //
            
            for i in stride(from: 0, to: self.imageSize.height, by: 1){
                
                autoreleasepool{
                    
                var newData:Data
                var rawBuffer:UnsafeRawPointer
                var floatBuffer:UnsafePointer<Float32>

                for j in stride(from: 0, to: self.imageSize.width, by: 1){
                                        
                    let curImagePixel = (i*self.imageSize.width+j)
                    
                    let patternOffset = curImagePixel*detectorBitCount
                    
                    self.fh?.seek(toFileOffset: UInt64(patternOffset))
                    
                    newData = (self.fh?.readData(ofLength: patternBitCount))!
                    
                
//                    rawBuffer = (newData as NSData).bytes
//
//                    floatBuffer =  rawBuffer.bindMemory(to: Float32.self, capacity: patternPixels)
//
                    let newPointer = self.patternPointer! + curImagePixel*(patternPixels)
//
//                    newPointer.assign(from: floatBuffer, count: patternPixels)
                    
                    newData.withUnsafeMutableBytes{(ptr: UnsafeMutablePointer<Float32>) in
                        
                        newPointer.assign(from: ptr, count: patternPixels)
                        
                    }
                    
                    if(curImagePixel % fracComplete == 0 ){
                        DispatchQueue.main.async {
                            nc.post(name: Notification.Name("updateProgress"), object:curImagePixel)
                        }
                    }
                    }// forj
                } //autorelease
                    
            } //fori
            
            
            DispatchQueue.main.async {
                self.delegate?.didFinishLoadingData()
                self.progressdelegate?.didFinishLoadingData()
            }
        } // async queue
        
        
    }
    

    func averagePattern(rect:NSRect)->Matrix{
        
        let patternPixels = self.patternPixels
        
        let adder = [Float].init(repeating: 0.0, count: patternPixels)
        let adderPointer =  UnsafeMutablePointer(mutating: adder)
        
        let starti = Int(rect.origin.y)
        let startj = Int(rect.origin.x)
        
        let endi = starti + Int(rect.size.height)
        let endj = startj + Int(rect.size.width)
        
        var strideDirectioni = 1
        var strideDirectionj = 1
        
        if starti > endi{
            strideDirectioni = -1
        }

        if startj > endj{
            strideDirectionj = -1
        }
        
        
        var patternCount = 0
        
        for i in stride(from: starti, through: endi, by: strideDirectioni){
            
            for j in stride(from: startj, through: endj, by: strideDirectionj){
                
                let nextPatternPointer = self.patternPointer!+(i*self.imageSize.width+j)*patternPixels
                

                vDSP_vadd(adderPointer, 1, nextPatternPointer, 1, adderPointer, 1, UInt(patternPixels))
                
                patternCount += 1
                }
        }
        
        
        // +1 may be needed for correct average to be inclusive
        var avgScaleFactor = 1.0/Float(patternCount)
        
        vDSP_vsmul(adderPointer, 1, &avgScaleFactor, adderPointer, 1, UInt(patternPixels))
        
        return Matrix.init(array: adder, patternSize.height, patternSize.width)

        
    }
    
    func dpc(_ detector:Detector,strideLength:Int = 1, lrud:Int = 0)->Matrix{
        
        let mask = detector.detectorMask()

        let indices = Matrix.init(meshIndicesAlong: lrud, patternSize.height, patternSize.width)
        
        let ldMask:Matrix?
        let ruMask:Matrix?

        if lrud == 1{
             ldMask = indices < Float(detector.center.x)
             ruMask = indices > Float(detector.center.x)
            

        }else{
             ldMask = indices > Float(detector.center.y)
            ruMask = indices < Float(detector.center.y)

        }
        
        let strideWidth = imageSize.width/strideLength
        let strideHeight = imageSize.height/strideLength
        
        //        let imageInts = self.integrating(mask, strideLength)
        
        var outArray = [Float].init(repeating: 0.0, count: strideWidth*strideHeight)
        
        let patternPixels = self.patternPixels

        let ldMaskProduct = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
        let ruMaskProduct = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)

        let ruProduct = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
        let ldProduct = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)

        vDSP_vmul(mask.real, 1, ldMask!.real, 1, ldMaskProduct, 1, UInt(patternPixels))
        vDSP_vmul(mask.real, 1, ruMask!.real, 1, ruMaskProduct, 1, UInt(patternPixels))
        
        let ldPixelSum = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
        let ruPixelSum = UnsafeMutablePointer<Float32>.allocate(capacity: 1)

        var pos = 0
        
        for i in stride(from: 0, to: self.imageSize.height, by: strideLength){
            for j in stride(from: 0, to: self.imageSize.width, by: strideLength){
                
                let nextPatternPointer = self.patternPointer!+(i*self.imageSize.width+j)*patternPixels
                
                vDSP_vmul(ldMaskProduct, 1, nextPatternPointer, 1, ldProduct, 1, UInt(patternPixels))
                vDSP_vmul(ruMaskProduct, 1, nextPatternPointer, 1, ruProduct, 1, UInt(patternPixels))
                
//                    vDSP_vmul(maskPatternProduct, 1, indices.real, 1, indexWeighted, 1, patternPixels)
                
                vDSP_sve(ldProduct, 1, ldPixelSum, UInt(patternPixels))
                vDSP_sve(ruProduct, 1, ruPixelSum, UInt(patternPixels))

                
                let dpcSignal = ldPixelSum.pointee-ruPixelSum.pointee
                
                outArray[pos] = dpcSignal
                pos += 1
            }
            // need to deallocate
            
            
        }
        
        return Matrix.init(array: outArray, strideHeight, strideWidth)
    }
    
    func com(_ detector:Detector,strideLength:Int = 1, xy:Int = 0)->Matrix{
    
        
        let mask = detector.detectorMask()
        
        let group = DispatchGroup()
        group.enter()
    
        let strideWidth = imageSize.width/strideLength
        let strideHeight = imageSize.height/strideLength
        
        var outArray = [Float].init(repeating: 0.0, count: strideWidth*strideHeight)

        let indices = Matrix.init(meshIndicesAlong: xy, patternSize.height, patternSize.width)

        DispatchQueue.global(qos: .userInteractive).sync {
        
            let patternPixels = self.patternPixels
            let maskPatternProduct = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
            let indexWeighted = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
            
            let pixelSum = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
            
            var pos = 0
            
            for i in stride(from: 0, to: self.imageSize.height, by: strideLength){
                for j in stride(from: 0, to: self.imageSize.width, by: strideLength){
                
                    let nextPatternPointer = self.patternPointer!+(i*self.imageSize.width+j)*patternPixels
                    
                    vDSP_vmul(mask.real, 1, nextPatternPointer, 1, maskPatternProduct, 1, UInt(patternPixels))
                    
                    vDSP_vmul(maskPatternProduct, 1, indices.real, 1, indexWeighted, 1, UInt(patternPixels))
                    
                    vDSP_sve(maskPatternProduct, 1, pixelSum, UInt(patternPixels))

                    let intSum = pixelSum.pointee
                    
            
                    vDSP_sve(indexWeighted, 1, pixelSum, UInt(patternPixels))

                    outArray[pos] = pixelSum.pointee/intSum
                    pos += 1
                }
            }
            maskPatternProduct.deallocate(capacity: patternPixels)

            group.leave()

        }
        
        
        group.wait()
        
        return Matrix.init(array: outArray, strideHeight, strideWidth)
    }
    
    func integrating(_ detector:Detector,strideLength:Int = 1) ->Matrix{
        
        let mask = detector.detectorMask()
        
//        let group = DispatchGroup()
//        group.enter()
        
        let strideWidth = imageSize.width/strideLength
        let strideHeight = imageSize.height/strideLength
        
        var outArray = [Float].init(repeating: 0.0, count: strideWidth*strideHeight)
        
//        DispatchQueue.global(qos: .default).sync {
        
//            let patternPixels = UInt(self.patternPixels)
        let c = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)

            let pixelSum = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
            
            var pos = 0
        
            for i in stride(from: 0, to: self.imageSize.height, by: strideLength){
                for j in stride(from: 0, to: self.imageSize.width, by: strideLength){
                    
                    let nextPatternPointer = self.patternPointer!+(i*self.imageSize.width+j)*patternSize.width*patternSize.height
                    
                    vDSP_vmul(mask.real, 1, nextPatternPointer, 1, c, 1, UInt(patternPixels))
                    
                    vDSP_sve(c, 1, pixelSum, UInt(patternPixels))
                    
                    outArray[pos] = pixelSum[0]
                    
                    pos += 1
                }
            }
            
            c.deallocate(capacity: patternPixels)
            
//            group.leave()
//        }
//        
//        group.wait()
//        
        
        return Matrix.init(array: outArray, strideHeight, strideWidth)
        
    }
    
    
    
    deinit {
        fh?.closeFile()
        patternPointer?.deinitialize()
    }
        
        
        

        
        
    

}
