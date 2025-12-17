import SwiftUI
import Combine
import UniformTypeIdentifiers

final class OpenPanelController: NSObject, ObservableObject {
    @Published var selectedURL: URL?

    func open() {
        let openPanel = NSOpenPanel()
        // Use modern UTType-based API instead of deprecated allowedFileTypes
        if #available(macOS 12.0, *) {
            var types: [UTType] = [.tiff]
            // Add known RAW and custom extensions. UTType for specific vendor RAWs may vary; allow generic image/raw and custom filename extensions.
            if let rawType = UTType(filenameExtension: "raw") { types.append(rawType) }
            if let mrcType = UTType(filenameExtension: "mrc") { types.append(mrcType) }
            if let dm4Type = UTType(filenameExtension: "dm4") { types.append(dm4Type) }
            openPanel.allowedContentTypes = types
        } else {
            // Fallback for older macOS versions
            openPanel.allowedFileTypes = ["raw", "public.tiff", "mrc", "dm4"]
        }
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        
        if (openPanel.runModal() == NSApplication.ModalResponse.OK){
            if let selectedURL = openPanel.url {
                self.selectedURL = selectedURL
                
                // add to recents menu
                let dc = NSDocumentController.shared
                dc.noteNewRecentDocumentURL(selectedURL)
            }
        }
    }
}

// MARK: - Main App Structure
@main
struct FourDSTEMExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = OpenPanelController()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 500, minHeight: 400)
        }
        .commands {
            FourDSTEMCommands(controller: controller)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

// MARK: - App Delegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup code here
    }
}

// MARK: - Commands (Menu Bar)
struct FourDSTEMCommands: Commands {
    let controller: OpenPanelController
    var body: some Commands {
        // File Menu additions
        CommandGroup(replacing: .newItem) {
            Button("New") {
                // Handle new document
            }
            .keyboardShortcut("n")
            
            Button("Open...") {
                controller.open()
            }
            .keyboardShortcut("o")
        }
        
        // Detector Menu
        CommandMenu("Detector") {
            Button("Bright field") {
                NotificationCenter.default.post(name: .detectorShapeChanged, object: 0)
            }
            .keyboardShortcut("1")
            
            Button("Annular Dark-field") {
                NotificationCenter.default.post(name: .detectorShapeChanged, object: 1)
            }
            .keyboardShortcut("2")
            
            Button("Annual Field") {
                NotificationCenter.default.post(name: .detectorShapeChanged, object: 2)
            }
            .keyboardShortcut("3")
            
            Divider()
            
            Button("Integrating") {
                NotificationCenter.default.post(name: .detectorTypeChanged, object: 0)
            }
            .keyboardShortcut("1", modifiers: [.option])
            
            Button("Differential Phase Contrast") {
                NotificationCenter.default.post(name: .detectorTypeChanged, object: 1)
            }
            .keyboardShortcut("2", modifiers: [.option])
            
            Button("Center of Mass") {
                NotificationCenter.default.post(name: .detectorTypeChanged, object: 2)
            }
            .keyboardShortcut("3", modifiers: [.option])
            
            Divider()
            
            Button("Show/Hide selection") {
                NotificationCenter.default.post(name: .toggleDetectorVisibility, object: nil)
            }
            .keyboardShortcut("/")
        }
        
        // Image Menu
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
                NotificationCenter.default.post(name: .zoomActual, object: nil)
            }
            .keyboardShortcut("'")
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var viewModel = FourDSTEMViewModel()
    @State private var scale: Double = 100
    @EnvironmentObject var openPanel: OpenPanelController
    @State private var isPresentingProbeSheet = false
    
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // Sidebar - Pattern Viewer
            SidebarView(viewModel: viewModel)
                .frame(minWidth: 256)
        } detail: {
            // Main Image Viewer
            ImageViewerView(viewModel: viewModel, scale: $scale)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // Export Menu
                Menu {
                    Button("Image") {
                        viewModel.exportImage()
                    }
                    Button("Pattern") {
                        viewModel.exportPattern()
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                
                Spacer()
                
                // Selection Mode
                Picker("", selection: $viewModel.selectionMode) {
                    Image(systemName: "scope")
                        .tag(SelectionMode.point)
                    Image(systemName: "rectangle.dashed")
                        .tag(SelectionMode.marquee)
                }
                .pickerStyle(.segmented)
                .frame(width: 80)
                .onChange(of: viewModel.selectionMode) { oldValue, newValue in
                    // Handle selection mode change
                }
                
                // Zoom Controls
                Button {
                    viewModel.zoomOut()
                    scale = viewModel.currentScale
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                
                Button {
                    viewModel.zoomIn()
                    scale = viewModel.currentScale
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                
                // Scale TextField
                TextField("Scale", value: $scale, format: .percent)
                    .frame(width: 55)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.setScale(scale)
                    }
            }
        }
        .onChange(of: openPanel.selectedURL) { oldValue, newValue in
            if newValue != nil {
                isPresentingProbeSheet = true
            }
        }
        .sheet(isPresented: $isPresentingProbeSheet) {
            if let url = openPanel.selectedURL {
                ProbeSelectView(fileURL: url) {
                    isPresentingProbeSheet = false
                }
            }
        }
    }
}

