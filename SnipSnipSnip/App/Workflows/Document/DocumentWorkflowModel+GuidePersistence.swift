import Combine
import Foundation
import UniformTypeIdentifiers

extension DocumentWorkflowModel {
    @discardableResult
    func saveCurrentGuideDocument(_ controller: GuideEditorController) async -> Bool {
        let targetURL: URL
        if let currentDocumentURL { targetURL = currentDocumentURL }
        else {
            guard let selectedURL = await presentSaveDocumentPanel(
                suggestedFilename: guideSuggestedFilename(for: controller),
                contentType: .snipSnipGuideDocument
            ) else { return false }
            targetURL = selectedURL
        }
        return await saveGuideDocument(controller, to: targetURL)
    }

    @discardableResult
    func saveCurrentGuideDocumentAs(_ controller: GuideEditorController) async -> Bool {
        guard let selectedURL = await presentSaveDocumentPanel(
            suggestedFilename: currentDocumentURL?.deletingPathExtension().lastPathComponent ?? guideSuggestedFilename(for: controller),
            contentType: .snipSnipGuideDocument
        ) else { return false }
        return await saveGuideDocument(controller, to: selectedURL)
    }

    @discardableResult
    func saveGuideDocument(_ controller: GuideEditorController, to url: URL) async -> Bool {
        pendingGuideAutosaveTask?.cancel()
        pendingGuideAutosaveTask = nil
        controller.finishMarkerDrag()
        return await performDocumentWork(message: "Saving Guide") {
            await persistGuide(controller, to: url)
        }
    }

    func installCapturedGuide(_ document: EditableGuideDocument) {
        installGuideController(GuideEditorController(document: document), documentURL: nil, savedProject: nil)
        requestMainWindowPresentation()
    }

    func installGuideController(_ controller: GuideEditorController, documentURL: URL?, savedProject: GuideProject?) {
        let previousTemporaryVideoURL = currentOwnedTemporaryVideoSourceURL(replacingWith: nil)
        clearCurrentRecoveryPendingState()
        editorController = nil
        videoEditorController = nil
        savedVideoSession = nil
        currentVideoUsesRecoveryCheckpoint = false
        pendingCompositionImportRecovery = nil
        guideEditorController = controller
        currentDocumentURL = documentURL
        savedGuideProject = savedProject
        savedGuideContentVersion = savedProject == nil ? nil : controller.contentVersion
        // Observe authored changes only: publishing a failure or loading a
        // thumbnail must not retry a failed save indefinitely.
        guidePersistenceObserver = controller.$contentRevision.dropFirst().sink { [weak self, weak controller] _ in
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller, controller === self.guideEditorController else { return }
                self.invalidateOutdatedGuideExport()
                self.updateDocumentChangeTracking()
                self.scheduleGuideAutosave()
            }
        }
        updateDocumentChangeTracking()
        cleanupTemporaryVideoSourceIfNeeded(previousTemporaryVideoURL)
        resizeMainWindowForEditorContentIfNeeded(animated: false)
    }

    func scheduleGuideAutosave() {
        guard let controller = guideEditorController,
              !controller.isSaving,
              controller.saveFailure == nil,
              controller.contentVersion != savedGuideContentVersion,
              let url = currentDocumentURL else { return }
        pendingGuideAutosaveTask?.cancel()
        pendingGuideAutosaveTask = Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, let controller, controller === self.guideEditorController else { return }
            _ = await self.persistGuide(controller, to: url)
        }
    }

    /// A completed/manual Guide is no longer owned by the live capture exit
    /// path. Keep its current editing revision before allowing app shutdown.
    func prepareGuideEditorForApplicationExit() async -> Bool {
        guard let controller = guideEditorController else { return true }
        controller.finishMarkerDrag()
        let requestedVersion = controller.contentVersion
        if controller.isSaving, let generation = guideSaveGeneration {
            await withCheckedContinuation { continuation in
                guideSaveCompletionWaiters[generation, default: []].append(continuation)
            }
            guard guideEditorController === controller,
                  controller.contentVersion == requestedVersion,
                  controller.saveFailure == nil, !Task.isCancelled else { return false }
        }
        pendingGuideAutosaveTask?.cancel()
        pendingGuideAutosaveTask = nil
        updateDocumentChangeTracking()
        guard hasUnsavedChanges else { return true }

        // No destination means there is no durable home for later manual
        // edits. Private work always retains an explicit Save/Discard choice.
        if currentDocumentURL == nil || controller.project.isPrivate {
            return await confirmUnsavedDocumentForApplicationExit()
        }
        guard let url = currentDocumentURL else { return false }
        let saved = await persistGuide(controller, to: url)
        guard saved, guideEditorController === controller,
              controller.contentVersion == requestedVersion, !Task.isCancelled else { return false }
        updateDocumentChangeTracking()
        return !hasUnsavedChanges
    }

    /// Shared by autosave, Retry, Save, and Save As. Publication is guarded by
    /// both session and write generation, including while switching documents.
    @discardableResult
    func persistGuide(_ controller: GuideEditorController, to url: URL) async -> Bool {
        guard controller === guideEditorController else { return false }
        let generation = UUID()
        guideSaveGeneration = generation
        let version = controller.contentVersion
        let document = controller.editableDocument()
        controller.isSaving = true
        defer {
            if guideSaveGeneration == generation { controller.isSaving = false }
            let waiters = guideSaveCompletionWaiters.removeValue(forKey: generation) ?? []
            waiters.forEach { $0.resume() }
        }
        do {
            let persisted = try await withSecurityScopedAccess(to: url) {
                try await guideDocumentWriter.save(document, to: url, files: systemServices.files)
            }
            guard !Task.isCancelled, guideSaveGeneration == generation,
                  controller === guideEditorController else { return false }
            controller.adoptPersistedMedia(from: persisted)
            currentDocumentURL = url
            savedGuideProject = document.project
            savedGuideContentVersion = version
            controller.setSaveFailure(nil)
            controller.isSaving = false
            updateDocumentChangeTracking()
            if controller.contentVersion == version {
                GuideRecoveryStore().remove(projectID: document.project.id)
            } else {
                scheduleGuideAutosave()
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard !Task.isCancelled, guideSaveGeneration == generation,
                  controller === guideEditorController else { return false }
            controller.setSaveFailure(error.localizedDescription)
            updateDocumentChangeTracking()
            return false
        }
    }

    private func guideSuggestedFilename(for controller: GuideEditorController) -> String {
        let title = controller.project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "SnipSnipSnip-Guide-\(title.isEmpty ? "Untitled" : title)"
    }
}
