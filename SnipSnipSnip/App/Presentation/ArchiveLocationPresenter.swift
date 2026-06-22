import AppKit
import Foundation

@MainActor
struct LiveArchiveLocationPresenter: ArchiveLocationPresenting {
    func selectArchiveLocation(initialDirectory: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory
        panel.prompt = "Use Location"

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }
}
