import Foundation
import Cocoa
import CoreVideo
import QuartzCore
import Accelerate
import SwiftUI

// Temporary local definitions to make the toolbar compile.
// If your project already defines these elsewhere, you can remove these and import/use the shared ones.
//enum SelectionMode: Hashable {
//    case point
//    case marquee
//}

enum CalculationMode: Hashable {
    case integrate
    case com
    case dpc
}

enum DPCAxis: Hashable {
    case leftRight // maps to lrud = 1 in STEMDataController.dpc
    case upDown    // maps to lrud = 0 in STEMDataController.dpc
    case color
}

enum COMAxis:  Int, Hashable {
    case x
    case y
    case color
}

//    var id: String { rawValue } }


final class DataViewModel: NSObject, ObservableObject {
    @Published var isDragging: Bool = false

    @Published var selectedURL: URL?
    @Published var status: String = "Idle"
    @Published var loadErrorMessage: String?
    @Published var progress: Double = 0.0
    @Published var isLoading: Bool = false
    @Published var lastProgressTick: Int = 0
    @Published var stride:Int = 1
    @Published var scanImage: NSImage?
    @Published var imageWidth: Int = 0
    @Published var imageHeight: Int = 0
    @Published var selectionRect: CGRect? = nil

    @Published var selected:Any? = nil
    @Published var patternSize: IntSize = .init(width: 32, height: 32)

    @Published var detectorShape: DetectorShape = .bf
    @Published var detectorType: DetectorType = .integrating
    @Published var detectorInnerRadius: CGFloat = 1
    @Published var detectorOuterRadius: CGFloat = 10
    @Published var detectorCenter: CGPoint = .zero
    
    // Selection mode used by the Picker in the toolbar
    @Published var selectionMode: InteractiveMarkerView.SelectionMode = .point
    // Current zoom scale (0.0 ... 1.0 for percent formatting)
    @Published var currentScale: Double = 1.0
    // When true, the ImageViewerRepresentable will compute and apply a fit-to-window zoom without changing currentScale.
    @Published var zoomToFitEnabled: Bool = true
    // Stores the last computed fit-to-window scale so we can seed currentScale when exiting zoom-to-fit.
    @Published var lastFitScale: Double = 1.0

    @Published var calculationMode: CalculationMode = .integrate
    @Published var dpcAxis: DPCAxis = .leftRight
    
