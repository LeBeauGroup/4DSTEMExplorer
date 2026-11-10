import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers

final class OpenPanelController: ObservableObject {
    /// Allowed content types for the open panel. Default is any type.
    var allowedContentTypes: [UTType] = [.item]
    
//    @MainActor
//    func open() {
//        let panel = NSOpenPanel()
//        panel.allowsMultipleSelection = false
//        panel.canChooseDirectories = false
//        panel.allowedFileTypes = ["dm4", "mrc", "tiff", "tif", "raw"]
//        panel.begin { _ in }
//    }
    
    @MainActor
    func open(onSelect: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Use modern API: allowedContentTypes instead of deprecated allowedFileTypes
        panel.allowedContentTypes = [
            UTType(filenameExtension: "dm4") ?? .data,
            UTType(filenameExtension: "mrc") ?? .data,
            UTType.tiff,
            UTType(filenameExtension: "tif") ?? .tiff,
            UTType(filenameExtension: "raw") ?? .data,
            UTType(filenameExtension: "emd") ?? .data,
            UTType(filenameExtension: "h5") ?? .data,
            UTType(filenameExtension: "hdf5") ?? .data
        ]
        panel.begin { resp in
            if resp == .OK, let url = panel.url {
                onSelect(url)
            }
        }
    }
}
/// Hands back the window hosting this view. A nested open panel has to be
/// attached to it as a sheet: the RAW dimensions panel is itself presented as a
/// sheet, and on the fallback path inside a modal session, where a free-floating
/// panel would never receive events.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Everything the RAW panel settles before the file can be read.
///
/// Gathered into a type rather than handed back as a row of unlabelled
/// arguments. There are eight of them now, two are rasters and three are
/// booleans, and at that width a positional callback is one transposed pair away
/// from reading a scan in the wrong orientation with nothing to show for it.
struct RawOpenChoice {
    var scanWidth: Int
    var scanHeight: Int
    /// The calibration fields as typed. "None", or anything else that is not a
    /// number, means the calibration was not given.
    var scanStep: String
    var diffStep: String
    var voltage: String
    var flips: DetectorFlips
    var scanPath: ScanPath
    /// What "Load Metadata…" read, when it was used.
    var metadata: ScanMetadata?
}

/// The scan-path choices as the picker sees them.
///
/// Separate from `ScanPath` because a picker needs a stable, hashable tag for
/// each row, and the explicit case carries an order that changes as files are
/// chosen — tagging rows with the value itself would reset the selection every
/// time the order did.
enum ScanPathKind: Hashable, CaseIterable, Identifiable {
    /// Worked out from the acquisition's own metadata. First, because when it
    /// is available it is the answer — and it is the row the panel selects
    /// itself, so it reads better at the top than buried under four orders the
    /// scan is known not to be.
    case computed
    case raster
    case snake
    case columnRaster
    case columnSnake
    case custom

    var id: Self { self }

    /// Short enough for a menu; the explanation is in the footnote below it.
    var title: String {
        switch self {
        case .computed:     return "From the acquisition metadata"
        case .raster:       return "Raster — row by row"
        case .snake:        return "Snake — alternate rows reversed"
        case .columnRaster: return "Raster — column by column"
        case .columnSnake:  return "Snake — alternate columns reversed"
        case .custom:       return "From a positions file\u{2026}"
        }
    }

    init(_ path: ScanPath) {
        switch path {
        case .raster:       self = .raster
        case .snake:        self = .snake
        case .columnRaster: self = .columnRaster
        case .columnSnake:  self = .columnSnake
        case .explicit:     self = .custom
        }
    }

    /// The path this row means, for every row but the two that have no meaning
    /// until something has been read.
    var namedPath: ScanPath? {
        switch self {
        case .raster:       return .raster
        case .snake:        return .snake
        case .columnRaster: return .columnRaster
        case .columnSnake:  return .columnSnake
        case .computed:     return nil
        case .custom:       return nil
        }
    }
}

