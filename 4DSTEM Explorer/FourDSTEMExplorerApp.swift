import SwiftUI

extension Notification.Name {
    static let taskProgressUpdated = Notification.Name("updateProgress")
    static let fileLoaded = Notification.Name("fileLoaded")
}

final class ExternalFileOpenHandler: NSObject, NSApplicationDelegate {
    @MainActor private static var pendingURLs: [URL] = []
    @MainActor private static var openMainWindow: (@MainActor () -> Void)?
    @MainActor private static var openURL: (@MainActor (URL) -> Void)?

    @MainActor
    static func configure(openMainWindow: @escaping @MainActor () -> Void, openURL: @escaping @MainActor (URL) -> Void) {
        self.openMainWindow = openMainWindow
        self.openURL = openURL
        drainPendingFiles()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            Self.queue(urls, application: application)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            Self.showMainWindow(in: sender)
        }
        return false
    }

    @MainActor
    private static func queue(_ urls: [URL], application: NSApplication) {
        guard !urls.isEmpty else { return }
        pendingURLs.append(contentsOf: urls)
        showMainWindow(in: application)

        Task { @MainActor in
            drainPendingFiles()
        }
    }

    @MainActor
    private static func showMainWindow(in application: NSApplication) {
        openMainWindow?()

        let mainWindow = application.windows.first(where: { $0.title == "4DSTEM Explorer" })
            ?? application.windows.first(where: { $0.canBecomeMain && $0.styleMask.contains(.titled) })

        if let mainWindow {
            if mainWindow.isMiniaturized {
                mainWindow.deminiaturize(nil)
            }
            mainWindow.makeKeyAndOrderFront(nil)
        }

        application.activate(ignoringOtherApps: true)
    }

    @MainActor
    private static func drainPendingFiles() {
        guard let openURL else { return }

        while !pendingURLs.isEmpty {
            openURL(pendingURLs.removeFirst())
        }
    }
}

private struct ExternalFileOpenRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let model: DataViewModel

    func body(content: Content) -> some View {
        content
            .onAppear {
                ExternalFileOpenHandler.configure(
                    openMainWindow: { openWindow(id: "main") },
                    openURL: { url in model.open(url: url) }
                )
            }
    }
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
    @NSApplicationDelegateAdaptor(ExternalFileOpenHandler.self) private var externalFileOpenHandler

    @State private var selectionMode: InteractiveMarkerView.SelectionMode = .point
    // Use StateObject for model ownership at the app root
    @StateObject private var model = DataViewModel()

    @StateObject private var openPanel = OpenPanelController()
    // Local state for user-editable scale text field (percent formatted)
    @State private var zoomScale: CGFloat = 1.0
    @State private var showDetector:Bool = true
    @State private var calculationMode:CalculationMode = .integrate

    var body: some Scene {
        Window("4DSTEM Explorer", id: "main") {
            RootView(zoomScale: $zoomScale, selectionMode: $selectionMode, showDetector: $showDetector, calculationMode: $calculationMode)
                .environmentObject(model)
                .environmentObject(openPanel)
                .navigationSubtitle(model.selectedURL?.lastPathComponent ?? "")
                .modifier(ExternalFileOpenRegistration(model: model))

                .toolbar {
                    
                    
                    ToolbarItemGroup(placement: .automatic) {

                        // Export Menu
                        Menu {
                            Button("Image") {
                                model.export(type: "image")
                                
                            }
                            .disabled(model.selectedURL == nil)
                            Button("Pattern") {
                                model.export(type: "pattern")
                            }
                            .disabled(model.selectedURL == nil)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }.disabled(model.selectedURL == nil)

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
                                model.selectionMode = .point
                                model.selectionRect = nil
//                                model.updatePatternForCurrentSelection()
                            case .marquee:
                                // Initialize a 1×1 marquee at the current selection for immediate feedback
                                model.selectionMode = .marquee
//                                model.beginMarquee(atI: model.selectedI, j: model.selectedJ)
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
                        TextField("Scale", value: Binding<Double>(
                            get: { Double(zoomScale) },
                            set: { zoomScale = CGFloat($0) }
                        ), format: .percent.precision(.fractionLength(0)))
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                            

                        

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
                }.onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                }
        }
        .handlesExternalEvents(matching: Set<String>())
        .commands {
            FourDSTEMMenuCommands(model: model, openPanel: openPanel, showDetector: $showDetector)
        }
    }
}
