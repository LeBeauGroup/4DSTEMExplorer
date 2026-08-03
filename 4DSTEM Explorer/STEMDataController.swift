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
    func didFinishLoadingData()->(pattern:NSImage?, virtual:NSImage?)
    func didFailLoadingData(_ error: Error)
}

extension STEMDataControllerDelegate {
    func didFailLoadingData(_ error: Error) { }
}

protocol STEMDataControllerProgressDelegate:class {
    func cancel(_ sender:Any)
}

struct Calibrations{
    let scan_step:Float?
    let diff_step:Float?
}


class STEMDataController: NSObject {
    
    // Notification posted when a new displayable NSImage is ready
    static let imageDidUpdateNotification = Notification.Name("STEMDataController.imageDidUpdate")
    // Optional cache for latest rendered image (used by observers)
    private(set) var lastRenderedImage: NSImage?
    
    var filePath:URL?
    var imageSize:IntSize = IntSize(width: 0, height: 0)
    var fh:FileHandle?
    
    var calibrations:Calibrations?
    
    weak var delegate:STEMDataControllerDelegate?
    weak var progressdelegate:STEMDataControllerProgressDelegate?
    
    var detectorSize:IntSize = empadSize
    var patternSize:IntSize = empadSize
    
    var providedRawImageSize: IntSize? = nil
    var rawFlipRows: Bool = true
    var rawFlipCols: Bool = false
    var rawTranspose: Bool = false
    
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
    
    func setRawImageSize(width: Int, height: Int) {
        self.providedRawImageSize = IntSize(width: width, height: height)
    }

