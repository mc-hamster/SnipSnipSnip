import Foundation

@MainActor
extension DocumentWorkflowModel {
    var automationCurrentEditorController: EditorController? {
        editorController
    }

    var automationImageExportOptions: ImageExportOptions {
        screenshotImageExportOptions
    }

    func openAutomationDocument(
        _ command: OpenDocumentAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard let automationCoordinator else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }

        automationCoordinator.openDocument(command.url)
        return await automationCoordinator.automationResultAfterCurrentEditorOutput(request, "openDocument", command.url.lastPathComponent)
    }

    func exportCurrentAutomationDocument(
        _ command: ExportCurrentAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard let automationCoordinator else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }

        var exportRequest = request
        if case .appDefault = exportRequest.output {
            exportRequest.output = .saveFile(AutomationFileOutput(url: nil, format: command.format))
        }
        return await automationCoordinator.automationResultAfterCurrentEditorOutput(exportRequest, "exportCurrent", automationCurrentEditorController?.capture.sourceName)
    }

    func requestAutomationEditorPresentation() {
        dependencies.lifecycle.requestMainWindowPresentation()
    }

    func saveAutomationDocument(_ controller: EditorController, to url: URL) async -> Bool {
        await automationCoordinator?.saveDocument(controller, to: url) ?? false
    }

    func floatAutomationReference() {
        automationCoordinator?.floatCurrentEditorReference()
    }
}
