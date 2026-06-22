import AppKit
import Combine
import Foundation

@MainActor
protocol ClipboardIgnoredAppPresenting {
    func selectIgnoredClipboardApp() -> ClipboardIgnoredApp?
}

@MainActor
protocol ClipboardManagerPresenting: AnyObject {
    func showClipboardManager(
        clipboard: ClipboardWorkflowModel,
        workspace: any WorkspaceServicing,
        bundleIdentifier: String?
    )
    func activatePreviousApplicationForPaste()
}

@MainActor
struct ClipboardWorkflowDependencies {
    let systemServices: AppSystemServices
    let ignoredAppPresenter: any ClipboardIgnoredAppPresenting
    let managerPresenter: any ClipboardManagerPresenting
}

@MainActor
final class ClipboardWorkflowModel: ObservableObject, ClipboardAutomationPort {
    let dependencies: ClipboardWorkflowDependencies
    let historyStore: ClipboardHistoryStore
    let monitor: ClipboardMonitor
    weak var outputSink: (any WorkflowOutputSink)?
    weak var documents: (any ClipboardDocumentWorkflowPort)?
    private let pasteboard: any PasteboardServicing
    let preferenceStore: ClipboardPreferenceStore
    @Published var autoCopyEnabled: Bool {
        didSet {
            preferenceStore.saveAutoCopyEnabled(autoCopyEnabled)
            outputSink?.handle(.autoCopyChanged(autoCopyEnabled))
        }
    }
    @Published var preferences: ClipboardPreferences {
        didSet {
            let sanitizedPreferences = preferences.sanitized()
            if sanitizedPreferences != preferences {
                preferences = sanitizedPreferences
                return
            }

            preferenceStore.savePreferences(preferences)
            monitor.update(preferences: preferences)
            historyStore.prune(using: preferences)
        }
    }
    @Published var searchQuery = ""
    @Published var filter: ClipboardItemFilter = .all

    init(
        dependencies: ClipboardWorkflowDependencies,
        historyStore: ClipboardHistoryStore,
        monitor: ClipboardMonitor,
        pasteboard: any PasteboardServicing,
        preferenceStore: ClipboardPreferenceStore
    ) {
        self.dependencies = dependencies
        self.historyStore = historyStore
        self.monitor = monitor
        self.pasteboard = pasteboard
        self.preferenceStore = preferenceStore
        self.autoCopyEnabled = preferenceStore.loadAutoCopyEnabled()
        self.preferences = preferenceStore.loadPreferences()
    }

    var items: [ClipboardItem] {
        historyStore.items
    }

    func copyItem(_ item: ClipboardItem, plainTextOnly: Bool = false) {
        writeItemToPasteboard(item, plainTextOnly: plainTextOnly)
    }

    func copyItemAsPlainText(_ item: ClipboardItem) {
        guard item.supportsPlainTextSanitization else {
            return
        }

        writeItemToPasteboard(item, plainTextOnly: true)
    }

    func pasteItem(
        _ item: ClipboardItem,
        plainTextOnly: Bool = false,
        activatePreviousApplication: @MainActor () -> Void,
        sendPasteKeystroke: @escaping @MainActor () -> Void
    ) {
        if plainTextOnly {
            guard item.supportsPlainTextSanitization else {
                return
            }
        }

        writeItemToPasteboard(item, plainTextOnly: plainTextOnly)
        activatePreviousApplication()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            Task { @MainActor in
                sendPasteKeystroke()
            }
        }
    }

    private func writeItemToPasteboard(_ item: ClipboardItem, plainTextOnly: Bool) {
        if plainTextOnly, item.plainTextValue == nil {
            return
        }

        pasteboard.clearContents()

        if plainTextOnly, let text = item.plainTextValue {
            pasteboard.setString(text, forType: .string)
            monitor.markCurrentPasteboardChangeAsHandled()
            return
        }

        switch item.kind {
        case let .text(text), let .link(text):
            pasteboard.setString(text, forType: .string)
        case let .fileURLs(paths):
            pasteboard.writeFileURLs(paths.map { URL(fileURLWithPath: $0) })
        case .image, .snip:
            if let data = historyStore.dataForPasteboard(for: item) {
                pasteboard.setData(data, forType: .png)
            }
        }

        monitor.markCurrentPasteboardChangeAsHandled()
    }

    func markAutomationPasteboardChangeAsHandled() {
        monitor.markCurrentPasteboardChangeAsHandled()
    }
}
