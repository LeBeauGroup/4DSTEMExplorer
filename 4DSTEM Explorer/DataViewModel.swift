import Foundation
import Cocoa
import CoreVideo

final class DataViewModel: NSObject, ObservableObject {
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

    @Published var detectorShape: DetectorShape = .bf
    @Published var detectorType: DetectorType = .integrating
    @Published var detectorInnerRadius: CGFloat = 0
    @Published var detectorOuterRadius: CGFloat = 10

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

    func computeScanImage() {
        let pW = self.dataController.patternSize.width
        let pH = self.dataController.patternSize.height
        if pW == 0 || pH == 0 { return }
        let det = currentDetector()
        let mat = self.dataController.integrating(det, strideLength: 1)
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