// MARK: - Sidebar View
struct SidebarView: View {
    @ObservedObject var viewModel: FourDSTEMViewModel
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Pattern Viewer
                PatternImageView(image: viewModel.patternImage)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        if let coordinates = viewModel.patternCoordinates {
                            Text(coordinates)
                                .foregroundColor(.white)
                                .font(.system(size: 12))
                                .padding(5)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let value = viewModel.patternValue {
                            Text(value)
                                .foregroundColor(.white)
                                .font(.system(size: 12))
                                .padding(5)
                        }
                    }
                
                // Controls
                ControlsView(viewModel: viewModel)
                    .padding()
            }
        }
    }
}

// MARK: - Controls View
struct ControlsView: View {
    @ObservedObject var viewModel: FourDSTEMViewModel
    
    var body: some View {
        GroupBox {
            VStack(spacing: 12) {
                // Log Checkbox
                Toggle("Log", isOn: $viewModel.displayLog)
                
                // Detector Type Segmented Control
                Picker("Type", selection: $viewModel.detectorType) {
                    Text("Int").tag(DetectorType.integrating)
                    Text("DPC").tag(DetectorType.dpc)
                    Text("COM").tag(DetectorType.com)
                }
                .pickerStyle(.segmented)
                
                // Detector Shape Segmented Control
                Picker("Shape", selection: $viewModel.detectorShape) {
                    Text("BF").tag(DetectorShape.brightField)
                    Text("ADF").tag(DetectorShape.annularDarkField)
                    Text("AF").tag(DetectorShape.annualField)
                }
                .pickerStyle(.segmented)
                
                // Radius Controls
                HStack {
                    Text("Inner")
                        .frame(width: 50, alignment: .trailing)
                    TextField("", value: $viewModel.innerRadius, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    
                    Spacer()
                    
                    // X/Y Selector
                    Picker("", selection: $viewModel.xyMode) {
                        Text("x").tag(XYMode.x)
                        Text("y").tag(XYMode.y)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 80)
                }
                
                HStack {
                    Text("Outer")
                        .frame(width: 50, alignment: .trailing)
                    TextField("", value: $viewModel.outerRadius, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
            }
        }
    }
}

// MARK: - Image Viewer View (Converted from ImageViewer.swift)
struct ImageViewerView: View {
    @ObservedObject var viewModel: FourDSTEMViewModel
    @Binding var scale: Double
    
    @State private var imageScale: CGFloat = 1.0
    @State private var imageOffset: CGSize = .zero
    @State private var lastDragLocation: CGPoint = .zero
    @State private var selectionRect: CGRect?
    @State private var isSelectionMoving: Bool = false
    @State private var isSelectionNew: Bool = true
    @FocusState private var isFocused: Bool
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .darkGray)
                
                if let image = viewModel.mainImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(imageScale)
                        .offset(imageOffset)
                        .overlay {
                            // Selection overlay
                            if !viewModel.selectionIsHidden {
                                SelectionOverlay(
                                    selectionRect: $selectionRect,
                                    selectionMode: viewModel.selectionMode,
                                    imageSize: image.size,
                                    viewSize: geometry.size,
                                    scale: imageScale
                                )
                            }
                        }
                        .gesture(createDragGesture(in: geometry))
                        .simultaneousGesture(createMagnificationGesture())
                        .focusable()
                        .focused($isFocused)
                        .onAppear {
                            isFocused = true
                        }
                } else {
                    Text("No image loaded")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .gridColor))
        .onKeyPress(.upArrow) {
            moveSelection(dx: 0, dy: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(dx: 0, dy: 1)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            moveSelection(dx: -1, dy: 0)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveSelection(dx: 1, dy: 0)
            return .handled
        }
    }
    
