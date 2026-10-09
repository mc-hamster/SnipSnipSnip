import Combine
import Foundation

@MainActor
final class PermissionWorkflowModel: ObservableObject, PermissionGatekeeping {
    let dependencies: PermissionWorkflowDependencies
    weak var outputSink: (any WorkflowOutputSink)?

    @Published var permissionStatus: CapturePermissionStatus {
        didSet {
            guard oldValue != permissionStatus else {
                return
            }

            if oldValue.hasScreenRecording != permissionStatus.hasScreenRecording {
                AppAccessibility.announce(permissionStatus.hasScreenRecording
                    ? String(localized: "Screen Recording access is ready.")
                    : String(localized: "Screen Recording access needs attention."))
            }
            if oldValue.hasAccessibility != permissionStatus.hasAccessibility {
                AppAccessibility.announce(permissionStatus.hasAccessibility
                    ? String(localized: "Accessibility access is ready.")
                    : String(localized: "Accessibility access needs attention."))
            }
            outputSink?.handle(.permissionsChanged(permissionStatus))
            // Consent may arrive while System Settings is frontmost. Resume only
            // after the user chooses Continue in the originating workflow.
            updateContinuationGuide()
        }
    }

    @Published var mediaPermissionStatuses: [MediaPermissionKind: MediaPermissionStatus] = [:]
    @Published var activeMediaPermissionRequest: MediaPermissionKind?
    @Published var permissionContinuation: PermissionOperationContinuation?
    @Published var permissionSetupGuide: PermissionSetupGuide?
    @Published var screenRecordingSetupNeedsAttention = false {
        didSet {
            if screenRecordingSetupNeedsAttention && !oldValue {
                AppAccessibility.announce(String(localized: "Restart required to apply Screen Recording access."))
            }
        }
    }
    @Published var isCheckingPermission = false
    @Published var activePermissionRequest: CapturePermissionRequirement? {
        didSet {
            guard oldValue != activePermissionRequest else {
                return
            }

            updateActivePermissionPolling()
        }
    }

    var activePermissionPollingTask: Task<Void, Never>?
    var permissionCheckTask: Task<Void, Never>?
    var permissionCheckID: UUID?
    var screenRecordingPermissionVerificationGeneration = 0
    var hasVerifiedScreenRecordingAccess = false
    var lastScreenRecordingPreflightStatus: Bool
    var screenRecordingSetupStartedThisRun = false

    init(
        dependencies: PermissionWorkflowDependencies,
        permissionStatus: CapturePermissionStatus? = nil
    ) {
        self.dependencies = dependencies
        let currentStatus = dependencies.permissions.currentStatus()
        self.permissionStatus = permissionStatus ?? currentStatus
        lastScreenRecordingPreflightStatus = currentStatus.hasScreenRecording
        hasVerifiedScreenRecordingAccess = self.permissionStatus.hasScreenRecording
    }

    deinit {
        activePermissionPollingTask?.cancel()
        permissionCheckTask?.cancel()
    }
}
