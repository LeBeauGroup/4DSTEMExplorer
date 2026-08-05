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

    @State private var isCalibrationVisible: Bool = false
    @State private var isTransformVisible: Bool = false
    @State private var metadataNote: String?
    @State private var metadataFailed: Bool = false
    @State private var hostWindow: NSWindow?

    let fileHint: String
    let onCancel: () -> Void
    let onOK: (String, String, String, String, Bool, Bool, Bool) -> Void

    /// Fills the fields in from a JSON sidecar, so the numbers come from the
    /// acquisition rather than from retyping them.
    private func loadMetadata() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.json]
        panel.prompt = "Load"
        panel.message = "Choose the JSON metadata written alongside this RAW file"

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
                // Show what was filled in, rather than leaving it collapsed and
                // apparently unchanged.
                isCalibrationVisible = true
            } catch {
                metadataFailed = true
                metadataNote = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        if let window = hostWindow {
            panel.beginSheetModal(for: window, completionHandler: adopt)
        } else {
            adopt(panel.runModal())
        }
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

                    DisclosureGroup("Calibrations:", isExpanded: $isCalibrationVisible) {
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

                    DisclosureGroup("Detector transforms:", isExpanded: $isTransformVisible) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Flip rows (mirror vertical)", isOn: $flipRows)
                            Toggle("Flip columns (mirror horizontal)", isOn: $flipCols)
                            Toggle("Transpose", isOn: $transpose)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("OK") { onOK(scan_dims, scan_step, diff_step, voltage, flipRows, flipCols, transpose) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340, height: 540)
        .background(WindowReader { hostWindow = $0 })
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

