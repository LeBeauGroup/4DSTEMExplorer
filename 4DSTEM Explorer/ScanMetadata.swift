//
//  ScanMetadata.swift
//  4DSTEM Explorer
//
//  Reads the sidecar file that accompanies a RAW scan, in JSON, XML or TOML
//  — EMPAD wrote the first two, EMPAD2 writes the third.
//
//  A RAW file is just pixels: no dimensions, no calibration. Acquisition
//  software writes the rest alongside it, and typing those numbers back in by
//  hand is both tedious and a good way to introduce an error.
//
//  Both formats are flattened to the same list of (path, name, value, unit)
//  fields and then interrogated by name, rather than by walking a fixed
//  structure. That is deliberate: JSON sidecars and acquisition XML disagree
//  about nesting and spelling between vendors and between versions of the same
//  vendor's software, but they agree remarkably well on what things are called.
//  Matching on names means a schema this was never tested against still has a
//  good chance of working, and adding support for one that does not is a matter
//  of extending a synonym list rather than writing another parser.
//
//  XML usually records units; JSON, in the formats seen here, does not. Where a
//  unit is given it is used. Where it is absent the magnitude decides, which is
//  unambiguous in practice because a scan step of 5e-11 nm or 0.05 m is not a
//  thing anyone means.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

struct ScanMetadata {

    var scanWidth: Int?
    var scanHeight: Int?
    /// Nanometres per probe position.
    var scanStepNanometres: Float?
    /// Milliradians per detector pixel.
    var diffractionStepMilliradians: Float?
    /// Accelerating voltage in kilovolts.
    var voltageKilovolts: Float?
    /// Convergence semi-angle in milliradians, when recorded.
    var convergenceMilliradians: Float?
    /// Scan rotation in degrees, when recorded.
    var scanRotationDegrees: Float?
    /// The 2×2 scan correction, row-major, when recorded: the matrix such that
    /// `[x', y'] = M · [x, y]`.
    var scanCorrectionRowMajor: [Float]?
    /// Detector orientation when recorded: `[flip_y, flip_x, transpose]`.
    var detectorFlips: [Bool]?
    /// The RAW file this metadata was written for, if it says.
    var rawFilename: String?
    /// "JSON" or "XML", for the note shown in the panel.
    var sourceFormat: String = ""
    /// Where the scan size came from, when it was not read directly.
    var scanSizeSource: String?
    /// Set when an independent record of the scan size disagrees with the one
    /// used, which usually means the sidecar does not belong to this RAW file.
    var scanSizeConflict: String?
    /// How the scan step was arrived at, when it was derived rather than read.
    /// Surfaced in the panel: a derived calibration deserves a second look in a
    /// way that one written down by the microscope does not.
    var scanStepDerivation: String?

    /// The file this was read from.
    ///
    /// Kept so an export can be named after the metadata it came from rather
    /// than after the raw data — acquisition software names the two differently,
    /// and a calibration written back under the raster's name is hard to pair
    /// with the file it describes.
    var sourceURL: URL?

    /// The JSON object exactly as it was read, when the source was JSON.
    ///
    /// This type models only the fields the application understands; a real
    /// acquisition file carries a good deal more — exposure, beam current, the
    /// single-electron level, the acquisition time. Exporting a calibration
    /// built from this struct alone would silently drop all of it, so the
    /// original is kept and written back through, with the calibration laid
    /// over the top.
    var originalJSON: [String: Any]?

