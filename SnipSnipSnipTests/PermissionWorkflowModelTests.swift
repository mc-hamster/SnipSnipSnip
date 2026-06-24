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
        XCTAssertEqual(workflow.activePermissionRequest, .screenRecording)
        XCTAssertEqual(workflow.permissionSetupGuide?.requirement, .screenRecording)
        XCTAssertEqual(workflow.permissionSetupGuide?.appName, "Fixture App")
        XCTAssertEqual(workflow.permissionSetupGuide?.appPath, "/Applications/Fixture.app")
        XCTAssertTrue(permissions.openedSettingsRequirements().isEmpty)

        workflow.openPermissionSettings(.screenRecording)

        XCTAssertEqual(permissions.openedSettingsRequirements(), [.screenRecording])
        XCTAssertEqual(workflow.activePermissionRequest, .screenRecording)
    }

    func testRequestNextMissingSetupRequirementDoesNotChainWhileScreenRecordingNeedsRestart() async {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions)

        workflow.requestNextMissingSetupRequirement(in: [.screenRecording, .accessibility])
        workflow.requestNextMissingSetupRequirement(in: [.screenRecording, .accessibility])
        workflow.requestPermission(.accessibility)

        XCTAssertEqual(permissions.requestedRequirements(), [.screenRecording])
        XCTAssertEqual(workflow.activePermissionRequest, .screenRecording)

        permissions.updateStatus(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        await workflow.refreshPermissionsIncludingScreenRecordingProbe()

        await waitUntil {
            workflow.activePermissionRequest == nil
                && workflow.screenRecordingSetupNeedsAttention
                && !workflow.permissionStatus.hasScreenRecording
        }

        workflow.requestNextMissingSetupRequirement(in: [.screenRecording, .accessibility])

        XCTAssertEqual(permissions.requestedRequirements(), [.screenRecording])
        XCTAssertNil(workflow.activePermissionRequest)
        XCTAssertTrue(workflow.screenRecordingSetupNeedsAttention)
    }

    func testActivePermissionRequestPollsUntilRestartRequiredAfterSameRunGrantSignal() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false),
            screenRecordingVerifier: { true }
        )
        let workflow = makeWorkflow(permissions: permissions, scheduler: SlowScheduler())

        workflow.requestPermission(.screenRecording)

        XCTAssertEqual(workflow.activePermissionRequest, .screenRecording)

        await waitUntil {
            workflow.activePermissionRequest == nil
                && workflow.screenRecordingSetupNeedsAttention
                && !workflow.permissionStatus.hasScreenRecording
        }
    }

    func testScreenRecordingProbeReconcilesMissingStatusWithoutActiveRequest() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true),
            screenRecordingVerifier: { true }
        )
        let workflow = makeWorkflow(permissions: permissions)

        await workflow.refreshPermissionsIncludingScreenRecordingProbe()

        XCTAssertNil(workflow.activePermissionRequest)
        XCTAssertNil(workflow.permissionSetupGuide)
        XCTAssertEqual(workflow.permissionStatus, CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true))
    }

    func testVerifiedScreenRecordingGrantSurvivesStalePassiveRefresh() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true),
            screenRecordingVerifier: { true }
        )
        let workflow = makeWorkflow(permissions: permissions)

        await workflow.refreshPermissionsIncludingScreenRecordingProbe()
        workflow.refreshPermissions()

        XCTAssertEqual(workflow.permissionStatus, CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true))
    }

    func testScreenRecordingProbeDoesNotPublishStaleMissingBeforeVerifierCompletes() async {
        let verifier = DeferredBoolVerifier()
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true),
            screenRecordingVerifier: { await verifier.value() }
        )
        let workflow = PermissionWorkflowModel(
            dependencies: PermissionWorkflowDependencies(
                capabilities: testCapabilities,
                permissions: permissions,
                scheduler: ImmediateScheduler(),
                lifecycle: TestWorkflowLifecyclePresenter()
            ),
            permissionStatus: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true)
        )

        let refreshTask = Task { @MainActor in
            await workflow.refreshPermissionsIncludingScreenRecordingProbe()
        }

        await verifier.waitForRequest()
        XCTAssertEqual(workflow.permissionStatus, CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true))

        await verifier.resume(returning: true)
        await refreshTask.value

        XCTAssertEqual(workflow.permissionStatus, CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true))
    }

    func testContextualSetupRequirementsSkipAccessibilityWhenScreenRecordingNeedsRestart() async {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions)

        workflow.requestNextMissingSetupRequirement(in: [.screenRecording])

        XCTAssertEqual(permissions.requestedRequirements(), [.screenRecording])

        await workflow.refreshPermissionsIncludingScreenRecordingProbe()

        await waitUntil {
            workflow.screenRecordingSetupNeedsAttention
                && !workflow.permissionStatus.hasScreenRecording
        }

        workflow.requestNextMissingSetupRequirement(in: [.screenRecording])

        XCTAssertEqual(permissions.requestedRequirements(), [.screenRecording])
        XCTAssertNil(workflow.activePermissionRequest)
        XCTAssertTrue(workflow.screenRecordingSetupNeedsAttention)
    }

    func testDismissingNonScreenRecordingPermissionSetupGuideAllowsAnotherPermissionRequest() async {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions)

        workflow.requestPermission(.accessibility)
        workflow.dismissPermissionSetupGuide()
        workflow.requestPermission(.screenRecording)

        XCTAssertEqual(permissions.requestedRequirements(), [.accessibility, .screenRecording])
        XCTAssertEqual(workflow.activePermissionRequest, .screenRecording)
    }

    func testDismissingScreenRecordingSetupGuideShowsRestartRequiredAfterSameRunGrantSignal() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false),
            screenRecordingVerifier: { true }
        )
        let workflow = makeWorkflow(permissions: permissions, scheduler: SlowScheduler())

        workflow.requestPermission(.screenRecording)
        workflow.dismissPermissionSetupGuide()

        await waitUntil {
            workflow.activePermissionRequest == nil
                && workflow.screenRecordingSetupNeedsAttention
                && !workflow.permissionStatus.hasScreenRecording
        }
    }

    func testCheckAgainShowsRestartRequiredWhenVerifierReportsSameRunGrantSignal() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false),
            screenRecordingVerifier: { true }
        )
        let workflow = makeWorkflow(permissions: permissions, scheduler: SlowScheduler())

        workflow.requestPermission(.screenRecording)
        workflow.checkPermissionSetupGuideStatus()

        await waitUntil {
            workflow.activePermissionRequest == nil
                && workflow.screenRecordingSetupNeedsAttention
                && !workflow.permissionStatus.hasScreenRecording
        }
    }

    func testCheckAgainShowsScreenRecordingFollowUpWhenGrantIsStillNotDetected() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false),
            screenRecordingVerifier: { false }
        )
        let workflow = makeWorkflow(permissions: permissions, scheduler: SlowScheduler())

        workflow.requestPermission(.screenRecording)
        workflow.checkPermissionSetupGuideStatus()

        await waitUntil {
            workflow.activePermissionRequest == nil
                && workflow.screenRecordingSetupNeedsAttention
        }

        XCTAssertFalse(workflow.permissionStatus.hasScreenRecording)
    }

    func testCheckAgainShowsRestartRequiredWhenPreflightAllowsButVerifierStillFails() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false),
            screenRecordingVerifier: { false }
        )
        let workflow = makeWorkflow(permissions: permissions, scheduler: SlowScheduler())

        workflow.requestPermission(.screenRecording)
        permissions.updateStatus(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        workflow.checkPermissionSetupGuideStatus()

        await waitUntil {
            workflow.activePermissionRequest == nil
                && workflow.screenRecordingSetupNeedsAttention
                && !workflow.permissionStatus.hasScreenRecording
        }
    }

    func testCheckAgainShowsRestartRequiredWhenPreflightAllowsAfterSameRunSetup() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false),
            screenRecordingVerifier: { true }
        )
        let workflow = makeWorkflow(permissions: permissions, scheduler: SlowScheduler())

        workflow.requestPermission(.screenRecording)
        permissions.updateStatus(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        workflow.checkPermissionSetupGuideStatus()

        await waitUntil {
            workflow.activePermissionRequest == nil
                && workflow.screenRecordingSetupNeedsAttention
                && !workflow.permissionStatus.hasScreenRecording
        }
    }

    func testOpenSettingsResumesScreenRecordingSetupFollowUp() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false),
            screenRecordingVerifier: { false }
        )
        let workflow = makeWorkflow(permissions: permissions, scheduler: SlowScheduler())

        workflow.requestPermission(.screenRecording)
        workflow.checkPermissionSetupGuideStatus()

        await waitUntil {
            workflow.screenRecordingSetupNeedsAttention
        }

        workflow.openPermissionSettings(.screenRecording)

        XCTAssertEqual(permissions.openedSettingsRequirements(), [.screenRecording])
        XCTAssertEqual(workflow.activePermissionRequest, .screenRecording)
        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
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

    func testCaptureDeniedAfterSameRunSetupShowsRestartRequiredEvenWhenPreflightIsFalse() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true),
            screenRecordingVerifier: { false }
        )
        let workflow = PermissionWorkflowModel(
            dependencies: PermissionWorkflowDependencies(
                capabilities: testCapabilities,
                permissions: permissions,
                scheduler: ImmediateScheduler(),
                lifecycle: TestWorkflowLifecyclePresenter()
            ),
            permissionStatus: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true)
        )

        workflow.noteScreenRecordingSetupStarted()
        workflow.reconcileScreenRecordingPermissionDenied(after: ScreenCaptureError.permissionDenied)

        XCTAssertTrue(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertFalse(workflow.permissionStatus.hasScreenRecording)
    }

    func testPendingCaptureWaitsForRestartAfterSameRunScreenRecordingGrant() async {
        let suiteName = "PermissionWorkflowModelTests.pendingCaptureWaitsForRestart"
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
            model.permissions.screenRecordingSetupNeedsAttention
                && !model.permissions.permissionStatus.hasScreenRecording
        }

        XCTAssertNotNil(model.capture.pendingPermissionCommand)
        XCTAssertNil(model.documents.editorController)
        XCTAssertNil(model.capture.lastCaptureRequest)
        XCTAssertEqual(captureService.fullscreenCaptureCount, 0)
    }

    private func makeWorkflow(
        permissions: MutablePermissionService,
        scheduler: Scheduling = ImmediateScheduler()
    ) -> PermissionWorkflowModel {
        PermissionWorkflowModel(
            dependencies: PermissionWorkflowDependencies(
                capabilities: testCapabilities,
                permissions: permissions,
                scheduler: scheduler,
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

private struct SlowScheduler: Scheduling {
    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: 10_000_000_000)
    }
}

private actor DeferredBoolVerifier {
    private var valueContinuation: CheckedContinuation<Bool, Never>?
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var hasRequest = false

    func value() async -> Bool {
        hasRequest = true
        requestContinuation?.resume()
        requestContinuation = nil

        return await withCheckedContinuation { continuation in
            valueContinuation = continuation
        }
    }

    func waitForRequest() async {
        if hasRequest {
            return
        }

        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func resume(returning value: Bool) {
        valueContinuation?.resume(returning: value)
        valueContinuation = nil
    }
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
