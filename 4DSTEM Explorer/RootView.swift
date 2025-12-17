import SwiftUI
import AppKit

struct DetectorOverlay: View {
    // Inputs from your model
    let shape: DetectorShape
    let inner: CGFloat
    let outer: CGFloat
    let patternWidth: Int
    let patternHeight: Int

    var body: some View {
        GeometryReader { geo in
            let viewSize = geo.size
            // Compute aspect-fit rect for the pattern inside the view
            let imgW = CGFloat(max(patternWidth, 1))
            let imgH = CGFloat(max(patternHeight, 1))
            let imageAspect = imgW / imgH
            let viewAspect = viewSize.width / max(viewSize.height, 1)
            let drawRect: CGRect = {
                if imageAspect > viewAspect {
                    // full width, letterbox vertically
                    let drawHeight = viewSize.width / imageAspect
                    let yOffset = (viewSize.height - drawHeight) / 2.0
                    return CGRect(x: 0, y: yOffset, width: viewSize.width, height: drawHeight)
                } else {
                    // full height, letterbox horizontally
                    let drawWidth = viewSize.height * imageAspect
                    let xOffset = (viewSize.width - drawWidth) / 2.0
                    return CGRect(x: xOffset, y: 0, width: drawWidth, height: viewSize.height)
                }
            }()

            // Detector center is at center of pattern (as in DataViewModel.currentDetector())
            let center = CGPoint(
                x: drawRect.minX + drawRect.width * 0.5,
                y: drawRect.minY + drawRect.height * 0.5
            )

            // Convert radii from pattern pixels to view pixels (scale by drawRect size / pattern size)
            let scaleX = drawRect.width / imgW
            let scaleY = drawRect.height / imgH
            let scale = min(scaleX, scaleY) // uniform scale for circular shapes

            let innerR = max(0, inner) * scale
            let outerR = max(0, outer) * scale

            // Build paths for different detector shapes
            ZStack {
                switch shape {
                case .bf, .adf:
                    // Single circle (use outer for BF, inner for ADF or as desired)
                    let r = shape == .bf ? outerR : innerR
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .foregroundStyle(Color.accentColor.opacity(0.9))
                        .frame(width: r * 2, height: r * 2)
                        .position(center)

                case .af:
                    // Annulus: region between inner and outer
                    // Draw two circles to indicate inner and outer bounds
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Color.accentColor.opacity(0.9))
                        .frame(width: innerR * 2, height: innerR * 2)
                        .position(center)
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Color.accentColor.opacity(0.9))
                        .frame(width: outerR * 2, height: outerR * 2)
                        .position(center)
                case .custom:
                    Rectangle()
                        .frame(width: 10, height: 10)
                case .point:
                    Rectangle()
                        .frame(width: 10, height: 10)

                }
                
            }
        }
        .allowsHitTesting(false) // overlay should not intercept interactions
    }
}

struct RootView: View {
    static let sharedModel = DataViewModel()
    @ObservedObject private var model: DataViewModel
    @EnvironmentObject private var openPanel: OpenPanelController

    init(model: DataViewModel = RootView.sharedModel) {
        self._model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            Divider()
            content
        }
        .padding(12)
        .frame(minWidth: 800, minHeight: 500)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("4DSTEM Explorer").font(.title).bold()
                if let url = model.selectedURL {
                    Text(url.lastPathComponent)
                        .foregroundColor(.secondary)
                }
                Text(model.status)
                    .foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Open File…") { openFile() }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
    }

    private var content: some View {
        HStack(alignment:.top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Pattern") {
                    ZStack {
                        if let pb = model.pixelBuffer {
                            PixelBufferView(pixelBuffer: pb)

                            // Overlay the detector shape above the pattern image
                            DetectorOverlay(
                                shape: model.detectorShape,
                                inner: model.detectorInnerRadius,
                                outer: model.detectorOuterRadius,
                                patternWidth: model.patternSize.width,
                                patternHeight: model.patternSize.height
                            )
                        } else {
                            Text(model.isLoading ? "Loading…" : "Select a point in the scan image.")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 256, height: 256)
                }
                detectorSettings
                    .frame(width: 240)
                
            }

            GroupBox("Scan Image") {
                ZStack {
                    if let scan = model.scanPixelBuffer {
                        ZStack(alignment: .topLeading) {
                            ClickableImageView(pixelBuffer: scan, onClick: { i, j in
                                model.select(i: i, j: j)
                            }, onDrag: { i, j in
                                model.select(i: i, j: j)
                            }, onArrowKey: { di, dj in
                                let newI = max(0, min(model.imageHeight - 1, model.selectedI + di))
                                let newJ = max(0, min(model.imageWidth - 1, model.selectedJ + dj))
                                model.select(i: newI, j: newJ)
                            })

                            // Overlay current selection label
                            Text("(i: \(model.selectedI), j: \(model.selectedJ))")
                                .padding(6)
                                .background(.thinMaterial)
                                .cornerRadius(6)
                                .padding(8)
                        }
                    } else {
                        Text(model.isLoading ? "Loading…" : "Open a file to compute the scan image.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(minWidth: 380, minHeight: 380)
            }

        }
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
                .onChange(of: model.detectorShape) { oldValue, newValue in
                    // Recompute when detector shape changes
                    model.computeScanImage()
                }

                // BF: Outer only
                if model.detectorShape == .bf {
                    HStack {
                        Text("Outer: ")
                        Slider(
                            value: Binding(
                                get: { Double(model.detectorOuterRadius) },
                                set: { newValue in
                                    model.detectorOuterRadius = CGFloat(newValue)
                                    model.computeScanImage(stride: 2)
                                }
                            ),
                            in: 1...Double(max(1, min(model.imageWidth, model.imageHeight))),
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    model.computeScanImage()
                                }
                            }
                        )
                    }
                }

                // ADF: Inner only
                if model.detectorShape == .adf {
                    HStack {
                        Text("Inner: ")
                        Slider(
                            value: Binding(
                                get: { Double(model.detectorInnerRadius) },
                                set: { newValue in
                                    model.detectorInnerRadius = CGFloat(newValue)
                                    model.computeScanImage(stride: 2)
                                }
                            ),
                            in: 0...Double(max(1, min(model.imageWidth, model.imageHeight))),
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    model.computeScanImage()
                                }
                            }
                        )
                    }
                }

                // AF: both Inner and Outer
                if model.detectorShape == .af {
                    HStack {
                        Text("Inner: ")
                        Slider(
                            value: Binding(
                                get: { Double(model.detectorInnerRadius) },
                                set: { newValue in
                                    model.detectorInnerRadius = CGFloat(newValue)
                                    model.computeScanImage(stride: 2)
                                }
                            ),
                            in: 0...Double(max(1, min(model.imageWidth, model.imageHeight))),
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    model.computeScanImage()
                                }
                            }
                        )
                    }
                    HStack {
                        Text("Outer: ")
                        Slider(
                            value: Binding(
                                get: { Double(model.detectorOuterRadius) },
                                set: { newValue in
                                    model.detectorOuterRadius = CGFloat(newValue)
                                    model.computeScanImage(stride: 2)
                                }
                            ),
                            in: 1...Double(max(1, min(model.imageWidth, model.imageHeight))),
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    model.computeScanImage()
                                }
                            }
                        )
                    }
                }

//                Button("Recompute") { model.computeScanImage() }
            }
            .padding(6)
        }
    }

    private func openFile() {
        openPanel.open { url in
            model.open(url: url)
        }
    }
}

#Preview {
    RootView()
}

