import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class PermissionWorkflowModelTests: XCTestCase {
    func testRequestPermissionOwnsSetupGuideAndSettingsRouting() async {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions)

        workflow.requestPermission(.screenRecording)

        XCTAssertEqual(permissions.requestedRequirements(), [.screenRecording])
        XCTAssertEqual(workflow.permissionSetupGuide?.requirement, .screenRecording)
        XCTAssertEqual(workflow.permissionSetupGuide?.appName, "Fixture App")
        XCTAssertEqual(workflow.permissionSetupGuide?.appPath, "/Applications/Fixture.app")

        await waitUntil {
            permissions.openedSettingsRequirements() == [.screenRecording]
        }
    }

    func testRefreshPermissionsReconcilesStaleScreenRecordingGrant() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false),
            screenRecordingVerifier: { false }
        )
        let workflow = makeWorkflow(permissions: permissions)

        workflow.refreshPermissions()

        await waitUntil {
            workflow.permissionStatus == CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false)
        }
    }

    func testPermissionOutputRetriesPendingCaptureCommand() async {
        let suiteName = "PermissionWorkflowModelTests.permissionOutputRetriesPendingCaptureCommand"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false))
        let captureService = PermissionRetryCaptureService()
        let model = AppModel(
            defaults: defaults,
            environment: AppEnvironment(defaults: defaults, permissions: permissions),
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: captureService,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        model.capture.captureCurrentDisplay()

        XCTAssertNotNil(model.capture.pendingPermissionCommand)
        XCTAssertNil(model.documents.editorController)

        permissions.updateStatus(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        model.permissions.refreshPermissions()

        await waitUntil {
            model.documents.editorController != nil
        }

        XCTAssertNil(model.capture.pendingPermissionCommand)
        if case .fullscreen? = model.capture.lastCaptureRequest {
        } else {
            XCTFail("Expected fullscreen capture request after permission retry")
        }
        XCTAssertEqual(captureService.fullscreenCaptureCount, 1)
    }

    private func makeWorkflow(permissions: MutablePermissionService) -> PermissionWorkflowModel {
        PermissionWorkflowModel(
            dependencies: PermissionWorkflowDependencies(
                capabilities: testCapabilities,
                permissions: permissions,
                scheduler: ImmediateScheduler(),
                lifecycle: TestWorkflowLifecyclePresenter()
            )
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

private final class TestWorkflowLifecyclePresenter: WorkflowLifecyclePresenting {
    var presentedErrors: [String] = []
    var didRequestMainWindowPresentation = false
    var workingMessages: [String] = []
    var didPresentExperimentalNotice = false

    func presentError(_ message: String) {
        presentedErrors.append(message)
    }

    func clearError() {
        presentedErrors = []
    }

    func updateWorkingMessage(_ message: String) {
        workingMessages.append(message)
    }

    func presentPresentationExperimentalNotice() {
        didPresentExperimentalNotice = true
    }

    func requestMainWindowPresentation() {
        didRequestMainWindowPresentation = true
    }
}

private struct ImmediateScheduler: Scheduling {
    func sleep(nanoseconds: UInt64) async throws {}
}

private final class MutablePermissionService: CapturePermissionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var status: CapturePermissionStatus
    private let verifier: @Sendable () async -> Bool
    private var requested: [CapturePermissionRequirement] = []
    private var openedSettings: [CapturePermissionRequirement] = []

    init(
        status: CapturePermissionStatus,
        screenRecordingVerifier: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.status = status
        self.verifier = screenRecordingVerifier
    }

    var currentAppName: String { "Fixture App" }
    var currentAppPath: String { "/Applications/Fixture.app" }

    func currentStatus() -> CapturePermissionStatus {
        lock.withLock { status }
    }

    func updateStatus(_ status: CapturePermissionStatus) {
        lock.withLock {
            self.status = status
        }
    }

    func availableSetupRequirements() -> [CapturePermissionRequirement] {
        CapturePermissionRequirement.availableCases(for: testCapabilities)
    }

    func canRequest(_ requirement: CapturePermissionRequirement) -> Bool {
        true
    }

    func requestAccess(for requirement: CapturePermissionRequirement) -> Bool {
        lock.withLock {
            requested.append(requirement)
        }
        return currentStatus().hasAccess(to: requirement)
    }

    func verifyScreenRecordingAccess() async -> Bool {
        await verifier()
    }

    func openSystemSettings(for requirement: CapturePermissionRequirement) {
        lock.withLock {
            openedSettings.append(requirement)
        }
    }

    func revealCurrentAppInFinder() {}

    func copyCurrentAppPathToPasteboard() {}

    func indicatesScreenRecordingPermissionFailure(_ error: Error) -> Bool {
        false
    }

    func requestedRequirements() -> [CapturePermissionRequirement] {
        lock.withLock { requested }
    }

    func openedSettingsRequirements() -> [CapturePermissionRequirement] {
        lock.withLock { openedSettings }
    }
}

private final class PermissionRetryCaptureService: ScreenCaptureServiceType, @unchecked Sendable {
    private let lock = NSLock()
    private var fullscreenCaptures = 0

    var fullscreenCaptureCount: Int {
        lock.withLock { fullscreenCaptures }
    }

    func listWindows(excluding processID: pid_t, includeThumbnails: Bool) async throws -> [CaptureWindowSummary] {
        []
    }

    func frontmostWindow(excluding processID: pid_t) async throws -> CaptureWindowSummary {
        throw ScreenCaptureError.noWindowsAvailable
    }

    func resolveWindowTarget(_ window: CaptureWindowSummary, excluding processID: pid_t) async throws -> CaptureWindowSummary {
        window
    }

    func captureCurrentDisplay() async throws -> CapturedScreenshot {
        lock.withLock {
            fullscreenCaptures += 1
        }
        return makeCapturedScreenshot(kind: .fullscreen, sourceName: "Fullscreen")
    }

    func captureFullscreen(mode: ScreenshotFullscreenDisplayMode, selectedDisplayID: CGDirectDisplayID?) async throws -> CapturedScreenshot {
        try await captureCurrentDisplay()
    }

    func captureDesktopOverlaySnapshot() async throws -> DesktopCompositeSnapshot {
        throw ScreenCaptureError.noDisplays
    }

    func captureRegion(from snapshot: DesktopCompositeSnapshot, selection: CGRect) async throws -> CapturedScreenshot {
        throw ScreenCaptureError.invalidRegion
    }

    func captureRegion(in selection: CGRect) async throws -> CapturedScreenshot {
        throw ScreenCaptureError.invalidRegion
    }

    func captureRegionDirect(in selection: CGRect) async throws -> CapturedScreenshot {
        throw ScreenCaptureError.invalidRegion
    }

    func captureRegionWithinSingleDisplayDirect(in selection: CGRect) async throws -> CapturedScreenshot {
        throw ScreenCaptureError.invalidRegion
    }

    func captureWindow(_ window: CaptureWindowSummary) async throws -> CapturedScreenshot {
        throw ScreenCaptureError.windowImageUnavailable
    }
}
