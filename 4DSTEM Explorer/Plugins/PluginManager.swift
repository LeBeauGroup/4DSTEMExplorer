//
//  PluginManager.swift
//  4DSTEM Explorer
//
//  Discovery and loading of `.bundle` plugins.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import AppKit

/// A plugin bundle that loaded successfully, with its metadata already read so
/// the menu can be built without touching the plugin again.
final class LoadedPlugin: Identifiable {
    let identifier: String
    let name: String
    let summary: String
    let parameters: [[String: Any]]
    let requiresData: Bool
    let bundleURL: URL
    let instance: FDSPlugin

    var id: String { identifier }

    init(instance: FDSPlugin, bundleURL: URL) {
        self.instance = instance
        self.bundleURL = bundleURL
        self.identifier = instance.pluginIdentifier
        self.name = instance.pluginName
        self.summary = instance.pluginSummary ?? ""
        self.parameters = instance.pluginParameters ?? []
        self.requiresData = instance.pluginRequiresData ?? true
    }
}

/// Why a bundle in a plugins folder did not become a usable plugin. Surfaced in
/// the Plugins menu so a failed install is visible rather than silent.
struct PluginLoadIssue: Identifiable {
    let id = UUID()
    let bundleName: String
    let reason: String
}

final class PluginManager: ObservableObject {

    static let shared = PluginManager()

    @Published private(set) var plugins: [LoadedPlugin] = []
    @Published private(set) var issues: [PluginLoadIssue] = []

    /// Bundles already handed to `Bundle.load()`. Code cannot be unloaded, so a
    /// reload re-instantiates the principal class rather than reloading images.
    private var loadedBundleURLs: Set<URL> = []

    private init() {}

    // MARK: - Locations

    /// Where users drop plugins. Under the App Sandbox this resolves inside the
    /// app's container, which the app can read without a security scope.
    static var userPluginsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("4DSTEM Explorer", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)
    }

    /// Plugins shipped inside the app itself.
    static var builtInPluginsDirectory: URL? {
        return Bundle.main.builtInPlugInsURL
    }

    @discardableResult
    static func createUserPluginsDirectoryIfNeeded() -> Bool {
        let url = userPluginsDirectory
        if FileManager.default.fileExists(atPath: url.path) { return true }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            return true
        } catch {
            NSLog("[Plugins] Could not create %@: %@", url.path, error.localizedDescription)
            return false
        }
    }

    func revealUserPluginsDirectory() {
        PluginManager.createUserPluginsDirectoryIfNeeded()
        NSWorkspace.shared.activateFileViewerSelecting([PluginManager.userPluginsDirectory])
    }

    // MARK: - Loading

    func reload() {
        var found: [LoadedPlugin] = []
        var problems: [PluginLoadIssue] = []
        var seenIdentifiers: Set<String> = []

        PluginManager.createUserPluginsDirectoryIfNeeded()

        var searchPaths: [URL] = []
        if let builtIn = PluginManager.builtInPluginsDirectory { searchPaths.append(builtIn) }
        searchPaths.append(PluginManager.userPluginsDirectory)

        for directory in searchPaths {
            for bundleURL in PluginManager.bundleURLs(in: directory) {
                switch load(bundleURL: bundleURL) {
                case .success(let plugin):
                    // A user-installed plugin shadows a built-in with the same
                    // identifier; search paths are visited built-in first.
                    if seenIdentifiers.contains(plugin.identifier) {
                        found.removeAll { $0.identifier == plugin.identifier }
                    }
                    seenIdentifiers.insert(plugin.identifier)
                    found.append(plugin)
                case .failure(let reason):
                    problems.append(PluginLoadIssue(bundleName: bundleURL.lastPathComponent, reason: reason))
                }
            }
        }

        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let result = found
        let resultIssues = problems
        if Thread.isMainThread {
            plugins = result
            issues = resultIssues
        } else {
            DispatchQueue.main.async {
                self.plugins = result
                self.issues = resultIssues
            }
        }
    }

    private static func bundleURLs(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.pathExtension.lowercased() == "bundle" || $0.pathExtension.lowercased() == "plugin" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private enum LoadOutcome {
        case success(LoadedPlugin)
        case failure(String)
    }

    private func load(bundleURL: URL) -> LoadOutcome {
        guard let bundle = Bundle(url: bundleURL) else {
            return .failure("Not a readable bundle.")
        }

        if !bundle.isLoaded {
            do {
                // `loadAndReturnError` reports code-signing rejections, which
                // `load()` reduces to a bare false.
                try bundle.loadAndReturnError()
            } catch {
                return .failure(PluginManager.describe(loadError: error))
            }
        }
        loadedBundleURLs.insert(bundleURL)

        guard let principalClass = bundle.principalClass else {
            return .failure("No NSPrincipalClass in Info.plist, or the class is missing from the binary.")
        }
        guard let objectClass = principalClass as? NSObject.Type else {
            return .failure("Principal class \(NSStringFromClass(principalClass)) is not an NSObject subclass.")
        }

        let instance = objectClass.init()
        guard let plugin = instance as? FDSPlugin else {
            return .failure("Principal class \(NSStringFromClass(principalClass)) does not conform to FDSPlugin.")
        }

        let declaredVersion = plugin.pluginAPIVersion ?? 1
        guard declaredVersion <= FDSPluginAPIVersion else {
            return .failure("Built against plugin API \(declaredVersion); this app supports up to \(FDSPluginAPIVersion).")
        }

        guard !plugin.pluginIdentifier.isEmpty, !plugin.pluginName.isEmpty else {
            return .failure("Plugin must provide a non-empty identifier and name.")
        }

        return .success(LoadedPlugin(instance: plugin, bundleURL: bundleURL))
    }

    private static func describe(loadError error: Error) -> String {
        let nsError = error as NSError
        // Hardened runtime rejects differently-signed code unless the app
        // carries com.apple.security.cs.disable-library-validation.
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSExecutableLoadError {
            return "The system refused to load the plugin's code. It may be built for another architecture, or signed by a team this app is not allowed to load. (\(nsError.localizedDescription))"
        }
        return nsError.localizedDescription
    }

    // MARK: - Installing

    /// Copies a plugin the user picked into the plugins folder and reloads.
    /// Returns an error message on failure.
    func install(from sourceURL: URL) -> String? {
        guard sourceURL.pathExtension.lowercased() == "bundle" || sourceURL.pathExtension.lowercased() == "plugin" else {
            return "\(sourceURL.lastPathComponent) is not a plugin bundle."
        }
        guard PluginManager.createUserPluginsDirectoryIfNeeded() else {
            return "Could not create the plugins folder."
        }

        let destination = PluginManager.userPluginsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            return error.localizedDescription
        }

        reload()

        if plugins.contains(where: { $0.bundleURL.lastPathComponent == destination.lastPathComponent }) {
            return nil
        }
        if let issue = issues.first(where: { $0.bundleName == destination.lastPathComponent }) {
            return issue.reason
        }
        // A bundle whose code was already loaded this session keeps the old
        // binary; replacing it needs a fresh launch.
        return "Installed, but the previous version of this plugin is still loaded. Quit and reopen 4DSTEM Explorer to use the new one."
    }
}
