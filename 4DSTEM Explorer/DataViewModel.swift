import Foundation
import Cocoa
import CoreVideo
import QuartzCore
import Accelerate
import SwiftUI
import UniformTypeIdentifiers

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

enum FocusedPanel { case image, pattern }

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

struct DetectorConfiguration: Identifiable, Equatable {
    let id: UUID
    var name: String
    var shape: DetectorShape
    var type: DetectorType
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    var center: CGPoint
    var calculationMode: CalculationMode
    var color: Color
    var dpcAxis: DPCAxis
    var comAxis: COMAxis

    init(
        id: UUID = UUID(),
        name: String,
        shape: DetectorShape = .bf,
        type: DetectorType = .integrating,
        innerRadius: CGFloat = 1,
        outerRadius: CGFloat = 10,
        center: CGPoint = .zero,
        calculationMode: CalculationMode = .integrate,
        color: Color = .white,
        dpcAxis: DPCAxis = .leftRight,
        comAxis: COMAxis = .x
    ) {
        self.id = id
        self.name = name
        self.shape = shape
        self.type = type
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.center = center
        self.calculationMode = calculationMode
        self.color = color
        self.dpcAxis = dpcAxis
        self.comAxis = comAxis
    }
}

//    var id: String { rawValue } }


final class DataViewModel: NSObject, ObservableObject {
    private static let initialDetectorID = UUID()
    private var nextDetectorNumber = 2
    private var isApplyingDetectorSelection = false

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

    @Published var detectors: [DetectorConfiguration] = [
        DetectorConfiguration(id: DataViewModel.initialDetectorID, name: "Detector 1")
    ]
    @Published var selectedDetectorID: DetectorConfiguration.ID? = DataViewModel.initialDetectorID {
        didSet {
            applySelectedDetector()
        }
    }
    @Published var selectedDetectorIDs: Set<DetectorConfiguration.ID> = [DataViewModel.initialDetectorID] {
        didSet {
            guard !isApplyingDetectorSelection else { return }
            // Keep the primary within the new selection if possible; otherwise pick any
            if let primary = selectedDetectorID, selectedDetectorIDs.contains(primary) {
                // primary is still valid
            } else {
                selectedDetectorID = selectedDetectorIDs.first
            }
        }
    }
    @Published var detectorShape: DetectorShape = .bf {
        didSet {
            syncSelectedDetector { $0.shape = detectorShape }
        }
    }
    @Published var detectorType: DetectorType = .integrating {
        didSet {
            syncSelectedDetector { $0.type = detectorType }
        }
    }
    @Published var detectorInnerRadius: CGFloat = 1 {
        didSet {
            syncSelectedDetector { $0.innerRadius = detectorInnerRadius }
            balanceRadii(after: .inner)
        }
    }
    @Published var detectorOuterRadius: CGFloat = 10 {
        didSet {
            syncSelectedDetector { $0.outerRadius = detectorOuterRadius }
            balanceRadii(after: .outer)
        }
    }

    // MARK: Keeping the annulus open
    //
    // The rule lives here rather than in the sliders because the sliders are
    // not the only thing that writes these: dragging the detector's rim on the
    // pattern sets both directly, and a stored detector restores both. A fix
    // applied only to the controls would leave the drag able to close the
    // annulus.

    private enum MovedRadius { case inner, outer }
    private var isBalancingRadii = false

    /// The largest radius that fits on the detector.
    var maximumDetectorRadius: CGFloat {
        return CGFloat(min(patternSize.width, patternSize.height)) / 2
    }

    var innerRadiusRange: ClosedRange<Double> {
        return DetectorRadii.innerRange(ceiling: maximumDetectorRadius)
    }
    var outerRadiusRange: ClosedRange<Double> {
        return DetectorRadii.outerRange(ceiling: maximumDetectorRadius)
    }

    /// Moves whichever radius was *not* just set, so the two keep their gap.
    ///
    /// Re-entrant by nature — correcting one radius sets the other, which comes
    /// straight back through here — so the flag stops the second pass. It stops
    /// only the balancing: the write still reaches the stored detector, because
    /// that happens before this is called.
    private func balanceRadii(after moved: MovedRadius) {
        guard !isBalancingRadii, !isApplyingDetectorSelection else { return }
        isBalancingRadii = true
        defer { isBalancingRadii = false }

        let ceiling = maximumDetectorRadius
        let settled: DetectorRadii
        switch moved {
        case .inner:
            settled = DetectorRadii.movingInner(to: detectorInnerRadius,
                                                outer: detectorOuterRadius,
                                                ceiling: ceiling)
        case .outer:
            settled = DetectorRadii.movingOuter(to: detectorOuterRadius,
                                                inner: detectorInnerRadius,
                                                ceiling: ceiling)
        }
        if settled.inner != detectorInnerRadius { detectorInnerRadius = settled.inner }
        if settled.outer != detectorOuterRadius { detectorOuterRadius = settled.outer }
    }
    @Published var detectorCenter: CGPoint = .zero {
        didSet {
            syncSelectedDetector { $0.center = detectorCenter }
        }
    }
    
