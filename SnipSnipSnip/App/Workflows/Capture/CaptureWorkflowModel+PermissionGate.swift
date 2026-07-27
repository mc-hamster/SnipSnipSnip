import Foundation

enum PendingCapturePermissionCommand {
    case currentDisplay
    case region
    case frontmostWindow
    case windowPicker
    case scrollingCapture

    func perform(on capture: CaptureWorkflowModel) {
        switch self {
        case .currentDisplay:
            capture.beginFullscreenCapture()
        case .region:
            capture.beginRegionCapture()
        case .frontmostWindow:
            capture.beginFrontmostWindowCapture()
        case .windowPicker:
            capture.windowPickerMode = .screenshot
            capture.beginWindowPickerPresentation()
        case .scrollingCapture:
            capture.beginScrollingCapture()
        }
    }
}

struct PendingCapturePermissionRequest {
    let requirements: [CapturePermissionRequirement]
    let command: PendingCapturePermissionCommand
    let captureContext: CaptureCompletionContext

    var captureIntent: CaptureIntent { captureContext.intent }
    var completionRole: CaptureCompletionRole { captureContext.role }
    var oneShotOptions: CaptureOneShotOptions? {
        captureContext.oneShotOptions
    }

    init(
        requirements: [CapturePermissionRequirement],
        command: PendingCapturePermissionCommand,
        captureIntent: CaptureIntent,
        completionRole: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil
    ) {
        self.requirements = requirements
        self.command = command
        self.captureContext = CaptureCompletionContext(
            intent: captureIntent,
            role: completionRole,
            oneShotOptions: oneShotOptions
        )
    }

    init(
        requirements: [CapturePermissionRequirement],
        command: PendingCapturePermissionCommand,
        captureContext: CaptureCompletionContext
    ) {
        self.requirements = requirements
        self.command = command
        self.captureContext = captureContext
    }
}

@MainActor
extension CaptureWorkflowModel {
    var windowUIMapNeedsAccessibilityAccess: Bool {
        windowUIMapEnabled && !dependencies.permissions.permissionStatus.hasAccessibility
    }

    func preflightPermissions(_ requirements: [CapturePermissionRequirement], for featureName: String) -> Bool {
        dependencies.permissions.preflight(requirements, featureName: featureName).isGranted
    }

    func runActionWhenPermissionsReady(
        _ requirements: [CapturePermissionRequirement],
        featureName: String,
        pendingCommand: PendingCapturePermissionCommand,
        action: @escaping @MainActor () -> Void
    ) {
        guard preflightPermissions(requirements, for: featureName) else {
            let captureContext = activeCaptureContext
            pendingPermissionCommand = PendingCapturePermissionRequest(
                requirements: CapturePermissionRequirement.allCases.filter { requirements.contains($0) },
                command: pendingCommand,
                captureContext: captureContext
            )
            // Permission deferral owns the operation now. Do not let its
            // one-shot context affect a different capture while access is
            // being granted or refused.
            resetPreparedCaptureContext(ifMatching: captureContext)
            return
        }

        pendingPermissionCommand = nil
        action()
    }

    func retryPendingPermissionCommandIfSatisfied(_ status: CapturePermissionStatus) {
        guard let pendingPermissionCommand,
              pendingPermissionCommand.requirements.allSatisfy({ status.hasAccess(to: $0) }) else {
            return
        }

        self.pendingPermissionCommand = nil
        activeCaptureContext = pendingPermissionCommand.captureContext
        pendingPermissionCommand.command.perform(on: self)
    }

    func cancelPendingPermissionCommand() {
        guard let pendingPermissionCommand else {
            return
        }
        self.pendingPermissionCommand = nil
        resetPreparedCaptureContext(
            ifMatching: pendingPermissionCommand.captureContext
        )
        dependencies.lifecycle.requestMainWindowPresentation()
    }

