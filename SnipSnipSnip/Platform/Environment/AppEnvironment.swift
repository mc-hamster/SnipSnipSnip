import Foundation

@MainActor
struct AppEnvironment {
    let defaults: UserDefaults
    let capabilities: AppCapabilitySnapshot
    let preferenceStores: AppPreferenceStores
    let systemServices: AppSystemServices
    var permissions: any CapturePermissionServicing { systemServices.permissions }

    init(
        defaults: UserDefaults = .standard,
        buildTarget: BuildTarget = .current,
        capabilityProvider: any AppCapabilityProvider = BuildTargetCapabilityProvider(),
        permissions: (any CapturePermissionServicing)? = nil,
        systemServices: AppSystemServices? = nil
    ) {
        self.defaults = defaults
        let capabilities = capabilityProvider.snapshot(for: buildTarget)
        self.capabilities = capabilities
        self.preferenceStores = AppPreferenceStores(storage: defaults)
        let resolvedPermissions = permissions ?? SystemCapturePermissionService(capabilities: capabilities)
        self.systemServices = systemServices ?? AppSystemServices.live(permissions: resolvedPermissions)
    }

    func makeScreenCaptureService() -> ScreenCaptureService {
        ScreenCaptureService(
            permissions: permissions,
            platform: systemServices.screenCapturePlatform,
            workspace: systemServices.workspace,
            screens: systemServices.screens,
            mouse: systemServices.mouse,
            windowFocus: systemServices.windowFocus,
            clock: systemServices.clock
        )
    }

    func makeScreenRecordingService() -> ScreenRecordingService {
        ScreenRecordingService(
            permissions: permissions,
            platform: systemServices.screenRecordingPlatform,
            capturePlatform: systemServices.screenCapturePlatform,
            workspace: systemServices.workspace,
            screens: systemServices.screens,
            files: systemServices.files,
            mouse: systemServices.mouse,
            clock: systemServices.clock
        )
    }

    func makeScrollingCaptureService(captureService: any ScreenCaptureServiceType) -> ScrollingCaptureService {
        ScrollingCaptureService(
            captureService: captureService,
            permissions: permissions,
            accessibility: systemServices.accessibility,
            screens: systemServices.screens,
            scheduler: systemServices.scheduler,
            clock: systemServices.clock
        )
    }

    func makeUIMapCaptureService() -> any UIMapCaptureServiceType {
        AccessibilityUIMapCaptureService(
            capabilities: capabilities,
            accessibility: systemServices.accessibility,
            screens: systemServices.screens,
            clock: systemServices.clock
        )
    }

    func makeConnectedDeviceCaptureService() -> any ConnectedDeviceCaptureServiceType {
        ConnectedDeviceCaptureService(
            capabilities: capabilities,
            platform: systemServices.connectedDevicePlatform
        )
    }
}
