//
//  STEMDataStore.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 8/29/25.
//  Copyright © 2025 The LeBeau Group. All rights reserved.
//

import Foundation
import Accelerate
import CoreGraphics
import Cocoa
import UniformTypeIdentifiers

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


@MainActor
protocol STEMDataControllerDelegate:AnyObject {
    @MainActor func didFinishLoadingData()
}

@MainActor
protocol STEMDataControllerProgressDelegate:AnyObject {
    func didFinishLoadingData()
    func cancel(_ sender:Any)
}

// MARK: - Store & Processing
@MainActor
final class STEMDataStore: ObservableObject {
    // 4D data dimensions (rY, rX, qY, qX)
    @Published private(set) var ry: Int = 0
    @Published private(set) var rx: Int = 0
    @Published private(set) var qy: Int = 0
    @Published private(set) var qx: Int = 0
    
    // Probe position (UI sliders are Double-bound)
    @Published var rIndexX: Double = 0 { didSet { updateCurrentFrame() } }
    @Published var rIndexY: Double = 0 { didSet { updateCurrentFrame() } }
    
    // Visualization settings
    @Published var logScale: Bool = true { didSet { refreshImages() } }
    @Published var colormap: Colormap = .gray { didSet { refreshImages() } }
    @Published var detectorMode: DetectorMode = .brightField { didSet { recomputeVirtualImage() } }
    
    // Backing storage
    private var data: [Float] = [] // size = ry*rx*qy*qx
    
    var dwi: DispatchWorkItem?
    
    var detectorSize:IntSize = empadSize
    var patternSize:IntSize = empadSize
    
    // Rendered outputs
    @Published private(set) var currentDiffractionCGImage: CGImage?
    @Published private(set) var virtualImageCGImage: CGImage?
    
    var imageSize:IntSize = IntSize(width: 0, height: 0)
    var fh:FileHandle?
    
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
    
    var patternPointer:UnsafeMutablePointer<Float32>?
    
    // Supported file types (extend as you add parsers)
    static let supportedUTTypes: [UTType] = [
        .init(importedAs: "org.nist.dm4") ?? .data,
        UTType(filenameExtension: "dm4") ?? .data,
        UTType(filenameExtension: "raw") ?? .data,
        UTType(filenameExtension: "tiff") ?? .data,
        .data
    ]
    
    private func isDropboxFile(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("Dropbox")
    }
    
    private func nudgeDropboxDownload(url: URL) {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { _ in
            // No-op — access itself is the trigger
        }
    }
    
    // MARK: Loading
    func load(url: URL) async throws{
        
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
        
        dwi = DispatchWorkItem {[weak self] in
            self?.load(url: url)
            
            self?.patternPointer?.deallocate()
            self?.patternPointer = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels * totalImages)
            
            let floatTempBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: patternPixels * batchSize)
            defer { floatTempBuffer.deallocate() }
            
            self?.fh?.seek(toFileOffset: firstImageOffset)
            let fracComplete = max(1, Int(Double(totalImages) * 0.05))
            
            for batchIndex in 0..<totalBatches {
                if self?.dwi?.isCancelled ?? false { break }
                
                let imagesInBatch = min(batchSize, totalImages - batchIndex * batchSize)
                let readSize = imagesInBatch * (totalPatternPixels) * elementSize
                
                guard let batchData = self?.fh?.readData(ofLength: readSize) else { continue }
                
                let count = imagesInBatch * totalPatternPixels
                
                self?.convertToFloat(dataType: dataType, sourceData: batchData, destinationBuffer: floatTempBuffer, count: count)
                
                
                for img in 0..<imagesInBatch {
                    let globalIndex = batchIndex * batchSize + img
                    if globalIndex >= totalImages { break }
                    
                    let outPointer = (self?.patternPointer!)! + globalIndex * patternPixels
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
            
            //            // finish on main
            //            DispatchQueue.main.async { [weak self] in
            //                guard let self else { return }
            //                self.delegate?.didFinishLoadingData()
            //                self.progressdelegate?.didFinishLoadingData()
            //            }
            
        }
        
        DispatchQueue.global().async(execute: dwi!)
    }
    
    func loadDemo() async {
        let (ry, rx, qy, qx) = (64, 64, 256, 256)
        self.ry = ry; self.rx = rx; self.qy = qy; self.qx = qx
        var arr = [Float](repeating: 0, count: ry*rx*qy*qx)
        
        // Synthetic: rings + shifting center with probe position
        for ryy in 0..<ry {
            for rxx in 0..<rx {
                let cx = Float(qx)/2 + 10 * sin(Float(rxx)/8) // wobble center
                let cy = Float(qy)/2 + 8 * cos(Float(ryy)/9)
                for yy in 0..<qy {
                    for xx in 0..<qx {
                        let dx = Float(xx) - cx
                        let dy = Float(yy) - cy
                        let r = sqrt(dx*dx + dy*dy)
                        let val = exp(-pow((r-40)/8, 2)) + 0.6*exp(-pow((r-90)/10, 2)) + 0.3*exp(-pow((r-140)/14, 2))
                        let idx = ((((ryy*rx) + rxx)*qy) + yy)*qx + xx
                        arr[idx] = val
                    }
                }
            }
        }
        self.data = arr
        rIndexX = 0; rIndexY = 0
        updateCurrentFrame()
        recomputeVirtualImage()
    }
    
