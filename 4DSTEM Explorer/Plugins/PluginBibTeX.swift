//
//  PluginBibTeX.swift
//  4DSTEM Explorer
//
//  Reads the .bib file a plugin ships with itself.
//
//  A plugin declares its references by putting a BibTeX file in its source
//  folder; build-plugin.sh bundles it, and the host reads it back out. The file
//  is the source of truth: what the user exports is a byte-for-byte copy of what
//  the plugin author wrote and validated with their own tools. Nothing here
//  re-emits BibTeX, so there is no formatting step that can silently corrupt an
//  entry — this parser only has to understand the file well enough to list it on
//  screen.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

// MARK: - Entry

/// One reference, as read from a .bib file.
struct PluginCitation: Identifiable {

    /// The cite key.
    let id: String
    /// Entry type without the `@`, lowercased: article, misc, book…
    let type: String
    /// Field names lowercased, values with the outer delimiters removed.
    let fields: [String: String]
    /// Position in the file, which is also the display order.
    let order: Int

    func field(_ name: String) -> String {
        return fields[name] ?? ""
    }

    // MARK: Display

    /// Authors split on the top-level "and", in reading order.
    var authorList: [String] {
        let raw = field("author")
        guard !raw.isEmpty else { return [] }
        var names: [String] = []
        var current = ""
        var depth = 0
        var index = raw.startIndex

        while index < raw.endIndex {
            let character = raw[index]
            if character == "{" { depth += 1 }
            if character == "}" { depth = Swift.max(0, depth - 1) }

            // " and " only separates authors outside braces, so a name like
            // {Institute of Science and Technology} stays whole.
            if depth == 0, raw[index...].hasPrefix(" and ") {
                names.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                index = raw.index(index, offsetBy: 5)
                continue
            }
            current.append(character)
            index = raw.index(after: index)
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { names.append(last) }
        return names.map { PluginBibTeXParser.plainText($0) }
    }

    /// "Family, Given" turned back into "Given Family" for reading.
    var displayAuthors: String {
        let names = authorList.map { name -> String in
            let parts = name.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[1].isEmpty else { return name }
            return "\(parts[1]) \(parts[0])"
        }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        // Long author lists are the norm here; the full list is in the file.
        case 3...5: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        default: return "\(names[0]) et al."
        }
    }

    var title: String { return PluginBibTeXParser.plainText(field("title")) }

    /// Why the plugin cites it. `annote` is a standard BibTeX field that the
    /// common styles ignore, so using it keeps the file ordinary BibTeX rather
    /// than something only this app understands.
    var reason: String { return PluginBibTeXParser.plainText(field("annote")) }

    var doi: String { return field("doi") }

    var url: String {
        let explicit = field("url")
        if !explicit.isEmpty { return explicit }
        // \url{...} inside howpublished is the classic-BibTeX idiom for this.
        let published = field("howpublished")
        if let range = published.range(of: "\\url{"),
           let close = published[range.upperBound...].firstIndex(of: "}") {
            return String(published[range.upperBound..<close])
        }
        return published.hasPrefix("http") ? published : ""
    }

    var link: URL? {
        if !doi.isEmpty { return URL(string: "https://doi.org/\(doi)") }
        if !url.isEmpty { return URL(string: url) }
        return nil
    }

    var linkLabel: String {
        if !doi.isEmpty { return "doi.org/\(doi)" }
        return url
    }

    /// Journal, volume, pages, year — whatever the entry actually has.
    var displayDetail: String {
        var parts: [String] = []
        let container = [field("journal"), field("booktitle"), field("publisher")]
            .first { !$0.isEmpty } ?? ""
        if !container.isEmpty { parts.append(PluginBibTeXParser.plainText(container)) }

        let volume = field("volume")
        if !volume.isEmpty {
            let number = field("number")
            parts.append(number.isEmpty ? volume : "\(volume)(\(number))")
        }
        let pages = field("pages").replacingOccurrences(of: "--", with: "–")
        if !pages.isEmpty { parts.append(pages) }
        let year = field("year")
        if !year.isEmpty { parts.append(year) }
        return parts.joined(separator: ", ")
    }