    func setRawTransforms(flipRows: Bool, flipCols: Bool, transpose: Bool) {
        self.rawFlipRows = flipRows
        self.rawFlipCols = flipCols
        self.rawTranspose = transpose
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
            
            // Convert pointer to array
            let patternArray = Array(UnsafeBufferPointer(start: selectedPatternPointer, count: patternPixels))
            matrix = Matrix.init(array: patternArray, patternSize.height, patternSize.width)
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
                guard let base = raw.bindMemory(to: Float32.self).baseAddress else {
                    // If we can't get a baseAddress (e.g., zero-length), do nothing safely.
                    return
                }
                destinationBuffer.update(from: base, count: count)
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
#if DEBUG
                print("Timeout waiting for file to download")
#endif
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
#if DEBUG
            print("Failed to check file status: \(error)")
#endif
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
    
    func nudgeDownload(url: URL) {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { _ in
                print("test")
            // No-op — access itself is the trigger
        }
    }
    
    func openFile(url: URL) throws {
        
        
//        if isDropboxFile(url) {
            nudgeDownload(url: url)
            // ...
//        } else if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
//#if DEBUG
//            print("Detected iCloud file")
//#endif
//            // Use `startDownloadingUbiquitousItem(at:)` and check download status
//        } else {
//#if DEBUG
//            print("Not iCloud or Dropbox")
//#endif
//        }
       
        
        let ext = url.pathExtension.lowercased()
        let typeIdentifier = UTTypeCreatePreferredIdentifierForTag(
            kUTTagClassFilenameExtension,
            ext as CFString,
            nil
        )?.takeRetainedValue()

        let isTIFF = typeIdentifier.map { UTTypeConformsTo($0, kUTTypeTIFF) } ?? false
        let isMRC = ext == "mrc"
        let isDM4 = ext == "dm4"
        let isRaw = ext == "raw"
        

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

            if isRaw {
                self.imageSize = providedRawImageSize ?? IntSize(width: 0, height: 0)
            }
        }

        let elementSize = dataType.elementSize
        


        let detectorPixels = self.detectorPixels
        let patternPixels = self.patternPixels
        let imagePixels = self.imagePixels

        if isRaw {
            do {
                let attrib = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = (attrib[.size] as? NSNumber)?.intValue ?? 0

                // Only validate when we know image dimensions
                if imagePixels > 0 {
                    let basePixelsPerImage = (self.patternSize.height + additionalRows) * self.patternSize.width
                    let totalPixels = basePixelsPerImage * imagePixels

                    let candidates: [DataType] = [.float32, .uint16, .int16, .uint8, .uint32]
                    var matched = false
                    for cand in candidates {
                        let expectedBytes = totalPixels * cand.elementSize
                        if fileSize == expectedBytes {
                            dataType = cand
                            matched = true
                            break
                        }
                    }
                    if !matched {
                        throw FileReadError.invalidDimensions
                    }
                }
                // Derive image dimensions for RAW if not already set
                let bytesPerImage = (self.patternSize.height + additionalRows) * self.patternSize.width * dataType.elementSize
                if bytesPerImage > 0 {
                    let totalImages = fileSize / bytesPerImage

                    // If image size hasn't been set yet, try to parse from filename or infer
                    if self.imageSize.width == 0 || self.imageSize.height == 0 {
                        if let provided = self.providedRawImageSize {
                            self.imageSize = provided
                        } else {
                            let name = url.lastPathComponent
                            var inferredW: Int? = nil
                            var inferredH: Int? = nil

                            // Try to parse numbers following 'x' and 'y' like original workflow
                            if let regex = try? NSRegularExpression(pattern: "(?<=[xXyY])[0-9]+", options: []) {
                                let s = name as NSString
                                let matches = regex.matches(in: name, options: [], range: NSRange(location: 0, length: s.length))
                                if let first = matches.first {
                                    inferredW = Int(s.substring(with: first.range))
                                }
                                if matches.count > 1, let last = matches.last {
                                    inferredH = Int(s.substring(with: last.range))
                                }
                            }

                            if let w = inferredW, let h = inferredH {
                                self.imageSize = IntSize(width: w, height: h)
                            } else {
                                let root = Int(Double(totalImages).squareRoot())
                                if root * root == totalImages {
                                    self.imageSize = IntSize(width: root, height: root)
                                } else {
                                    self.imageSize = IntSize(width: totalImages, height: 1)
                                }
                            }
                        }
                    }
                }
            } catch let fileReadError as FileReadError {
                throw fileReadError
            } catch {
                throw FileReadError.invalidRaw
            }
        }


        let width = self.patternSize.width
        let height = self.patternSize.height
        let totalPatternPixels = (height + additionalRows) * width
    
        
        let totalImages = self.imageSize.width * self.imageSize.height
        guard totalImages > 0 else {
            throw FileReadError.invalidDimensions
        }

        let doFlipRows = rawFlipRows
        let doFlipCols = rawFlipCols
        let doTranspose = rawTranspose

        let batchSize = 64
        let totalBatches = (totalImages + batchSize - 1) / batchSize


        let nc = NotificationCenter.default

        dwi = DispatchWorkItem {
            let fail: (Error) -> Void = { error in
                DispatchQueue.main.async {
                    self.delegate?.didFailLoadingData(error)
                }
            }

            self.openFileHandle(url: url)
            guard let fileHandle = self.fh else {
                fail(FileReadError.invalidRaw)
                return
            }

            self.patternPointer?.deallocate()
            self.patternPointer = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels * totalImages)

            let floatTempBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: detectorPixels * batchSize)
            defer { floatTempBuffer.deallocate() }

            // Pre-allocate a single pattern-sized buffer for transpose; reused each image
            let transposeBuf: UnsafeMutablePointer<Float32>? = doTranspose
                ? UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
                : nil
            defer { transposeBuf?.deallocate() }

            // Output dimensions after optional transpose
            let outH = doTranspose ? width  : height
            let outW = doTranspose ? height : width

            fileHandle.seek(toFileOffset: firstImageOffset)
            let fracComplete = max(1, Int(Double(totalImages) * 0.05))