    private func createDragGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDragChanged(value: value, geometry: geometry)
            }
            .onEnded { value in
                handleDragEnded(value: value)
            }
    }
    
    private func handleDragChanged(value: DragGesture.Value, geometry: GeometryProxy) {
        if viewModel.selectionIsHidden {
            return
        }
        
        let location = value.location
        
        switch viewModel.selectionMode {
        case .point:
            // Update point selection
            if selectionRect == nil || isSelectionNew {
                selectionRect = CGRect(origin: location, size: .zero)
                isSelectionNew = false
            } else {
                selectionRect?.origin = location
            }
            notifyDelegate()
            
        case .marquee:
            if selectionRect == nil || !isInSelectionRect(location) {
                // Start new selection
                selectionRect = CGRect(origin: location, size: CGSize(width: 1, height: 1))
                isSelectionMoving = false
                lastDragLocation = location
            } else if isSelectionMoving {
                // Move existing selection
                let dx = location.x - lastDragLocation.x
                let dy = location.y - lastDragLocation.y
                
                if var rect = selectionRect {
                    rect.origin.x += dx
                    rect.origin.y += dy
                    selectionRect = rect
                }
                lastDragLocation = location
            } else {
                // Resize selection
                if var rect = selectionRect {
                    rect.size.width = location.x - rect.origin.x
                    rect.size.height = location.y - rect.origin.y
                    selectionRect = rect
                }
            }
            notifyDelegate()
            
        case .none:
            break
        }
    }
    
    private func handleDragEnded(value: DragGesture.Value) {
        if viewModel.selectionIsHidden {
            return
        }
        
        let location = value.location
        
        if viewModel.selectionMode == .marquee {
            if isInSelectionRect(location) {
                isSelectionMoving = true
                lastDragLocation = location
            } else {
                isSelectionMoving = false
            }
        }
        
        isSelectionNew = false
    }
    
    private func isInSelectionRect(_ point: CGPoint) -> Bool {
        guard let rect = selectionRect else { return false }
        
        var hitRect = rect
        if hitRect.size.width < 0 {
            hitRect.origin.x += hitRect.size.width
            hitRect.size.width = abs(hitRect.size.width)
        }
        if hitRect.size.height < 0 {
            hitRect.origin.y += hitRect.size.height
            hitRect.size.height = abs(hitRect.size.height)
        }
        
        return hitRect.contains(point)
    }
    
    private func moveSelection(dx: CGFloat, dy: CGFloat) {
        guard selectionRect != nil, viewModel.selectionMode != .none else { return }
        
        let rate: CGFloat = 1.0
        selectionRect?.origin.x += dx * rate
        selectionRect?.origin.y += dy * rate
        
        notifyDelegate()
    }
    
    private func notifyDelegate() {
        // Calculate scaled rect and notify view model
        if let rect = selectionRect {
            let scaleFactor = (viewModel.mainImage?.size.width ?? 1) / imageScale
            var scaledRect = rect
            scaledRect.origin.x *= scaleFactor
            scaledRect.origin.y *= scaleFactor
            scaledRect.size.width *= scaleFactor
            scaledRect.size.height *= scaleFactor
            
            if viewModel.selectionMode == .point {
                let i = Int(scaledRect.origin.x)
                let j = Int(scaledRect.origin.y)
                viewModel.selectPatternAt(i: i, j: j)
            } else {
                viewModel.averagePatternInRect(rect: scaledRect)
            }
        }
    }
    
    private func createMagnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                imageScale = value
            }
            .onEnded { value in
                imageScale = value
                scale = value * 100
            }
    }
}

// MARK: - Selection Overlay
struct SelectionOverlay: View {
    @Binding var selectionRect: CGRect?
    let selectionMode: SelectionMode
    let imageSize: CGSize
    let viewSize: CGSize
    let scale: CGFloat
    
    var body: some View {
        Canvas { context, size in
            guard let rect = selectionRect else { return }
            
            switch selectionMode {
            case .marquee:
                // Draw marquee selection
                let path = Path(rect)
                context.fill(path, with: .color(.red.opacity(0.25)))
                context.stroke(path, with: .color(.red), lineWidth: 0.5)
                
            case .point:
                // Draw point selection (crosshairs)
                drawPointSelection(context: context, point: rect.origin)
                
            case .none:
                break
            }
        }
    }
    