struct RawDimsSheet: View {
    @State var scan_dims: String
    @State var diff_step: String
    @State var scan_step: String
    @State var voltage: String = "None"
    @State var flipRows: Bool = true
    @State var flipCols: Bool = false
    @State var transpose: Bool = false

    @State var isCalibrationVisible: Bool = false
    @State private var metadataNote: String?
    @State private var metadataFailed: Bool = false
    /// What "Load Metadata…" read, kept so the export can be based on it and
    /// named after it rather than after the raster.
    @State private var importedMetadata: ScanMetadata?
    @State private var hostWindow: NSWindow?

    @State private var pathKind: ScanPathKind = .raster
    /// The chosen positions file, held unresolved: it is only a placement once
    /// there is a raster to check it against, and although the file can usually
    /// supply that raster itself, the user is free to disagree with it.
    @State private var positions: ScanPositions?
    /// The path read out of the acquisition's own metadata, when it holds one.
    /// Also held unresolved, for the same reason as `positions`.
    @State private var computed: MacSTEMScanPath?
    @State private var pathNote: String?
    @State private var pathFailed: Bool = false
    /// Whether the metadata beside the RAW file has been looked for yet. The
    /// panel's body is rebuilt often and the look is a file read.
    @State private var lookedBeside: Bool = false

    let fileHint: String
    /// The RAW file being opened. Only used to start the metadata panel in the
    /// right folder — the sidecar is written next to the data far more often
    /// than not, so anywhere else is a wasted navigation.
    var fileURL: URL? = nil
    let onCancel: () -> Void
    let onOK: (RawOpenChoice) -> Void

