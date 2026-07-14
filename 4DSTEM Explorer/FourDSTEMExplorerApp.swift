import SwiftUI
import AppKit

extension Notification.Name {
    static let taskProgressUpdated = Notification.Name("updateProgress")
    static let fileLoaded = Notification.Name("fileLoaded")
}

@MainActor
final class RecentFilesController: ObservableObject {
    @Published private(set) var urls: [URL] = []

    private let documentController = NSDocumentController.shared

    init() {
        refresh()
    }

    func noteOpened(_ url: URL) {
        documentController.noteNewRecentDocumentURL(url)
        refresh()
    }

    func clear() {
        documentController.clearRecentDocuments(nil)
        refresh()
    }

    func refresh() {
        urls = documentController.recentDocumentURLs
    }
}

final class ExternalFileOpenHandler: NSObject, NSApplicationDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("FourDSTEMExplorerMainWindow")

    @MainActor private static var pendingURLs: [URL] = []
    @MainActor private static var openMainWindow: (@MainActor () -> Void)?
    @MainActor private static var openURL: (@MainActor (URL) -> Void)?
    @MainActor private static weak var mainWindow: NSWindow?

    @MainActor
    static func configure(openMainWindow: @escaping @MainActor () -> Void, openURL: @escaping @MainActor (URL) -> Void) {
        self.openMainWindow = openMainWindow
        self.openURL = openURL
        Task { @MainActor in
            await Task.yield()
            if focusMainWindow(in: NSApp) {
                drainPendingFiles()
            } else if !pendingURLs.isEmpty {
                openMainWindow()
                await Task.yield()
                if focusMainWindow(in: NSApp) {
                    drainPendingFiles()
                }
            }
        }
    }

    @MainActor
    static func registerMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.identifier = mainWindowIdentifier
        window.isReleasedWhenClosed = false
        mainWindow = window
        if !pendingURLs.isEmpty {
            _ = focusMainWindow(in: NSApp)
            drainPendingFiles()
        }
    }

    @MainActor
    static func openFiles(_ urls: [URL], application: NSApplication) {
        queue(urls, application: application)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            Self.openFiles(urls, application: application)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Task { @MainActor in
            Self.openFiles([URL(fileURLWithPath: filename)], application: sender)
        }
        return true
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

        Task { @MainActor in
            if focusMainWindow(in: application) {
                drainPendingFiles()
                return
            }

            await Task.yield()

            if focusMainWindow(in: application) {
                drainPendingFiles()
                return
            }

            openMainWindow?()
            await Task.yield()

            if focusMainWindow(in: application) {
                drainPendingFiles()
            }
        }
    }

    @MainActor
    private static func showMainWindow(in application: NSApplication) {
        if focusMainWindow(in: application) {
            return
        }

        openMainWindow?()

        Task { @MainActor in
            await Task.yield()
            _ = focusMainWindow(in: application)
        }
    }

    @MainActor
    private static func existingMainWindow(in application: NSApplication) -> NSWindow? {
        if let mainWindow {
            return mainWindow
        }

        if let window = application.windows.first(where: { $0.identifier == mainWindowIdentifier }) {
            return window
        }

        let preferredWindows = [application.keyWindow, application.mainWindow].compactMap { $0 }
        if let window = preferredWindows.first(where: isContentWindow) {
            return window
        }

        if let window = application.windows.first(where: { $0.title == "4DSTEM Explorer" && isContentWindow($0) }) {
            return window
        }

        return application.windows.first(where: isContentWindow)
    }

    private static func isContentWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.canBecomeMain && window.styleMask.contains(.titled)
    }

    @MainActor
    @discardableResult
    private static func focusMainWindow(in application: NSApplication) -> Bool {
        guard let window = existingMainWindow(in: application) else {
            return false
        }

        mainWindow = window
        window.identifier = mainWindowIdentifier
        window.isReleasedWhenClosed = false

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        return true
    }

    @MainActor
    private static func drainPendingFiles() {
        guard let openURL else { return }

        while !pendingURLs.isEmpty {
            openURL(pendingURLs.removeFirst())
        }
    }
}

private struct MainWindowRegistrationView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowRegistrationView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            ExternalFileOpenHandler.registerMainWindow(nsView.window)
        }
    }
}

private final class WindowRegistrationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            ExternalFileOpenHandler.registerMainWindow(self?.window)
        }
    }
}

private struct ExternalFileOpenRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let model: DataViewModel
    let recentFiles: RecentFilesController

    func body(content: Content) -> some View {
        content
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onAppear {
                ExternalFileOpenHandler.configure(
                    openMainWindow: { openWindow(id: "main") },
                    openURL: { url in
                        recentFiles.noteOpened(url)
                        model.open(url: url)
                    }
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
    @StateObject private var recentFiles = RecentFilesController()

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
                .background(MainWindowRegistrationView())
                .navigationSubtitle(model.selectedURL?.lastPathComponent ?? "")
                .modifier(ExternalFileOpenRegistration(model: model, recentFiles: recentFiles))
                .alert("Unable to Load File", isPresented: Binding(
                    get: { model.loadErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            model.loadErrorMessage = nil
                        }
                    }
                )) {
                    Button("OK", role: .cancel) {
                        model.loadErrorMessage = nil
                    }
                } message: {
                    Text(model.loadErrorMessage ?? "")
                }

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
        .defaultLaunchBehavior(.presented)
        .commands {
            FourDSTEMMenuCommands(model: model, openPanel: openPanel, recentFiles: recentFiles, showDetector: $showDetector)
        }
    }
}
