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
    case notDiffractionSI
}

enum DataType {
    case uint32
    case float32
    case int16
    case uint8
    case uint16
    case bool
    case unknown // for default handling

    var elementSize: Int {
        switch self {
        case .uint32: return MemoryLayout<UInt32>.size
        case .float32: return MemoryLayout<Float32>.size
        case .int16: return MemoryLayout<Int16>.size
        case .uint8: return MemoryLayout<UInt8>.size
        case .uint16: return MemoryLayout<UInt16>.size
        case .bool: return MemoryLayout<Bool>.size
        case .unknown: return MemoryLayout<Float32>.size
        }
    }
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
    private func navigateDict(_ metadata:[String:Any],_ keyPath:[String]) -> [String:Any]{
        var temp = metadata
        for key in keyPath{
            if let dict = temp[key] as! [String:Any]?{
                temp = dict
            }
            
        }
        
        return temp
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
    
    private func convertToFloat(
        dataType: DataType,
        sourceData: Data,
        destinationBuffer: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        sourceData.withUnsafeBytes { raw in
            switch dataType {
            case .int16:
                vDSP_vflt16(raw.bindMemory(to: Int16.self).baseAddress!, 1,
                            destinationBuffer, 1, vDSP_Length(count))

            case .uint16:
                vDSP_vflt16(raw.bindMemory(to: UInt16.self).baseAddress!, 1,
                            destinationBuffer, 1, vDSP_Length(count))

            case .uint32:
                vDSP_vflt32(raw.bindMemory(to: UInt32.self).baseAddress!, 1,
                            destinationBuffer, 1, vDSP_Length(count))

            case .uint8, .bool:
                vDSP_vfltu8(raw.bindMemory(to: UInt8.self).baseAddress!, 1,
                            destinationBuffer, 1, vDSP_Length(count))

            default: // assuming Float32
                destinationBuffer.update(from: raw.bindMemory(to: Float32.self).baseAddress!, count: count)
            }
        }
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
    
    enum DataType {
        case uint32
        case float32
        case int16
        case uint8
        case uint16
        case bool
        case unknown // for default handling

        var elementSize: Int {
            switch self {
            case .uint32: return MemoryLayout<UInt32>.size
            case .float32: return MemoryLayout<Float32>.size
            case .int16: return MemoryLayout<Int16>.size
            case .uint8: return MemoryLayout<UInt8>.size
            case .uint16: return MemoryLayout<UInt16>.size
            case .bool: return MemoryLayout<Bool>.size
            case .unknown: return MemoryLayout<Float32>.size
            }
        }
    }
    
    
    // MARK: - File read
    
    
    func waitForFileDownload(at url: URL, timeout: TimeInterval = 15.0, stableDuration: TimeInterval = 1.5) -> Bool {
        let start = Date()
        var lastSize: Int64 = -1
        var stableStart: Date? = nil

        while Date().timeIntervalSince(start) < timeout {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                if let fileSize = attrs[.size] as? Int64 {
                    if fileSize == lastSize {
                        if stableStart == nil {
                            stableStart = Date()
                        } else if Date().timeIntervalSince(stableStart!) >= stableDuration {
                            // File size hasn't changed for long enough; assume download complete
                            return true
                        }
                    } else {
                        stableStart = nil
                        lastSize = fileSize
                    }
                }
            } catch {
                // File not yet readable
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return false
    }
    
    func waitUntilDropboxFileIsReadable(at url: URL, timeout: TimeInterval = 10.0) -> Bool {
        let start = Date()
        while true {
            do {
                _ = try Data(contentsOf: url)
                return true  // File is readable
            } catch {
                // Possibly still downloading
            }

            if Date().timeIntervalSince(start) > timeout {
                return false  // Timed out
            }

            // Sleep a bit to avoid CPU spinning
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
    func waitUntilFileIsDownloaded(at url: URL, timeout: TimeInterval = 10.0) -> Bool {
        let start = Date()
        while !isFileFullyDownloaded(at: url) {
            if Date().timeIntervalSince(start) > timeout {
                print("Timeout waiting for file to download")
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1)) // Avoid CPU hog
        }
        return true
    }
    
    func isDropboxFile(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("Dropbox")
    }

    func isFileFullyDownloaded(at url: URL) -> Bool {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                                  .ubiquitousItemDownloadingStatusKey])
            guard resourceValues.isUbiquitousItem == true else {
                return true  // Not a cloud file, assume it's local
            }

            return resourceValues.ubiquitousItemDownloadingStatus == .current
        } catch {
            print("Failed to check file status: \(error)")
            return false
        }
    }
    
    func forceDownloadDropboxFile(at url: URL) -> Bool {
        let startTime = Date()
        let timeout: TimeInterval = 15.0
        var lastSize: Int64 = -1
        var stableStart: Date? = nil

        while Date().timeIntervalSince(startTime) < timeout {
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                // Optional: check size stability for completeness
                let size = Int64(data.count)
                if size == lastSize {
                    if stableStart == nil {
                        stableStart = Date()
                    } else if Date().timeIntervalSince(stableStart!) > 2.0 {
                        return true // Size is stable → likely fully downloaded
                    }
                } else {
                    lastSize = size
                    stableStart = nil
                }
            } catch {
                // Triggers Dropbox download behind the scenes
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return false
    }
    
    func nudgeDropboxDownload(url: URL) {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { _ in
            // No-op — access itself is the trigger
        }
    }
    
    func openFile(url: URL) throws {
        
        
        if isDropboxFile(url) {
            nudgeDropboxDownload(url: url)
            // ...
        } else if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            print("Detected iCloud file")
            // Use `startDownloadingUbiquitousItem(at:)` and check download status
        } else {
            print("Not iCloud or Dropbox")
        }
       
        
        let ext = url.pathExtension
        let uti = UTTypeCreatePreferredIdentifierForTag(
            kUTTagClassFilenameExtension,
            ext as CFString,
            nil
        )

        let isTIFF = UTTypeConformsTo((uti?.takeRetainedValue())!, kUTTypeTIFF)
        let isMRC = url.pathExtension == "mrc"
        let isDM4 = url.pathExtension == "dm4"
        let isRaw = url.pathExtension == "raw"
        

        var dataType: DataType = .unknown
        var firstImageOffset: UInt64
        var additionalRows:Int = 0
    
        if isTIFF {
            dataType = .float32
            let props: [String: Any]
            do {
                try props = TIFFheader(url)
                try readTiffInfo(props)
                firstImageOffset = props["FirstImageOffset"] as! UInt64
            } catch {
                throw FileReadError.invalidTiff
            }
        } else if isMRC {
            dataType = .int16
            
            let (header, feiHeader) = try loadMRCHeader(from: url)
//            let header = try readMRCHeader(from: url)
//            let feiHeader = try readFEI1ExtendedHeaders(from: url)
            firstImageOffset = UInt64(1024 + header!.nsymbt)
            self.detectorSize = IntSize(width: Int(header!.nx), height: Int(header!.nx))
            self.patternSize = detectorSize
            
            self.imageSize = IntSize(width: Int(feiHeader!.scanSizeRight), height: Int(feiHeader!.scanSizeBottom))
        } else if isDM4{
            
            let dm4 = try DigitalMicrographReader(fileURL: url)
            var metadata = dm4.tagsDict
            
            firstImageOffset = 0
                        
//            let keysToSampling = ["root", "ImageList", "TagGroup0", "ImageTags", "SI", "Acquisition", "Spatial Sampling"]
//            
//
//        
//            let sampling = navigateDict(metadata, keysToSampling)
            
            let keysImageList = ["root", "ImageList"]
            
            let imageList  = navigateDict(metadata, keysImageList)
            
            var tagGroup:String? = nil
            
            for (key, _) in imageList {
                let keyToImage = ["root", "ImageList", "\(key)"]
                let imageDict  = navigateDict(metadata, keyToImage)
                
                if let name = imageDict["Name"] as? String{
                    if name == "Diffraction SI"{
                        tagGroup = key
                        break
                    }
                }
            }
            
            guard let tg = tagGroup else {
                throw FileReadError.notDiffractionSI
                }
                //
            let keysToData = ["root", "ImageList", tg, "ImageData", "Data"]
            
            //            let keysToDetector = ["root", "ImageList", "TagGroup1", "ImageTags",  "Acquisition", "Parameters", "Detector"]
            
            let keysToSize = ["root", "ImageList", tg, "ImageData", "Dimensions"]
            
            //            let keysToPixelDepth = ["root", "ImageList", "TagGroup1", "ImageData"]
            
            let data = navigateDict(metadata, keysToData)
            //            let pixelDepth = navigateDictToInt(metadata, keysToPixelDepth)
            
            //            let detector = navigateDict(metadata, keysToDetector)
            let sizes = navigateDict(metadata, keysToSize)
            
            if let dtypeNumber = data["datatype"] as? Int{
                switch dtypeNumber{
                case 2:
                    dataType = .int16
                case 4:
                    dataType = .uint16
                case 5:
                    dataType = .uint32
                case 8:
                    dataType = .bool
                case 10:
                    dataType = .uint8
                default:
                    dataType = .int16
                    
                }
            }
            
            
            
            var sizesArray: [UInt32]  = Array.init(repeating: 0, count: 4)
            
            for sizeKey in sizes.keys{
                if let index = sizeKey.last(where: { $0.isNumber }){
                    if let t = sizes[sizeKey] as? UInt32{
                        sizesArray[Int(String(index))!] = t
                    }
                    
                }
            }
            
            firstImageOffset = UInt64(data["offset"] as! Int)
            self.detectorSize = IntSize(width: Int(sizesArray[0]), height: Int(sizesArray[1]))
            self.patternSize = detectorSize
            
            self.imageSize = IntSize(width: Int(sizesArray[2]), height: Int(sizesArray[3]))
        

        } else {
            dataType = .float32
            firstImageOffset = 0
            self.detectorSize = empadSize
            self.patternSize = detectorSize
            patternSize.height -= 2
            additionalRows = 2
        }

        let elementSize = dataType.elementSize
        


        let detectorPixels = self.detectorPixels
        let patternPixels = self.patternPixels
        let imagePixels = self.imagePixels
//        let detectorBitCount = detectorPixels * elementSize

        if isRaw {
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

        
//        let patternByteCount = patternPixels * elementSize
//        let dataTypeIsInt16 == Int16.self

        let width = self.patternSize.width
        let height = self.patternSize.height
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

            self.fh?.seek(toFileOffset: firstImageOffset)
            let fracComplete = max(1, Int(Double(totalImages) * 0.05))

            for batchIndex in 0..<totalBatches {
                if self.dwi?.isCancelled ?? false { break }

                let imagesInBatch = min(batchSize, totalImages - batchIndex * batchSize)
                let readSize = imagesInBatch * (totalPatternPixels) * elementSize

                guard let batchData = self.fh?.readData(ofLength: readSize) else { continue }
                
                let count = imagesInBatch * totalPatternPixels

                self.convertToFloat(dataType: dataType, sourceData: batchData, destinationBuffer: floatTempBuffer, count: count)


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
