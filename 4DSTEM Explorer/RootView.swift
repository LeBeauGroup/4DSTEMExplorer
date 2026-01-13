import SwiftUI
import AppKit

struct DetectorOverlay: View {
    let shape: DetectorShape
    let inner: CGFloat
    let outer: CGFloat
    let patternWidth: Int
    let patternHeight: Int
    @State private var centerViewPoint: CGPoint? = nil
    let onCenterChange: (CGPoint, Bool) -> Void
    let imageSizeProvider: () -> (width: Int, height: Int)

    var body: some View {
        GeometryReader { geo in
            let viewSize = geo.size
            let imgW = CGFloat(max(patternWidth, 1))
            let imgH = CGFloat(max(patternHeight, 1))
            let imageAspect = imgW / imgH
            let viewAspect = viewSize.width / max(viewSize.height, 1)
            let drawRect: CGRect = {
                if imageAspect > viewAspect {
                    let drawHeight = viewSize.width / imageAspect
                    let yOffset = (viewSize.height - drawHeight) / 2.0
                    return CGRect(x: 0, y: yOffset, width: viewSize.width, height: drawHeight)
                } else {
                    let drawWidth = viewSize.height * imageAspect
                    let xOffset = (viewSize.width - drawWidth) / 2.0
                    return CGRect(x: xOffset, y: 0, width: drawWidth, height: viewSize.height)
                }
            }()
            let defaultCenter = CGPoint(x: drawRect.midX, y: drawRect.midY)
            let center = centerViewPoint ?? defaultCenter
            let scale = min(drawRect.width / imgW, drawRect.height / imgH)
            let innerR = max(0, inner) * scale
            let outerR = max(0, outer) * scale

            ZStack {
                switch shape {
                case .bf, .adf:
                    let r = shape == .bf ? outerR : innerR
                    Circle().stroke(style: StrokeStyle(lineWidth: 2)).foregroundStyle(Color.accentColor.opacity(0.9)).frame(width: r * 2, height: r * 2).position(center)
                case .af:
                    Circle().stroke(style: StrokeStyle(lineWidth: 2)).foregroundStyle(Color.accentColor.opacity(0.9)).frame(width: innerR * 2, height: innerR * 2).position(center)
                    Circle().stroke(style: StrokeStyle(lineWidth: 2)).foregroundStyle(Color.accentColor.opacity(0.9)).frame(width: outerR * 2, height: outerR * 2).position(center)
                default: EmptyView()
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Clamp to drawRect
                        let x = min(max(value.location.x, drawRect.minX), drawRect.maxX)
                        let y = min(max(value.location.y, drawRect.minY), drawRect.maxY)
                        centerViewPoint = CGPoint(x: x, y: y)
                        // Map to image indices and notify
                        let imgW = max(patternWidth, 1)
                        let imgH = max(patternHeight, 1)
                        let normX = (x - drawRect.minX) / max(drawRect.width, 1)
                        let normY = (y - drawRect.minY) / max(drawRect.height, 1)
                        let j = Int(round(normX * CGFloat(max(imgW - 1, 0))))
                        let i = Int(round((1 - normY) * CGFloat(max(imgH - 1, 0))))
                        onCenterChange(CGPoint(x: j, y: i), true)
                    }
                    .onEnded { _ in
                        // Final notification on end
                        let x = min(max((centerViewPoint ?? defaultCenter).x, drawRect.minX), drawRect.maxX)
                        let y = min(max((centerViewPoint ?? defaultCenter).y, drawRect.minY), drawRect.maxY)
                        let normX = (x - drawRect.minX) / max(drawRect.width, 1)
                        let normY = (y - drawRect.minY) / max(drawRect.height, 1)
                        let imgW = max(patternWidth, 1)
                        let imgH = max(patternHeight, 1)
                        let j = Int(round(normX * CGFloat(max(imgW - 1, 0))))
                        let i = Int(round((1 - normY) * CGFloat(max(imgH - 1, 0))))
                        onCenterChange(CGPoint(x: j, y: i), false)
                    }
            )
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: DataViewModel
    @EnvironmentObject private var openPanel: OpenPanelController

    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isDraggingSelection: Bool = false
    @State private var dragStart: CGPoint? = nil
    @State private var currentDrag: CGPoint? = nil
    
    @State private var zoomScale: CGFloat = 1.0
    @State private var contentOffset: CGSize = .zero
    @State private var points = [CGPoint(x: 0, y: 0)]
    @State private var marquee:CGRect?
    @State private var currentImage: NSImage?
    @Binding var selectionMode: InteractiveMarkerView.SelectionMode
    @State var lastPoint: CGPoint?
    @FocusState private var isFocused: Bool

    var body: some View {
        
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Left Panel
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Pattern") {
                    ZStack {
                        if let pb = model.pixelBuffer {
                            PixelBufferView(pixelBuffer: pb)
                            DetectorOverlay(
                                shape: model.detectorShape,
                                inner: model.detectorInnerRadius,
                                outer: model.detectorOuterRadius,
                                patternWidth: model.patternSize.width,
                                patternHeight: model.patternSize.height,
                                onCenterChange: { point,interactive  in
                                    model.detectorCenter = point
                                    model.computeScanImage(interactive: interactive)

                                },
                                imageSizeProvider: { (width: model.imageWidth, height: model.imageHeight) }
                            )
                        } else {
                            Text(model.isLoading ? "Loading…" : "Select a point in the computed image.")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .foregroundColor(.secondary)
                        }
                    }
                    
//                    .frame(maxWidth: .infinity)
                    .aspectRatio(1.0,contentMode: .fit)
                }
                detectorSettings
                    .frame(width: 240)
                Spacer()
            }.padding(12)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
                // Right Panel: Computed Image
            GroupBox("Computed Image") {
                if let img = model.scanImage {
                    ZoomableImageView(image: img , lastPoint:$lastPoint, marquee: $marquee, selectionMode: $selectionMode)
                        .onChange(of: img, {
                        })
                        .onChange(of: lastPoint){ point in
                            model.selectedI = model.imageHeight - Int(floor(point?.y ?? 0))
                            model.selectedJ = Int(floor(point?.x ?? 0))
//                            print(model.selectedI, model.selectedJ)

                            model.updatePatternForCurrentSelection()
                        }
                        .onChange(of: marquee) { newValue in
                            model.marquee = newValue
                            model.updatePatternForCurrentSelection()

                        }
                        .focusable()                  // 1) Make focusable
                        .focused($isFocused)          // 2) Bind focus state
                        .focusEffectDisabled(true)
                        .onAppear { isFocused = true } // 3) Give it focus when it appears
//                        .onKeyPress(.leftArrow) {
//                            lastPoint?.x -= 1
//                            
//                            return .handled
//                        }
//                        .onKeyPress(.rightArrow) {
//                            lastPoint?.x += 1
//                            return .handled
//                        }
//                        .onKeyPress(.upArrow) {
//                            lastPoint?.y += 1
//                            return .handled
//                        }
//                        .onKeyPress(.downArrow) {
//                            lastPoint?.y -= 1
//                            return .handled
//                        }
                    
                    

                } else {
                    Text("No Image Loaded")
                }
//                ImageViewerRepresentable(model:_model)
            }

            }.padding(12)
        
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
        GroupBox("Detector") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Shape", selection: $model.detectorShape) {
                    Text("BF").tag(DetectorShape.bf)
                    Text("ADF").tag(DetectorShape.adf)
                    Text("AF").tag(DetectorShape.af)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.detectorShape) { _,
                    _ in model.computeScanImage()
                }

                if model.detectorShape == .bf || model.detectorShape == .af {
                    HStack {
                        Text("Outer: ")
                        Slider(value: Binding(get: { Double(model.detectorOuterRadius) }, set: { model.detectorOuterRadius = CGFloat($0); model.computeScanImage(interactive: true) }), in: 1...256, onEditingChanged: {
                            if !$0 { model.computeScanImage()
                            }})
                    }
                }
                if model.detectorShape == .adf || model.detectorShape == .af {
                    HStack {
                        Text("Inner: ")
                        Slider(value: Binding(get: { Double(model.detectorInnerRadius) }, set: { model.detectorInnerRadius = CGFloat($0); model.computeScanImage(interactive: true) }), in: 0...256, onEditingChanged: {
                            if !$0 { model.computeScanImage() }
                        })
                    }
                }

                Divider()

                Picker("Mode", selection: $model.calculationMode) {
                    Text("Integrate").tag(CalculationMode.integrate)
                    Text("COM").tag(CalculationMode.com)
                    Text("DPC").tag(CalculationMode.dpc)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.calculationMode) { _, _ in model.computeScanImage() }

                if model.calculationMode == .com {
                    Picker("Axis", selection: Binding<COMAxis>(get: { model.comAxis }, set: { model.comAxis = $0; model.computeScanImage(interactive: true); model.scheduleFullResRecompute() })) {
                        Text("X").tag(COMAxis.x); Text("Y").tag(COMAxis.y); Text("Color").tag(COMAxis.color)
                    }.pickerStyle(.segmented)
                }

                if model.calculationMode == .dpc {
                    Picker("DPC Axis", selection: $model.dpcAxis) {
                        Text("L-R").tag(DPCAxis.leftRight); Text("U-D").tag(DPCAxis.upDown)
                    }.pickerStyle(.segmented).onChange(of: model.dpcAxis) { _, _ in model.computeScanImage() }
                }
            }
            .disabled(model.imageWidth == 0)
            .padding(4)
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private func mapViewPointToImageIJ(_ point: CGPoint, viewSize: CGSize, imageW: Int, imageH: Int) -> (Int, Int) {
    let imgWf = CGFloat(max(imageW, 1))
    let imgHf = CGFloat(max(imageH, 1))
    let imageAspect = imgWf / imgHf
    let viewAspect = viewSize.width / max(viewSize.height, 1)
    let drawRect: CGRect = {
        if imageAspect > viewAspect {
            let drawHeight = viewSize.width / imageAspect
            let yOffset = (viewSize.height - drawHeight) / 2.0
            return CGRect(x: 0, y: yOffset, width: viewSize.width, height: drawHeight)
        } else {
            let drawWidth = viewSize.height * imageAspect
            let xOffset = (viewSize.width - drawWidth) / 2.0
            return CGRect(x: xOffset, y: 0, width: drawWidth, height: viewSize.height)
        }
    }()
    let nx = (point.x - drawRect.minX) / max(drawRect.width, 1)
    let ny = (point.y - drawRect.minY) / max(drawRect.height, 1)
    let cx = min(max(nx, 0), 1)
    let cy = min(max(ny, 0), 1)
    let i = Int(round((1 - cy) * CGFloat(max(imageH - 1, 0))))
    let j = Int(round(cx * CGFloat(max(imageW - 1, 0))))
    return (i, j)
}

