import AppKit
import Foundation

extension Notification.Name {
    static let sssPendingDocumentURLsDidChange = Notification.Name("sssPendingDocumentURLsDidChange")
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
final class AppOpenBridge: NSObject, NSApplicationDelegate {
    private var localEventMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        NSApp?.applicationIconImage = icon
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleMinimizeShortcut(event) ?? event
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

    private func handleMinimizeShortcut(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "w" else {
            return event
        }

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return event
        }

        window.performMiniaturize(nil)
        return nil
    }
}