    @Published var comAxis: COMAxis = .x
    @Published var calibrations:Calibrations?
    @Published var pattern_mat:Matrix? = nil
    
    
    func export(type:String){
        
        var outString:String = ""
        var matrix: Matrix? = nil
        var renderedImage: NSImage? = nil
        let exportColorImage = type == "image" && isColorScanImageMode
        let fileroot = selectedURL?.deletingPathExtension().lastPathComponent ?? ""
        
        switch type
        {
        case "image":
            let detectorLabel =  String(describing: calculationMode)
            var axisLabel:String = ""
            
            switch calculationMode {
                
            case .integrate:
                break
            case .dpc:
                axisLabel = String(describing: dpcAxis)
            case .com:
                axisLabel = String(describing: comAxis)
            }
            
            
            if fileroot != "" {
                outString = fileroot + "_" + detectorLabel
                
                if axisLabel != "" {
                    outString += "_" + axisLabel
                }
                
                outString += ".tif"
                
                
            }
            
            if let (tmpImage, tmpMatrix) = computeScanImage(){
                renderedImage = tmpImage
                matrix = tmpMatrix
            }
            
            
            
        case "pattern":
            
            if fileroot != "" {
                outString = fileroot + "_"
                if let (y,x) = selected as? (Int, Int){
                    outString += "x\(x)_y\(y)"
                }
                
                if let rect = selected as? CGRect{
                    outString += "x\(Int(rect.origin.x))_y\(Int(rect.origin.y))_w\(Int(rect.size.width))_h\(Int(rect.size.height))"
                }
    
                
                outString += ".tif"
            }
            
            matrix = pattern_mat
            //            savePanel.nameFieldStringValue = (self.view.window?.title)!+"_"+(patternSelectionLabel?.stringValue)!
            
        default:
            break
        }
        
        if let amatrix = matrix{
            
            
            // Present a save panel with suggested filename
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.showsTagField = false
            panel.isExtensionHidden = false
            panel.allowedFileTypes = ["tif", "tiff"]
            panel.nameFieldStringValue = outString
            
            // Try to present as a sheet from a host window if available, otherwise modal
            
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                
                let cgImage: CGImage?
                if exportColorImage, let renderedImage {
                    cgImage = self.make32BitRGBImage(from: renderedImage)
                } else {
                    cgImage = amatrix.floatImageRep().cgImage
                }
                guard let cgImage else { return }

                var cgProps = [CFString:Any]()
                
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else { return }
                
                
                cgProps["{TIFF}" as CFString] = ["ImageDescription" as CFString:"A description" as CFString]
                
                CGImageDestinationAddImage(dest, cgImage, cgProps as CFDictionary)
                
                CGImageDestinationFinalize(dest)
                
            }
        }
            

    }



    private var isColorScanImageMode: Bool {
        switch calculationMode {
        case .com:
            return comAxis == .color
        case .dpc:
            return dpcAxis == .color
        case .integrate:
            return false
        }
    }

    private func make32BitRGBImage(from image: NSImage) -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let sourceImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        let width = sourceImage.width
        let height = sourceImage.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }




    // Zoom controls used by the toolbar
    func zoomIn() {
        if zoomToFitEnabled { currentScale = lastFitScale }
        zoomToFitEnabled = false
        currentScale *= 1.1
    }
    func zoomOut() {
        if zoomToFitEnabled { currentScale = lastFitScale }
        zoomToFitEnabled = false
        currentScale /= 1.1
    }
    func setScale(_ scale: Double) {
        if zoomToFitEnabled { currentScale = lastFitScale }
        zoomToFitEnabled = false
        currentScale = scale
    }

    // MARK: - Drag-driven selection updates
    func beginDrag() {
        isDragging = true
    }

    func endDrag() {
        isDragging = false
    }

    private let dataController = STEMDataController()
    private var progressObserver: NSObjectProtocol?
    private var imageUpdateObserver: NSObjectProtocol?
    private var securityScopedURL: URL?

    override init() {
                
        super.init()
        
        dataController.delegate = self
//        dataController.progressdelegate = self
        
        

        progressObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("updateProgress"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let tick = note.object as? Int {
                self.lastProgressTick = tick
                if self.isLoading {
                    self.status = "Loading… (tick: \(tick))"
                    self.progress = 0
                }
            }
        }
        imageUpdateObserver = NotificationCenter.default.addObserver(
            forName: STEMDataController.imageDidUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Use the NSImage posted by STEMDataController in userInfo["image"]
            if let img = note.userInfo?["image"] as? NSImage {
                self?.scanImage = img
            } else {
                #if DEBUG
                NSLog("imageDidUpdateNotification missing NSImage in userInfo['image'] (object: %@, keys: %@)", String(describing: type(of: note.object as Any)), String(describing: note.userInfo?.keys))
                #endif
            }
        }
    }

    deinit {
        if let obs = progressObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = imageUpdateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    private func updateSecurityScopedAccess(for url: URL) {
        if securityScopedURL == url { return }

        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    private func suggestRawDimensions(from url: URL) -> (w: Int?, h: Int?) {
        let name = url.lastPathComponent
        var inferredW: Int? = nil
        var inferredH: Int? = nil
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
        return (inferredW, inferredH)
    }

// SwiftUI panel to prompt for RAW dimensions
    private func promptForRawDimensions(suggested: (w: Int?, h: Int?), completion: @escaping ((w: Int, h: Int, scan_step:Float?, diff_step:Float?)?) -> Void) {
        // Helper to parse strings like "80x80", "256×128", "64 X 32"
        func parseXY(_ text: String) -> (Int, Int)? {
            // Normalize input: trim, lowercase, unify separators, and be tolerant to spaces
            var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            s = s.lowercased()
            // Replace common unicode multiplication signs with 'x'
            s = s.replacingOccurrences(of: "×", with: "x")
            s = s.replacingOccurrences(of: "✕", with: "x")
            s = s.replacingOccurrences(of: "✖", with: "x")
            s = s.replacingOccurrences(of: "✗", with: "x")
            // Remove common labels if present
            s = s.replacingOccurrences(of: "pixels", with: "")
            s = s.replacingOccurrences(of: "px", with: "")

            // Try patterns in order: with 'x' or '*', then space-separated
            let patterns = [
                #"^\s*(\d+)\s*[x*]\s*(\d+)\s*$"#, // 80x80, 80*80, 80 x 80
                #"^\s*(\d+)\s+(\d+)\s*$"#           // 80 80
            ]
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let ns = s as NSString
                    if let m = regex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)),
                       m.numberOfRanges >= 3,
                       let r1 = Range(m.range(at: 1), in: s),
                       let r2 = Range(m.range(at: 2), in: s),
                       let w = Int(s[r1]), let h = Int(s[r2]), w > 0, h > 0 {
                        return (w, h)
                    }
                }
            }
            return nil
        }

        // Build default suggestion string
        var defaultString: String = ""
        if let w = suggested.w, let h = suggested.h {
            defaultString = "\(w)x\(h)"
        } else {
            defaultString = "80x80"
        }

        // State holders for the sheet lifecycle
        var result: (Int, Int, Float?, Float?)? = nil

        // SwiftUI content
        

        // Create an NSPanel hosting the SwiftUI content
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
                            styleMask: [.titled, .closable, .resizable],
                            backing: .buffered,
                            defer: false)
        panel.title = "RAW Scan Dimensions"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .modalPanel

        let fileHint = self.selectedURL?.lastPathComponent ?? ""

        let hosting = NSHostingView(rootView: RawDimsSheet(scan_dims: defaultString, diff_step: "None", scan_step:"None", fileHint: fileHint, onCancel: {
            if let parent = panel.sheetParent {
                parent.endSheet(panel, returnCode: .cancel)
                DispatchQueue.main.async { completion(nil) }
            } else {
                NSApp.stopModal(withCode: .cancel)
                panel.close()
                DispatchQueue.main.async { completion(nil) }
            }
        }, onOK: { scan_dims, scan_step, diff_step in
            if let xy = parseXY(scan_dims) {
                
                let scan_step = Float(scan_step) ?? nil
                let diff_step = Float(diff_step) ?? nil
                
                
                result = (xy.0, xy.1, scan_step, diff_step)
                if let parent = panel.sheetParent {
                    parent.endSheet(panel, returnCode: .OK)
                    DispatchQueue.main.async { completion(result) }
                } else {
                    NSApp.stopModal(withCode: .OK)
                    panel.close()
                    DispatchQueue.main.async { completion(result) }
                }
            } else {
                NSSound.beep()
            }
        }))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hosting)

        panel.contentView = contentView
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        // Present as a sheet from a host window if available, otherwise modal
        func hostWindow() -> NSWindow? {
            if let w = NSApp.keyWindow { return w }
            if let w = NSApp.mainWindow { return w }
            return NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) })
        }

        if let window = hostWindow() {
            window.beginSheet(panel) { _ in }
        } else {
            // Modal fallback (non-blocking with completion invoked from button handlers)
            NSApp.runModal(for: panel)
        }
    }

    private func continueOpen(afterPromptFor url: URL) {
        do {
            try self.dataController.openFile(url: url)
        } catch {
            handleOpenError(error)
        }
    }

    private func handleOpenError(_ error: Error) {
        isLoading = false

        let message: String
        switch error {
        case FileReadError.invalidTiff:
            message = "Selected image is incompatible. Please select an EMPAD tiff stack."
        case FileReadError.invalidRaw:
            message = "Invalid RAW file. Check dimensions and try again."
        case FileReadError.invalidDimensions:
            message = "Incorrect dimensions for the file."
        case FileReadError.notDiffractionSI:
            message = "DM File does not contain a diffraction SI dataset."
        default:
            message = "Something went wrong loading the file."
        }

        status = message
        loadErrorMessage = message
    }

    func open(url: URL) {
        updateSecurityScopedAccess(for: url)
        selectedURL = url
        loadErrorMessage = nil
        
        status = "Preparing to load \(url.lastPathComponent)…"
        isLoading = true
        dataController.filePath = url
        if url.pathExtension.lowercased() == "raw" {
            let suggested = suggestRawDimensions(from: url)
            promptForRawDimensions(suggested: suggested) { [weak self] dims in
                guard let self = self else { return }
                if let dims = dims {
                    self.dataController.setRawImageSize(width: dims.w, height: dims.h)
                    
                    self.calibrations = Calibrations(scan_step: dims.scan_step, diff_step: dims.diff_step)
                    
                    self.continueOpen(afterPromptFor: url)
                } else {
                    self.isLoading = false
                    self.status = "Cancelled"
                }
            }
            return
        }
        do {
            try dataController.openFile(url: url)
        } catch {
            handleOpenError(error)
        }
    }

    private func currentDetector() -> Detector {
        let pW = self.dataController.patternSize.width
        let pH = self.dataController.patternSize.height
        let center = NSPoint(x: max(0, min(CGFloat(pW - 1), detectorCenter.x)),
                             y: max(0, min(CGFloat(pH - 1), detectorCenter.y)))
        
        
        let clampedInnerRadius = min(detectorInnerRadius, detectorOuterRadius)
        let params:[DetectorParameter: Float]  = [.innerRadius:Float(clampedInnerRadius), .outerRadius:Float(detectorOuterRadius)]
        return Detector(shape: detectorShape, type: detectorType, center: center, params: params, size: NSSize(width: pW, height: pH))
    }
    private func dynamicStrideForTargetGrid(targetWidth: Int = 80, targetHeight: Int = 80) -> Int {
        let w = max(1, self.dataController.imageSize.width)
        let h = max(1, self.dataController.imageSize.height)
        // compute stride so that ceil(w/stride) ≈ targetWidth and ceil(h/stride) ≈ targetHeight
        let sx = max(1, Int(ceil(Double(w) / Double(targetWidth))))
        let sy = max(1, Int(ceil(Double(h) / Double(targetHeight))))
        return max(sx, sy)
    }
    
    