private func mapViewportPointToImageSpacePoint(_ point: CGPoint, viewSize: CGSize, imageW: Int, imageH: Int) -> CGPoint {
    let imgW = CGFloat(max(imageW, 1))
    let imgH = CGFloat(max(imageH, 1))
    let imageAspect = imgW / imgH
    let viewAspect = viewSize.width / max(viewSize.height, 1)
    let drawRect: CGRect = {
        if imageAspect > viewAspect {
            let drawHeight = viewSize.width / imageAspect
            let yOffset = (viewSize.height - drawHeight) / 2.0
            return CGRect(x: 0, y: yOffset, width: viewSize.width, height: drawHeight)
        } else {
            let drawWidth = viewSize.height * imageAspect
            let xOffset = (viewSize.width - drawWidth) / 2.0
            return CGRect(x: xOffset, y: 0, width: drawWidth, height: viewSize.height)
        }
    }()
    // Convert to local coordinates within drawRect
    let localX = point.x - drawRect.minX
    let localY = point.y - drawRect.minY
    return CGPoint(x: localX, y: localY)
}

//private struct SelectionOverlay: View {
//    let imageWidth: Int
//    let imageHeight: Int
//    let selectionRectImageSpace: CGRect?
//    let onUpdateRectImageSpace: (CGRect) -> Void
//    let viewSize: CGSize
//    let zoomScale: CGFloat
//
//    // Visual constants (scale inversely with zoom to keep screen size constant)
//    private var handleSize: CGFloat { max(4, 6 / max(zoomScale, 0.0001)) }
//    private var handleHitSize: CGFloat { max(12, 15 / max(zoomScale, 0.0001)) }
//    private var strokeWidth: CGFloat { max(0.5, 1.0 / max(zoomScale, 0.0001)) }
//
//    var body: some View {
//        GeometryReader { _ in
//            if let rImg = selectionRectImageSpace {
//                // Normalize the image-space rect so width/height are always positive
//                let normX1 = min(rImg.minX, rImg.maxX)
//                let normY1 = min(rImg.minY, rImg.maxY)
//                let normX2 = max(rImg.minX, rImg.maxX)
//                let normY2 = max(rImg.minY, rImg.maxY)
//                let rImgNorm = CGRect(x: normX1, y: normY1, width: normX2 - normX1, height: normY2 - normY1)
//
//                // Compute drawRect that fits the image into the view
//                let imgW = CGFloat(max(imageWidth, 1))
//                let imgH = CGFloat(max(imageHeight, 1))
//                let imageAspect = imgW / imgH
//                let viewAspect = viewSize.width / max(viewSize.height, 1)
//                let drawRect: CGRect = {
//                    if imageAspect > viewAspect {
//                        let drawHeight = viewSize.width / imageAspect
//                        let yOffset = (viewSize.height - drawHeight) / 2.0
//                        return CGRect(x: 0, y: yOffset, width: viewSize.width, height: drawHeight)
//                    } else {
//                        let drawWidth = viewSize.height * imageAspect
//                        let xOffset = (viewSize.width - drawWidth) / 2.0
//                        return CGRect(x: xOffset, y: 0, width: drawWidth, height: viewSize.height)
//                    }
//                }()
//
//                // Map image-space rect to view-space rect
//                let sx = drawRect.width / imgW
//                let sy = drawRect.height / imgH
//                let vRect = CGRect(
//                    x: drawRect.minX + rImgNorm.origin.x * sx,
//                    y: drawRect.minY + rImgNorm.origin.y * sy,
//                    width: rImgNorm.width * sx,
//                    height: rImgNorm.height * sy
//                )
//                
//                // Clamp vRect to drawRect to avoid drawing outside the image area
//                let clampedVRect: CGRect = {
//                    var r = vRect
//                    let minX = max(drawRect.minX, r.minX)
//                    let minY = max(drawRect.minY, r.minY)
//                    let maxX = min(drawRect.maxX, r.maxX)
//                    let maxY = min(drawRect.maxY, r.maxY)
//                    return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
//                }()
//
//                // Draw the selection rectangle
//                Rectangle()
//                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: strokeWidth, dash: [6, 4]))
//                    .background(Rectangle().fill(Color.accentColor.opacity(0.10)))
//                    .frame(width: clampedVRect.width, height: clampedVRect.height)
//                    .position(x: clampedVRect.midX, y: clampedVRect.midY)
//                    .allowsHitTesting(false)
//
//                // Draw handles and attach resize gestures
//                ZStack {
//                    // Left
//                    handleView()
//                        .position(x: clampedVRect.minX, y: clampedVRect.midY)
//                        .gesture(resizeGesture(edge: .leading, vRect: vRect, drawRect: drawRect, imgW: imgW, imgH: imgH))
//                    // Right
//                    handleView()
//                        .position(x: clampedVRect.maxX, y: clampedVRect.midY)
//                        .gesture(resizeGesture(edge: .trailing, vRect: vRect, drawRect: drawRect, imgW: imgW, imgH: imgH))
//                    // Top
//                    handleView()
//                        .position(x: clampedVRect.midX, y: clampedVRect.minY)
//                        .gesture(resizeGesture(edge: .top, vRect: vRect, drawRect: drawRect, imgW: imgW, imgH: imgH))
//                    // Bottom
//                    handleView()
//                        .position(x: clampedVRect.midX, y: clampedVRect.maxY)
//                        .gesture(resizeGesture(edge: .bottom, vRect: vRect, drawRect: drawRect, imgW: imgW, imgH: imgH))
//                }
//                .frame(width: viewSize.width, height: viewSize.height)
//            }
//        }
//        .allowsHitTesting(true)
//    }
//
//    private enum EdgeHandle { case leading, trailing, top, bottom }
//
//    @ViewBuilder
//    private func handleView() -> some View {
//        ZStack {
//            Rectangle()
//                .fill(Color.white)
//                .frame(width: handleSize, height: handleSize)
//            Rectangle()
//                .fill(Color.clear)
//                .contentShape(Rectangle())
//                .frame(width: handleHitSize, height: handleHitSize)
//        }
//    }
//
//    private func resizeGesture(edge: EdgeHandle, vRect: CGRect, drawRect: CGRect, imgW: CGFloat, imgH: CGFloat) -> some Gesture {
//        DragGesture(minimumDistance: 0)
//            .onChanged { value in
//                var newVRect = vRect
//                switch edge {
//                case .leading:
//                    let newMinX = max(drawRect.minX, min(value.location.x, vRect.maxX))
//                    newVRect.origin.x = newMinX
//                    newVRect.size.width = vRect.maxX - newMinX
//                case .trailing:
//                    let newMaxX = max(vRect.minX, min(value.location.x, drawRect.maxX))
//                    newVRect.size.width = newMaxX - vRect.minX
//                case .top:
//                    let newMinY = max(drawRect.minY, min(value.location.y, vRect.maxY))
//                    newVRect.origin.y = newMinY
//                    newVRect.size.height = vRect.maxY - newMinY
//                case .bottom:
//                    let newMaxY = max(vRect.minY, min(value.location.y, drawRect.maxY))
//                    newVRect.size.height = newMaxY - vRect.minY
//                }
//                let newImgRect = viewRectToImageRect(newVRect, drawRect: drawRect, imgW: imgW, imgH: imgH)
//                onUpdateRectImageSpace(newImgRect)
//            }
//    }
//
//    private func viewRectToImageRect(_ viewRect: CGRect, drawRect: CGRect, imgW: CGFloat, imgH: CGFloat) -> CGRect {
//        let invSx = imgW / max(drawRect.width, 1)
//        let invSy = imgH / max(drawRect.height, 1)
//        var clamped = viewRect
//        clamped.origin.x = max(drawRect.minX, min(viewRect.origin.x, drawRect.maxX))
//        clamped.origin.y = max(drawRect.minY, min(viewRect.origin.y, drawRect.maxY))
//        let maxW = drawRect.maxX - clamped.origin.x
//        let maxH = drawRect.maxY - clamped.origin.y
//        clamped.size.width = max(0, min(viewRect.size.width, maxW))
//        clamped.size.height = max(0, min(viewRect.size.height, maxH))
//        let ix = (clamped.minX - drawRect.minX) * invSx
//        let iy = (clamped.minY - drawRect.minY) * invSy
//        let iw = clamped.width * invSx
//        let ih = clamped.height * invSy
//        return CGRect(x: ix, y: iy, width: iw, height: ih)
//    }
//}