    func updateUIMapEnabled(_ enabled: Bool, requestAccessIfNeeded: Bool = true) {
        guard dependencies.capabilities.isEnabled(.uiMap) else {
            uiMapEnabled = false
            return
        }

        uiMapEnabled = enabled

        if enabled && requestAccessIfNeeded {
            dependencies.permissions.refreshPermissions()

            if !dependencies.permissions.permissionStatus.hasAccessibility {
                dependencies.permissions.requestPermission(.accessibility)
            }
        }
    }

    func present(_ error: Error) {
        present(error, recovering: nil)
    }

    func present(
        _ error: Error,
        recovering request: LastCaptureRequest?,
        captureContext: CaptureCompletionContext? = nil
    ) {
        let failedCaptureContext =
            captureContext ?? activeCaptureContext
        resetPreparedCaptureContext(ifMatching: failedCaptureContext)
        guard !(error is CancellationError) else {
            pendingRecoveryRequest = nil
            pendingRecoveryCaptureContext = nil
            pendingScrollingPartialCapture = nil
            dependencies.lifecycle.requestMainWindowPresentation()
            return
        }

        _ = dependencies.permissions.reconcileScreenRecordingPermissionFailureIfNeeded(after: error)
        pendingRecoveryRequest = request ?? lastCaptureRequest
        pendingRecoveryCaptureContext = failedCaptureContext
        captureRecovery = recovery(for: error)
        dependencies.lifecycle.requestMainWindowPresentation()
    }

    func dismissCaptureRecovery() {
        captureRecovery = nil
        pendingRecoveryRequest = nil
        pendingRecoveryCaptureContext = nil
        pendingScrollingPartialCapture = nil
        activeCaptureContext = .standalone
        dependencies.lifecycle.requestMainWindowPresentation()
    }

    func performCaptureRecovery(_ action: CaptureRecoveryAction) {
        captureRecovery = nil
        let captureContext =
            pendingRecoveryCaptureContext ?? activeCaptureContext
        pendingRecoveryCaptureContext = nil
        activeCaptureContext = .standalone
        if action != .keepPartialResult {
            pendingScrollingPartialCapture = nil
        }

        switch action {
        case .retryLastCapture:
            retryRecoveryCapture(with: captureContext)
        case .setUpScreenRecording:
            dependencies.permissions.requestPermission(.screenRecording)
        case .setUpAccessibility:
            dependencies.permissions.requestPermission(.accessibility)
        case .refreshWindows:
            refreshAvailableWindows(includeThumbnails: true, allowsCancellingPendingThumbnailRefresh: true)
        case .pickAnotherWindow:
            presentWindowPicker(
                intent: captureContext.intent,
                completionRole: captureContext.role,
                oneShotOptions: captureContext.oneShotOptions
            )
        case .captureFrontmostWindow:
            captureFrontmostWindow(
                intent: captureContext.intent,
                completionRole: captureContext.role,
                oneShotOptions: captureContext.oneShotOptions
            )
        case .useCurrentDisplay:
            screenshotFullscreenDisplayMode = .currentDisplay
            selectedScreenshotFullscreenDisplayID = nil
            captureCurrentDisplay(
                intent: captureContext.intent,
                completionRole: captureContext.role,
                oneShotOptions: captureContext.oneShotOptions
            )
        case .chooseDisplay:
            dependencies.lifecycle.presentSettings(tab: .capture)
        case .captureVisibleArea:
            captureRegion(
                intent: captureContext.intent,
                completionRole: captureContext.role,
                oneShotOptions: captureContext.oneShotOptions
            )
        case .chooseAnotherArea:
            pendingScrollingPartialCapture = nil
            captureScrollingArea(
                intent: captureContext.intent,
                completionRole: captureContext.role,
                oneShotOptions: captureContext.oneShotOptions
            )
        case .keepPartialResult:
            keepPendingScrollingPartialResult(with: captureContext)
        case .openTroubleshooting:
            break
        }
    }

