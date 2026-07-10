import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    @discardableResult
    func performCapture(
        request: LastCaptureRequest,
        minimizeAppWindow: Bool = false,
        runOptions: CaptureRunOptions? = nil,
        _ action: () async throws -> CapturedScreenshot
    ) async -> Bool {
        let resolvedRunOptions = runOptions ?? currentCaptureRunOptions()
        guard ensureScreenshotCaptureAccess(for: request, runOptions: resolvedRunOptions) else {
            return false
        }

        let isPrivateCapture = beginCapturePrivacyLock()
        defer { endCapturePrivacyLock() }

        let hiddenWindow = minimizeAppWindow ? hideAppWindowIfNeeded() : nil
        defer { restoreAppWindowIfNeeded(hiddenWindow) }

        if hiddenWindow != nil {
            try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
        }

        isWorking = true
        dependencies.lifecycle.updateWorkingMessage(
            resolvedRunOptions.captureDelay == .immediate
                ? "Capturing"
                : resolvedRunOptions.captureDelay.shortLabel
        )
        defer { isWorking = false }

        do {
            try await runCaptureDelayIfNeeded(actionName: "Capturing", delay: resolvedRunOptions.captureDelay)
            let capture = try await action()
            showCapturedFeedback()
            try completeCapture(capture, request: request, isPrivateCapture: isPrivateCapture, runOptions: resolvedRunOptions)
            return true
        } catch {
            present(error, recovering: request)
            return false
        }
    }

    func suspendEditorAutosaveForInteractiveCapture() -> InteractiveCaptureAutosaveSuspension {
        interactiveCaptureAutosaveSuspensionDepth += 1
        return documents?.suspendAutosaveForInteractiveCapture()
            ?? InteractiveCaptureAutosaveSuspension(editorControllerID: nil)
    }

    func resumeEditorAutosaveAfterInteractiveCapture(_ suspension: InteractiveCaptureAutosaveSuspension) {
        interactiveCaptureAutosaveSuspensionDepth = max(0, interactiveCaptureAutosaveSuspensionDepth - 1)

        guard interactiveCaptureAutosaveSuspensionDepth == 0 else {
            return
        }

        documents?.resumeAutosaveAfterInteractiveCapture(suspension)
    }

    func ensureScreenshotCaptureAccess() -> Bool {
        ensureScreenshotCaptureAccess(for: .fullscreen)
    }

    func ensureScreenshotCaptureAccess(for request: LastCaptureRequest) -> Bool {
        ensureScreenshotCaptureAccess(for: request, runOptions: currentCaptureRunOptions())
    }

    func ensureScreenshotCaptureAccess(for request: LastCaptureRequest, runOptions: CaptureRunOptions) -> Bool {
        preflightPermissions(
            screenshotCapturePermissionRequirements(for: request, runOptions: runOptions),
            for: screenshotCaptureFeatureName(for: request, runOptions: runOptions)
        )
    }

    func screenshotCapturePermissionRequirements(for request: LastCaptureRequest) -> [CapturePermissionRequirement] {
        screenshotCapturePermissionRequirements(for: request, runOptions: currentCaptureRunOptions())
    }

    func screenshotCapturePermissionRequirements(for request: LastCaptureRequest, runOptions: CaptureRunOptions) -> [CapturePermissionRequirement] {
        request.canIncludeWindowUIMap && dependencies.capabilities.isEnabled(.uiMap) && runOptions.windowUIMapEnabled
            ? [.screenRecording, .accessibility]
            : [.screenRecording]
    }

    func screenshotCaptureFeatureName(for request: LastCaptureRequest) -> String {
        screenshotCaptureFeatureName(for: request, runOptions: currentCaptureRunOptions())
    }

    func screenshotCaptureFeatureName(for request: LastCaptureRequest, runOptions: CaptureRunOptions) -> String {
        request.canIncludeWindowUIMap && dependencies.capabilities.isEnabled(.uiMap) && runOptions.windowUIMapEnabled
            ? "Window Capture with UI Map"
            : "Capture"
    }

    func runCaptureDelayIfNeeded(actionName: String, delay: CaptureDelay? = nil) async throws {
        let resolvedDelay = delay ?? captureDelay
        guard resolvedDelay.countdownSeconds > 0 else {
            dependencies.lifecycle.updateWorkingMessage(actionName)
            return
        }

        let overlay = isRunningUnderTests ? nil : CaptureFeedbackOverlay(
            title: "\(resolvedDelay.countdownSeconds)",
            detail: actionName
        )
        overlay?.show()
        defer {
            overlay?.close()
        }

        for remainingSeconds in stride(from: resolvedDelay.countdownSeconds, through: 1, by: -1) {
            dependencies.lifecycle.updateWorkingMessage("\(actionName) in \(remainingSeconds)…")
            overlay?.update(title: "\(remainingSeconds)", detail: actionName)
            try await dependencies.systemServices.scheduler.sleep(nanoseconds: 1_000_000_000)
        }

        dependencies.lifecycle.updateWorkingMessage(actionName)
        try await dependencies.systemServices.scheduler.sleep(nanoseconds: 80_000_000)
    }

    func showCapturedFeedback() {
        guard !isRunningUnderTests else {
            return
        }

        CaptureFeedbackOverlay.showCapturedFeedback()
    }

    func hideAppWindowIfNeeded() -> AppWindowVisibilityToken? {
        dependencies.appWindowPresenter.hideAppWindowIfNeeded()
    }

    func restoreAppWindowIfNeeded(_ token: AppWindowVisibilityToken?) {
        dependencies.appWindowPresenter.restoreAppWindowIfNeeded(token)
    }

    func promoteToRegularApp() {
        dependencies.appWindowPresenter.promoteToRegularApp()
    }

    func demoteToAccessoryIfPossible() {
        dependencies.appWindowPresenter.demoteToAccessoryIfPossible()
    }

    private var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var isInteractiveCaptureAutosaveSuspended: Bool {
        interactiveCaptureAutosaveSuspensionDepth > 0
    }

    func cancelPendingWindowThumbnailRefresh() {
        pendingWindowThumbnailTask?.cancel()
        pendingWindowThumbnailTask = nil
    }

    func performDocumentWork<Result>(
        message: String,
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        isWorking = true
        dependencies.lifecycle.updateWorkingMessage(message)
        defer { isWorking = false }
        return try await operation()
    }

    func beginVideoWindowSelection() {
        windowPickerMode = .videoRecording
        beginWindowPickerPresentation()
    }

    func dismissWindowPicker() {
        isShowingWindowPicker = false
    }

    func desktopSnapshotForVideoSelection() async throws -> DesktopCompositeSnapshot {
        try await captureService.captureDesktopOverlaySnapshot()
    }

    func videoWindowSelectionSnapshot(fallbackWindows: [CaptureWindowSummary]) async throws -> (windows: [CaptureWindowSummary], snapshot: DesktopCompositeSnapshot) {
        let windowOptions = fallbackWindows.isEmpty ? try await captureService.listWindows(includeThumbnails: false) : fallbackWindows
        let snapshot = try await captureService.captureDesktopOverlaySnapshot()
        return (windowOptions, snapshot)
    }

    func performVideoWork<Result>(
        message: String,
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        isWorking = true
        dependencies.lifecycle.updateWorkingMessage(message)
        defer { isWorking = false }
        return try await operation()
    }

}
