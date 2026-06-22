import Foundation

@MainActor
extension PermissionWorkflowModel {
    func presentPermissionSetupGuide(for requirement: CapturePermissionRequirement) {
        refreshPermissions()

        guard !permissionStatus.hasAccess(to: requirement) else {
            permissionSetupGuide = nil
            return
        }

        permissionSetupGuide = PermissionSetupGuide(
            requirement: requirement,
            appName: dependencies.permissions.currentAppName,
            appPath: dependencies.permissions.currentAppPath
        )
    }

    func dismissPermissionSetupGuide() {
        permissionSetupGuide = nil
        refreshPermissions()
    }

    func revealAppForPermissionSetup() {
        dependencies.permissions.revealCurrentAppInFinder()
    }

    func copyAppPathForPermissionSetup() {
        dependencies.permissions.copyCurrentAppPathToPasteboard()
    }

    func openPermissionSettingsFromGuide() {
        guard let permissionSetupGuide else {
            return
        }

        openPermissionSettings(permissionSetupGuide.requirement)
    }

    func checkPermissionSetupGuideStatus() {
        refreshPermissions()

        guard let permissionSetupGuide,
              permissionStatus.hasAccess(to: permissionSetupGuide.requirement) else {
            return
        }

        self.permissionSetupGuide = nil
        dependencies.lifecycle.clearError()
    }
}