    private func keepPendingScrollingPartialResult(
        with captureContext: CaptureCompletionContext
    ) {
        guard let pending = pendingScrollingPartialCapture else {
            return
        }

        pendingScrollingPartialCapture = nil
        activeCaptureContext = captureContext
        let runOptions = captureRunOptions(for: captureContext)
        do {
            try completeCapture(
                pending.result.capturedScreenshot,
                request: .scrolling(pending.result.sourceViewportRect),
                isPrivateCapture: pending.isPrivateCapture,
                runOptions: runOptions,
                completionContext: captureContext
            )
            showCapturedFeedback()
            dependencies.lifecycle.presentError("Partial scrolling capture kept. Review the seams before sharing.")
        } catch {
            present(
                error,
                recovering:
                    .scrolling(pending.result.sourceViewportRect),
                captureContext: captureContext
            )
        }
    }

    private func retryRecoveryCapture(
        with captureContext: CaptureCompletionContext
    ) {
        guard let pendingRecoveryRequest else {
            return
        }

        self.pendingRecoveryRequest = nil
        activeCaptureContext = captureContext
        switch pendingRecoveryRequest {
        case .region(let region):
            repeatRegionCapture(region)
        case .scrolling(let region):
            repeatScrollingCapture(region)
        case .window(let window):
            repeatWindowCapture(window)
        case .frontmostWindow:
            captureFrontmostWindow(
                intent: captureContext.intent,
                completionRole: captureContext.role,
                oneShotOptions: captureContext.oneShotOptions
            )
        case .fullscreen:
            captureCurrentDisplay(
                intent: captureContext.intent,
                completionRole: captureContext.role,
                oneShotOptions: captureContext.oneShotOptions
            )
        case .connectedDevice(let device):
            captureConnectedDevice(
                device,
                intent: captureContext.intent,
                completionRole: captureContext.role,
                oneShotOptions: captureContext.oneShotOptions
            )
        }
    }

    private func recovery(for error: Error) -> CaptureRecovery {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        switch error {
        case ScreenCaptureError.permissionDenied:
            return CaptureRecovery(
                title: "Screen Recording Is Needed",
                message: message,
                actions: [.setUpScreenRecording, .retryLastCapture]
            )
        case ScreenCaptureError.noWindowsAvailable, ScreenCaptureError.windowImageUnavailable:
            return CaptureRecovery(
                title: "That Window Is No Longer Available",
                message: "The window may have moved, closed, or become protected. Refresh the list or choose another target.",
                actions: [.refreshWindows, .pickAnotherWindow, .captureFrontmostWindow]
            )
        case ScreenCaptureError.currentDisplayUnavailable, ScreenCaptureError.noDisplays:
            return CaptureRecovery(
                title: "That Display Is Unavailable",
                message: message,
                actions: [.useCurrentDisplay, .chooseDisplay]
            )
        case ScrollingCaptureError.accessibilityPermissionDenied:
            return CaptureRecovery(
                title: "Accessibility Is Needed",
                message: message,
                actions: [.setUpAccessibility, .retryLastCapture]
            )
        case ScrollingCaptureError.noScrollableTarget:
            return CaptureRecovery(
                title: "Choose a Scrollable Area",
                message: message,
                actions: [.chooseAnotherArea, .captureVisibleArea]
            )
        case ScrollingCaptureError.stitchingFailed, ScrollingCaptureError.firstFrameUnavailable:
            return CaptureRecovery(
                title: "Scrolling Capture Could Not Finish",
                message: message,
                actions: [.retryLastCapture, .captureVisibleArea, .openTroubleshooting]
            )
        case let interruption as ScrollingCaptureInterruptedError:
            return CaptureRecovery(
                title: "Keep the Useful Part?",
                message: interruption.errorDescription ?? interruption.reason,
                actions: [.keepPartialResult, .retryLastCapture, .captureVisibleArea]
            )
        default:
            return CaptureRecovery(
                title: "Capture Needs Attention",
                message: message,
                actions: [.retryLastCapture, .openTroubleshooting]
            )
        }
    }
}
