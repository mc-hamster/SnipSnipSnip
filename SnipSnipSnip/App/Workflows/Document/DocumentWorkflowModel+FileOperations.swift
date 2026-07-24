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

    func exportWorkflowCapture(
        from controller: EditorController,
        to destination: CapturePresetExportDestination
    ) async throws -> URL {
        if controller.exportFormatRequiresPNG(), destination.format != .png {
            throw ImageExportError.transparentPresentationRequiresPNG
        }

        let filename = ScreenshotFilenameTemplate(pattern: screenshotFilenameTemplate)
            .resolvedFilename(for: controller.capture, formatExtension: destination.format.fileExtension)
        let url = destination.folderURL
            .appendingPathComponent(filename)
            .appendingPathExtension(destination.format.fileExtension)
        let image = try await controller.renderedImageForExport()
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
    let renderInput: ExportRenderInput
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