    /// Reads "80x80" and the several things people type when they mean it.
    ///
    /// Lives here, on the panel that owns the field, and is used by the caller
    /// too. It was the caller's own private function, which meant the panel
    /// could not tell whether what had been typed was a raster — and a scan
    /// path cannot be checked without knowing that.
    static func parseScanDimensions(_ text: String) -> (width: Int, height: Int)? {
        // Normalise: trim, lowercase, unify separators, tolerate spaces.
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for sign in ["\u{00D7}", "\u{2715}", "\u{2716}", "\u{2717}"] {
            s = s.replacingOccurrences(of: sign, with: "x")
        }
        s = s.replacingOccurrences(of: "pixels", with: "")
        s = s.replacingOccurrences(of: "px", with: "")

        let patterns = [
            #"^\s*(\d+)\s*[x*]\s*(\d+)\s*$"#,   // 80x80, 80*80, 80 x 80
            #"^\s*(\d+)\s+(\d+)\s*$"#            // 80 80
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let ns = s as NSString
            guard let m = regex.firstMatch(in: s, options: [],
                                           range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges >= 3,
                  let r1 = Range(m.range(at: 1), in: s),
                  let r2 = Range(m.range(at: 2), in: s),
                  let w = Int(s[r1]), let h = Int(s[r2]), w > 0, h > 0 else { continue }
            return (w, h)
        }
        return nil
    }

    /// The path the panel currently describes, or why it does not describe one.
    ///
    /// A named order is always valid. An explicit one is valid only against a
    /// raster, so this is the single place the two are brought together — both
    /// for the note under the picker and for the OK button, which must not
    /// start a read with a path that cannot place every frame.
    private func resolvedPath() -> Result<ScanPath, Error> {
        if let named = pathKind.namedPath { return .success(named) }
        if pathKind == .computed {
            guard let computed = computed else {
                return .failure(MacSTEMScanPath.Failure.notRead)
            }
            guard let dims = Self.parseScanDimensions(scan_dims) else {
                return .failure(ScanPath.Failure.noRaster)
            }
            do {
                return .success(.explicit(try computed.placement(width: dims.width,
                                                                 height: dims.height)))
            } catch {
                return .failure(error)
            }
        }
        guard let positions = positions else {
            return .failure(ScanPath.Failure.noPositions("No positions file"))
        }
        guard let dims = Self.parseScanDimensions(scan_dims) else {
            return .failure(ScanPath.Failure.noRaster)
        }
        do {
            return .success(.explicit(try positions.placement(width: dims.width,
                                                              height: dims.height)))
        } catch {
            return .failure(error)
        }
    }

    /// Restates the note under the picker from the current file and raster.
    private func refreshPathNote() {
        guard pathKind == .custom || pathKind == .computed else {
            pathNote = nil
            pathFailed = false
            return
        }

        var lines: [String] = []
        var worrying = false

        if pathKind == .computed {
            guard let computed = computed else {
                pathNote = MacSTEMScanPath.Failure.notRead.errorDescription
                pathFailed = false
                return
            }
            // Said plainly, because a recomputed order is a claim about the
            // data rather than a reading of it: what was computed, from what,
            // and over how many frames.
            lines.append("\(computed.name), computed from \(computed.source)"
                         + " \u{2014} \(computed.canvas)\u{00D7}\(computed.canvas) scan,"
                         + " \(computed.keptWidth * computed.keptHeight) frames")
            if computed.settle > 0 {
                lines.append("\(computed.settle) settling frame"
                             + "\(computed.settle == 1 ? "" : "s") before the path")
            }
        } else {
            guard let positions = positions else {
                pathNote = "Choose the scan_positions.npz written alongside the scan."
                pathFailed = false
                return
            }

            // The file's own name for the pattern, which is the one thing here
            // the arrays cannot say. `hilbert` is not a placement, but it is
            // what the user called the scan, so it is what the panel should
            // call it too.
            if let pattern = positions.pattern {
                lines.append("\(positions.label): \(pattern), \(positions.frameCount) frames")
            } else {
                lines.append("\(positions.label): \(positions.frameCount) frames")
            }

            // The positions file names the raw file it belongs to. When that is
            // not the file being opened, say so — a positions file paired with
            // the wrong scan is the one mistake here that yields a complete,
            // plausible and entirely wrong image. Not refused, because
            // acquisition and the user do rename things, but not passed over in
            // silence either.
            if let named = positions.rawFile, let opening = fileURL?.lastPathComponent,
               named.lowercased() != opening.lowercased() {
                lines.append("\u{26A0}\u{FE0E} written for \(named), not \(opening)")
                worrying = true
            }
        }

        switch resolvedPath() {
        case .success(let path):
            if case .explicit(let placement) = path {
                if placement.frameCount != placement.placedCount {
                    lines.append("\(placement.placedCount) at a scan position")
                }
                if placement.unfilled > 0 {
                    lines.append("\(placement.unfilled) scan position"
                                 + "\(placement.unfilled == 1 ? "" : "s") left empty")
                }
            }
        case .failure(let error):
            lines.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            worrying = true
        }
        pathFailed = worrying
        pathNote = lines.joined(separator: ". ")
    }

    /// Reads the scan positions written alongside the scan.
    private func loadScanPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // npz is what acquisition writes; npy is the same array format without
        // the archive around it, and costs nothing to accept.
        panel.allowedContentTypes = ["npz", "npy"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.prompt = "Load"
        panel.message = "Choose the scan positions written alongside this RAW file — the .npz holding an x and a y for every frame, in acquisition order"

        func adopt(_ response: NSApplication.ModalResponse) {
            guard response == .OK, let url = panel.url else { return }
            do {
                let read = try ScanPositions.read(contentsOf: url)
                positions = read
                // The file knows the raster and the step. Filling them in is
                // the point of reading it: both are already in the file, and
                // retyping either is a chance to get it wrong.
                if let raster = read.inferredRaster(),
                   Self.parseScanDimensions(scan_dims).map({ $0 != raster }) ?? true {
                    scan_dims = "\(raster.width)x\(raster.height)"
                }
                if Float(scan_step) == nil, let step = read.inferredScanStepNanometres() {
                    scan_step = String(format: "%g", step)
                    isCalibrationVisible = true
                }
                refreshPathNote()
                followContentSize()
            } catch {
                positions = nil
                pathFailed = true
                pathNote = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                followContentSize()
            }
        }

        if let window = hostWindow {
            panel.beginSheetModal(for: window, completionHandler: adopt)
        } else {
            adopt(panel.runModal())
        }
    }

    /// Fills the fields in from a JSON sidecar, so the numbers come from the
    /// acquisition rather than from retyping them.
    private func loadMetadata() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Both formats are read; the content is sniffed rather than trusted to
        // the extension, so a mislabelled file still works.
        panel.allowedContentTypes = ScanMetadata.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.prompt = "Load"
        panel.message = "Choose the JSON, XML or TOML metadata written alongside this RAW file"

        func chosen(_ response: NSApplication.ModalResponse) {
            guard response == .OK, let url = panel.url else { return }
            do {
                adopt(try ScanMetadata.read(url: url), foundAutomatically: false)
                followContentSize()
            } catch {
                metadataFailed = true
                metadataNote = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                importedMetadata = nil
                followContentSize()
            }
        }

        if let window = hostWindow {
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            chosen(panel.runModal())
        }
    }

