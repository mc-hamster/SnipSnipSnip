import AppKit
import Foundation
import OSLog

private enum CaptureWorkflowUIMapDiagnostics {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SnipSnipSnip",
        category: "UIMapCapture"
    )

    nonisolated static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}

@MainActor
extension CaptureWorkflowModel {
    var windowUIMapEnabled: Bool {
        dependencies.capabilities.isEnabled(.uiMap) && uiMapEnabled
    }

    func currentCaptureRunOptions() -> CaptureRunOptions {
        CaptureRunOptions(
            captureDelay: captureDelay,
            includesCursor: screenshotIncludesCursor,
            fullscreenDisplayMode: screenshotFullscreenDisplayMode,
            selectedFullscreenDisplayID: selectedScreenshotFullscreenDisplayID,
            regionPreferences: regionCapturePreferences,
            windowUIMapEnabled: windowUIMapEnabled
        )
    }

    func uiMapCaptureEligibility(for capture: CapturedScreenshot) -> UIMapCaptureEligibility {
        uiMapCaptureEligibility(for: capture, userEnabled: uiMapEnabled)
    }

    func uiMapCaptureEligibility(for capture: CapturedScreenshot, userEnabled: Bool) -> UIMapCaptureEligibility {
        UIMapCaptureEligibility(
            featureFlagEnabled: dependencies.capabilities.isEnabled(.uiMap),
            userEnabled: userEnabled,
            captureKind: capture.kind,
            hasSourceWindowIdentity: capture.sourceWindowIdentity != nil,
            hasAccessibility: dependencies.permissions.permissionStatus.hasAccessibility
        )
    }

    func completeCapture(
        _ capture: CapturedScreenshot,
        request: LastCaptureRequest,
        isPrivateCapture: Bool,
        cursorCaptureGlobalLocation: CGPoint? = nil,
        shouldAttemptUIMapCapture: Bool = true,
        runOptions: CaptureRunOptions? = nil
    ) throws {
        guard let outputSink else {
            throw CaptureWorkflowCompletionError.missingCoordinator
        }

        let resolvedRunOptions = runOptions ?? currentCaptureRunOptions()
        CaptureWorkflowUIMapDiagnostics.notice(
            "[UIMap] CaptureWorkflow capture decision featureFlag=\(dependencies.capabilities.isEnabled(.uiMap)) userEnabled=\(resolvedRunOptions.windowUIMapEnabled) kind='\(capture.kind.rawValue)' hasWindowIdentity=\(capture.sourceWindowIdentity != nil) shouldCapture=\(uiMapCaptureEligibility(for: capture, userEnabled: resolvedRunOptions.windowUIMapEnabled).shouldCapture) hasAccessibility=\(dependencies.permissions.permissionStatus.hasAccessibility) existingUIMap=\(capture.uiMap != nil) sourceName='\(capture.sourceName)'"
        )
        let uiMapEligibility = uiMapCaptureEligibility(for: capture, userEnabled: resolvedRunOptions.windowUIMapEnabled)
        let shouldProcessUIMap = shouldAttemptUIMapCapture
            && capture.uiMap == nil
            && uiMapEligibility.shouldCapture
        let cursorAwareCapture = capture.attachingCursorOverlay(currentCursorOverlay(
            for: capture,
            cursorCaptureGlobalLocation: cursorCaptureGlobalLocation,
            includesCursor: resolvedRunOptions.includesCursor
        ))
        outputSink.handle(.captureCompleted(CaptureWorkflowResult(
            capture: cursorAwareCapture,
            uiMapSourceCapture: capture,
            request: request,
            runOptions: resolvedRunOptions,
            isPrivateCapture: isPrivateCapture,
            checkpointLabel: "Capture",
            shouldAttemptUIMapCapture: shouldAttemptUIMapCapture,
            shouldProcessUIMap: shouldProcessUIMap,
            uiMapSkipReason: uiMapEligibility.skipReason
        )))
    }

