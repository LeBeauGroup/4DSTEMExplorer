import SwiftUI
import UniformTypeIdentifiers
import Accelerate

// MARK: - macOS App Entry
@main
struct FourDSTEMViewerApp: App {
    @StateObject private var store = STEMStore()

    var body: some Scene {
        WindowGroup("4D-STEM Explorer") {
            MainWindow()
                .environmentObject(store)
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Main Window (Toolbar + SplitView)
struct MainWindow: View {
    @EnvironmentObject private var store: STEMStore
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView { // vertical divider → left/right panes
                DiffractionPane()
                    .frame(minWidth: 360, idealWidth: 520)
                VirtualImagePane()
                    .frame(minWidth: 360, idealWidth: 520)
            }
        }
        .toolbar { mainToolbar }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: STEMStore.supportedUTTypes, allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { try await store.load(url: url) }
        }
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                showImporter = true
            } label: {
                Label("Open…", systemImage: "folder")
            }
            .help("Open a 4D-STEM dataset (DM4/HDF5/etc.)")
        }

        ToolbarItemGroup(placement: .automatic) {
            Picker("Detector", selection: $store.detectorMode) {
                ForEach(DetectorMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            Toggle(isOn: $store.logScale) { Image(systemName: "waveform.path.ecg") }
                .help("Log intensity scale")

            Picker("Colormap", selection: $store.colormap) {
                ForEach(Colormap.allCases) { cm in Text(cm.rawValue).tag(cm) }
            }
            .frame(width: 140)
        }

        ToolbarItemGroup(placement: .status) {
            PositionPicker()
            Button {
                Task { await store.exportSnapshot() }
            } label: { Label("Export", systemImage: "square.and.arrow.down") }
            .help("Export pane snapshots")
        }
    }
}

// MARK: - Left Pane: Diffraction Pattern
struct DiffractionPane: View {
    @EnvironmentObject private var store: STEMStore
    var body: some View {
        ZStack {
            PaneBackground(title: "Diffraction Pattern")
            if let cg = store.currentDiffractionCGImage {
                ZoomableImage(cgImage: cg, colormap: store.colormap)
            } else {
                ContentPlaceholder(title: "No frame loaded", message: "Open a dataset or use Demo → Generate Synthetic")
            }
        }
        .contextMenu { DemoMenu() }
    }
}

// MARK: - Right Pane: Virtual BF/DF Image
struct VirtualImagePane: View {
    @EnvironmentObject private var store: STEMStore
    var body: some View {
        ZStack {
            PaneBackground(title: store.detectorMode.label + " Image")
            if let cg = store.virtualImageCGImage {
                ZoomableImage(cgImage: cg, colormap: store.colormap)
            } else {
                ContentPlaceholder(title: "No image computed", message: "Choose a detector and open a dataset")
            }
        }
        .contextMenu { DemoMenu() }
    }
}

// MARK: - Shared Pane UI
struct PaneBackground: View {
    var title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            Spacer()
        }
        .background(.background)
    }
}

struct PositionPicker: View {
    @EnvironmentObject private var store: STEMStore
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.grid.2x2")
            Text("r:")
            Slider(value: $store.rIndexX, in: 0...Double(max(store.rx-1, 1)), step: 1) { Text("R X") }
                .frame(width: 160)
            Slider(value: $store.rIndexY, in: 0...Double(max(store.ry-1, 1)), step: 1) { Text("R Y") }
                .frame(width: 160)
            Text("(\(Int(store.rIndexX)), \(Int(store.rIndexY)))")
                .foregroundStyle(.secondary)
        }
        .help("Probe position selector")
    }
}

struct DemoMenu: View {
    @EnvironmentObject private var store: STEMStore
    var body: some View {
        Button("Generate Synthetic 4D Demo") { Task { await store.loadDemo() } }
        Button("Reset View") { store.resetView() }
    }
}

// MARK: - Zoomable Image (simple)
struct ZoomableImage: View {
    let cgImage: CGImage
    let colormap: Colormap
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size)
                var transform = CGAffineTransform.identity
                transform = transform.translatedBy(x: rect.midX + offset.width, y: rect.midY + offset.height)
                transform = transform.scaledBy(x: scale, y: scale)
                transform = transform.translatedBy(x: -rect.midX, y: -rect.midY)
                ctx.concatenate(transform)
                ctx.draw(Image(cgImage, scale: 1, label: Text("")), in: rect)
            }
            .gesture(zoomAndPanGesture(in: geo.size))
            .background(.black.opacity(0.85))
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(Int(scale*100))%")
                .font(.caption2)
                .padding(4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(6)
        }
    }

    private func zoomAndPanGesture(in _size: CGSize) -> some Gesture {
        SimultaneousGesture(
            MagnificationGesture().onChanged { scale = max(0.25, min(8.0, scale * $0)) },
            DragGesture().onChanged { offset = CGSize(width: offset.width + $0.translation.width, height: offset.height + $0.translation.height) }
        )
    }
}


// MARK: - Enums & Types
enum DetectorMode: String, CaseIterable, Identifiable {
    var id: String { rawValue }
    case brightField = "BF"
    case darkFieldAnnular = "ADF"
    case highAngleADF = "HAADF"
    var label: String { rawValue }
}

enum Colormap: String, CaseIterable, Identifiable { case gray, invert, hot
    var id: String { rawValue }
}

// MARK: - Components
struct ContentPlaceholder: View {
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.slash").font(.largeTitle)
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary)
        }
        .padding()
    }
}

// MARK: - Settings (placeholder)
struct SettingsView: View {
    @State private var dummy = false
    var body: some View {
        Form {
            Toggle("Reduce motion", isOn: $dummy)
            Text("Colormap preferences coming soon…")
        }.frame(width: 420, height: 160)
    }
}

// MARK: - macOS helpers
extension Image {
    init(_ cgImage: CGImage, scale: CGFloat, label: Text) {
        #if os(macOS)
        self.init(nsImage: NSImage(cgImage: cgImage, size: .zero))
        #else
        self.init(decorative: cgImage, scale: scale, orientation: .up)
        #endif
    }
}

