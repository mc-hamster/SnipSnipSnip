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
        guard let state = await keepScreenshotInRecents(controller),
              editorController === controller,
              state == AutosaveState(controller: controller, documentURL: currentDocumentURL) else { return false }
        closeCurrentDocument(keepingScreenshotInRecents: true)
        return true
    }

    /// Return the exact retained state so each navigation caller can verify it
    /// once more after awaiting the write and before replacing the editor.
    func keepScreenshotInRecents(_ controller: EditorController) async -> AutosaveState? {
        guard editorController === controller, !controller.isPrivateDocument else { return nil }
        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil
        controller.commitPendingTextEdits()
        updateDocumentChangeTracking()
        if currentRecoverySessionID == nil {
            currentRecoverySessionID = createRecoverySessionIfNeeded(for: controller, documentURL: currentDocumentURL)
        }
        guard let retainedSessionID = currentRecoverySessionID else { return nil }
        let state = AutosaveState(controller: controller, documentURL: currentDocumentURL)
        guard let checkpoint = recordRecoveryCheckpoint(
            for: controller, label: "Recent Snip", pendingRecovery: true, mustComplete: true
        ) else { return nil }
        let saved = await checkpoint.value
        guard saved, !checkpoint.isCancelled, !Task.isCancelled,
              editorController === controller, !controller.isPrivateDocument else { return nil }
        guard state == AutosaveState(controller: controller, documentURL: currentDocumentURL) else {
            presentError("The screenshot changed while it was being kept in Recent Snips. Try again to keep your latest edits.")
            return nil
        }
        guard recoveryStore.pendingRecoveryEntries().contains(where: { $0.sessionID == retainedSessionID }) else {
            presentError("The screenshot could not be kept in Recent Snips. Your edits are still open. Choose Save As to keep an editable copy.")
            return nil
        }
        return state
    }
}
