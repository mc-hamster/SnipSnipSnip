import AppKit
import Foundation

struct AutomationExecutionError: LocalizedError {
    var code: AutomationErrorCode
    var message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
protocol AutomationCommandHandler: AnyObject {
    var automationPermissionPreflight: AutomationPermissionPreflight { get }
    var automationCapturePresets: [AutomationPresetSummary] { get }

    func runAutomationPreset(_ command: RunPresetAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope
    func captureAutomation(_ command: CaptureAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope
    func repeatLastAutomationCapture(_ request: AutomationRequest) async -> AutomationResultEnvelope
    func openAutomationDocument(_ command: OpenDocumentAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope
    func exportCurrentAutomationDocument(_ command: ExportCurrentAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope
}

@MainActor
final class AutomationExecutor {
    private weak var handler: AutomationCommandHandler?

    init(handler: AutomationCommandHandler) {
        self.handler = handler
    }

    func perform(_ request: AutomationRequest) async -> AutomationResultEnvelope {
        if let validationError = request.validationError {
            return .failure(requestID: request.id, code: validationError.code, message: validationError.message)
        }

        guard let handler else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation host is not available.")
        }

        switch request.command {
        case .status:
            return .success(
                requestID: request.id,
                payload: .preflight(handler.automationPermissionPreflight),
                outputs: [.init(kind: .none)]
            )
        case .listPresets:
            return .success(
                requestID: request.id,
                payload: .presets(handler.automationCapturePresets),
                outputs: [.init(kind: .none)]
            )
        case .runPreset(let command):
            return await handler.runAutomationPreset(command, request: request)
        case .capture(let command):
            return await handler.captureAutomation(command, request: request)
        case .repeatLastCapture:
            return await handler.repeatLastAutomationCapture(request)
        case .openDocument(let command):
            return await handler.openAutomationDocument(command, request: request)
        case .exportCurrent(let command):
            return await handler.exportCurrentAutomationDocument(command, request: request)
        }
    }
}

@MainActor
protocol AutomationOutputPort: AnyObject {
    var automationCurrentEditorController: EditorController? { get }
    var automationImageExportOptions: ImageExportOptions { get }

    func requestAutomationEditorPresentation()
    func markAutomationPasteboardChangeAsHandled()
    func saveAutomationDocument(_ controller: EditorController, to url: URL) async -> Bool
    func floatAutomationReference()
}

@MainActor
final class AutomationOutputService {
    private weak var port: AutomationOutputPort?
    private let files: any FileSystemServicing
    private let workspace: any WorkspaceServicing
    private let pasteboard: any PasteboardServicing

    init(
        port: AutomationOutputPort,
        files: any FileSystemServicing = SystemFileService(),
        workspace: any WorkspaceServicing = SystemWorkspaceService(),
        pasteboard: any PasteboardServicing = SystemPasteboardService()
    ) {
        self.port = port
        self.files = files
        self.workspace = workspace
        self.pasteboard = pasteboard
    }

    func write(_ output: AutomationOutput) async throws -> [AutomationOutputResult] {
        guard let port else {
            throw AutomationExecutionError(code: .internalError, message: "Automation output host is not available.")
        }

        switch output {
        case .appDefault, .openEditor:
            port.requestAutomationEditorPresentation()
            return [.init(kind: .openedEditor)]
        case .copyRenderedImage:
            guard let controller = port.automationCurrentEditorController,
                  let image = controller.exportedImage(usingPresentation: true) else {
                throw AutomationExecutionError(code: .targetUnavailable, message: "There is no current screenshot to copy.")
            }
            try ImageExporter.copyToClipboard(image, pasteboard: pasteboard)
            port.markAutomationPasteboardChangeAsHandled()
            return [.init(kind: .copiedClipboard)]
        case .saveFile(let file):
            guard file.format != .sss else {
                throw AutomationExecutionError(code: .unsupportedOutput, message: "Rendered file output does not support .sss.")
            }
            let url = try outputURL(file)
            guard let format = ImageExportFormat(automationFormat: file.format),
                  let image = port.automationCurrentEditorController?.exportedImage(usingPresentation: true) else {
                throw AutomationExecutionError(code: .targetUnavailable, message: "There is no current screenshot to export.")
            }
            try await writeFile(to: url, overwrite: file.overwrite) {
                try await ImageExporter.write(image, format: format, to: url, options: port.automationImageExportOptions)
            }
            revealIfNeeded(url, reveal: file.revealInFinder)
            return [.init(kind: .savedFile, url: url, format: file.format)]
        case .saveEditableDocument(let file):
            guard file.format == .sss else {
                throw AutomationExecutionError(code: .unsupportedOutput, message: "Editable document output only supports .sss.")
            }
            guard let controller = port.automationCurrentEditorController else {
                throw AutomationExecutionError(code: .targetUnavailable, message: "There is no current screenshot document to save.")
            }
            if controller.containsRedactions {
                throw AutomationExecutionError(code: .confirmationRequired, message: "Editable .sss output with redactions requires user confirmation because original pixels remain in the package.")
            }
            let url = try outputURL(file)
            try await writeFile(to: url, overwrite: file.overwrite) {
                guard await port.saveAutomationDocument(controller, to: url) else {
                    throw AutomationExecutionError(code: .outputFailed, message: "The editable document could not be saved.")
                }
            }
            revealIfNeeded(url, reveal: file.revealInFinder)
            return [.init(kind: .savedEditableDocument, url: url, format: .sss)]
        case .floatReference:
            port.floatAutomationReference()
            return [.init(kind: .floatedReference)]
        case .none:
            return [.init(kind: .none)]
        }
    }

    private func outputURL(_ file: AutomationFileOutput) throws -> URL {
        guard let url = file.url else {
            throw AutomationExecutionError(code: .invalidRequest, message: "Automation file output requires a path.")
        }
        return url
    }

    private func writeFile(to url: URL, overwrite: Bool, operation: () async throws -> Void) async throws {
        if files.fileExists(atPath: url.path), !overwrite {
            throw AutomationExecutionError(code: .outputFailed, message: "Output file already exists. Pass overwrite to replace it.")
        }
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await operation()
    }

    private func revealIfNeeded(_ url: URL, reveal: Bool) {
        guard reveal else {
            return
        }
        workspace.activateFileViewerSelecting([url])
    }
}

extension ImageExportFormat {
    init?(automationFormat: AutomationExportFormat) {
        switch automationFormat {
        case .png:
            self = .png
        case .jpeg:
            self = .jpeg
        case .pdf:
            self = .pdf
        case .sss:
            return nil
        }
    }
}