    // Selection mode used by the Picker in the toolbar
    @Published var selectionMode: InteractiveMarkerView.SelectionMode = .point
    // Current zoom scale (0.0 ... 1.0 for percent formatting)
    @Published var currentScale: Double = 1.0
    // When true, the ImageViewerRepresentable will compute and apply a fit-to-window zoom without changing currentScale.
    @Published var zoomToFitEnabled: Bool = true
    // Stores the last computed fit-to-window scale so we can seed currentScale when exiting zoom-to-fit.
    @Published var lastFitScale: Double = 1.0

    @Published var calculationMode: CalculationMode = .integrate {
        didSet {
            syncSelectedDetector { $0.calculationMode = calculationMode }
        }
    }
    @Published var detectorColor: Color = .white {
        didSet {
            syncSelectedDetector { $0.color = detectorColor }
        }
    }
    @Published var dpcAxis: DPCAxis = .leftRight {
        didSet { syncSelectedDetector { $0.dpcAxis = dpcAxis } }
    }
    @Published var comAxis: COMAxis = .x {
        didSet { syncSelectedDetector { $0.comAxis = comAxis } }
    }
    /// Live for one load, so a cancellation or a second open can disown the
    /// first without it writing over the newer one when it finishes.
    private var loadToken: LoadCancellationToken?
    private var openWork: DispatchWorkItem?

    @Published var calibrations:Calibrations? {
        didSet {
            // Keep an open calibration window showing what the application
            // believes, so a calibration read from a newly opened file is not
            // hidden behind stale fields.
            if let windowModel = calibrationWindowModel, !windowModel.isEditing {
                windowModel.load(from: calibrations)
            }
        }
    }
    private var calibrationWindow: NSWindow?
    private var calibrationBatchWindow: NSWindow?
    private var calibrationWindowModel: CalibrationWindowModel?
    @Published var focusedPanel: FocusedPanel = .image
    @Published var pattern_mat:Matrix? = nil
    @Published var patternLogScaleEnabled: Bool = false
    /// Most recent computed-image matrix. Kept so plugins can post-process the
    /// displayed result; not @Published because nothing observes it.
    var lastScanMatrix:Matrix? = nil
    
    var selectedDetector: DetectorConfiguration? {
        guard let selectedDetectorID else { return nil }
        return detectors.first { $0.id == selectedDetectorID }
    }

    func addDetector() {
        let detector = DetectorConfiguration(
            name: "Detector \(nextDetectorNumber)",
            shape: detectorShape,
            type: detectorType,
            innerRadius: detectorInnerRadius,
            outerRadius: detectorOuterRadius,
            center: detectorCenter
        )
        nextDetectorNumber += 1
        detectors.append(detector)
        selectedDetectorID = detector.id
        selectedDetectorIDs = [detector.id]
    }

    func removeSelectedDetector() {
        guard detectors.count > 1,
              let selectedDetectorID,
              let index = detectors.firstIndex(where: { $0.id == selectedDetectorID }) else {
            return
        }

        detectors.remove(at: index)
        let nextIndex = min(index, detectors.count - 1)
        self.selectedDetectorID = detectors[nextIndex].id
        self.selectedDetectorIDs = [detectors[nextIndex].id]
    }

    private func syncSelectedDetector(_ update: (inout DetectorConfiguration) -> Void) {
        guard !isApplyingDetectorSelection,
              let selectedDetectorID,
              let index = detectors.firstIndex(where: { $0.id == selectedDetectorID }) else {
            return
        }

        update(&detectors[index])
    }

    private func applySelectedDetector() {
        guard let detector = selectedDetector else { return }

        isApplyingDetectorSelection = true
        detectorShape = detector.shape
        detectorType = detector.type
        detectorInnerRadius = detector.innerRadius
        detectorOuterRadius = detector.outerRadius
        detectorCenter = detector.center
        calculationMode = detector.calculationMode
        detectorColor = detector.color
        dpcAxis = detector.dpcAxis
        comAxis = detector.comAxis
        isApplyingDetectorSelection = false
    }

