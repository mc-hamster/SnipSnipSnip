import AppKit

extension DocumentWorkflowModel {
    func printCurrentDocument() {
        if let controller = guideEditorController {
            guard !controller.includedSteps.isEmpty else { return }
            let document = controller.editableDocument()
            printCoordinator.printDocument(
                title: document.project.title,
                prepare: {
                    try await Task.detached(priority: .userInitiated) {
                        try await GuidePrintRenderer.pdfData(document: document)
                    }.value
                },
                isCurrent: { [weak self, weak controller] in
                    controller != nil && self?.guideEditorController === controller
                },
                onError: { [weak self] in self?.present($0) }
            )
            return
        }
        guard videoEditorController == nil, let controller = editorController,
              controller.isDocumentOutputAvailable else { return }
        controller.commitPendingTextEdits()
        let appearance = controller.currentWorkspaceOutputAppearance
        do {
            let compositionInput = controller.hasComposition
                ? try controller.compositionOutputInput(appearance: appearance) : nil
            let outputSize = controller.screenshotOutputSize
            printCoordinator.printDocument(
                title: String(localized: "Screenshot"),
                prepare: {
                    if let compositionInput {
                        return try await Task.detached(priority: .userInitiated) {
                            try await CompositionOutputExporter.printPDFData(
                                compositionInput, outputSize: outputSize
                            )
                        }.value
                    }
                    let image = try await controller.renderedImageForExport(
                        appearance: appearance, usesOutputSize: true
                    )
                    return try await Task.detached(priority: .userInitiated) {
                        try ImageExporter.pdfData(for: image)
                    }.value
                },
                isCurrent: { [weak self, weak controller] in
                    controller != nil && self?.editorController === controller
                        && controller?.isDocumentOutputAvailable == true
                },
                onError: { [weak self] in self?.present($0) }
            )
        } catch {
            present(error)
        }
    }
}
