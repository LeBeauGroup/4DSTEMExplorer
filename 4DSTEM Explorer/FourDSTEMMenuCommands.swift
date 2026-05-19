import SwiftUI

// MARK: - Menu Commands using direct model calls

struct FourDSTEMMenuCommands: Commands {
      @ObservedObject var model: DataViewModel
      @ObservedObject var openPanel: OpenPanelController
    @Binding var showDetector:Bool

//      init(model: DataViewModel, openPanel: OpenPanelController) {
//          self.model = model
//          self.openPanel = openPanel
//      }

    var body: some Commands {
        // File menu
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                openPanel.open { url in
                    model.open(url: url)
                }
            }
            .keyboardShortcut("o")
            Menu("Export") {
                Button("Image") {
                    model.export(type: "image")
                }.keyboardShortcut("i").disabled(model.selected == nil)
                Button("Pattern") {
                    model.export(type: "pattern")
                }.keyboardShortcut("p")
                    .disabled(model.selected == nil)
            }
        }

        // Export menu
        

        // Detector menu
        CommandMenu("Detector") {
            // Shape
            Button("Bright Field") {
                model.detectorShape = .bf
//                model.computeScanImage()
            }
            .keyboardShortcut("1")

            Button("Annular Dark-field") {
                model.detectorShape = .adf
//                model.computeScanImage()
            }
            .keyboardShortcut("2")

            Button("Annular Field") {
                model.detectorShape = .af
//                model.computeScanImage()
            }
            .keyboardShortcut("3")

            Divider()

            // Type
            Button("Integrating") {
                model.calculationMode = .integrate
            }
            .keyboardShortcut("1", modifiers: [.option])


            Button("Center of Mass") {
                model.calculationMode = .com
            }
            .keyboardShortcut("2", modifiers: [.option])
            Button("Differential Phase Contrast") {
                model.calculationMode = .dpc
            }
            .keyboardShortcut("3", modifiers: [.option])

            Divider()

            Button("Show/Hide Detector") {
                showDetector.toggle()
            }
            .keyboardShortcut("/")
        }

        // Image menu
        CommandMenu("Image") {
            Button("Zoom in") {
                NotificationCenter.default.post(name: .zoomIn, object: nil)
            }
            .keyboardShortcut("+")

            Button("Zoom out") {
                NotificationCenter.default.post(name: .zoomOut, object: nil)
            }
            .keyboardShortcut("-")

            Button("Zoom to fit") {
                NotificationCenter.default.post(name: .zoomToFit, object: nil)

            }
            .keyboardShortcut(".")

            Button("Actual size") {
                NotificationCenter.default.post(name: .zoomToActual, object: nil)
            }
            .keyboardShortcut("'")
        }
    }
}

