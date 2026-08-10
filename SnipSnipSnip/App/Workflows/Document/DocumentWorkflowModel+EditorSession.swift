import AppKit
import Combine
import Foundation

extension DocumentWorkflowModel {
    func floatCurrentWorkspaceReference() {
        guard let controller = editorController,
              controller.isDocumentOutputAvailable else {
            return
        }
        floatCurrentEditorReference(
            appearance: controller.currentWorkspaceOutputAppearance
        )
    }

    func floatCurrentEditorReference() {
        guard let controller = editorController else {
            return
        }
        floatCurrentEditorReference(appearance: controller.automationOutputAppearance)
    }

    func floatCurrentEditorReference(appearance: ScreenshotOutputAppearance) {
        guard let controller = editorController else {
            return
        }

        controller.commitPendingTextEdits()

        let image: CGImage
        do {
            image = try controller.exportedImageForInteractiveUse(
                appearance: appearance
            )
        } catch is CancellationError {
            return
        } catch {
            presentError("The floating reference image could not be rendered.")
            return
        }

        floatingReferenceCoordinator.present(FloatingReferenceRequest(
            title: "Floating Reference",
            subtitle: currentDocumentFilename,
            image: image,
            outOfCapturePatternSettings: editorOutOfCapturePatternSettings
        ))
    }

