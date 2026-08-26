import Foundation

@MainActor
final class LiveClipboardManagerPresenter: ClipboardManagerPresenting {
    private var managerWindowController: ClipboardManagerWindowController?
    private let workspace: any WorkspaceServicing

    init(workspace: any WorkspaceServicing) {
        self.workspace = workspace
    }

    func showClipboardManager(
        clipboard: ClipboardWorkflowModel,
        presentationContext: WorkflowPresentationContext
    ) {
        if managerWindowController == nil {
            managerWindowController = ClipboardManagerWindowController(clipboard: clipboard, workspace: workspace)
        }

        managerWindowController?.show(
            on: presentationContext.displayID
        )
    }
}