    /// Takes everything a metadata file says into the panel.
    ///
    /// Shared by the button and by the look beside the RAW file, so a sidecar
    /// that was found is read exactly as one that was chosen.
    private func adopt(_ metadata: ScanMetadata, foundAutomatically: Bool) {
        if let w = metadata.scanWidth, let h = metadata.scanHeight { scan_dims = "\(w)x\(h)" }
        if let step = metadata.scanStepNanometres { scan_step = trimmed(step) }
        if let step = metadata.diffractionStepMilliradians { diff_step = trimmed(step) }
        if let volts = metadata.voltageKilovolts { voltage = trimmed(volts) }

        // A path the metadata is enough to reproduce is the point of this:
        // nothing has to be chosen, and nothing has to have been saved beside
        // the data either. Otherwise, only when the file names an order —
        // silence about the scan path says nothing about it, so whatever is in
        // the picker, which may have been set deliberately, stands.
        if let path = metadata.macSTEMScanPath {
            computed = path
            pathKind = .computed
        } else if let path = metadata.scanPath {
            pathKind = ScanPathKind(path)
        }

        var note = metadata.summary
        if foundAutomatically, let name = metadata.sourceURL?.lastPathComponent {
            note = "Found \(name) \u{2014} " + note
        }
        // Why a pattern the file names could not be reproduced belongs here
        // rather than nowhere: it is what says which file to load instead.
        metadataFailed = metadata.macSTEMScanPathNote != nil
        if let unresolved = metadata.macSTEMScanPathNote {
            note += ". " + unresolved
        }
        metadataNote = note
        importedMetadata = metadata
        // Show what was filled in, rather than leaving it collapsed and
        // apparently unchanged.
        isCalibrationVisible = true
        refreshPathNote()
    }

    /// Looks for the acquisition's own metadata beside the RAW file.
    ///
    /// macSTEM writes `metadata.toml` into the acquisition folder, next to the
    /// data, so for its scans there is nothing to go and find — and for a path
    /// scan there is nothing to choose either, because the order is in that
    /// file. Taken only when it reads and holds something; a failure is not
    /// reported, since nothing was asked for.
    private func adoptMetadataBesideFile() {
        guard !lookedBeside else { return }
        lookedBeside = true
        guard let sidecar = fileURL?.deletingLastPathComponent()
                .appendingPathComponent("metadata.toml"),
              FileManager.default.fileExists(atPath: sidecar.path),
              let metadata = try? ScanMetadata.read(url: sidecar) else { return }
        adopt(metadata, foundAutomatically: true)
        followContentSize()
    }

