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

    @State private var hovered: PixelReadout? = nil
    @State private var magnification: CGFloat = 1
    // Counters rather than notifications: a result window's zoom buttons must
    // drive that window only, not every other open result.
    @State private var fitRequest: Int = 0
    @State private var actualSizeRequest: Int = 0

    /// Visible x span of a plot result; nil shows the full extent.
    @State private var plotXRange: ClosedRange<Double>?
    @State private var plotAutoScaleY: Bool = true

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

    /// The value under the pointer, ready to show.
    ///
    /// Nil when the pointer is off the image, or when the coordinates fall
    /// outside the data — which can happen for a moment after a result is
    /// replaced by a smaller one, before the tracking area catches up.
    private var hoverDescription: String? {
        guard let readout = hovered,
              readout.x >= 0, readout.x < payload.columns,
              readout.y >= 0, readout.y < payload.rows else { return nil }
        let index = readout.y * payload.columns + readout.x
        guard index < payload.values.count else { return nil }

        let value = payload.values[index]
        let shown: String
        if !value.isFinite {
            // Worth naming rather than printing as "nan": a non-finite pixel is
            // usually a division by an empty region, and knowing which pixels
            // they are is the point of looking.
            shown = value.isNaN ? "not a number" : (value < 0 ? "−∞" : "+∞")
        } else {
            // Zero is exactly the value the range test excludes, and it is the
            // most common one in any map that has been masked or thresholded —
            // rendering it as 0.0000e+00 makes the commonest reading the least
            // readable.
            let plain = value == 0 || (abs(value) >= 1e-4 && abs(value) < 1e6)
            shown = String(format: plain ? "%.5g" : "%.4e", value)
        }
        let unit = payload.valueLabel.map { " \($0)" } ?? ""
        return String(format: "(%d, %d)  %@%@", readout.x, readout.y, shown as NSString, unit as NSString)
    }

    // MARK: Image

    @ViewBuilder
    private var imageBody: some View {
        if let image = image {
            // Scroll-to-pan, pinch-to-zoom, nearest-neighbour — the same
            // handling the computed-image panel gives the scan image.
            PluginZoomableImage(image: image,
                                magnification: $magnification,
                                hovered: $hovered,
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
                // The pointer's own reading replaces the size line while it is
                // over the image: the size does not change and can be read at
                // leisure, whereas the value under the pointer is the thing
                // being looked for and wants the steadiest place on the row.
                if let readout = hoverDescription {
                    Text(readout)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                } else {
                    Text("\(payload.columns) × \(payload.rows) \(payload.kind == .scanImage ? "probe positions" : "detector pixels")")
                }
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

            // A menu when there is a choice, a button when there is not.
            //
            // This used to key on `rgba` alone — the assumption being that a
            // result without a colour rendering had exactly one thing worth
            // exporting. Attached arrays broke that: a plain greyscale map with
            // four arrays behind it fell into the single-button branch, so the
            // HDF5 item existed and could not be reached from any result that
            // did not also happen to be coloured.
            if payload.rgba != nil || !payload.datasets.isEmpty {
                Menu("Export…") {
                    Button("Data (32-bit TIFF)") { PluginResultExporter.exportFloatTIFF(payload) }
                    if payload.rgba != nil {
                        Button("Rendered (RGB TIFF)") { PluginResultExporter.exportRenderedTIFF(payload) }
                    }
                    if !payload.datasets.isEmpty {
                        Divider()
                        Button("All Arrays (HDF5)…") { PluginResultExporter.exportHDF5(payload) }
                    }
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
        PluginPlotView(x: payload.x, y: payload.y,
                       xLabel: payload.xLabel, yLabel: payload.yLabel,
                       xRange: $plotXRange, autoScaleY: plotAutoScaleY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        HStack(spacing: 10) {
            Text(plotRangeCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Toggle("Auto Y", isOn: $plotAutoScaleY)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Rescale the vertical axis to the visible range")

            Button("Reset") { plotXRange = nil }
                .disabled(plotXRange == nil)
                .help("Show the full range")

            Button("Export CSV…") { PluginResultExporter.exportCSV(payload) }
        }
    }

    private var plotRangeCaption: String {
        guard let range = plotXRange else {
            return "\(payload.y.count) points · drag across the plot to zoom"
        }
        let visible = payload.x.filter { Double($0) >= range.lowerBound && Double($0) <= range.upperBound }
        return String(format: "%d of %d points · x %.4g to %.4g",
                      visible.count, payload.y.count, range.lowerBound, range.upperBound)
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
/// Which pixel the pointer is over, in image coordinates.
struct PixelReadout: Equatable {
    var x: Int
    var y: Int
}

struct PluginZoomableImage: NSViewRepresentable {

    let image: NSImage
    /// Markings drawn over the image as geometry, so they stay crisp at every
    /// magnification instead of being one data pixel wide for ever.
    var overlay: [PluginOverlayShape] = []
    @Binding var magnification: CGFloat
    /// The pixel under the pointer, or nil when it is not over the image.
    ///
    /// Optional so the two callers that do not want a readout — and any future
    /// one — pay nothing for it.
    var hovered: Binding<PixelReadout?>? = nil
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

        let canvas = PluginImageCanvas(image: image)
        canvas.overlay = overlay
        // The canvas is flipped and its frame is the image's pixel size, so a
        // point converted into it *is* a pixel coordinate — no scaling by the
        // magnification, no flipping of y, nothing to get wrong when the view is
        // zoomed or scrolled.
        canvas.onHover = { point in
            guard let hovered = hovered else { return }
            let readout = point.map { PixelReadout(x: Int(floor($0.x)), y: Int(floor($0.y))) }
            if hovered.wrappedValue != readout { hovered.wrappedValue = readout }
        }
        scrollView.documentView = canvas

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

        if let canvas = nsView.documentView as? PluginImageCanvas {
            // Rebound every update: the closure captures the binding, and a
            // stale one would report into a view that has been replaced.
            canvas.onHover = { point in
                guard let hovered = hovered else { return }
                let readout = point.map { PixelReadout(x: Int(floor($0.x)), y: Int(floor($0.y))) }
                if hovered.wrappedValue != readout { hovered.wrappedValue = readout }
            }
        }
        if let canvas = nsView.documentView as? PluginImageCanvas {
            canvas.overlay = overlay
        }
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
/// A transparent view that draws a plugin's markings above the image.
///
/// Separate from the canvas because the canvas shows its image through
/// `layer.contents`, which AppKit replaces with the results of `draw(_:)` on a
/// layer-backed view. It also refuses hit-testing, so the canvas underneath
/// keeps receiving the mouse movements the pixel readout depends on.
private final class PluginOverlayView: NSView {

    var shapes: [PluginOverlayShape] = []

    override var isFlipped: Bool { return true }
    override func hitTest(_ point: NSPoint) -> NSView? { return nil }
    override var isOpaque: Bool { return false }

    override func draw(_ dirtyRect: NSRect) {
        guard !shapes.isEmpty,
              let context = NSGraphicsContext.current?.cgContext else { return }
        // The view is flipped and its bounds are the image's pixel size, so the
        // context is already in image-pixel coordinates. What has to be
        // recovered is how many points on screen one image pixel is worth, which
        // is what keeps line widths and type constant at every magnification.
        let scale = convert(NSSize(width: 1, height: 1), to: nil).width
        PluginOverlayRenderer.draw(shapes, in: context, scale: max(scale, 0.0001))
    }
}

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

        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        overlayView.isHidden = true
        addSubview(overlayView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Called with the pixel under the pointer, or nil when it leaves.
    var onHover: ((CGPoint?) -> Void)?

    /// Geometry drawn above the image, in image-pixel coordinates.
    ///
    /// Drawn by a subview rather than by this one. The image arrives as
    /// `layer.contents`, and a layer-backed view that implements `draw(_:)` has
    /// its drawing rendered *into* those contents — so adding a draw method here
    /// to paint the overlay silently erased the image it was meant to annotate.
    /// A transparent sibling on top composites instead of replacing.
    var overlay: [PluginOverlayShape] = [] {
        didSet {
            overlayView.shapes = overlay
            overlayView.isHidden = overlay.isEmpty
            overlayView.needsDisplay = true
        }
    }

    private let overlayView = PluginOverlayView()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // `.inVisibleRect` keeps the area correct as the view is zoomed and
        // scrolled without rebuilding it on every change.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func report(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= 0, point.y >= 0,
              point.x < bounds.width, point.y < bounds.height else {
            onHover?(nil)
            return
        }
        onHover?(point)
    }

    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseDragged(with event: NSEvent) { report(event) }
    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    func update(image: NSImage) {
        sourceImage = image
        setFrameSize(image.size)
        overlayView.frame = bounds
        overlayView.needsDisplay = true
        layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        needsDisplay = true
    }
}


/// x-axis zoom arithmetic, kept out of the view so its edge cases can be
/// checked directly: a minimum usable span, panning that must not change width
/// when it hits an end stop, and a selection covering everything collapsing
/// back to "no zoom".
struct PlotXZoom {

    /// Smallest zoom, as a fraction of the full extent.
    static let minimumSpanFraction = 1.0 / 5000.0

    /// Takes loose bounds rather than a `ClosedRange`: a range traps on
    /// construction when its bounds are the wrong way round, which would put the
    /// crash at the call site, before any normalisation could run.
    /// Returns nil when the result is the full extent — i.e. not zoomed.
    static func clamped(low requestedLow: Double,
                        high requestedHigh: Double,
                        full: ClosedRange<Double>,
                        preserveSpan: Bool = false) -> ClosedRange<Double>? {

        let fullSpan = full.upperBound - full.lowerBound
        guard fullSpan > 0, requestedLow.isFinite, requestedHigh.isFinite else { return nil }

        var low = Swift.min(requestedLow, requestedHigh)
        var high = Swift.max(requestedLow, requestedHigh)

        let minimumSpan = fullSpan * minimumSpanFraction
        if high - low < minimumSpan {
            let centre = (low + high) / 2
            low = centre - minimumSpan / 2
            high = centre + minimumSpan / 2
        }

        if preserveSpan {
            // Panning: slide against the end stop rather than squashing.
            let span = Swift.min(high - low, fullSpan)
            if low < full.lowerBound { low = full.lowerBound; high = low + span }
            if high > full.upperBound { high = full.upperBound; low = high - span }
        }
        low = Swift.max(low, full.lowerBound)
        high = Swift.min(high, full.upperBound)

        guard high > low else { return nil }
        if low <= full.lowerBound && high >= full.upperBound { return nil }
        return low...high
    }
}

// MARK: - Plot

/// Minimal line plot with x-axis zooming. Deliberately hand-drawn rather than
/// pulling in Charts so the plugin surface adds no framework dependency.
///
/// Drag across the plot to zoom into a span, pinch to zoom about the centre,
/// scroll to pan once zoomed, double-click to reset. Hovering reads out the
/// nearest point, which is how you get a number off a histogram peak.
struct PluginPlotView: View {

    let x: [Float]
    let y: [Float]
    let xLabel: String
    let yLabel: String
    @Binding var xRange: ClosedRange<Double>?
    let autoScaleY: Bool

    @State private var dragStartX: CGFloat?
    @State private var dragCurrentX: CGFloat?
    @State private var pinchBaseRange: ClosedRange<Double>?
    @State private var hoverIndex: Int?

    private let inset = EdgeInsets(top: 12, leading: 62, bottom: 44, trailing: 16)

    var body: some View {
        GeometryReader { geo in
            let plotRect = CGRect(
                x: inset.leading,
                y: inset.top,
                width: Swift.max(1, geo.size.width - inset.leading - inset.trailing),
                height: Swift.max(1, geo.size.height - inset.top - inset.bottom)
            )
            let bounds = self.bounds()

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    draw(in: &context, plotRect: plotRect, bounds: bounds)
                }

                axisLabels(plotRect: plotRect, bounds: bounds)

                if let index = hoverIndex, index < x.count {
                    crosshair(index: index, plotRect: plotRect, bounds: bounds)
                }

                // Transparent hit area on top, so gestures work anywhere over
                // the plot without the Canvas having to handle them.
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverIndex = plotRect.contains(location)
                                ? nearestIndex(toViewX: location.x, plotRect: plotRect, bounds: bounds)
                                : nil
                        case .ended:
                            hoverIndex = nil
                        }
                    }
                    .onTapGesture(count: 2) { xRange = nil }
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { value in
                                if dragStartX == nil { dragStartX = value.startLocation.x }
                                dragCurrentX = value.location.x
                            }
                            .onEnded { value in
                                let start = dragStartX
                                dragStartX = nil
                                dragCurrentX = nil
                                guard let start = start else { return }
                                let lowX = Swift.min(start, value.location.x)
                                let highX = Swift.max(start, value.location.x)
                                // Too small to be a deliberate selection.
                                guard highX - lowX > 6 else { return }
                                let low = dataX(fromView: lowX, plotRect: plotRect, bounds: bounds)
                                let high = dataX(fromView: highX, plotRect: plotRect, bounds: bounds)
                                xRange = clamped(low: low, high: high)
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let base = pinchBaseRange ?? (bounds.xMin...bounds.xMax)
                                if pinchBaseRange == nil { pinchBaseRange = base }
                                let centre = (base.lowerBound + base.upperBound) / 2
                                let half = (base.upperBound - base.lowerBound) / 2 / Swift.max(0.05, Double(value))
                                xRange = clamped(low: centre - half, high: centre + half)
                            }
                            .onEnded { _ in pinchBaseRange = nil }
                    )
                    .overlay(PlotScrollReceiver { delta in
                        guard xRange != nil else { return }   // nothing to pan when fully zoomed out
                        let span = bounds.xMax - bounds.xMin
                        let shift = -Double(delta) * span / Double(plotRect.width)
                        xRange = clamped(low: bounds.xMin + shift, high: bounds.xMax + shift, preserveSpan: true)
                    })

                if let start = dragStartX, let current = dragCurrentX {
                    let low = Swift.min(start, current)
                    let width = abs(current - start)
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(Rectangle().stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
                        .frame(width: width, height: plotRect.height)
                        .position(x: low + width / 2, y: plotRect.midY)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, plotRect: CGRect, bounds: Bounds) {
        var frame = Path()
        frame.addRect(plotRect)
        context.stroke(frame, with: .color(.secondary.opacity(0.5)), lineWidth: 1)

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

        guard x.count == y.count, x.count > 1 else { return }

        // Clip to the plot so a zoomed range cannot draw over the axes.
        context.clip(to: Path(plotRect))

        var line = Path()
        var started = false
        for i in 0..<x.count {
            guard x[i].isFinite, y[i].isFinite else { started = false; continue }
            let point = viewPoint(index: i, plotRect: plotRect, bounds: bounds)
            // One point either side of the visible span keeps the line running
            // to the edges instead of stopping short.
            guard point.x >= plotRect.minX - plotRect.width, point.x <= plotRect.maxX + plotRect.width else {
                started = false
                continue
            }
            if started {
                line.addLine(to: point)
            } else {
                line.move(to: point)
                started = true
            }
        }
        context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
    }

    @ViewBuilder
    private func axisLabels(plotRect: CGRect, bounds: Bounds) -> some View {
        ForEach(0..<5) { step in
            let fraction = Double(step) / 4.0
            Text(PluginPlotView.format(bounds.xMin + fraction * (bounds.xMax - bounds.xMin)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .position(x: plotRect.minX + plotRect.width * fraction, y: plotRect.maxY + 12)

            Text(PluginPlotView.format(bounds.yMin + fraction * (bounds.yMax - bounds.yMin)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: inset.leading - 8, alignment: .trailing)
                .position(x: (inset.leading - 8) / 2, y: plotRect.maxY - plotRect.height * fraction)
        }

        if !xLabel.isEmpty {
            Text(xLabel)
                .font(.caption)
                .position(x: plotRect.midX, y: plotRect.maxY + 32)
        }
        if !yLabel.isEmpty {
            Text(yLabel)
                .font(.caption)
                .rotationEffect(.degrees(-90))
                .position(x: 13, y: plotRect.midY)
        }
    }

    @ViewBuilder
    private func crosshair(index: Int, plotRect: CGRect, bounds: Bounds) -> some View {
        let point = viewPoint(index: index, plotRect: plotRect, bounds: bounds)
        if plotRect.contains(CGPoint(x: point.x, y: plotRect.midY)) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.45))
                .frame(width: 1, height: plotRect.height)
                .position(x: point.x, y: plotRect.midY)
                .allowsHitTesting(false)

            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
                .position(point)
                .allowsHitTesting(false)

            Text(String(format: "%@ = %.5g,  %@ = %.5g",
                        xLabel.isEmpty ? "x" : xLabel, x[index],
                        yLabel.isEmpty ? "y" : yLabel, y[index]))
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
                // Flip to the left of the crosshair near the right edge.
                .position(x: Swift.min(Swift.max(point.x + 78, plotRect.minX + 78), plotRect.maxX - 4),
                          y: plotRect.minY + 12)
                .allowsHitTesting(false)
        }
    }

    // MARK: Geometry

    private struct Bounds {
        var xMin: Double, xMax: Double, yMin: Double, yMax: Double
    }

    private var fullXExtent: ClosedRange<Double> {
        let finite = x.filter { $0.isFinite }
        let low = Double(finite.min() ?? 0)
        let high = Double(finite.max() ?? 1)
        return high > low ? low...high : low...(low + 1)
    }

    private func bounds() -> Bounds {
        let visible = xRange ?? fullXExtent
        let xMin = visible.lowerBound
        let xMax = visible.upperBound > visible.lowerBound ? visible.upperBound : visible.lowerBound + 1

        var yLow = Double.greatestFiniteMagnitude
        var yHigh = -Double.greatestFiniteMagnitude
        var sawAny = false

        for i in 0..<Swift.min(x.count, y.count) {
            guard y[i].isFinite, x[i].isFinite else { continue }
            if autoScaleY {
                let value = Double(x[i])
                guard value >= xMin, value <= xMax else { continue }
            }
            yLow = Swift.min(yLow, Double(y[i]))
            yHigh = Swift.max(yHigh, Double(y[i]))
            sawAny = true
        }
        if !sawAny { yLow = 0; yHigh = 1 }

        // Counts and other non-negative series read correctly only when the
        // baseline is zero; series that go negative keep their own minimum.
        if yLow >= 0 { yLow = 0 }
        if yHigh <= yLow { yHigh = yLow + 1 }

        return Bounds(xMin: xMin, xMax: xMax, yMin: yLow, yMax: yHigh)
    }

    private func viewPoint(index: Int, plotRect: CGRect, bounds: Bounds) -> CGPoint {
        let spanX = bounds.xMax - bounds.xMin
        let spanY = bounds.yMax - bounds.yMin
        return CGPoint(
            x: plotRect.minX + CGFloat((Double(x[index]) - bounds.xMin) / spanX) * plotRect.width,
            y: plotRect.maxY - CGFloat((Double(y[index]) - bounds.yMin) / spanY) * plotRect.height
        )
    }

    private func dataX(fromView viewX: CGFloat, plotRect: CGRect, bounds: Bounds) -> Double {
        let fraction = Double((viewX - plotRect.minX) / plotRect.width)
        return bounds.xMin + fraction * (bounds.xMax - bounds.xMin)
    }

    private func nearestIndex(toViewX viewX: CGFloat, plotRect: CGRect, bounds: Bounds) -> Int? {
        let target = dataX(fromView: viewX, plotRect: plotRect, bounds: bounds)
        var best: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for i in 0..<Swift.min(x.count, y.count) {
            guard x[i].isFinite, y[i].isFinite else { continue }
            let value = Double(x[i])
            guard value >= bounds.xMin, value <= bounds.xMax else { continue }
            let distance = abs(value - target)
            if distance < bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

    private func clamped(low: Double, high: Double, preserveSpan: Bool = false) -> ClosedRange<Double>? {
        return PlotXZoom.clamped(low: low, high: high, full: fullXExtent, preserveSpan: preserveSpan)
    }

    private static func format(_ value: Double) -> String {
        return String(format: "%.4g", value)
    }
}

/// Forwards scroll-wheel deltas without swallowing clicks or drags.
private struct PlotScrollReceiver: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollCatcher { return ScrollCatcher() }

    func updateNSView(_ nsView: ScrollCatcher, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollCatcher: NSView {
        var onScroll: ((CGFloat) -> Void)?

        // Claim the hit test only for scroll events; everything else falls
        // through to the SwiftUI gestures underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            return NSApp.currentEvent?.type == .scrollWheel ? self : nil
        }

        override func scrollWheel(with event: NSEvent) {
            let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            onScroll?(delta)
        }
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

    /// The displayed image with its markings drawn on, enlarged enough that the
    /// markings survive.
    ///
    /// The data is enlarged nearest-neighbour — every output pixel is exactly
    /// one measured pixel — and the geometry is drawn over it at the output
    /// resolution. A 128-pixel pattern exported at its own size would render
    /// every annotation as a single pixel, which is what made the old
    /// pixel-poked overlays useless in a figure.
    static func renderedImage(_ payload: PluginResultPayload) -> CGImage? {
        guard let base = payload.makeImage()?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard !payload.overlayShapes.isEmpty else { return base }
        let scale = PluginOverlayRenderer.exportScale(for: base)
        return PluginOverlayRenderer.rendered(image: base, shapes: payload.overlayShapes,
                                              scale: scale) ?? base
    }

    static func exportRenderedTIFF(_ payload: PluginResultPayload) {
        guard let image = payload.makeImage(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        save(name: payload.suggestedFileName + "_rgb.tif", extensions: ["tif", "tiff"]) { url in
            writeTIFF(cgImage, to: url)
        }
    }

    /// Writes the plugin's attached arrays as one HDF5 file.
    ///
    /// The plugin supplies the arrays and the provenance; the file layout, the
    /// save panel and the writing are the host's, because a plugin has neither a
    /// panel nor — in a sandboxed application — permission to write anywhere the
    /// user has not just chosen.
    ///
    /// Provenance goes in as a JSON string, in an attribute *and* a dataset. The
    /// attribute is what `h5py` reads as `f.attrs["provenance"]` and what
    /// `h5dump -A` shows without being asked; the dataset is what survives tools
    /// that copy data and drop attributes. It is the same text both times.
    static func exportHDF5(_ payload: PluginResultPayload) {
        guard !payload.datasets.isEmpty else { return }

        let panel = NSSavePanel()
        let ext = payload.exportExtension ?? "h5"
        let stem = payload.pluginName
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        panel.nameFieldStringValue = "\(payload.fileRoot)_\(stem).\(ext)"
        panel.canCreateDirectories = true
        panel.message = "Save the measured arrays and how they were produced"
        // A custom extension has no registered content type, and demanding one
        // would stop the panel accepting the name it just suggested.
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try writeHDF5(payload, to: url)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not write \(url.lastPathComponent)"
            alert.informativeText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    enum HDF5ExportError: LocalizedError {
        case couldNotCreate(String)
        case couldNotWrite(String)

        var errorDescription: String? {
            switch self {
            case .couldNotCreate(let name):
                return "\(name) could not be created. Check that the folder is writable."
            case .couldNotWrite(let name):
                return "\(name) could not be written."
            }
        }
    }

    static func writeHDF5(_ payload: PluginResultPayload, to url: URL) throws {
        // Truncating: the panel has already asked about replacing.
        guard let file = HDF5File.create(url.path, mode: .truncate) else {
            throw HDF5ExportError.couldNotCreate(url.lastPathComponent)
        }

        var groups: [String: HDF5Group] = [:]
        /// Resolves `a/b/name` to the group `a/b`, creating each level once.
        ///
        /// `createGroup` lives on the concrete types rather than on
        /// `HDF5GroupType`, which carries only the identifier, so the walk has
        /// to know which of the two it is holding.
        func container(for path: String) -> HDF5GroupType {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count > 1 else { return file }
            var walked: [String] = []
            var current: HDF5GroupType = file
            for part in parts.dropLast() {
                walked.append(part)
                let key = walked.joined(separator: "/")
                if let existing = groups[key] {
                    current = existing
                    continue
                }
                let made: HDF5Group
                if let asFile = current as? HDF5File {
                    made = asFile.createGroup(part)
                } else if let asGroup = current as? HDF5Group {
                    made = asGroup.createGroup(part)
                } else {
                    return file
                }
                groups[key] = made
                current = made
            }
            return current
        }

        for dataset in payload.datasets {
            let leaf = dataset.name.split(separator: "/").map(String.init).last ?? dataset.name
            let parent = container(for: dataset.name)
            // Rows then columns, which is the order numpy will read the shape
            // in — `(rows, columns)` indexes as `[y, x]`, matching the values.
            guard (try? parent.createAndWriteDataset(
                leaf, dims: [dataset.rows, dataset.columns], data: dataset.values)) != nil else {
                throw HDF5ExportError.couldNotWrite(dataset.name)
            }
        }

        // Units and per-array notes go into the provenance rather than onto the
        // datasets. Attributes attach to identifiers, and `createStringAttribute`
        // is offered on groups and the file but not on datasets — and the units
        // are processing information, which is what the JSON is for. One place
        // to look beats two.
        var provenance = payload.provenance
        if !payload.datasets.isEmpty {
            provenance["datasets"] = payload.datasets.map { dataset -> [String: Any] in
                var entry: [String: Any] = ["name": dataset.name,
                                            "shape": [dataset.rows, dataset.columns]]
                if let units = dataset.units { entry["units"] = units }
                if let note = dataset.note { entry["description"] = note }
                return entry
            }
        }
        provenance["written_by"] = "4DSTEM Explorer"
        provenance["written_at"] = ISO8601DateFormatter().string(from: Date())

        if JSONSerialization.isValidJSONObject(provenance),
           // Without the slash escaping: a dataset path is the commonest thing
           // in here, and `binned\/tilt_x` is valid JSON that reads as a typo to
           // anyone opening the file with h5dump.
           let data = try? JSONSerialization.data(withJSONObject: provenance,
                                                  options: [.prettyPrinted, .sortedKeys,
                                                            .withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            // Both an attribute and a dataset, deliberately. The attribute is
            // what `h5py` reads as `f.attrs["provenance"]` and what `h5dump -A`
            // shows unasked; the dataset is what survives tools that copy data
            // and drop attributes. Same text either way.
            if let attribute = file.createStringAttribute("provenance") {
                try? attribute.write(text)
            }
            let dataspace = HDF5Dataspace(dims: [1])
            if let dataset = file.createStringDataset("provenance", dataspace: dataspace) {
                try? dataset.write([text])
            }
        }

        file.flush()
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

    /// The batch runner writes to paths it chose itself, with no panel.
    static func writeTIFFPublic(_ cgImage: CGImage, to url: URL) {
        writeTIFF(cgImage, to: url)
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
