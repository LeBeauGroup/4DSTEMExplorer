import Foundation
import AppKit

// A lightweight view model that exposes export actions for Image and Pattern matrices.
// Provide closures that return the current matrices when called.

final class ExportViewModel: ObservableObject {
    // Supply these from your hosting environment (SwiftUI or AppKit bridge).
    var currentImageMatrix: () -> Matrix?
    var currentPatternMatrix: () -> Matrix?
    var suggestedDocumentName: () -> String? // e.g., window/document title

    init(currentImageMatrix: @escaping () -> Matrix?,
         currentPatternMatrix: @escaping () -> Matrix?,
         suggestedDocumentName: @escaping () -> String? = { nil }) {
        self.currentImageMatrix = currentImageMatrix
        self.currentPatternMatrix = currentPatternMatrix
        self.suggestedDocumentName = suggestedDocumentName
    }

    func exportImage() {
        guard let matrix = currentImageMatrix() else { return }
        presentSavePanel(defaultName: makeDefaultName(prefix: "Image")) { url in
            do {
                try MatrixExporting.writeTIFF(matrix: matrix, to: url, tiffDescription: "Exported Image")
            } catch {
                NSSound.beep()
                NSLog("Failed to export image: \(error)")
            }
        }
    }

    func exportPattern() {
        guard let matrix = currentPatternMatrix() else { return }
        presentSavePanel(defaultName: makeDefaultName(prefix: "Pattern")) { url in
            do {
                try MatrixExporting.writeTIFF(matrix: matrix, to: url, tiffDescription: "Exported Pattern")
            } catch {
                NSSound.beep()
                NSLog("Failed to export pattern: \(error)")
            }
        }
    }

    private func makeDefaultName(prefix: String) -> String {
        if let doc = suggestedDocumentName(), !doc.isEmpty {
            return "\(doc)_\(prefix)"
        }
        return prefix
    }

    private func presentSavePanel(defaultName: String, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.isExtensionHidden = false
        panel.allowedFileTypes = ["tif", "tiff"]
        panel.nameFieldStringValue = defaultName

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }
}
