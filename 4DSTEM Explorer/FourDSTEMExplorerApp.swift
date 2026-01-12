import SwiftUI

extension Notification.Name {
    static let taskProgressUpdated = Notification.Name("updateProgress")
}

struct NoTrackProgressStyle: ProgressViewStyle {
    var color: Color = .accentColor
    var height: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        // configuration.fractionCompleted is 0.0 to 1.0
        let progress = configuration.fractionCompleted ?? 0
        
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: height / 2)
                .fill(color)
                .frame(width: geometry.size.width * CGFloat(progress))
        }
        .frame(height: height)
    }
}

@main
struct FourDSTEMExplorerApp: App {
    // Use StateObject for model ownership at the app root
    @StateObject private var model = DataViewModel()
    @StateObject private var openPanel = OpenPanelController()
    // Local state for user-editable scale text field (percent formatted)
    @State private var scale: Double = 1.0
    @State private var selectionMode: InteractiveMarkerView.SelectionMode = .point
    
    var body: some Scene {
        WindowGroup {
            RootView(selectionMode: $selectionMode)
            
                .environmentObject(model)
                .environmentObject(openPanel)
                .navigationSubtitle(model.selectedURL?.lastPathComponent ?? "")

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
                        Picker("", selection: $selectionMode) {
                            Image(systemName: "scope").tag( InteractiveMarkerView.SelectionMode.point)
                            Image(systemName: "rectangle.dashed").tag(InteractiveMarkerView.SelectionMode.marquee)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                        .onChange(of: selectionMode) { _, newMode in
                            switch newMode {
                            case .point:
                                // Clear any marquee and show the single pattern at the current selection
                                model.selectionRect = nil
                                model.updatePatternForCurrentSelection()
                            case .marquee:
                                // Initialize a 1×1 marquee at the current selection for immediate feedback
                                model.beginMarquee(atI: model.selectedI, j: model.selectedJ)
                            }
                        }

                        // Zoom Controls
                        Button {
                            NotificationCenter.default.post(name: .zoomOut, object: nil)
//                            scale = model.currentScale
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }

                        Button {
                            NotificationCenter.default.post(name: .zoomIn, object: nil)
//                            scale = model.currentScale
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
                    ToolbarItem() {
                        
                        if model.isLoading {
                            VStack(alignment: .leading, spacing: 2) {
                                ProgressView(value: model.progress, total: 1.0) // Determinate
                                    .progressViewStyle(.linear)
                                    .controlSize(.small)
                                    .frame(width: 100)
                                
                                    .onReceive(NotificationCenter.default.publisher(for: .taskProgressUpdated)) { notification in
                                        // Extract the value from userInfo
                                        if let progress = notification.object as? Double {
                                            model.progress = progress
                                        }
                                    }
                                
                            }
                        }
//                        Spacer()
                    }
                }
        }
        .commands {
            FourDSTEMMenuCommands(model: model, openPanel: openPanel)
        }
    }
}

