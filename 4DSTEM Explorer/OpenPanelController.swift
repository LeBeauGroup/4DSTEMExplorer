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
struct RawDimsSheet: View {
    @State var scan_dims: String
    @State var diff_step: String
    @State var scan_step: String
    @State var flipRows: Bool = true
    @State var flipCols: Bool = false
    @State var transpose: Bool = false

    @State private var isCalibrationVisible: Bool = false
    @State private var isTransformVisible: Bool = false

    let fileHint: String
    let onCancel: () -> Void
    let onOK: (String, String, String, Bool, Bool, Bool) -> Void

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

                    DisclosureGroup("Calibrations:", isExpanded: $isCalibrationVisible) {
                        Text("Scan step (nm/pix):")
                        TextField("None", text: $scan_step)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        Text("Diffraction sampling (mrad/pix):")
                        TextField("None", text: $diff_step)
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
                Button("OK") { onOK(scan_dims, scan_step, diff_step, flipRows, flipCols, transpose) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 325, height: 440)
    }
}

struct CalibrationSheet: View {
    @State var scanStep: String
    @State var diffStep: String

    let onCancel: () -> Void
    let onOK: (String, String) -> Void

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
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("OK") { onOK(scanStep, diffStep) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340, height: 180)
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

