import Foundation

extension DocumentWorkflowModel {
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
}
