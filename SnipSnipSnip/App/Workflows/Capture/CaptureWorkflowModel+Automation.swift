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
            supportsCurrentEditorExport: documents?.activeCaptureEditorController != nil,
            supportsGuide: dependencies.capabilities.isEnabled(.guideCapture),
            supportsComposition: dependencies.capabilities.isEnabled(.composition)
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
        if preset.options.windowUIMapEnabled,
           !dependencies.capabilities.isEnabled(.uiMap) {
            return .failure(
                requestID: request.id,
                code: .proFeatureRequired,
                message: "UI Map capture is available in SnipSnipSnip Pro."
            )
        }
        do {
            let destination = try automationCaptureDestinationContext(for: request)
            prepareCaptureIntent(destination.intent)
            var leavesCaptureIntentPending = false
            defer {
                if !leavesCaptureIntentPending {
                    resetAutomationCaptureIntent(ifMatching: destination.intent)
                }
            }

            switch preset.target {
            case .region(let region):
                try await automationCaptureRegion(region.rect, runOptions: preset.options, request: request)
            case .window(let savedWindow):
                let windows = try await captureService.listWindows(includeThumbnails: true)
                guard let resolvedWindow = gscStrictSavedWindowMatch(for: savedWindow, in: windows) else {
                    if request.interactionPolicy == .never {
                        throw AutomationExecutionError(code: .targetUnavailable, message: "The preset's saved window is not available.")
                    }
                    leavesCaptureIntentPending = true
                    automationCoordinator.capturePreset(preset)
                    return acceptedInteractiveResult(requestID: request.id, kind: "preset", warning: "The preset needs a replacement window. SnipSnipSnip opened its normal replacement workflow.")
                }
                try await automationCaptureWindow(resolvedWindow, runOptions: preset.options, request: request)
            case .frontmostWindow:
                try await automationCaptureFrontmostWindow(runOptions: preset.options, request: request)
            case .fullscreen:
                try await automationCaptureFullscreen(runOptions: preset.options, request: request)
            }

            let affectedItemID = try destination.verifyCompletion(
                in: documents?.activeCaptureEditorController
            )
            let result = await automationCoordinator.automationResultAfterCurrentEditorOutput(request, preset.target.automationKind, preset.name)
            return result.identifyingAffectedCompositionItem(affectedItemID)
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
        if command.options.windowUIMap == .enabled,
           !dependencies.capabilities.isEnabled(.uiMap) {
            return .failure(
                requestID: request.id,
                code: .proFeatureRequired,
                message: "UI Map capture is available in SnipSnipSnip Pro."
            )
        }

        do {
            let destination = try automationCaptureDestinationContext(for: request)
            prepareCaptureIntent(destination.intent)
            var leavesCaptureIntentPending = false
            defer {
                if !leavesCaptureIntentPending {
                    resetAutomationCaptureIntent(ifMatching: destination.intent)
                }
            }

            let runOptions = automationRunOptions(from: command.options, target: command.target)
            ShortcutsAutomationLog.logger.info(
                "capture.automation runOptions requestID=\(request.id.uuidString, privacy: .public) delay=\(runOptions.captureDelay.rawValue, privacy: .public) fullscreenMode=\(String(describing: runOptions.fullscreenDisplayMode), privacy: .public) cursor=\(runOptions.includesCursor, privacy: .public) uiMap=\(runOptions.windowUIMapEnabled, privacy: .public)"
            )

            switch command.target {
            case .fullscreen:
                try await automationCaptureFullscreen(runOptions: runOptions, request: request)
                let affectedItemID = try destination.verifyCompletion(
                    in: documents?.activeCaptureEditorController
                )
                let result = await automationCoordinator.automationResultAfterCurrentEditorOutput(request, "fullscreen", documents?.activeCaptureEditorController?.capture.sourceName)
                ShortcutsAutomationLog.logger.info(
                    "capture.automation fullscreen result requestID=\(request.id.uuidString, privacy: .public) \(result.debugSummary, privacy: .public)"
                )
                return result.identifyingAffectedCompositionItem(affectedItemID)
            case .frontmostWindow:
                try await automationCaptureFrontmostWindow(runOptions: runOptions, request: request)
                let affectedItemID = try destination.verifyCompletion(
                    in: documents?.activeCaptureEditorController
                )
                let result = await automationCoordinator.automationResultAfterCurrentEditorOutput(request, "frontmostWindow", documents?.activeCaptureEditorController?.capture.sourceName)
                ShortcutsAutomationLog.logger.info(
                    "capture.automation frontmostWindow result requestID=\(request.id.uuidString, privacy: .public) \(result.debugSummary, privacy: .public)"
                )
                return result.identifyingAffectedCompositionItem(affectedItemID)
            case .region(let selector):
                try await automationCaptureRegion(selector.rect, runOptions: runOptions, request: request)
                let affectedItemID = try destination.verifyCompletion(
                    in: documents?.activeCaptureEditorController
                )
                let result = await automationCoordinator.automationResultAfterCurrentEditorOutput(request, "region", documents?.activeCaptureEditorController?.capture.sourceName)
                ShortcutsAutomationLog.logger.info(
                    "capture.automation region result requestID=\(request.id.uuidString, privacy: .public) \(result.debugSummary, privacy: .public)"
                )
                return result.identifyingAffectedCompositionItem(affectedItemID)
            case .interactiveRegion:
                ShortcutsAutomationLog.logger.info(
                    "capture.automation accepted interactiveRegion requestID=\(request.id.uuidString, privacy: .public)"
                )
                leavesCaptureIntentPending = true
                beginRegionCapture()
                return acceptedInteractiveResult(requestID: request.id, kind: "interactiveRegion", warning: nil)
            case .interactiveWindow:
                ShortcutsAutomationLog.logger.info(
                    "capture.automation accepted interactiveWindow requestID=\(request.id.uuidString, privacy: .public)"
                )
                leavesCaptureIntentPending = true
                presentWindowPicker(intent: destination.intent)
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
        guard !isWorking, video?.isRecording != true, guide?.isActive != true, !isConnectedDeviceSessionActive else {
            return .failure(requestID: request.id, code: .busy, message: "SnipSnipSnip is already working.")
        }
        guard automationCoordinator.canRepeatLastCapture() else {
            return .failure(requestID: request.id, code: .targetUnavailable, message: "There is no repeatable last capture.")
        }
        guard let lastCaptureRequest else {
            return .failure(requestID: request.id, code: .targetUnavailable, message: "There is no repeatable last capture.")
        }

        do {
            let destination = try automationCaptureDestinationContext(for: request)
            prepareCaptureIntent(destination.intent)
            var leavesCaptureIntentPending = false
            defer {
                if !leavesCaptureIntentPending {
                    resetAutomationCaptureIntent(ifMatching: destination.intent)
                }
            }

            let runOptions = lastCaptureRunOptions ?? currentCaptureRunOptions()
            let resultKind: String
            switch lastCaptureRequest {
            case .region(let region):
                try await automationCaptureRegion(
                    region,
                    runOptions: runOptions,
                    request: request
                )
                resultKind = "region"
            case .window(let window):
                let resolvedWindow: CaptureWindowSummary
                do {
                    resolvedWindow = try await captureService.resolveWindowTarget(
                        window
                    )
                } catch {
                    throw AutomationExecutionError(
                        code: .targetUnavailable,
                        message: "The last captured window is no longer available."
                    )
                }
                try await automationCaptureWindow(
                    resolvedWindow,
                    runOptions: runOptions,
                    request: request
                )
                resultKind = "window"
            case .frontmostWindow:
                try await automationCaptureFrontmostWindow(
                    runOptions: runOptions,
                    request: request
                )
                resultKind = "frontmostWindow"
            case .fullscreen:
                try await automationCaptureFullscreen(
                    runOptions: runOptions,
                    request: request
                )
                resultKind = "fullscreen"
            case .scrolling, .connectedDevice:
                // These repeat workflows intentionally retain a confirmation or
                // live-preview interaction. Their result is therefore the same
                // explicit accepted-interactive contract as region/window
                // pickers; unattended repeat targets above await completion.
                leavesCaptureIntentPending = true
                repeatLastCapture(intent: destination.intent)
                return acceptedInteractiveResult(
                    requestID: request.id,
                    kind: "repeatLastCapture",
                    warning: "This repeat capture requires interaction and will finish after the accepted result is returned."
                )
            }

            let affectedItemID = try destination.verifyCompletion(
                in: documents?.activeCaptureEditorController
            )
            let result = await automationCoordinator
                .automationResultAfterCurrentEditorOutput(
                    request,
                    resultKind,
                    documents?.activeCaptureEditorController?.capture.sourceName
                )
            return result.identifyingAffectedCompositionItem(affectedItemID)
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

    private func automationCaptureFullscreen(
        runOptions: CaptureRunOptions,
        request: AutomationRequest
    ) async throws {
        let captureContext = activeCaptureContext
        try await automationWithPrivateCapture(request.privacy.privateCapture) {
            ShortcutsAutomationLog.logger.info(
                "capture.fullscreen start requestID=\(request.id.uuidString, privacy: .public)"
            )
            let didComplete = await performCapture(
                request: .fullscreen,
                minimizeAppWindow: true,
                runOptions: runOptions,
                completionContext: captureContext
            ) { [captureService] in
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
        let captureContext = activeCaptureContext
        try await automationWithPrivateCapture(request.privacy.privateCapture) {
            ShortcutsAutomationLog.logger.info(
                "capture.frontmostWindow start requestID=\(request.id.uuidString, privacy: .public)"
            )
            let didComplete = await performCapture(
                request: .frontmostWindow,
                minimizeAppWindow: true,
                runOptions: runOptions,
                completionContext: captureContext
            ) { [captureService] in
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
        let captureContext = activeCaptureContext
        try await automationWithPrivateCapture(request.privacy.privateCapture) {
            ShortcutsAutomationLog.logger.info(
                "capture.window start requestID=\(request.id.uuidString, privacy: .public)"
            )
            let didComplete = await performCapture(
                request: .window(window),
                minimizeAppWindow: true,
                runOptions: runOptions,
                completionContext: captureContext
            ) { [captureService] in
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
        let captureContext = activeCaptureContext
        try await automationWithPrivateCapture(request.privacy.privateCapture) {
            ShortcutsAutomationLog.logger.info(
                "capture.region start requestID=\(request.id.uuidString, privacy: .public) rect=\(rect.debugDescription, privacy: .public)"
            )
            let didComplete = await performCapture(
                request: .region(rect),
                minimizeAppWindow: true,
                runOptions: runOptions,
                completionContext: captureContext
            ) { [captureService] in
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

    private func automationCaptureDestinationContext(
        for request: AutomationRequest
    ) throws -> AutomationCaptureDestinationContext {
        try AutomationCaptureDestinationContext(
            request: request,
            controller: documents?.activeCaptureEditorController
        )
    }

    private func resetAutomationCaptureIntent(ifMatching intent: CaptureIntent) {
        guard activeCaptureIntent == intent else {
            return
        }
        activeCaptureIntent = .newDocument
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

@MainActor
struct AutomationCaptureDestinationContext {
    private enum ExpectedMutation {
        case none
        case append(
            documentID: UUID,
            afterItemID: UUID?,
            previousItemIDs: Set<UUID>,
            previousItemCount: Int
        )
        case replace(documentID: UUID, itemID: UUID, previousAssetID: UUID)
    }

    let intent: CaptureIntent
    private let expectedMutation: ExpectedMutation

    init(
        request: AutomationRequest,
        controller: EditorController?
    ) throws {
        switch request.captureDestination {
        case .new:
            intent = .newDocument
            expectedMutation = .none
        case .append:
            guard let controller else {
                throw AutomationExecutionError(
                    code: .noActiveComposition,
                    message: "Open a screenshot or composition before appending a capture."
                )
            }
            let afterItemID: UUID?
            if let requestedItemID = request.appendAfterCompositionItemID {
                guard controller.composition?.items.contains(where: { $0.id == requestedItemID }) == true else {
                    throw AutomationExecutionError(
                        code: .compositionItemNotFound,
                        message: "Composition item \(requestedItemID.uuidString) was not found."
                    )
                }
                afterItemID = requestedItemID
            } else {
                afterItemID = controller.composition?.selectedItemIDs.last
            }
            intent = .append(
                documentGenerationID: controller.documentGenerationID,
                afterItemID: afterItemID
            )
            expectedMutation = .append(
                documentID: controller.documentGenerationID,
                afterItemID: afterItemID,
                previousItemIDs: Set(
                    controller.composition?.items.map(\.id) ?? []
                ),
                previousItemCount: controller.compositionItemCount
            )
        case .replace:
            guard let controller,
                  controller.hasComposition,
                  let composition = controller.composition else {
                throw AutomationExecutionError(
                    code: .noActiveComposition,
                    message: "Open a composition before replacing one of its captures."
                )
            }
            guard let itemID = request.replaceCompositionItemID else {
                throw AutomationExecutionError(
                    code: .invalidRequest,
                    message: "Replace capture destination requires a composition item id."
                )
            }
            guard let item = composition.items.first(where: { $0.id == itemID }) else {
                throw AutomationExecutionError(
                    code: .compositionItemNotFound,
                    message: "Composition item \(itemID.uuidString) was not found."
                )
            }
            intent = .replace(
                documentGenerationID: controller.documentGenerationID,
                itemID: itemID
            )
            expectedMutation = .replace(
                documentID: controller.documentGenerationID,
                itemID: itemID,
                previousAssetID: item.assetID
            )
        }
    }

    func verifyCompletion(in controller: EditorController?) throws -> UUID? {
        switch expectedMutation {
        case .none:
            return nil
        case .append(
            let documentID,
            let afterItemID,
            let previousItemIDs,
            let previousItemCount
        ):
            guard let controller,
                  controller.documentGenerationID == documentID else {
                throw AutomationExecutionError(
                    code: .staleDestination,
                    message: "The target composition changed before the capture finished."
                )
            }
            if let afterItemID,
               controller.composition?.items.contains(where: { $0.id == afterItemID }) != true {
                throw AutomationExecutionError(
                    code: .staleDestination,
                    message: "The append-after composition item was removed before the capture finished."
                )
            }
            let currentItemIDs = controller.composition?.items.map(\.id) ?? []
            guard currentItemIDs.count == previousItemCount + 1 else {
                throw AutomationExecutionError(
                    code: .outputFailed,
                    message: "The capture completed but could not be appended to the composition."
                )
            }
            if !previousItemIDs.isEmpty {
                let insertedIDs = currentItemIDs.filter {
                    !previousItemIDs.contains($0)
                }
                guard insertedIDs.count == 1,
                      let insertedItemID = insertedIDs.first else {
                    throw AutomationExecutionError(
                        code: .outputFailed,
                        message: "The appended composition item could not be identified."
                    )
                }
                return insertedItemID
            }
            guard let insertedItemID = controller.composition?
                .selectedItemIDs.last,
                  currentItemIDs.contains(insertedItemID) else {
                throw AutomationExecutionError(
                    code: .outputFailed,
                    message: "The appended composition item could not be identified."
                )
            }
            return insertedItemID
        case .replace(let documentID, let itemID, let previousAssetID):
            guard let controller,
                  controller.documentGenerationID == documentID else {
                throw AutomationExecutionError(
                    code: .staleDestination,
                    message: "The target composition changed before the capture finished."
                )
            }
            guard let item = controller.composition?.items.first(where: { $0.id == itemID }) else {
                throw AutomationExecutionError(
                    code: .staleDestination,
                    message: "Composition item \(itemID.uuidString) was removed before the capture finished."
                )
            }
            guard item.assetID != previousAssetID else {
                throw AutomationExecutionError(
                    code: .outputFailed,
                    message: "The capture completed but could not replace the composition item."
                )
            }
            return itemID
        }
    }
}

private extension AutomationResultEnvelope {
    func identifyingAffectedCompositionItem(
        _ itemID: UUID?
    ) -> AutomationResultEnvelope {
        guard let itemID,
              case .composition(var summary) = payload else {
            return self
        }
        summary.itemID = itemID
        var result = self
        result.payload = .composition(summary)
        return result
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