            for batchIndex in 0..<totalBatches {
                if self.dwi?.isCancelled ?? false { return }

                let imagesInBatch = min(batchSize, totalImages - batchIndex * batchSize)
                let readSize = imagesInBatch * (totalPatternPixels) * elementSize

                let batchData = fileHandle.readData(ofLength: readSize)
                guard batchData.count == readSize else {
                    fail(FileReadError.invalidDimensions)
                    return
                }

                let count = imagesInBatch * totalPatternPixels

                self.convertToFloat(dataType: dataType, sourceData: batchData, destinationBuffer: floatTempBuffer, count: count)


                for img in 0..<imagesInBatch {
                    let globalIndex = batchIndex * batchSize + img
                    if globalIndex >= totalImages { break }

                    let outPointer = self.patternPointer! + globalIndex * patternPixels
                    let srcPointer = floatTempBuffer + img * (totalPatternPixels)

                    // Determine the source for row operations (possibly transposed)
                    let rowSrc: UnsafeMutablePointer<Float32>
                    if doTranspose, let tb = transposeBuf {
                        // vDSP_mtrans: transposes height×width → width×height (row-major)
                        vDSP_mtrans(srcPointer, 1, tb, 1, vDSP_Length(height), vDSP_Length(width))
                        rowSrc = tb
                    } else {
                        rowSrc = srcPointer
                    }

                    // Copy rows (with optional vertical flip) then reverse each row for horizontal flip
                    for row in 0..<outH {
                        let destRow = doFlipRows ? outH - 1 - row : row
                        let dst = outPointer + destRow * outW
                        let src = rowSrc + row * outW
                        dst.update(from: src, count: outW)
                        if doFlipCols {
                            vDSP_vrvrs(dst, 1, vDSP_Length(outW))
                        }
                    }

                    if globalIndex % fracComplete == 0 {
                        DispatchQueue.main.async {
                            nc.post(name: .taskProgressUpdated, object: Double(globalIndex)/Double(totalImages))
                        }
                    }
                }
            }