    private func resetDetectorsForLoadedPattern(center: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat) {
        let detector = DetectorConfiguration(
            name: "Detector 1",
            shape: .bf,
            type: .integrating,
            innerRadius: innerRadius,
            outerRadius: outerRadius,
            center: center
        )

        nextDetectorNumber = 2
        isApplyingDetectorSelection = true
        detectors = [detector]
        selectedDetectorID = detector.id
        selectedDetectorIDs = [detector.id]
        detectorShape = detector.shape
        detectorType = detector.type
        detectorInnerRadius = detector.innerRadius
        detectorOuterRadius = detector.outerRadius
        detectorCenter = detector.center
        calculationMode = detector.calculationMode
        detectorColor = detector.color
        dpcAxis = detector.dpcAxis
        comAxis = detector.comAxis
        isApplyingDetectorSelection = false
    }


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



    /// Opens the batch calibration sheet.
    func showCalibrationBatch() {
        if let existing = calibrationBatchWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 640),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Batch Calibrations"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CalibrationBatchSheet(
            onClose: { [weak self] in self?.calibrationBatchWindow?.close() }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        calibrationBatchWindow = window
    }

    /// Opens the calibration window.
    ///
    /// One window rather than a panel per activity: it shows the whole
    /// calibration, lets any of it be typed, and measures the parts that can be
    /// measured. Held in a property because it is a real window the user can
    /// leave open beside the data while adjusting a detector, not a sheet that
    /// blocks the application it is calibrating.
    func calibrate() {
        if let existing = calibrationWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let windowModel = CalibrationWindowModel(model: self)
        calibrationWindowModel = windowModel

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Calibration"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CalibrationWindowView(
            model: windowModel,
            onClose: { [weak self] in
                self?.calibrationWindow?.close()
            }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        calibrationWindow = window
    }

    func exportAll() {
        guard let fileroot = selectedURL?.deletingPathExtension().lastPathComponent,
              !fileroot.isEmpty,
              dataController.patternSize.width > 0 else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder to export images into"

        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url, let self else { return }
            self.performExportAll(to: folder, fileroot: fileroot)
        }
    }

    private func performExportAll(to folder: URL, fileroot: String) {
        let niceNm: [Float] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000]
        let fmtNm:  (Float) -> String = { $0 < 1000 ? String(format: "%.0f nm", $0) : String(format: "%.0f µm", $0 / 1000) }

        let withRGBBar: (CGImage, [Float], (Float) -> String, Float?) -> CGImage = { [weak self] ci, units, fmt, step in
            guard let self, let step, step > 0, step.isFinite,
                  let bar = self.exportScaleBar(imageWidth: ci.width, unitsPerPixel: step, niceUnits: units, formatUnit: fmt),
                  let result = self.appendDataBar(to: ci, barPixelWidth: bar.barPixels, label: bar.label)
            else { return ci }
            return result
        }

        let scanStep = calibrations?.scan_step

        // Per-detector export, branching on calculation mode
        for config in detectors {
            let det = makeDetector(from: config)
            let name = config.name.isEmpty ? "detector" : config.name

            switch config.calculationMode {
            case .integrate:
                let mat = dataController.integrating(det, strideLength: 1)
                guard mat.rows > 0 else { continue }
                saveTiff(matrix: mat, to: folder.appendingPathComponent("\(fileroot)_\(name).tif"))
                let nsColor = NSColor(config.color).usingColorSpace(.sRGB) ?? NSColor.white
                if let colorCI = makeColorizedImage(matrix: mat, color: nsColor) {
                    saveRawCGImageTiff(withRGBBar(colorCI, niceNm, fmtNm, scanStep),
                                       to: folder.appendingPathComponent("\(fileroot)_\(name)_rgb.tif"))
                }

            case .com:
                let comX = dataController.com(det, strideLength: 1, xy: .x)
                let comY = dataController.com(det, strideLength: 1, xy: .y)
                guard comX.rows > 0, comY.rows > 0 else { continue }
                saveTiff(matrix: comX, to: folder.appendingPathComponent("\(fileroot)_\(name)_com_x.tif"))
                saveTiff(matrix: comY, to: folder.appendingPathComponent("\(fileroot)_\(name)_com_y.tif"))
                if let (nsImage, _) = colorCom(comX, comY, removeDCOffset: true),
                   let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    saveRawCGImageTiff(withRGBBar(cgImage, niceNm, fmtNm, scanStep),
                                       to: folder.appendingPathComponent("\(fileroot)_\(name)_com_rgb.tif"))
                }

            case .dpc:
                let dpcLR = dataController.dpc(det, strideLength: 1, lrud: 1)
                let dpcUD = dataController.dpc(det, strideLength: 1, lrud: 0)
                guard dpcLR.rows > 0, dpcUD.rows > 0 else { continue }
                saveTiff(matrix: dpcLR, to: folder.appendingPathComponent("\(fileroot)_\(name)_dpc_lr.tif"))
                saveTiff(matrix: dpcUD, to: folder.appendingPathComponent("\(fileroot)_\(name)_dpc_ud.tif"))
                if let (nsImage, _) = colorCom(dpcLR, dpcUD, removeDCOffset: true),
                   let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    saveRawCGImageTiff(withRGBBar(cgImage, niceNm, fmtNm, scanStep),
                                       to: folder.appendingPathComponent("\(fileroot)_\(name)_dpc_rgb.tif"))
                }
            }
        }

        // Color-mixed image if multiple detectors selected
        if selectedDetectorIDs.count > 1 {
            let configs = detectors.filter { selectedDetectorIDs.contains($0.id) }
            if let (blended, _) = blendDetectorImages(configs: configs, strideLength: 1),
               let cgImage = make32BitRGBImage(from: blended) {
                saveRawCGImageTiff(withRGBBar(cgImage, niceNm, fmtNm, scanStep),
                                   to: folder.appendingPathComponent("\(fileroot)_colormix.tif"))
            }
        }

        // Current diffraction pattern — raw 32-bit float, no scale bar
        if let mat = pattern_mat {
            let suffix: String
            if let (y, x) = selected as? (Int, Int) { suffix = "_pattern_x\(x)_y\(y)" }
            else { suffix = "_pattern" }
            saveTiff(matrix: mat, to: folder.appendingPathComponent("\(fileroot)\(suffix).tif"))
        }
    }

    private func exportScaleBar(
        imageWidth: Int,
        unitsPerPixel: Float,
        niceUnits: [Float],
        formatUnit: (Float) -> String
    ) -> (barPixels: Int, label: String)? {
        guard imageWidth > 0, unitsPerPixel > 0 else { return nil }
        let maxPx = Float(imageWidth) * 0.20
        for unit in niceUnits.reversed() {
            let px = unit / unitsPerPixel
            if px <= maxPx {
                return (max(1, Int(round(px))), formatUnit(unit))
            }
        }
        return nil
    }

    private func appendDataBar(to image: CGImage, barPixelWidth: Int, label: String) -> CGImage? {
        let imgW = image.width
        let imgH = image.height
        guard imgW > 0, imgH > 0, barPixelWidth > 0 else { return nil }

        let barH      = max(24, min(64, imgH / 8))
        let lineThick = max(1, barH / 12)
        let lineY     = barH * 2 / 3
        let fontSize  = CGFloat(max(8, barH * 2 / 5))

        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: imgW, height: imgH + barH,
                                  bitsPerComponent: 8, bytesPerRow: imgW * 4,
                                  space: cs, bitmapInfo: bi) else { return nil }

        // Original image in upper region
        ctx.draw(image, in: CGRect(x: 0, y: barH, width: imgW, height: imgH))

        // Dark data bar background
        ctx.setFillColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: barH))

        // Scale bar line (centered)
        let barX = (imgW - barPixelWidth) / 2
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: barX, y: lineY, width: barPixelWidth, height: lineThick))
        // End caps
        let capH = lineThick * 3
        let capY = lineY - (capH - lineThick) / 2
        ctx.fill(CGRect(x: barX,                              y: capY, width: lineThick, height: capH))
        ctx.fill(CGRect(x: barX + barPixelWidth - lineThick,  y: capY, width: lineThick, height: capH))

        // Label (centered, below the line)
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, fontSize, nil)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: white]
        let attrStr = CFAttributedStringCreate(nil, label as CFString, attrs as CFDictionary)!
        let ctLine = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(ctLine, [.useOpticalBounds])
        let textX = max(2, (CGFloat(imgW) - bounds.width) / 2)
        let textY = max(2, CGFloat(lineY) - fontSize - 3)
        ctx.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(ctLine, ctx)

        return ctx.makeImage()
    }

    private func saveTiff(matrix: Matrix, to url: URL) {
        guard let cgImage = matrix.floatImageRep().cgImage,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }

    private func saveRawCGImageTiff(_ cgImage: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }

    private func makeColorizedImage(matrix: Matrix, color: NSColor) -> CGImage? {
        let data = matrix.real
        let rows = matrix.rows
        let cols = matrix.columns
        guard data.count == rows * cols, rows > 0 else { return nil }
        let count = rows * cols

        let minVal = data.min() ?? 0
        let maxVal = data.max() ?? 1
        let invRange: Float = (maxVal - minVal) > 0 ? 1.0 / (maxVal - minVal) : 1.0

        var cr: CGFloat = 1, cg: CGFloat = 1, cb: CGFloat = 1, ca: CGFloat = 1
        (color.usingColorSpace(.sRGB) ?? NSColor.white).getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
        let fr = Float(cr), fg = Float(cg), fb = Float(cb)

        var pixelData = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            let t = max(0, min(1, (data[i] - minVal) * invRange))
            pixelData[i * 4 + 0] = UInt8(t * fr * 255)
            pixelData[i * 4 + 1] = UInt8(t * fg * 255)
            pixelData[i * 4 + 2] = UInt8(t * fb * 255)
            pixelData[i * 4 + 3] = 255
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixelData) as CFData),
              let cgImage = CGImage(
                  width: cols, height: rows,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: cols * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }
        return cgImage
    }

    private func saveColorTiff(image: NSImage, to url: URL) {
        guard let cgImage = make32BitRGBImage(from: image),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
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

    // Not private: PluginHostContext reads the 4D stack through this.
    let dataController = STEMDataController()
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
    /// Writes the current calibration as EMPAD metadata JSON.
    ///
    /// What is exported is what the application currently believes, whatever put
    /// it there — a sidecar read at open time, the Calibrate dialog, or a
    /// measurement accepted from the Calibration plugin. There is deliberately
    /// no separate "calibrated" copy to drift out of step with the live one.
    func exportMetadata() {
        let data: Data
        do {
            data = try EMPADMetadataWriter.json(url: selectedURL,
                                                scanWidth: imageWidth,
                                                scanHeight: imageHeight,
                                                calibrations: calibrations)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Cannot export metadata"
            alert.informativeText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = EMPADMetadataWriter.suggestedFilename(for: selectedURL)
        panel.canCreateDirectories = true
        panel.message = "Save the calibration as EMPAD metadata"
        // Alongside the data, for the same reason the metadata panel opens there:
        // `raw_filename` is relative to the metadata's own location, so the two
        // belong in one folder.
        panel.directoryURL = selectedURL?.deletingLastPathComponent()

        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not save"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    private func promptForRawDimensions(suggested: (w: Int?, h: Int?), completion: @escaping ((w: Int, h: Int, scan_step: Float?, diff_step: Float?, voltage: Float?, flipRows: Bool, flipCols: Bool, transpose: Bool)?) -> Void) {
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
        var result: (Int, Int, Float?, Float?, Float?, Bool, Bool, Bool)? = nil

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

        let hosting = NSHostingView(rootView: RawDimsSheet(scan_dims: defaultString, diff_step: "None", scan_step: "None", fileHint: fileHint, fileURL: self.selectedURL, onCancel: {
            if let parent = panel.sheetParent {
                parent.endSheet(panel, returnCode: .cancel)
                DispatchQueue.main.async { completion(nil) }
            } else {
                NSApp.stopModal(withCode: .cancel)
                panel.close()
                DispatchQueue.main.async { completion(nil) }
            }
        }, onOK: { scan_dims, scan_step, diff_step, voltage, flipRows, flipCols, transpose in
            if let xy = parseXY(scan_dims) {
                let scan_step = Float(scan_step) ?? nil
                let diff_step = Float(diff_step) ?? nil
                let voltage = Float(voltage) ?? nil
                result = (xy.0, xy.1, scan_step, diff_step, voltage, flipRows, flipCols, transpose)
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
            func isContentWindow(_ window: NSWindow) -> Bool {
                !(window is NSPanel) && window.isVisible && window.styleMask.contains(.titled)
            }

            let preferredWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            if let window = preferredWindows.first(where: isContentWindow) {
                return window
            }

            if let window = NSApp.windows.first(where: { $0.identifier == ExternalFileOpenHandler.mainWindowIdentifier && isContentWindow($0) }) {
                return window
            }

            return NSApp.windows.first(where: isContentWindow)
        }

        if let window = hostWindow() {
            window.beginSheet(panel) { _ in }
        } else {
            // Modal fallback (non-blocking with completion invoked from button handlers)
            NSApp.runModal(for: panel)
        }
    }

    private func continueOpen(afterPromptFor url: URL) {
        // The RAW panel has already been answered on the main thread; the read
        // itself goes the same way round as every other format.
        beginOpen(url: url)
    }

    private func handleOpenError(_ error: Error) {
        isLoading = false

        // A cancellation is an outcome, not a fault, and an alert about it would
        // be reporting the user's own decision back to them.
        if case FileMaterializer.Failure.cancelled = error {
            status = "Cancelled"
            loadErrorMessage = nil
            return
        }

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
            // HDF5/EMD failures explain exactly what was wrong with the file,
            // which is far more use than a generic message.
            if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
                message = described
            } else {
                message = "Something went wrong loading the file."
            }
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
                    self.dataController.setRawTransforms(flipRows: dims.flipRows, flipCols: dims.flipCols, transpose: dims.transpose)
                    // The orientation the file is about to be read with is the
                    // orientation the metadata should record, so it is captured
                    // here rather than inferred later.
                    self.calibrations = Calibrations(scan_step: dims.scan_step,
                                                     diff_step: dims.diff_step,
                                                     voltage: dims.voltage,
                                                     detectorFlips: DetectorFlips(
                                                        flipY: dims.flipRows,
                                                        flipX: dims.flipCols,
                                                        transpose: dims.transpose))
                    self.continueOpen(afterPromptFor: url)
                } else {
                    self.isLoading = false
                    self.status = "Cancelled"
                }
            }
            return
        }
        beginOpen(url: url)
    }

    /// Everything between choosing a file and the first pattern arriving.
    ///
    /// All of it happens off the main thread. It used to happen on it, and the
    /// consequences were not subtle: identifying the format means reading a
    /// header, and for a Digital Micrograph file it means parsing the entire tag
    /// tree, so opening a large dataset froze the window for as long as that
    /// took. Worse, a file still in iCloud is fetched *inside* the first read
    /// that touches it, so opening one that had not been downloaded blocked the
    /// main thread for the length of a multi-gigabyte download, with no progress
    /// and no way out.
    private func beginOpen(url: URL) {
        // Whatever was loading is no longer wanted. Superseding without
        // cancelling would leave the previous file still downloading in the
        // background, competing for the network with the one actually asked for
        // and finishing into a window that has moved on.
        loadToken?.cancel()
        openWork?.cancel()
        dataController.cancelLoad()

        let token = LoadCancellationToken()
        loadToken = token

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            func finish(_ error: Error?) {
                DispatchQueue.main.async {
                    guard self.loadToken === token else { return }   // superseded
                    self.loadToken = nil
                    if let error = error { self.handleOpenError(error) }
                }
            }

            do {
                // Bring the file down first, if it is not already here. Doing it
                // deliberately is what makes it visible and interruptible.
                try FileMaterializer.ensureLocal(url, token: token) { fraction, line in
                    DispatchQueue.main.async {
                        guard self.loadToken === token else { return }
                        self.status = line
                        // Nil means the system will not say how far along it is;
                        // leaving the bar where it was beats pinning it to zero
                        // and implying nothing is happening.
                        if let fraction = fraction { self.progress = fraction }
                    }
                }
                if token.isCancelled { throw FileMaterializer.Failure.cancelled }

                DispatchQueue.main.async {
                    guard self.loadToken === token else { return }
                    self.status = "Reading \(url.lastPathComponent)…"
                    self.progress = 0
                }

                // `openFile` hands the bulk read to its own queue and returns, so
                // this thread is only carrying the header and format work — which
                // is the part that used to block.
                try self.dataController.openFile(url: url)
                finish(nil)
            } catch {
                finish(error)
            }
        }
        openWork = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    /// Stops whatever stage the load has reached.
    ///
    /// Three of them, and all three have to be told: the iCloud download watches
    /// the token, the header work is a cancellable work item, and the bulk read
    /// belongs to the data controller.
    func cancelLoading() {
        loadToken?.cancel()
        openWork?.cancel()
        dataController.cancelLoad()
        loadToken = nil
        openWork = nil
        isLoading = false
        progress = 0
        status = "Cancelled"
        loadErrorMessage = nil
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


    // MARK: - Calibration window support
    //
    // The calibration measurements are host-free by design — they take arrays
    // and a closure, not a view model. These are the adapters that hand them
    // what they need, and are the only place the window touches the data
    // controller.

    /// Names of the configured detectors, for the centre-of-mass picker.
    var detectorNames: [String] {
        return detectors.map { $0.name }
    }

    /// The computed image currently displayed.
    func currentScanImageFloats() -> (image: [Float], rows: Int, columns: Int)? {
        guard let matrix = lastScanMatrix, matrix.rows > 0, matrix.columns > 0 else { return nil }
        return (matrix.real, matrix.rows, matrix.columns)
    }

    /// The diffraction pattern currently displayed.
    func currentPatternFloats() -> (image: [Float], rows: Int, columns: Int)? {
        guard let matrix = pattern_mat, matrix.rows > 0, matrix.columns > 0 else { return nil }
        return (matrix.real, matrix.rows, matrix.columns)
    }

    /// The stack geometry, or nil when nothing is loaded.
    func rotationGeometry() -> ScanRotationGeometry? {
        let scan = dataController.imageSize
        let pattern = dataController.patternSize
        guard scan.width > 0, scan.height > 0, pattern.width > 0, pattern.height > 0 else {
            return nil
        }
        return ScanRotationGeometry(scanWidth: scan.width, scanHeight: scan.height,
                                    patternWidth: pattern.width, patternHeight: pattern.height)
    }

    /// A detector's mask, as the centre-of-mass computation wants it.
    func detectorMaskFloats(at index: Int) -> [Float]? {
        guard detectors.indices.contains(index) else { return nil }
        return makeDetector(from: detectors[index]).detectorMask().real
    }

    /// Reads patterns straight out of the loaded stack.
    ///
    /// The buffer is owned by the caller and the pointer is not retained, so this
    /// stays valid for the life of one measurement — which is the only thing it
    /// is used for.
    func patternProvider() -> PatternProvider {
        let controller = dataController
        let pixels = controller.patternPixels
        let width = controller.imageSize.width
        let height = controller.imageSize.height
        return { row, column, buffer, capacity in
            guard row >= 0, row < height, column >= 0, column < width,
                  capacity >= pixels, let base = controller.patternPointer else { return false }
            let source = base + (row * width + column) * pixels
            buffer.update(from: source, count: pixels)
            return true
        }
    }

    private func makeDetector(from config: DetectorConfiguration) -> Detector {
        let pW = dataController.patternSize.width
        let pH = dataController.patternSize.height
        let center = NSPoint(
            x: max(0, min(CGFloat(pW - 1), config.center.x)),
            y: max(0, min(CGFloat(pH - 1), config.center.y))
        )
        let clampedInner = min(config.innerRadius, config.outerRadius)
        let params: [DetectorParameter: Float] = [
            .innerRadius: Float(clampedInner),
            .outerRadius: Float(config.outerRadius)
        ]
        return Detector(shape: config.shape, type: config.type, center: center, params: params, size: NSSize(width: pW, height: pH))
    }

    private func blendDetectorImages(configs: [DetectorConfiguration], strideLength: Int) -> (NSImage, Matrix)? {
        guard !configs.isEmpty else { return nil }

        let pairs: [(Matrix, NSColor)] = configs.compactMap { config in
            let mat = dataController.integrating(makeDetector(from: config), strideLength: strideLength)
            guard mat.rows > 0, mat.columns > 0 else { return nil }
            let nsColor = (NSColor(config.color).usingColorSpace(.sRGB) ?? NSColor.white)
            return (mat, nsColor)
        }
        guard let (first, _) = pairs.first else { return nil }

        let rows = first.rows
        let cols = first.columns
        let count = rows * cols

        var red   = [Float](repeating: 0, count: count)
        var green = [Float](repeating: 0, count: count)
        var blue  = [Float](repeating: 0, count: count)

        for (matrix, nsColor) in pairs {
            let data = matrix.real
            guard data.count == count else { continue }
            let minVal = data.min() ?? 0
            let maxVal = data.max() ?? 1
            let invRange: Float = (maxVal - minVal) > 0 ? 1.0 / (maxVal - minVal) : 1.0
            var cr: CGFloat = 1, cg: CGFloat = 1, cb: CGFloat = 1, ca: CGFloat = 1
            nsColor.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
            let fr = Float(cr), fg = Float(cg), fb = Float(cb)
            for i in 0..<count {
                let t = max(0, min(1, (data[i] - minVal) * invRange))
                red[i]   += t * fr
                green[i] += t * fg
                blue[i]  += t * fb
            }
        }

        var pixelData = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            pixelData[i * 4 + 0] = UInt8(min(1, red[i])   * 255)
            pixelData[i * 4 + 1] = UInt8(min(1, green[i]) * 255)
            pixelData[i * 4 + 2] = UInt8(min(1, blue[i])  * 255)
            pixelData[i * 4 + 3] = 255
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let provider = CGDataProvider(data: Data(pixelData) as CFData),
              let cgImage = CGImage(
                  width: cols, height: rows,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: cols * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }

        return (NSImage(cgImage: cgImage, size: NSSize(width: cols, height: rows)), first)
    }
    /// True when everything being computed is a point detector.
    ///
    /// All of them, not just the first: a point detector blended with an annular
    /// one still has to sum the annular one over every probe position, and that
    /// is the cost subsampling exists to avoid.
    private var selectedDetectorsAreAllPoints: Bool {
        let active = detectors.filter { selectedDetectorIDs.contains($0.id) }
        let considered = active.isEmpty ? detectors : active
        return !considered.isEmpty && considered.allSatisfy {
            $0.shape == .point && $0.calculationMode == .integrate
        }
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

        // Subsampling exists to keep dragging responsive, and it costs
        // resolution to do it. A point detector reads one number per probe
        // position rather than summing a masked pattern, which is thousands of
        // times less work — cheap enough that there is nothing to trade, so the
        // full scan is computed even while the crosshair is moving.
        if interactive && !selectedDetectorsAreAllPoints {
            stride = max(1, dynamicStrideForTargetGrid())
        } else {
            stride = 1
        }

        // Multi-detector: blend each selected detector's integrate image by its color
        if selectedDetectorIDs.count > 1 {
            let configs = detectors.filter { selectedDetectorIDs.contains($0.id) }
            if let (blended, mat) = blendDetectorImages(configs: configs, strideLength: stride),
               let scaled = scaleStrideImage(blended, stride) {
                lastScanMatrix = mat
                return (scaled, mat)
            }
            return nil
        }

        let det = currentDetector()

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
            tempImage = makeColoredImage(from: mat, tintColor: NSColor(detectorColor))
        }
        
        if let tempImage = tempImage {
            
            if let finalImage = scaleStrideImage(tempImage, stride)
            {
                    lastScanMatrix = mat
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
            let displayMatrix = patternDisplayMatrix(from: avgMatrix)
            
            if let avgImg = makeImage(from: displayMatrix){
                return (avgImg, avgMatrix)
            }
            return nil
            
            

            
        }
        return nil
        
    }
    
    func getPatternImage(i: Int, j: Int)->(NSImage, Matrix)? {
        
        if let m = self.dataController.pattern(i, j) {
            let displayMatrix = patternDisplayMatrix(from: m)
            if let pattern = makeImage(from: displayMatrix){
                
                return (pattern, m)
            }
        }

        return nil
        
    }

    private func patternDisplayMatrix(from matrix: Matrix) -> Matrix {
        guard patternLogScaleEnabled else { return matrix }

        let data = matrix.real
        let n = data.count
        var result = [Float](repeating: 0, count: n)

        // Clamp to small positive to avoid log10(0) = -inf or log10(negative) = NaN,
        // which would corrupt the quantile normalization in uInt8ImageRep.
        var eps: Float = Float.leastNormalMagnitude
        vDSP_vthres(data, 1, &eps, &result, 1, vDSP_Length(n))

        var count = Int32(n)
        vvlog10f(&result, result, &count)

        return Matrix(array: result, matrix.rows, matrix.columns)
    }
    
    func makeImage(from m:Matrix)->NSImage? {

        let width = m.columns
        let height = m.rows

        if let cgImg = m.uInt8ImageRep()?.cgImage{
            return NSImage(cgImage: cgImg, size: NSSize(width: width, height: height))
        }

        return nil

    }

    private func makeColoredImage(from m: Matrix, tintColor: NSColor) -> NSImage? {
        let width = m.columns
        let height = m.rows
        guard width > 0, height > 0 else { return nil }
        let data = m.real
        guard data.count == width * height else { return nil }

        // If tint is white, fall back to the standard grayscale path (faster)
        var cr: CGFloat = 1, cg: CGFloat = 1, cb: CGFloat = 1, ca: CGFloat = 1
        let srgb = tintColor.usingColorSpace(.sRGB) ?? tintColor
        srgb.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
        if cr >= 0.999 && cg >= 0.999 && cb >= 0.999 {
            return makeImage(from: m)
        }

        let minVal = data.min() ?? 0
        let maxVal = data.max() ?? 1
        let range = maxVal - minVal
        let invRange: Float = range > 0 ? 1.0 / range : 1.0
        let fr = Float(cr), fg = Float(cg), fb = Float(cb)

        // Build RGBA bytes: intensity t mapped to (t·r, t·g, t·b)
        var pixelData = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let t = max(0, min(1, (data[i] - minVal) * invRange))
            pixelData[i * 4 + 0] = UInt8(t * fr * 255)
            pixelData[i * 4 + 1] = UInt8(t * fg * 255)
            pixelData[i * 4 + 2] = UInt8(t * fb * 255)
            pixelData[i * 4 + 3] = 255
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let provider = CGDataProvider(data: Data(pixelData) as CFData),
              let cgImage = CGImage(
                  width: width, height: height,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: provider,
                  decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
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
        // Formats that carry their own calibration (EMD) report it here; the
        // RAW path sets it from the prompt before loading, so only overwrite
        // when the reader actually found something.
        if let discovered = self.dataController.calibrations {
            self.calibrations = discovered
        }
        self.imageWidth = self.dataController.imageSize.width
        self.imageHeight = self.dataController.imageSize.height
        self.patternSize.width = self.dataController.patternSize.width
        self.patternSize.height = self.dataController.patternSize.height
        let center = CGPoint(x: CGFloat(self.patternSize.width) / 2.0, y: CGFloat(self.patternSize.height) / 2.0)
        self.detectorCenter = center
        
        if dataController.pattern(0, 0) != nil {
            let pW = self.dataController.patternSize.width
            let pH = self.dataController.patternSize.height
            let base = CGFloat(min(pW, pH))
            resetDetectorsForLoadedPattern(center: center, innerRadius: 1, outerRadius: base * 0.15)
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
        cancelLoading()
    }
}
