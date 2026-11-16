import AppKit
import Foundation

@MainActor
struct LiveDocumentPasteboardImporter: DocumentPasteboardImporting {
    func isConcealed(fromPasteboardNamed pasteboardName: String) -> Bool {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        return ClipboardPasteboardReader.containsConcealedType(pasteboard.types?.map(\.rawValue) ?? [])
    }

    func imageData(fromPasteboardNamed pasteboardName: String) -> Data? {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        return pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
    }

    func clearPasteboard(named pasteboardName: String) {
        NSPasteboard(name: NSPasteboard.Name(pasteboardName)).clearContents()
    }
}
