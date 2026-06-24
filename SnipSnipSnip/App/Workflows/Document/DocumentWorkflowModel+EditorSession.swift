import AppKit
import Combine
import Foundation

extension DocumentWorkflowModel {
    func floatCurrentEditorReference() {
        guard let controller = editorController else {
            return
        }

        controller.commitPendingTextEdits()

        let usesPresentation = controller.workspaceMode == .presentation
        guard let image = controller.exportedImage(usingPresentation: usesPresentation) else {
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
        pendingEditorAction = nil
        isShowingUnsavedChangesPrompt = false

        Task { @MainActor [weak self] in
            guard let self, await self.saveCurrentDocument() else {
                return
            }

            continuation?()
        }
    }

    func discardChangesAndContinue() {
        let continuation = pendingEditorAction
        pendingEditorAction = nil
        isShowingUnsavedChangesPrompt = false
        discardCurrentDocument()

        DispatchQueue.main.async {
            continuation?()
        }
    }

    func cancelPendingEditorAction() {
        pendingEditorAction = nil
        isShowingUnsavedChangesPrompt = false
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
            editorWorkspaceModeObserver = nil

            if videoEditorController == nil {
                resetEditorSessionState()
            }

            return
        }

        var lastRenderedState = RenderedEditorState(snapshot: controller.snapshot)
        editorRenderObserver = controller.$snapshot
            .dropFirst()
            .sink { [weak self, weak controller] snapshot in
                guard let self else {
                    return
                }

                self.updateDocumentChangeTracking(allowDirtyFastPath: true)

                guard self.autoCopyEnabled,
                      let controller,
                      controller.workspaceMode != .presentation else {
                    return
                }

                let renderedState = RenderedEditorState(snapshot: snapshot)
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

        editorWorkspaceModeObserver = controller.$workspaceMode
            .sink { [weak self] mode in
                self?.handleEditorWorkspaceModeChange(mode)
            }

        updateDocumentChangeTracking()
        refreshRecoveryPresentationState()
    }

    func handleEditorWorkspaceModeChange(_ mode: EditorWorkspaceMode) {
        guard mode == .presentation,
              !hasShownPresentationExperimentalNoticeThisStartup else {
            return
        }

        hasShownPresentationExperimentalNoticeThisStartup = true
        presentPresentationExperimentalNotice()
    }

    func copyCurrentEditorImageToClipboard() {
        pendingAutoCopyTask?.cancel()
        pendingAutoCopyTask = nil

        guard let controller = editorController else {
            return
        }

        pendingAutoCopyTask = Task { [weak self, weak controller] in
            guard let self, let controller else {
                return
            }

            await self.copyRenderedImageToClipboardAsync(from: controller)
            self.pendingAutoCopyTask = nil
        }
    }

    func cancelPendingAutoCopy() {
        pendingAutoCopyTask?.cancel()
        pendingAutoCopyTask = nil
    }

    func copyCurrentAnnotatedImageToClipboard() {
        editorController?.copyAnnotatedImage()
        clipboardMonitor.markCurrentPasteboardChangeAsHandled()
    }

    func copyCurrentPlainEditorImageToClipboard() {
        editorController?.copyPlainAnnotatedImage()
        clipboardMonitor.markCurrentPasteboardChangeAsHandled()
    }

    func resetEditorSessionState() {
        editorRenderObserver = nil
        editorPersistenceObserver = nil
        editorWorkspaceModeObserver = nil
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
        pendingRecoveryWriteTasks.values.forEach { $0.cancel() }
        pendingRecoveryWriteTasks.removeAll()
        recoveryRefreshGeneration += 1
        currentRecoverySessionID = nil
        historyEntries = []
        lastAutosavedState = nil
        savedEditorAutosaveState = nil
        currentDocumentURL = nil
        savedDocumentSession = nil
        savedVideoSession = nil
        hasUnsavedChanges = false
        refreshRecoveryPresentationState()
        syncMainWindowDocumentState()
    }

    func copyRenderedImageToClipboard(from controller: EditorController) throws {
        guard let image = controller.exportedImage() else {
            return
        }

        try ImageExporter.copyToClipboard(image, pasteboard: systemServices.pasteboard)
        clipboardMonitor.markCurrentPasteboardChangeAsHandled()
    }

    func copyRenderedImageToClipboardAsync(from controller: EditorController) async {
        let renderInput = ExportRenderInput(
            baseImage: controller.capture.image,
            snapshot: controller.snapshot,
            pinnedUIMapElements: controller.pinnedUIMapElements,
            uiMapOverlayOptions: controller.uiMapOverlayOptions
        )

        do {
            let pngData = try await AutoCopyRenderer.renderPNGData(from: renderInput)

            guard autoCopyEnabled, editorController === controller, !Task.isCancelled else {
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
        pendingAutoCopyTask = Task { @MainActor [weak self, weak controller] in
            do {
                try await self?.systemServices.scheduler.sleep(nanoseconds: ClipboardWorkflowConstants.autoCopyDebounceNanoseconds)
            } catch {
                return
            }

            guard let self, self.autoCopyEnabled, let controller, self.editorController === controller else {
                return
            }

            await self.copyRenderedImageToClipboardAsync(from: controller)

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
        cleanupTemporaryVideoSourceIfNeeded(previousTemporaryVideoURL)
        savedVideoSession = nil
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
        let previousTemporaryVideoURL = currentOwnedTemporaryVideoSourceURL(replacingWith: nil)
        clearCurrentRecoveryPendingState()
        editorController = nil
        videoEditorController = nil
        savedVideoSession = nil
        cleanupTemporaryVideoSourceIfNeeded(previousTemporaryVideoURL)
    }

    func shelveCurrentDocumentForRecents() {
        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil

        guard let controller = editorController else {
            return
        }

        controller.commitPendingTextEdits()

        updateDocumentChangeTracking()
        recordRecoveryCheckpoint(for: controller, label: "Recent Snip", pendingRecovery: hasUnsavedChanges)
    }

    func performAfterHandlingUnsavedChanges(_ action: @escaping () -> Void) {
        guard (editorController != nil || videoEditorController != nil), hasUnsavedChanges else {
            action()
            return
        }

        pendingEditorAction = action
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

        hasUnsavedChanges = false
        syncMainWindowDocumentState()
    }

    func syncMainWindowDocumentState() {
        let title = editorController == nil && videoEditorController == nil ? AppBranding.displayName : currentDocumentFilename
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

    @discardableResult
    func installCapturedScreenshot(_ result: CaptureWorkflowResult) -> EditorController {
        shelveCurrentDocumentForRecents()
        let controller = EditorController(
            capture: result.capture,
            capabilities: capabilities,
            uiMapOverlayOptions: uiMapPinnedOverlayDefaults
        )
        if result.shouldProcessUIMap {
            controller.beginUIMapProcessing()
        }
        installEditorController(
            controller,
            documentURL: nil,
            savedSession: nil,
            shouldCreateRecoverySession: !result.isPrivateCapture,
            initialCheckpointLabel: result.isPrivateCapture ? nil : result.checkpointLabel
        )
        return controller
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
        currentDocumentURL = documentURL
        savedVideoSession = savedSession
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

            if editorController == nil {
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
        if url.pathExtension.lowercased() == "sssvideo" {
            return SSSVideoDocumentPackage.compatibilityStatus(at: url, files: systemServices.files)
        }

        return SSSDocumentPackage.compatibilityStatus(at: url, files: systemServices.files)
    }

    static func presentEditableRedactionSaveConfirmation() -> EditableRedactionSaveDecision {
        let alert = NSAlert()
        alert.messageText = "Save editable document with redactions?"
        alert.informativeText = ".sss keeps original unredacted pixels. Use Copy, Share, or Export for flattened redactions."
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
}

nonisolated struct ExportRenderInput: @unchecked Sendable {
    let baseImage: CGImage
    let snapshot: EditorSnapshot
    let pinnedUIMapElements: [UIMapElement]
    let uiMapOverlayOptions: UIMapOverlayOptions

    init(
        baseImage: CGImage,
        snapshot: EditorSnapshot,
        pinnedUIMapElements: [UIMapElement] = [],
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions()
    ) {
        self.baseImage = baseImage
        self.snapshot = snapshot
        self.pinnedUIMapElements = pinnedUIMapElements
        self.uiMapOverlayOptions = uiMapOverlayOptions
    }
}

nonisolated private enum AutoCopyRenderer {
    static func renderPNGData(from input: ExportRenderInput) async throws -> Data {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()

            let image = PresentationPerformanceMetrics.measure(
                "autoCopy.content",
                context: "base=\(input.baseImage.width)x\(input.baseImage.height) crop=\(PresentationPerformanceMetrics.size(input.snapshot.cropRect.size)) annotations=\(input.snapshot.annotations.count)",
                warnAfterMS: 80
            ) {
                EditorRenderer.render(
                    baseImage: input.baseImage,
                    snapshot: input.snapshot,
                    pinnedUIMapElements: input.pinnedUIMapElements,
                    uiMapOverlayOptions: input.uiMapOverlayOptions
                )
            }

            guard let image else {
                throw ImageExportError.encodingFailed
            }

            let presentedImage = PresentationPerformanceMetrics.measure(
                "autoCopy.presentation",
                context: "content=\(image.width)x\(image.height) \(PresentationPerformanceMetrics.presentationSummary(input.snapshot.presentation))",
                warnAfterMS: 100
            ) {
                ScreenshotPresentationRenderer.render(contentImage: image, presentation: input.snapshot.presentation)
            }

            guard let presentedImage else {
                throw ImageExportError.encodingFailed
            }

            try Task.checkCancellation()
            return try PresentationPerformanceMetrics.measure(
                "autoCopy.encode",
                context: "image=\(presentedImage.width)x\(presentedImage.height)",
                warnAfterMS: 80
            ) {
                try ImageExporter.pngData(for: presentedImage)
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
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
            return try SSSDocumentPackage.loadDisplayPreview(from: packageURL, files: files)?.image
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
