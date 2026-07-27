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
        let document = controller.editableDocument(
            previewImage: GuideRenderer.renderPreview(project: controller.project, images: controller.stepImages)
        )
        let files = systemServices.files
        do {
            try await performDocumentWork(message: "Saving Guide") {
                try await withSecurityScopedAccess(to: url) {
                    try await Task.detached(priority: .userInitiated) {
                        try SSSGuideDocumentPackage.save(document: document, to: url, files: files)
                    }.value
                }
            }
            let persisted = try SSSGuideDocumentPackage.load(from: url, files: files)
            GuideRecoveryStore().remove(projectID: controller.project.id)
            let persistedController = GuideEditorController(document: persisted)
            installGuideController(persistedController, documentURL: url, savedProject: persistedController.project)
            return true
        } catch {
            present(error)
            return false
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
        pendingCompositionImportRecovery = nil
        guideEditorController = controller
        currentDocumentURL = documentURL
        savedGuideProject = savedProject
        guidePersistenceObserver = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateDocumentChangeTracking()
                self?.scheduleGuideAutosave()
            }
        }
        updateDocumentChangeTracking()
        cleanupTemporaryVideoSourceIfNeeded(previousTemporaryVideoURL)
        resizeMainWindowForEditorContentIfNeeded(animated: false)
    }

    func scheduleGuideAutosave() {
        pendingGuideAutosaveTask?.cancel()
        guard let controller = guideEditorController, let url = currentDocumentURL else { return }
        pendingGuideAutosaveTask = Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, let controller, controller === self.guideEditorController else { return }
            let project = controller.project
            let document = controller.editableDocument(
                previewImage: GuideRenderer.renderPreview(project: project, images: controller.stepImages)
            )
            let files = systemServices.files
            do {
                try await withSecurityScopedAccess(to: url) {
                    try await Task.detached(priority: .utility) {
                        try SSSGuideDocumentPackage.save(document: document, to: url, files: files)
                    }.value
                }
                guard controller === self.guideEditorController else { return }
                savedGuideProject = project
                updateDocumentChangeTracking()
            } catch {
                controller.notice = "Autosave paused: \(error.localizedDescription)"
            }
        }
    }

    private func guideSuggestedFilename(for controller: GuideEditorController) -> String {
        let title = controller.project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "SnipSnipSnip-Guide-\(title.isEmpty ? "Untitled" : title)"
    }
}
