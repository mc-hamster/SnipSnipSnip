import Foundation

@MainActor
final class LiveClipboardManagerPresenter: ClipboardManagerPresenting {
    private var managerWindowController: ClipboardManagerWindowController?

    func showClipboardManager(
        clipboard: ClipboardWorkflowModel,
        workspace: any WorkspaceServicing,
        bundleIdentifier: String?
    ) {
        if managerWindowController == nil {
            managerWindowController = ClipboardManagerWindowController(
                clipboard: clipboard,
                workspace: workspace,
                bundleIdentifier: bundleIdentifier
            )
        }

        managerWindowController?.show()
    }

    func activatePreviousApplicationForPaste() {
        managerWindowController?.activatePreviousApplicationForPaste()
    }
}