    /// Shown when there is nothing else to say about an entry.
    var note: String { return PluginBibTeXParser.plainText(field("note")) }
}

// MARK: - Parser

/// Enough of BibTeX to list a bibliography on screen.
///
/// Deliberately lenient: a file that a real BibTeX run would reject should still
/// show what it can rather than displaying nothing. Anything it cannot make
/// sense of is skipped, and the raw file is what gets exported regardless.
enum PluginBibTeXParser {

    /// Every entry in the file, in the order they appear.
    static func parse(_ text: String) -> [PluginCitation] {
        var scanner = Scanner(text: Array(text))
        var macros: [String: String] = [:]
        var entries: [PluginCitation] = []
        var seen = Set<String>()

        while let at = scanner.advanceToEntry() {
            _ = at
            guard let type = scanner.readName()?.lowercased() else { continue }

            if type == "comment" || type == "preamble" {
                scanner.skipBalancedBlock()
                continue
            }
            guard let open = scanner.readOpeningDelimiter() else { continue }
            let close: Character = (open == "(") ? ")" : "}"

            if type == "string" {
                if let (name, value) = scanner.readField(macros: macros, terminator: close) {
                    macros[name] = value
                }
                scanner.skipTo(close)
                continue
            }

            guard let key = scanner.readCiteKey() else {
                scanner.skipTo(close)
                continue
            }

            var fields: [String: String] = [:]
            while scanner.consumeComma() {
                guard let (name, value) = scanner.readField(macros: macros, terminator: close) else { break }
                // First definition wins, matching BibTeX itself.
                if fields[name] == nil { fields[name] = value }
            }
            scanner.skipTo(close)

            // A duplicate cite key would collide in the exported file; keep the
            // first, as BibTeX does.
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            entries.append(PluginCitation(id: key, type: type, fields: fields, order: entries.count))
        }
        return entries
    }

    // MARK: Display text

    /// Turns a field value into something readable: drops the braces that
    /// protect capitalisation, unescapes the characters BibTeX requires to be
    /// escaped, and resolves the accent forms common in author names.
    static func plainText(_ value: String) -> String {
        var out = ""
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]

            if character == "\\" {
                let rest = value[value.index(after: index)...]
                var matched = false
                for (macro, replacement) in PluginBibTeXParser.escapes where rest.hasPrefix(macro) {
                    out += replacement
                    index = value.index(index, offsetBy: 1 + macro.count)
                    matched = true
                    break
                }
                if matched { continue }
                // An accent such as \"o or \'e, optionally braced: {\"o}, \"{o}.
                if let accent = readAccent(value, from: index) {
                    out += accent.text
                    index = accent.next
                    continue
                }
                index = value.index(after: index)     // drop a macro we do not know
                continue
            }

            // Braces here are grouping, not content.
            if character == "{" || character == "}" {
                index = value.index(after: index)
                continue
            }
            if character == "~" {                      // non-breaking space
                out += " "
                index = value.index(after: index)
                continue
            }
            out.append(character)
            index = value.index(after: index)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let escapes: [(String, String)] = [
        ("textbackslash{}", "\\"), ("textbackslash", "\\"),
        ("textasciitilde{}", "~"), ("textasciitilde", "~"),
        ("textasciicircum{}", "^"), ("textasciicircum", "^"),
        ("textemdash", "—"), ("textendash", "–"),
        ("&", "&"), ("%", "%"), ("#", "#"), ("$", "$"), ("_", "_"),
        ("{", "{"), ("}", "}")
    ]

