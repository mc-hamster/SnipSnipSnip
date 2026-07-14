import Foundation

@MainActor
final class LiveClipboardManagerPresenter: ClipboardManagerPresenting {
    private var managerWindowController: ClipboardManagerWindowController?

    func showClipboardManager(clipboard: ClipboardWorkflowModel) {
        if managerWindowController == nil {
            managerWindowController = ClipboardManagerWindowController(clipboard: clipboard)
        }

        managerWindowController?.show()
    }
}
