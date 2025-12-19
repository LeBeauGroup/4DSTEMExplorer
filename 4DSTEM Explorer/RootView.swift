import SwiftUI
import AppKit

struct DetectorOverlay: View {
    let shape: DetectorShape
    let inner: CGFloat
    let outer: CGFloat
    let patternWidth: Int
    let patternHeight: Int

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
            let center = CGPoint(x: drawRect.midX, y: drawRect.midY)
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
        }
        .allowsHitTesting(false)
    }
}

struct RootView: View {
    @EnvironmentObject private var model: DataViewModel
    @EnvironmentObject private var openPanel: OpenPanelController

    @State private var columnVisibility = NavigationSplitViewVisibility.all
    
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
                                patternHeight: model.patternSize.height
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
                    GeometryReader { geo in
                        // Compute a stable draw rect that does not depend on stride/pixel content
                        let imgW = max(CGFloat(model.imageWidth), 1)
                        let imgH = max(CGFloat(model.imageHeight), 1)
                        let aspect = imgW / imgH
                        let containerSize = geo.size
                        // Fit a rectangle of the image aspect inside the available container
                        let targetSize: CGSize = {
                            let containerAspect = containerSize.width / max(containerSize.height, 1)
                            if aspect > containerAspect {
                                // width-bound
                                return CGSize(width: containerSize.width, height: containerSize.width / aspect)
                            } else {
                                // height-bound
                                return CGSize(width: containerSize.height * aspect, height: containerSize.height)
                            }
                        }()
                        let origin = CGPoint(x: (containerSize.width - targetSize.width) / 2,
                                             y: (containerSize.height - targetSize.height) / 2)

                        ZStack {
                            Color.clear
                            ImageViewerRepresentable()
                                .environmentObject(model)
                                // Render the image into the stable rect regardless of stride changes
                                .frame(width: targetSize.width, height: targetSize.height)
                                .position(x: origin.x + targetSize.width / 2, y: origin.y + targetSize.height / 2)
                                .clipped()
                        }
                        .frame(width: containerSize.width, height: containerSize.height)
                    }
                    .frame(minWidth: 400, minHeight: 400)
                }.padding(12)
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
        GroupBox("Detector") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Shape", selection: $model.detectorShape) {
                    Text("BF").tag(DetectorShape.bf)
                    Text("ADF").tag(DetectorShape.adf)
                    Text("AF").tag(DetectorShape.af)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.detectorShape) { _, _ in model.computeScanImage() }

                if model.detectorShape == .bf || model.detectorShape == .af {
                    HStack {
                        Text("Outer: ")
                        Slider(value: Binding(get: { Double(model.detectorOuterRadius) }, set: { model.detectorOuterRadius = CGFloat($0); model.computeScanImage(interactive: true) }), in: 1...256, onEditingChanged: { if !$0 { model.computeScanImage() }})
                    }
                }
                if model.detectorShape == .adf || model.detectorShape == .af {
                    HStack {
                        Text("Inner: ")
                        Slider(value: Binding(get: { Double(model.detectorInnerRadius) }, set: { model.detectorInnerRadius = CGFloat($0); model.computeScanImage(interactive: true) }), in: 0...256, onEditingChanged: { if !$0 { model.computeScanImage() }})
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
