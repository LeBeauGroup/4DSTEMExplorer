import SwiftUI
import AppKit

struct RootView: View {
    static let sharedModel = DataViewModel()
    @ObservedObject private var model: DataViewModel

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
        HStack(spacing: 12) {
            GroupBox("Scan Image") {
                ZStack {
                    if let scan = model.scanPixelBuffer {
                        ClickablePixelBufferView(pixelBuffer: scan) { i, j in
                            model.select(i: i, j: j)
                        }
                    } else {
                        Text(model.isLoading ? "Loading…" : "Open a file to compute the scan image.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(minWidth: 380, minHeight: 380)
            }
            GroupBox("Pattern") {
                ZStack {
                    if let pb = model.pixelBuffer {
                        PixelBufferView(pixelBuffer: pb)
                    } else {
                        Text(model.isLoading ? "Loading…" : "Select a point in the scan image.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(minWidth: 380, minHeight: 380)
            }
            detectorSettings
                .frame(width: 240)
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

                if model.detectorShape == .af {
                    HStack {
                        Text("Inner: ")
                        Slider(value: Binding(get: { Double(model.detectorInnerRadius) }, set: { model.detectorInnerRadius = CGFloat($0); model.computeScanImage() }), in: 0...Double(max(1, min(model.imageWidth, model.imageHeight))))
                    }
                }

                HStack {
                    Text("Outer: ")
                    Slider(value: Binding(get: { Double(model.detectorOuterRadius) }, set: { model.detectorOuterRadius = CGFloat($0); model.computeScanImage() }), in: 1...Double(max(1, min(model.imageWidth, model.imageHeight))))
                }

                Button("Recompute") { model.computeScanImage() }
            }
            .padding(6)
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["dm4", "mrc", "tiff", "tif", "raw", "png", "jpg", "jpeg"]
        panel.begin { resp in
            if resp == .OK, let url = panel.url {
                model.open(url: url)
            }
        }
    }
}

#Preview {
    RootView()
}