func computeScanImage(interactive: Bool = false)-> (NSImage, Matrix)? {
        let pW = self.dataController.patternSize.width
        let pH = self.dataController.patternSize.height
        if pW == 0 || pH == 0 { return nil }
        
        let det = currentDetector()

//        let baseStride = (stride > 0) ? stride : self.strideLength
        

        
        if interactive {
            stride = max(1, dynamicStrideForTargetGrid())
        } else {
            stride = 1
        }
                
        var mat: Matrix
        var tempImage:NSImage?
        
        switch calculationMode {
        case .integrate:
            mat = self.dataController.integrating(det, strideLength: stride)
        case .com:
            switch self.comAxis {
            case .x, .y:
                mat = self.dataController.com(det, strideLength: stride, xy: self.comAxis)
                
            case .color:

                let comX = self.dataController.com(det, strideLength: stride, xy: .x)
                let comY = self.dataController.com(det, strideLength: stride, xy: .y)
                
                guard let (img, m) = colorCom(comX, comY, removeDCOffset: true) else { return nil }
                tempImage = img
                mat = m
            
            }
        case .dpc:
            switch dpcAxis {
            case .leftRight, .upDown:
                // lrud: 1 = left-right, 0 = up-down (per STEMDataController.dpc)
                let lrud = (dpcAxis == .leftRight) ? 1 : 0
                mat = self.dataController.dpc(det, strideLength: stride, lrud: lrud)
            case .color:
                let dpcX = self.dataController.dpc(det, strideLength: stride, lrud: 1)
                let dpcY = self.dataController.dpc(det, strideLength: stride, lrud: 0)

                guard let (img, m) = colorCom(dpcX, dpcY, removeDCOffset: true) else { return nil }
                tempImage = img
                mat = m
            }
        }

        if tempImage == nil {
            tempImage = makeImage(from: mat)
        }
        
        if let tempImage = tempImage {
            
            if let finalImage = scaleStrideImage(tempImage, stride)
            {
                    return (finalImage, mat)
               
            }
        }

        return nil
            
        
    }
    
    private func colorCom(_ x: Matrix, _ y: Matrix, removeDCOffset: Bool = false) -> (NSImage, Matrix)? {
        

        let rows = x.rows
        let cols = x.columns
        let count = rows * cols
        guard rows == y.rows, cols == y.columns, count > 0 else { return nil }
        
        var xData = x.real
        var yData = y.real
        var validVector = [Bool](repeating: false, count: count)
        var finiteCount = 0
        var xSum: Float = 0
        var ySum: Float = 0

        for i in 0..<count {
            let xValue = xData[i]
            let yValue = yData[i]
            if xValue.isFinite && yValue.isFinite {
                validVector[i] = true
                finiteCount += 1
                xSum += xValue
                ySum += yValue
            } else {
                xData[i] = 0
                yData[i] = 0
            }
        }

        if removeDCOffset, finiteCount > 0 {
            let xMean = xSum / Float(finiteCount)
            let yMean = ySum / Float(finiteCount)
            for i in 0..<count where validVector[i] {
                xData[i] -= xMean
                yData[i] -= yMean
            }
        }
        
      
        var mag = [Float](repeating: 0, count: count)
        var hue = [Float](repeating: 0, count: count)
        
//        var cx = Float(detector.center.x)
//        var cy = Float(detector.center.y)
//        
//        vDSP_vsadd(shiftedX, 1, [-cx], &shiftedX, 1, vDSP_Length(count))
//        vDSP_vsadd(shiftedY, 1, [-cy], &shiftedY, 1, vDSP_Length(count))
        
        vDSP.hypot(xData, yData, result: &mag)
        
        // Use both vector components for the full 0...360 degree color wheel.
        // Negate y so image-space downward y maps to a conventional mathematical angle.
        var negY = [Float](repeating: 0, count: count)
        vDSP_vneg(yData, 1, &negY, 1, vDSP_Length(count))
        
        var ang = [Float](repeating: 0, count: count)
        var vectorLength = Int32(count)
        ang.withUnsafeMutableBufferPointer { angPtr in
            negY.withUnsafeBufferPointer { negYPtr in
                xData.withUnsafeBufferPointer { xPtr in
                    vvatan2f(angPtr.baseAddress!, negYPtr.baseAddress!, xPtr.baseAddress!, &vectorLength)
                }
            }
        }
        
        // Convert angle to hue [0,1)
        let twoPi = Float.pi * 2.0
        vDSP_vsdiv(ang, 1, [twoPi], &hue, 1, vDSP_Length(count))
        for i in 0..<count where hue[i] < 0 {
            hue[i] += 1.0
        }
        
        // Normalize magnitude via 95th percentile and map to Value (brightness)
        var val = mag
        var sorted = val
        sorted.sort()
        let idx = max(0, min(count - 1, Int(Float(count - 1) * 0.95)))
        let p95 = sorted[idx]
        let inv = (p95 > 0) ? (1.0 / p95) : 1.0
        if inv != 1.0 {
            val = vDSP.multiply(inv, val)
        }
        val = vDSP.clip(val, to: 0.0...1.0)

        // Use full saturation so hue is vivid while brightness encodes magnitude
        let sat = [Float](repeating: 1.0, count: count)

        // Convert HSV to RGB bytes (low magnitude -> black, high magnitude -> bright color)
        let rgbBytes = hsvToRGB(h: hue, s: sat, v: val)
        
        // Create BGRA pixel buffer
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, cols, rows, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(pb, [])
        
        if let baseAddress = CVPixelBufferGetBaseAddress(pb) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
            for row in 0..<rows {
                let rowPtr = baseAddress.advanced(by: row * bytesPerRow)
                for col in 0..<cols {
                    let srcIndex = (row * cols + col) * 3
                    let pixelPtr = rowPtr.advanced(by: col * 4)
                    let r = rgbBytes[srcIndex]
                    let g = rgbBytes[srcIndex + 1]
                    let b = rgbBytes[srcIndex + 2]
                    pixelPtr.storeBytes(of: b, as: UInt8.self)       // B
                    pixelPtr.advanced(by: 1).storeBytes(of: g, as: UInt8.self) // G
                    pixelPtr.advanced(by: 2).storeBytes(of: r, as: UInt8.self) // R
                    pixelPtr.advanced(by: 3).storeBytes(of: UInt8(255), as: UInt8.self) // A
                }
            }
        }
        
        CVPixelBufferUnlockBaseAddress(pb, [])
        
        let ciImage = CIImage(cvImageBuffer: pb)
        let context = CIContext(options: nil)

        if let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: cols, height: rows)){
            let image = NSImage(cgImage: cgImage, size: CGSize(width: cols, height: rows))
            let angMatrix  = Matrix(array: ang, rows, cols, type:.complex)
            let magMatrix = Matrix(array: mag, rows, cols)
            let mat = magMatrix + angMatrix
            
            if let mat = mat{
                return (image, mat)
            }
            
            return nil           
        }
        
        return nil
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

            if !hue.isFinite || !saturation.isFinite || !value.isFinite {
                rgb[i * 3] = 0
                rgb[i * 3 + 1] = 0
                rgb[i * 3 + 2] = 0

                continue
            }

            let c = value * saturation
            let x = c * (1 - abs(fmod(hue, 2.0) - 1))
            let m = value - c
            
            var r1: Float = 0
            var g1: Float = 0
            var b1: Float = 0
            
            if hue.isNaN{
                rgb[i * 3] = 0
                rgb[i * 3 + 1] = 0
                rgb[i * 3 + 2] = 0
                
                continue
            }
            
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
    
    private func scaleStrideImage(_ image: NSImage,_ stride:Int) -> NSImage?{
        
        if stride != 1{
            let tempSize = image.size

            let newSize = NSSize(width: tempSize.width * CGFloat(stride), height: tempSize.height * CGFloat(stride))
            let newImage = NSImage(size: newSize)

            newImage.lockFocus()
            
            // Draw the source image into the new size rectangle
            image.draw(in: NSRect(origin: .zero, size: newSize),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .sourceOver,
                       fraction: 1.0)
            
            newImage.unlockFocus()
            return newImage
        }else{
            return image
        }
        
    }

    func getPatternImage(rect: CGRect)->(NSImage, Matrix)?{
                
        if selectionMode == .marquee{
            
            let avgMatrix = self.dataController.averagePattern(rect: rect)
            
            if let avgImg = makeImage(from: avgMatrix){
                return (avgImg, avgMatrix)
            }
            return nil
            
            

            
        }
        return nil
        
    }
    
    func getPatternImage(i: Int, j: Int)->(NSImage, Matrix)? {
        
        if let m = self.dataController.pattern(i, j) {
            if let pattern = makeImage(from: m){
                
                return (pattern, m)
            }
        }

        return nil
        
    }
    
    func makeImage(from m:Matrix)->NSImage? {
        
        let width = m.columns
        let height = m.rows
        
        if let cgImg = m.uInt8ImageRep()?.cgImage{
            return NSImage(cgImage: cgImg, size: NSSize(width: width, height: height))
        }
        
        return nil
        
    }
    
    private func hsvToRGB(h: [Float], s: Float, v: [Float]) -> [UInt8] {
        let count = min(h.count, v.count)
        var rgb = [UInt8](repeating: 0, count: count * 3)
        for i in 0..<count {
            // Clamp inputs
            let H = max(0.0, min(1.0, h[i]))
            let S = max(0.0, min(1.0, s))
            let V = max(0.0, min(1.0, v[i]))

            // Use NSColor to convert HSV (HSB) to RGB in sRGB space
            let color = NSColor(hue: CGFloat(H), saturation: CGFloat(S), brightness: CGFloat(V), alpha: 1.0)
            let srgb = color.usingColorSpace(.sRGB) ?? color
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            srgb.getRed(&r, green: &g, blue: &b, alpha: &a)

            rgb[i*3 + 0] = UInt8(min(max(r * 255.0, 0.0), 255.0))
            rgb[i*3 + 1] = UInt8(min(max(g * 255.0, 0.0), 255.0))
            rgb[i*3 + 2] = UInt8(min(max(b * 255.0, 0.0), 255.0))
        }
        return rgb
    }
}

