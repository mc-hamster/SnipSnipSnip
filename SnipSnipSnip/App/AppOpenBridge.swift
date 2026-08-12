import AppKit
import Foundation

extension Notification.Name {
    static let sssPendingDocumentURLsDidChange = Notification.Name("sssPendingDocumentURLsDidChange")
    static let sssPendingPasteboardImageImportsDidChange = Notification.Name("sssPendingPasteboardImageImportsDidChange")
    static let sssPendingAutomationRequestsDidChange = Notification.Name("sssPendingAutomationRequestsDidChange")
    static let sssOpenMainWindowRequest = Notification.Name("sssOpenMainWindowRequest")
    static let sssToggleEditorInspector = Notification.Name("sssToggleEditorInspector")
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

@MainActor
enum PendingAutomationRequests {
    private static var requests: [AutomationRequest] = []

    static func enqueue(_ request: AutomationRequest) {
        requests.append(request)
        NotificationCenter.default.post(name: .sssOpenMainWindowRequest, object: nil)
        NotificationCenter.default.post(name: .sssPendingAutomationRequestsDidChange, object: nil)
    }

    static func drain() -> [AutomationRequest] {
        let drained = requests
        requests.removeAll()
        return drained
    }
}

enum AppImportURL {
    nonisolated static let scheme = "snipsnipsnip"
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

nonisolated enum AppLifecyclePreferenceKeys {
    static let confirmsBeforeQuitting = "SSSConfirmsBeforeQuitting"
}

enum AppCloseShortcutDisposition: Equatable {
    case miniaturize
    case orderOut
    case hideApplication
}

@MainActor
enum AppCommandWClosePolicy {
    static func shouldClose(_ window: NSWindow?) -> Bool {
        ClipboardManagerWindowID.isClipboardManagerWindow(window)
            || ScreenInspectorWindowID.isScreenInspectorWindow(window)
            || ScreenRulerWindowID.isScreenRulerWindow(window)
    }
}

@MainActor
enum NativePanelShortcutPolicy {
    static func suspendsCaptureKeyEquivalents(for window: NSWindow?) -> Bool {
        window is NSOpenPanel || window is NSSavePanel
    }
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppTerminationController.shared.applicationShouldTerminate()
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
            } else if let request = AutomationURLRouter.request(from: url) {
                PendingAutomationRequests.enqueue(request)
            } else if url.isFileURL {
                fileURLs.append(url)
            }
        }

        PendingDocumentOpenRequests.enqueue(fileURLs)
    }

    static func handleCloseShortcut() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        switch closeShortcutDisposition(for: window?.styleMask) {
        case .miniaturize:
            window?.miniaturize(nil)
        case .orderOut:
            window?.orderOut(nil)
        case .hideApplication:
            NSApp.hide(nil)
        }
    }

    static func closeShortcutDisposition(for styleMask: NSWindow.StyleMask?) -> AppCloseShortcutDisposition {
        guard let styleMask else {
            return .hideApplication
        }
        return styleMask.contains(.miniaturizable) ? .miniaturize : .orderOut
    }

    private func handleWindowShortcut(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard modifiers == [.command],
              let shortcut = event.charactersIgnoringModifiers?.lowercased(),
              shortcut == "w" || shortcut == "q" else {
            return event
        }

        let activeWindow = NSApp.keyWindow ?? NSApp.mainWindow
        if shortcut == "w", AppCommandWClosePolicy.shouldClose(activeWindow) {
            activeWindow?.performClose(nil)
            return nil
        }

        if shortcut == "q" {
            Task { @MainActor in
                AppTerminationController.shared.requestQuit()
            }
        } else {
            Self.handleCloseShortcut()
        }
        return nil
    }
}
