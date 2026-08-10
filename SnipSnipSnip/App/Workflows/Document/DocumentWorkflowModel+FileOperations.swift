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
        exportAnnotatedImage(as: .png, appearance: .plain)
    }

    func exportAnnotatedImage(as format: ImageExportFormat, appearance: ScreenshotOutputAppearance) {
        if editorController?.hasComposition == true,
           let compositionFormat = CompositionOutputFormat(imageFormat: format) {
            exportComposition(as: compositionFormat, appearance: appearance)
            return
        }
        editorController?.saveAnnotatedImage(
            appearance: appearance,
            format: format,
            filenameTemplate: ScreenshotFilenameTemplate(pattern: screenshotFilenameTemplate),
            exportOptions: screenshotImageExportOptions
        )
    }

    func shareAnnotatedImage(appearance: ScreenshotOutputAppearance) {
        editorController?.shareAnnotatedImage(appearance: appearance)
    }

    func promisedAnnotatedImagePayload(appearance: ScreenshotOutputAppearance) -> PromisedFilePayload? {
        editorController?.promisedImagePayload(
            appearance: appearance,
            requestedFormat: screenshotDragOutFormat,
            filenameTemplate: ScreenshotFilenameTemplate(pattern: screenshotFilenameTemplate),
            exportOptions: screenshotImageExportOptions
        )
    }

    var screenshotImageExportOptions: ImageExportOptions {
        ImageExportOptions(jpegQuality: screenshotJPEGQuality)
    }

    func exportWorkflowCapture(
        from controller: EditorController,
        to destination: CapturePresetExportDestination
    ) async throws -> URL {
        let appearance = controller.automationOutputAppearance
        if controller.exportFormatRequiresPNG(appearance: appearance), destination.format != .png {
            throw ImageExportError.transparentPresentationRequiresPNG
        }

        let filename = ScreenshotFilenameTemplate(pattern: screenshotFilenameTemplate)
            .resolvedFilename(for: controller.capture, formatExtension: destination.format.fileExtension)
        let url = destination.folderURL
            .appendingPathComponent(filename)
            .appendingPathExtension(destination.format.fileExtension)
        let image = try await controller.renderedImageForExport(appearance: appearance)
        try await ImageExporter.write(image, format: destination.format, to: url, options: screenshotImageExportOptions)
        return url
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

        let document = controller.editableDocument
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
            currentDocumentURL = url
            savedDocumentSession = controller.documentSession
            controller.markDocumentSavedInCurrentFormat()
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
            let persistedController = VideoEditorController(
                recording: controller.recording.updatingSourceURL(
                    url.appendingPathComponent(SSSVideoDocumentPackage.mediaFilename)
                ),
                session: controller.documentSession,
                posterImage: controller.posterImage
            )
            installVideoController(persistedController, documentURL: url, savedSession: persistedController.documentSession)
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

        loadDocument(from: url)
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

    func loadDocument(from url: URL) {
        if handleIncompatibleDocumentIfNeeded(at: url) {
            return
        }

        do {
            if url.pathExtension.lowercased() == "sssguide" {
                let document = try withSecurityScopedAccess(to: url) {
                    try SSSGuideDocumentPackage.load(from: url, files: systemServices.files)
                }
                let controller = GuideEditorController(document: document)
                installGuideController(controller, documentURL: url, savedProject: controller.project)
                presentGuideDocumentProNoticeIfNeeded()
            } else if url.pathExtension.lowercased() == "sssvideo" {
                let document = try withSecurityScopedAccess(to: url) {
                    try SSSVideoDocumentPackage.load(from: url, files: systemServices.files)
                }
                let posterImage = try? SSSVideoDocumentPackage.loadPosterImage(from: url, files: systemServices.files)
                let controller = VideoEditorController(
                    recording: document.recording,
                    session: document.session,
                    posterImage: posterImage
                )
                installVideoController(controller, documentURL: url, savedSession: controller.documentSession)
            } else {
                let document = try withSecurityScopedAccess(to: url) {
                    try SSSDocumentPackage.load(from: url, files: systemServices.files)
                }
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
        do {
            guard let imageData = dependencies.pasteboardImporter.imageData(fromPasteboardNamed: pasteboardName),
                  let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw ImportedImageLoadError()
            }

            importImage(image, sourceName: sourceName ?? "Shared Photo")
            dependencies.pasteboardImporter.clearPasteboard(named: pasteboardName)
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
            capturedAt: systemServices.clock.now()
        )
        let controller = EditorController(
            capture: capture,
            capabilities: capabilities,
            uiMapOverlayOptions: uiMapPinnedOverlayDefaults
        )
        installEditorController(controller, documentURL: nil, savedSession: nil)
        requestMainWindowPresentation()
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
