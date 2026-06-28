import Foundation

@MainActor
protocol AutomationStatusPort: AnyObject {
    var automationCapabilities: AutomationCapabilities { get }
    var automationPermissionSummary: AutomationPermissionSummary { get }
    var automationCapturePresets: [AutomationPresetSummary] { get }
}

@MainActor
protocol CaptureAutomationPort: AnyObject {
    func runAutomationPreset(
        _ command: RunPresetAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope
    func captureAutomation(
        _ command: CaptureAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope
    func repeatLastAutomationCapture(_ request: AutomationRequest) async -> AutomationResultEnvelope
}

@MainActor
protocol DocumentAutomationPort: AnyObject {
    var automationCurrentEditorController: EditorController? { get }
    var automationImageExportOptions: ImageExportOptions { get }

    func openAutomationDocument(
        _ command: OpenDocumentAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope
    func exportCurrentAutomationDocument(
        _ command: ExportCurrentAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope
    func requestAutomationEditorPresentation()
    func saveAutomationDocument(_ controller: EditorController, to url: URL) async -> Bool
    func floatAutomationReference()
}

@MainActor
protocol ClipboardAutomationPort: AnyObject {
    func markAutomationPasteboardChangeAsHandled()
}

@MainActor
final class AutomationWorkflowModel: AutomationHost, AutomationOutputPort {
    private weak var statusPort: (any AutomationStatusPort)?
    private weak var capturePort: (any CaptureAutomationPort)?
    private weak var documentPort: (any DocumentAutomationPort)?
    private weak var clipboardPort: (any ClipboardAutomationPort)?
    private let files: any FileSystemServicing
    private let workspace: any WorkspaceServicing
    private let pasteboard: any PasteboardServicing

    init(
        statusPort: any AutomationStatusPort,
        capturePort: any CaptureAutomationPort,
        documentPort: any DocumentAutomationPort,
        clipboardPort: any ClipboardAutomationPort,
        files: any FileSystemServicing,
        workspace: any WorkspaceServicing,
        pasteboard: any PasteboardServicing
    ) {
        self.statusPort = statusPort
        self.capturePort = capturePort
        self.documentPort = documentPort
        self.clipboardPort = clipboardPort
        self.files = files
        self.workspace = workspace
        self.pasteboard = pasteboard
    }

    var automationCapabilities: AutomationCapabilities {
        statusPort?.automationCapabilities ?? AutomationCapabilities(
            supportsURLScheme: true,
            supportsAppleScript: true,
            supportsCLI: true,
            supportsAppIntents: true,
            supportsCapturePresets: false,
            supportsPrivateCapture: false,
            supportsUIMap: false,
            supportsScrollingCapture: false,
            supportsConnectedDeviceCapture: false,
            supportsCurrentEditorExport: false
        )
    }

    var automationPermissionSummary: AutomationPermissionSummary {
        statusPort?.automationPermissionSummary ?? AutomationPermissionSummary(
            hasScreenRecording: false,
            hasAccessibility: false,
            hasMicrophone: false
        )
    }

    var automationCapturePresets: [AutomationPresetSummary] {
        statusPort?.automationCapturePresets ?? []
    }

    var automationCurrentEditorController: EditorController? {
        documentPort?.automationCurrentEditorController
    }

    var automationImageExportOptions: ImageExportOptions {
        documentPort?.automationImageExportOptions ?? ImageExportOptions()
    }

    func runAutomationPreset(
        _ command: RunPresetAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard let capturePort else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }
        return await capturePort.runAutomationPreset(command, request: request)
    }

    func captureAutomation(
        _ command: CaptureAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard let capturePort else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }
        return await capturePort.captureAutomation(command, request: request)
    }

    func repeatLastAutomationCapture(_ request: AutomationRequest) async -> AutomationResultEnvelope {
        guard let capturePort else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }
        return await capturePort.repeatLastAutomationCapture(request)
    }

    func openAutomationDocument(
        _ command: OpenDocumentAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard files.fileExists(atPath: command.url.path) else {
            return .failure(requestID: request.id, code: .targetUnavailable, message: "Document does not exist.")
        }
        guard let documentPort else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }
        return await documentPort.openAutomationDocument(command, request: request)
    }

    func exportCurrentAutomationDocument(
        _ command: ExportCurrentAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard let documentPort else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }
        return await documentPort.exportCurrentAutomationDocument(command, request: request)
    }

    func requestAutomationEditorPresentation() {
        documentPort?.requestAutomationEditorPresentation()
    }

    func markAutomationPasteboardChangeAsHandled() {
        clipboardPort?.markAutomationPasteboardChangeAsHandled()
    }

    func saveAutomationDocument(_ controller: EditorController, to url: URL) async -> Bool {
        await documentPort?.saveAutomationDocument(controller, to: url) ?? false
    }

    func floatAutomationReference() {
        documentPort?.floatAutomationReference()
    }

    func reveal(_ url: URL) {
        workspace.activateFileViewerSelecting([url])
    }

    func resultAfterCurrentEditorOutput(
        request: AutomationRequest,
        kind: String,
        sourceName: String?
    ) async -> AutomationResultEnvelope {
        do {
            let outputs = try await AutomationOutputService(
                port: self,
                files: files,
                workspace: workspace,
                pasteboard: pasteboard
            )
            .write(request.output)
            return .success(
                requestID: request.id,
                payload: .capture(AutomationCaptureSummary(kind: kind, sourceName: sourceName, acceptedInteractiveWorkflow: false)),
                outputs: outputs.isEmpty ? [.init(kind: .none)] : outputs
            )
        } catch let error as AutomationExecutionError {
            return .failure(requestID: request.id, code: error.code, message: error.message)
        } catch {
            return .failure(requestID: request.id, code: .outputFailed, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
