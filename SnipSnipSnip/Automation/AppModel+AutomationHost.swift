import Foundation

extension AppModel: AutomationHost, AutomationOutputPort {
    var automationService: AppAutomationService {
        if let service = cachedAutomationService {
            return service
        }

        let service = AppAutomationService(host: self)
        cachedAutomationService = service
        return service
    }

    var automationCapabilities: AutomationCapabilities {
        AutomationCapabilities(
            supportsURLScheme: true,
            supportsAppleScript: true,
            supportsCLI: true,
            supportsCapturePresets: true,
            supportsPrivateCapture: true,
            supportsUIMap: capabilities.isEnabled(.uiMap),
            supportsScrollingCapture: capabilities.isEnabled(.scrollingCapture),
            supportsConnectedDeviceCapture: capabilities.isEnabled(.connectedDeviceCapture),
            supportsCurrentEditorExport: editorController != nil
        )
    }

    var automationPermissionSummary: AutomationPermissionSummary {
        refreshPermissions()
        return AutomationPermissionSummary(
            hasScreenRecording: permissionStatus.hasScreenRecording,
            hasAccessibility: permissionStatus.hasAccessibility,
            hasMicrophone: false
        )
    }

    var automationCapturePresets: [AutomationPresetSummary] {
        capturePresets.map { preset in
            AutomationPresetSummary(
                id: preset.id,
                name: preset.name,
                target: preset.target.automationKind,
                targetLabel: preset.targetLabel,
                createdAt: preset.createdAt,
                updatedAt: preset.updatedAt
            )
        }
    }

    var automationCurrentEditorController: EditorController? {
        editorController
    }

    var automationImageExportOptions: ImageExportOptions {
        screenshotImageExportOptions
    }

    func requestAutomationEditorPresentation() {
        requestMainWindowPresentation()
    }

    func markAutomationPasteboardChangeAsHandled() {
        clipboardMonitor.markCurrentPasteboardChangeAsHandled()
    }

    func saveAutomationDocument(_ controller: EditorController, to url: URL) async -> Bool {
        await saveDocument(controller, to: url)
    }

    func floatAutomationReference() {
        floatCurrentEditorReference()
    }
}

