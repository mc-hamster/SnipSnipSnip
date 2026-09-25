import Foundation

extension DocumentWorkflowModel {
    func returnToCapture() {
        guard let controller = editorController, !controller.isPrivateDocument else {
            closeEditor()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await performDocumentWork(message: "Keeping screenshot in Recent Snips") {
                await keepScreenshotAndReturnToCapture(controller)
            }
        }
    }

    /// Leave only after the exact editing state is safely retained. A write failure
    /// or an edit made while the checkpoint is being written keeps the editor open.
    @discardableResult
    func keepScreenshotAndReturnToCapture(_ controller: EditorController) async -> Bool {
        guard editorController === controller, !controller.isPrivateDocument else { return false }
        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil
        controller.commitPendingTextEdits()
        updateDocumentChangeTracking()
        if currentRecoverySessionID == nil {
            currentRecoverySessionID = createRecoverySessionIfNeeded(for: controller, documentURL: currentDocumentURL)
        }
        guard let retainedSessionID = currentRecoverySessionID else { return false }
        let state = AutosaveState(controller: controller, documentURL: currentDocumentURL)
        guard let checkpoint = recordRecoveryCheckpoint(
            for: controller, label: "Recent Snip", pendingRecovery: true, mustComplete: true
        ) else { return false }
        let saved = await checkpoint.value
        guard saved, !checkpoint.isCancelled, !Task.isCancelled,
              editorController === controller, !controller.isPrivateDocument else { return false }
        guard state == AutosaveState(controller: controller, documentURL: currentDocumentURL) else {
            presentError("The screenshot changed while it was being kept in Recent Snips. Choose Back to Capture again to keep your latest edits.")
            return false
        }
        guard recoveryStore.pendingRecoveryEntries().contains(where: { $0.sessionID == retainedSessionID }) else {
            presentError("The screenshot could not be kept in Recent Snips. Your edits are still open. Choose Save As to keep an editable copy.")
            return false
        }
        closeCurrentDocument(keepingScreenshotInRecents: true)
        return true
    }
}
