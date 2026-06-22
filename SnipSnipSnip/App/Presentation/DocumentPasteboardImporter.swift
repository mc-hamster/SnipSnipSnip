import AppKit
import Foundation

@MainActor
struct LiveDocumentPasteboardImporter: DocumentPasteboardImporting {
    func imageData(fromPasteboardNamed pasteboardName: String) -> Data? {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        return pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
    }

    func clearPasteboard(named pasteboardName: String) {
        NSPasteboard(name: NSPasteboard.Name(pasteboardName)).clearContents()
    }
}