    // MARK: Derived images
    private func updateCurrentFrame() {
        guard ry>0, rx>0, qy>0, qx>0 else { return }
        let rxx = min(max(Int(rIndexX.rounded()), 0), rx-1)
        let ryy = min(max(Int(rIndexY.rounded()), 0), ry-1)
        let slice = diffractionSlice(rY: ryy, rX: rxx)
        currentDiffractionCGImage = makeCG(from: slice, width: qx, height: qy, log: logScale)
        // whenever probe changes, virtual image may change for modes that depend on per-frame integration cache; keep simple for now
        recomputeVirtualImage()
    }
    
    private func recomputeVirtualImage() {
        guard ry>0, rx>0, qy>0, qx>0 else { return }
        // Integrate each frame with a virtual detector mask
        let mask = detectorMask(mode: detectorMode, qx: qx, qy: qy)
        var img = [Float](repeating: 0, count: ry*rx)
        for ryy in 0..<ry {
            for rxx in 0..<rx {
                let frame = diffractionSlice(rY: ryy, rX: rxx)
                var sum: Float = 0
                vDSP_dotpr(frame, 1, mask, 1, &sum, vDSP_Length(frame.count))
                img[ryy*rx + rxx] = sum
            }
        }
        // Normalize
        if let maxv = img.max(), maxv > 0 { vDSP.divide(img, maxv, result: &img) }
        virtualImageCGImage = makeCG(from: img, width: rx, height: ry, log: false)
    }
    
    private func refreshImages() {
        updateCurrentFrame()
        // virtual image unaffected by log/colormap in this simplified pipeline (colormap applied in view)
    }
    
    func resetView() { /* reserved for future: zoom reset, etc. */ }
    
    // MARK: - Helpers
    private func diffractionSlice(rY: Int, rX: Int) -> [Float] {
        let base = ((rY*rx) + rX) * qy*qx
        let end = base + qy*qx
        return Array(data[base..<end])
    }
    
    private func detectorMask(mode: DetectorMode, qx: Int, qy: Int) -> [Float] {
        let cx = Float(qx)/2
        let cy = Float(qy)/2
        let rInner: Float
        let rOuter: Float
        switch mode {
        case .brightField:
            rInner = 0; rOuter = 25
        case .darkFieldAnnular:
            rInner = 60; rOuter = 120
        case .highAngleADF:
            rInner = 120; rOuter = 180
        }
        var mask = [Float](repeating: 0, count: qx*qy)
        for y in 0..<qy {
            for x in 0..<qx {
                let dx = Float(x) - cx
                let dy = Float(y) - cy
                let r = sqrt(dx*dx + dy*dy)
                mask[y*qx + x] = (r >= rInner && r <= rOuter) ? 1 : 0
            }
        }
        return mask
    }
    
    private func makeCG(from floats: [Float], width: Int, height: Int, log: Bool) -> CGImage? {
        var v = floats
        // log scale optional
        if log {
            var one: Float = 1
            vDSP.add(one, v, result: &v)
            vvlogf(&v, v, [Int32(v.count)])
        }
        // normalize 0…255
        var minVal: Float = 0, maxVal: Float = 1
        minVal = vDSP.minimum(v)
        maxVal = vDSP.maximum(v)
        var range = maxVal - minVal
        if range == 0 { range = 1 }
        var scaled = [UInt8](repeating: 0, count: v.count)
        // Scale to 0…255 and convert to UInt8 using Accelerate C APIs
        var scaleVal: Float = 255.0 / range
        var biasVal:  Float = -minVal * scaleVal
        var scaledF   = [Float](repeating: 0, count: v.count)
        vDSP_vsmsa(v, 1, &scaleVal, &biasVal, &scaledF, 1, vDSP_Length(v.count))
        var lo: Float = 0, hi: Float = 255
        vDSP_vclip(scaledF, 1, &lo, &hi, &scaledF, 1, vDSP_Length(v.count))
        vDSP_vfixu8(scaledF, 1, &scaled, 1, vDSP_Length(v.count))
        
        
        let colorSpace = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray()
        let bytesPerRow = width
        guard let provider = CGDataProvider(data: Data(scaled) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    
    // Stub: export both panes as PNGs next to dataset (or Desktop)
    func exportSnapshot() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "4DSTEM-snapshot.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // For demo, just write virtual image
        if let cg = virtualImageCGImage {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
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
    
    
}
