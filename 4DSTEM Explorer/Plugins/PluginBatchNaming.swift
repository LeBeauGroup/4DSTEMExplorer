//
//  PluginBatchNaming.swift
//  4DSTEM Explorer
//
//  Where a batch's results land, and which files it can run without asking.
//
//  Separate from the runner because none of it needs a data controller, a plugin
//  or a window: it is string and file-system logic that decides the shape of
//  every batch on disk, and that is worth being able to test on its own.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

enum PluginBatchNaming {

    /// A folder per input file, named after it.
    static func folderName(for url: URL) -> String {
        return safeName(url.deletingPathExtension().lastPathComponent)
    }

    /// A filename component that cannot escape the folder it belongs in.
    ///
    /// Dataset names come from plugins and file names from the user, so neither
    /// is trusted to be a legal path component. A name that reduces to nothing —
    /// `...` does — becomes `output`, because an empty component would silently
    /// write into the results root instead of a subfolder of it.
    static func safeName(_ text: String) -> String {
        let cleaned = text.map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            if character == "-" || character == "_" || character == "." { return character }
            return "_"
        }
        let joined = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return joined.isEmpty ? "output" : joined
    }

    /// Parameter dictionaries hold `NSNumber` and `String`, which serialise, but
    /// a plugin may put anything in one. Anything that will not serialise is
    /// described rather than dropped, so the record still says what was set
    /// instead of quietly omitting the setting that mattered.
    static func jsonSafe(_ dictionary: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in dictionary {
            if JSONSerialization.isValidJSONObject([key: value]) {
                out[key] = value
            } else {
                out[key] = String(describing: value)
            }
        }
        return out
    }

    /// The sidecars a RAW file's raster might be written in, in the order they
    /// are worth trying.
    static func sidecarCandidates(for url: URL) -> [URL] {
        let stem = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        return ["\(stem)_calib.json", "\(stem).json", "\(stem).xml", "\(stem)_calib.xml"]
            .map { folder.appendingPathComponent($0) }
    }

    /// Whether a RAW file's raster can be established without asking anyone.
    ///
    /// A batch cannot put up the dimensions panel, and it must not guess: a
    /// guessed raster reads the file as a perfectly valid dataset of the wrong
    /// shape, and nothing downstream can tell. Either a sidecar says, or the
    /// `scan_x180_y180` convention in the name does, or the file is skipped.
    static func rawIsSizeable(_ url: URL) -> Bool {
        if ScanMetadata.dimensions(fromFilename: url.lastPathComponent) != nil { return true }
        for candidate in sidecarCandidates(for: url) {
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let metadata = try? ScanMetadata.read(url: candidate),
                  let width = metadata.scanWidth, let height = metadata.scanHeight,
                  width > 0, height > 0 else { continue }
            return true
        }
        return false
    }
}
