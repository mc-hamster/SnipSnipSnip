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

            outputSink?.handle(.permissionsChanged(permissionStatus))
            outputSink?.handle(.requirementsMayNowBeSatisfied(permissionStatus))
        }
    }

    @Published var permissionSetupGuide: PermissionSetupGuide?
    var pendingScreenRecordingPermissionVerificationTask: Task<Void, Never>?
    var screenRecordingPermissionVerificationGeneration = 0

    init(
        dependencies: PermissionWorkflowDependencies,
        permissionStatus: CapturePermissionStatus? = nil
    ) {
        self.dependencies = dependencies
        self.permissionStatus = permissionStatus ?? dependencies.permissions.currentStatus()
    }
}