    private static let accents: [Character: [Character: String]] = [
        "\"": ["a": "ä", "e": "ë", "i": "ï", "o": "ö", "u": "ü", "y": "ÿ",
               "A": "Ä", "E": "Ë", "I": "Ï", "O": "Ö", "U": "Ü"],
        "'":  ["a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý", "c": "ć", "n": "ń", "s": "ś",
               "A": "Á", "E": "É", "I": "Í", "O": "Ó", "U": "Ú"],
        "`":  ["a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù",
               "A": "À", "E": "È", "I": "Ì", "O": "Ò", "U": "Ù"],
        "^":  ["a": "â", "e": "ê", "i": "î", "o": "ô", "u": "û",
               "A": "Â", "E": "Ê", "I": "Î", "O": "Ô", "U": "Û"],
        "~":  ["a": "ã", "n": "ñ", "o": "õ", "A": "Ã", "N": "Ñ", "O": "Õ"],
        "c":  ["c": "ç", "C": "Ç"],
        "v":  ["c": "č", "s": "š", "z": "ž", "r": "ř", "C": "Č", "S": "Š", "Z": "Ž"]
    ]

    /// Reads `\<accent><letter>` or `\<accent>{<letter>}` starting at the
    /// backslash, returning the composed character.
    private static func readAccent(_ value: String, from start: String.Index)
        -> (text: String, next: String.Index)? {

        var index = value.index(after: start)
        guard index < value.endIndex else { return nil }
        let mark = value[index]
        guard let table = accents[mark] else { return nil }

        index = value.index(after: index)
        // A letter accent such as \c or \v must be followed by a separator.
        if mark.isLetter {
            guard index < value.endIndex, value[index] == "{" || value[index] == " " else { return nil }
        }
        var braced = false
        if index < value.endIndex, value[index] == "{" {
            braced = true
            index = value.index(after: index)
        } else if index < value.endIndex, value[index] == " " {
            index = value.index(after: index)
        }
        guard index < value.endIndex, let composed = table[value[index]] else { return nil }
        index = value.index(after: index)
        if braced, index < value.endIndex, value[index] == "}" { index = value.index(after: index) }
        return (composed, index)
    }

    // MARK: Scanner

    private struct Scanner {
        let text: [Character]
        var position: Int = 0

        init(text: [Character]) { self.text = text }

        var isAtEnd: Bool { return position >= text.count }

        mutating func skipWhitespace() {
            while position < text.count, text[position].isWhitespace { position += 1 }
        }

        /// Moves to just past the next `@` that begins an entry. Everything
        /// between entries in a .bib file is a comment.
        mutating func advanceToEntry() -> Bool? {
            while position < text.count {
                if text[position] == "@" {
                    position += 1
                    return true
                }
                position += 1
            }
            return nil
        }

        mutating func readName() -> String? {
            skipWhitespace()
            var out = ""
            while position < text.count, text[position].isLetter || text[position].isNumber
                    || text[position] == "-" || text[position] == "_" {
                out.append(text[position])
                position += 1
            }
            return out.isEmpty ? nil : out
        }

        mutating func readOpeningDelimiter() -> Character? {
            skipWhitespace()
            guard position < text.count, text[position] == "{" || text[position] == "(" else { return nil }
            let delimiter = text[position]
            position += 1
            return delimiter
        }

        mutating func readCiteKey() -> String? {
            skipWhitespace()
            var out = ""
            while position < text.count, text[position] != ",", text[position] != "}",
                  !text[position].isWhitespace {
                out.append(text[position])
                position += 1
            }
            skipWhitespace()
            return out
        }

        mutating func consumeComma() -> Bool {
            skipWhitespace()
            guard position < text.count, text[position] == "," else { return false }
            position += 1
            skipWhitespace()
            // A trailing comma before the closing brace ends the entry.
            return position < text.count && text[position] != "}" && text[position] != ")"
        }

