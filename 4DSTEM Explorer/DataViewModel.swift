import Foundation
import Cocoa
import CoreVideo
import QuartzCore
import Accelerate
import SwiftUI

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
}

enum DPCAxis: Hashable {
    case leftRight // maps to lrud = 1 in STEMDataController.dpc
    case upDown    // maps to lrud = 0 in STEMDataController.dpc
}

enum COMAxis:  Int, Hashable {
    case x
    case y
    case color
}

//    var id: String { rawValue } }


final class DataViewModel: NSObject, ObservableObject {
    // Drag/continuous update support
    private var lastDragUpdate: TimeInterval = 0
    private let dragUpdateInterval: TimeInterval = 0.012 // ~83 Hz
    @Published var isDragging: Bool = false

    private var fullResRecomputeWorkItem: DispatchWorkItem?

    @Published var selectedURL: URL?
    @Published var status: String = "Idle"
    @Published var progress: Double = 0.0
    @Published var isLoading: Bool = false
    @Published var lastProgressTick: Int = 0
    @Published var pixelBuffer: CVPixelBuffer?
    @Published var scanPixelBuffer: CVPixelBuffer?
    @Published var scanImage: NSImage?
    @Published var imageWidth: Int = 0
    @Published var imageHeight: Int = 0
    @Published var selectedI: Int = 0
    @Published var selectedJ: Int = 0
    @Published var selectionRect: CGRect? = nil

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

