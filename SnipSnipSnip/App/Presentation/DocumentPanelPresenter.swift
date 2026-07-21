import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
struct LiveDocumentPanelPresenter: DocumentPanelPresenting {
    func selectDocumentToOpen() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.snipSnipDocument, .snipSnipVideoDocument, .snipSnipGuideDocument]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }

    func selectImageToImport() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }

    func selectPresentationScenesRoot(initialDirectory: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory
        panel.prompt = "Use Scenes Folder"

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }

    func selectSaveDestination(suggestedFilename: String, contentType: UTType) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFilename

        return await ImageExporter.presentSavePanel(panel)
    }

    func selectExportDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Guide"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func copyExportedFiles(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    func shareExportedFiles(_ urls: [URL]) {
        guard let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else { return }
        NSSharingServicePicker(items: urls).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}
