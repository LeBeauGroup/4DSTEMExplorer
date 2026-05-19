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
            UTType(filenameExtension: "raw") ?? .data
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
    
    @State private var isCalibrationVisible:Bool = false

    
    let fileHint: String
    let onCancel: () -> Void
    let onOK: (String, String, String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("RAW Scan Dimensions").font(.title2).bold()
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the number of scan positions as “X×Y” (e.g., 80x80).").foregroundStyle(.secondary)
                if !fileHint.isEmpty {
                    Text(fileHint).font(.footnote).foregroundStyle(.secondary)
                }
                    VStack {
                        Text("Scan size (X×Y):")
                        TextField("80x80", text: $scan_dims)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        DisclosureGroup("Calibrations: ", isExpanded: $isCalibrationVisible) {
                            Text("Scan step (nm/pix):")
                            TextField("None", text: $scan_step)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                            Text("Diffraction sampling (mrad)/pix: ")
                            TextField("None", text: $diff_step)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                                       
                                    }

                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("OK") { onOK(scan_dims, scan_step, diff_step) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 325, height: 400)

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

