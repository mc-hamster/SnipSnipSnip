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

    func updateUIMapEnabled(_ enabled: Bool) {
        guard dependencies.capabilities.isEnabled(.uiMap) else {
            uiMapEnabled = false
            return
        }

        uiMapEnabled = enabled

        if enabled {
            dependencies.permissions.refreshPermissions()

            if !dependencies.permissions.permissionStatus.hasAccessibility {
                dependencies.permissions.requestPermission(.accessibility)
            }
        }
    }

    func present(_ error: Error) {
        guard !(error is CancellationError) else {
            return
        }

        _ = dependencies.permissions.reconcileScreenRecordingPermissionFailureIfNeeded(after: error)

        dependencies.lifecycle.presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        dependencies.lifecycle.requestMainWindowPresentation()
    }
}