    /// One line describing what was found, for the panel.
    var summary: String {
        var parts: [String] = []
        if let w = scanWidth, let h = scanHeight { parts.append("\(w)×\(h) scan") }
        if let step = scanStepNanometres { parts.append(String(format: "%.4g nm/px", step)) }
        if let step = diffractionStepMilliradians { parts.append(String(format: "%.4g mrad/px", step)) }
        if let volts = voltageKilovolts { parts.append(String(format: "%.0f kV", volts)) }
        if let angle = convergenceMilliradians { parts.append(String(format: "%.1f mrad conv.", angle)) }
        if let rotation = scanRotationDegrees { parts.append(String(format: "%+.2f° scan rot.", rotation)) }
        if scanCorrectionRowMajor != nil { parts.append("scan correction") }
        if let flips = detectorFlips {
            let names = ["flip y", "flip x", "transpose"]
            let set = zip(flips, names).filter { $0.0 }.map { $0.1 }
            parts.append("det flips: " + (set.isEmpty ? "none" : set.joined(separator: "+")))
        }
        guard !parts.isEmpty else { return "No usable fields found." }
        var found = parts.joined(separator: ", ")
        if !sourceFormat.isEmpty { found = "\(sourceFormat): \(found)" }
        var qualifications: [String] = []
        if let source = scanSizeSource { qualifications.append("size from \(source)") }
        if let conflict = scanSizeConflict { qualifications.append("⚠︎ " + conflict) }
        if let derivation = scanStepDerivation { qualifications.append(derivation) }
        if !qualifications.isEmpty { found += " (" + qualifications.joined(separator: "; ") + ")" }
        return found
    }

    var isEmpty: Bool {
        return scanWidth == nil && scanStepNanometres == nil
            && diffractionStepMilliradians == nil && voltageKilovolts == nil
    }

    // MARK: - Reading