            DispatchQueue.main.async(execute: DispatchWorkItem {
                if doTranspose {
                    self.patternSize = IntSize(width: self.patternSize.height, height: self.patternSize.width)
                }
                _ = self.delegate?.didFinishLoadingData()
                nc.post(name: .fileLoaded, object: nil)
//                self.progressdelegate?.didFinishLoadingData()

//                // Produce a default integrated preview for the viewer (safe detector covering full pattern)
//                let fullDetector = Detector()
//                let previewMatrix = self.integrating(fullDetector, strideLength: 1)
//                #if DEBUG
//                NSLog("[STEMDataController] Creating preview image: matrix size %dx%d", previewMatrix.columns, previewMatrix.rows)
//                #endif
//                if let img = self.nsImage(from: previewMatrix) {
//                    #if DEBUG
//                    NSLog("[STEMDataController] Preview NSImage created (w: %f, h: %f). Posting imageDidUpdateNotification…", img.size.width, img.size.height)
//                    #endif
//                    self.lastRenderedImage = img
//                    NotificationCenter.default.post(name: STEMDataController.imageDidUpdateNotification, object: self, userInfo: ["image": img])
//                } else {
//                    #if DEBUG
//                    NSLog("[STEMDataController] Failed to create NSImage from preview matrix")
//                    #endif
//                }
            })
        }

        DispatchQueue.global().async(execute: dwi!)
    }
    
    func openFileHandle(url:URL){
       
        let bufferStream:FileHandle?
        
        do{
            try bufferStream = FileHandle.init(forReadingFrom: url)
            self.fh = bufferStream
            
        }catch{
#if DEBUG
            print("error creating file handle")
#endif
        }
    }
   

    func averagePattern(rect:NSRect)->Matrix{
        
        let patternPixels = self.patternPixels
        
        // Allocate a mutable buffer for accumulation to avoid dangling pointers
        let adderPointer = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
        adderPointer.initialize(repeating: 0.0, count: patternPixels)
        
        let starti = Int(rect.origin.y)
        let startj = Int(rect.origin.x)
        
        let endi = starti + Int(floor(rect.size.height))
        let endj = startj + Int(floor(rect.size.width))
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
        
        // Materialize result array safely and deallocate buffer
        let adderArray = Array(UnsafeBufferPointer(start: adderPointer, count: patternPixels))
        adderPointer.deinitialize(count: patternPixels)
        adderPointer.deallocate()
        
        return Matrix.init(array: adderArray, patternSize.height, patternSize.width)

        
    }
    
    func dpc(_ detector: Detector, strideLength: Int = 1, lrud: Int = 0) -> Matrix {

        let detectorMask = detector.detectorMask()
        // Matrix(meshIndicesAlong:) uses 0 for x/column indices and 1 for y/row indices.
        // DPC uses lrud = 1 for left-right (x split) and 0 for up-down (y split),
        // so convert explicitly here instead of relying on matching integer values.
        let meshAxis = (lrud == 1) ? 0 : 1
        let indices = Matrix(meshIndicesAlong: meshAxis, patternSize.height, patternSize.width)

        // Split the detector into two complementary halves for differential phase contrast.
        // The DPC signal = leftOrDown intensity − rightOrUp intensity.
        //
        //   Horizontal DPC (lrud == 1): left  half (x < center.x) vs right half (x > center.x)
        //   Vertical DPC   (lrud == 0): lower half (y > center.y) vs upper half (y < center.y)
        //                               (y increases downward in image coordinates)
        let leftOrDownMask: Matrix
        let rightOrUpMask: Matrix

        if lrud == 1 {
            leftOrDownMask = indices < Float(detector.center.x)  // left half of detector
            rightOrUpMask  = indices > Float(detector.center.x)  // right half of detector
        } else {
            leftOrDownMask = indices > Float(detector.center.y)  // lower half of detector
            rightOrUpMask  = indices < Float(detector.center.y)  // upper half of detector
        }

        let (strideWidth, strideHeight) = strideSize(imageSize, strideLength)

        var outArray = [Float](repeating: 0.0, count: strideWidth * strideHeight)

        let patternPixels = self.patternPixels

        // Pre-multiply each directional half mask by the detector aperture mask
        let leftOrDownDetectorMask = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
        let rightOrUpDetectorMask  = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
        let leftOrDownIntensity    = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)
        let rightOrUpIntensity     = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels)

        vDSP_vmul(detectorMask.real, 1, leftOrDownMask.real, 1, leftOrDownDetectorMask, 1, UInt(patternPixels))
        vDSP_vmul(detectorMask.real, 1, rightOrUpMask.real,  1, rightOrUpDetectorMask,  1, UInt(patternPixels))

        let leftOrDownSum = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
        let rightOrUpSum  = UnsafeMutablePointer<Float32>.allocate(capacity: 1)

        var pos = 0

        for i in stride(from: 0, to: self.imageSize.height, by: strideLength) {
            for j in stride(from: 0, to: self.imageSize.width, by: strideLength) {

                let patternPointer = self.patternPointer! + (i * self.imageSize.width + j) * patternPixels

                // Apply each masked detector half to the diffraction pattern
                vDSP_vmul(leftOrDownDetectorMask, 1, patternPointer, 1, leftOrDownIntensity, 1, UInt(patternPixels))
                vDSP_vmul(rightOrUpDetectorMask,  1, patternPointer, 1, rightOrUpIntensity,  1, UInt(patternPixels))

                // Sum the intensities in each half
                vDSP_sve(leftOrDownIntensity, 1, leftOrDownSum, UInt(patternPixels))
                vDSP_sve(rightOrUpIntensity,  1, rightOrUpSum,  UInt(patternPixels))

                // Horizontal DPC: R-L; Vertical DPC: D-U
                outArray[pos] = lrud == 1
                    ? rightOrUpSum.pointee - leftOrDownSum.pointee
                    : leftOrDownSum.pointee - rightOrUpSum.pointee
                pos += 1
            }
        }

        return Matrix(array: outArray, strideHeight, strideWidth)
    }
    
    func com(_ detector:Detector,strideLength:Int = 1, xy:COMAxis = .x)->Matrix{
    
        let mask = detector.detectorMask()
        
        let group = DispatchGroup()
        group.enter()
    
        let (strideWidth, strideHeight) = strideSize(imageSize, strideLength)
        
        var outArray = [Float].init(repeating: 0.0, count: Int(strideWidth*strideHeight))

        let indices = Matrix.init(meshIndicesAlong: xy.rawValue, patternSize.height, patternSize.width)
        
        var shifted = indices.real
                
        let c:Float
        if xy == .x {
            c = Float(detector.center.x)
        }else {
            c = Float(detector.center.y)
        }
        
        vDSP_vsadd(shifted, 1, [-c], &shifted, 1, vDSP_Length(shifted.count))

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
                    
                    vDSP_vmul(maskPatternProduct, 1, shifted, 1, indexWeighted, 1, UInt(patternPixels))
                    
                    vDSP_sve(maskPatternProduct, 1, pixelSum, UInt(patternPixels))

                    let intSum = pixelSum.pointee
                    
            
                    vDSP_sve(indexWeighted, 1, pixelSum, UInt(patternPixels))

                    outArray[pos] = pixelSum.pointee/intSum
                    pos += 1
                }
            }
            maskPatternProduct.deallocate()

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
    
    private func hsvToRGB(h: [Float], s: [Float], v: [Float]) -> [UInt8] {
        // Convert HSV float arrays to RGB UInt8 array (3 components per pixel)
        // h, s, v expected in [0,1]
        // Output RGB in [0,255]
        let count = h.count
        var rgb = [UInt8](repeating: 0, count: count * 3)
        
        for i in 0..<count {
            let hue = h[i] * 6.0
            let saturation = s[i]
            let value = v[i]
            
            let c = value * saturation
            let x = c * (1 - abs(fmod(hue, 2.0) - 1))
            let m = value - c
            
            var r1: Float = 0
            var g1: Float = 0
            var b1: Float = 0
            
            switch Int(hue) {
            case 0:
                r1 = c; g1 = x; b1 = 0
            case 1:
                r1 = x; g1 = c; b1 = 0
            case 2:
                r1 = 0; g1 = c; b1 = x
            case 3:
                r1 = 0; g1 = x; b1 = c
            case 4:
                r1 = x; g1 = 0; b1 = c
            case 5:
                r1 = c; g1 = 0; b1 = x
            default:
                r1 = 0; g1 = 0; b1 = 0
            }
            
            let r = UInt8(max(0, min(255, Int((r1 + m) * 255))))
            let g = UInt8(max(0, min(255, Int((g1 + m) * 255))))
            let b = UInt8(max(0, min(255, Int((b1 + m) * 255))))
            
            rgb[i * 3] = r
            rgb[i * 3 + 1] = g
            rgb[i * 3 + 2] = b
        }
        
        return rgb
    }
    
    // MARK: - Rendering helpers for ImageViewerRepresentable
    private func nsImage(from pixelBuffer: CVPixelBuffer) -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rep = NSCIImageRep(ciImage: ciImage)
        let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        img.addRepresentation(rep)
        return img
    }

    private func nsImage(from matrix: Matrix) -> NSImage? {
        let rows = matrix.rows
        let cols = matrix.columns
        var data = matrix.real
        guard rows > 0, cols > 0, !data.isEmpty else { return nil }
        if let minVal = data.min(), let maxVal = data.max(), maxVal > minVal {
            let scale = 255.0 / (maxVal - minVal)
            let offset = -minVal * scale
            vDSP_vsmsa(data, 1, [scale], [offset], &data, 1, vDSP_Length(data.count))
        }
        var u8 = [UInt8](repeating: 0, count: data.count)
        vDSP_vfixu8(data, 1, &u8, 1, vDSP_Length(data.count))
        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(u8) as CFData) else { return nil }
        guard let cg = CGImage(width: cols,
                               height: rows,
                               bitsPerComponent: 8,
                               bitsPerPixel: 8,
                               bytesPerRow: cols,
                               space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider,
                               decode: nil,
                               shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }
        let img = NSImage(size: NSSize(width: cols, height: rows))
        img.addRepresentation(NSBitmapImageRep(cgImage: cg))
        return img
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





