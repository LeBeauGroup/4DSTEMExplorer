import SwiftUI
import UniformTypeIdentifiers

// MARK: - Menu Commands using direct model calls

struct FourDSTEMMenuCommands: Commands {
    @ObservedObject var model: DataViewModel
    @ObservedObject var openPanel: OpenPanelController
    @ObservedObject var recentFiles: RecentFilesController
    @ObservedObject var pluginManager: PluginManager
    @ObservedObject var pluginRunner: PluginRunner
    @Binding var showDetector:Bool

//      init(model: DataViewModel, openPanel: OpenPanelController) {
//          self.model = model
//          self.openPanel = openPanel
//      }

    var body: some Commands {
        // File menu
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                openPanel.open { url in
                    Task { @MainActor in
                        ExternalFileOpenHandler.openFiles([url], application: .shared)
                    }
                }
            }
            .keyboardShortcut("o")

            Menu("Open Recent") {
                if recentFiles.urls.isEmpty {
                    Button("No Recent Files") { }
                        .disabled(true)
                } else {
                    ForEach(recentFiles.urls, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            Task { @MainActor in
                                ExternalFileOpenHandler.openFiles([url], application: .shared)
                            }
                        }
                    }

                    Divider()

                    Button("Clear Menu") {
                        recentFiles.clear()
                    }
                }
            }

            Menu("Export") {
                Button("Export All…") {
                    model.exportAll()
                }
                .disabled(model.selectedURL == nil)
                Divider()
                Button("Image") {
                    model.export(type: "image")
                }.keyboardShortcut("i").disabled(model.selected == nil)
                Button("Pattern") {
                    model.export(type: "pattern")
                }.keyboardShortcut("p")
                    .disabled(model.selected == nil)
            }

            Divider()

            Button("Calibrate…") {
                model.calibrate()
            }
            .disabled(model.selectedURL == nil)
        }

        // Export menu
        

        // Detector menu
        CommandMenu("Detector") {
            // Shape
            Button("Bright Field") {
                model.detectorShape = .bf
//                model.computeScanImage()
            }
            .keyboardShortcut("1")

            Button("Annular Dark-field") {
                model.detectorShape = .adf
//                model.computeScanImage()
            }
            .keyboardShortcut("2")

            Button("Annular Field") {
                model.detectorShape = .af
//                model.computeScanImage()
            }
            .keyboardShortcut("3")

            Divider()

            // Type
            Button("Integrating") {
                model.calculationMode = .integrate
            }
            .keyboardShortcut("1", modifiers: [.option])


            Button("Center of Mass") {
                model.calculationMode = .com
            }
            .keyboardShortcut("2", modifiers: [.option])
            Button("Differential Phase Contrast") {
                model.calculationMode = .dpc
            }
            .keyboardShortcut("3", modifiers: [.option])

            Divider()

            Button("Show/Hide Detector") {
                showDetector.toggle()
            }
            .keyboardShortcut("/")
        }

        // Image menu
        CommandMenu("Image") {
            Button("Zoom in") {
                NotificationCenter.default.post(
                    name: model.focusedPanel == .image ? .zoomIn : .zoomInPattern, object: nil)
            }
            .keyboardShortcut("+")

            Button("Zoom out") {
                NotificationCenter.default.post(
                    name: model.focusedPanel == .image ? .zoomOut : .zoomOutPattern, object: nil)
            }
            .keyboardShortcut("-")

            Button("Zoom to fit") {
                NotificationCenter.default.post(
                    name: model.focusedPanel == .image ? .zoomToFit : .zoomToFitPattern, object: nil)
            }
            .keyboardShortcut(".")

            Button("Actual size") {
                NotificationCenter.default.post(
                    name: model.focusedPanel == .image ? .zoomToActual : .zoomToActualPattern, object: nil)
            }
            .keyboardShortcut("'")
        }

        // Plugins menu
        CommandMenu("Plugins") {
            if pluginManager.plugins.isEmpty {
                Button("No Plugins Installed") { }
                    .disabled(true)
            } else {
                ForEach(pluginManager.plugins) { plugin in
                    Button(plugin.name) {
                        PluginRunner.shared.run(plugin, model: model)
                    }
                    .disabled(pluginRunner.isRunning || (plugin.requiresData && model.imageWidth == 0))
                    .help(plugin.summary)
                }
            }

            if !pluginManager.issues.isEmpty {
                Divider()
                Menu("Not Loaded (\(pluginManager.issues.count))") {
                    ForEach(pluginManager.issues) { issue in
                        Button("\(issue.bundleName) — \(issue.reason)") {
                            PluginRunner.presentAlert(style: .warning,
                                                      title: issue.bundleName,
                                                      message: issue.reason)
                        }
                    }
                }
            }

            Divider()

            Button("Install Plugin…") {
                installPlugin()
            }

            Button("Reload Plugins") {
                pluginManager.reload()
            }

            Button("Show Plugins Folder") {
                pluginManager.revealUserPluginsDirectory()
            }
        }
    }

    private func installPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType.bundle]
        panel.prompt = "Install"
        panel.message = "Choose a 4DSTEM Explorer plugin bundle"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let problem = pluginManager.install(from: url) {
                PluginRunner.presentAlert(style: .warning,
                                          title: "Could not install \(url.lastPathComponent)",
                                          message: problem)
            }
        }
    }
}

