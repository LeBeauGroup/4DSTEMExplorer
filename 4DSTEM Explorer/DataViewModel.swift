import Foundation
import Cocoa
import CoreVideo
import QuartzCore

// Temporary local definitions to make the toolbar compile.
// If your project already defines these elsewhere, you can remove these and import/use the shared ones.
enum SelectionMode: Hashable {
    case point
    case marquee
}

enum CalculationMode: Hashable {
    case integrate
    case com
    case dpc
    case comColor
}

enum DPCAxis: Hashable {
    case leftRight // maps to lrud = 1 in STEMDataController.dpc
    case upDown    // maps to lrud = 0 in STEMDataController.dpc
}

enum COMAxis:  Int, Hashable {
    case x
    case y
}

//    var id: String { rawValue } }


final class DataViewModel: NSObject, ObservableObject {
    // Drag/continuous update support
    private var lastDragUpdate: TimeInterval = 0
    private let dragUpdateInterval: TimeInterval = 0.012 // ~83 Hz
    @Published var isDragging: Bool = false

    @Published var selectedURL: URL?
    @Published var status: String = "Idle"
    @Published var isLoading: Bool = false
    @Published var lastProgressTick: Int = 0
    @Published var pixelBuffer: CVPixelBuffer?
    @Published var scanPixelBuffer: CVPixelBuffer?
    @Published var imageWidth: Int = 0
    @Published var imageHeight: Int = 0
    @Published var selectedI: Int = 0
    @Published var selectedJ: Int = 0

    @Published var patternSize: IntSize = .init(width: 32, height: 32)

    @Published var detectorShape: DetectorShape = .bf
    @Published var detectorType: DetectorType = .integrating
    @Published var detectorInnerRadius: CGFloat = 0
    @Published var detectorOuterRadius: CGFloat = 10
    
    // Selection mode used by the Picker in the toolbar
    @Published var selectionMode: SelectionMode = .point
    // Current zoom scale (0.0 ... 1.0 for percent formatting)
    @Published var currentScale: Double = 1.0

    @Published var calculationMode: CalculationMode = .integrate
    @Published var strideLength: Int = 1
    @Published var dpcAxis: DPCAxis = .leftRight
    @Published var comAxis: COMAxis = .x

    // Export actions used by the toolbar
    func exportImage() { /* TODO: implement */ }
    func exportPattern() { /* TODO: implement */ }

    // Zoom controls used by the toolbar
    func zoomIn() { currentScale *= 1.1 }
    func zoomOut() { currentScale /= 1.1 }
    func setScale(_ scale: Double) { currentScale = scale }

    // MARK: - Drag-driven selection updates
    func beginDrag() {
        isDragging = true
        lastDragUpdate = 0
    }

    func endDrag() {
        isDragging = false
    }

    /// Update selection continuously from a point in the scan image view's coordinate space.
    /// - Parameters:
    ///   - location: The location in the view's coordinate space (origin at top-left for SwiftUI GeometryReader by default).
    ///   - viewSize: The size of the view that renders the scan image.
    ///   - throttle: If true, limits update rate to `dragUpdateInterval`.
    func updateSelection(at location: CGPoint, in viewSize: CGSize, throttle: Bool = true) {
        let now = CACurrentMediaTime()
        if throttle {
            if now - lastDragUpdate < dragUpdateInterval { return }
            lastDragUpdate = now
        }

        let imgW = max(1, self.dataController.imageSize.width)
        let imgH = max(1, self.dataController.imageSize.height)
        let vW = max(1.0, Double(viewSize.width))
        let vH = max(1.0, Double(viewSize.height))

        // Map view-space point to image indices. Assume the scan image is aspect-fit inside the view.
        // Compute aspect-fit rect of the image within the view to handle letterboxing.
        let imgAspect = Double(imgW) / Double(imgH)
        let viewAspect = vW / vH

        var drawRect = CGRect(origin: .zero, size: CGSize(width: vW, height: vH))
        if imgAspect > viewAspect {
            // Image is wider than view: full width, vertical letterboxing
            let drawHeight = vW / imgAspect
            let yOffset = (vH - drawHeight) / 2.0
            drawRect = CGRect(x: 0, y: yOffset, width: vW, height: drawHeight)
        } else {
            // Image is taller than view: full height, horizontal letterboxing
            let drawWidth = vH * imgAspect
            let xOffset = (vW - drawWidth) / 2.0
            drawRect = CGRect(x: xOffset, y: 0, width: drawWidth, height: vH)
        }

        // Convert location to normalized coordinates within drawRect
        let x = Double(location.x)
        let y = Double(location.y)
        guard drawRect.width > 0 && drawRect.height > 0 else { return }
        let nx = (x - Double(drawRect.minX)) / Double(drawRect.width)
        let ny = (y - Double(drawRect.minY)) / Double(drawRect.height)

        // If outside the drawn image area, clamp to edges
        let clampedNX = min(max(nx, 0.0), 1.0)
        let clampedNY = min(max(ny, 0.0), 1.0)

        // Map to image indices. Note: SwiftUI's origin is top-left in GeometryReader, so y increases downward already.
        let j = Int(round(clampedNX * Double(imgW - 1)))
        let i = Int(round(clampedNY * Double(imgH - 1)))

        self.select(i: i, j: j)
    }

