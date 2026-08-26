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
        presentationContext: WorkflowPresentationContext
    )
}

extension ClipboardManagerPresenting {
    func showClipboardManager(clipboard: ClipboardWorkflowModel) {
        showClipboardManager(
            clipboard: clipboard,
            presentationContext: .application
        )
    }
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
            if preferences.isEnabled {
                historyStore.prune(using: preferences)
            }
        }
    }
    @Published var searchQuery = ""
    @Published var filter: ClipboardItemFilter = .all
    @Published var actionMessage: String?
    @Published var monitoringPausedUntil: Date?

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
        if writeItemToPasteboard(item, plainTextOnly: plainTextOnly) {
            actionMessage = plainTextOnly ? "Copied as plain text." : "Copied."
        } else {
            actionMessage = "This clipboard item is no longer available. Your current clipboard was preserved."
        }
    }

    func copyItemAsPlainText(_ item: ClipboardItem) {
        guard item.supportsPlainTextSanitization else {
            return
        }

        copyItem(item, plainTextOnly: true)
    }

    @discardableResult
    private func writeItemToPasteboard(_ item: ClipboardItem, plainTextOnly: Bool) -> Bool {
        if plainTextOnly, item.plainTextValue == nil {
            return false
        }

        let preparedSnapshots: [PasteboardItemSnapshot]?
        if plainTextOnly, let text = item.plainTextValue {
            preparedSnapshots = [PasteboardItemSnapshot(representations: [
                PasteboardRepresentationSnapshot(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    data: Data(text.utf8)
                )
            ])]
        } else {
            preparedSnapshots = historyStore.pasteboardItemSnapshots(for: item)
        }

        if item.storedPayload != nil, preparedSnapshots == nil {
            return false
        }

        var fallbackImageData: Data?
        if preparedSnapshots == nil, case .image = item.kind {
            fallbackImageData = historyStore.dataForPasteboard(for: item)
            guard fallbackImageData != nil else { return false }
        } else if preparedSnapshots == nil, case .snip = item.kind {
            fallbackImageData = historyStore.dataForPasteboard(for: item)
            guard fallbackImageData != nil else { return false }
        }

        let succeeded = ClipboardPasteboardTransaction.commit(
            pasteboard: pasteboard,
            preparedItems: preparedSnapshots
        ) {
            switch item.kind {
            case let .text(text), let .link(text):
                return pasteboard.setString(text, forType: .string)
            case let .fileURLs(paths):
                return pasteboard.writeFileURLs(paths.map { URL(fileURLWithPath: $0) })
            case .image, .snip:
                return fallbackImageData.map { pasteboard.setData($0, forType: .png) } ?? false
            }
        }

        if succeeded {
            monitor.markCurrentPasteboardChangeAsHandled()
            return true
        }

        monitor.markCurrentPasteboardChangeAsHandled()
        return false
    }

    func markAutomationPasteboardChangeAsHandled() {
        monitor.markCurrentPasteboardChangeAsHandled()
    }

    func copyEditedText(_ text: String) {
        let item = ClipboardItem(
            id: UUID(),
            kind: .text(text),
            previewText: ClipboardHistoryStore.previewText(for: text),
            searchableText: text,
            sourceApp: nil,
            copiedAt: Date(),
            isPinned: false,
            contentHash: "edited",
            byteSize: Int64(text.utf8.count)
        )
        copyItem(item)
    }

}

@MainActor
enum ClipboardPasteboardTransaction {
    static func commit(
        pasteboard: any PasteboardServicing,
        preparedItems: [PasteboardItemSnapshot]?,
        fallbackWrite: () -> Bool
    ) -> Bool {
        let previousItems = pasteboard.itemSnapshots(acceptedTypeIdentifiers: Set(pasteboard.typeNames))
        _ = pasteboard.clearContents()
        let succeeded = preparedItems.map(pasteboard.writeItemSnapshots) ?? fallbackWrite()
        guard !succeeded else { return true }

        _ = pasteboard.clearContents()
        if !previousItems.isEmpty {
            _ = pasteboard.writeItemSnapshots(previousItems)
        }
        return false
    }
}
