//
//  PluginResultViews.swift
//  4DSTEM Explorer
//
//  Presentation of plugin results in their own windows.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import SwiftUI
import AppKit
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

// MARK: - Window

/// Owns one result window. Results open in windows rather than sheets so
/// several can be compared side by side, and so the main view keeps working.
final class PluginResultWindowController: NSObject, NSWindowDelegate {

    /// Windows are ordered out and released when closed; until then the
    /// controller has to keep itself alive.
    private static var open: [PluginResultWindowController] = []

    private var window: NSWindow?

    static func present(_ payload: PluginResultPayload) {
        let controller = PluginResultWindowController()
        controller.show(payload)
        open.append(controller)
    }

    /// Opening size. Image results follow the data's aspect ratio: a 256×64 scan
    /// in a fixed portrait window would be a thin strip with dead space above and
    /// below it, and dragging the bottom edge would only add more.
    static func initialSize(for payload: PluginResultPayload, on screen: NSScreen?) -> NSSize {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let ceilingWidth = Swift.min(760, visible.width - 80)
        let ceilingHeight = Swift.min(820, visible.height - 80)

        switch payload.kind {
        case .plot:
            return NSSize(width: Swift.min(620, ceilingWidth), height: Swift.min(460, ceilingHeight))
        case .text:
            return NSSize(width: Swift.min(620, ceilingWidth), height: Swift.min(480, ceilingHeight))
        case .scanImage, .pattern:
            // Readout, zoom controls, optional message and padding sit below the image.
            let chrome: CGFloat = 112
            // Long edge of the image pane at rest. Filling the screen for a
            // 64×64 scan would open at 11× before the user asks for anything.
            let target: CGFloat = 560
            let aspect = CGFloat(Swift.max(payload.columns, 1)) / CGFloat(Swift.max(payload.rows, 1))

            var width = aspect >= 1 ? target : target * aspect
            var height = aspect >= 1 ? target / aspect : target

            // Shrink to fit the screen, keeping the aspect.
            if width > ceilingWidth {
                height *= ceilingWidth / width
                width = ceilingWidth
            }
            if height + chrome > ceilingHeight {
                let scale = (ceilingHeight - chrome) / height
                width *= scale
                height = ceilingHeight - chrome
            }

            // Floors win over aspect: a 512×16 result should still open as a
            // usable window rather than a sliver. Fit-on-open handles the rest.
            width = Swift.max(460, width)
            height = Swift.max(200, height)

            return NSSize(width: width.rounded(), height: (height + chrome).rounded())
        }
    }

    private func show(_ payload: PluginResultPayload) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: PluginResultWindowController.initialSize(for: payload, on: nil)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = payload.title
        window.isReleasedWhenClosed = false

        // NSHostingView defaults to .standardBounds, which pushes the SwiftUI
        // view's own size limits onto the window. Clearing it keeps the window's
        // resize limits entirely ours — set explicitly just below.
        // Render once here, not inside `body`: a fresh NSImage on every SwiftUI
        // update would read as a new image downstream and reset the zoom.
        let hosting = NSHostingView(rootView: PluginResultView(payload: payload, image: payload.makeImage()))
        hosting.sizingOptions = []
        window.contentView = hosting

        // Wide enough that the zoom controls and Export button stay on one row.
        window.contentMinSize = NSSize(width: 460, height: 260)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                       height: CGFloat.greatestFiniteMagnitude)

        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        PluginResultWindowController.open.removeAll { $0 === self }
    }
}

// MARK: - Result view

struct PluginResultView: View {
    let payload: PluginResultPayload
    /// Rendered once by the window controller and held constant for the life of
    /// the window, so zoom state survives re-renders.
    let image: NSImage?

    @State private var magnification: CGFloat = 1
    // Counters rather than notifications: a result window's zoom buttons must
    // drive that window only, not every other open result.
    @State private var fitRequest: Int = 0
    @State private var actualSizeRequest: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch payload.kind {
            case .scanImage, .pattern:
                imageBody
            case .plot:
                plotBody
            case .text:
                textBody
            }

