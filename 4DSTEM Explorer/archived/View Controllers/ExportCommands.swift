import SwiftUI

// Commands that can be added to your SwiftUI App to expose Image/Pattern export
// via menus and can be bound to toolbar dropdown handlers.

struct ExportCommands: Commands {
    @EnvironmentObject var exportVM: ExportViewModel

    var body: some Commands {
        CommandMenu("Export") {
            Button("Export Image…") { exportVM.exportImage() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export Pattern…") { exportVM.exportPattern() }
        }
    }
}