extension AppModel {
    func runAutomationPreset(
        _ command: RunPresetAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard !isWorking, !isRecordingVideo, !isConnectedDeviceSessionActive else {
            return .failure(requestID: request.id, code: .busy, message: "SnipSnipSnip is already working.")
        }

        guard let preset = AutomationPresetResolver(presets: capturePresets).resolve(command) else {
            return .failure(requestID: request.id, code: .targetUnavailable, message: "Capture preset was not found.")
        }

        do {
            switch preset.target {
            case .region(let region):
                try await automationCaptureRegion(region.rect, runOptions: preset.options, request: request)
            case .window(let savedWindow):
                let windows = try await captureService.listWindows(includeThumbnails: true)
                guard let resolvedWindow = gscStrictSavedWindowMatch(for: savedWindow, in: windows) else {
                    if request.interactionPolicy == .never {
                        throw AutomationExecutionError(code: .targetUnavailable, message: "The preset's saved window is not available.")
                    }
                    capturePreset(preset)
                    return acceptedInteractiveResult(requestID: request.id, kind: "preset", warning: "The preset needs a replacement window. SnipSnipSnip opened its normal replacement workflow.")
                }
                try await automationCaptureWindow(resolvedWindow, runOptions: preset.options, request: request)
            case .frontmostWindow:
                try await automationCaptureFrontmostWindow(runOptions: preset.options, request: request)
            case .fullscreen:
                try await automationCaptureFullscreen(runOptions: preset.options, request: request)
            }

            return await automationResultAfterCurrentEditorOutput(request: request, kind: preset.target.automationKind, sourceName: preset.name)
        } catch let error as AutomationExecutionError {
            return .failure(requestID: request.id, code: error.code, message: error.message)
        } catch {
            present(error)
            return .failure(requestID: request.id, code: .internalError, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func captureAutomation(
        _ command: CaptureAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard !isWorking, !isRecordingVideo, !isConnectedDeviceSessionActive else {
            return .failure(requestID: request.id, code: .busy, message: "SnipSnipSnip is already working.")
        }

        do {
            let runOptions = automationRunOptions(from: command.options, target: command.target)

            switch command.target {
            case .fullscreen:
                try await automationCaptureFullscreen(runOptions: runOptions, request: request)
                return await automationResultAfterCurrentEditorOutput(request: request, kind: "fullscreen", sourceName: editorController?.capture.sourceName)
            case .frontmostWindow:
                try await automationCaptureFrontmostWindow(runOptions: runOptions, request: request)
                return await automationResultAfterCurrentEditorOutput(request: request, kind: "frontmostWindow", sourceName: editorController?.capture.sourceName)
            case .region(let selector):
                try await automationCaptureRegion(selector.rect, runOptions: runOptions, request: request)
                return await automationResultAfterCurrentEditorOutput(request: request, kind: "region", sourceName: editorController?.capture.sourceName)
            case .interactiveRegion:
                beginRegionCapture()
                return acceptedInteractiveResult(requestID: request.id, kind: "interactiveRegion", warning: nil)
            case .interactiveWindow:
                presentWindowPicker()
                return acceptedInteractiveResult(requestID: request.id, kind: "interactiveWindow", warning: nil)
            }
        } catch let error as AutomationExecutionError {
            return .failure(requestID: request.id, code: error.code, message: error.message)
        } catch {
            present(error)
            return .failure(requestID: request.id, code: .internalError, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func repeatLastAutomationCapture(_ request: AutomationRequest) async -> AutomationResultEnvelope {
        guard canRepeatLastCapture else {
            return .failure(requestID: request.id, code: .targetUnavailable, message: "There is no repeatable last capture.")
        }

        repeatLastCapture()
        return acceptedInteractiveResult(requestID: request.id, kind: "repeatLastCapture", warning: "Repeat last capture uses the normal app workflow and may finish after this automation result is returned.")
    }

    func openAutomationDocument(
        _ command: OpenDocumentAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard FileManager.default.fileExists(atPath: command.url.path) else {
            return .failure(requestID: request.id, code: .targetUnavailable, message: "Document does not exist.")
        }

        openDocument(at: command.url)
        return await automationResultAfterCurrentEditorOutput(request: request, kind: "openDocument", sourceName: command.url.lastPathComponent)
    }

    func exportCurrentAutomationDocument(
        _ command: ExportCurrentAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        var exportRequest = request
        if case .appDefault = exportRequest.output {
            exportRequest.output = .saveFile(AutomationFileOutput(url: nil, format: command.format))
        }
        return await automationResultAfterCurrentEditorOutput(request: exportRequest, kind: "exportCurrent", sourceName: editorController?.capture.sourceName)
    }

    private func automationCaptureFullscreen(
        runOptions: CaptureRunOptions,
        request: AutomationRequest
    ) async throws {
        try await automationWithPrivateCapture(request.privacy.privateCapture) {
            await performCapture(request: .fullscreen, minimizeAppWindow: true, runOptions: runOptions) {
                try await captureService.captureFullscreen(
                    mode: runOptions.fullscreenDisplayMode,
                    selectedDisplayID: runOptions.selectedFullscreenDisplayID
                )
            }
        }
    }

    private func automationCaptureFrontmostWindow(
        runOptions: CaptureRunOptions,
        request: AutomationRequest
    ) async throws {
        try await automationWithPrivateCapture(request.privacy.privateCapture) {
            await performCapture(request: .frontmostWindow, minimizeAppWindow: true, runOptions: runOptions) {
                let window = try await captureService.frontmostWindow()
                return try await captureService.captureWindow(window)
            }
        }
    }

    private func automationCaptureWindow(
        _ window: CaptureWindowSummary,
        runOptions: CaptureRunOptions,
        request: AutomationRequest
    ) async throws {
        try await automationWithPrivateCapture(request.privacy.privateCapture) {
            await performCapture(request: .window(window), minimizeAppWindow: true, runOptions: runOptions) {
                try await captureService.captureWindow(window)
            }
        }
    }

    private func automationCaptureRegion(
        _ rect: CGRect,
        runOptions: CaptureRunOptions,
        request: AutomationRequest
    ) async throws {
        try await automationWithPrivateCapture(request.privacy.privateCapture) {
            await performCapture(request: .region(rect), minimizeAppWindow: true, runOptions: runOptions) {
                try await captureService.captureRegion(in: rect)
            }
        }
    }

    private func automationWithPrivateCapture(_ privateCapture: Bool, _ operation: () async throws -> Void) async throws {
        let previous = privateCaptureEnabled
        if privateCapture {
            privateCaptureEnabled = true
        }
        defer {
            privateCaptureEnabled = previous
        }
        try await operation()
    }

    private func automationResultAfterCurrentEditorOutput(
        request: AutomationRequest,
        kind: String,
        sourceName: String?
    ) async -> AutomationResultEnvelope {
        do {
            let outputs = try await AutomationOutputService(port: self).write(request.output)
            return .success(
                requestID: request.id,
                payload: .capture(AutomationCaptureSummary(kind: kind, sourceName: sourceName, acceptedInteractiveWorkflow: false)),
                outputs: outputs.isEmpty ? [.init(kind: .none)] : outputs
            )
        } catch let error as AutomationExecutionError {
            return .failure(requestID: request.id, code: error.code, message: error.message)
        } catch {
            present(error)
            return .failure(requestID: request.id, code: .outputFailed, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func acceptedInteractiveResult(requestID: UUID, kind: String, warning: String?) -> AutomationResultEnvelope {
        var warnings: [AutomationWarning] = []
        if let warning {
            warnings.append(AutomationWarning(code: "interactiveWorkflow", message: warning))
        }

        return .success(
            requestID: requestID,
            payload: .capture(AutomationCaptureSummary(kind: kind, sourceName: nil, acceptedInteractiveWorkflow: true)),
            outputs: [.init(kind: .acceptedInteractiveWorkflow)],
            warnings: warnings
        )
    }

    private func automationRunOptions(
        from options: CaptureAutomationOptions,
        target: CaptureAutomationTarget
    ) -> CaptureRunOptions {
        var runOptions = currentCaptureRunOptions()

        switch options.delay {
        case .appDefault:
            break
        case .immediate:
            runOptions.captureDelay = .immediate
        case .seconds(let seconds):
            runOptions.captureDelay = CaptureDelay(rawValue: seconds) ?? runOptions.captureDelay
        }

        if let includesCursor = options.includesCursor {
            runOptions.includesCursor = includesCursor
        }

        switch options.windowUIMap {
        case .appDefault:
            break
        case .enabled:
            runOptions.windowUIMapEnabled = true
        case .disabled:
            runOptions.windowUIMapEnabled = false
        }

        if case .fullscreen(let fullscreen) = target {
            switch fullscreen.displayMode {
            case .appDefault:
                break
            case .current:
                runOptions.fullscreenDisplayMode = .currentDisplay
            case .selected:
                runOptions.fullscreenDisplayMode = .selectedDisplay
            case .all:
                runOptions.fullscreenDisplayMode = .allDisplays
            }
        }

        return runOptions
    }
}

private extension CapturePresetTarget {
    var automationKind: String {
        switch self {
        case .region:
            return "region"
        case .window:
            return "window"
        case .frontmostWindow:
            return "frontmostWindow"
        case .fullscreen:
            return "fullscreen"
        }
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