    enum ReadError: LocalizedError {
        case unreadable(String)
        case unrecognised(String)
        case nothingUseful(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "\(name) could not be read."
            case .unrecognised(let name):
                return "\(name) is not JSON, XML or TOML."
            case .nothingUseful(let name):
                return "\(name) has no scan size or calibration in it. Expected fields such as scan_shape, scan_step, diff_step and voltage."
            }
        }
    }

    /// File extensions the open panel should offer.
    static let supportedExtensions = ["json", "xml", "toml"]

    static func read(url: URL) throws -> ScanMetadata {
        let name = url.lastPathComponent
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable(name) }

        // Sniff the content rather than trusting the extension: acquisition
        // software is not consistent about naming, and an XML file called .json
        // should still work.
        var fields: [Field]
        var format: String
        var original: [String: Any]? = nil
        if let root = try? JSONSerialization.jsonObject(with: data) {
            fields = ScanMetadata.flattenJSON(root, path: [])
            format = "JSON"
            // Only a top-level object round-trips as metadata; an array or a
            // bare value parses but is not an EMPAD document.
            original = root as? [String: Any]
        } else if let parsed = ScanMetadata.flattenXML(data) {
            fields = parsed
            format = "XML"
        } else if let parsed = ScanMetadata.flattenTOML(data) {
            fields = parsed
            format = "TOML"
        } else {
            throw ReadError.unrecognised(name)
        }

        var metadata = ScanMetadata.interpret(fields)
        metadata.sourceFormat = format
        metadata.sourceURL = url
        metadata.originalJSON = original
        guard !metadata.isEmpty else { throw ReadError.nothingUseful(name) }
        return metadata
    }

    // MARK: - Fields

    /// One leaf value from either format.
    private struct Field {
        /// Normalised full path, e.g. `acquisitionscanstep`.
        let path: String
        /// The same path before it was joined, each component normalised.
        ///
        /// Kept so a synonym can be required to line up with whole components.
        /// Matching a suffix of the joined string instead lets a short synonym
        /// land in the middle of a word: `dk` matches `…pid_k`, and `ht`
        /// matches `…height`.
        let components: [String]
        /// Normalised local name, e.g. `step`.
        let name: String
        /// The value as written.
        let text: String
        /// A unit given alongside the value, if the format recorded one.
        let unit: String?
        /// Normalised values of `mode`/`type`/`name`/`id` attributes on this
        /// element and its ancestors. Acquisition XML repeats whole blocks —
        /// EMPAD writes one `scan_parameters` for the search raster and another
        /// for the acquisition — and without these the first one in the file
        /// wins, which is the wrong one.
        let qualifiers: Set<String>

        /// Every number in the text, so `256 256` and `[256, 256]` both work.
        var numbers: [Double] {
            var out: [Double] = []
            var current = ""
            for character in text {
                if character.isNumber || character == "." || character == "-"
                    || character == "+" || character == "e" || character == "E" {
                    current.append(character)
                } else {
                    if let value = Double(current) { out.append(value) }
                    current = ""
                }
            }
            if let value = Double(current) { out.append(value) }
            return out
        }

        var number: Double? { return numbers.count == 1 ? numbers[0] : numbers.first }

        /// True when `synonym` is exactly the last one-or-more components
        /// joined together.
        func matchesTrailingComponents(_ synonym: String) -> Bool {
            guard !components.isEmpty else { return false }
            var joined = ""
            for component in components.reversed() {
                joined = component + joined
                if joined == synonym { return true }
                if joined.count > synonym.count { return false }
            }
            return false
        }
    }

    /// Lowercased with everything that is not a letter or digit removed, so
    /// `Scan Step`, `scan_step`, `scan-step` and `ScanStep` all coincide.
    private static func normalise(_ text: String) -> String {
        return String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    // MARK: JSON

    private static func flattenJSON(_ value: Any, path: [String]) -> [Field] {
        if let dictionary = value as? [String: Any] {
            var out: [Field] = []
            for (key, child) in dictionary {
                out += flattenJSON(child, path: path + [key])
            }
            return out
        }
        if let array = value as? [Any] {
            // An array of numbers is one value (a shape, a step pair). An array
            // of objects is a list of things to walk into.
            let scalars = array.compactMap { element -> String? in
                if let number = element as? NSNumber { return number.stringValue }
                if let text = element as? String { return text }
                return nil
            }
            if scalars.count == array.count, !array.isEmpty {
                return [field(path: path, text: scalars.joined(separator: " "), unit: nil)]
            }
            var out: [Field] = []
            for (index, element) in array.enumerated() {
                out += flattenJSON(element, path: path + ["\(index)"])
            }
            return out
        }
        if let number = value as? NSNumber {
            return [field(path: path, text: number.stringValue, unit: nil)]
        }
        if let text = value as? String {
            return [field(path: path, text: text, unit: nil)]
        }
        return []
    }

    private static func field(path: [String], text: String, unit: String?,
                             qualifiers: Set<String> = []) -> Field {
        let components = path.map(normalise).filter { !$0.isEmpty }
        return Field(path: components.joined(),
                     components: components,
                     name: normalise(path.last ?? ""),
                     text: text,
                     unit: unit.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                     qualifiers: qualifiers)
    }

    // MARK: TOML

    /// EMPAD2 writes its metadata as TOML, so this reads TOML.
    ///
    /// A deliberate subset, not a conforming parser: table headers, key/value
    /// pairs, strings, numbers, booleans and arrays including the multi-line
    /// form. That is what instrument software writes. The things left out —
    /// arrays of tables, inline tables, multi-line strings — do not appear in
    /// these files, and a partial read of one would be worse than declining it,
    /// so anything unrecognised is skipped rather than guessed at.
    ///
    /// Emits the same `Field` values the JSON and XML readers do, so everything
    /// downstream — the synonym lookup, the unit handling, the whole of
    /// `interpret` — applies unchanged.
    private static func flattenTOML(_ data: Data) -> [Field]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var fields: [Field] = []
        var table: [String] = []
        var headers = 0
        var buffer = ""
        var depth = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripComment(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if depth == 0 {
                if trimmed.isEmpty { continue }
                // A table header: bracketed, and no assignment in it. An array
                // value also starts with a bracket but only after an `=`.
                if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.contains("=") {
                    let inner = String(trimmed.dropFirst().dropLast())
                        .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    table = inner.split(separator: ".").map {
                        $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    }
                    headers += 1
                    continue
                }
                guard trimmed.contains("=") else { continue }
            }

            buffer += buffer.isEmpty ? trimmed : " " + trimmed
            depth += bracketDepth(trimmed)
            guard depth <= 0 else { continue }
            depth = 0

            defer { buffer = "" }
            guard let split = assignmentIndex(buffer) else { continue }
            let key = String(buffer[buffer.startIndex..<split])
                .trimmingCharacters(in: .whitespaces)
            let value = String(buffer[buffer.index(after: split)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }

            // A dotted key names a sub-table of the current one.
            let keyPath = key.split(separator: ".").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
            guard !keyPath.isEmpty else { continue }
            fields.append(field(path: table + keyPath, text: tomlValue(value), unit: nil))
        }

        // Some structure is required before this is called TOML at all: any
        // plain text file has lines with an equals sign in it.
        guard headers > 0 || fields.count > 1 else { return nil }
        return fields.isEmpty ? nil : fields
    }

    /// Everything from an unquoted `#` onwards.
    private static func stripComment(_ line: String) -> String {
        var out = ""
        var quote: Character? = nil
        var escaped = false
        for character in line {
            if let active = quote {
                out.append(character)
                if escaped { escaped = false }
                else if character == "\\" && active == "\"" { escaped = true }
                else if character == active { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character; out.append(character); continue }
            if character == "#" { break }
            out.append(character)
        }
        return out
    }

    /// Net bracket depth, ignoring brackets inside strings.
    private static func bracketDepth(_ line: String) -> Int {
        var depth = 0
        var quote: Character? = nil
        var escaped = false
        for character in line {
            if let active = quote {
                if escaped { escaped = false }
                else if character == "\\" && active == "\"" { escaped = true }
                else if character == active { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "[": depth += 1
            case "]": depth -= 1
            default: break
            }
        }
        return depth
    }

    /// The first `=` that is not inside a string.
    private static func assignmentIndex(_ line: String) -> String.Index? {
        var quote: Character? = nil
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let active = quote {
                if escaped { escaped = false }
                else if character == "\\" && active == "\"" { escaped = true }
                else if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// A TOML value as the text a `Field` carries.
    ///
    /// Arrays collapse to their scalars separated by spaces, which is how the
    /// JSON reader renders them and what `Field.numbers` expects. Booleans
    /// become 1 and 0 for the same reason: the detector-flip triple is read as
    /// three numbers whatever wrote it.
    private static func tomlValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
            let parts = splitTopLevel(value).map { tomlValue($0) }.filter { !$0.isEmpty }
            return parts.joined(separator: " ")
        }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            let body = String(value.dropFirst().dropLast())
            var out = ""
            var escaped = false
            for character in body {
                if escaped {
                    switch character {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    default: out.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    out.append(character)
                }
            }
            return out
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        if value == "true" { return "1" }
        if value == "false" { return "0" }
        return value
    }

    /// Splits on commas that are not inside a nested array or a string.
    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character? = nil
        var escaped = false
        for character in text {
            if let active = quote {
                current.append(character)
                if escaped { escaped = false }
                else if character == "\\" && active == "\"" { escaped = true }
                else if character == active { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character; current.append(character)
            case "[": depth += 1; current.append(character)
            case "]": depth -= 1; current.append(character)
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            default: current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    // MARK: XML

    private static func flattenXML(_ data: Data) -> [Field]? {
        let delegate = XMLFlattener()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse(), !delegate.fields.isEmpty else { return nil }
        return delegate.fields
    }

    /// Walks an XML document and records every element with text and every
    /// attribute as a field.
    ///
    /// Attributes matter as much as elements here: acquisition XML is as likely
    /// to write `<Scan step="0.05" unit="nm"/>` as it is to use child elements,
    /// and a reader that only looked at element text would miss half the
    /// formats. A `unit`-like attribute on an element is attached to that
    /// element's value rather than recorded on its own.
    private final class XMLFlattener: NSObject, XMLParserDelegate {

        private(set) var fields: [Field] = []
        private var path: [String] = []
        private var text = ""
        private var pendingUnit: [String?] = []
        private var qualifierStack: [Set<String>] = []

        private static let unitNames: Set<String> = ["unit", "units", "unitname", "uom", "dimension"]
        /// Attributes that distinguish one repeated block from another.
        private static let qualifierNames: Set<String> = ["mode", "type", "name", "id", "idx", "state"]

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes attributeDict: [String: String]) {
            path.append(elementName)
            text = ""

            var unit: String?
            var qualifiers = qualifierStack.last ?? []
            for (key, value) in attributeDict
            where XMLFlattener.qualifierNames.contains(ScanMetadata.normalise(key)) {
                qualifiers.insert(ScanMetadata.normalise(value))
            }
            qualifierStack.append(qualifiers)

            for (key, value) in attributeDict {
                if XMLFlattener.unitNames.contains(ScanMetadata.normalise(key)) {
                    unit = value
                } else {
                    // A value-bearing attribute is a field in its own right.
                    fields.append(ScanMetadata.field(path: path + [key], text: value,
                                                     unit: nil, qualifiers: qualifiers))
                }
            }
            // A `value` attribute is the element's value, not a separate field.
            if let value = attributeDict.first(where: { ScanMetadata.normalise($0.key) == "value" })?.value {
                fields.append(ScanMetadata.field(path: path, text: value, unit: unit,
                                                 qualifiers: qualifiers))
            }
            pendingUnit.append(unit)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let unit = pendingUnit.popLast() ?? nil
            let qualifiers = qualifierStack.popLast() ?? []
            if !trimmed.isEmpty {
                fields.append(ScanMetadata.field(path: path, text: trimmed, unit: unit,
                                                 qualifiers: qualifiers))
            }
            path.removeLast()
            text = ""
        }
    }

    // MARK: - Interpretation

    /// Finds the first field whose name or path matches one of `synonyms`.
    ///
    /// Tried most specific first: a full path equal to the synonym, then a local
    /// name equal to it, then a path ending with it. The last case is what lets
    /// `scanstep` find `<Scan><Step>` without knowing the nesting.
    private static func lookup(_ fields: [Field], _ synonyms: [String],
                               preferring qualifiers: [String] = [],
                               rejecting excluded: [String] = []) -> Field? {
        // A preferred block is searched exhaustively before the rest of the
        // document, so the acquisition raster beats the search raster no matter
        // which appears first.
        if !qualifiers.isEmpty {
            let preferred = fields.filter { field in
                qualifiers.contains { field.qualifiers.contains($0) }
            }
            if let hit = match(preferred, synonyms) { return hit }
        }
        // Rejection is not the same as preference. For the scan geometry the
        // search raster is not a worse answer than the acquisition raster, it is
        // the wrong one — it describes a different raster entirely — so it must
        // never be returned as a fallback. Returning nothing is recoverable;
        // returning the preview's dimensions silently is not.
        guard !excluded.isEmpty else { return match(fields, synonyms) }
        let permitted = fields.filter { field in
            !excluded.contains { field.qualifiers.contains($0) }
        }
        return match(permitted, synonyms)
    }

    private static func match(_ fields: [Field], _ synonyms: [String]) -> Field? {
        for synonym in synonyms {
            if let hit = fields.first(where: { $0.path == synonym }) { return hit }
        }
        for synonym in synonyms {
            if let hit = fields.first(where: { $0.name == synonym }) { return hit }
        }
        // A trailing run of whole components, not any trailing substring.
        //
        // `scan.width` still answers to `scanwidth` and `raw_file.filename` to
        // `rawfilefilename`, because those align with the components. What no
        // longer matches is a synonym that happens to end a word: `dk` against
        // `instruments.ostech_ps01.pid_k`, which read a cooler's PID gain as the
        // detector calibration, or `ht` against `scan.height`, which would read
        // a raster as an accelerating voltage. Both are silent — the number is
        // plausible and nothing downstream can tell it came from the wrong key.
        for synonym in synonyms {
            if let hit = fields.first(where: { $0.matchesTrailingComponents(synonym) }) {
                return hit
            }
        }
        return nil
    }

    /// Blocks describing the real acquisition, preferred over a preview raster.
    private static let acquisitionQualifiers = ["acquire", "acquisition", "record", "capture"]

    /// Blocks describing a raster that is not the one on disk. EMPAD writes a
    /// `scan_parameters mode="search"` block for the live preview alongside the
    /// `mode="acquire"` block, and the preview comes first in the file.
    private static let previewQualifiers = ["search", "preview", "focus", "survey", "align", "tune"]

    private static func interpret(_ fields: [Field]) -> ScanMetadata {
        var metadata = ScanMetadata()

        if let name = lookup(fields, ["rawfilename", "rawfilefilename", "rawfile",
                                      "datafilename", "filename"]),
           name.numbers.count != 1 {
            metadata.rawFilename = name.text
        }

        // Scan size. The acquisition block is the authority: it describes the
        // raster that was actually written to disk. A preview or search block
        // describes a different one and is excluded outright rather than merely
        // ranked below.
        let fromFilename = metadata.rawFilename.flatMap { dimensions(fromFilename: $0) }

        if let shape = lookup(fields, ["scanshape", "scandimensions", "scandims", "shape"],
                              preferring: acquisitionQualifiers,
                              rejecting: previewQualifiers),
           shape.numbers.count >= 2 {
            metadata.scanWidth = Int(shape.numbers[0])
            metadata.scanHeight = Int(shape.numbers[1])
        } else if let w = lookup(fields, ["scanresolutionx", "scanx", "scanwidth", "scansizex",
                                          "nx", "scanxpixels", "scanpointsx", "resolutionx", "width"],
                                 preferring: acquisitionQualifiers,
                                 rejecting: previewQualifiers)?.number,
                  let h = lookup(fields, ["scanresolutiony", "scany", "scanheight", "scansizey",
                                          "ny", "scanypixels", "scanpointsy", "resolutiony", "height"],
                                 preferring: acquisitionQualifiers,
                                 rejecting: previewQualifiers)?.number {
            metadata.scanWidth = Int(w)
            metadata.scanHeight = Int(h)
        } else if let size = fromFilename {
            // Nothing usable in the metadata itself; the RAW file's own name
            // encodes the raster, as EMPAD writes scan_x100_y100.raw.
            metadata.scanWidth = size.width
            metadata.scanHeight = size.height
            metadata.scanSizeSource = "raw filename"
        }

        // The filename is an independent record of the same thing. When both
        // exist and disagree, say so rather than quietly trusting one: it means
        // the sidecar and the data file have come apart.
        if let size = fromFilename, let width = metadata.scanWidth, let height = metadata.scanHeight,
           metadata.scanSizeSource == nil, size.width != width || size.height != height {
            metadata.scanSizeConflict = "the raw filename says \(size.width)×\(size.height)"
        }

        // Scan step, if it is written down.
        if let step = lookup(fields, ["scanstep", "scanstepsize", "stepsize", "pixelsize",
                                      "scanpixelsize", "scanpixelsizex", "scanpixelsizey",
                                      "realspacepixelsize", "scancalibration"],
                             preferring: acquisitionQualifiers,
                             rejecting: previewQualifiers) {
            metadata.scanStepNanometres = lengthInNanometres(step)
        }

        // Otherwise derive it from the field of view.
        //
        // Note what is deliberately *not* in the list below: `scan_size`. EMPAD
        // writes `<scan_size>1.0</scan_size>` as the fraction of the full field
        // being scanned — a dimensionless number, not a length. Reading it as one
        // gives a step three orders of magnitude too small, and nothing about the
        // result looks wrong enough to notice.
        if metadata.scanStepNanometres == nil,
           let fov = lookup(fields, ["fullscanfieldofviewx", "scanfieldofviewx", "fieldofviewx",
                                     "fovx", "scanfov", "fieldofview", "fov", "scanwidthnm"],
                            preferring: acquisitionQualifiers,
                            rejecting: previewQualifiers),
           let extent = lengthInNanometres(fov),
           let width = metadata.scanWidth, width > 0 {

            var scanned = extent
            var note = "step from field of view / scan size"
            // The scanned fraction of the full field, when given as a fraction.
            if let fraction = lookup(fields, ["scansize", "scanfraction", "scanscale"],
                                     preferring: acquisitionQualifiers,
                                     rejecting: previewQualifiers)?.number,
               fraction > 0, fraction <= 1 {
                scanned = extent * Float(fraction)
                if fraction != 1 { note += String(format: " x %.3g", fraction) }
            }
            metadata.scanStepNanometres = scanned / Float(width)
            metadata.scanStepDerivation = note
        }

        // Diffraction step, an angle per detector pixel.
        if let step = lookup(fields, ["diffstep", "diffractionstep", "diffractionpixelsize",
                                      "reciprocalpixelsize", "dk", "qpixelsize",
                                      "detectorcalibration", "angularpixelsize"]) {
            metadata.diffractionStepMilliradians = milliradians(step)
        }

        if let volts = lookup(fields, ["voltage", "acceleratingvoltage", "accelerationvoltage",
                                       "highvoltage", "ht", "beamenergy", "energy", "kv"]) {
            metadata.voltageKilovolts = kilovolts(volts)
        }

        if let angle = lookup(fields, ["convangle", "convergenceangle", "convergencesemiangle",
                                       "semiangle", "alpha", "probeconvergence", "aperture"]) {
            metadata.convergenceMilliradians = beamMilliradians(angle)
        }

        if let rotation = lookup(fields, ["scanrotation", "rotation", "scanrotationangle"],
                                 preferring: acquisitionQualifiers,
                                 rejecting: previewQualifiers)?.number {
            metadata.scanRotationDegrees = Float(rotation)
        }

        metadata.scanCorrectionRowMajor = scanCorrection(fields)
        metadata.detectorFlips = detectorFlips(fields)

        return metadata
    }

    /// Detector orientation, `[flip_y, flip_x, transpose]`.
    ///
    /// JSON writes these as booleans, which the flattener renders as "1"/"0" —
    /// so they arrive as three numbers, not three words, and are read as such.
    private static func detectorFlips(_ fields: [Field]) -> [Bool]? {
        guard let field = lookup(fields, ["detflips", "detectorflips", "patternflips"]) else {
            return nil
        }
        let numbers = field.numbers
        if numbers.count == 3 { return numbers.map { $0 != 0 } }
        // Tolerate "true false false" as well, since a hand-written file may.
        let words = field.text.lowercased().split { !$0.isLetter }
        if words.count == 3, words.allSatisfy({ $0 == "true" || $0 == "false" }) {
            return words.map { $0 == "true" }
        }
        return nil
    }

    /// The 2×2 scan correction, row-major.
    ///
    /// Written as nested arrays, `[[a, b], [c, d]]` flattens to one field per
    /// row rather than one field for the matrix — the array walker only treats
    /// an array as a single value when its elements are scalars. So both shapes
    /// are accepted: two two-number rows, or one field holding all four.
    private static func scanCorrection(_ fields: [Field]) -> [Float]? {
        let names = ["scancorrection", "scancorrectionmatrix", "scanaffine", "scanshear"]

        let rows = fields.filter { field in
            names.contains { field.path.hasPrefix($0) } && field.numbers.count == 2
        }
        if rows.count == 2 {
            // Sorted by path so row 1 cannot arrive before row 0; dictionary
            // iteration gives no order and the transpose is a plausible matrix,
            // so this would fail silently rather than loudly.
            let ordered = rows.sorted { $0.path < $1.path }
            let values = ordered.flatMap { $0.numbers }.map { Float($0) }
            return values.allSatisfy { $0.isFinite } ? values : nil
        }

        if let flat = lookup(fields, names), flat.numbers.count == 4 {
            let values = flat.numbers.map { Float($0) }
            return values.allSatisfy { $0.isFinite } ? values : nil
        }
        return nil
    }

    /// Scan dimensions encoded in a RAW filename, as EMPAD writes them:
    /// `scan_x100_y100.raw`.
    static func dimensions(fromFilename name: String) -> (width: Int, height: Int)? {
        let lowered = name.lowercased()
        func value(after marker: String) -> Int? {
            guard let range = lowered.range(of: marker) else { return nil }
            let digits = lowered[range.upperBound...].prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
        guard let width = value(after: "_x"), let height = value(after: "_y"),
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    // MARK: - Units

    /// Multiplier from a named length unit to nanometres, or nil if unrecognised.
    private static func nanometresPer(unit: String) -> Double? {
        switch normalise(unit) {
        case "m", "meter", "meters", "metre", "metres":       return 1e9
        case "mm", "millimeter", "millimeters", "millimetre", "millimetres": return 1e6
        case "um", "µm", "micron", "microns", "micrometer", "micrometers",
             "micrometre", "micrometres":                     return 1e3
        case "nm", "nanometer", "nanometers", "nanometre", "nanometres":     return 1
        case "a", "å", "ang", "angstrom", "angstroms", "angstrom0":          return 0.1
        case "pm", "picometer", "picometers", "picometre", "picometres":     return 1e-3
        default: return nil
        }
    }

    /// A length in nanometres, using the recorded unit when there is one and
    /// falling back to the magnitude when there is not.
    private static func lengthInNanometres(_ field: Field) -> Float? {
        guard let value = field.number, value > 0, value.isFinite else { return nil }
        if let unit = field.unit, let scale = nanometresPer(unit: unit) {
            return Float(value * scale)
        }
        return lengthInNanometres(value)
    }

    /// The magnitude-based fallback, kept separate so it can be tested directly.
    static func lengthInNanometres(_ value: Double) -> Float? {
        guard value > 0, value.isFinite else { return nil }
        if value < 1e-7 { return Float(value * 1e9) }      // metres
        if value < 1e-4 { return Float(value * 1e6) }      // millimetres
        if value > 100 { return Float(value / 10.0) }      // ångström
        return Float(value)                                // already nanometres
    }

    /// An angle in milliradians, from a unit when given, otherwise from the
    /// magnitude: radians are three orders below any sane per-pixel value.
    private static func milliradians(_ field: Field) -> Float? {
        guard let value = field.number, value > 0, value.isFinite else { return nil }
        if let unit = field.unit {
            switch normalise(unit) {
            case "rad", "radian", "radians":            return Float(value * 1000)
            case "mrad", "milliradian", "milliradians": return Float(value)
            case "deg", "degree", "degrees", "°":       return Float(value * 1000 * .pi / 180)
            default: break
            }
        }
        return value < 1e-3 ? Float(value * 1000) : Float(value)
    }

    /// A beam angle in milliradians.
    ///
    /// Kept apart from the per-pixel version because the two quantities live at
    /// different magnitudes and one rule cannot serve both. A convergence
    /// semi-angle is 1–50 mrad, which is 0.001–0.05 rad, so below 1 means
    /// radians. The per-pixel step is a thousand times smaller and needs the
    /// lower threshold it has.
    ///
    /// Sharing the per-pixel rule is what EMPAD2 exposed: it records
    /// `convergence_angle = 0.025` in radians, and 0.025 is above that rule's
    /// threshold, so a 25 mrad probe was read as 0.025 mrad. A factor of a
    /// thousand, and nothing downstream looks wrong enough to catch it — the
    /// disc simply implies a detector calibration a thousand times too fine.
    private static func beamMilliradians(_ field: Field) -> Float? {
        guard let value = field.number, value > 0, value.isFinite else { return nil }
        if let unit = field.unit {
            switch normalise(unit) {
            case "rad", "radian", "radians":            return Float(value * 1000)
            case "mrad", "milliradian", "milliradians": return Float(value)
            case "deg", "degree", "degrees", "°":       return Float(value * 1000 * .pi / 180)
            default: break
            }
        }
        // No convergence semi-angle worth recording is below a milliradian.
        return value < 1 ? Float(value * 1000) : Float(value)
    }

    private static func kilovolts(_ field: Field) -> Float? {
        guard let value = field.number, value > 0, value.isFinite else { return nil }
        if let unit = field.unit {
            switch normalise(unit) {
            case "v", "volt", "volts":            return Float(value / 1000)
            case "kv", "kilovolt", "kilovolts":   return Float(value)
            case "ev", "electronvolt", "electronvolts": return Float(value / 1000)
            case "kev":                           return Float(value)
            case "mv", "megavolt", "megavolts":   return Float(value * 1000)
            default: break
            }
        }
        return value >= 1000 ? Float(value / 1000) : Float(value)
    }
}
