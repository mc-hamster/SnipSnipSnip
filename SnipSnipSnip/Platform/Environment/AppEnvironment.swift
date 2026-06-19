import Foundation

@MainActor
struct AppEnvironment {
    let defaults: UserDefaults
    let capabilities: AppCapabilitySnapshot
    let preferenceStores: AppPreferenceStores
    private let permissionStatusProvider: @MainActor () -> CapturePermissionStatus

    init(
        defaults: UserDefaults = .standard,
        buildTarget: BuildTarget = .current,
        capabilityProvider: any AppCapabilityProvider = BuildTargetCapabilityProvider(),
        permissionStatusProvider: @escaping @MainActor () -> CapturePermissionStatus = {
            CapturePermissionStatus.current()
        }
    ) {
        self.defaults = defaults
        self.capabilities = capabilityProvider.snapshot(for: buildTarget)
        self.preferenceStores = AppPreferenceStores(storage: defaults)
        self.permissionStatusProvider = permissionStatusProvider
    }

    func currentPermissionStatus() -> CapturePermissionStatus {
        permissionStatusProvider()
    }

    func makeUIMapCaptureService() -> any UIMapCaptureServiceType {
        AccessibilityUIMapCaptureService(capabilities: capabilities)
    }

    func makeConnectedDeviceCaptureService() -> any ConnectedDeviceCaptureServiceType {
        ConnectedDeviceCaptureService(capabilities: capabilities)
    }
}
