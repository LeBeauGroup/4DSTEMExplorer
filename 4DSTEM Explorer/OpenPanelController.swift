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
        panel.allowedFileTypes = ["dm4", "mrc", "tiff", "tif", "raw"]
        panel.begin { resp in
            if resp == .OK, let url = panel.url {
                onSelect(url)
            }
        }
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

