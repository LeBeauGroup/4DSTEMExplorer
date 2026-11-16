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

        // Keep the window freely resizable in both directions.
        //
        // Inside a `Window` scene a `NavigationSplitView` reports a fixed
        // ideal height to SwiftUI's content-driven sizing, which pins the
        // window's maximum height to its current height — so it can be
        // dragged wider (the detail column has no maximum width) but not
        // taller. `.windowResizability(.contentMinSize)` on the scene is not
        // enough on its own, so clear the AppKit max size explicitly. This
        // runs again on every layout pass (updateNSView re-registers), which
        // re-asserts the unbounded ceiling after SwiftUI touches it.
        let unbounded = NSSize(width: CGFloat.greatestFiniteMagnitude,
                               height: CGFloat.greatestFiniteMagnitude)
        window.styleMask.insert(.resizable)
        window.maxSize = unbounded
        window.contentMaxSize = unbounded

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

/// Sets the window's represented document to the open file, so the titlebar
/// shows the filename, a document proxy icon, and the right-click / ⌘-click
/// path popup. When no file is open the view is left untouched and the window
/// keeps its plain app title.
private struct RepresentedDocument: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.navigationDocument(url)
        } else {
            content
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
    @StateObject private var pluginManager = PluginManager.shared
    @StateObject private var pluginRunner = PluginRunner.shared
    @State private var zoomScale: CGFloat = 1.0
    @State private var zoomText: String = "100"
    @State private var showDetector:Bool = true
    @State private var calculationMode:CalculationMode = .integrate

    var body: some Scene {
        Window("4DSTEM Explorer", id: "main") {
            RootView(zoomScale: $zoomScale, selectionMode: $selectionMode, showDetector: $showDetector, calculationMode: $calculationMode)
                // Tell the window the content may be *any* size, so it can be
                // dragged taller as well as wider. Only `maxWidth`/`maxHeight`
                // are set — deliberately no `minHeight`/`idealHeight`, which on
                // an earlier attempt forced the window taller than the screen
                // and pushed its titlebar under the menubar. With no ideal the
                // window still opens at the layout's natural size and simply
                // becomes resizable upward from there.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environmentObject(model)
                .environmentObject(openPanel)
                .background(MainWindowRegistrationView())
                // Show the open file's name in the titlebar, with a document
                // proxy icon and the standard right-click / ⌘-click path popup.
                // `.navigationDocument` sets the window's represented URL, which
                // is what AppKit uses to drive both. Falls back to the plain
                // app title when nothing is loaded.
                .modifier(RepresentedDocument(url: model.selectedURL))
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
                            Button("Export All…") {
                                model.exportAll()
                            }
                            .disabled(model.selectedURL == nil)
                            Divider()
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

                        // Zoom Controls — route to active panel (image or pattern)
                        Button {
                            NotificationCenter.default.post(
                                name: model.focusedPanel == .image ? .zoomOut : .zoomOutPattern,
                                object: nil)
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }

                        Button {
                            NotificationCenter.default.post(
                                name: model.focusedPanel == .image ? .zoomToFit : .zoomToFitPattern,
                                object: nil)
                        } label: {
                            Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                        }

                        Button {
                            NotificationCenter.default.post(
                                name: model.focusedPanel == .image ? .zoomIn : .zoomInPattern,
                                object: nil)
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }

                        // Scale TextField — apply only on Enter, display updates from external zoom changes
                        HStack(spacing: 2) {
                            TextField("", text: $zoomText)
                                .frame(width: 48)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .onSubmit {
                                    let cleaned = zoomText
                                        .trimmingCharacters(in: .whitespaces)
                                        .replacingOccurrences(of: "%", with: "")
                                    if let value = Double(cleaned), value > 0 {
                                        zoomScale = CGFloat(value / 100)
                                    } else {
                                        zoomText = "\(Int((Double(zoomScale) * 100).rounded()))%"
                                    }
                                }
                                .onChange(of: zoomScale) { _, newZoom in
                                    zoomText = "\(Int((Double(newZoom) * 100).rounded()))%"
                                }
//                            Text("%")
//                                .font(.callout)
//                                .foregroundStyle(.secondary)
                        }
                            

                        

                    }
                    ToolbarItem() {
                        
                        if model.isLoading {
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    ProgressView(value: model.progress, total: 1.0) // Determinate
                                        .progressViewStyle(.linear)
                                        .controlSize(.small)
                                        .frame(width: 130)

                                        .onReceive(NotificationCenter.default.publisher(for: .taskProgressUpdated)) { notification in
                                            // Extract the value from userInfo
                                            if let progress = notification.object as? Double {
                                                model.progress = progress
                                            }
                                        }

                                    // What it is doing, which matters most when
                                    // the answer is "waiting for iCloud" — the
                                    // one case where a long wait is not the
                                    // application's own doing.
                                    Text(model.status)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(width: 130, alignment: .leading)
                                        .help(model.status)
                                }

                                Button {
                                    model.cancelLoading()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Stop loading")
                                .accessibilityLabel("Stop loading")
                            }
                        }
//                        Spacer()
                    }
                }.onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                    PluginSheetController.preferredHostWindowIdentifier = ExternalFileOpenHandler.mainWindowIdentifier
                    pluginManager.reload()
                }
        }
        // Treat the content's size as a *minimum* only, not a fixed size. The
        // default resizability for a `Window` scene is `.contentSize`, which
        // pins the window's height to whatever the content currently wants —
        // so the window could grow sideways (the detail pane has no maximum
        // width) but not vertically. `.contentMinSize` keeps the content's
        // minimum as the floor and lets the user drag the window taller or
        // shorter freely.
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.presented)
        .commands {
            FourDSTEMMenuCommands(model: model,
                                  openPanel: openPanel,
                                  recentFiles: recentFiles,
                                  pluginManager: pluginManager,
                                  pluginRunner: pluginRunner,
                                  showDetector: $showDetector)
        }

        // ⌘, — where a Mac user looks to turn automatic update checking off.
        Settings {
            SettingsView()
        }
    }
}
