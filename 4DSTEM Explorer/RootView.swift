import SwiftUI
import AppKit


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
    @Binding var calculationMode:CalculationMode

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
    
    private func scaleBarPixelsAndLabel(for viewWidth: CGFloat) -> (pixels: CGFloat, label: String)? {
        
        guard let step = model.calibrations?.scan_step, step.isFinite, step > 0 else { return nil }
        // step is distance per pixel (e.g., nm/px or um/px). We'll assume meters per pixel if step is SI; format to nm/µm/mm intelligently.
        // Choose a target on-screen bar width ~120-180pt (depends on image scale) by picking a nice round physical length.
        // We don't know units, but we can format in nm/µm/mm by scaling step.
        let metersPerPixel = step*1e-9 // assume meters per pixel
        // Candidate nice lengths in meters
        let niceMeters: [Float] = [1e-9, 2e-9, 5e-9, 1e-8, 2e-8, 5e-8, 1e-7, 2e-7, 5e-7, 1e-6, 2e-6, 5e-6, 1e-5, 2e-5, 5e-5, 1e-4, 2e-4, 5e-4, 1e-3]
        // Desired pixel width range
        
        let minPx: Float = 80
        let maxPx: Float = 160
        var best: (px: Float, m: Float)? = nil
        
        for m in niceMeters {
            let px = (m / metersPerPixel)
            if px >= minPx && px <= maxPx {
                best = (px, m)
                break
            }
        }
        // Fallback: pick closest within range
        if best == nil {
            var closest: (diff: Float, px: Float, m: Float)? = nil
            for m in niceMeters {
                let px = Float(m / metersPerPixel)
                let diff = abs(px - (minPx + maxPx) / 2)
                if closest == nil || diff < closest!.diff {
                    closest = (diff, px, m)
                }
            }
            if let c = closest { best = (c.px, c.m) }
        }
        guard let chosen = best else { return nil }
        let label = formatMeters(chosen.m)
        return (pixels: CGFloat(chosen.px), label: label)
    }

    private func formatMeters(_ m: Float) -> String {
        let absM = abs(m)
        if absM < 1e-6 {
            return String(format: "%.0f nm", m * 1e9)
        } else if absM < 1e-3 {
            return String(format: "%.0f µm", m * 1e6)
        } else if absM < 1.0 {
            return String(format: "%.2f mm", m * 1e3)
        } else {
            return String(format: "%.2f m", m)
        }
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
        guard let info = patternHoverInfo else {
            return "(i: -, j: -, intensity: -)"
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
                                showDetector: $showDetector,
                                onCenterChange: { point, interactive in
                                    if let idx = model.detectors.firstIndex(where: { $0.id == detector.id }) {
                                        model.detectors[idx].center = point
                                        if detector.id == model.selectedDetectorID {
                                            model.detectorCenter = point
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
                }
                .onReceive(NotificationCenter.default.publisher(for: .fileLoaded)) { _ in
                    updatePattern(0, 0)
                    updateVirtual()
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

//                        GeometryReader { geo in
//                            if let bar = scaleBarPixelsAndLabel(for: geo.size.width) {
//                                VStack {
//                                    Spacer()
//                                    HStack {
//                                        // Draw bar
//                                        Rectangle()
//                                            .fill(Color.primary)
//                                            .frame(width: bar.pixels, height: 2)
//                                            .overlay(
//                                                Text(bar.label)
//                                                    .font(.caption2)
//                                                    .foregroundStyle(.secondary)
//                                                    .padding(.top, 2)
//                                                    .frame(maxWidth: .infinity, alignment: .leading)
//                                                    .offset(y: 6)
//                                                , alignment: .bottomLeading
//                                            )
//                                        Spacer()
//                                    }
//                                }
//                                .padding(8)
//                                .allowsHitTesting(false)
//                            }
//                        }
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
                    .frame(width: 240)
                Spacer()
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
        
//        .padding(12)
//        .frame(minWidth: 800, minHeight: 500)
    }

    private var detectorSettings: some View {
        GroupBox("Detectors") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Name")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Shape")
                            .frame(width: 48, alignment: .trailing)
                        Text("Color")
                            .frame(width: 36, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    List(selection: Binding<Set<DetectorConfiguration.ID>>(
                        get: { model.selectedDetectorIDs },
                        set: { model.selectedDetectorIDs = $0 }
                    )) {
                        ForEach(model.detectors) { detector in
                            HStack {
                                Text(detector.name)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(detectorShapeLabel(detector.shape))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .trailing)
                                ColorPicker("", selection: Binding<Color>(
                                    get: { detector.color },
                                    set: { newColor in
                                        if let idx = model.detectors.firstIndex(where: { $0.id == detector.id }) {
                                            model.detectors[idx].color = newColor
                                            if detector.id == model.selectedDetectorID {
                                                model.detectorColor = newColor
                                            }
                                        }
                                    }
                                ), supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 36)
                            }
                            .tag(detector.id as DetectorConfiguration.ID?)
                        }
                    }
                    .frame(height: 96)
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
                }

                Divider()

                Picker("Shape", selection: $model.detectorShape) {
                    Text("BF").tag(DetectorShape.bf)
                    Text("ADF").tag(DetectorShape.adf)
                    Text("AF").tag(DetectorShape.af)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.detectorShape) { old, new in
                    
                   updateVirtual()
                }

                if model.detectorShape == .bf || model.detectorShape == .af {
                    HStack {
                        Text("Outer: ")
                        Slider(
                            value: Binding<Double>(
                                get: { Double(model.detectorOuterRadius) },
                                set: { newValue in
                                    model.detectorOuterRadius = CGFloat(newValue)
                                    model.detectorInnerRadius = min(model.detectorInnerRadius, model.detectorOuterRadius)
                                    updateVirtual(true)
                                }
                            ),
                            in: 1...min(Double(model.patternSize.width)/2.0, Double(model.patternSize.height)/2.0),
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
                                    model.detectorInnerRadius = min(CGFloat(newValue), model.detectorOuterRadius)
                                    updateVirtual(true)
                                }
                            ),
                            in: 1...Double(model.detectorOuterRadius),
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

                Picker("Mode", selection: $model.calculationMode) {
                    Text("Integrate").tag(CalculationMode.integrate)
                    Text("COM").tag(CalculationMode.com)
                    Text("DPC").tag(CalculationMode.dpc)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.calculationMode) { _, _ in
                    updateVirtual() }

                if model.calculationMode == .com {
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

                if model.calculationMode == .dpc {
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