        /// `name = value`, with `#` concatenation and macro substitution.
        mutating func readField(macros: [String: String], terminator: Character)
            -> (String, String)? {

            skipWhitespace()
            guard let name = readName()?.lowercased() else { return nil }
            skipWhitespace()
            guard position < text.count, text[position] == "=" else { return nil }
            position += 1

            var value = ""
            while true {
                skipWhitespace()
                guard position < text.count else { break }
                value += readPiece(macros: macros)
                skipWhitespace()
                guard position < text.count, text[position] == "#" else { break }
                position += 1
            }
            return (name, value)
        }

        private mutating func readPiece(macros: [String: String]) -> String {
            guard position < text.count else { return "" }

            if text[position] == "{" {
                return readBraced()
            }
            if text[position] == "\"" {
                position += 1
                var out = ""
                var depth = 0
                while position < text.count {
                    let character = text[position]
                    // A backslash escapes whatever follows. This matters far
                    // more than it looks: \" is the umlaut accent, so without
                    // it a name like "M\"uller" would end the value early and
                    // every field after it in the entry would be lost.
                    if character == "\\", position + 1 < text.count {
                        out.append(character)
                        out.append(text[position + 1])
                        position += 2
                        continue
                    }
                    if character == "{" { depth += 1 }
                    if character == "}" { depth = Swift.max(0, depth - 1) }
                    // A quote inside braces is content, not the terminator.
                    if character == "\"" && depth == 0 { position += 1; break }
                    out.append(character)
                    position += 1
                }
                return out
            }
            // A bare word: either a number or a macro name.
            var word = ""
            while position < text.count, !text[position].isWhitespace,
                  text[position] != ",", text[position] != "}", text[position] != ")",
                  text[position] != "#" {
                word.append(text[position])
                position += 1
            }
            if let expansion = macros[word.lowercased()] { return expansion }
            return word
        }

        /// The contents of a `{…}` group, keeping any nested braces.
        private mutating func readBraced() -> String {
            guard position < text.count, text[position] == "{" else { return "" }
            position += 1
            var out = ""
            var depth = 1
            while position < text.count {
                let character = text[position]
                if character == "\\", position + 1 < text.count {
                    // An escaped brace is content and must not change the depth.
                    out.append(character)
                    out.append(text[position + 1])
                    position += 2
                    continue
                }
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { position += 1; break }
                }
                out.append(character)
                position += 1
            }
            return out
        }

        mutating func skipBalancedBlock() {
            skipWhitespace()
            guard position < text.count, text[position] == "{" else { return }
            _ = readBraced()
        }

        mutating func skipTo(_ terminator: Character) {
            var depth = 0
            while position < text.count {
                let character = text[position]
                if character == "{" { depth += 1 }
                if character == "}" || character == ")" {
                    if depth == 0 && character == terminator { position += 1; return }
                    depth = Swift.max(0, depth - 1)
                }
                position += 1
            }
        }
    }
}

// MARK: - Library

/// A plugin's bibliography: the file it shipped, and the entries read from it.
struct PluginCitationLibrary {

    /// The .bib exactly as the plugin author wrote it. This is what gets
    /// exported — never a re-rendering of the parsed entries.
    let source: String
    let citations: [PluginCitation]
    /// Where it came from, for the export's provenance comment.
    let fileName: String

    var isEmpty: Bool { return citations.isEmpty }

    init?(contentsOf url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.init(source: text, fileName: url.lastPathComponent)
    }

    init?(source: String, fileName: String) {
        let parsed = PluginBibTeXParser.parse(source)
        guard !parsed.isEmpty else { return nil }
        self.source = source
        self.citations = parsed
        self.fileName = fileName
    }

    /// What Export writes: the file verbatim, under a provenance comment.
    /// Comments cannot affect how BibTeX reads the entries, so this preserves
    /// the guarantee that the author's records leave exactly as they arrived.
    func exportText(pluginName: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var header = "% References for the \(pluginName) plugin.\n"
        header += "% Exported verbatim from \(fileName) by 4DSTEM Explorer on "
        header += "\(formatter.string(from: Date())).\n\n"
        return header + source
    }
}
