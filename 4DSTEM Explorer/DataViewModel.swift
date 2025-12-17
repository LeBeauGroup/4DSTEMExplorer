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
        let mat = self.dataController.integrating(det, strideLength: max(1, stride))
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
            self.computeScanImage()
        }
    }

    func cancel(_ sender: Any) {
        isLoading = false
        status = "Cancelled"
    }
}

