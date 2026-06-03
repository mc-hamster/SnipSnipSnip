import AppKit
import Foundation

struct IncompatibleDocumentCoordinator {
    struct Context: Equatable {
        let urls: [URL]
        let sourceDescription: String
    }

    typealias ConfirmationHandler = (Context) -> Bool
    typealias TrashHandler = ([URL]) throws -> Void
    typealias CancellationNoticeHandler = (Context) -> Void
    typealias TerminationHandler = () -> Void

    private let confirmationHandler: ConfirmationHandler
    private let trashHandler: TrashHandler
    private let cancellationNoticeHandler: CancellationNoticeHandler
    private let terminationHandler: TerminationHandler

    init(
        confirmationHandler: ConfirmationHandler? = nil,
        trashHandler: TrashHandler? = nil,
        cancellationNoticeHandler: CancellationNoticeHandler? = nil,
        terminationHandler: TerminationHandler? = nil
    ) {
        self.confirmationHandler = confirmationHandler ?? Self.presentConfirmation
        self.trashHandler = trashHandler ?? Self.moveToTrash
        self.cancellationNoticeHandler = cancellationNoticeHandler ?? Self.presentCancellationNotice
        self.terminationHandler = terminationHandler ?? Self.terminateApplication
    }

    @discardableResult
    func handleIncompatibleFiles(
        _ urls: [URL],
        sourceDescription: String,
        presentError: (Error) -> Void,
        afterTrash: () throws -> Void = {}
    ) -> Bool {
        let uniqueURLs = urls.uniquedByPath()

        guard !uniqueURLs.isEmpty else {
            return true
        }

        let context = Context(urls: uniqueURLs, sourceDescription: sourceDescription)

        guard confirmationHandler(context) else {
            cancellationNoticeHandler(context)
            terminationHandler()
            return false
        }

        do {
            try trashHandler(uniqueURLs)
            try afterTrash()
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    private static func presentConfirmation(for context: Context) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = context.urls.count == 1
            ? "Older SnipSnipSnip Document Found"
            : "Older SnipSnipSnip Documents Found"
        alert.informativeText = confirmationMessage(for: context)
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func presentCancellationNotice(for context: Context) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Open an Older Version"
        alert.informativeText = "This version cannot continue with the incompatible \(context.sourceDescription). SnipSnipSnip will now close. Reopen an older version to work with these files."
        alert.addButton(withTitle: "Close App")
        alert.runModal()
    }

    private static func terminateApplication() {
        NSApp.terminate(nil)
    }

    private static func moveToTrash(_ urls: [URL]) throws {
        for url in urls.uniquedByPath() {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        }
    }

    private static func confirmationMessage(for context: Context) -> String {
        let filenames = context.urls.prefix(3).map(\.lastPathComponent)
        let filenameSummary = filenames.joined(separator: ", ")
        let extraCount = max(context.urls.count - filenames.count, 0)
        let suffix = extraCount > 0 ? " and \(extraCount) more" : ""

        if context.urls.count == 1 {
            return "This version no longer supports documents created by older SnipSnipSnip builds. If you continue, \(filenameSummary) will be moved to the Trash."
        }

        return "This version no longer supports documents created by older SnipSnipSnip builds. If you continue, \(filenameSummary)\(suffix) from \(context.sourceDescription) will be moved to the Trash."
    }
}

private extension Array where Element == URL {
    func uniquedByPath() -> [URL] {
        var seenPaths: Set<String> = []

        return filter { url in
            let normalizedPath = url.standardizedFileURL.path
            return seenPaths.insert(normalizedPath).inserted
        }
    }
}