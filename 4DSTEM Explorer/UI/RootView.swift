import SwiftUI
import AppKit
import UniformTypeIdentifiers

private class ScrollOnlyNSView: NSView {
    var onScroll: ((CGFloat, CGFloat) -> Void)?

    // Accept hit tests only for scroll wheel events; all other events fall through to SwiftUI content below
    override func hitTest(_ point: NSPoint) -> NSView? {
        NSApp.currentEvent?.type == .scrollWheel ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaX, event.scrollingDeltaY)
    }
}

private struct ScrollOnlyReceiver: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollOnlyNSView {
        ScrollOnlyNSView()
    }

    func updateNSView(_ nsView: ScrollOnlyNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

struct RootView: View {
    @EnvironmentObject private var model: DataViewModel
    @EnvironmentObject private var openPanel: OpenPanelController

    @Binding var zoomScale: CGFloat

    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isDraggingSelection: Bool = false
    @State private var dragStart: CGPoint? = nil
    @State private var currentDrag: CGPoint? = nil
    
//    @State private var zoomScale: CGFloat = 1.0
    @State private var contentOffset: CGSize = .zero
    @State private var points = [CGPoint(x: 0, y: 0)]
    @State private var marquee:CGRect?

    @State private var virtual_image:NSImage?
    @State private var pattern_image:NSImage?
    @State private var patternHoverInfo: PatternHoverInfo?
    @State private var needs_update:Bool = false
    @Binding var selectionMode: InteractiveMarkerView.SelectionMode
    @State var lastPoint: CGPoint?
    @FocusState private var isFocused: Bool
    @State private var detectorShape: DetectorShape = .bf
    @State private var virtual_mat:Matrix?
    @State private var pattern_mat:Matrix?
    @Binding var showDetector: Bool
    @State private var interactive:Bool = false
    @State private var isDetectorDragging: Bool = false
    @State private var isFileDropTargeted: Bool = false
    @Binding var calculationMode:CalculationMode
    @State private var patternZoom: CGFloat = 1.0
    @State private var patternZoomStart: CGFloat = 1.0
    @State private var patternOffset: CGSize = .zero
    @State private var patternOffsetStart: CGSize = .zero
    @State private var patternViewSize: CGSize = .zero

    private func detectorShapeLabel(_ shape: DetectorShape) -> String {
        switch shape {
        case .bf:
            return "BF"
        case .adf:
            return "ADF"
        case .af:
            return "AF"
        case .point:
            return "Point"
        case .custom:
            return "Custom"
        }
    }

    private var innerAngle: Double {
        // Uses model.diffStep (radians per pixel) if available; fall back to 0
        let radius = Double(model.detectorInnerRadius)
        let step = Double(model.calibrations?.diff_step ?? 1.0)
        // angle = radius * step (in radians) -> convert to degrees
        let mrad = radius * step
        return mrad.isFinite ? mrad : 0.0
    }

    private var outerAngle: Double {
        let radius = Double(model.detectorOuterRadius)
        let step = Double(model.calibrations?.diff_step ?? 1.0)
        // angle = radius * step (in radians) -> convert to degrees
        let mrad = radius * step
        return mrad.isFinite ? mrad : 0.0
    }

    private var showsColorWheelLegend: Bool {
        switch model.calculationMode {
        case .com:
            return model.comAxis == .color
        case .dpc:
            return model.dpcAxis == .color
        case .integrate:
            return false
        }
    }
    
    private func scaleBarPixelsAndLabel(viewWidth: CGFloat, zoomScale: CGFloat) -> (imagePixels: CGFloat, label: String)? {
        guard let step = model.calibrations?.scan_step, step.isFinite, step > 0 else { return nil }
        // step is nm per image pixel
        // Limit bar to 10% of the displayed image width in image pixels
        let maxImagePixels = (viewWidth / max(zoomScale, 0.01)) * 0.20
        // Candidate nice lengths in nm
        let niceNm: [Float] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000]
        // Pick the largest length whose image-pixel width fits within the limit
        for length in niceNm.reversed() {
            let imagePixels = CGFloat(length / step)
            if imagePixels <= maxImagePixels {
                let label: String
                if length < 1000 {
                    label = String(format: "%.0f nm", length)
                } else {
                    label = String(format: "%.0f µm", length / 1000)
                }
                return (imagePixels, label)
            }
        }
        return nil
    }

    private func updateVirtual(_ interactive:Bool = false) {
        self.interactive = interactive
        if let (vi, vm) = model.computeScanImage(interactive: interactive){
            virtual_image = vi
            virtual_mat = vm
        }
    }
    
    private func updatePattern(_ i:Int, _ j:Int) {
        self.interactive = interactive
        if let (pi, pm) = model.getPatternImage(i: i, j: j) {
            pattern_image = pi
            pattern_mat = pm
            model.pattern_mat = pm
            model.selected = (i,j)
            
        }
        
    }

    private func updatePattern(rect: CGRect) {
        if let (pi, pm) = model.getPatternImage(rect: rect) {
            pattern_image = pi
            pattern_mat = pm
            model.pattern_mat = pm
            model.selected = rect
        }
    }

    private func refreshPatternDisplay() {
        if selectionMode == .marquee, let rect = marquee {
            updatePattern(rect: rect)
        } else if let point = lastPoint {
            updatePattern(Int(floor(point.y)), Int(floor(point.x)))
        } else if model.imageWidth > 0 {
            updatePattern(0, 0)
        }
    }

    private func updatePatternHover(location: CGPoint, viewSize: CGSize, patternWidth: Int, patternHeight: Int) {
        guard let matrix = pattern_mat, matrix.rows > 0, matrix.columns > 0 else {
            patternHoverInfo = nil
            return
        }

        let drawRect = fittedImageRect(viewSize: viewSize, imageWidth: patternWidth, imageHeight: patternHeight)
        guard drawRect.contains(location) else {
            patternHoverInfo = nil
            return
        }

        let normalizedX = (location.x - drawRect.minX) / max(drawRect.width, 1)
        let normalizedY = (location.y - drawRect.minY) / max(drawRect.height, 1)
        let rawJ = Int(floor(normalizedX * CGFloat(matrix.columns)))
        let rawI = Int(floor(normalizedY * CGFloat(matrix.rows)))
        let j = Swift.min(Swift.max(rawJ, 0), matrix.columns - 1)
        let i = Swift.min(Swift.max(rawI, 0), matrix.rows - 1)
        let intensity = matrix.get(i, j).0

        patternHoverInfo = PatternHoverInfo(i: i, j: j, intensity: intensity)
    }

    private func fittedImageRect(viewSize: CGSize, imageWidth: Int, imageHeight: Int) -> CGRect {
        let imgW = CGFloat(max(imageWidth, 1))
        let imgH = CGFloat(max(imageHeight, 1))
        let imageAspect = imgW / imgH
        let viewAspect = viewSize.width / max(viewSize.height, 1)

        if imageAspect > viewAspect {
            let drawHeight = viewSize.width / imageAspect
            let yOffset = (viewSize.height - drawHeight) / 2.0
            return CGRect(x: 0, y: yOffset, width: viewSize.width, height: drawHeight)
        } else {
            let drawWidth = viewSize.height * imageAspect
            let xOffset = (viewSize.width - drawWidth) / 2.0
            return CGRect(x: xOffset, y: 0, width: drawWidth, height: viewSize.height)
        }
    }

    private var patternHoverText: String {
        guard let info = patternHoverInfo, !isDetectorDragging else {
            let c = model.detectorCenter
            if let name = model.selectedDetector?.name{
                return "\(name) i: \(Int(round(c.y))), j: \(Int(round(c.x)))"
            }else{
                return "no detector selected"
            }
            
            
        }
        return "(i: \(info.i), j: \(info.j), intensity: \(formatIntensity(info.intensity)))"
    }

    private func formatIntensity(_ value: Float) -> String {
        guard value.isFinite else {
            return value.isNaN ? "NaN" : (value > 0 ? "inf" : "-inf")
        }

        return String(format: "%.4g", Double(value))
    }

    private var patternPanel: some View {
        GroupBox("Pattern") {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    ZStack {
                    if let pi = pattern_image {
                        
                        // TODO: remove w,h input and just grab from pattern
                        PatternView(pattern: pi)
                        
                        ForEach(model.detectors.filter { model.selectedDetectorIDs.contains($0.id) }) { detector in
                            DetectorOverlay(
                                shape: detector.shape,
                                inner: detector.innerRadius,
                                outer: detector.outerRadius,
                                center: detector.center,
                                tintColor: detector.color,
                                patternWidth: Int(pi.size.width),
                                patternHeight: Int(pi.size.height),
                                isActive: detector.id == model.selectedDetectorID,
                                showDetector: $showDetector,
                                onActivate: { tapLocation in
                                    // Z-ordered hit test: find the topmost selected detector whose circle
                                    // contains tapLocation and make it the primary selected detector.
                                    let patternW = Int(pi.size.width)
                                    let patternH = Int(pi.size.height)
                                    let dr = fittedImageRect(viewSize: geo.size, imageWidth: patternW, imageHeight: patternH)
                                    let sc = min(dr.width / CGFloat(max(patternW, 1)), dr.height / CGFloat(max(patternH, 1)))
                                    let tol: CGFloat = 10
                                    for det in model.detectors.filter({ model.selectedDetectorIDs.contains($0.id) }).reversed() {
                                        let nx = det.center.x / CGFloat(max(patternW - 1, 1))
                                        let ny = 1.0 - det.center.y / CGFloat(max(patternH - 1, 1))
                                        let dc = CGPoint(x: dr.minX + nx * dr.width, y: dr.minY + ny * dr.height)
                                        let dx = tapLocation.x - dc.x
                                        let dy = tapLocation.y - dc.y
                                        let dist = sqrt(dx * dx + dy * dy)
                                        let hit: Bool
                                        switch det.shape {
                                        case .bf:  hit = dist <= det.outerRadius * sc + tol
                                        case .adf: hit = dist <= det.innerRadius * sc + tol
                                        case .af:  hit = dist <= det.outerRadius * sc + tol
                                        // No circle to aim at, so the crosshair
                                        // itself is the target.
                                        case .point: hit = dist <= tol + 2
                                        default:   hit = false
                                        }
                                        if hit { model.selectedDetectorID = det.id; break }
                                    }
                                },
                                onCenterChange: { point, interactive in
                                    isDetectorDragging = interactive
                                    if let idx = model.detectors.firstIndex(where: { $0.id == detector.id }) {
                                        model.detectors[idx].center = point
                                        if detector.id == model.selectedDetectorID {
                                            model.detectorCenter = point
                                        }
                                    }
                                    updateVirtual(interactive)
                                },
                                onRadiusChange: { innerR, outerR, interactive in
                                    isDetectorDragging = interactive
                                    if let idx = model.detectors.firstIndex(where: { $0.id == detector.id }) {
                                        // A drag moves both at once and writes
                                        // straight to the stored detector, so
                                        // the rule is applied here too — the
                                        // published properties below would
                                        // otherwise be corrected while the
                                        // array kept the collapsed pair.
                                        let settled = DetectorRadii.settled(
                                            inner: innerR, outer: outerR,
                                            ceiling: model.maximumDetectorRadius)
                                        model.detectors[idx].innerRadius = settled.inner
                                        model.detectors[idx].outerRadius = settled.outer
                                        if detector.id == model.selectedDetectorID {
                                            model.detectorInnerRadius = settled.inner
                                            model.detectorOuterRadius = settled.outer
                                        }
                                    }
                                    updateVirtual(interactive)
                                },
                                imageSizeProvider: { (width: model.imageWidth, height: model.imageHeight) }
                            )
                            .id(detector.id)
                        }
                        
                        // Nice overlay for detector size
    //                    VStack {
    //                        Spacer()
    //                        HStack {
    //                            let innerText = String(format: "Inner: %.1f mrad", innerAngle)
    //                            let outerText = String(format: "Outer: %.1f mrad", outerAngle)
    //                            Text("\(innerText)  ·  \(outerText)")
    //                                .font(.caption2)
    //                                .padding(.horizontal, 6)
    //                                .padding(.vertical, 3)
    //                                .background(.thinMaterial, in: Capsule())
    //                                .foregroundStyle(.secondary)
    //                            Spacer()
    //                        }
    //                        .padding(6)
    //                    }
                    } else {
                        Text(model.isLoading ? "Loading…" : "Select a point in the computed image.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .foregroundColor(.secondary)
                    }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard let pi = pattern_image else {
                            patternHoverInfo = nil
                            return
                        }
                        switch phase {
                        case .active(let location):
                            updatePatternHover(
                                location: location,
                                viewSize: geo.size,
                                patternWidth: Int(pi.size.width),
                                patternHeight: Int(pi.size.height)
                            )
                        case .ended:
                            patternHoverInfo = nil
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded { model.focusedPanel = .pattern })
                    .scaleEffect(patternZoom, anchor: .center)
                    .offset(patternOffset)
                    .clipped()
                    .overlay(ScrollOnlyReceiver { dx, dy in
                        guard patternZoom > 1 else { return }
                        let maxX = geo.size.width  * (patternZoom - 1) / 2
                        let maxY = geo.size.height * (patternZoom - 1) / 2
                        patternOffset.width  = max(-maxX, min(maxX, patternOffset.width  + dx))
                        patternOffset.height = max(-maxY, min(maxY, patternOffset.height + dy))
                        patternOffsetStart = patternOffset
                    })
                    .gesture(MagnificationGesture()
                        .onChanged { value in
                            patternZoom = max(0.5, patternZoomStart * value)
                        }
                        .onEnded { value in
                            patternZoom = max(0.5, patternZoomStart * value)
                            patternZoomStart = patternZoom
                            let maxX = max(0, geo.size.width  * (patternZoom - 1) / 2)
                            let maxY = max(0, geo.size.height * (patternZoom - 1) / 2)
                            patternOffset.width  = max(-maxX, min(maxX, patternOffset.width))
                            patternOffset.height = max(-maxY, min(maxY, patternOffset.height))
                            patternOffsetStart = patternOffset
                        }
                    )
                    .onAppear { patternViewSize = geo.size }
                    .onChange(of: geo.size) { _, size in patternViewSize = size }
                }
                .onReceive(NotificationCenter.default.publisher(for: .fileLoaded)) { _ in
                    updatePattern(0, 0)
                    updateVirtual()
                }
                .onReceive(NotificationCenter.default.publisher(for: .imageViewClicked)) { _ in
                    model.focusedPanel = .image
                }
                .onReceive(NotificationCenter.default.publisher(for: .zoomInPattern)) { _ in
                    patternZoom = patternZoom * 1.25
                    patternZoomStart = patternZoom
                }
                .onReceive(NotificationCenter.default.publisher(for: .zoomOutPattern)) { _ in
                    patternZoom = max(0.5, patternZoom / 1.25)
                    patternZoomStart = patternZoom
                    let maxX = max(0, patternViewSize.width  * (patternZoom - 1) / 2)
                    let maxY = max(0, patternViewSize.height * (patternZoom - 1) / 2)
                    patternOffset.width  = max(-maxX, min(maxX, patternOffset.width))
                    patternOffset.height = max(-maxY, min(maxY, patternOffset.height))
                    patternOffsetStart = patternOffset
                }
                .onReceive(NotificationCenter.default.publisher(for: .zoomToFitPattern)) { _ in
                    patternZoom = 1.0
                    patternZoomStart = 1.0
                    patternOffset = .zero
                    patternOffsetStart = .zero
                }
                .onReceive(NotificationCenter.default.publisher(for: .zoomToActualPattern)) { _ in
                    patternZoom = 1.0
                    patternZoomStart = 1.0
                    patternOffset = .zero
                    patternOffsetStart = .zero
                }
                .aspectRatio(1.0, contentMode: .fit)

                Text(patternHoverText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Toggle("Log scale", isOn: $model.patternLogScaleEnabled)
                    .disabled(pattern_image == nil)
                    .onChange(of: model.patternLogScaleEnabled) { _, _ in
                        refreshPatternDisplay()
                    }
            }
        }
    }

    private var computedImagePanel: some View {
        GroupBox("Computed Image") {
            Group {
                if let img = virtual_image {
                    let stride = CGFloat(model.stride)
                    
                    let coordinateText: String = {
                        if selectionMode == .point {
                            if let p = lastPoint {
                                
                                let int:Float
                                let real:Float
                                let imag:Float?
                                
                                

                                
                                if let val = (virtual_mat?.get(Int(p.y/stride), Int(p.x/stride))){
                            
                                    (real, imag) = val
                                    
                                    if let imag = imag{
                                        let mag = real
                                        var ang = (imag*180/Float.pi)
                                        
                                        if ang < 0 {
                                            ang += 360.0
                                        }
                                        
                                        return String(format: "(x: %.0f, y: %.0f, mag: %.2f, ang:%.2f)", p.x, p.y, mag, ang)
                                        
                                    }
                                    int = real

                                    return String(format: "(x: %.0f, y: %.0f, int: %.2f)", p.x, p.y, int)
                                    
                                }else{
                                    int = 0.0
                                    return String(format: "(x: %.0f, y: %.0f, int: %.2f)", p.x, p.y, int)
                                }
                                
                            } else {
                                                                
                                return "(x: –, y: –, int: -)"
                            }
                        } else if selectionMode == .marquee {
                            if let rect = marquee {
                                var origin = rect.origin
                                var size = rect.size
                                origin.x /= stride
                                origin.y /= stride
                                size.height /= stride
                                size.width /= stride
                                
                                let strideRect = CGRect(origin: origin, size: size)
                                
                                let mean = virtual_mat?.mean(strideRect)
                                
                                return String(
                                    format: "min x: %.0f, min y: %.0f, width: %.0f, height: %.0f, mean: %.2f",
                                    rect.minX, rect.minY, rect.width, rect.height, mean ?? 0.0
                                )
                            } else {
                                return "min x: –, min y: –, width: -, height: -, mean: -"
                            }
                        } else {
                            return ""
                        }
                    }()

                    VStack(spacing: 8) {
                        ZStack(alignment: .topTrailing) {
                            ZoomableImageView(image: img, lastPoint: $lastPoint, marquee: $marquee, zoomScale:$zoomScale, selectionMode: $selectionMode)
                                .onChange(of: virtual_image) { }
                                .onChange(of: lastPoint) { _, point in
                                    let i = Int(floor(point?.y ?? 0))
                                    let j = Int(floor(point?.x ?? 0))
                                    updatePattern(i, j)
                                }
                                .onChange(of: marquee) { _, newValue in
                                    if let rect = newValue {
                                        updatePattern(rect: rect)
                                    }
                                }
//                                .onChange(of: model.calculationMode,{ _, type in
//                                    print(type)
//                                    updateVirtual()
//                                })
                                .focusable()
                                .focused($isFocused)
                                .focusEffectDisabled(true)
                                .onAppear { isFocused = true }

                            if showsColorWheelLegend {
                                ColorWheelLegend()
                                    .padding(10)
                                    .allowsHitTesting(false)
                            }

                        }
                        .overlay(alignment: .bottom) {
                            GeometryReader { geo in
                                if let bar = scaleBarPixelsAndLabel(viewWidth: geo.size.width, zoomScale: zoomScale) {
                                    VStack(spacing: 4) {
                                        Rectangle()
                                            .fill(Color.white)
                                            .frame(width: bar.imagePixels * zoomScale, height: 2)
                                        Text(bar.label)
                                            .font(.caption2)
                                            .foregroundStyle(.white)
                                    }
                                    .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 0)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                    .padding(.bottom, 10)
                                }
                            }
                            .allowsHitTesting(false)
                        }

                        if !coordinateText.isEmpty {
                            Text(coordinateText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No Image Loaded")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var body: some View {
        
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Left Panel
            VStack(alignment: .leading, spacing: 12) {
                patternPanel
                detectorSettings
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            computedImagePanel
                .padding(12)
        }
        
        .onChange(of: columnVisibility) { _, newValue in
            if newValue == .detailOnly {
                // Use an async call to ensure the UI has finished its current transition
                DispatchQueue.main.async {
                    columnVisibility = .all
                }
            }
        }
        .overlay {
            if isFileDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isFileDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            let supportedExtensions = ["dm4", "mrc", "tif", "tiff", "raw", "emd", "h5", "hdf5"]
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url,
                      supportedExtensions.contains(url.pathExtension.lowercased()) else { return }
                DispatchQueue.main.async {
                    model.open(url: url)
                }
            }
            return true
        }
    }

    /// Occupies exactly the height of the controls a point detector hides.
    ///
    /// Built from the same control types rather than a fixed number of points,
    /// so it keeps up with font size, control size and accessibility settings
    /// instead of drifting out of step with them.
    private var reservedControlSpace: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Outer: ")
                Slider(value: .constant(0.0), in: 0...1)
                Text("0 (pix)").frame(minWidth: 24, alignment: .trailing)
            }
            Picker("", selection: .constant(0)) {
                Text("Integrate").tag(0)
                Text("COM").tag(1)
                Text("DPC").tag(2)
            }
            .pickerStyle(.segmented)
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private var detectorSettings: some View {
        GroupBox("Detectors") {
            VStack(alignment: .leading, spacing: 8) {
                Table(model.detectors, selection: Binding<Set<DetectorConfiguration.ID>>(
                    get: { model.selectedDetectorIDs },
                    set: { model.selectedDetectorIDs = $0 }
                )) {
                    TableColumn("Name") { (detector: DetectorConfiguration) in
                        Text(detector.name).lineLimit(1)
                    }
                    TableColumn("Shape") { (detector: DetectorConfiguration) in
                        Text(detectorShapeLabel(detector.shape))
                            .foregroundStyle(.secondary)
                    }
                    .width(48)
                    TableColumn("Color") { (detector: DetectorConfiguration) in
                        ColorPicker("", selection: Binding<Color>(
                            get: { detector.color },
                            set: { newColor in
                                if let idx = model.detectors.firstIndex(where: { $0.id == detector.id }) {
                                    model.detectors[idx].color = newColor
                                    if detector.id == model.selectedDetectorID {
                                        model.detectorColor = newColor
                                    }
                                    if model.selectedDetectorIDs.contains(detector.id) {
                                        updateVirtual()
                                    }
                                }
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    .width(44)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: .infinity)
                .onChange(of: model.selectedDetectorID) { _, _ in
                    updateVirtual()
                }
                .onChange(of: model.selectedDetectorIDs) { _, _ in
                    updateVirtual()
                }
                .onChange(of: model.detectorColor) { _, _ in
                    updateVirtual()
                }

                    HStack(spacing: 8) {
                        Button {
                            model.addDetector()
                            updateVirtual()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("Add detector")

                        Button {
                            model.removeSelectedDetector()
                            updateVirtual()
                        } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(model.detectors.count <= 1)
                        .help("Remove selected detector")

                        Spacer()
                    }
                    .buttonStyle(.borderless)

                Divider()

                Picker("Shape", selection: $model.detectorShape) {
                    Text("Point").tag(DetectorShape.point)
                        .help("A single detector pixel at the crosshair. Drag it on the pattern, or nudge it with the arrow keys.")
                    Text("BF").tag(DetectorShape.bf)
                    Text("ADF").tag(DetectorShape.adf)
                    Text("AF").tag(DetectorShape.af)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.detectorShape) { old, new in
                    // A point detector is one pixel, so the only calculation that
                    // means anything is integrating it. A centre of mass or a
                    // difference across a single element is degenerate — it can
                    // only ever return that element's own position.
                    if new == .point && model.calculationMode != .integrate {
                        model.calculationMode = .integrate
                    }
                   updateVirtual()
                }

                if model.detectorShape == .bf || model.detectorShape == .af {
                    HStack {
                        Text("Outer: ")
                        Slider(
                            value: Binding<Double>(
                                get: { Double(model.detectorOuterRadius) },
                                set: { newValue in
                                    // The model pushes the inner radius out of
                                    // the way; doing it here as well would
                                    // clamp rather than push.
                                    model.detectorOuterRadius = CGFloat(newValue)
                                    updateVirtual(true)
                                }
                            ),
                            in: model.outerRadiusRange,
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    updateVirtual(false)
                                }
                            }
                        )
                        if model.calibrations?.diff_step != nil{
                            Text(String(format: "%.1f (mrad)", outerAngle))
                                .frame(minWidth: 24, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }else{
                            Text(String(format: "%.0f (pix)", model.detectorOuterRadius))
                                .frame(minWidth: 24, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if model.detectorShape == .adf || model.detectorShape == .af {
                    HStack {
                        Text("Inner: ")
                        Slider(
                            value: Binding<Double>(
                                get: { Double(model.detectorInnerRadius) },
                                set: { newValue in
                                    model.detectorInnerRadius = CGFloat(newValue)
                                    updateVirtual(true)
                                }
                            ),
                            // Not bounded by the outer radius. That bound was
                            // the reason this control could never widen the
                            // annulus from the inside — it ran out of travel at
                            // exactly the point where it should start pushing.
                            in: model.innerRadiusRange,
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    updateVirtual(false)
                                }
                            }
                        )
                        if model.calibrations?.diff_step != nil{
                            Text(String(format: "%.1f (mrad)", innerAngle))
                                .frame(minWidth: 24, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        
                    }else{
                        Text(String(format: "%.0f (pix)", model.detectorInnerRadius))
                            .frame(minWidth: 24, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                    }
                }

                Divider()

                // The point detector hides both the size slider and the mode
                // picker. Removing them outright would shrink this panel, and
                // since the sidebar stacks the pattern view above it — and the
                // pattern is flexible, being aspectRatio(.fit) — SwiftUI hands
                // the freed height to the pattern, which visibly grows. Laying
                // out hidden copies keeps the panel exactly the height it has
                // for the other shapes, so nothing above it moves.
                //
                // Nothing may be *added* here either. Extra content raises this
                // panel's minimum height above the other shapes', which raises
                // the window's minimum — and a wrapped Text with
                // .fixedSize(vertical:) is worse still, because its minimum
                // grows as the column narrows and the window then cannot shrink
                // at all.
                if model.detectorShape == .point {
                    reservedControlSpace
                }

                if model.detectorShape != .point {
                    Picker("Mode", selection: $model.calculationMode) {
                        Text("Integrate").tag(CalculationMode.integrate)
                        Text("COM").tag(CalculationMode.com)
                        Text("DPC").tag(CalculationMode.dpc)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.calculationMode) { _, _ in
                        updateVirtual() }
                }

                if model.calculationMode == .com && model.detectorShape != .point {
                    Picker("Axis", selection: Binding<COMAxis>(
                        get: { model.comAxis },
                        set: { newAxis in
                            DispatchQueue.main.async {
                                model.comAxis = newAxis
                                updateVirtual()
                            }
                        }
                    )) {
                        Text("X").tag(COMAxis.x)
                        Text("Y").tag(COMAxis.y)
                        Text("Color").tag(COMAxis.color)
                    }
                    .pickerStyle(.segmented)
                }

                if model.calculationMode == .dpc && model.detectorShape != .point {
                    Picker("DPC Axis", selection: $model.dpcAxis) {
                        Text("L-R").tag(DPCAxis.leftRight)
                        Text("U-D").tag(DPCAxis.upDown)
                        Text("Color").tag(DPCAxis.color)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.dpcAxis) { _, _ in
                        updateVirtual()
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .disabled(model.imageWidth == 0)
            .padding(4)
        }
    }
}

private struct PatternHoverInfo {
    let i: Int
    let j: Int
    let intensity: Float
}

private struct ColorWheelLegend: View {
    private let diameter: CGFloat = 88

    var body: some View {
        Canvas { context, size in
            let pixelWidth = max(1, Int(size.width.rounded(.down)))
            let pixelHeight = max(1, Int(size.height.rounded(.down)))
            let side = CGFloat(min(pixelWidth, pixelHeight))
            let radius = side / 2.0 - 0.5
            let center = CGPoint(x: size.width / 2.0, y: size.height / 2.0)

            for y in 0..<pixelHeight {
                for x in 0..<pixelWidth {
                    let dx = CGFloat(x) + 0.5 - center.x
                    let dy = CGFloat(y) + 0.5 - center.y
                    let distance = sqrt(dx * dx + dy * dy)
                    guard distance <= radius else { continue }

                    let angle = atan2(Double(-dy), Double(dx))
                    var hue = angle / (2.0 * Double.pi)
                    if hue < 0 {
                        hue += 1.0
                    }

                    let brightness = Double(distance / radius)
                    let rect = CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)
                    context.fill(
                        Path(rect),
                        with: .color(Color(hue: hue, saturation: 1.0, brightness: brightness))
                    )
                }
            }

            let wheelRect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2.0,
                height: radius * 2.0
            )
            context.stroke(Path(ellipseIn: wheelRect), with: .color(.white.opacity(0.85)), lineWidth: 1.0)

            var ticks = Path()
            for degrees in stride(from: 0.0, to: 360.0, by: 45.0) {
                let radians = degrees * Double.pi / 180.0
                let inner = radius - (degrees.truncatingRemainder(dividingBy: 90.0) == 0 ? 8.0 : 5.0)
                let outerPoint = CGPoint(
                    x: center.x + CGFloat(cos(radians)) * radius,
                    y: center.y - CGFloat(sin(radians)) * radius
                )
                let innerPoint = CGPoint(
                    x: center.x + CGFloat(cos(radians)) * inner,
                    y: center.y - CGFloat(sin(radians)) * inner
                )
                ticks.move(to: innerPoint)
                ticks.addLine(to: outerPoint)
            }
            context.stroke(ticks, with: .color(.white.opacity(0.75)), lineWidth: 1.0)
        }
        .frame(width: diameter, height: diameter)
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.primary.opacity(0.16), lineWidth: 1)
        )
        .accessibilityLabel("Vector color reference")
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