            if let message = payload.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Image

    @ViewBuilder
    private var imageBody: some View {
        if let image = image {
            // Scroll-to-pan, pinch-to-zoom, nearest-neighbour — the same
            // handling the computed-image panel gives the scan image.
            PluginZoomableImage(image: image,
                                magnification: $magnification,
                                fitRequest: $fitRequest,
                                actualSizeRequest: $actualSizeRequest)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("The result could not be rendered.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(payload.columns) × \(payload.rows) \(payload.kind == .scanImage ? "probe positions" : "detector pixels")")
                if let stats = payload.statistics {
                    Text(String(format: "min %.4g   max %.4g   mean %.4g", stats.min, stats.max, stats.mean))
                    if stats.finite < payload.values.count {
                        Text("\(payload.values.count - stats.finite) non-finite values excluded")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            zoomControls

            if payload.rgba != nil {
                Menu("Export…") {
                    Button("Data (32-bit TIFF)") { PluginResultExporter.exportFloatTIFF(payload) }
                    Button("Rendered (RGB TIFF)") { PluginResultExporter.exportRenderedTIFF(payload) }
                }
                .fixedSize()
            } else {
                Button("Export…") { PluginResultExporter.exportFloatTIFF(payload) }
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 3) {
            Button { actualSizeRequest &+= 1 } label: { Image(systemName: "1.square") }
                .help("Actual size")
            Button { fitRequest &+= 1 } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Zoom to fit")
            Button { magnification = Swift.max(0.05, magnification / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Text("\(Int((magnification * 100).rounded()))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
            Button { magnification = Swift.min(500, magnification * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    // MARK: Plot

    @ViewBuilder
    private var plotBody: some View {
        PluginPlotView(x: payload.x, y: payload.y, xLabel: payload.xLabel, yLabel: payload.yLabel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        HStack {
            Text("\(payload.y.count) points")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Export CSV…") { PluginResultExporter.exportCSV(payload) }
        }
    }

    // MARK: Text

    @ViewBuilder
    private var textBody: some View {
        ScrollView {
            Text(payload.text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        HStack {
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(payload.text, forType: .string)
            }
            Button("Export…") { PluginResultExporter.exportText(payload) }
        }
    }
}

// MARK: - Zoomable image

/// Scrollable, magnifiable image for result windows.
///
/// Built on the same `CenteringClipView` and nearest-neighbour rendering the
/// computed-image panel uses, so a plugin result pans and zooms the way the
/// scan image does. It deliberately does *not* reuse `ZoomableImageView`: that
/// one listens for the global `.zoomIn` / `.zoomOut` notifications the Image
/// menu posts, which would zoom every open result window at once, and it holds
/// its observers for the lifetime of the process. Zoom here is driven by
/// bindings, so each window is independent and nothing outlives it.
struct PluginZoomableImage: NSViewRepresentable {

    let image: NSImage
    @Binding var magnification: CGFloat
    /// Bumped to request zoom-to-fit; the value itself carries no meaning.
    @Binding var fitRequest: Int
    /// Bumped to request 1:1.
    @Binding var actualSizeRequest: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()

        let clip = CenteringClipView(frame: .zero)
        clip.drawsBackground = false
        scrollView.contentView = clip

        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 500

        scrollView.documentView = PluginImageCanvas(image: image)

        context.coordinator.observation = scrollView.observe(\.magnification, options: [.new]) { _, change in
            guard let value = change.newValue else { return }
            context.coordinator.lastSynced = value
            DispatchQueue.main.async { magnification = value }
        }
        context.coordinator.fit(scrollView)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator

        if let canvas = nsView.documentView as? PluginImageCanvas, canvas.sourceImage !== image {
            canvas.update(image: image)
            coordinator.fit(nsView)
            return
        }

        if fitRequest != coordinator.lastFitRequest {
            coordinator.lastFitRequest = fitRequest
            coordinator.fit(nsView)
            return
        }

        if actualSizeRequest != coordinator.lastActualSizeRequest {
            coordinator.lastActualSizeRequest = actualSizeRequest
            nsView.setMagnification(1.0, centeredAt: PluginZoomableImage.center(of: nsView))
            return
        }

        // Only react when the buttons moved the value; the KVO observer above
        // is what keeps the binding in step with pinch and trackpad zooming.
        if abs(magnification - coordinator.lastSynced) > 0.001 {
            let clamped = Swift.max(nsView.minMagnification, Swift.min(nsView.maxMagnification, magnification))
            nsView.setMagnification(clamped, centeredAt: PluginZoomableImage.center(of: nsView))
        }
    }

    private static func center(of scrollView: NSScrollView) -> NSPoint {
        let visible = scrollView.contentView.documentVisibleRect
        return NSPoint(x: visible.midX, y: visible.midY)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var observation: NSKeyValueObservation?
        var lastSynced: CGFloat = 1
        var lastFitRequest: Int = 0
        var lastActualSizeRequest: Int = 0

        /// Deferred: on the first pass the scroll view has no size yet, so
        /// fitting immediately would magnify to a zero rect.
        func fit(_ scrollView: NSScrollView) {
            DispatchQueue.main.async {
                guard let document = scrollView.documentView, !document.frame.isEmpty else { return }
                scrollView.layoutSubtreeIfNeeded()
                scrollView.magnify(toFit: document.frame)
            }
        }

        deinit { observation?.invalidate() }
    }
}

/// Draws the result at exact pixel boundaries — no smoothing, so a single
/// probe position stays a single square when zoomed in.
private final class PluginImageCanvas: NSView {

    private(set) var sourceImage: NSImage

    override var isFlipped: Bool { return true }

    init(image: NSImage) {
        self.sourceImage = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
        wantsLayer = true
        // String literals rather than `.nearest`, matching ZoomableImageView:
        // the app builds in Swift 4 language mode, where these are plain
        // strings. The literal is accepted in either mode.
        layer?.magnificationFilter = "nearest"
        layer?.minificationFilter = "nearest"
        layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(image: NSImage) {
        sourceImage = image
        setFrameSize(image.size)
        layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        needsDisplay = true
    }
}

// MARK: - Plot

/// Minimal line plot. Deliberately hand-drawn rather than pulling in Charts so
/// the plugin surface adds no framework dependency to the app.
struct PluginPlotView: View {
    let x: [Float]
    let y: [Float]
    let xLabel: String
    let yLabel: String

    private let inset = EdgeInsets(top: 12, leading: 56, bottom: 40, trailing: 14)

    var body: some View {
        GeometryReader { geo in
            let plotRect = CGRect(
                x: inset.leading,
                y: inset.top,
                width: max(1, geo.size.width - inset.leading - inset.trailing),
                height: max(1, geo.size.height - inset.top - inset.bottom)
            )
            let bounds = PluginPlotView.bounds(x: x, y: y)

            ZStack {
                Canvas { context, _ in
                    // Frame
                    var frame = Path()
                    frame.addRect(plotRect)
                    context.stroke(frame, with: .color(.secondary.opacity(0.5)), lineWidth: 1)

                    // Gridlines at the tick positions
                    var grid = Path()
                    for fraction in [0.25, 0.5, 0.75] {
                        let gx = plotRect.minX + plotRect.width * fraction
                        grid.move(to: CGPoint(x: gx, y: plotRect.minY))
                        grid.addLine(to: CGPoint(x: gx, y: plotRect.maxY))
                        let gy = plotRect.minY + plotRect.height * fraction
                        grid.move(to: CGPoint(x: plotRect.minX, y: gy))
                        grid.addLine(to: CGPoint(x: plotRect.maxX, y: gy))
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

                    // Series
                    guard x.count == y.count, x.count > 1 else { return }
                    var line = Path()
                    var started = false
                    for i in 0..<x.count {
                        guard x[i].isFinite, y[i].isFinite else { started = false; continue }
                        let point = CGPoint(
                            x: plotRect.minX + CGFloat((x[i] - bounds.xMin) / bounds.xSpan) * plotRect.width,
                            y: plotRect.maxY - CGFloat((y[i] - bounds.yMin) / bounds.ySpan) * plotRect.height
                        )
                        if started {
                            line.addLine(to: point)
                        } else {
                            line.move(to: point)
                            started = true
                        }
                    }
                    context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
                }

                // Tick labels and axis titles, drawn as views so they pick up
                // the system font and colour automatically.
                ForEach(0..<5) { step in
                    let fraction = Double(step) / 4.0
                    Text(PluginPlotView.format(bounds.xMin + Float(fraction) * bounds.xSpan))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .position(x: plotRect.minX + plotRect.width * fraction, y: plotRect.maxY + 12)

                    Text(PluginPlotView.format(bounds.yMin + Float(fraction) * bounds.ySpan))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: inset.leading - 8, alignment: .trailing)
                        .position(x: (inset.leading - 8) / 2, y: plotRect.maxY - plotRect.height * fraction)
                }

                if !xLabel.isEmpty {
                    Text(xLabel)
                        .font(.caption)
                        .position(x: plotRect.midX, y: plotRect.maxY + 30)
                }
                if !yLabel.isEmpty {
                    Text(yLabel)
                        .font(.caption)
                        .rotationEffect(.degrees(-90))
                        .position(x: 12, y: plotRect.midY)
                }
            }
        }
    }

    private struct Bounds {
        var xMin: Float, xSpan: Float, yMin: Float, ySpan: Float
    }

    private static func bounds(x: [Float], y: [Float]) -> Bounds {
        let finiteX = x.filter { $0.isFinite }
        let finiteY = y.filter { $0.isFinite }
        let xMin = finiteX.min() ?? 0
        let xMax = finiteX.max() ?? 1
        let yMin = finiteY.min() ?? 0
        let yMax = finiteY.max() ?? 1
        return Bounds(
            xMin: xMin,
            xSpan: (xMax - xMin) > 0 ? (xMax - xMin) : 1,
            yMin: yMin,
            ySpan: (yMax - yMin) > 0 ? (yMax - yMin) : 1
        )
    }

    private static func format(_ value: Float) -> String {
        return String(format: "%.4g", value)
    }
}

// MARK: - Export

enum PluginResultExporter {

    static func exportFloatTIFF(_ payload: PluginResultPayload) {
        guard let matrix = payload.matrix else { return }
        save(name: payload.suggestedFileName + ".tif", extensions: ["tif", "tiff"]) { url in
            guard let cgImage = matrix.floatImageRep().cgImage else { return }
            writeTIFF(cgImage, to: url)
        }
    }

    static func exportRenderedTIFF(_ payload: PluginResultPayload) {
        guard let image = payload.makeImage(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        save(name: payload.suggestedFileName + "_rgb.tif", extensions: ["tif", "tiff"]) { url in
            writeTIFF(cgImage, to: url)
        }
    }

    static func exportCSV(_ payload: PluginResultPayload) {
        let xHeader = payload.xLabel.isEmpty ? "x" : payload.xLabel
        let yHeader = payload.yLabel.isEmpty ? "y" : payload.yLabel
        var csv = "\(xHeader),\(yHeader)\n"
        for i in 0..<payload.y.count {
            let xValue = i < payload.x.count ? payload.x[i] : Float(i)
            csv += "\(xValue),\(payload.y[i])\n"
        }
        save(name: payload.suggestedFileName + ".csv", extensions: ["csv"]) { url in
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func exportText(_ payload: PluginResultPayload) {
        save(name: payload.suggestedFileName + ".txt", extensions: ["txt"]) { url in
            try? payload.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func writeTIFF(_ cgImage: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func save(name: String, extensions: [String], write: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.isExtensionHidden = false
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.nameFieldStringValue = name
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            write(url)
        }
    }
}
