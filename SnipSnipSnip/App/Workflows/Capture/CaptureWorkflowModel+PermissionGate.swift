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
            pendingPermissionCommand = PendingCapturePermissionRequest(
                requirements: CapturePermissionRequirement.allCases.filter { requirements.contains($0) },
                command: pendingCommand
            )
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
        pendingPermissionCommand.command.perform(on: self)
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

    func present(_ error: Error, recovering request: LastCaptureRequest?) {
        guard !(error is CancellationError) else {
            return
        }

        _ = dependencies.permissions.reconcileScreenRecordingPermissionFailureIfNeeded(after: error)
        pendingRecoveryRequest = request ?? lastCaptureRequest
        captureRecovery = recovery(for: error)
        dependencies.lifecycle.requestMainWindowPresentation()
    }

    func dismissCaptureRecovery() {
        captureRecovery = nil
    }

    func performCaptureRecovery(_ action: CaptureRecoveryAction) {
        captureRecovery = nil

        switch action {
        case .retryLastCapture:
            retryRecoveryCapture()
        case .setUpScreenRecording:
            dependencies.permissions.requestPermission(.screenRecording)
        case .setUpAccessibility:
            dependencies.permissions.requestPermission(.accessibility)
        case .refreshWindows:
            refreshAvailableWindows(includeThumbnails: true, allowsCancellingPendingThumbnailRefresh: true)
        case .pickAnotherWindow:
            presentWindowPicker()
        case .captureFrontmostWindow:
            captureFrontmostWindow()
        case .useCurrentDisplay:
            screenshotFullscreenDisplayMode = .currentDisplay
            selectedScreenshotFullscreenDisplayID = nil
            captureCurrentDisplay()
        case .chooseDisplay:
            dependencies.lifecycle.requestMainWindowPresentation()
        case .captureVisibleArea:
            captureRegion()
        case .chooseAnotherArea:
            captureScrollingArea()
        case .openTroubleshooting:
            break
        }
    }

    private func retryRecoveryCapture() {
        guard let pendingRecoveryRequest else {
            return
        }

        self.pendingRecoveryRequest = nil
        switch pendingRecoveryRequest {
        case .region(let region):
            repeatRegionCapture(region)
        case .scrolling(let region):
            repeatScrollingCapture(region)
        case .window(let window):
            repeatWindowCapture(window)
        case .frontmostWindow:
            captureFrontmostWindow()
        case .fullscreen:
            captureCurrentDisplay()
        case .connectedDevice(let device):
            captureConnectedDevice(device)
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
        default:
            return CaptureRecovery(
                title: "Capture Needs Attention",
                message: message,
                actions: [.retryLastCapture, .openTroubleshooting]
            )
        }
    }
}
