import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension DocumentWorkflowModel {
    private struct ImportedImageLoadError: LocalizedError {
        var errorDescription: String? {
            "The selected file could not be loaded as an image."
        }
    }

    func openDocumentPanel() {
        presentOpenDocumentPanel()
    }

    func importImagePanel() {
        presentImportImagePanel()
    }

    func openDocument(at url: URL) {
        guard let candidate = prepareDocument(from: url) else { return }
        let isReopeningUnsavedDocument = hasUnsavedChanges
            && currentDocumentURL?.standardizedFileURL == url.standardizedFileURL
        performAfterHandlingUnsavedChanges { [weak self] in
            guard let self else { return }
            // Save may have just updated this same file. Keep the saved editor
            // rather than installing the older candidate loaded before Save.
            if isReopeningUnsavedDocument,
               self.currentDocumentURL?.standardizedFileURL == url.standardizedFileURL,
               !self.hasUnsavedChanges {
                return
            }
            self.installPreparedDocument(candidate, documentURL: url)
        }
    }

    func openExternalFile(at url: URL) {
        if Self.isEditableDocumentURL(url) {
            openDocument(at: url)
        } else {
            importImage(from: url)
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

    @discardableResult
    func saveCurrentDocument() async -> Bool {
        if let controller = guideEditorController {
            return await saveCurrentGuideDocument(controller)
        }
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
            if controller.requiresDocumentFormatMigration {
                switch documentFormatMigrationDecisionHandler() {
                case .saveV7:
                    targetURL = currentDocumentURL
                case .saveCopy:
                    let suggestedFilename = currentDocumentURL
                        .deletingPathExtension()
                        .lastPathComponent + " v7"
                    guard let selectedURL = await presentSaveDocumentPanel(suggestedFilename: suggestedFilename) else {
                        return false
                    }
                    targetURL = selectedURL
                case .cancel:
                    return false
                }
            } else {
                targetURL = currentDocumentURL
            }
        } else {
            guard let selectedURL = await presentSaveDocumentPanel(suggestedFilename: ScreenshotFilenameTemplate(pattern: screenshotFilenameTemplate).resolvedFilename(for: controller.capture, formatExtension: "sss")) else {
                return false
            }

            targetURL = selectedURL
        }

        guard editorController === controller else { return false }
        return await saveDocument(controller, to: targetURL)
    }

    @discardableResult
    func saveCurrentDocumentAs() async -> Bool {
        if let controller = guideEditorController {
            return await saveCurrentGuideDocumentAs(controller)
        }
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

        guard editorController === controller else { return false }
        return await saveDocument(controller, to: selectedURL)
    }

    @discardableResult
    func handleEditableRedactionSaveIfNeeded(for controller: EditorController) -> Bool {
        guard controller.containsRedactions || controller.isPrivateDocument else {
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
            exportAnnotatedImage(as: .png, appearance: .plain)
            return false
        case .cancel:
            return false
        }
    }

    @discardableResult
    func saveDocument(_ controller: EditorController, to url: URL) async -> Bool {
        controller.commitPendingTextEdits()

        let wasCurrentController = editorController === controller
        let document = controller.editableDocument
        let savedState = AutosaveState(controller: controller, documentURL: url)
        let payload = ScreenshotDocumentWritePayload(
            document: document,
            renderInput: controller.compositionDocumentPreviewInput(),
            url: url,
            includeUIMapSearchText: windowUIMapEnabled,
            files: systemServices.files
        )

        do {
            try await performDocumentWork(message: "Saving") {
                try await withSecurityScopedAccess(to: url) {
                    try await DocumentPackageWriter.saveScreenshot(payload)
                }
            }
            guard editorController === controller else {
                // A background save may finish after another document opens.
                // Its file is valid, but it must not relabel that editor or
                // allow an old Save-and-Continue action to replace it.
                return !wasCurrentController
            }
            currentDocumentURL = url
            savedDocumentSession = document.session
            controller.markDocumentSavedInCurrentFormat()
            savedEditorAutosaveState = savedState
            updateDocumentChangeTracking()
            recordRecoveryCheckpoint(for: controller, label: hasUnsavedChanges ? "Autosave" : "Saved", pendingRecovery: hasUnsavedChanges)
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

        guard videoEditorController === controller else { return false }
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

        guard videoEditorController === controller else { return false }
        return await saveVideoDocument(controller, to: selectedURL)
    }

    @discardableResult
    func saveVideoDocument(_ controller: VideoEditorController, to url: URL) async -> Bool {
        let wasCurrentController = videoEditorController === controller
        let wasRecoveryCheckpointVideo = currentVideoUsesRecoveryCheckpoint
        let payload = VideoDocumentWritePayload(
            document: EditableVideoDocument(recording: controller.recording, session: controller.documentSession),
            posterImage: controller.posterImage,
            url: url,
            files: systemServices.files
        )

        do {
            try await performDocumentWork(message: "Saving") {
                try await withSecurityScopedAccess(to: url) {
                    try await DocumentPackageWriter.saveVideo(payload)
                }
            }
            guard videoEditorController === controller else { return !wasCurrentController }
            let mediaURL = url.appendingPathComponent(SSSVideoDocumentPackage.mediaFilename)
            let previousTemporarySource = currentOwnedTemporaryVideoSourceURL(replacingWith: mediaURL)
            controller.rebaseSourceURL(mediaURL)
            currentDocumentURL = url
            savedVideoSession = payload.document.session
            updateDocumentChangeTracking()
            // An already-running export may still be consuming the old media.
            // Otherwise the durable package now owns the source pixels.
            if !controller.isExporting { cleanupTemporaryVideoSourceIfNeeded(previousTemporarySource) }
            completeVideoRecoveryAfterSave(wasRecoveryCheckpointVideo)
            return true
        } catch {
            present(error)
            return false
        }
    }

    func presentOpenDocumentPanel() {
        guard let url = dependencies.panels.selectDocumentToOpen() else {
            return
        }

        openDocument(at: url)
    }

    func presentImportImagePanel() {
        guard let url = dependencies.panels.selectImageToImport() else {
            return
        }

        importImage(from: url)
    }

    func presentSaveDocumentPanel(suggestedFilename: String, contentType: UTType = .snipSnipDocument) async -> URL? {
        await dependencies.panels.selectSaveDestination(suggestedFilename: suggestedFilename, contentType: contentType)
    }

    /// A complete replacement is prepared before the current document can be
    /// discarded. Keeping the controller alive also avoids reopening the file
    /// after the person approves the switch.
    enum PreparedDocument {
        case screenshot(EditorController)
        case video(VideoEditorController)
        case guide(GuideEditorController)
    }

    func loadDocument(from url: URL) {
        guard let candidate = prepareDocument(from: url) else { return }
        installPreparedDocument(candidate, documentURL: url)
    }

    private func prepareDocument(from url: URL) -> PreparedDocument? {
        do { return try readPreparedDocument(from: url) }
        catch { present(error); return nil }
    }

    func readPreparedDocument(from url: URL) throws -> PreparedDocument {
        return try withSecurityScopedAccess(to: url) {
            if url.pathExtension.lowercased() == "sssguide" {
                let document = try SSSGuideDocumentPackage.load(from: url, files: systemServices.files)
                return .guide(GuideEditorController(document: document))
            } else if url.pathExtension.lowercased() == "sssvideo" {
                let document = try SSSVideoDocumentPackage.load(from: url, files: systemServices.files)
                let posterImage = try? SSSVideoDocumentPackage.loadPosterImage(from: url, files: systemServices.files)
                return .video(VideoEditorController(
                    recording: document.recording,
                    session: document.session,
                    posterImage: posterImage
                ))
            } else {
                let document = try SSSDocumentPackage.load(from: url, files: systemServices.files)
                let controller = EditorController(
                    capture: document.capture,
                    session: document.session,
                    capabilities: capabilities,
                    uiMapOverlayOptions: uiMapPinnedOverlayDefaults,
                    isPrivateDocument: document.isPrivate,
                    workflowResumeState: document.workflowResumeState,
                    sourceDocumentFormatVersion: document.sourceFormatVersion,
                    compositionStoredAssets: document.compositionStoredAssets
                )
                controller.restoreWorkflowWorkspace()
                return .screenshot(controller)
            }
        }
    }


    func installPreparedDocument(_ candidate: PreparedDocument, documentURL: URL?) {
        switch candidate {
        case .screenshot(let controller):
            installEditorController(controller, documentURL: documentURL,
                                    savedSession: documentURL == nil ? nil : controller.documentSession)
        case .video(let controller):
            installVideoController(controller, documentURL: documentURL, savedSession: controller.documentSession)
        case .guide(let controller):
            installGuideController(controller, documentURL: documentURL, savedProject: controller.project)
            presentGuideDocumentProNoticeIfNeeded()
        }
        requestMainWindowPresentation()
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
            let controller = importedImageController(image, sourceName: url.deletingPathExtension().lastPathComponent)
            performAfterHandlingUnsavedChanges { [weak self] in
                self?.installPreparedDocument(.screenshot(controller), documentURL: nil)
            }
        } catch {
            present(error)
        }
    }

    func importImageFromPasteboard(named pasteboardName: String, sourceName: String?) {
        do {
            let isPrivate = dependencies.pasteboardImporter.isConcealed(fromPasteboardNamed: pasteboardName)
            guard let imageData = dependencies.pasteboardImporter.imageData(fromPasteboardNamed: pasteboardName),
                  let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw ImportedImageLoadError()
            }

            importImage(image, sourceName: sourceName ?? "Shared Photo", isPrivate: isPrivate) { [weak self] in
                self?.dependencies.pasteboardImporter.clearPasteboard(named: pasteboardName)
            }
        } catch {
            present(error)
        }
    }

    private func importImage(_ image: CGImage, sourceName: String?, isPrivate: Bool = false, onCommit: @escaping () -> Void) {
        let controller = importedImageController(image, sourceName: sourceName, isPrivate: isPrivate)
        performAfterHandlingUnsavedChanges { [weak self] in
            guard let self else { return }
            self.installPreparedDocument(.screenshot(controller), documentURL: nil)
            onCommit()
        }
    }

    private func importedImageController(_ image: CGImage, sourceName: String?, isPrivate: Bool = false) -> EditorController {
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
            capturedAt: systemServices.clock.now()
        )
        return EditorController(
            capture: capture,
            capabilities: capabilities,
            uiMapOverlayOptions: uiMapPinnedOverlayDefaults,
            isPrivateDocument: isPrivate
        )
    }

    private static func isEditableDocumentURL(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "sss", "sssvideo", "sssguide":
            return true
        default:
            return false
        }
    }
}

nonisolated private struct ScreenshotDocumentWritePayload: @unchecked Sendable {
    let document: EditableScreenshotDocument
    let renderInput: CompositionDocumentPreviewInput
    let url: URL
    let includeUIMapSearchText: Bool
    let files: any FileSystemServicing
}

nonisolated private struct VideoDocumentWritePayload: @unchecked Sendable {
    let document: EditableVideoDocument
    let posterImage: CGImage?
    let url: URL
    let files: any FileSystemServicing
}

nonisolated private enum DocumentPackageWriter {
    static func saveScreenshot(_ payload: ScreenshotDocumentWritePayload) async throws {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            let presentedPreviewImage = try CompositionDocumentPreviewRenderer.render(
                payload.renderInput
            )

            try Task.checkCancellation()
            try SSSDocumentPackage.save(
                document: payload.document,
                previewImage: presentedPreviewImage,
                to: payload.url,
                includeUIMapSearchText: payload.includeUIMapSearchText,
                files: payload.files
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
                to: payload.url,
                files: payload.files
            )
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
