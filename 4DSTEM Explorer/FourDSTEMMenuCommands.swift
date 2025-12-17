import SwiftUI

// MARK: - Menu Commands using direct model calls
struct FourDSTEMMenuCommands: Commands {
    @EnvironmentObject private var model: DataViewModel
    @EnvironmentObject private var openPanel: OpenPanelController
    
    var body: some Commands {
        // File menu
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                openPanel.open { url in
                    model.open(url: url)
                }
            }
            .keyboardShortcut("o")
        }

        // Export menu
        CommandMenu("Export") {
            Button("Image") {
                model.exportImage()
            }
            Button("Pattern") {
                model.exportPattern()
            }
        }

        // Detector menu
        CommandMenu("Detector") {
            // Shape
            Button("Bright Field") {
                model.detectorShape = .bf
                model.computeScanImage()
            }
            .keyboardShortcut("1")

            Button("Annular Dark-field") {
                model.detectorShape = .adf
                model.computeScanImage()
            }
            .keyboardShortcut("2")

            Button("Annular Field") {
                model.detectorShape = .af
                model.computeScanImage()
            }
            .keyboardShortcut("3")

            Divider()

            // Type
            Button("Integrating") {
                model.detectorType = .integrating
                model.computeScanImage()
            }
            .keyboardShortcut("1", modifiers: [.option])

            Button("Differential Phase Contrast") {
                model.detectorType = .dpc
                model.computeScanImage()
            }
            .keyboardShortcut("2", modifiers: [.option])

            Button("Center of Mass") {
                model.detectorType = .com
                model.computeScanImage()
            }
            .keyboardShortcut("3", modifiers: [.option])

            Divider()

            Button("Show/Hide selection") {
                // If you track selection visibility on the model, toggle it here.
                // model.selectionIsHidden.toggle()
            }
            .keyboardShortcut("/")
        }

        // Image menu
        CommandMenu("Image") {
            Button("Zoom in") {
                model.zoomIn()
            }
            .keyboardShortcut("+")

            Button("Zoom out") {
                model.zoomOut()
            }
            .keyboardShortcut("-")

            Button("Zoom to fit") {
                // Provide a zoomToFit() on your model if desired.
                // model.zoomToFit()
            }
            .keyboardShortcut(".")

            Button("Actual size") {
                model.setScale(1.0)
            }
            .keyboardShortcut("'")
        }
    }
}