    /// How long the panel takes to grow or shrink. Shared with the content's
    /// own animation so the two move together.
    private static let resizeDuration: TimeInterval = 0.2

    /// Keeps the window the size of its content while the content is moving.
    ///
    /// Animating the window to a precomputed target does not work once the
    /// content animates too: the target has to be read after the change, and by
    /// then SwiftUI is part way through its own animation, so what comes back is
    /// an intermediate height and the window animates to the wrong place.
    ///
    /// So the window is not animated at all. It follows — each tick it is set to
    /// whatever the content currently measures, with no animation of its own.
    /// The content's animation is the only clock, which is why the two cannot
    /// drift apart: there is only one of them.
    private func followContentSize() {
        let deadline = Date().addingTimeInterval(Self.resizeDuration + 0.1)
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { tick in
            syncWindowToContent()
            if Date() >= deadline { tick.invalidate() }
        }
        RunLoop.main.add(timer, forMode: RunLoopMode.commonModes)
    }

    /// Sets the window to the height its content currently measures.
    ///
    /// Also driven by the content's own geometry, so a change that nothing
    /// remembered to follow — a long note under the path picker once the
    /// positions file is read, for one — still gets a window that fits it,
    /// rather than one cut off at the height it opened with.
    private func syncWindowToContent() {
        guard let window = hostWindow, let content = window.contentView else { return }
        let swiftUIView = content.subviews.first ?? content
        swiftUIView.layoutSubtreeIfNeeded()
        let target = swiftUIView.fittingSize
        guard target.height > 0 else { return }

        var frame = window.frame
        let chrome = frame.height - content.frame.height
        let height = target.height + chrome
        if abs(height - frame.height) > 0.5 {
            // The top edge stays put: AppKit positions a window from its
            // bottom left, so height has to be taken off the origin too or
            // the title bar walks up the screen.
            frame.origin.y += frame.height - height
            frame.size.height = height
            window.setFrame(frame, display: true)
        }
    }

    private func trimmed(_ value: Float) -> String {
        return String(format: "%g", value)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("RAW Scan Dimensions").font(.title2).bold()
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the number of scan positions as X\u{00D7}Y (e.g., 80x80).").foregroundStyle(.secondary)
                if !fileHint.isEmpty {
                    Text(fileHint).font(.footnote).foregroundStyle(.secondary)
                }
                VStack {
                    Text("Scan size (X×Y):")
                    TextField("80x80", text: $scan_dims)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)

                    Button("Load Metadata\u{2026}") { loadMetadata() }
                        .padding(.top, 2)
                    if let note = metadataNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(metadataFailed ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 260)
                    }

