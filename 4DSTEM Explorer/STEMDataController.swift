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
    func cancel(_ sender:Any)
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
    
    var dwi: DispatchWorkItem?


    
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
    
//    import Accelerate
//    import UniformTypeIdentifiers

    func openFile(url: URL) throws {
        let ext = url.pathExtension
        let uti = UTTypeCreatePreferredIdentifierForTag(
            kUTTagClassFilenameExtension,
            ext as CFString,
            nil
        )

        let isTIFF = UTTypeConformsTo((uti?.takeRetainedValue())!, kUTTypeTIFF)
        let isMRC = url.pathExtension == "mrc"

        let dataType: Any.Type
        var firstImageOffset: UInt64
        var additionalRows:Int = 0
    
        if isTIFF {
            dataType = Float32.self
            let props: [String: Any]
            do {
                try props = TIFFheader(url)
                try readTiffInfo(props)
                firstImageOffset = props["FirstImageOffset"] as! UInt64
            } catch {
                throw FileReadError.invalidTiff
            }
        } else if isMRC {
            dataType = Int16.self
            let (header, feiHeader) = try loadMRCHeader(from: url)
            firstImageOffset = UInt64(1024 + header!.nsymbt)
            self.detectorSize = IntSize(width: Int(header!.nx), height: Int(header!.nx))
            self.patternSize = detectorSize
            self.imageSize = IntSize(width: Int(feiHeader!.scanSizeRight), height: Int(feiHeader!.scanSizeBottom))
        } else {
            dataType = Float32.self
            firstImageOffset = 0
            self.detectorSize = empadSize
            self.patternSize = detectorSize
            patternSize.height -= 2
            additionalRows = 2
        }

        let elementSize: Int
        switch dataType {
        case is Float32.Type:
            elementSize = MemoryLayout<Float32>.size
        case is Int16.Type:
            elementSize = MemoryLayout<Int16>.size
        default:
            elementSize = MemoryLayout<Float32>.size
        }

        let detectorPixels = self.detectorPixels
        let patternPixels = self.patternPixels
        let imagePixels = self.imagePixels
        let detectorBitCount = detectorPixels * elementSize

        if !isTIFF && !isMRC {
            do {
                let attrib = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attrib[.size] as! Int
                if fileSize != detectorPixels * imagePixels * elementSize {
                    throw FileReadError.invalidDimensions
                }
            } catch {
                throw FileReadError.invalidRaw
            }
        }

        
        let patternByteCount = patternPixels * elementSize
        let dataTypeIsInt16 = dataType == Int16.self
        let width = self.patternSize.width
        var height = self.patternSize.height
        let totalPatternPixels = height*(width + additionalRows)
    
        
        let totalImages = self.imageSize.width * self.imageSize.height
        let batchSize = 64
        let totalBatches = (totalImages + batchSize - 1) / batchSize


        let nc = NotificationCenter.default

        dwi = DispatchWorkItem {
            self.openFileHandle(url: url)

            self.patternPointer?.deallocate()
            self.patternPointer = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels * totalImages)

            let floatTempBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels * batchSize)
            defer { floatTempBuffer.deallocate() }

            let int16TempBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: patternPixels * batchSize)
            defer { int16TempBuffer.deallocate() }

            self.fh?.seek(toFileOffset: firstImageOffset)
            let fracComplete = max(1, Int(Double(totalImages) * 0.05))

            for batchIndex in 0..<totalBatches {
                if self.dwi?.isCancelled ?? false { break }

                let imagesInBatch = min(batchSize, totalImages - batchIndex * batchSize)
                let readSize = imagesInBatch * (totalPatternPixels) * elementSize

                guard let batchData = self.fh?.readData(ofLength: readSize) else { continue }

                if dataTypeIsInt16 {
                    batchData.withUnsafeBytes { raw in
                        let int16Ptr = raw.bindMemory(to: Int16.self).baseAddress!
                        vDSP_vflt16(int16Ptr, 1, floatTempBuffer, 1, vDSP_Length(imagesInBatch * totalPatternPixels))
                    }
                } else {
                    batchData.withUnsafeBytes { raw in
                        let float32Ptr = raw.bindMemory(to: Float32.self).baseAddress!
                        floatTempBuffer.update(from: float32Ptr, count: imagesInBatch * totalPatternPixels)
                    }
                }

                for img in 0..<imagesInBatch {
                    let globalIndex = batchIndex * batchSize + img
                    if globalIndex >= totalImages { break }

                    let outPointer = self.patternPointer! + globalIndex * patternPixels
                    let srcPointer = floatTempBuffer + img * (totalPatternPixels)

                    for row in 0..<height {
                        let destRow = height - row - 1
                        let dst = outPointer + destRow * width
                        let src = srcPointer + row * width
                        dst.update(from: src, count: width)
                    }

                    if globalIndex % fracComplete == 0 {
                        DispatchQueue.main.async {
                            nc.post(name: Notification.Name("updateProgress"), object: globalIndex)
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                self.delegate?.didFinishLoadingData()
                self.progressdelegate?.didFinishLoadingData()
            }
        }

        DispatchQueue.global().async(execute: dwi!)
    }
    
//    func openFile(url:URL) throws{
//        
//        let ext = url.pathExtension
//
//        let uti = UTTypeCreatePreferredIdentifierForTag(
//            kUTTagClassFilenameExtension,
//            ext as CFString,
//            nil)
//        
//        let dataType:Any.Type
//        
//        var firstImageOffset:UInt64
//        
//        let isTIFF = UTTypeConformsTo((uti?.takeRetainedValue())!, kUTTypeTIFF)
//        let isMRC = url.pathExtension == "mrc"
//        
//        
////        // Example usage
////        do {
////            let fileURL = URL(fileURLWithPath: "/path/to/your_file.mrc") // Replace with real path
////            let mrcVolume = try loadMRCFile(from: fileURL)
////            
////            print("MRC file loaded successfully.")
////            print("Dimensions (nx, ny, nz): (\(mrcVolume.header.nx), \(mrcVolume.header.ny), \(mrcVolume.header.nz))")
////            print("Mode: \(mrcVolume.header.mode)")
////            print("Data array length: \(mrcVolume.volumeData.count)")
////            // You can now process `mrcVolume.volumeData` as needed.
////            
////        } catch {
////            print("Error reading MRC file: \(error)")
////        }
//        
//        if  isTIFF{
//            dataType =  Float32.self
//            
//            let props:[String:Any]
//            
//            do{
//                try props =  TIFFheader(url)
//                try readTiffInfo(props)
//                firstImageOffset = props["FirstImageOffset"] as! UInt64
//                
//            }catch{
//                
//                throw FileReadError.invalidTiff
//                
//            }
//        }
//        else if isMRC{
//            dataType =  Int16.self
//
//            let (header, feiHeader) = try loadMRCHeader(from: url)
//            firstImageOffset = UInt64(1024+header!.nsymbt)
//            self.detectorSize = IntSize(width: Int(header!.nx), height: Int(header!.nx))
//            self.patternSize = detectorSize
//            self.imageSize = IntSize(width: Int(feiHeader!.scanSizeRight), height: Int(feiHeader!.scanSizeBottom))
////                volume =  try? loadMRCFile(from: url)
//            
//        }else{
//            dataType =  Float32.self
//            firstImageOffset = 0
//            self.detectorSize = empadSize
//            self.patternSize = detectorSize
//            patternSize.height -= 2
//            
//    
//            
//        }
//        
//        var fileSize = 0
//        let detectorPixels = self.detectorPixels
//        let patternPixels = self.patternPixels
//        let imagePixels = self.imagePixels
//       
//        
//        let elementSize:Int
//        
//        switch dataType {
//        case is Float32.Type:
//            elementSize = MemoryLayout<Float32>.size
//        case is Int16.Type:
//            elementSize = MemoryLayout<Int16>.size
//        default:
//            elementSize = MemoryLayout<Float32>.size
//        }
//        
//        let detectorBitCount = detectorPixels*elementSize
//        
//        
//        if !isTIFF && !isMRC{
//            do{
//                let attrib = try FileManager.default.attributesOfItem(atPath: url.path)
//                fileSize = attrib[.size] as! Int
//                
//            }catch{
//                throw FileReadError.invalidRaw
//            }
//            if  fileSize != detectorPixels*imagePixels*elementSize {
//                throw FileReadError.invalidDimensions
//            }
//            
//
//        }
//        
//        
//        
//        let patternBitCount = patternPixels*elementSize
//        let dataPixels = patternPixels*imagePixels*elementSize
//        
//        let nc = NotificationCenter.default
//
//        dwi  = DispatchWorkItem {
//        
//            self.openFileHandle(url: url)
//            
//            if self.patternPointer != nil{
//                self.patternPointer?.deallocate(capacity: patternPixels*imagePixels*elementSize)
//            }
//            
//            self.patternPointer = UnsafeMutablePointer<Float32>.allocate(capacity: dataPixels)
//
//            
//
//            
//            let fracComplete = Int(Double(imagePixels)*0.05)
//            
//            self.fh?.seek(toFileOffset: firstImageOffset)
//            
//            for i in stride(from: 0, to: self.imageSize.height, by: 1){
//                
//                if (self.dwi?.isCancelled)!{
//                    break
//                }
//                
//                autoreleasepool{
//                    
//                    for j in stride(from: 0, to: self.imageSize.width, by: 1){
//                        
//                        if (self.dwi?.isCancelled)!{
//                            break
//                        }
//                        
//                        let curImagePixel = (i*self.imageSize.width+j)
//                        let patternOffset = curImagePixel*detectorBitCount
//
//                        
//                        let newPointer = self.patternPointer! + curImagePixel*(patternPixels)
//                        
//                        if !isTIFF{
//                            self.fh?.seek(toFileOffset: UInt64(patternOffset))
//                        }
//                        
//                        var imageData = self.fh?.readData(ofLength: patternBitCount)
//                        
//                        //                    let newPointer = self.patternPointer! + curImagePixel*(patternPixels)
//
//                        
//                        if isTIFF{
//                            imageData?.withUnsafeMutableBytes { (i32ptr: UnsafeMutablePointer<UInt32>) in
//                                for i in 0..<patternPixels {
//                                    i32ptr[i] =  i32ptr[i].byteSwapped
//                                }
//                            }
//                        }
//                        
//                        if dataType is Int16.Type{
//                                // Fast conversion
//                                var floatBuffer = [Float32](repeating: 0, count: patternPixels)
//                                imageData?.withUnsafeBytes { rawBufferPointer in
//                                    let int16Ptr = rawBufferPointer.bindMemory(to: Int16.self).baseAddress!
//                                    vDSP_vflt16(int16Ptr, 1, &floatBuffer, 1, vDSP_Length(patternPixels))
//                                }
//
//                            }
//                        
//                                                
//
//                        // store rows in reversed order
//                        imageData?.withUnsafeBytes{(ptr: UnsafePointer<Float32>) in
//                            let width = self.patternSize.width
//                            for row in 0..<self.patternSize.height {
//                                let destRow = self.patternSize.height - row - 1
//                                (newPointer + destRow*width).assign(from: ptr + row*width, count: width)
//                            }
//                        }
//                        
//                        
//                        
//                        if(curImagePixel % fracComplete == 0 ){
//                            DispatchQueue.main.async {
//                                nc.post(name: Notification.Name("updateProgress"), object:curImagePixel)
//                            }
//                        }
//                    }// forj
//                } //autorelease
//                
//            } //fori
//            
//            DispatchQueue.main.async {
//                self.delegate?.didFinishLoadingData()
//                self.progressdelegate?.didFinishLoadingData()
//            }
//            
////            if (self.dwi?.isCancelled)!{
////                DispatchQueue.main.async {
////                    self.progressdelegate?.cancel(self)
////                }
////            }else{
////                
////                DispatchQueue.main.async {
////                    self.delegate?.didFinishLoadingData()
////                    self.progressdelegate?.didFinishLoadingData()
////                }
////            }
//        }
//        
//        
//         DispatchQueue.global().async(execute: dwi!)
//
//        
//    }
    
    
    func openFileHandle(url:URL){
       
        let bufferStream:FileHandle?
        
        do{
            try bufferStream = FileHandle.init(forReadingFrom: url)
            self.fh = bufferStream
            
        }catch{
            print("error creating file handle")
        }
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
        
        let (strideWidth, strideHeight) = strideSize(imageSize, strideLength)
        
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
    
        let (strideWidth, strideHeight) = strideSize(imageSize, strideLength)
        
        var outArray = [Float].init(repeating: 0.0, count: Int(strideWidth*strideHeight))

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
        
        let (strideWidth, strideHeight) = strideSize(imageSize, strideLength)
        
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
            
            c.deallocate()
            
//            group.leave()
//        }
//        
//        group.wait()
//        
        
        return Matrix.init(array: outArray, Int(strideHeight), Int(strideWidth))
        
    }
    
    
    
    deinit {
        fh?.closeFile()
        patternPointer?.deinitialize()
    }

}

// Needed to ceil the stride size to avoid stride overruns

func strideSize(_ imageSize:IntSize, _ strideLength:Int)->(Int, Int){
    
    let strideWidth = Int(ceil(Double(imageSize.width)/Double(strideLength)))
    let strideHeight = Int(ceil(Double(imageSize.height)/Double(strideLength)))
    
    return (strideWidth, strideHeight)
}
