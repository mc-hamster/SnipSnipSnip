import Foundation

@MainActor
struct PermissionOperationContinuation {
    let requirements: [CapturePermissionRequirement]
    let featureName: String
    let resume: @MainActor () -> Void
    var alternativeTitle: String? = nil
    var alternative: (@MainActor () -> Void)? = nil
}

@MainActor
extension PermissionWorkflowModel {
    func offerPermissionAlternative(title: String, action: @escaping @MainActor () -> Void) {
        permissionContinuation?.alternativeTitle = title
        permissionContinuation?.alternative = action
    }

    func cancelDeferredOperation(ifFeature feature: String?) {
        guard let permissionContinuation, feature == nil || permissionContinuation.featureName == feature else { return }
        dismissPermissionSetupGuide()
    }

    func rememberPermissionRestartAction(_ action: PermissionRestartAction) {
        guard permissionContinuation != nil else { return }
        dependencies.restartStore?.save(action)
    }

    var canContinueOperation: Bool {
        guard let permissionContinuation else { return false }
        return permissionContinuation.requirements.allSatisfy { permissionStatus.hasAccess(to: $0) }
    }

    func deferOperation(
        requiring requirements: [CapturePermissionRequirement],
        featureName: String,
        resume: @escaping @MainActor () -> Void
    ) {
        dependencies.restartStore?.save(nil)
        permissionContinuation = PermissionOperationContinuation(
            requirements: requirements, featureName: featureName, resume: resume
        )
        updateContinuationGuide()
    }

    func continueOperation() {
        guard let continuation = permissionContinuation else { return }
        refreshPermissions()
        if let missing = continuation.requirements.first(where: { !permissionStatus.hasAccess(to: $0) }) {
            requestPermission(missing)
            updateContinuationGuide()
            return
        }
        dependencies.restartStore?.save(nil)
        permissionContinuation = nil
        permissionSetupGuide = nil
        activePermissionRequest = nil
        continuation.resume()
    }

    func updateContinuationGuide() {
        guard let continuation = permissionContinuation,
              let requirement = continuation.requirements.first(where: { !permissionStatus.hasAccess(to: $0) })
                ?? continuation.requirements.last else { return }
        if permissionSetupGuide?.requirement != requirement {
            permissionSetupGuide = PermissionSetupGuide(
                requirement: requirement, appName: dependencies.permissions.currentAppName,
                appPath: dependencies.permissions.currentAppPath, featureName: continuation.featureName
            )
        } else {
            permissionSetupGuide?.featureName = continuation.featureName
        }
    }
}
