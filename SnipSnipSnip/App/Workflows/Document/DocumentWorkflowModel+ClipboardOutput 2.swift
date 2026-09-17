import Foundation

/// All manual screenshot copy entry points share completion and clipboard
/// monitoring behavior. Rendering remains owned by the editor export pipeline.
extension DocumentWorkflowModel {
    func copyCurrentEditorImageToClipboard() {
        copyCurrentEditorImageToClipboard(completion: nil)
    }

    func copyCurrentEditorImageToClipboard(completion: ((Bool) -> Void)?) {
        copyEditorImageToClipboard(
            appearance: editorController?.currentWorkspaceOutputAppearance ?? .plain,
            completion: completion
        )
    }

    private func copyEditorImageToClipboard(
        appearance: ScreenshotOutputAppearance,
        completion: ((Bool) -> Void)? = nil
    ) {
        cancelPendingAutoCopy()

        guard let controller = editorController else {
            completion?(false)
            return
        }

        controller.copyAnnotatedImage(
            appearance: appearance,
            pasteboard: systemServices.pasteboard,
            completion: { [weak self] succeeded in
                if succeeded { self?.clipboardMonitor.markCurrentPasteboardChangeAsHandled() }
                completion?(succeeded)
            }
        )
    }

    func cancelPendingAutoCopy() {
        pendingAutoCopyTask?.cancel()
        pendingAutoCopyTask = nil
        autoCopyRequestGeneration &+= 1
    }

    func copyCurrentAnnotatedImageToClipboard() {
        guard let controller = editorController,
              controller.isDocumentOutputAvailable else {
            return
        }
        copyEditorImageToClipboard(
            appearance: controller.currentWorkspaceOutputAppearance
        )
    }

    func copyCurrentPlainEditorImageToClipboard() {
        copyEditorImageToClipboard(appearance: .plain)
    }

    func copyCurrentStyledEditorImageToClipboard() {
        copyEditorImageToClipboard(appearance: .styled)
    }
}
