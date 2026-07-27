import AppKit
import Foundation
import OSLog

nonisolated struct AutomationExecutionError: LocalizedError {
    var code: AutomationErrorCode
    var message: String

    var errorDescription: String? {
        message
    }
}

nonisolated struct AutomationFileDestinationPolicy {
    var restrictsUnattendedOutputToDownloads: Bool
    var downloadsDirectory: URL?

    static var current: AutomationFileDestinationPolicy {
#if APP_STORE_BUILD
        AutomationFileDestinationPolicy(
            restrictsUnattendedOutputToDownloads: true,
            downloadsDirectory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        )
#else
        AutomationFileDestinationPolicy(
            restrictsUnattendedOutputToDownloads: false,
            downloadsDirectory: nil
        )
#endif
    }

    func validate(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw AutomationExecutionError(
                code: .invalidRequest,
                message: "Automation file output requires a local file path."
            )
        }

        let candidate = url.standardizedFileURL
        guard restrictsUnattendedOutputToDownloads else { return candidate }
        guard let downloadsDirectory else {
            throw AutomationExecutionError(
                code: .permissionDenied,
                message: "The Downloads folder is unavailable for unattended automation output."
            )
        }

        let downloads = downloadsDirectory.standardizedFileURL
        let downloadsComponents = downloads.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > downloadsComponents.count,
              candidateComponents.prefix(downloadsComponents.count).elementsEqual(downloadsComponents) else {
            throw AutomationExecutionError(
                code: .permissionDenied,
                message: "The App Store build can save unattended automation output only in Downloads. Choose a Downloads path or use an interactive export."
            )
        }
        return candidate
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
    func compositionAutomation(_ command: CompositionAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope
    func guideAutomation(_ command: GuideAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope
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
        case .composition(let command):
            return await handler.compositionAutomation(command, request: request)
        case .guide(let command):
            return await handler.guideAutomation(command, request: request)
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
    private let destinationPolicy: AutomationFileDestinationPolicy

    init(
        port: AutomationOutputPort,
        files: any FileSystemServicing = SystemFileService(),
        workspace: any WorkspaceServicing = SystemWorkspaceService(),
        pasteboard: any PasteboardServicing = SystemPasteboardService(),
        destinationPolicy: AutomationFileDestinationPolicy = .current
    ) {
        self.port = port
        self.files = files
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.destinationPolicy = destinationPolicy
    }

    func write(
        _ output: AutomationOutput,
        appearance requestedAppearance: AutomationOutputAppearance = .appDefault
    ) async throws -> [AutomationOutputResult] {
        ShortcutsAutomationLog.logger.info(
            "output.write start output=\(output.debugSummary, privacy: .public)"
        )
        guard let port else {
            ShortcutsAutomationLog.logger.error("output.write failed host unavailable")
            throw AutomationExecutionError(code: .internalError, message: "Automation output host is not available.")
        }

        switch output {
        case .appDefault, .openEditor:
            ShortcutsAutomationLog.logger.info("output.write presenting editor")
            port.requestAutomationEditorPresentation()
            return [.init(kind: .openedEditor)]
        case .copyRenderedImage:
            guard let controller = port.automationCurrentEditorController else {
                ShortcutsAutomationLog.logger.error("output.write copy failed current editor/image unavailable")
                throw AutomationExecutionError(code: .targetUnavailable, message: "There is no current screenshot to copy.")
            }
            let image: CGImage
            do {
                image = try controller.exportedImage(
                    appearance: resolvedAppearance(
                        requestedAppearance,
                        controller: controller
                    )
                )
            } catch {
                ShortcutsAutomationLog.logger.error("output.write copy failed rendered image unavailable")
                throw AutomationExecutionError(
                    code: .outputFailed,
                    message: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                )
            }
            if !controller.isPrivateDocument {
                ShortcutsAutomationLog.logger.info(
                    "output.write copy image width=\(image.width, privacy: .public) height=\(image.height, privacy: .public)"
                )
            }
            try ImageExporter.copyToClipboard(image, pasteboard: pasteboard)
            port.markAutomationPasteboardChangeAsHandled()
            ShortcutsAutomationLog.logger.info("output.write copy finished")
            return [.init(kind: .copiedClipboard)]
        case .saveFile(let file):
            guard file.format != .sss else {
                ShortcutsAutomationLog.logger.error("output.write saveFile rejected sss")
                throw AutomationExecutionError(code: .unsupportedOutput, message: "Rendered file output does not support .sss.")
            }
            let url = try outputURL(file)
            ShortcutsAutomationLog.logger.info(
                "output.write saveFile resolved url=\(url.path, privacy: .public) format=\(file.format.rawValue, privacy: .public) overwrite=\(file.overwrite, privacy: .public)"
            )
            guard let controller = port.automationCurrentEditorController else {
                ShortcutsAutomationLog.logger.error("output.write saveFile failed current editor unavailable")
                throw AutomationExecutionError(code: .targetUnavailable, message: "There is no current screenshot to export.")
            }
            guard let compositionFormat = CompositionOutputFormat(
                automationFormat: file.format
            ) else {
                throw AutomationExecutionError(
                    code: .unsupportedOutput,
                    message: "Editable .sss output must use the editable-document destination."
                )
            }
            do {
                try await writeFile(to: url, overwrite: file.overwrite) {
                    ShortcutsAutomationLog.logger.info(
                        "output.write saveFile invoking composition output url=\(url.path, privacy: .public)"
                    )
                    _ = try await controller.exportComposition(
                        format: compositionFormat,
                        appearance: resolvedAppearance(
                            requestedAppearance,
                            controller: controller
                        ),
                        to: url,
                        imageOptions: port.automationImageExportOptions
                    )
                }
            } catch let error as CompositionOutputError {
                let code: AutomationErrorCode
                if error.isUnsupportedCombination {
                    code = .unsupportedComparisonOutput
                } else if error.isOversized {
                    code = .oversizedOutput
                } else {
                    code = .outputFailed
                }
                throw AutomationExecutionError(
                    code: code,
                    message: error.errorDescription ?? "Composition export failed."
                )
            }
            ShortcutsAutomationLog.logger.info(
                "output.write saveFile finished url=\(url.path, privacy: .public) exists=\(self.files.fileExists(atPath: url.path), privacy: .public)"
            )
            revealIfNeeded(url, reveal: file.revealInFinder)
            return [.init(kind: .savedFile, url: url, format: file.format)]
        case .saveEditableDocument(let file):
            guard file.format == .sss else {
                ShortcutsAutomationLog.logger.error("output.write saveEditable rejected format=\(file.format.rawValue, privacy: .public)")
                throw AutomationExecutionError(code: .unsupportedOutput, message: "Editable document output only supports .sss.")
            }
            guard let controller = port.automationCurrentEditorController else {
                ShortcutsAutomationLog.logger.error("output.write saveEditable failed current editor unavailable")
                throw AutomationExecutionError(code: .targetUnavailable, message: "There is no current screenshot document to save.")
            }
            if controller.containsRedactions || controller.isPrivateDocument {
                ShortcutsAutomationLog.logger.error("output.write saveEditable rejected source-pixel warning")
                throw AutomationExecutionError(
                    code: .confirmationRequired,
                    message: "Editable .sss output with redactions or private captures requires user confirmation because original pixels remain in the package."
                )
            }
            let url = try outputURL(file)
            ShortcutsAutomationLog.logger.info(
                "output.write saveEditable resolved url=\(url.path, privacy: .public) overwrite=\(file.overwrite, privacy: .public)"
            )
            try await writeFile(to: url, overwrite: file.overwrite) {
                ShortcutsAutomationLog.logger.info(
                    "output.write saveEditable invoking document save url=\(url.path, privacy: .public)"
                )
                guard await port.saveAutomationDocument(controller, to: url) else {
                    throw AutomationExecutionError(code: .outputFailed, message: "The editable document could not be saved.")
                }
            }
            ShortcutsAutomationLog.logger.info(
                "output.write saveEditable finished url=\(url.path, privacy: .public) exists=\(self.files.fileExists(atPath: url.path), privacy: .public)"
            )
            revealIfNeeded(url, reveal: file.revealInFinder)
            return [.init(kind: .savedEditableDocument, url: url, format: .sss)]
        case .floatReference:
            ShortcutsAutomationLog.logger.info("output.write floating reference")
            port.floatAutomationReference()
            return [.init(kind: .floatedReference)]
        case .none:
            ShortcutsAutomationLog.logger.info("output.write none")
            return [.init(kind: .none)]
        }
    }

    private func outputURL(_ file: AutomationFileOutput) throws -> URL {
        guard let url = file.url else {
            ShortcutsAutomationLog.logger.error("output.url missing")
            throw AutomationExecutionError(code: .invalidRequest, message: "Automation file output requires a path.")
        }
        return try destinationPolicy.validate(url)
    }

    private func writeFile(to url: URL, overwrite: Bool, operation: () async throws -> Void) async throws {
        let existedBefore = files.fileExists(atPath: url.path)
        ShortcutsAutomationLog.logger.info(
            "output.writeFile preflight url=\(url.path, privacy: .public) existedBefore=\(existedBefore, privacy: .public) overwrite=\(overwrite, privacy: .public)"
        )
        if existedBefore, !overwrite {
            ShortcutsAutomationLog.logger.error(
                "output.writeFile refusing existing file url=\(url.path, privacy: .public)"
            )
            throw AutomationExecutionError(code: .outputFailed, message: "Output file already exists. Pass overwrite to replace it.")
        }
        ShortcutsAutomationLog.logger.info(
            "output.writeFile creating directory url=\(url.deletingLastPathComponent().path, privacy: .public)"
        )
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await operation()
        ShortcutsAutomationLog.logger.info(
            "output.writeFile postflight url=\(url.path, privacy: .public) existsAfter=\(self.files.fileExists(atPath: url.path), privacy: .public)"
        )
    }

    private func revealIfNeeded(_ url: URL, reveal: Bool) {
        guard reveal else {
            return
        }
        workspace.activateFileViewerSelecting([url])
    }

    private func resolvedAppearance(
        _ requested: AutomationOutputAppearance,
        controller: EditorController
    ) -> ScreenshotOutputAppearance {
        switch requested {
        case .appDefault:
            controller.automationOutputAppearance
        case .plain:
            .plain
        case .styled:
            .styled
        }
    }
}

extension CompositionOutputFormat {
    init?(automationFormat: AutomationExportFormat) {
        switch automationFormat {
        case .png:
            self = .png
        case .jpeg:
            self = .jpeg
        case .pdf:
            self = .pdf
        case .gif:
            self = .gif
        case .apng:
            self = .apng
        case .mp4:
            self = .mp4
        case .html:
            self = .html
        case .sss:
            return nil
        }
    }
}
