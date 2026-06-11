import AppKit
import Foundation

extension Notification.Name {
    static let sssPendingDocumentURLsDidChange = Notification.Name("sssPendingDocumentURLsDidChange")
    static let sssPendingPasteboardImageImportsDidChange = Notification.Name("sssPendingPasteboardImageImportsDidChange")
    static let sssOpenMainWindowRequest = Notification.Name("sssOpenMainWindowRequest")
}

@MainActor
enum PendingDocumentOpenRequests {
    private static var urls: [URL] = []

    static func enqueue(_ newURLs: [URL]) {
        guard !newURLs.isEmpty else {
            return
        }

        urls.append(contentsOf: newURLs)
        NotificationCenter.default.post(name: .sssOpenMainWindowRequest, object: nil)
        NotificationCenter.default.post(name: .sssPendingDocumentURLsDidChange, object: nil)
    }

    static func drain() -> [URL] {
        let drained = urls
        urls.removeAll()
        return drained
    }
}

@MainActor
enum PendingPasteboardImageImportRequests {
    struct Request: Equatable {
        let pasteboardName: String
        let sourceName: String?
    }

    private static var requests: [Request] = []

    static func enqueue(_ request: Request) {
        requests.append(request)
        NotificationCenter.default.post(name: .sssOpenMainWindowRequest, object: nil)
        NotificationCenter.default.post(name: .sssPendingPasteboardImageImportsDidChange, object: nil)
    }

    static func drain() -> [Request] {
        let drained = requests
        requests.removeAll()
        return drained
    }
}

enum AppImportURL {
    static let scheme = "snipsnipsnip"
    static let pasteboardImportHost = "import-pasteboard"
    static let pasteboardNameQueryItem = "name"
    static let sourceNameQueryItem = "source"

    static func pasteboardImportURL(pasteboardName: String, sourceName: String?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = pasteboardImportHost
        components.queryItems = [
            URLQueryItem(name: pasteboardNameQueryItem, value: pasteboardName),
            URLQueryItem(name: sourceNameQueryItem, value: sourceName)
        ]
        return components.url
    }

    static func pasteboardImportRequest(from url: URL) -> PendingPasteboardImageImportRequests.Request? {
        guard url.scheme == scheme, url.host == pasteboardImportHost else {
            return nil
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let pasteboardName = queryItems.first(where: { $0.name == pasteboardNameQueryItem })?.value,
              !pasteboardName.isEmpty else {
            return nil
        }

        let sourceName = queryItems.first(where: { $0.name == sourceNameQueryItem })?.value
        return PendingPasteboardImageImportRequests.Request(pasteboardName: pasteboardName, sourceName: sourceName)
    }
}

enum AppLifecyclePreferenceKeys {
    static let confirmsBeforeQuitting = "SSSConfirmsBeforeQuitting"
}

@MainActor
final class AppOpenBridge: NSObject, NSApplicationDelegate {
    private var localEventMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        NSApp?.applicationIconImage = icon
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleWindowShortcut(event) ?? event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let localEventMonitor else {
            return
        }

        NSEvent.removeMonitor(localEventMonitor)
        self.localEventMonitor = nil
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        PendingDocumentOpenRequests.enqueue([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        PendingDocumentOpenRequests.enqueue(filenames.map(URL.init(fileURLWithPath:)))
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        var fileURLs: [URL] = []

        for url in urls {
            if let request = AppImportURL.pasteboardImportRequest(from: url) {
                PendingPasteboardImageImportRequests.enqueue(request)
            } else if url.isFileURL {
                fileURLs.append(url)
            }
        }

        PendingDocumentOpenRequests.enqueue(fileURLs)
    }

    static func minimizeActiveWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return
        }

        window.performMiniaturize(nil)
    }

    private func handleWindowShortcut(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard modifiers == [.command],
              let shortcut = event.charactersIgnoringModifiers?.lowercased(),
              shortcut == "w" || shortcut == "q" else {
            return event
        }

        if shortcut == "w", ClipboardManagerWindowID.isClipboardManagerWindow(NSApp.keyWindow) {
            NSApp.keyWindow?.performClose(nil)
            return nil
        }

        Self.minimizeActiveWindow()
        return nil
    }
}