    func completeScreenInspectorSnip(_ sample: ScreenInspectorSample) {
        guard let outputSink else {
            dependencies.lifecycle.presentError("Document workflow is not available.")
            dependencies.lifecycle.requestMainWindowPresentation()
            return
        }

        let isPrivateCapture = privateCaptureEnabled
        let capture = CapturedScreenshot(
            image: sample.image,
            kind: .region,
            sourceName: "Screen Inspector",
            sourceRect: sample.sourceRect,
            capturedAt: dependencies.systemServices.clock.now()
        )

        let runOptions = CaptureRunOptions(
            captureDelay: .immediate,
            includesCursor: false,
            fullscreenDisplayMode: screenshotFullscreenDisplayMode,
            selectedFullscreenDisplayID: selectedScreenshotFullscreenDisplayID,
            regionPreferences: regionCapturePreferences,
            windowUIMapEnabled: windowUIMapEnabled
        )
        outputSink.handle(.captureCompleted(CaptureWorkflowResult(
            capture: capture,
            uiMapSourceCapture: capture,
            request: .region(sample.sourceRect),
            runOptions: runOptions,
            isPrivateCapture: isPrivateCapture,
            checkpointLabel: "Screen Inspector",
            shouldAttemptUIMapCapture: false,
            shouldProcessUIMap: false,
            uiMapSkipReason: nil
        )))
    }

    private func currentCursorOverlay(
        for capture: CapturedScreenshot,
        cursorCaptureGlobalLocation: CGPoint? = nil,
        includesCursor: Bool
    ) -> CapturedCursorOverlay? {
        guard includesCursor, capture.kind != .scrolling else {
            return nil
        }

        guard capture.kind != .connectedDevice else {
            return nil
        }

        let cursor = NSCursor.current
        let resolvedCaptureCursorLocation = cursorCaptureGlobalLocation
            ?? CursorCaptureGeometry.captureGlobalPoint(
                fromAppKitGlobalPoint: dependencies.systemServices.mouse.appKitGlobalLocation
            )
        let cursorImage = cursor.image
        var proposedRect = CGRect(origin: .zero, size: cursorImage.size)
        guard let image = cursorImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
              let captureCursorLocation = resolvedCaptureCursorLocation,
              let rect = CursorCaptureGeometry.overlayRect(
                  cursorCaptureGlobalLocation: captureCursorLocation,
                  cursorHotSpot: cursor.hotSpot,
                  cursorSize: cursorImage.size,
                  captureSourceRect: capture.sourceRect,
                  capturePixelSize: capture.pixelSize
              ) else {
            return nil
        }

        return CapturedCursorOverlay(image: image, rect: rect)
    }

    func recordCompletedCapture(request: LastCaptureRequest, runOptions: CaptureRunOptions) {
        lastCaptureRequest = request
        lastCaptureRunOptions = runOptions
    }

    func scheduleUIMapCapture(for controller: EditorController, capture: CapturedScreenshot) {
        let service = uiMapCaptureService
        let controllerID = ObjectIdentifier(controller)

        Task { @MainActor [weak self] in
            let uiMap = await Task.detached(priority: .userInitiated) {
                service.captureUIMap(for: capture)
            }.value

            guard let self,
                  let activeController = self.documents?.activeCaptureEditorController,
                  ObjectIdentifier(activeController) == controllerID else {
                return
            }

            activeController.finishUIMapProcessing(with: uiMap)

            if let uiMap {
                CaptureWorkflowUIMapDiagnostics.notice("[UIMap] CaptureWorkflow attached UI Map asynchronously flattenedElements=\(uiMap.elementCount)")
            } else {
                CaptureWorkflowUIMapDiagnostics.notice("[UIMap] CaptureWorkflow async UI Map service returned nil")
                activeController.showNotice(uiMapCaptureUnavailableNotice(for: capture))
            }
        }
    }

    func noticeSkippedUIMapCapture(reason: String?) {
        CaptureWorkflowUIMapDiagnostics.notice(
            "[UIMap] CaptureWorkflow skipped capture: \(reason ?? "screenshot already has UI Map metadata or capture disabled for this workflow")"
        )
    }

    private func uiMapCaptureUnavailableNotice(for capture: CapturedScreenshot) -> String {
        dependencies.permissions.refreshPermissions()

        guard capture.kind == .window else {
            return "UI Map is available for Window captures only."
        }

        guard dependencies.permissions.permissionStatus.hasAccessibility else {
            return "UI Map was not captured. Allow Accessibility access, then capture the window again."
        }

        return "No UI Map metadata was available for this window."
    }
}

enum CaptureWorkflowCompletionError: LocalizedError {
    case missingCoordinator

    var errorDescription: String? {
        switch self {
        case .missingCoordinator:
            "Capture workflow is not connected to the workflow coordinator."
        }
    }
}
