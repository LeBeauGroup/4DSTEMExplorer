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

class STEMDataController: NSObject {
    
    var filePath:URL?
    var width:Int = 0;
    var height:Int = 0;
    var imageSize:NSSize?
    var fh:FileHandle?
    var detectorSize:IntSize = empadSize
    
    var fileStream:InputStream?
    
    var patternPointer:UnsafeMutablePointer<Float32>?

    
    override init() {
        super.init()
    }
    
    func indexFor(_ i:Int,_ j:Int)->Int{
        
        return i*width+j
        
    }
    
    func readTiffInfo(_ imgSrc:CGImageSource){
        
        let props = CGImageSourceCopyPropertiesAtIndex(imgSrc, 0, nil) as! NSDictionary

        // {TIFF} key contains a dictionary with imageJ string containingthe width and height info (\nslices and \nframes)

        let tiffProps = props.value(forKey: "{TIFF}") as! NSDictionary
        let pixelWidth = props.value(forKey: "PixelWidth") as! Int
        let pixelHeight = props.value(forKey: "PixelHeight") as! Int
        
        
        detectorSize = IntSize(width: pixelWidth, height: pixelHeight)
        
        if let imageDescription = tiffProps.value(forKey: "ImageDescription") as? String{
            
            var width:String = ""
            var height:String = ""
            
            let patWidth = "(?<=\\nslices=)[0-9]+"
            let patHeight = "(?<=\\nframes=)[0-9]+"
            
            
            var regex = try! NSRegularExpression(pattern: patWidth, options: [])
            var matches = regex.matches(in: imageDescription, options: [], range: NSRange(location: 0, length: imageDescription.count))
            
            
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
            
            self.width = Int(width)!
            self.height = Int(height)!
        }
        
    }
    
    func openTIFF(url:URL){
        
        let options:NSDictionary = NSDictionary.init(object: kCFBooleanTrue, forKey: kCGImageSourceShouldAllowFloat as! NSCopying)

        let myImageSource = CGImageSourceCreateWithURL(url as CFURL, options);
        
        readTiffInfo(myImageSource!)

        let imagePixelCount = CGImageSourceGetCount(myImageSource!)
        
        let patternPixels = Int((detectorSize.width)*(detectorSize.height))
        let floatSize = MemoryLayout<Float32>.size
        let imagePixels = self.width*self.height
        
        let nc = NotificationCenter.default
        
        
        if self.patternPointer != nil{
            self.patternPointer?.deallocate(capacity: patternPixels*imagePixels*floatSize)
        }
        
        self.patternPointer = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels*imagePixels*floatSize)
        
        let fracComplete = Int(Double(imagePixels)*0.05)

