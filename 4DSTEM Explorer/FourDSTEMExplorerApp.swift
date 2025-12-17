import SwiftUI




@main
struct FourDSTEMExplorerApp: App {
    // Use StateObject for model ownership at the app root
    @StateObject private var model = DataViewModel()
    @StateObject private var openPanel = OpenPanelController()
    // Local state for user-editable scale text field (percent formatted)
    @State private var scale: Double = 1.0

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(openPanel)
                .toolbar {
                    ToolbarItemGroup(placement: .automatic) {
                        // Export Menu
                        Menu {
                            Button("Image") {
                                model.exportImage()
                            }
                            Button("Pattern") {
                                model.exportPattern()
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }

                        // Selection Mode
                        Picker("", selection: $model.selectionMode) {
                            Image(systemName: "scope").tag(SelectionMode.point)
                            Image(systemName: "rectangle.dashed").tag(SelectionMode.marquee)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)

                        // Zoom Controls
                        Button {
                            model.zoomOut()
                            scale = model.currentScale
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }

                        Button {
                            model.zoomIn()
                            scale = model.currentScale
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }

                        // Scale TextField
                        TextField("Scale", value: $scale, format: .percent)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                model.setScale(scale)
                            }
                    }
                }
        }
        .commands {
            FourDSTEMMenuCommands()
        }
    }
}

