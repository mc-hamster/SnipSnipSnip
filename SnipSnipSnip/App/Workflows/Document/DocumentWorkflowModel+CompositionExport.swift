import AppKit
import Foundation

private enum CompositionOversizedOutputChoice {
    case scaleToFit
    case paginatedPDF
    case cancel
}

extension DocumentWorkflowModel {
    func exportCurrentWorkspaceImage(as format: ImageExportFormat) {
        guard let controller = editorController,
              controller.isDocumentOutputAvailable else {
            return
        }
        exportAnnotatedImage(
            as: format,
            appearance: controller.currentWorkspaceOutputAppearance
        )
    }

    func shareCurrentWorkspaceImage() {
        guard let controller = editorController,
              controller.isDocumentOutputAvailable else {
            return
        }
        shareAnnotatedImage(
            appearance: controller.currentWorkspaceOutputAppearance
        )
    }

    var currentWorkspaceOutputRequiresPNG: Bool {
        guard let controller = editorController,
              controller.isDocumentOutputAvailable else {
            return false
        }
        return controller.exportFormatRequiresPNG(
            appearance: controller.currentWorkspaceOutputAppearance
        )
    }

    func exportComposition(
        as format: CompositionOutputFormat,
        appearance: ScreenshotOutputAppearance
    ) {
        guard let controller = editorController else {
            return
        }
        let outputInput: CompositionOutputInput
        do {
            outputInput = try controller.compositionOutputInput(
                appearance: appearance
            )
        } catch {
            present(error)
            return
        }
        let preflight: CompositionOutputPreflight
        do {
            preflight = try CompositionOutputExporter.preflight(
                outputInput,
                format: format
            )
        } catch {
            present(error)
            return
        }
        var maximumOutputDimension: Int?
        var forcedPDFItemsPerPage: Int?
        if preflight.isOversized {
            switch compositionOversizedOutputChoice(
                preflight: preflight,
                format: format
            ) {
            case .scaleToFit:
                maximumOutputDimension =
                    preflight.recommendedMaximumOutputDimension
            case .paginatedPDF:
                forcedPDFItemsPerPage = 1
                do {
                    let pagePreflight = try CompositionOutputExporter.preflight(
                        outputInput,
                        format: format,
                        forcedPDFItemsPerPage: 1
                    )
                    maximumOutputDimension = pagePreflight.isOversized
                        ? pagePreflight.recommendedMaximumOutputDimension
                        : nil
                } catch {
                    present(error)
                    return
                }
            case .cancel:
                return
            }
        }

        let resolved = ScreenshotFilenameTemplate(
            pattern: screenshotFilenameTemplate
        ).resolvedFilename(
            for: controller.capture,
            formatExtension: format.fileExtension
        )
        let base = (resolved as NSString).deletingPathExtension
        let filename =
            "\(base.isEmpty ? "Composition" : base)-"
            + "\(appearance.filenameSuffix).\(format.fileExtension)"

        Task { @MainActor [weak self, weak controller] in
            guard let self,
                  let controller,
                  let destination = await dependencies.panels
                    .selectSaveDestination(
                        suggestedFilename: filename,
                        contentType: format.contentType
                    ) else {
                return
            }
            do {
                let result = try await CompositionOutputExporter.export(
                    outputInput,
                    format: format,
                    to: destination,
                    imageOptions: screenshotImageExportOptions,
                    maximumOutputDimension: maximumOutputDimension,
                    forcedPDFItemsPerPage: forcedPDFItemsPerPage
                )
                var message = String(
                    localized: "Exported \(format.label) to \(destination.lastPathComponent)."
                )
                if result.pageCount > 1 {
                    message += " \(result.pageCount) PDF pages were created."
                }
                if let disclosure = result.disclosure {
                    message += " \(disclosure)"
                }
                controller.showNotice(
                    EditorNotice(
                        message: message,
                        action: .reveal(destination),
                        dismissalDelaySeconds: 7
                    )
                )
            } catch {
                self.present(error)
            }
        }
    }

    private func compositionOversizedOutputChoice(
        preflight: CompositionOutputPreflight,
        format: CompositionOutputFormat
    ) -> CompositionOversizedOutputChoice {
        let workingSetMB = max(
            1,
            Int(ceil(Double(preflight.estimatedWorkingSetBytes) / 1_048_576))
        )
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Composition Is Too Large for a Full-Size Raster"
        alert.informativeText = """
        The estimated output is \(preflight.sizeDescription) pixels and may use about \(workingSetMB) MB while rendering. Scale it to the safe raster limits\(preflight.canUsePaginatedPDF ? ", or put each step on its own PDF page" : "").
        """
        alert.addButton(withTitle: "Scale to Fit")
        if preflight.canUsePaginatedPDF && format == .pdf {
            alert.addButton(withTitle: "Paginated PDF")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return .scaleToFit
            case .alertSecondButtonReturn:
                return .paginatedPDF
            default:
                return .cancel
            }
        }
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
            ? .scaleToFit
            : .cancel
    }
}
