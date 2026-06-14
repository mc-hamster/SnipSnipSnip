import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension AppModel {
    private struct ImportedImageLoadError: LocalizedError {
        var errorDescription: String? {
            "The selected file could not be loaded as an image."
        }
    }

    func openDocumentPanel() {
        performAfterHandlingUnsavedChanges { [weak self] in
            self?.presentOpenDocumentPanel()
        }
    }

    func importImagePanel() {
        performAfterHandlingUnsavedChanges { [weak self] in
            self?.presentImportImagePanel()
        }
    }

    func openDocument(at url: URL) {
        performAfterHandlingUnsavedChanges { [weak self] in
            self?.loadDocument(from: url)
        }
    }

    func openExternalFile(at url: URL) {
        performAfterHandlingUnsavedChanges { [weak self] in
            if Self.isEditableDocumentURL(url) {
                self?.loadDocument(from: url)
            } else {
                self?.importImage(from: url)
            }
        }
    }

    func saveDocument() {
        Task {
            _ = await saveCurrentDocument()
        }
    }

    func saveDocumentAs() {
        Task {
            _ = await saveCurrentDocumentAs()
        }
    }

    func exportAnnotatedImage() {
        exportAnnotatedImage(as: .png)
    }

    func exportAnnotatedImage(as format: ImageExportFormat) {
        editorController?.saveAnnotatedImage(
            format: format,
            filenameTemplate: ScreenshotFilenameTemplate(pattern: screenshotFilenameTemplate),
            exportOptions: screenshotImageExportOptions
        )
    }

    func shareAnnotatedImage() {
        editorController?.shareAnnotatedImage()
    }

    func floatCurrentEditorReference() {
        guard let controller = editorController else {
            return
        }

        controller.commitPendingTextEdits()

        guard let image = controller.exportedImage() else {
            errorMessage = "The floating reference image could not be rendered."
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
                guard let image = try await FloatingReferenceHistoryLoader.loadImage(from: entry.packageURL) else {
                    self?.errorMessage = "The selected history preview could not be loaded."
                    return
                }

                self?.floatingReferenceCoordinator.present(FloatingReferenceRequest(
                    title: entry.label,
                    subtitle: entry.savedAt.formatted(date: .abbreviated, time: .shortened),
                    image: image,
                    outOfCapturePatternSettings: self?.editorOutOfCapturePatternSettings ?? .default
                ))
            } catch {
                self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func promisedAnnotatedImagePayload() -> PromisedFilePayload? {
        editorController?.promisedImagePayload(
            requestedFormat: screenshotDragOutFormat,
            filenameTemplate: ScreenshotFilenameTemplate(pattern: screenshotFilenameTemplate),
            exportOptions: screenshotImageExportOptions
        )
    }

    var screenshotImageExportOptions: ImageExportOptions {
        ImageExportOptions(jpegQuality: screenshotJPEGQuality)
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

            if videoEditorController == nil {
                resetEditorSessionState()
            }

            return
        }

        editorRenderObserver = controller.$snapshot
            .map(RenderedEditorState.init)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self, weak controller] _ in
                guard let self else {
                    return
                }

                self.updateDocumentChangeTracking()

                guard self.autoCopyEnabled,
                      let controller,
                      controller.workspaceMode != .presentation else {
                    return
                }

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

        updateDocumentChangeTracking()
        refreshRecoveryPresentationState()
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
        videoPersistenceObserver = nil
        textRecognitionCoordinator.cancelAll()
        pendingAutoCopyTask?.cancel()
        pendingAutoCopyTask = nil
        pendingAutosaveTask?.cancel()
        pendingAutosaveTask = nil
        pendingWindowThumbnailTask?.cancel()
        pendingWindowThumbnailTask = nil
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

        try ImageExporter.copyToClipboard(image)
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

            try ImageExporter.copyPNGDataToClipboard(pngData)
            clipboardMonitor.markCurrentPasteboardChangeAsHandled()
        } catch is CancellationError {
            // Cancellation is expected when a newer auto-copy task supersedes this one.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func scheduleAutoCopy(for controller: EditorController) {
        pendingAutoCopyTask?.cancel()
        pendingAutoCopyTask = Task { @MainActor [weak self, weak controller] in
            do {
                try await Task.sleep(nanoseconds: Self.autoCopyDebounceNanoseconds)
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

    @discardableResult
    func saveCurrentDocument() async -> Bool {
        if let controller = videoEditorController {
            return await saveCurrentVideoDocument(controller)
        }

        guard let controller = editorController else {
            return false
        }

        guard handleEditableRedactionSaveIfNeeded(for: controller) else {
            return false
        }

        let targetURL: URL

        if let currentDocumentURL {
            targetURL = currentDocumentURL
        } else {
            guard let selectedURL = await presentSaveDocumentPanel(suggestedFilename: ScreenshotFilenameTemplate(pattern: screenshotFilenameTemplate).resolvedFilename(for: controller.capture, formatExtension: "sss")) else {
                return false
            }

            targetURL = selectedURL
        }

        return await saveDocument(controller, to: targetURL)
    }

    @discardableResult
    func saveCurrentDocumentAs() async -> Bool {
        if let controller = videoEditorController {
            return await saveCurrentVideoDocumentAs(controller)
        }

        guard let controller = editorController else {
            return false
        }

        guard handleEditableRedactionSaveIfNeeded(for: controller) else {
            return false
        }

        let suggestedFilename = currentDocumentURL?.deletingPathExtension().lastPathComponent
            ?? ScreenshotFilenameTemplate(pattern: screenshotFilenameTemplate).resolvedFilename(for: controller.capture, formatExtension: "sss")

        guard let selectedURL = await presentSaveDocumentPanel(suggestedFilename: suggestedFilename) else {
            return false
        }

        return await saveDocument(controller, to: selectedURL)
    }

    @discardableResult
    func handleEditableRedactionSaveIfNeeded(for controller: EditorController) -> Bool {
        guard controller.containsRedactions else {
            return true
        }

        let controllerID = ObjectIdentifier(controller)
        guard !editableRedactionSaveWarningAcknowledgedEditorIDs.contains(controllerID) else {
            return true
        }

        switch editableRedactionSaveConfirmationHandler() {
        case .saveEditable:
            editableRedactionSaveWarningAcknowledgedEditorIDs.insert(controllerID)
            return true
        case .exportFlattenedPNG:
            exportAnnotatedImage(as: .png)
            return false
        case .cancel:
            return false
        }
    }

    @discardableResult
    func saveDocument(_ controller: EditorController, to url: URL) async -> Bool {
        controller.commitPendingTextEdits()

        let document = EditableScreenshotDocument(capture: controller.capture, session: controller.documentSession)
        let payload = ScreenshotDocumentWritePayload(
            document: document,
            renderInput: ExportRenderInput(
                baseImage: controller.capture.image,
                snapshot: controller.snapshot,
                pinnedUIMapElements: controller.pinnedUIMapElements,
                uiMapOverlayOptions: controller.uiMapOverlayOptions
            ),
            url: url,
            includeUIMapSearchText: windowUIMapEnabled
        )

        do {
            isWorking = true
            workingMessage = "Saving"
            defer { isWorking = false }

            try await withSecurityScopedAccess(to: url) {
                try await DocumentPackageWriter.saveScreenshot(payload)
            }
            currentDocumentURL = url
            savedDocumentSession = controller.documentSession
            savedEditorAutosaveState = AutosaveState(controller: controller, documentURL: url)
            updateDocumentChangeTracking()
            recordRecoveryCheckpoint(for: controller, label: "Saved", pendingRecovery: false)
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func saveCurrentVideoDocument(_ controller: VideoEditorController) async -> Bool {
        let targetURL: URL

        if let currentDocumentURL {
            targetURL = currentDocumentURL
        } else {
            guard let selectedURL = await presentSaveDocumentPanel(
                suggestedFilename: controller.recording.defaultFilename,
                contentType: .snipSnipVideoDocument
            ) else {
                return false
            }

            targetURL = selectedURL
        }

        return await saveVideoDocument(controller, to: targetURL)
    }

    @discardableResult
    func saveCurrentVideoDocumentAs(_ controller: VideoEditorController) async -> Bool {
        let suggestedFilename = currentDocumentURL?.deletingPathExtension().lastPathComponent ?? controller.recording.defaultFilename

        guard let selectedURL = await presentSaveDocumentPanel(
            suggestedFilename: suggestedFilename,
            contentType: .snipSnipVideoDocument
        ) else {
            return false
        }

        return await saveVideoDocument(controller, to: selectedURL)
    }

    @discardableResult
    func saveVideoDocument(_ controller: VideoEditorController, to url: URL) async -> Bool {
        let payload = VideoDocumentWritePayload(
            document: EditableVideoDocument(recording: controller.recording, session: controller.documentSession),
            posterImage: controller.posterImage,
            url: url
        )

        do {
            isWorking = true
            workingMessage = "Saving"
            defer { isWorking = false }

            try await withSecurityScopedAccess(to: url) {
                try await DocumentPackageWriter.saveVideo(payload)
            }
            let persistedController = VideoEditorController(
                recording: controller.recording.updatingSourceURL(
                    url.appendingPathComponent(SSSVideoDocumentPackage.mediaFilename)
                ),
                session: controller.documentSession,
                posterImage: controller.posterImage
            )
            installVideoController(persistedController, documentURL: url, savedSession: persistedController.documentSession)
            return true
        } catch {
            present(error)
            return false
        }
    }

    func presentOpenDocumentPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.snipSnipDocument, .snipSnipVideoDocument]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        loadDocument(from: url)
    }

    func presentImportImagePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        importImage(from: url)
    }

    func presentSaveDocumentPanel(suggestedFilename: String, contentType: UTType = .snipSnipDocument) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFilename

        return await ImageExporter.presentSavePanel(panel)
    }

    func loadDocument(from url: URL) {
        if handleIncompatibleDocumentIfNeeded(at: url) {
            return
        }

        do {
            if url.pathExtension.lowercased() == "sssvideo" {
                let document = try withSecurityScopedAccess(to: url) {
                    try SSSVideoDocumentPackage.load(from: url)
                }
                let posterImage = try? SSSVideoDocumentPackage.loadPosterImage(from: url)
                let controller = VideoEditorController(
                    recording: document.recording,
                    session: document.session,
                    posterImage: posterImage
                )
                installVideoController(controller, documentURL: url, savedSession: controller.documentSession)
            } else {
                let document = try withSecurityScopedAccess(to: url) {
                    try SSSDocumentPackage.load(from: url)
                }
                let controller = EditorController(
                    capture: document.capture,
                    session: document.session,
                    uiMapOverlayOptions: uiMapPinnedOverlayDefaults
                )
                installEditorController(controller, documentURL: url, savedSession: controller.documentSession)
            }
            requestMainWindowPresentation()
        } catch {
            present(error)
        }
    }

    func importImage(from url: URL) {
        do {
            let image = try withSecurityScopedAccess(to: url) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ImportedImageLoadError()
                }

                return image
            }

            let sourceName = url.deletingPathExtension().lastPathComponent
            importImage(image, sourceName: sourceName)
        } catch {
            present(error)
        }
    }

    func importImageFromPasteboard(named pasteboardName: String, sourceName: String?) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))

        do {
            guard let imageData = pasteboard.data(forType: .png)
                    ?? pasteboard.data(forType: .tiff),
                  let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw ImportedImageLoadError()
            }

            importImage(image, sourceName: sourceName ?? "Shared Photo")
            pasteboard.clearContents()
        } catch {
            present(error)
        }
    }

    private func importImage(_ image: CGImage, sourceName: String?) {
        let resolvedSourceName: String

        if let sourceName, !sourceName.isEmpty {
            resolvedSourceName = sourceName
        } else {
            resolvedSourceName = "Imported Image"
        }

        let capture = CapturedScreenshot(
            image: image,
            kind: .region,
            sourceName: resolvedSourceName,
            sourceRect: CGRect(origin: .zero, size: CGSize(width: image.width, height: image.height)),
            capturedAt: Date()
        )
        let controller = EditorController(
            capture: capture,
            uiMapOverlayOptions: uiMapPinnedOverlayDefaults
        )
        installEditorController(controller, documentURL: nil, savedSession: nil)
        requestMainWindowPresentation()
    }

    private static func isEditableDocumentURL(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "sss", "sssvideo":
            return true
        default:
            return false
        }
    }

    func updateDocumentChangeTracking() {
        if let controller = editorController {
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
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == AppSceneID.mainWindow
        }) else {
            return
        }

        if window.representedURL != currentDocumentURL {
            window.representedURL = currentDocumentURL
        }

        if window.isDocumentEdited != hasUnsavedChanges {
            window.isDocumentEdited = hasUnsavedChanges
        }

        let title = editorController == nil && videoEditorController == nil ? "SnipSnipSnip" : currentDocumentFilename

        if window.title != title {
            window.title = title
        }
    }

    func resizeMainWindowForEditorContentIfNeeded(animated: Bool = true) {
        guard editorController != nil || videoEditorController != nil,
              let window = NSApp.windows.first(where: { $0.identifier?.rawValue == AppSceneID.mainWindow }),
              let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        else {
            return
        }

        let imagePixelSize: CGSize
        if let editorController {
            imagePixelSize = editorController.capture.pixelSize
        } else if let videoController = videoEditorController {
            imagePixelSize = videoController.recording.bounds.size
        } else {
            return
        }

        let screenScale = screen.backingScaleFactor
        let imagePointSize = CGSize(
            width: imagePixelSize.width / screenScale,
            height: imagePixelSize.height / screenScale
        )

        // Chrome overhead: inspector sidebar + scrollbar gutter (width), header + toolbar + dividers (height)
        let chromeWidth: CGFloat = 300 + 30
        let chromeHeight: CGFloat = 150

        let minSize = CGSize(width: 900, height: 600)
        let maxSize = screen.visibleFrame.size

        let targetWidth = min(max(imagePointSize.width + chromeWidth, minSize.width), maxSize.width)
        let targetHeight = min(max(imagePointSize.height + chromeHeight, minSize.height), maxSize.height)
        let targetSize = CGSize(width: targetWidth, height: targetHeight)

        let targetOrigin = CGPoint(
            x: screen.visibleFrame.midX - targetSize.width / 2,
            y: screen.visibleFrame.midY - targetSize.height / 2
        )
        let targetFrame = CGRect(origin: targetOrigin, size: targetSize).integral

        guard targetFrame.width > 0, targetFrame.height > 0 else {
            return
        }

        if window.frame != targetFrame {
            window.setFrame(targetFrame, display: true, animate: animated)
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
}

extension AppModel {
    func currentProtectedTemporaryVideoURLs() -> [URL] {
        [videoEditorController?.recording.sourceURL, activeVideoRecording?.session.outputURL]
            .compactMap { $0 }
            .filter { TemporaryVideoMediaManager.isOwnedTemporaryMediaURL($0) }
    }

    func currentOwnedTemporaryVideoSourceURL(replacingWith newSourceURL: URL?) -> URL? {
        guard let currentSourceURL = videoEditorController?.recording.sourceURL,
              TemporaryVideoMediaManager.isOwnedTemporaryMediaURL(currentSourceURL) else {
            return nil
        }

        guard currentSourceURL.standardizedFileURL != newSourceURL?.standardizedFileURL else {
            return nil
        }

        return currentSourceURL
    }

    func cleanupTemporaryVideoSourceIfNeeded(previousSourceURL: URL?) {
        guard let previousSourceURL,
              TemporaryVideoMediaManager.isOwnedTemporaryMediaURL(previousSourceURL) else {
            return
        }

        try? FileManager.default.removeItem(at: previousSourceURL)
    }

    func cleanupTemporaryVideoSourceIfNeeded(_ previousSourceURL: URL?) {
        cleanupTemporaryVideoSourceIfNeeded(previousSourceURL: previousSourceURL)
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

nonisolated private struct ScreenshotDocumentWritePayload: @unchecked Sendable {
    let document: EditableScreenshotDocument
    let renderInput: ExportRenderInput
    let url: URL
    let includeUIMapSearchText: Bool
}

nonisolated private struct VideoDocumentWritePayload: @unchecked Sendable {
    let document: EditableVideoDocument
    let posterImage: CGImage?
    let url: URL
}

nonisolated private enum DocumentPackageWriter {
    static func saveScreenshot(_ payload: ScreenshotDocumentWritePayload) async throws {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            let previewImage = PresentationPerformanceMetrics.measure(
                "package.preview.content",
                context: "base=\(payload.renderInput.baseImage.width)x\(payload.renderInput.baseImage.height) crop=\(PresentationPerformanceMetrics.size(payload.renderInput.snapshot.cropRect.size)) annotations=\(payload.renderInput.snapshot.annotations.count)",
                warnAfterMS: 80
            ) {
                EditorRenderer.render(
                    baseImage: payload.renderInput.baseImage,
                    snapshot: payload.renderInput.snapshot,
                    pinnedUIMapElements: payload.renderInput.pinnedUIMapElements,
                    uiMapOverlayOptions: payload.renderInput.uiMapOverlayOptions
                )
            }

            guard let previewImage else {
                throw ImageExportError.encodingFailed
            }

            let presentedPreviewImage = PresentationPerformanceMetrics.measure(
                "package.preview.presentation",
                context: "content=\(previewImage.width)x\(previewImage.height) \(PresentationPerformanceMetrics.presentationSummary(payload.renderInput.snapshot.presentation))",
                warnAfterMS: 100
            ) {
                ScreenshotPresentationRenderer.render(
                    contentImage: previewImage,
                    presentation: payload.renderInput.snapshot.presentation
                )
            }

            guard let presentedPreviewImage else {
                throw ImageExportError.encodingFailed
            }

            try Task.checkCancellation()
            try SSSDocumentPackage.save(
                document: payload.document,
                previewImage: presentedPreviewImage,
                to: payload.url,
                includeUIMapSearchText: payload.includeUIMapSearchText
            )
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func saveVideo(_ payload: VideoDocumentWritePayload) async throws {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try SSSVideoDocumentPackage.save(
                document: payload.document,
                posterImage: payload.posterImage,
                to: payload.url
            )
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
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
    static func loadImage(from packageURL: URL) async throws -> CGImage? {
        let task = Task.detached(priority: .userInitiated) { () throws -> CGImage? in
            try Task.checkCancellation()
            return try SSSDocumentPackage.loadDisplayPreview(from: packageURL)?.image
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