        DispatchQueue.global(qos: .userInteractive).async {

            for i in 0..<imagePixelCount{
                    autoreleasepool{

                        let newImage = CGImageSourceCreateImageAtIndex(myImageSource!, i, options)
                    
                    
                        let newDataProvider = newImage?.dataProvider
                        
                        let newData = newDataProvider!.data! as NSData
                        
                        let rawBuffer = newData.bytes//(newData as NSData).bytes
                        
                        let floatBuffer =  rawBuffer.bindMemory(to: Float32.self, capacity: patternPixels)
                        
                        
                        let newPointer = self.patternPointer! + i*patternPixels
                        
                        newPointer.assign(from: floatBuffer, count: patternPixels)
                        
                        
                        
                        if(i % fracComplete == 0 ){
                            DispatchQueue.main.async {
                                nc.post(name: Notification.Name("updateProgress"), object:i)
                            }
                        }
                    }// autoreleasepool
                }// for
            
            
                DispatchQueue.main.async {
                    nc.post(name: Notification.Name("finishedLoadingData"), object: 0)
                }
            }
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

    
    func formattedMatrixData(){
        
        let ext = filePath!.pathExtension
        
        let uti = UTTypeCreatePreferredIdentifierForTag(
            kUTTagClassFilenameExtension,
            ext as CFString,
            nil)
        
        if UTTypeConformsTo((uti?.takeRetainedValue())!, kUTTypeTIFF) {
            self.openTIFF(url: self.filePath!)
            return
        }
        
        self.openFileHandle(url: self.filePath!)
        
        self.detectorSize = empadSize
        
        self.detectorSize.height -= 2
        
        DispatchQueue.global(qos: .userInteractive).async {

//            self.fileStream?.open()


            let empadPixels = empadSize.width * empadSize.height
            let patternPixels = self.detectorSize.width*self.detectorSize.height
            let floatSize = MemoryLayout<Float32>.size

            let imagePixels = self.width * self.height

            let nc = NotificationCenter.default
            
            if self.patternPointer != nil{
                self.patternPointer?.deallocate(capacity: patternPixels*imagePixels*floatSize)
            }
            
            self.patternPointer = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels*imagePixels*floatSize)
            
            let fracComplete = Int(Double(imagePixels)*0.05)

            let empadBitCount = empadPixels*floatSize
            let patternBitCount = patternPixels*floatSize
        
            //
            
            for i in stride(from: 0, to: self.height, by: 1){
                
                autoreleasepool{
                    
                var newData:Data
                var rawBuffer:UnsafeRawPointer
                var floatBuffer:UnsafePointer<Float32>

                for j in stride(from: 0, to: self.width, by: 1){
                                        
                    let curImagePixel = (i*self.width+j)
                    
                    let patternIndex = curImagePixel*empadBitCount
                    
                    self.fh?.seek(toFileOffset: UInt64(patternIndex))
                    newData = (self.fh?.readData(ofLength: patternBitCount))!
                    
                    rawBuffer = (newData as NSData).bytes
                    
                    floatBuffer =  rawBuffer.bindMemory(to: Float32.self, capacity: patternPixels)
                    
                    let newPointer = self.patternPointer! + curImagePixel*(patternPixels)
                
                    newPointer.assign(from: floatBuffer, count: patternPixels)
                    
                    if(curImagePixel % fracComplete == 0 ){
                        DispatchQueue.main.async {
                            nc.post(name: Notification.Name("updateProgress"), object:curImagePixel)
                        }
                    }
                    }// forj
                } //autorelease
                    
            } //fori
            
//            while (self.fileStream?.hasBytesAvailable)!{
//
//                let read =  self.fileStream?.read(buffer, maxLength: count)
////                print(read)
//
//                    if (read == 0) {
//                        break  // added
//                    }
//
//                let newPointer = pointer + i*count
//                newPointer.assign(from: buffer, count: count)
//
//                i += 1
//
//
//                if(i % fracComplete == 0 ){
//                    DispatchQueue.main.async {
//                        nc.post(name: Notification.Name("updateProgress"), object: i)
//                    }
//                }
//
//            } //while
            
//            buffer.deinitialize()

            // recast as a float pointer
//            self.patternPointer = UnsafeMutableRawPointer(pointer)
//                .bindMemory(to: Float32.self, capacity: patternPixels*imagePixels)
            
            DispatchQueue.main.async {
                nc.post(name: Notification.Name("finishedLoadingData"), object: 0)
            }
        } // async queue
        
        
    }
    
