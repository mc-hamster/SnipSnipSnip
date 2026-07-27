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
protocol CompositionAutomationPort: AnyObject {
    var automationCompositionSummary: AutomationCompositionSummary? { get }

    func applyAutomationComposition(
        _ command: CompositionAutomationCommand
    ) throws -> AutomationCompositionSummary
}

@MainActor
protocol DocumentAutomationPort: CompositionAutomationPort {
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
    func exportCurrentAutomationGuide(_ format: GuideAutomationExportFormat, request: AutomationRequest) async -> AutomationResultEnvelope
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
    private weak var guidePort: (any GuideAutomationPort)?
    private let files: any FileSystemServicing
    private let workspace: any WorkspaceServicing
    private let pasteboard: any PasteboardServicing

    init(
        statusPort: any AutomationStatusPort,
        capturePort: any CaptureAutomationPort,
        documentPort: any DocumentAutomationPort,
        clipboardPort: any ClipboardAutomationPort,
        guidePort: any GuideAutomationPort,
        files: any FileSystemServicing,
        workspace: any WorkspaceServicing,
        pasteboard: any PasteboardServicing
    ) {
        self.statusPort = statusPort
        self.capturePort = capturePort
        self.documentPort = documentPort
        self.clipboardPort = clipboardPort
        self.guidePort = guidePort
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
            supportsCurrentEditorExport: false,
            supportsGuide: false
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

    func compositionAutomation(
        _ command: CompositionAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard automationCapabilities.supportsComposition else {
            return .failure(
                requestID: request.id,
                code: .featureUnavailable,
                message: "Composition is not available in this build."
            )
        }
        guard let documentPort else {
            return .failure(
                requestID: request.id,
                code: .internalError,
                message: "Automation workflow is not available."
            )
        }

        do {
            let summary = try documentPort.applyAutomationComposition(command)
            var outputs = try await writeAutomationOutput(
                request.output,
                appearance: request.appearance
            )
            outputs.removeAll { $0.kind == .none }
            outputs.insert(.init(kind: .updatedComposition), at: 0)
            return .success(
                requestID: request.id,
                payload: .composition(summary),
                outputs: outputs
            )
        } catch let error as AutomationExecutionError {
            return .failure(requestID: request.id, code: error.code, message: error.message)
        } catch {
            return .failure(
                requestID: request.id,
                code: .internalError,
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    func guideAutomation(_ command: GuideAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope {
        guard automationCapabilities.supportsGuide else {
            return .failure(
                requestID: request.id,
                code: .proFeatureRequired,
                message: "Guide capture and Guide automation are available in SnipSnipSnip Pro."
            )
        }
        if case .export(let format) = command {
            guard let documentPort else {
                return .failure(requestID: request.id, code: .internalError, message: "Guide export is unavailable.")
            }
            return await documentPort.exportCurrentAutomationGuide(format, request: request)
        }
        guard let guidePort else {
            return .failure(requestID: request.id, code: .internalError, message: "Guide automation is unavailable.")
        }
        return await guidePort.guideAutomation(command, request: request)
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
            var outputs = try await writeAutomationOutput(
                request.output,
                appearance: request.appearance
            )
            let compositionSummary: AutomationCompositionSummary?
            switch request.captureDestination {
            case .new:
                compositionSummary = nil
            case .append, .replace:
                guard let summary = documentPort?.automationCompositionSummary else {
                    return .failure(
                        requestID: request.id,
                        code: .noActiveComposition,
                        message: "The capture completed, but its target composition is no longer active."
                    )
                }
                compositionSummary = summary
                outputs.removeAll { $0.kind == .none }
                outputs.insert(.init(kind: .updatedComposition), at: 0)
            }

            return .success(
                requestID: request.id,
                payload: compositionSummary.map(AutomationPayload.composition)
                    ?? .capture(AutomationCaptureSummary(
                        kind: kind,
                        sourceName: sourceName,
                        acceptedInteractiveWorkflow: false
                    )),
                outputs: outputs.isEmpty ? [.init(kind: .none)] : outputs
            )
        } catch let error as AutomationExecutionError {
            return .failure(requestID: request.id, code: error.code, message: error.message)
        } catch {
            return .failure(requestID: request.id, code: .outputFailed, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func writeAutomationOutput(
        _ output: AutomationOutput,
        appearance: AutomationOutputAppearance
    ) async throws -> [AutomationOutputResult] {
        try await AutomationOutputService(
            port: self,
            files: files,
            workspace: workspace,
            pasteboard: pasteboard
        )
        .write(output, appearance: appearance)
    }
}