    private let dataController = STEMDataController()
    private var progressObserver: NSObjectProtocol?

    override init() {
        super.init()
        dataController.delegate = self
        dataController.progressdelegate = self

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
                }
            }
        }
    }

    deinit {
        if let obs = progressObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func open(url: URL) {
        selectedURL = url
        status = "Preparing to load \(url.lastPathComponent)…"
        isLoading = true
        dataController.filePath = url
        do {
            try dataController.openFile(url: url)
        } catch FileReadError.invalidTiff {
            isLoading = false
            status = "Selected image is incompatible. Please select an EMPAD tiff stack."
        } catch FileReadError.invalidRaw {
            isLoading = false
            status = "Invalid RAW file. Check dimensions and try again."
        } catch FileReadError.invalidDimensions {
            isLoading = false
            status = "Incorrect dimensions for the file."
        } catch FileReadError.notDiffractionSI {
            isLoading = false
            status = "DM File does not contain a diffraction SI dataset."
        } catch {
            isLoading = false
            status = "Something went wrong loading the file."
        }
    }

    private func currentDetector() -> Detector {
        let pW = self.dataController.patternSize.width
        let pH = self.dataController.patternSize.height
        let center = NSPoint(x: CGFloat(pW) / 2.0, y: CGFloat(pH) / 2.0)
        let radii = DetectorRadii(inner: detectorInnerRadius, outer: detectorOuterRadius)
        return Detector(shape: detectorShape, type: detectorType, center: center, radii: radii, size: NSSize(width: pW, height: pH))
    }

//    func computeScanImage() {
//        let pW = self.dataController.patternSize.width
//        let pH = self.dataController.patternSize.height
//        if pW == 0 || pH == 0 { return }
//        let det = currentDetector()
//        let mat = self.dataController.integrating(det, strideLength: 1)
//        self.scanPixelBuffer = makePixelBuffer(from: mat)
//    }
    func computeScanImage(stride: Int=0) {
        let pW = self.dataController.patternSize.width
        let pH = self.dataController.patternSize.height
        if pW == 0 || pH == 0 { return }
        let det = currentDetector()

        let strideLen = max(1, stride > 0 ? stride : self.strideLength)
        let mat: Matrix
        switch calculationMode {
        case .integrate:
            mat = self.dataController.integrating(det, strideLength: strideLen)
        case .com:
            // xy: 0 = x, 1 = y. For now, use x; extend UI if you want both.
            mat = self.dataController.com(det, strideLength: strideLen, xy: self.comAxis)
        case .dpc:
            // lrud: 1 = left-right, 0 = up-down (per STEMDataController.dpc)
            let lrud = (dpcAxis == .leftRight) ? 1 : 0
            mat = self.dataController.dpc(det, strideLength: strideLen, lrud: lrud)
        case .comColor:
            // Compute COM X and Y
            let comX = self.dataController.com(det, strideLength: 1, xy: COMAxis.x)
            let comY = self.dataController.com(det, strideLength: 1, xy: COMAxis.y)
            let rows = comX.rows
            let cols = comX.columns
            let count = rows * cols

            // Build magnitude and angle arrays
            var hue = [Float](repeating: 0, count: count)
            var mag = [Float](repeating: 0, count: count)

            // Accessors: assuming Matrix provides `real` contiguous floats
            let xData = comX.real
            let yData = comY.real
            for idx in 0..<count {
                let x = xData[idx]
                let y = yData[idx]
                let m = hypotf(x, y)
                let ang = atan2f(-y, x) // [-pi, pi]
                var h = (ang + Float.pi) / (2.0 * Float.pi) // -> [0,1]
                if h < 0 { h += 1 }
                if h > 1 { h -= 1 }
                hue[idx] = h
                mag[idx] = m
            }

            // Angle-only visualization: full saturation and value
            let sat = [Float](repeating: 1.0, count: count)
            let valArr = [Float](repeating: 1.0, count: count)

            let rgb = hsvToRGB(h: hue, s: sat, v: valArr)
            self.scanPixelBuffer = makeRGBPixelBuffer(fromRGB: rgb, width: cols, height: rows)
            return
        }
        self.scanPixelBuffer = makePixelBuffer(from: mat)
    }

    func select(i: Int, j: Int) {
        self.selectedI = max(0, min(i, max(0, self.dataController.imageSize.height - 1)))
        self.selectedJ = max(0, min(j, max(0, self.dataController.imageSize.width - 1)))
        if let m = self.dataController.pattern(self.selectedI, self.selectedJ) {
            self.pixelBuffer = makePixelBuffer(from: m)
            self.status = "Pattern (i=\(self.selectedI), j=\(self.selectedJ))"
        }
    }

    private func makePixelBuffer(from matrix: Matrix) -> CVPixelBuffer? {
        let width = matrix.columns
        let height = matrix.rows

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_OneComponent8,
                                         attrs as CFDictionary,
                                         &pixelBuffer)
        if status != kCVReturnSuccess { return nil }
        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)

        // Scale to 8-bit and copy row by row
        var src = matrix.realUint8()
        src.withUnsafeMutableBytes { raw in
            let srcPtr = raw.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<height {
                let dstRow = base.advanced(by: y * bytesPerRow)
                let srcRow = srcPtr.advanced(by: y * width)
                memcpy(dstRow, srcRow, width)
            }
        }

        return pb
    }

    private func robustMinMax(_ values: inout [Float], lowPercentile: Float = 0.02, highPercentile: Float = 0.98) -> (Float, Float) {
        // Copy and partially sort to estimate percentiles
        var sorted = values
        sorted.sort()
        let n = sorted.count
        if n == 0 { return (0, 1) }
        let loIdx = max(0, min(n - 1, Int(Float(n - 1) * lowPercentile)))
        let hiIdx = max(0, min(n - 1, Int(Float(n - 1) * highPercentile)))
        return (sorted[loIdx], sorted[hiIdx])
    }

    private func hsvToRGB(h: [Float], s: Float, v: [Float]) -> [UInt8] {
        let count = min(h.count, v.count)
        var rgb = [UInt8](repeating: 0, count: count * 3)
        for i in 0..<count {
            var H = h[i]
            var V = v[i]
            // Clamp inputs
            if H < 0 { H = 0 } else if H > 1 { H = 1 }
            if V < 0 { V = 0 } else if V > 1 { V = 1 }
            let S = max(0, min(s, 1))

            let h6 = H * 6
            let c = V * S
            let x = c * (1 - fabsf(fmodf(h6, 2) - 1))
            let m = V - c

            let r1, g1, b1: Float
            switch h6 {
            case 0..<1: (r1, g1, b1) = (c, x, 0)
            case 1..<2: (r1, g1, b1) = (x, c, 0)
            case 2..<3: (r1, g1, b1) = (0, c, x)
            case 3..<4: (r1, g1, b1) = (0, x, c)
            case 4..<5: (r1, g1, b1) = (x, 0, c)
            default:    (r1, g1, b1) = (c, 0, x)
            }

            let r = r1 + m
            let g = g1 + m
            let b = b1 + m

            rgb[i*3 + 0] = UInt8(min(max(r * 255, 0), 255))
            rgb[i*3 + 1] = UInt8(min(max(g * 255, 0), 255))
            rgb[i*3 + 2] = UInt8(min(max(b * 255, 0), 255))
        }
        return rgb
    }

    private func hsvToRGB(h: [Float], s: [Float], v: [Float]) -> [UInt8] {
        let count = min(h.count, min(s.count, v.count))
        var rgb = [UInt8](repeating: 0, count: count * 3)
        for i in 0..<count {
            var H = h[i]
            var V = v[i]
            var S = s[i]
            // Clamp inputs
            if H < 0 { H = 0 } else if H > 1 { H = 1 }
            if V < 0 { V = 0 } else if V > 1 { V = 1 }
            if S < 0 { S = 0 } else if S > 1 { S = 1 }

            let h6 = H * 6
            let c = V * S
            let x = c * (1 - fabsf(fmodf(h6, 2) - 1))
            let m = V - c

            let r1, g1, b1: Float
            switch h6 {
            case 0..<1: (r1, g1, b1) = (c, x, 0)
            case 1..<2: (r1, g1, b1) = (x, c, 0)
            case 2..<3: (r1, g1, b1) = (0, c, x)
            case 3..<4: (r1, g1, b1) = (0, x, c)
            case 4..<5: (r1, g1, b1) = (x, 0, c)
            default:    (r1, g1, b1) = (c, 0, x)
            }

            let r = r1 + m
            let g = g1 + m
            let b = b1 + m

            rgb[i*3 + 0] = UInt8(min(max(r * 255, 0), 255))
            rgb[i*3 + 1] = UInt8(min(max(g * 255, 0), 255))
            rgb[i*3 + 2] = UInt8(min(max(b * 255, 0), 255))
        }
        return rgb
    }

    private func makeRGBPixelBuffer(fromRGB rgb: [UInt8], width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pixelBuffer)
        if status != kCVReturnSuccess { return nil }
        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)

        // Pack RGB into BGRA with A = 255
        for y in 0..<height {
            let dstRow = base.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let srcIdx = (y * width + x) * 3
                let dstIdx = x * 4
                let r = rgb[srcIdx + 0]
                let g = rgb[srcIdx + 1]
                let b = rgb[srcIdx + 2]
                dstRow[dstIdx + 0] = b
                dstRow[dstIdx + 1] = g
                dstRow[dstIdx + 2] = r
                dstRow[dstIdx + 3] = 255
            }
        }
        return pb
    }
}

extension DataViewModel: STEMDataControllerDelegate, STEMDataControllerProgressDelegate {
    func didFinishLoadingData() {
        isLoading = false
        if let url = selectedURL {
            status = "Loaded: \(url.lastPathComponent)"
        } else {
            status = "Loaded"
        }
        self.imageWidth = self.dataController.imageSize.width
        self.imageHeight = self.dataController.imageSize.height
        self.patternSize.width = self.dataController.patternSize.width
        self.patternSize.height = self.dataController.patternSize.height
        if let m = dataController.pattern(0, 0) {
            self.pixelBuffer = makePixelBuffer(from: m)
            self.computeScanImage()
            self.select(i: 0, j: 0)
            let pW = self.dataController.patternSize.width
            let pH = self.dataController.patternSize.height
            let base = CGFloat(min(pW, pH))
            self.detectorInnerRadius = 0
            self.detectorOuterRadius = base * 0.15
            self.detectorShape = .bf
            self.detectorType = .integrating
            self.calculationMode = .integrate
            self.strideLength = 1
            self.dpcAxis = .leftRight
            self.comAxis = .x
            self.computeScanImage()
        }
    }

    func cancel(_ sender: Any) {
        isLoading = false
        status = "Cancelled"
    }
}

