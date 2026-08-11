//
//  BatchDiscovery.swift
//  4DSTEM Explorer
//
//  Finding datasets under a folder, and finding the metadata that goes with them.
//
//  The second half is less obvious than it sounds. A sidecar is *not* reliably
//  named after the file it describes — acquisition software names the raw data
//  for its raster and the metadata for the acquisition, so a folder routinely
//  looks like this:
//
//      scan_x128_y128.raw
//      aq3_10nm_20Mx_calib.json
//      acquisition_20.xml
//
//  Nothing about those three names says they belong together except that they
//  are in the same folder. Matching on a shared stem — the obvious first
//  implementation, and the one this replaced — finds nothing here at all. So the
//  whole directory is considered, in an order that prefers the specific to the
//  merely nearby, and the first candidate that actually parses into something
//  usable wins.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

enum BatchDiscovery {

    /// Extensions the application can open.
    static let openableExtensions: Set<String> = [
        "raw", "dm3", "dm4", "mrc", "emd", "h5", "hdf5", "tif", "tiff"
    ]

    /// Every dataset under `root`, including in subfolders.
    ///
    /// Sorted by path so a batch runs in an order the user can predict and
    /// resume by eye, rather than in whatever order the file system enumerated.
    static func datasets(under root: URL,
                         isCancelled: () -> Bool = { false }) -> [URL] {
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        for case let url as URL in walker {
            if isCancelled() { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            guard openableExtensions.contains(url.pathExtension.lowercased()) else { continue }
            // A TIFF sitting beside a RAW is usually a computed image of that
            // same scan rather than a dataset of its own — `scan_x128_y128.raw`
            // next to `scan_x128_y128_integrate.tif`. Opening it as a dataset
            // would calibrate a picture of the data instead of the data.
            if url.pathExtension.lowercased().hasPrefix("tif"),
               hasSiblingDataset(besides: url) { continue }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func hasSiblingDataset(besides url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return false }
        return names.contains {
            let ext = ($0 as NSString).pathExtension.lowercased()
            return ext == "raw" || ext == "dm3" || ext == "dm4" || ext == "mrc"
        }
    }

    // MARK: Sidecars

    /// Metadata files that might describe `url`, most specific first.
    ///
    /// Same-stem names come first because they are unambiguous. Everything else
    /// in the folder follows, JSON before XML — JSON in this workflow is written
    /// by whoever calibrated the data, XML by the microscope, so where both
    /// exist the JSON is the more considered of the two. Within each kind, names
    /// containing "calib" come first for the same reason.
    static func sidecarCandidates(for url: URL) -> [URL] {
        let stem = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()

        var ordered: [URL] = []
        var seen = Set<String>()
        func add(_ candidate: URL) {
            guard !seen.contains(candidate.path) else { return }
            guard FileManager.default.fileExists(atPath: candidate.path) else { return }
            seen.insert(candidate.path)
            ordered.append(candidate)
        }

        for name in ["\(stem)_calib.json", "\(stem).json"] {
            add(folder.appendingPathComponent(name))
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        func neighbours(extension ext: String) -> [String] {
            return names
                .filter { ($0 as NSString).pathExtension.lowercased() == ext }
                .sorted { lhs, rhs in
                    let l = lhs.lowercased().contains("calib")
                    let r = rhs.lowercased().contains("calib")
                    if l != r { return l }
                    return lhs < rhs
                }
        }
        for name in neighbours(extension: "json") { add(folder.appendingPathComponent(name)) }
        for name in ["\(stem)_calib.xml", "\(stem).xml"] {
            add(folder.appendingPathComponent(name))
        }
        for name in neighbours(extension: "xml") { add(folder.appendingPathComponent(name)) }

        return ordered
    }

    /// The first sidecar that parses into something usable, and what it said.
    ///
    /// Proximity picks the candidates; the sidecar's own record of which file it
    /// describes picks between them. EMPAD JSON carries `raw_filename`, and a
    /// sidecar naming this very file is the end of the argument — it beats any
    /// amount of similarity in the names.
    ///
    /// A recorded name that does *not* match demotes rather than excludes, which
    /// is the case that matters: acquisition XML records the derived images it
    /// wrote — `scan_roi0_sum_circle_x64_y64_r2.tif`, on the microscope's own
    /// paths — and never the raw file. Excluding on a mismatch would throw away
    /// the only sidecar in a folder that has just one.
    ///
    /// - Parameter requiringScanSize: true for a RAW file, which cannot be
    ///   opened at all without a raster, so a sidecar that lacks one is no use
    ///   and the search carries on to the next.
    static func seed(for url: URL, requiringScanSize: Bool)
        -> (source: URL, metadata: ScanMetadata)? {

        let wanted = url.lastPathComponent

        var unnamed: (URL, ScanMetadata)? = nil     // says nothing about which file
        var mismatched: (URL, ScanMetadata)? = nil  // names some other file

        for candidate in sidecarCandidates(for: url) {
            guard let metadata = try? ScanMetadata.read(url: candidate) else { continue }
            if requiringScanSize {
                guard let width = metadata.scanWidth, let height = metadata.scanHeight,
                      width > 0, height > 0 else { continue }
            } else if metadata.isEmpty {
                continue
            }

            // The recorded name may be a full path from another machine, so only
            // the last component is comparable.
            let recorded = metadata.rawFilename
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .flatMap { $0.isEmpty ? nil : $0 }

            guard let recorded = recorded else {
                if unnamed == nil { unnamed = (candidate, metadata) }
                continue
            }
            if recorded.caseInsensitiveCompare(wanted) == .orderedSame {
                return (candidate, metadata)
            }
            if mismatched == nil { mismatched = (candidate, metadata) }
        }
        return unnamed ?? mismatched
    }

    /// Where a measured calibration goes.
    ///
    /// `_calib.json` when that name is free. When it is not — which is precisely
    /// when a sidecar seeded the measurement — `_calib.measured.json`, because
    /// the file this would replace is the one a bad measurement would destroy,
    /// and having the two side by side is what makes a bad one noticeable.
    static func destination(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let preferred = folder.appendingPathComponent("\(stem)_calib.json")
        if !FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        return folder.appendingPathComponent("\(stem)_calib.measured.json")
    }

    /// The calibration a sidecar describes.
    static func calibrations(from metadata: ScanMetadata) -> Calibrations {
        return Calibrations(
            scan_step: metadata.scanStepNanometres,
            diff_step: metadata.diffractionStepMilliradians,
            voltage: metadata.voltageKilovolts,
            scanRotationDegrees: metadata.scanRotationDegrees,
            scanCorrection: metadata.scanCorrectionRowMajor.flatMap { ScanCorrection(rowMajor: $0) },
            detectorFlips: metadata.detectorFlips.flatMap { DetectorFlips(triple: $0) })
    }

    /// Whether a file can be opened without asking the user anything.
    ///
    /// Only RAW cannot describe itself. Its raster comes from a sidecar or from
    /// the `scan_x180_y180` convention in the name — and from nothing else,
    /// because a guessed raster reads the file as a perfectly valid dataset of
    /// the wrong shape and nothing downstream can tell.
    static func canOpenUnattended(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "raw" else { return true }
        if ScanMetadata.dimensions(fromFilename: url.lastPathComponent) != nil { return true }
        return seed(for: url, requiringScanSize: true) != nil
    }
}