    func scheduleFullResRecompute(after delay: TimeInterval = 0.35) {
        fullResRecomputeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.computeScanImage()
        }
        fullResRecomputeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
    private var imageUpdateObserver: NSObjectProtocol?

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
    private func promptForRawDimensions(suggested: (w: Int?, h: Int?), completion: @escaping ((w: Int, h: Int)?) -> Void) {
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
        var result: (Int, Int)? = nil

        // SwiftUI content
        struct RawDimsSheet: View {
            @State var text: String
            let fileHint: String
            let onCancel: () -> Void
            let onOK: (String) -> Void

            var body: some View {
                VStack(spacing: 12) {
                    HStack {
                        Text("RAW Scan Dimensions").font(.title2).bold()
                        Spacer()
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter the number of scan positions as “X×Y” (e.g., 80x80).").foregroundStyle(.secondary)
                        if !fileHint.isEmpty {
                            Text(fileHint).font(.footnote).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Scan size (X×Y):")
                            TextField("80x80", text: $text)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        Button("Cancel") { onCancel() }
                        Button("OK") { onOK(text) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .frame(minWidth: 200, minHeight: 220)
            }
        }

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

        let hosting = NSHostingView(rootView: RawDimsSheet(text: defaultString, fileHint: fileHint, onCancel: {
            if let parent = panel.sheetParent {
                parent.endSheet(panel, returnCode: .cancel)
                DispatchQueue.main.async { completion(nil) }
            } else {
                NSApp.stopModal(withCode: .cancel)
                panel.close()
                DispatchQueue.main.async { completion(nil) }
            }
        }, onOK: { text in
            if let xy = parseXY(text) {
                result = xy
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
        } catch FileReadError.invalidTiff {
            self.isLoading = false
            self.status = "Selected image is incompatible. Please select an EMPAD tiff stack."
        } catch FileReadError.invalidRaw {
            self.isLoading = false
            self.status = "Invalid RAW file. Check dimensions and try again."
        } catch FileReadError.invalidDimensions {
            self.isLoading = false
            self.status = "Incorrect dimensions for the file."
        } catch FileReadError.notDiffractionSI {
            self.isLoading = false
            self.status = "DM File does not contain a diffraction SI dataset."
        } catch {
            self.isLoading = false
            self.status = "Something went wrong loading the file."
        }
    }

    func open(url: URL) {
        selectedURL = url
        status = "Preparing to load \(url.lastPathComponent)…"
        isLoading = true
        dataController.filePath = url
        if url.pathExtension.lowercased() == "raw" {
            let suggested = suggestRawDimensions(from: url)
            promptForRawDimensions(suggested: suggested) { [weak self] dims in
                guard let self = self else { return }
                if let dims = dims {
                    self.dataController.setRawImageSize(width: dims.w, height: dims.h)
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
    private func dynamicStrideForTargetGrid(targetWidth: Int = 80, targetHeight: Int = 80) -> Int {
        let w = max(1, self.dataController.imageSize.width)
        let h = max(1, self.dataController.imageSize.height)
        // compute stride so that ceil(w/stride) ≈ targetWidth and ceil(h/stride) ≈ targetHeight
        let sx = max(1, Int(ceil(Double(w) / Double(targetWidth))))
        let sy = max(1, Int(ceil(Double(h) / Double(targetHeight))))
        return max(sx, sy)
    }

#if DEBUG
    private func debugGradientImageX() {
        let w = max(1, dataController.imageSize.width)
        let h = max(1, dataController.imageSize.height)
        let rows = h
        let cols = w
        var arr = [Float](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                arr[r * cols + c] = Float(c) / Float(max(1, cols - 1)) // increases across columns
            }
        }
        let mat = Matrix(array: arr, rows, cols)
        self.scanPixelBuffer = makePixelBuffer(from: mat)
    }

    private func debugGradientImageY() {
        let w = max(1, dataController.imageSize.width)
        let h = max(1, dataController.imageSize.height)
        let rows = h
        let cols = w
        var arr = [Float](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            let v = Float(r) / Float(max(1, rows - 1)) // increases down rows
            for c in 0..<cols {
                arr[r * cols + c] = v
            }
        }
        let mat = Matrix(array: arr, rows, cols)
        self.scanPixelBuffer = makePixelBuffer(from: mat)
    }
#endif
    
    func nsImage() -> NSImage? {
        if let pixelBuffer = self.scanPixelBuffer{
            // 1. Create a CIImage from the pixel buffer
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            
            // 2. Initialize a CIContext for rendering
            let context = CIContext(options: nil)
            
            // 3. Create a CGImage from the CIImage
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let extent = CGRect(x: 0, y: 0, width: width, height: height)
            
            guard let cgImage = context.createCGImage(ciImage, from: extent) else {
                return nil
            }
            
            // 4. Create the final NSImage
            return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        }
        return nil
        
    }

//    func computeScanImage() {
//        let pW = self.dataController.patternSize.width
//        let pH = self.dataController.patternSize.height
//        if pW == 0 || pH == 0 { return }
//        let det = currentDetector()
//        let mat = self.dataController.integrating(det, strideLength: 1)
//        self.scanPixelBuffer = makePixelBuffer(from: mat)
//    }
    func computeScanImage(stride: Int = 0, interactive: Bool = false) {
        let pW = self.dataController.patternSize.width
        let pH = self.dataController.patternSize.height
        if pW == 0 || pH == 0 { return }
        let det = currentDetector()

        let baseStride = (stride > 0) ? stride : self.strideLength
        let strideLen: Int
        if interactive {
            strideLen = max(1, dynamicStrideForTargetGrid())
        } else {
            strideLen = max(1, baseStride)
        }
        let mat: Matrix
        switch calculationMode {
        case .integrate:
            mat = self.dataController.integrating(det, strideLength: strideLen)
        case .com:
            switch self.comAxis {
            case .x, .y:
                mat = self.dataController.com(det, strideLength: strideLen, xy: self.comAxis)
            case .color:
                if let pb = self.dataController.comColor(det, strideLength: strideLen) {
                    DispatchQueue.main.async { [weak self] in
                        self?.scanPixelBuffer = pb
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.scanPixelBuffer = nil
                    }
                }
                return
            }
        case .dpc:
            // lrud: 1 = left-right, 0 = up-down (per STEMDataController.dpc)
            let lrud = (dpcAxis == .leftRight) ? 1 : 0
            mat = self.dataController.dpc(det, strideLength: strideLen, lrud: lrud)
        }
        self.scanPixelBuffer = makePixelBuffer(from: mat)
    }

    func select(i: Int, j: Int) {
        self.selectedI = max(0, min(i, max(0, self.dataController.imageSize.height - 1)))
        self.selectedJ = max(0, min(j, max(0, self.dataController.imageSize.width - 1)))

        if selectionMode == .point {
            if let m = self.dataController.pattern(self.selectedI, self.selectedJ) {
                self.pixelBuffer = makePixelBuffer(from: m)
            } else {
                self.pixelBuffer = nil
            }
        } else {
            beginMarquee(atI: self.selectedI, j: self.selectedJ)
        }
    }

    func beginMarquee(atI i0: Int, j j0: Int) {
        selectionRect = CGRect(x: j0, y: i0, width: 0, height: 0)
        updatePatternForCurrentSelection(interactive: true)
    }

    func updateMarquee(toI i1: Int, j j1: Int) {
        guard var rect = selectionRect else { return }
        rect.size.width = CGFloat(j1) - rect.origin.x
        rect.size.height = CGFloat(i1) - rect.origin.y
        selectionRect = rect
        updatePatternForCurrentSelection(interactive: true)
    }

    func endMarquee(atI i1: Int, j j1: Int) {
        updateMarquee(toI: i1, j: j1)
        updatePatternForCurrentSelection(interactive: false)
    }

    func updatePatternForCurrentSelection(interactive: Bool = false) {
        guard imageWidth > 0, imageHeight > 0 else { return }

        switch selectionMode {
        case .point:
            if let m = self.dataController.pattern(self.selectedI, self.selectedJ) {
                self.pixelBuffer = makePixelBuffer(from: m)
            } else {
                self.pixelBuffer = nil
            }

        case .marquee:
            guard var rect = selectionRect else { return }
            rect = normalizedRect(rect, maxWidth: imageWidth, maxHeight: imageHeight)
            if rect.width <= 0.0 || rect.height <= 0.0 {
                if let m = self.dataController.pattern(Int(rect.origin.y), Int(rect.origin.x)) {
                    self.pixelBuffer = makePixelBuffer(from: m)
                } else {
                    self.pixelBuffer = nil
                }
                return
            }
            let avg = self.dataController.averagePattern(rect: NSRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.size.width,
                height: rect.size.height
            ))
            self.pixelBuffer = makePixelBuffer(from: avg)
        }
    }

    private func normalizedRect(_ rect: CGRect, maxWidth: Int, maxHeight: Int) -> CGRect {
        var r = rect
        if r.width < 0 { r.origin.x += r.width; r.size.width = -r.width }
        if r.height < 0 { r.origin.y += r.height; r.size.height = -r.height }
        r.origin.x = max(0, min(CGFloat(maxWidth - 1), r.origin.x))
        r.origin.y = max(0, min(CGFloat(maxHeight - 1), r.origin.y))
        r.size.width = max(0, min(CGFloat(maxWidth) - r.origin.x, r.size.width))
        r.size.height = max(0, min(CGFloat(maxHeight) - r.origin.y, r.size.height))
        return r
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

    private func hsvToRGB(h: [Float], s: [Float], v: [Float]) -> [UInt8] {
        let count = min(h.count, min(s.count, v.count))
        var rgb = [UInt8](repeating: 0, count: count * 3)
        for i in 0..<count {
            // Clamp inputs
            let H = max(0.0, min(1.0, h[i]))
            let S = max(0.0, min(1.0, s[i]))
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
//            self.computeScanImage()
            let centerI = max(0, self.dataController.imageSize.height / 2)
            let centerJ = max(0, self.dataController.imageSize.width / 2)
            self.select(i: centerI, j: centerJ)
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

