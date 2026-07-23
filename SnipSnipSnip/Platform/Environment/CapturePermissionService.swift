import Foundation

nonisolated protocol CapturePermissionServicing: Sendable {
    @MainActor
    var currentAppName: String { get }

    @MainActor
    var currentAppPath: String { get }

    func currentStatus() -> CapturePermissionStatus
    func availableSetupRequirements() -> [CapturePermissionRequirement]
    func canRequest(_ requirement: CapturePermissionRequirement) -> Bool

    @MainActor
    @discardableResult
    func requestAccess(for requirement: CapturePermissionRequirement) -> Bool

    func verifyScreenRecordingAccess() async -> Bool

    @MainActor
    func openSystemSettings(for requirement: CapturePermissionRequirement)

    @MainActor
    func revealCurrentAppInFinder()

    @MainActor
    func copyCurrentAppPathToPasteboard()

    func indicatesScreenRecordingPermissionFailure(_ error: Error) -> Bool
}

nonisolated struct CapturePermissionSystemClient: Sendable {
    var screenRecordingStatus: @Sendable () -> Bool
    var accessibilityStatus: @Sendable () -> Bool
    var screenRecordingAccessVerifier: @Sendable () async -> Bool
    var screenRecordingAccessRequester: @MainActor @Sendable () -> Bool
    var accessibilityAccessRequester: @MainActor @Sendable () -> Bool
    var systemSettingsOpener: @MainActor @Sendable (CapturePermissionRequirement) -> Void
    var currentAppName: @MainActor @Sendable () -> String
    var currentAppPath: @MainActor @Sendable () -> String
    var revealCurrentAppInFinder: @MainActor @Sendable () -> Void
    var copyCurrentAppPathToPasteboard: @MainActor @Sendable () -> Void
    var screenRecordingPermissionFailureDetector: @Sendable (Error) -> Bool

    static let live = CapturePermissionSystemClient(
        screenRecordingStatus: {
            ScreenCapturePermissions.screenRecordingStatusProvider()
        },
        accessibilityStatus: {
            ScreenCapturePermissions.accessibilityStatusProvider()
        },
        screenRecordingAccessVerifier: {
            await ScreenCapturePermissions.verifyScreenRecordingAccess()
        },
        screenRecordingAccessRequester: {
            ScreenCapturePermissions.requestScreenRecordingAccess()
        },
        accessibilityAccessRequester: {
            ScreenCapturePermissions.requestAccessibilityAccess()
        },
        systemSettingsOpener: { requirement in
            ScreenCapturePermissions.openSystemSettings(for: requirement)
        },
        currentAppName: {
            ScreenCapturePermissions.currentAppName
        },
        currentAppPath: {
            ScreenCapturePermissions.currentAppPath
        },
        revealCurrentAppInFinder: {
            ScreenCapturePermissions.revealCurrentAppInFinder()
        },
        copyCurrentAppPathToPasteboard: {
            ScreenCapturePermissions.copyCurrentAppPathToPasteboard()
        },
        screenRecordingPermissionFailureDetector: { error in
            ScreenCapturePermissions.indicatesScreenRecordingPermissionFailure(error)
        }
    )
}

nonisolated struct SystemCapturePermissionService: CapturePermissionServicing {
    let capabilities: AppCapabilitySnapshot
    let client: CapturePermissionSystemClient

    init(
        capabilities: AppCapabilitySnapshot,
        client: CapturePermissionSystemClient = .live
    ) {
        self.capabilities = capabilities
        self.client = client
    }

    @MainActor
    var currentAppName: String {
        client.currentAppName()
    }

    @MainActor
    var currentAppPath: String {
        client.currentAppPath()
    }

    func currentStatus() -> CapturePermissionStatus {
        CapturePermissionStatus(
            hasScreenRecording: client.screenRecordingStatus(),
            hasAccessibility: client.accessibilityStatus()
        )
    }

    func availableSetupRequirements() -> [CapturePermissionRequirement] {
        CapturePermissionRequirement.availableCases(for: capabilities)
    }

    func canRequest(_ requirement: CapturePermissionRequirement) -> Bool {
        switch requirement {
        case .screenRecording:
            return true
        case .accessibility:
            return capabilities.isEnabled(.accessibilityAutomation)
                || capabilities.isEnabled(.uiMap)
                || capabilities.isEnabled(.scrollingCapture)
                || capabilities.isEnabled(.guide)
        }
    }

    @MainActor
    @discardableResult
    func requestAccess(for requirement: CapturePermissionRequirement) -> Bool {
        guard canRequest(requirement) else {
            return false
        }

        switch requirement {
        case .screenRecording:
            return client.screenRecordingAccessRequester()
        case .accessibility:
            return client.accessibilityAccessRequester()
        }
    }

    func verifyScreenRecordingAccess() async -> Bool {
        await client.screenRecordingAccessVerifier()
    }

    @MainActor
    func openSystemSettings(for requirement: CapturePermissionRequirement) {
        client.systemSettingsOpener(requirement)
    }

    @MainActor
    func revealCurrentAppInFinder() {
        client.revealCurrentAppInFinder()
    }

    @MainActor
    func copyCurrentAppPathToPasteboard() {
        client.copyCurrentAppPathToPasteboard()
    }

    func indicatesScreenRecordingPermissionFailure(_ error: Error) -> Bool {
        client.screenRecordingPermissionFailureDetector(error)
    }
}
