import AppKit
import Foundation
import OSLog

@MainActor
extension CaptureWorkflowModel {
    var automationCapabilities: AutomationCapabilities {
        AutomationCapabilities(
            supportsURLScheme: true,
            supportsAppleScript: true,
            supportsCLI: true,
            supportsAppIntents: true,
            supportsCapturePresets: true,
            supportsPrivateCapture: true,
            supportsUIMap: dependencies.capabilities.isEnabled(.uiMap),
            supportsScrollingCapture: dependencies.capabilities.isEnabled(.scrollingCapture),
            supportsConnectedDeviceCapture: dependencies.capabilities.isEnabled(.connectedDeviceCapture),
            supportsCurrentEditorExport: documents?.activeCaptureEditorController != nil
        )
    }

    var automationPermissionSummary: AutomationPermissionSummary {
        dependencies.permissions.refreshPermissions()
        let status = dependencies.permissions.permissionStatus
        return AutomationPermissionSummary(
            hasScreenRecording: status.hasScreenRecording,
            hasAccessibility: status.hasAccessibility,
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

    func runAutomationPreset(
        _ command: RunPresetAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard let automationCoordinator else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }
        guard !isWorking, video?.isRecording != true, guide?.isActive != true, !isConnectedDeviceSessionActive else {
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
                    automationCoordinator.capturePreset(preset)
                    return acceptedInteractiveResult(requestID: request.id, kind: "preset", warning: "The preset needs a replacement window. SnipSnipSnip opened its normal replacement workflow.")
                }
                try await automationCaptureWindow(resolvedWindow, runOptions: preset.options, request: request)
            case .frontmostWindow:
                try await automationCaptureFrontmostWindow(runOptions: preset.options, request: request)
            case .fullscreen:
                try await automationCaptureFullscreen(runOptions: preset.options, request: request)
            }

            return await automationCoordinator.automationResultAfterCurrentEditorOutput(request, preset.target.automationKind, preset.name)
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
        ShortcutsAutomationLog.logger.info(
            "capture.automation start requestID=\(request.id.uuidString, privacy: .public) \(request.debugSummary, privacy: .public)"
        )
        guard let automationCoordinator else {
            ShortcutsAutomationLog.logger.error(
                "capture.automation failed coordinator unavailable requestID=\(request.id.uuidString, privacy: .public)"
            )
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }
        guard !isWorking, video?.isRecording != true, guide?.isActive != true, !isConnectedDeviceSessionActive else {
            ShortcutsAutomationLog.logger.error(
                "capture.automation busy requestID=\(request.id.uuidString, privacy: .public) isWorking=\(self.isWorking, privacy: .public) videoRecording=\(self.video?.isRecording == true, privacy: .public) connectedDevice=\(self.isConnectedDeviceSessionActive, privacy: .public)"
            )
            return .failure(requestID: request.id, code: .busy, message: "SnipSnipSnip is already working.")
        }

        do {
            let runOptions = automationRunOptions(from: command.options, target: command.target)
            ShortcutsAutomationLog.logger.info(
                "capture.automation runOptions requestID=\(request.id.uuidString, privacy: .public) delay=\(runOptions.captureDelay.rawValue, privacy: .public) fullscreenMode=\(String(describing: runOptions.fullscreenDisplayMode), privacy: .public) cursor=\(runOptions.includesCursor, privacy: .public) uiMap=\(runOptions.windowUIMapEnabled, privacy: .public)"
            )

            switch command.target {
            case .fullscreen:
                try await automationCaptureFullscreen(runOptions: runOptions, request: request)
                let result = await automationCoordinator.automationResultAfterCurrentEditorOutput(request, "fullscreen", documents?.activeCaptureEditorController?.capture.sourceName)
                ShortcutsAutomationLog.logger.info(
                    "capture.automation fullscreen result requestID=\(request.id.uuidString, privacy: .public) \(result.debugSummary, privacy: .public)"
                )
                return result
            case .frontmostWindow:
                try await automationCaptureFrontmostWindow(runOptions: runOptions, request: request)
                let result = await automationCoordinator.automationResultAfterCurrentEditorOutput(request, "frontmostWindow", documents?.activeCaptureEditorController?.capture.sourceName)
                ShortcutsAutomationLog.logger.info(
                    "capture.automation frontmostWindow result requestID=\(request.id.uuidString, privacy: .public) \(result.debugSummary, privacy: .public)"
                )
                return result
            case .region(let selector):
                try await automationCaptureRegion(selector.rect, runOptions: runOptions, request: request)
                let result = await automationCoordinator.automationResultAfterCurrentEditorOutput(request, "region", documents?.activeCaptureEditorController?.capture.sourceName)
                ShortcutsAutomationLog.logger.info(
                    "capture.automation region result requestID=\(request.id.uuidString, privacy: .public) \(result.debugSummary, privacy: .public)"
                )
                return result
            case .interactiveRegion:
                ShortcutsAutomationLog.logger.info(
                    "capture.automation accepted interactiveRegion requestID=\(request.id.uuidString, privacy: .public)"
                )
                automationCoordinator.beginRegionCapture()
                return acceptedInteractiveResult(requestID: request.id, kind: "interactiveRegion", warning: nil)
            case .interactiveWindow:
                ShortcutsAutomationLog.logger.info(
                    "capture.automation accepted interactiveWindow requestID=\(request.id.uuidString, privacy: .public)"
                )
                automationCoordinator.presentWindowPicker()
                return acceptedInteractiveResult(requestID: request.id, kind: "interactiveWindow", warning: nil)
            }
        } catch let error as AutomationExecutionError {
            ShortcutsAutomationLog.logger.error(
                "capture.automation executionError requestID=\(request.id.uuidString, privacy: .public) code=\(error.code.rawValue, privacy: .public) message=\(error.message, privacy: .public)"
            )
            return .failure(requestID: request.id, code: error.code, message: error.message)
        } catch {
            ShortcutsAutomationLog.logger.error(
                "capture.automation unexpectedError requestID=\(request.id.uuidString, privacy: .public) message=\(error.localizedDescription, privacy: .public)"
            )
            present(error)
            return .failure(requestID: request.id, code: .internalError, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func repeatLastAutomationCapture(_ request: AutomationRequest) async -> AutomationResultEnvelope {
        guard let automationCoordinator else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }
        guard automationCoordinator.canRepeatLastCapture() else {
            return .failure(requestID: request.id, code: .targetUnavailable, message: "There is no repeatable last capture.")
        }

        automationCoordinator.repeatLastCapture()
        return acceptedInteractiveResult(requestID: request.id, kind: "repeatLastCapture", warning: "Repeat last capture uses the normal app workflow and may finish after this automation result is returned.")
    }

    private func automationCaptureFullscreen(
        runOptions: CaptureRunOptions,
        request: AutomationRequest
    ) async throws {
        try await automationWithPrivateCapture(request.privacy.privateCapture) {
            ShortcutsAutomationLog.logger.info(
                "capture.fullscreen start requestID=\(request.id.uuidString, privacy: .public)"
            )
            let didComplete = await performCapture(request: .fullscreen, minimizeAppWindow: true, runOptions: runOptions) { [captureService] in
                try await captureService.captureFullscreen(
                    mode: runOptions.fullscreenDisplayMode,
                    selectedDisplayID: runOptions.selectedFullscreenDisplayID
                )
            }
            ShortcutsAutomationLog.logger.info(
                "capture.fullscreen completed requestID=\(request.id.uuidString, privacy: .public) didComplete=\(didComplete, privacy: .public) hasEditor=\(self.documents?.activeCaptureEditorController != nil, privacy: .public)"
            )
            try ensureAutomationCaptureCompleted(didComplete)
        }
    }

    private func automationCaptureFrontmostWindow(
        runOptions: CaptureRunOptions,
        request: AutomationRequest
    ) async throws {
        try await automationWithPrivateCapture(request.privacy.privateCapture) {
            ShortcutsAutomationLog.logger.info(
                "capture.frontmostWindow start requestID=\(request.id.uuidString, privacy: .public)"
            )
            let didComplete = await performCapture(request: .frontmostWindow, minimizeAppWindow: true, runOptions: runOptions) { [captureService] in
                let window = try await captureService.frontmostWindow()
                return try await captureService.captureWindow(window)
            }
            ShortcutsAutomationLog.logger.info(
                "capture.frontmostWindow completed requestID=\(request.id.uuidString, privacy: .public) didComplete=\(didComplete, privacy: .public) hasEditor=\(self.documents?.activeCaptureEditorController != nil, privacy: .public)"
            )
            try ensureAutomationCaptureCompleted(didComplete)
        }
    }

    private func automationCaptureWindow(
        _ window: CaptureWindowSummary,
        runOptions: CaptureRunOptions,
        request: AutomationRequest
    ) async throws {
        try await automationWithPrivateCapture(request.privacy.privateCapture) {
            ShortcutsAutomationLog.logger.info(
                "capture.window start requestID=\(request.id.uuidString, privacy: .public)"
            )
            let didComplete = await performCapture(request: .window(window), minimizeAppWindow: true, runOptions: runOptions) { [captureService] in
                try await captureService.captureWindow(window)
            }
            ShortcutsAutomationLog.logger.info(
                "capture.window completed requestID=\(request.id.uuidString, privacy: .public) didComplete=\(didComplete, privacy: .public) hasEditor=\(self.documents?.activeCaptureEditorController != nil, privacy: .public)"
            )
            try ensureAutomationCaptureCompleted(didComplete)
        }
    }

    private func automationCaptureRegion(
        _ rect: CGRect,
        runOptions: CaptureRunOptions,
        request: AutomationRequest
    ) async throws {
        try await automationWithPrivateCapture(request.privacy.privateCapture) {
            ShortcutsAutomationLog.logger.info(
                "capture.region start requestID=\(request.id.uuidString, privacy: .public) rect=\(rect.debugDescription, privacy: .public)"
            )
            let didComplete = await performCapture(request: .region(rect), minimizeAppWindow: true, runOptions: runOptions) { [captureService] in
                try await captureService.captureRegion(in: rect)
            }
            ShortcutsAutomationLog.logger.info(
                "capture.region completed requestID=\(request.id.uuidString, privacy: .public) didComplete=\(didComplete, privacy: .public) hasEditor=\(self.documents?.activeCaptureEditorController != nil, privacy: .public)"
            )
            try ensureAutomationCaptureCompleted(didComplete)
        }
    }

    private func ensureAutomationCaptureCompleted(_ didComplete: Bool) throws {
        guard didComplete else {
            ShortcutsAutomationLog.logger.error("capture.ensureCompleted failed didComplete=false")
            throw AutomationExecutionError(code: .outputFailed, message: "Capture did not complete.")
        }
    }

    private func automationWithPrivateCapture(_ privateCapture: Bool, _ operation: () async throws -> Void) async throws {
        guard automationCoordinator != nil else {
            throw AutomationExecutionError(code: .internalError, message: "Automation workflow is not available.")
        }
        let previous = privateCaptureEnabled
        if privateCapture {
            privateCaptureEnabled = true
        }
        defer {
            privateCaptureEnabled = previous
        }
        try await operation()
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
