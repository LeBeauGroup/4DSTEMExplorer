import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers

final class OpenPanelController: ObservableObject {
    /// Allowed content types for the open panel. Default is any type.
    var allowedContentTypes: [UTType] = [.item]
    
//    @MainActor
//    func open() {
//        let panel = NSOpenPanel()
//        panel.allowsMultipleSelection = false
//        panel.canChooseDirectories = false
//        panel.allowedFileTypes = ["dm4", "mrc", "tiff", "tif", "raw"]
//        panel.begin { _ in }
//    }
    
    @MainActor
    func open(onSelect: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Use modern API: allowedContentTypes instead of deprecated allowedFileTypes
        panel.allowedContentTypes = [
            UTType(filenameExtension: "dm4") ?? .data,
            UTType(filenameExtension: "mrc") ?? .data,
            UTType.tiff,
            UTType(filenameExtension: "tif") ?? .tiff,
            UTType(filenameExtension: "raw") ?? .data,
            UTType(filenameExtension: "emd") ?? .data,
            UTType(filenameExtension: "h5") ?? .data,
            UTType(filenameExtension: "hdf5") ?? .data
        ]
        panel.begin { resp in
            if resp == .OK, let url = panel.url {
                onSelect(url)
            }
        }
    }
}
/// Hands back the window hosting this view. A nested open panel has to be
/// attached to it as a sheet: the RAW dimensions panel is itself presented as a
/// sheet, and on the fallback path inside a modal session, where a free-floating
/// panel would never receive events.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct RawDimsSheet: View {
    @State var scan_dims: String
    @State var diff_step: String
    @State var scan_step: String
    @State var voltage: String = "None"
    @State var flipRows: Bool = true
    @State var flipCols: Bool = false
    @State var transpose: Bool = false

    @State var isCalibrationVisible: Bool = false
    @State private var metadataNote: String?
    @State private var metadataFailed: Bool = false
    /// What "Load Metadata…" read, kept so the export can be based on it and
    /// named after it rather than after the raster.
    @State private var importedMetadata: ScanMetadata?
    @State private var hostWindow: NSWindow?

    let fileHint: String
    /// The RAW file being opened. Only used to start the metadata panel in the
    /// right folder — the sidecar is written next to the data far more often
    /// than not, so anywhere else is a wasted navigation.
    var fileURL: URL? = nil
    let onCancel: () -> Void
    let onOK: (String, String, String, String, Bool, Bool, Bool, ScanMetadata?) -> Void

    /// Fills the fields in from a JSON sidecar, so the numbers come from the
    /// acquisition rather than from retyping them.
    private func loadMetadata() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Both formats are read; the content is sniffed rather than trusted to
        // the extension, so a mislabelled file still works.
        panel.allowedContentTypes = ScanMetadata.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.prompt = "Load"
        panel.message = "Choose the JSON, XML or TOML metadata written alongside this RAW file"

        func adopt(_ response: NSApplication.ModalResponse) {
            guard response == .OK, let url = panel.url else { return }
            do {
                let metadata = try ScanMetadata.read(url: url)
                if let w = metadata.scanWidth, let h = metadata.scanHeight { scan_dims = "\(w)x\(h)" }
                if let step = metadata.scanStepNanometres { scan_step = trimmed(step) }
                if let step = metadata.diffractionStepMilliradians { diff_step = trimmed(step) }
                if let volts = metadata.voltageKilovolts { voltage = trimmed(volts) }
                metadataFailed = false
                metadataNote = metadata.summary
                importedMetadata = metadata
                // Show what was filled in, rather than leaving it collapsed and
                // apparently unchanged.
                isCalibrationVisible = true
            } catch {
                metadataFailed = true
                metadataNote = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                importedMetadata = nil
            }
        }

        if let window = hostWindow {
            panel.beginSheetModal(for: window, completionHandler: adopt)
        } else {
            adopt(panel.runModal())
        }
    }

    /// How long the panel takes to grow or shrink. Shared with the content's
    /// own animation so the two move together.
    private static let resizeDuration: TimeInterval = 0.2

    /// Keeps the window the size of its content while the content is moving.
    ///
    /// Animating the window to a precomputed target does not work once the
    /// content animates too: the target has to be read after the change, and by
    /// then SwiftUI is part way through its own animation, so what comes back is
    /// an intermediate height and the window animates to the wrong place.
    ///
    /// So the window is not animated at all. It follows — each tick it is set to
    /// whatever the content currently measures, with no animation of its own.
    /// The content's animation is the only clock, which is why the two cannot
    /// drift apart: there is only one of them.
    private func followContentSize() {
        guard let window = hostWindow, let content = window.contentView else { return }
        let swiftUIView = content.subviews.first ?? content

        let deadline = Date().addingTimeInterval(Self.resizeDuration + 0.1)
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { tick in
            swiftUIView.layoutSubtreeIfNeeded()
            let target = swiftUIView.fittingSize
            guard target.height > 0 else { return }

            var frame = window.frame
            let chrome = frame.height - content.frame.height
            let height = target.height + chrome
            if abs(height - frame.height) > 0.5 {
                // The top edge stays put: AppKit positions a window from its
                // bottom left, so height has to be taken off the origin too or
                // the title bar walks up the screen.
                frame.origin.y += frame.height - height
                frame.size.height = height
                window.setFrame(frame, display: true)
            }
            if Date() >= deadline { tick.invalidate() }
        }
        RunLoop.main.add(timer, forMode: RunLoopMode.commonModes)
    }

    private func trimmed(_ value: Float) -> String {
        return String(format: "%g", value)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("RAW Scan Dimensions").font(.title2).bold()
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the number of scan positions as X\u{00D7}Y (e.g., 80x80).").foregroundStyle(.secondary)
                if !fileHint.isEmpty {
                    Text(fileHint).font(.footnote).foregroundStyle(.secondary)
                }
                VStack {
                    Text("Scan size (X×Y):")
                    TextField("80x80", text: $scan_dims)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)

                    Button("Load Metadata\u{2026}") { loadMetadata() }
                        .padding(.top, 2)
                    if let note = metadataNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(metadataFailed ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 260)
                    }

                    // Not behind a disclosure triangle, and above the
                    // calibrations. The orientation is the one thing here that
                    // is wrong by default as often as it is right — it depends
                    // on which detector wrote the file — and a wrong choice is
                    // not obvious afterwards, it just mirrors the scan. The
                    // calibrations below can be left empty and filled in later;
                    // this cannot.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Detector transforms:")
                            Spacer()
                        }
                        Toggle("Flip rows (mirror vertical)", isOn: $flipRows)
                        Toggle("Flip columns (mirror horizontal)", isOn: $flipCols)
                        Toggle("Transpose", isOn: $transpose)
                    }
                    .padding(.top, 6)

                    DisclosureGroup("Calibrations:", isExpanded: Binding(
                        get: { isCalibrationVisible },
                        set: { expanded in
                            // Animated, and over the same span the window takes.
                            // Left unanimated the fields appear at once while
                            // the panel is still opening underneath them.
                            withAnimation(.easeInOut(duration: Self.resizeDuration)) {
                                isCalibrationVisible = expanded
                            }
                        })) {
                        Text("Scan step (nm/pix):")
                        TextField("None", text: $scan_step)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        Text("Diffraction sampling (mrad/pix):")
                        TextField("None", text: $diff_step)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        Text("Accelerating voltage (kV):")
                        TextField("None", text: $voltage)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("OK") { onOK(scan_dims, scan_step, diff_step, voltage, flipRows, flipCols, transpose, importedMetadata) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowReader { hostWindow = $0 })
        .onChange(of: isCalibrationVisible) { _, _ in
            followContentSize()
        }
    }
}

struct CalibrationSheet: View {
    @State var scanStep: String
    @State var diffStep: String
    @State var voltage: String

    let onCancel: () -> Void
    let onOK: (String, String, String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Calibrate").font(.title2).bold()
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Scan step (nm/pixel):")
                        .frame(width: 180, alignment: .leading)
                    TextField("None", text: $scanStep)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                HStack {
                    Text("Diffraction sampling (mrad/pixel):")
                        .frame(width: 180, alignment: .leading)
                    TextField("None", text: $diffStep)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                HStack {
                    Text("Accelerating voltage (kV):")
                        .frame(width: 180, alignment: .leading)
                    TextField("None", text: $voltage)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("OK") { onOK(scanStep, diffStep, voltage) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340, height: 220)
    }
}

#else
final class OpenPanelController: ObservableObject {
    @MainActor
    func open() {
        // No-op on non-macOS platforms
    }
}
#endif