extension DataViewModel: STEMDataControllerDelegate {

    func didFinishLoadingData() -> (pattern:NSImage?, virtual:NSImage?) {
        isLoading = false
        loadErrorMessage = nil
        if let url = selectedURL {
            status = "Loaded: \(url.lastPathComponent)"
        } else {
            status = "Loaded"
        }
        self.imageWidth = self.dataController.imageSize.width
        self.imageHeight = self.dataController.imageSize.height
        self.patternSize.width = self.dataController.patternSize.width
        self.patternSize.height = self.dataController.patternSize.height
        self.detectorCenter = CGPoint(x: CGFloat(self.patternSize.width) / 2.0, y: CGFloat(self.patternSize.height) / 2.0)
        
        if dataController.pattern(0, 0) != nil {
            let pW = self.dataController.patternSize.width
            let pH = self.dataController.patternSize.height
            let base = CGFloat(min(pW, pH))
            self.detectorInnerRadius = 1
            self.detectorOuterRadius = base * 0.15
            self.detectorShape = .bf
            self.detectorType = .integrating
            self.calculationMode = .integrate
            self.dpcAxis = .leftRight
            self.comAxis = .x
        }
        
        return (nil, nil)
    }

    func didFailLoadingData(_ error: Error) {
        handleOpenError(error)
    }

    func cancel(_ sender: Any) {
        isLoading = false
        status = "Cancelled"
    }
}