    private func drawPointSelection(context: GraphicsContext, point: CGPoint) {
        let strokeWidth: CGFloat = 1.0
        let longOffset: CGFloat = 8.0
        let shortOffset: CGFloat = longOffset * 0.25
        
        let adjustedCenter = CGPoint(
            x: point.x - strokeWidth / 2.0 + 1,
            y: point.y - strokeWidth / 2.0 + 1
        )
        
        // Draw crosshairs
        let offsets: [(CGFloat, CGFloat)] = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        
        for (dx, dy) in offsets {
            let outerPoint = CGPoint(
                x: adjustedCenter.x + dx * longOffset,
                y: adjustedCenter.y + dy * longOffset
            )
            let innerPoint = CGPoint(
                x: adjustedCenter.x + dx * shortOffset,
                y: adjustedCenter.y + dy * shortOffset
            )
            
            var path = Path()
            path.move(to: outerPoint)
            path.addLine(to: innerPoint)
            context.stroke(path, with: .color(.red), lineWidth: strokeWidth)
        }
        
        // Draw coordinates text
        let text = "(\(Int(point.x)), \(Int(point.y)))"
        let textPosition = CGPoint(x: adjustedCenter.x + 10, y: adjustedCenter.y)
        
        context.draw(
            Text(text)
                .foregroundColor(.red)
                .font(.system(size: 10)),
            at: textPosition,
            anchor: .leading
        )
    }
}

// MARK: - Pattern Image View
struct PatternImageView: View {
    let image: NSImage?
    
    var body: some View {
        if let image = image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
        }
    }
}

// MARK: - View Model
class FourDSTEMViewModel: ObservableObject {
    @Published var mainImage: NSImage?
    @Published var patternImage: NSImage?
    @Published var patternCoordinates: String?
    @Published var patternValue: String?
    
    @Published var selectionMode: SelectionMode = .point
    @Published var detectorType: DetectorType = .integrating
    @Published var detectorShape: DetectorShape = .brightField
    @Published var displayLog: Bool = true
    @Published var innerRadius: Double = 5.0
    @Published var outerRadius: Double = 10.0
    @Published var xyMode: XYMode = .x
    @Published var currentScale: Double = 100.0
    @Published var selectionIsHidden: Bool = false
    
    // Matrix storage (you'll need to implement this based on your Matrix class)
    var matrixStorage: Any? // Replace with your Matrix type
    
    func zoomIn() {
        currentScale = min(currentScale * 1.2, 2000)
    }
    
    func zoomOut() {
        currentScale = max(currentScale / 1.2, 10)
    }
    
    func setScale(_ scale: Double) {
        currentScale = max(10, min(scale, 2000))
    }
    
    func exportImage() {
        // Export implementation
    }
    
    func exportPattern() {
        // Export implementation
    }
    
    func selectPatternAt(i: Int, j: Int) {
        // Implementation for selecting pattern at specific coordinates
        patternCoordinates = "(\(i), \(j))"
        // Update pattern image and value based on matrix data
    }
    
    func averagePatternInRect(rect: CGRect) {
        // Implementation for averaging pattern in rectangle
        // This should update patternImage and patternValue
    }
}

// MARK: - Enums
enum SelectionMode: Int {
    case point
    case marquee
    case none
}

enum DetectorType: Int {
    case integrating = 0
    case dpc = 1
    case com = 2
}

enum DetectorShape: Int {
    case brightField = 0
    case annularDarkField = 1
    case annualField = 2
}

enum XYMode: Int {
    case x = 1
    case y = 0
}

// MARK: - Notification Names
extension Notification.Name {
    static let detectorShapeChanged = Notification.Name("detectorShapeChanged")
    static let detectorTypeChanged = Notification.Name("detectorTypeChanged")
    static let toggleDetectorVisibility = Notification.Name("toggleDetectorVisibility")
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let zoomToFit = Notification.Name("zoomToFit")
    static let zoomActual = Notification.Name("zoomActual")
}

// MARK: - ProbeSelectView placeholder declaration
// The actual implementation of ProbeSelectView should be in a separate file.
struct ProbeSelectView: View {
    let fileURL: URL
    let onDismiss: () -> Void
    var body: some View {
        // Placeholder content
        Text("ProbeSelectView for \(fileURL.lastPathComponent)")
            .frame(width: 400, height: 300)
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        onDismiss()
                    }
                }
            }
    }
}