                    // Also in the open, and for the same reason as the
                    // transforms below: a scan read in the wrong order is not
                    // obviously wrong afterwards. A serpentine scan read as a
                    // raster comes out complete and the right size, with every
                    // other row mirrored — which on a uniform region looks like
                    // a slightly noisy image rather than a mistake.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Scan path:")
                            Spacer()
                        }
                        Picker("", selection: $pathKind) {
                            ForEach(pathKinds) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 260)

                        if pathKind == .custom {
                            Button(positions == nil ? "Choose Positions\u{2026}" : "Choose Another\u{2026}") {
                                loadScanPath()
                            }
                        }
                        if let note = pathNote {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(pathFailed ? Color.orange : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 260, alignment: .leading)
                        }
                    }
                    .padding(.top, 6)

                    // Not behind a disclosure triangle, and above the
                    // calibrations. The orientation is the one thing here that
                    // is wrong by default as often as it is right — it depends
                    // on which detector wrote the file — and a wrong choice is
                    // not obvious afterwards, it just mirrors the scan. The
                    // calibrations below can be left empty and filled in later;
                    // this cannot.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Detector transforms:")
                            Spacer()
                        }
                        Toggle("Flip rows (mirror vertical)", isOn: $flipRows)
                        Toggle("Flip columns (mirror horizontal)", isOn: $flipCols)
                        Toggle("Transpose", isOn: $transpose)
                    }
                    .padding(.top, 6)

                    DisclosureGroup("Calibrations:", isExpanded: Binding(
                        get: { isCalibrationVisible },
                        set: { expanded in
                            // Animated, and over the same span the window takes.
                            // Left unanimated the fields appear at once while
                            // the panel is still opening underneath them.
                            withAnimation(.easeInOut(duration: Self.resizeDuration)) {
                                isCalibrationVisible = expanded
                            }
                        })) {
                        Text("Scan step (nm/pix):")
                        TextField("None", text: $scan_step)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        Text("Diffraction sampling (mrad/pix):")
                        TextField("None", text: $diff_step)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        Text("Accelerating voltage (kV):")
                        TextField("None", text: $voltage)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("OK") { confirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowReader { hostWindow = $0 })
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
            syncWindowToContent()
        }
        .onChange(of: isCalibrationVisible) { _, _ in
            followContentSize()
        }
        // The note under the picker depends on both, so both have to restate
        // it. A raster typed after the path file was chosen is the ordinary way
        // round, and it is the case where the check first becomes possible.
        .onChange(of: pathKind) { _, _ in
            refreshPathNote()
            followContentSize()
        }
        .onChange(of: scan_dims) { _, _ in refreshPathNote() }
        // The acquisition's own metadata, if it is sitting beside the data. Done
        // on appearance rather than when the panel is built, because it reads a
        // file and the body is rebuilt on every keystroke.
        .onAppear { adoptMetadataBesideFile() }
    }

    /// The rows the picker offers.
    ///
    /// The computed row appears only once there is something to compute from.
    /// A row that cannot be chosen is worse than no row at all: it reads as a
    /// claim that the metadata has been looked at.
    private var pathKinds: [ScanPathKind] {
        return ScanPathKind.allCases.filter { $0 != .computed || computed != nil }
    }

    /// Leaves the panel only if everything in it holds together.
    ///
    /// The scan size and the scan path are both checked here, because both can
    /// fail and neither failure is worth discovering once the read is under way:
    /// a bad raster reads the file as a valid dataset of the wrong shape, and a
    /// bad path would abort the load from a background queue.
    private func confirm() {
        guard let dims = Self.parseScanDimensions(scan_dims) else {
            NSSound.beep()
            return
        }
        let path: ScanPath
        switch resolvedPath() {
        case .success(let resolved):
            path = resolved
        case .failure(let error):
            pathFailed = true
            pathNote = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSSound.beep()
            followContentSize()
            return
        }
        onOK(RawOpenChoice(scanWidth: dims.width,
                           scanHeight: dims.height,
                           scanStep: scan_step,
                           diffStep: diff_step,
                           voltage: voltage,
                           flips: DetectorFlips(flipY: flipRows, flipX: flipCols,
                                                transpose: transpose),
                           scanPath: path,
                           metadata: importedMetadata))
    }
}

struct CalibrationSheet: View {
    @State var scanStep: String
    @State var diffStep: String
    @State var voltage: String

    let onCancel: () -> Void
    let onOK: (String, String, String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Calibrate").font(.title2).bold()
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Scan step (nm/pixel):")
                        .frame(width: 180, alignment: .leading)
                    TextField("None", text: $scanStep)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                HStack {
                    Text("Diffraction sampling (mrad/pixel):")
                        .frame(width: 180, alignment: .leading)
                    TextField("None", text: $diffStep)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                HStack {
                    Text("Accelerating voltage (kV):")
                        .frame(width: 180, alignment: .leading)
                    TextField("None", text: $voltage)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("OK") { onOK(scanStep, diffStep, voltage) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340, height: 220)
    }
}

#else
final class OpenPanelController: ObservableObject {
    @MainActor
    func open() {
        // No-op on non-macOS platforms
    }
}
#endif

