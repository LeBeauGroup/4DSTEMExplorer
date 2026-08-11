//
//  FileMaterializer.swift
//  4DSTEM Explorer
//
//  Waiting for a file to actually be on this machine before trying to read it.
//
//  A file in iCloud Drive, or in any folder with "Optimise Mac Storage" turned
//  on, may be a placeholder: the name and the size are there, the bytes are not.
//  Reading one is not an error — the system quietly fetches it first — but it
//  fetches it *synchronously*, inside whatever call touched the file. A
//  multi-gigabyte 4D dataset therefore turns a single `Data(contentsOf:)` into a
//  download of several minutes with no progress, no cancellation and, if that
//  call was made on the main thread, no user interface either.
//
//  So the download is done deliberately and up front instead: ask for it, watch
//  it, report how far it has got, and let the user give up. By the time the
//  reader opens the file the bytes are local and the read is as fast as any
//  other.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation

/// A flag one thread sets and another reads.
///
/// Small enough to be worth writing out rather than reaching for a framework:
/// the download loop needs to see a cancellation the instant the button is
/// pressed, and the button is on a different thread.
final class LoadCancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

enum FileMaterializer {

    enum Failure: LocalizedError {
        case cancelled
        case downloadFailed(name: String, underlying: String?)
        case stalled(name: String, seconds: Int)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Cancelled."
            case .downloadFailed(let name, let underlying):
                return "\(name) could not be downloaded."
                    + (underlying.map { " \($0)" } ?? "")
            case .stalled(let name, let seconds):
                return "\(name) has not downloaded any further in \(seconds) seconds. Check the network, or look at the file in Finder to see what the sync client thinks is happening."
            }
        }
    }

    /// What a file's local availability is right now.
    struct Availability {
        /// The bytes are not on this machine yet.
        var isRemote: Bool
        /// How much of the file is on disk, 0…1, or nil when the provider will
        /// not say how large the file is until it has fetched it.
        var fractionLocal: Double?
        /// iCloud Drive, Dropbox, Google Drive, OneDrive… for the status line.
        var provider: String
        /// True when the proper iCloud API can be used to ask for the download.
        var isICloud: Bool
        /// Whether the provider will report how far along it is.
        ///
        /// False for Dropbox, measured: `st_size` stays at zero for the whole
        /// download and jumps to the full length at the end, so any percentage
        /// derived from it would read 0% for eighty seconds and then 100%. An
        /// indeterminate bar is the honest display.
        var reportsProgress: Bool = true
    }

    /// Whether this file still has to be fetched, and how far along it is.
    ///
    /// Everything here comes from `stat`, deliberately. Reading a placeholder is
    /// what triggers the download, so a function whose job is to find out
    /// whether a download is needed must not perform one to answer. `stat` does
    /// not materialise.
    ///
    /// `SF_DATALESS` is the flag that matters. It is set on any placeholder the
    /// File Provider machinery manages — Dropbox, Google Drive, OneDrive, Box
    /// and iCloud alike — whereas `isUbiquitousItem` is true only for iCloud and
    /// reads as nil for every third-party provider. Keying off the iCloud flag
    /// alone, which is what this did first, silently classified every
    /// online-only Dropbox and Drive file as already local.
    static func availability(of url: URL) -> Availability {
        let path = url.path
        let provider = providerName(for: url)

        var status = stat()
        guard lstat(path, &status) == 0 else {
            return Availability(isRemote: false, fractionLocal: 1, provider: provider, isICloud: false)
        }

        let dataless = (status.st_flags & UInt32(SF_DATALESS)) != 0
        let logical = Int64(status.st_size)
        let onDisk = Int64(status.st_blocks) * 512
        let fraction: Double? = logical > 0 ? min(1, max(0, Double(onDisk) / Double(logical))) : nil

        // Dropbox's legacy sync engine, which is not a File Provider at all.
        //
        // Its online-only files sit on the ordinary volume with `SF_DATALESS`
        // clear, `isUbiquitousItem` nil, `st_size` **0**, and a private
        // `com.dropbox.placeholder` extended attribute. Every generic signal
        // therefore reads "an empty local file" — which is exactly what the
        // application would then try to open, so the user would be told the
        // dimensions were wrong rather than that the file had not arrived.
        //
        // The attribute is the only thing that distinguishes the two. Nothing
        // here reads the file, so probing still does not trigger a download.
        //
        // Deliberately *not* an early return. Dropbox is migrating accounts to
        // its File Provider extension, and there is no guarantee a migrated file
        // stops carrying the attribute. What decides whether progress can be
        // reported is whether the file admits its own size, not which engine
        // wrote the attribute — so the size is what is tested, and a migrated
        // placeholder gets a percentage instead of being pinned to the
        // no-progress path by a leftover marker.
        let isDropboxPlaceholder = hasExtendedAttribute("com.dropbox.placeholder", at: path)
        if isDropboxPlaceholder {
            return Availability(isRemote: true,
                                // No size means no honest percentage; a size
                                // means one, whichever engine left the marker.
                                fractionLocal: logical == 0 ? nil : (fraction ?? 0),
                                provider: "Dropbox",
                                isICloud: false,
                                reportsProgress: logical != 0)
        }

        // iCloud additionally reports a downloading status, which is more
        // authoritative than the flag for the "downloaded but stale" case.
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        let isICloud = values?.isUbiquitousItem == true
        if isICloud, let downloadStatus = values?.ubiquitousItemDownloadingStatus,
           downloadStatus != .current {
            return Availability(isRemote: true, fractionLocal: fraction ?? 0,
                                provider: provider, isICloud: true)
        }

        return Availability(isRemote: dataless,
                            fractionLocal: dataless ? (fraction ?? 0) : 1,
                            provider: provider, isICloud: isICloud)
    }

    /// Whether a named extended attribute is present, without reading the file.
    private static func hasExtendedAttribute(_ name: String, at path: String) -> Bool {
        return path.withCString { cPath in
            name.withCString { cName in
                getxattr(cPath, cName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
            }
        }
    }

    /// Bytes actually on disk, which grows as a fetch proceeds.
    private static func bytesOnDisk(_ url: URL) -> Int64 {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return 0 }
        return max(Int64(status.st_size), Int64(status.st_blocks) * 512)
    }

    /// Which service is holding the file, from where it lives.
    ///
    /// There is no API that names the provider for an arbitrary URL, but since
    /// macOS 12 every File Provider mount lives under `~/Library/CloudStorage`
    /// as `Provider-Account`, which is enough to say "Google Drive" rather than
    /// "the cloud" in a status line.
    static func providerName(for url: URL) -> String {
        let path = url.path
        if path.contains("/Library/Mobile Documents/") { return "iCloud" }
        if let range = path.range(of: "/Library/CloudStorage/") {
            let rest = path[range.upperBound...]
            let mount = rest.prefix { $0 != "/" }
            let vendor = mount.prefix { $0 != "-" }
            switch vendor.lowercased() {
            case "googledrive": return "Google Drive"
            case "onedrive":    return "OneDrive"
            case "dropbox":     return "Dropbox"
            case "box":         return "Box"
            default:            return vendor.isEmpty ? "the cloud" : String(vendor)
            }
        }
        if path.contains("Dropbox") { return "Dropbox" }
        return "the cloud"
    }

    /// Blocks until `url` is on this machine.
    ///
    /// Returns immediately for an ordinary local file, so callers do not have to
    /// ask first. Call this off the main thread — the whole point is that it
    /// waits.
    ///
    /// - Parameters:
    ///   - progress: fraction downloaded and a line to show, on an unspecified
    ///     thread. The caller marshals it wherever it needs to go.
    static func ensureLocal(_ url: URL,
                            token: LoadCancellationToken,
                            progress: @escaping (Double?, String) -> Void) throws {

        let name = url.lastPathComponent
        var state = availability(of: url)
        guard state.isRemote else { return }
        let provider = state.provider


        // Ask for it.
        //
        // iCloud has an explicit API. Everything else is fetched by *coordinated*
        // access — `NSFileCoordinator` announces to whatever sync client owns the
        // file that a read is about to happen, and the client materialises it
        // before granting access. This is not the same as simply reading: a plain
        // `read()` on a Dropbox placeholder succeeds, returns zero bytes and
        // triggers nothing, which was measured on a real one before this was
        // written the right way.
        //
        // Coordination blocks for the whole download — eighty-one seconds for a
        // 2.2 GB file on a fast connection — which is precisely why none of this
        // may run on the main thread.
        let coordinator = NSFileCoordinator()
        let finished = DispatchSemaphore(value: 0)
        var coordinationError: NSError?

        if state.isICloud {
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
            } catch {
                throw Failure.downloadFailed(name: name, underlying: error.localizedDescription)
            }
        }

        // On its own thread, so this one stays free to report progress and to
        // notice a cancellation while the coordinated read is blocked.
        let fetch = Thread {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { granted in
                // The access is the trigger; one byte is enough to make it real.
                if let handle = try? FileHandle(forReadingFrom: granted) {
                    _ = try? handle.read(upToCount: 1)
                    try? handle.close()
                }
            }
            finished.signal()
        }
        fetch.qualityOfService = .userInitiated
        fetch.start()

        progress(state.fractionLocal, "Downloading \(name) from \(provider)…")

        // A stall is worth reporting only where there is something to watch. A
        // provider that reveals nothing until it has finished — Dropbox holds
        // `st_size` at zero throughout — would otherwise be declared stalled
        // every time it took longer than the limit, which is exactly when the
        // user least wants to be told to give up.
        let watchable = state.reportsProgress
        let stallLimit: TimeInterval = 120
        var lastProgressAt = Date()
        var lastFraction = state.fractionLocal ?? 0
        let started = Date()

        while finished.wait(timeout: .now() + 0.25) == .timedOut {
            if token.isCancelled {
                // Aborts the pending coordination, so the thread above returns
                // rather than being left blocked for the rest of the download.
                coordinator.cancel()
                throw Failure.cancelled
            }

            state = availability(of: url)
            if state.isICloud {
                let probe = URL(fileURLWithPath: url.path)
                if let values = try? probe.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]),
                   let error = values.ubiquitousItemDownloadingError {
                    coordinator.cancel()
                    throw Failure.downloadFailed(name: name, underlying: error.localizedDescription)
                }
            }

            if let fraction = state.fractionLocal, watchable {
                if fraction > lastFraction + 0.0005 {
                    lastFraction = fraction
                    lastProgressAt = Date()
                } else if Date().timeIntervalSince(lastProgressAt) > stallLimit {
                    coordinator.cancel()
                    throw Failure.stalled(name: name, seconds: Int(stallLimit))
                }
                progress(fraction, String(format: "Downloading %@ from %@… %.0f%%",
                                          name, provider, fraction * 100))
            } else {
                // Nothing to show but that it is still going, so show that.
                let elapsed = Int(Date().timeIntervalSince(started))
                progress(nil, String(format: "Downloading %@ from %@… %d:%02d",
                                     name, provider, elapsed / 60, elapsed % 60))
            }
        }

        if let error = coordinationError {
            throw Failure.downloadFailed(name: name, underlying: error.localizedDescription)
        }
        if token.isCancelled { throw Failure.cancelled }

        progress(1, "Opening \(name)…")
    }

}