//    func detectImage(_ detector:Detector, strideLength: Int = 1, lrup_xy:Int = 0) -> Matrix{
//
//        let detectorMask = detector.detectorMask()
//        let type = detector.type
//
//        var outMatrix:Matrix?
//
//        if type == DetectorType.integrating{
//            outMatrix = integrating(detectorMask, strideLength)
//        }else if type == DetectorType.com{
//            outMatrix = com(detectorMask, strideLength, lrup_xy)
//        }else if type == DetectorType.dpc{
//
//            let indices = Matrix.init(meshIndicesAlong: lrup_xy, detectorSize.height-2, detectorSize.width)
//
//            let dpc_mask = m
//
//        }else{
//            outMatrix = integrating(detectorMask, strideLength)
//
//        }
//
//        return (outMatrix)!
//
//    }
    
    func dpc(_ detector:Detector,strideLength:Int = 1, lrud:Int = 0)->Matrix{
        
        let mask = detector.detectorMask()
        let group = DispatchGroup()

        group.enter()
        
        
        let indices = Matrix.init(meshIndicesAlong: lrud, detectorSize.height, detectorSize.width)
        
        let ldMask:Matrix?
        let ruMask:Matrix?


        if lrud == 1{
             ldMask = indices < Float(detector.center.x)
             ruMask = indices > Float(detector.center.x)
            

        }else{
             ldMask = indices > Float(detector.center.y)
            ruMask = indices < Float(detector.center.y)

        }
        
        let strideWidth = width/strideLength
        let strideHeight = height/strideLength
        
        //        let imageInts = self.integrating(mask, strideLength)
        
        var outArray = [Float].init(repeating: 0.0, count: strideWidth*strideHeight)
        
        DispatchQueue.global(qos: .userInteractive).sync {
            
            let patternPixels = UInt(detectorSize.width*(detectorSize.height-2))

            let ldMaskProduct = UnsafeMutablePointer<Float32>.allocate(capacity: Int(patternPixels))
            let ruMaskProduct = UnsafeMutablePointer<Float32>.allocate(capacity: Int(patternPixels))

            let ruProduct = UnsafeMutablePointer<Float32>.allocate(capacity: Int(patternPixels))

            let ldProduct = UnsafeMutablePointer<Float32>.allocate(capacity: Int(patternPixels))

            
            vDSP_vmul(mask.real, 1, ldMask!.real, 1, ldMaskProduct, 1, patternPixels)
            vDSP_vmul(mask.real, 1, ruMask!.real, 1, ruMaskProduct, 1, patternPixels)
            
            let ldPixelSum = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
            let ruPixelSum = UnsafeMutablePointer<Float32>.allocate(capacity: 1)

            var pos = 0
            
            for i in stride(from: 0, to: self.height, by: strideLength){
                for j in stride(from: 0, to: self.width, by: strideLength){
                    
                    let nextPatternPointer = self.patternPointer!+(i*self.width+j)*detectorSize.width*detectorSize.height
                    
                    vDSP_vmul(ldMaskProduct, 1, nextPatternPointer, 1, ldProduct, 1, patternPixels)
                    vDSP_vmul(ruMaskProduct, 1, nextPatternPointer, 1, ruProduct, 1, patternPixels)
                    
//                    vDSP_vmul(maskPatternProduct, 1, indices.real, 1, indexWeighted, 1, patternPixels)
                    
                    vDSP_sve(ldProduct, 1, ldPixelSum, patternPixels)
                    vDSP_sve(ruProduct, 1, ruPixelSum, patternPixels)

                    
                    let dpcSignal = ldPixelSum.pointee-ruPixelSum.pointee
                    
                    outArray[pos] = dpcSignal
                    pos += 1
                }
            }

            // need to deallocate
            
            group.leave()
            
        }
        
        
        group.wait()
        
        return Matrix.init(array: outArray, strideHeight, strideWidth)
    }
    
    func com(_ detector:Detector,strideLength:Int = 1, xy:Int = 0)->Matrix{
    
        
        let mask = detector.detectorMask()
        
        let group = DispatchGroup()
        group.enter()
    
        let strideWidth = width/strideLength
        let strideHeight = height/strideLength
        
        var outArray = [Float].init(repeating: 0.0, count: strideWidth*strideHeight)

        let indices = Matrix.init(meshIndicesAlong: xy, detectorSize.height-2, detectorSize.width)

        DispatchQueue.global(qos: .userInteractive).sync {
        
            let patternPixels = UInt(detectorSize.width*(detectorSize.height-2))
            let maskPatternProduct = UnsafeMutablePointer<Float32>.allocate(capacity: Int(patternPixels))
            let indexWeighted = UnsafeMutablePointer<Float32>.allocate(capacity: Int(patternPixels))
            
            let pixelSum = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
            let empadPixels = detectorSize.height*detectorSize.width
            
            var pos = 0
            
            for i in stride(from: 0, to: self.height, by: strideLength){
                for j in stride(from: 0, to: self.width, by: strideLength){
                
                    let nextPatternPointer = self.patternPointer!+(i*self.width+j)*empadPixels
                    
                    vDSP_vmul(mask.real, 1, nextPatternPointer, 1, maskPatternProduct, 1, patternPixels)
                    
                    vDSP_vmul(maskPatternProduct, 1, indices.real, 1, indexWeighted, 1, patternPixels)
                    
                    vDSP_sve(maskPatternProduct, 1, pixelSum, patternPixels)

                    let intSum = pixelSum.pointee
                    
            
                    vDSP_sve(indexWeighted, 1, pixelSum, patternPixels)

                    outArray[pos] = pixelSum.pointee/intSum
                    pos += 1
                }
            }
            maskPatternProduct.deallocate(capacity: detectorSize.width*detectorSize.height)

            group.leave()

        }
        
        
        group.wait()
        
        return Matrix.init(array: outArray, strideHeight, strideWidth)
    }
    
    func integrating(_ detector:Detector,strideLength:Int = 1) ->Matrix{
        
        let mask = detector.detectorMask()
        
//        let group = DispatchGroup()
//        group.enter()
        
        let strideWidth = width/strideLength
        let strideHeight = height/strideLength
        
        var outArray = [Float].init(repeating: 0.0, count: strideWidth*strideHeight)
        
//        DispatchQueue.global(qos: .default).sync {
        
            let patternPixels = UInt(detectorSize.width*(detectorSize.height-2))
            let c = UnsafeMutablePointer<Float32>.allocate(capacity: Int(patternPixels))

            let pixelSum = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
            
            var pos = 0
        
            for i in stride(from: 0, to: self.height, by: strideLength){
                
                for j in stride(from: 0, to: self.width, by: strideLength){
                    
                    let nextPatternPointer = self.patternPointer!+(i*self.width+j)*detectorSize.width*detectorSize.height
                    
                    
                    vDSP_vmul(mask.real, 1, nextPatternPointer, 1, c, 1, patternPixels)
                    vDSP_sve(c, 1, pixelSum, patternPixels)
                    
                    outArray[pos] = pixelSum[0]
                    
                    pos += 1
                }
            }
            
            c.deallocate(capacity: detectorSize.width*detectorSize.height)
            
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