    func floatHistoryReference(_ entry: DocumentHistoryEntry) {
        Task { @MainActor [weak self] in
            do {
                guard let self else {
                    return
                }

                guard let image = try await FloatingReferenceHistoryLoader.loadImage(
                    from: entry.packageURL,
                    files: systemServices.files
                ) else {
                    presentError("The selected history preview could not be loaded.")
                    return
                }

                floatingReferenceCoordinator.present(FloatingReferenceRequest(
                    title: entry.label,
                    subtitle: entry.savedAt.formatted(date: .abbreviated, time: .shortened),
                    image: image,
                    outOfCapturePatternSettings: editorOutOfCapturePatternSettings
                ))
            } catch {
                self?.presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func confirmSaveBeforeContinuing() {
        let continuation = pendingEditorAction
        let cancellation = pendingEditorCancellation
        pendingEditorAction = nil
        pendingEditorCancellation = nil
        isShowingUnsavedChangesPrompt = false

        Task { @MainActor [weak self] in
            guard let self, await self.saveCurrentDocument() else {
                cancellation?()
                return
            }

            continuation?()
        }
    }

    func discardChangesAndContinue() {
        let continuation = pendingEditorAction
        pendingEditorAction = nil
        pendingEditorCancellation = nil
        isShowingUnsavedChangesPrompt = false
        discardCurrentDocument()

        DispatchQueue.main.async {
            continuation?()
        }
    }

    func cancelPendingEditorAction() {
        let cancellation = pendingEditorCancellation
        pendingEditorAction = nil
        pendingEditorCancellation = nil
        isShowingUnsavedChangesPrompt = false
        cancellation?()
    }

    func closeEditor() {
        performAfterHandlingUnsavedChanges { [weak self] in
            self?.discardCurrentDocument()
        }
    }

    func discardCapture() {
        discardCurrentDocument()
    }

    func configureEditorObservers() {
        guard let controller = editorController else {
            editorRenderObserver = nil
            editorPersistenceObserver = nil
            editorCommandStateObserver = nil
            if videoEditorController == nil && guideEditorController == nil {
                resetEditorSessionState()
            }

            return
        }

        var lastRenderedState = RenderedEditorState(
            snapshot: controller.documentSession.currentSnapshot
        )
        editorRenderObserver = controller.$snapshot
            .dropFirst()
            .sink { [weak self, weak controller] _ in
                guard let self else {
                    return
                }

                self.updateDocumentChangeTracking(allowDirtyFastPath: true)

                guard self.autoCopyEnabled,
                      let controller,
                      !controller.isPrivateDocument,
                      controller.workspaceMode != .presentation else {
                    return
                }

                let renderedState = RenderedEditorState(
                    snapshot: controller.documentSession.currentSnapshot
                )
                guard renderedState != lastRenderedState else {
                    return
                }
                lastRenderedState = renderedState

                self.scheduleAutoCopy(for: controller)
            }

        editorPersistenceObserver = controller.$persistenceRevision
            .dropFirst()
            .sink { [weak self, weak controller] _ in
                guard let self, let controller else {
                    return
                }

                self.updateDocumentChangeTracking()
                self.scheduleAutosave(for: controller)
            }

        editorCommandStateObserver = Publishers.CombineLatest(
            controller.$workspaceMode,
            controller.$compositionEditingScope
        )
        .sink { [weak self, weak controller] _, scope in
            guard let self, self.editorController === controller else {
                return
            }

            // Use the publisher's new scope value instead of reading through
            // the controller while @Published is still committing it. SwiftUI
            // Commands then observe stable state owned by this workflow.
            publishEditorDocumentOutputAvailability(scope == .layout)
        }

        updateDocumentChangeTracking()
        refreshRecoveryPresentationState()
    }

    func copyCurrentEditorImageToClipboard() {
        pendingAutoCopyTask?.cancel()
        pendingAutoCopyTask = nil

        guard let controller = editorController else {
            return
        }

        controller.copyAnnotatedImage(
            appearance: controller.currentWorkspaceOutputAppearance
        )
        clipboardMonitor.markCurrentPasteboardChangeAsHandled()
    }

    func cancelPendingAutoCopy() {
        pendingAutoCopyTask?.cancel()
        pendingAutoCopyTask = nil
    }

    func copyCurrentAnnotatedImageToClipboard() {
        guard let controller = editorController,
              controller.isDocumentOutputAvailable else {
            return
        }
        controller.copyAnnotatedImage(
            appearance: controller.currentWorkspaceOutputAppearance
        )
        clipboardMonitor.markCurrentPasteboardChangeAsHandled()
    }

    func copyCurrentPlainEditorImageToClipboard() {
        editorController?.copyAnnotatedImage(appearance: .plain)
        clipboardMonitor.markCurrentPasteboardChangeAsHandled()
    }

    func copyCurrentStyledEditorImageToClipboard() {
        editorController?.copyAnnotatedImage(appearance: .styled)
        clipboardMonitor.markCurrentPasteboardChangeAsHandled()
    }

    func resetEditorSessionState() {
        editorRenderObserver = nil
        editorPersistenceObserver = nil
        editorCommandStateObserver = nil
        videoPersistenceObserver = nil
        textRecognitionCoordinator.cancelAll()
        pendingAutoCopyTask?.cancel()
        pendingAutoCopyTask = nil
        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil
        cancelPendingWindowThumbnailRefresh()
        pendingRecoveryRefreshTask?.cancel()
        pendingRecoveryRefreshTask = nil
        pendingCaptureHistorySearchTask?.cancel()
        pendingCaptureHistorySearchTask = nil
        for (taskID, task) in pendingRecoveryWriteTasks
        where !recoveryOperationIDsRequiredForConsistency.contains(taskID) {
            task.cancel()
        }
        recoveryRefreshGeneration += 1
        currentRecoverySessionID = nil
        historyEntries = []
        lastAutosavedState = nil
        lastEnqueuedRecoveryState = nil
        savedEditorAutosaveState = nil
        currentDocumentURL = nil
        savedDocumentSession = nil
        savedVideoSession = nil
        currentVideoUsesRecoveryCheckpoint = false
        pendingCompositionImportRecovery = nil
        hasUnsavedChanges = false
        refreshRecoveryPresentationState()
        syncMainWindowDocumentState()
    }

    func copyRenderedImageToClipboard(
        from controller: EditorController,
        appearance: ScreenshotOutputAppearance
    ) throws {
        let image = try controller.exportedImageForInteractiveUse(
            appearance: appearance
        )
        try ImageExporter.copyToClipboard(image, pasteboard: systemServices.pasteboard)
        clipboardMonitor.markCurrentPasteboardChangeAsHandled()
    }

    func copyRenderedImageToClipboardAsync(
        from controller: EditorController,
        appearance: ScreenshotOutputAppearance
    ) async {
        do {
            let image = try await controller.renderedImageForExport(
                appearance: appearance
            )
            let pngData = try await Task.detached(
                priority: .utility
            ) {
                try Task.checkCancellation()
                return try ImageExporter.pngData(for: image)
            }.value

            guard autoCopyEnabled,
                  !controller.isPrivateDocument,
                  editorController === controller,
                  !Task.isCancelled else {
                return
            }

            try ImageExporter.copyPNGDataToClipboard(pngData, pasteboard: systemServices.pasteboard)
            clipboardMonitor.markCurrentPasteboardChangeAsHandled()
        } catch is CancellationError {
            // Cancellation is expected when a newer auto-copy task supersedes this one.
        } catch {
            presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func scheduleAutoCopy(for controller: EditorController) {
        pendingAutoCopyTask?.cancel()
        guard !controller.isPrivateDocument else {
            pendingAutoCopyTask = nil
            return
        }
        pendingAutoCopyTask = Task { @MainActor [weak self, weak controller] in
            do {
                try await self?.systemServices.scheduler.sleep(nanoseconds: ClipboardWorkflowConstants.autoCopyDebounceNanoseconds)
            } catch {
                return
            }

            guard let self,
                  self.autoCopyEnabled,
                  let controller,
                  !controller.isPrivateDocument,
                  self.editorController === controller else {
                return
            }

            await self.copyRenderedImageToClipboardAsync(
                from: controller,
                appearance: controller.currentWorkspaceOutputAppearance
            )

            self.pendingAutoCopyTask = nil
        }
    }

    func installEditorController(
        _ controller: EditorController,
        documentURL: URL?,
        savedSession: EditorDocumentSession?,
        recoverySessionID: UUID? = nil,
        shouldCreateRecoverySession: Bool = true,
        initialCheckpointLabel: String? = nil
    ) {
        let previousTemporaryVideoURL = currentOwnedTemporaryVideoSourceURL(replacingWith: nil)
        videoEditorController = nil
        guideEditorController = nil
        savedGuideProject = nil
        cleanupTemporaryVideoSourceIfNeeded(previousTemporaryVideoURL)
        savedVideoSession = nil
        currentVideoUsesRecoveryCheckpoint = false
        pendingCompositionImportRecovery = nil
        currentDocumentURL = documentURL
        savedDocumentSession = savedSession
        savedEditorAutosaveState = savedSession.map { _ in
            AutosaveState(controller: controller, documentURL: documentURL)
        }
        lastAutosavedState = nil
        controller.editorSingleKeyToolShortcutsEnabled = editorSingleKeyToolShortcutsEnabled
        controller.updateCropOutsideOverlayAlpha(editorCropOutsideOverlayAlpha)
        controller.updateOutOfCapturePatternSettings(editorOutOfCapturePatternSettings)
        controller.updatePresentationScenesRootURL(presentationScenesRootURL)
        editorController = controller
        configureEditorObservers()
        currentRecoverySessionID = recoverySessionID ?? (shouldCreateRecoverySession ? createRecoverySessionIfNeeded(for: controller, documentURL: documentURL) : nil)
        updateDocumentChangeTracking()
        resizeMainWindowForEditorContentIfNeeded()

        if let initialCheckpointLabel, shouldCreateRecoverySession {
            recordRecoveryCheckpoint(
                for: controller,
                label: initialCheckpointLabel,
                pendingRecovery: hasUnsavedChanges
            )
        } else {
            refreshRecoveryPresentationState()
        }
    }

    func discardCurrentDocument() {
        let discardedRecoveryVideo = videoEditorController != nil && currentVideoUsesRecoveryCheckpoint
        let previousTemporaryVideoURL = currentOwnedTemporaryVideoSourceURL(replacingWith: nil)
        clearCurrentRecoveryPendingState()
        editorController = nil
        videoEditorController = nil
        guideEditorController = nil
        savedGuideProject = nil
        savedVideoSession = nil
        cleanupTemporaryVideoSourceIfNeeded(previousTemporaryVideoURL)
        if discardedRecoveryVideo {
            clearVideoRecoveryAfterSaveOrDiscard()
        }
    }

    func shelveCurrentDocumentForRecents() {
        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil

        guard let controller = editorController else {
            return
        }
        guard !controller.isPrivateDocument else {
            excludeCurrentPrivateDocumentFromRecoveryAndHistory()
            return
        }

        controller.commitPendingTextEdits()

        updateDocumentChangeTracking()
        recordRecoveryCheckpoint(for: controller, label: "Recent Snip", pendingRecovery: hasUnsavedChanges)
    }

    func performAfterHandlingUnsavedChanges(_ action: @escaping () -> Void) {
        guard (editorController != nil || videoEditorController != nil || guideEditorController != nil), hasUnsavedChanges else {
            action()
            return
        }

        pendingEditorAction = action
        pendingEditorCancellation = nil
        isShowingUnsavedChangesPrompt = true
        requestMainWindowPresentation()
    }

    func updateDocumentChangeTracking(allowDirtyFastPath: Bool = false) {
        if let controller = editorController {
            if allowDirtyFastPath,
               currentDocumentURL != nil,
               savedEditorAutosaveState != nil,
               hasUnsavedChanges {
                return
            }

            if currentDocumentURL == nil {
                hasUnsavedChanges = true
            } else {
                hasUnsavedChanges = AutosaveState(controller: controller, documentURL: currentDocumentURL) != savedEditorAutosaveState
            }

            if !hasUnsavedChanges {
                clearCurrentRecoveryPendingState()
            }

            syncMainWindowDocumentState()
            return
        }

        if let controller = videoEditorController {
            if currentDocumentURL == nil {
                hasUnsavedChanges = true
            } else {
                hasUnsavedChanges = controller.documentSession != savedVideoSession
            }

            syncMainWindowDocumentState()
            return
        }

        if let controller = guideEditorController {
            hasUnsavedChanges = currentDocumentURL == nil || controller.project != savedGuideProject
            syncMainWindowDocumentState()
            return
        }

        hasUnsavedChanges = false
        syncMainWindowDocumentState()
    }

    func syncMainWindowDocumentState() {
        let title = editorController == nil && videoEditorController == nil && guideEditorController == nil ? AppBranding.displayName : currentDocumentFilename
        dependencies.windowPresenter.syncMainWindowDocumentState(
            documentURL: currentDocumentURL,
            hasUnsavedChanges: hasUnsavedChanges,
            title: title
        )
    }

    func resizeMainWindowForEditorContentIfNeeded(animated: Bool = true) {
        let imagePixelSize: CGSize
        let contentKind: DocumentWindowContentKind
        if let editorController {
            imagePixelSize = editorController.capture.pixelSize
            contentKind = .screenshot
        } else if let videoController = videoEditorController {
            imagePixelSize = videoController.recording.bounds.size
            contentKind = .video
        } else if let guideController = guideEditorController,
                  let step = guideController.project.steps.first,
                  let image = guideController.stepImages[step.id] {
            imagePixelSize = CGSize(width: image.width, height: image.height)
            contentKind = .guide
        } else {
            return
        }

        guard dependencies.windowPresenter.resizeMainWindowForContent(pixelSize: imagePixelSize, kind: contentKind, animated: animated) else {
            return
        }

        guard let editorController else {
            return
        }

        // Apply the bounded initial scale after layout settles at the new window size.
        DispatchQueue.main.async { [weak editorController] in
            editorController?.zoomToInitialDisplayScale()
        }
    }

    func withSecurityScopedAccess<T>(to url: URL, perform work: () throws -> T) throws -> T {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try work()
    }

    func withSecurityScopedAccess<T>(to url: URL, perform work: () async throws -> T) async throws -> T {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try await work()
    }

    func installCapturedRecording(_ recording: CapturedVideoRecording) {
        let controller = VideoEditorController(recording: recording)
        installVideoController(controller, documentURL: nil, savedSession: nil)
        requestMainWindowPresentation()
    }

    func installVideoController(_ controller: VideoEditorController, documentURL: URL?, savedSession: VideoEditorSession?) {
        let previousTemporaryVideoURL = currentOwnedTemporaryVideoSourceURL(replacingWith: controller.recording.sourceURL)
        clearCurrentRecoveryPendingState()
        editorController = nil
        guideEditorController = nil
        savedGuideProject = nil
        pendingCompositionImportRecovery = nil
        currentDocumentURL = documentURL
        savedVideoSession = savedSession
        currentVideoUsesRecoveryCheckpoint = false
        videoEditorController = controller
        configureVideoEditorObservers()
        updateDocumentChangeTracking()
        cleanupTemporaryVideoSourceIfNeeded(previousTemporaryVideoURL)

        Task { @MainActor [weak self] in
            self?.resizeMainWindowForEditorContentIfNeeded(animated: false)
        }
    }

    func configureVideoEditorObservers() {
        guard let videoEditorController else {
            videoPersistenceObserver = nil

            if editorController == nil && guideEditorController == nil {
                resetEditorSessionState()
            }

            return
        }

        videoPersistenceObserver = videoEditorController.$persistenceRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.updateDocumentChangeTracking()
            }

        updateDocumentChangeTracking()
    }

    func requestMainWindowPresentation() {
        dependencies.lifecycle.requestMainWindowPresentation()
    }

    func triggerArchiveMaintenance() {
        dependencies.archive.triggerArchiveMaintenance()
    }

    func present(_ error: Error) {
        presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    func handleIncompatibleDocumentIfNeeded(at url: URL) -> Bool {
        guard compatibilityStatus(forDocumentAt: url).isUnsupportedFormatVersion else {
            return false
        }

        _ = incompatibleDocumentCoordinator.handleIncompatibleFiles(
            [url],
            sourceDescription: "selected document",
            presentError: present
        )
        return true
    }

    private func compatibilityStatus(forDocumentAt url: URL) -> PackageCompatibilityStatus {
        if url.pathExtension.lowercased() == "sssguide" {
            return SSSGuideDocumentPackage.compatibilityStatus(at: url, files: systemServices.files)
        }
        if url.pathExtension.lowercased() == "sssvideo" {
            return SSSVideoDocumentPackage.compatibilityStatus(at: url, files: systemServices.files)
        }

        return SSSDocumentPackage.compatibilityStatus(at: url, files: systemServices.files)
    }

    static func presentEditableRedactionSaveConfirmation() -> EditableRedactionSaveDecision {
        let alert = NSAlert()
        alert.messageText = "Save original source pixels in this editable document?"
        alert.informativeText = ".sss keeps every original source pixel, including private captures and content hidden by item or composition redactions. Use Copy, Share, or Export for flattened output."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save Editable Anyway")
        alert.addButton(withTitle: "Export Flattened PNG")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .saveEditable
        case .alertSecondButtonReturn:
            return .exportFlattenedPNG
        default:
            return .cancel
        }
    }

    static func presentDocumentFormatMigrationConfirmation() -> DocumentFormatMigrationDecision {
        let alert = NSAlert()
        alert.messageText = "Update this document to .sss v7?"
        alert.informativeText = "Multi-capture composition requires the current editable document format. The existing v6 package remains untouched if saving fails."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save v7")
        alert.addButton(withTitle: "Save a Copy")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .saveV7
        case .alertSecondButtonReturn:
            return .saveCopy
        default:
            return .cancel
        }
    }
}

nonisolated private enum FloatingReferenceHistoryLoader {
    static func loadImage(
        from packageURL: URL,
        files: any FileSystemServicing
    ) async throws -> CGImage? {
        let task = Task.detached(priority: .userInitiated) { () throws -> CGImage? in
            try Task.checkCancellation()
            return try SSSDocumentPackage.loadDisplayPreview(
                from: packageURL,
                allowsExternalRecoveryBase: true,
                files: files
            )?.image
        }

        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }
}

private struct RenderedEditorState: Equatable {
    let cropRect: CGRect
    let annotations: [Annotation]
    let presentation: ScreenshotPresentation

    init(snapshot: EditorSnapshot) {
        cropRect = snapshot.cropRect
        annotations = snapshot.annotations
        presentation = snapshot.presentation
    }
}
