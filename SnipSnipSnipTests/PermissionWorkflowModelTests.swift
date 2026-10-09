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
        permissions.updateStatus(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))

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

    func testPassiveRefreshDoesNotProbeMissingScreenRecordingPermission() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true),
            screenRecordingVerifier: { true }
        )
        let workflow = makeWorkflow(permissions: permissions)

        workflow.refreshPermissions()

        XCTAssertEqual(permissions.screenRecordingVerifierCallCount(), 0)
        XCTAssertTrue(permissions.requestedRequirements().isEmpty)
        XCTAssertTrue(permissions.openedSettingsRequirements().isEmpty)
        XCTAssertEqual(workflow.permissionStatus, CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true))
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

    func testCancellingScreenRecordingSetupStopsRequestsWithoutProbingOrClaimingRestart() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false),
            screenRecordingVerifier: { false }
        )
        let workflow = makeWorkflow(permissions: permissions)
        workflow.requestPermission(.screenRecording)
        workflow.dismissPermissionSetupGuide()
        XCTAssertNil(workflow.activePermissionRequest)
        XCTAssertNil(workflow.permissionSetupGuide)
        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertEqual(permissions.screenRecordingVerifierCallCount(), 0)
        workflow.requestPermission(.accessibility)
        XCTAssertEqual(permissions.requestedRequirements(), [.screenRecording, .accessibility])
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

    func testCheckAgainWithoutGrantKeepsSettingsRecoveryAndDoesNotRecommendRestart() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false),
            screenRecordingVerifier: { false }
        )
        let workflow = makeWorkflow(permissions: permissions)
        workflow.requestPermission(.screenRecording)
        workflow.checkPermissionSetupGuideStatus()
        await waitUntil { !workflow.isCheckingPermission }
        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertFalse(workflow.permissionStatus.hasScreenRecording)
        XCTAssertEqual(workflow.activePermissionRequest, .screenRecording)
        XCTAssertNotNil(workflow.permissionSetupGuide)
        XCTAssertTrue(permissions.openedSettingsRequirements().isEmpty)
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

    func testManagingAllowedScreenRecordingNeverStartsSetupOrRequiresRestart() async {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions)
        workflow.openPermissionSettings(.screenRecording)
        XCTAssertTrue(workflow.permissionStatus.hasScreenRecording)
        XCTAssertFalse(workflow.screenRecordingSetupStartedThisRun)
        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertNil(workflow.activePermissionRequest)
        XCTAssertNil(workflow.permissionSetupGuide)
        XCTAssertEqual(permissions.openedSettingsRequirements(), [.screenRecording])
        XCTAssertTrue(permissions.requestedRequirements().isEmpty)
    }

    func testOpenSettingsForMissingAccessStartsRecoverableSetup() {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions)
        workflow.openPermissionSettings(.screenRecording)
        XCTAssertEqual(workflow.activePermissionRequest, .screenRecording)
        XCTAssertNotNil(workflow.permissionSetupGuide)
        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertEqual(permissions.openedSettingsRequirements(), [.screenRecording])
    }

    func testRevocationClearsCachedGrantWithoutRequestingOrProbingAccess() async {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions)
        permissions.updateStatus(CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false))
        workflow.refreshPermissions()
        XCTAssertFalse(workflow.permissionStatus.hasScreenRecording)
        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertEqual(permissions.screenRecordingVerifierCallCount(), 0)
        XCTAssertTrue(permissions.requestedRequirements().isEmpty)
    }

    func testSetupDoesNotOpenSettingsAutomaticallyOrProbeDeniedAccessWhilePolling() async {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions)
        workflow.requestPermission(.screenRecording)
        try? await Task.sleep(for: .milliseconds(1_100))
        XCTAssertTrue(permissions.openedSettingsRequirements().isEmpty)
        XCTAssertEqual(permissions.screenRecordingVerifierCallCount(), 0)
        workflow.dismissPermissionSetupGuide()
    }

    func testPassiveRefreshNeverProbesEvenWhenAccessIsAllowed() async {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions)
        for _ in 0..<10 { workflow.refreshPermissions() }
        await Task.yield()
        XCTAssertEqual(permissions.screenRecordingVerifierCallCount(), 0)
    }

    func testExplicitProbeReconcilesStaleScreenRecordingGrant() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false),
            screenRecordingVerifier: { false }
        )
        let workflow = makeWorkflow(permissions: permissions)

        await workflow.refreshPermissionsIncludingScreenRecordingProbe()

        await waitUntil {
            workflow.permissionStatus == CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false)
        }
    }

    func testCaptureDeniedWithoutAGrantDoesNotClaimRestartWillFixIt() async {
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

        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertFalse(workflow.permissionStatus.hasScreenRecording)
    }

    func testPendingCaptureWaitsForRestartAfterSameRunScreenRecordingGrant() async {
        let suiteName = "PermissionWorkflowModelTests.pendingCaptureWaitsForRestart"
        let defaults = makeDefaults(named: suiteName)
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

    func testAccessibilityGrantKeepsAContinuationUntilUserContinues() {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions)
        var resumes = 0
        _ = workflow.preflight([.accessibility], featureName: "Scrolling Capture")
        workflow.deferOperation(requiring: [.accessibility], featureName: "Scrolling Capture") { resumes += 1 }
        permissions.updateStatus(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true))
        workflow.refreshPermissions()
        XCTAssertEqual(resumes, 0)
        XCTAssertTrue(workflow.canContinueOperation)
        XCTAssertEqual(workflow.permissionSetupGuide?.requirement, .accessibility)
        workflow.continueOperation()
        workflow.continueOperation()
        XCTAssertEqual(resumes, 1)
        XCTAssertNil(workflow.permissionSetupGuide)
    }

    func testCancelDiscardsDeferredOperation() {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions)
        var resumes = 0
        workflow.deferOperation(requiring: [.accessibility], featureName: "Guide") { resumes += 1 }
        workflow.dismissPermissionSetupGuide()
        permissions.updateStatus(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true))
        workflow.refreshPermissions()
        workflow.continueOperation()
        XCTAssertEqual(resumes, 0)
        XCTAssertNil(workflow.permissionContinuation)
        XCTAssertNil(workflow.permissionSetupGuide)
    }

    func testCancelledExplicitProbeCannotRestoreAccessOrRequireRestart() async {
        let verifier = DeferredBoolVerifier()
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false),
            screenRecordingVerifier: { await verifier.value() }
        )
        let workflow = makeWorkflow(permissions: permissions)
        workflow.requestPermission(.screenRecording)
        workflow.checkPermissionSetupGuideStatus()
        await verifier.waitForRequest()
        workflow.dismissPermissionSetupGuide()
        await verifier.resume(returning: true)
        await Task.yield()
        XCTAssertFalse(workflow.permissionStatus.hasScreenRecording)
        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertNil(workflow.permissionSetupGuide)
    }

    func testUIMapFallbackKeepsPreferencesAndQueuesVisualOnlyWindowCapture() {
        let name = "PermissionWorkflowModelTests.uiMapFallback.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false))
        let model = AppModel(defaults: defaults,
            environment: AppEnvironment(defaults: defaults, permissions: permissions),
            recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
            captureService: PermissionRetryCaptureService(), shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        model.capture.updateUIMapEnabled(true, requestAccessIfNeeded: false)
        model.capture.runActionWhenPermissionsReady([.screenRecording, .accessibility], featureName: "Window Capture with UI Map", pendingCommand: .windowPicker) {
            XCTFail("Capture must wait for Screen Recording")
        }
        XCTAssertNotNil(model.permissions.permissionContinuation?.alternative)
        model.permissions.permissionContinuation?.alternative?()
        XCTAssertEqual(model.capture.pendingPermissionCommand?.requirements, [.screenRecording])
        XCTAssertEqual(model.capture.pendingPermissionCommand?.oneShotOptions?.windowUIMapEnabled, false)
        XCTAssertTrue(model.capture.uiMapEnabled)
        model.permissions.dismissPermissionSetupGuide()
    }

    func testReturningFromSettingsDoesNotProbeOrAutomaticallyCapture() async {
        let name = "PermissionWorkflowModelTests.foreground.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        let captureService = PermissionRetryCaptureService()
        let model = AppModel(defaults: defaults,
            environment: AppEnvironment(defaults: defaults, permissions: permissions),
            recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
            captureService: captureService, shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        model.capture.runActionWhenPermissionsReady([.accessibility], featureName: "Capture", pendingCommand: .currentDisplay) {
            XCTFail("Access has not been granted yet")
        }
        permissions.updateStatus(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true))
        model.workflowCoordinator.handleApplicationDidBecomeActive()
        await Task.yield()
        XCTAssertEqual(captureService.fullscreenCaptureCount, 0)
        XCTAssertEqual(permissions.screenRecordingVerifierCallCount(), 0)
        XCTAssertTrue(model.permissions.canContinueOperation)
        model.permissions.dismissPermissionSetupGuide()
    }

    func testGrantedAccessDoesNotRequireTheAbilityToRequestAgain() {
        let service = TestCapturePermissionService(
            statusProvider: { CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true) },
            requestHandler: { _ in XCTFail("Already-granted access must not be requested again"); return false },
            canRequestHandler: { _ in false }
        )
        let workflow = PermissionWorkflowModel(dependencies: PermissionWorkflowDependencies(
            capabilities: testCapabilities, permissions: service,
            scheduler: ImmediateScheduler(), lifecycle: TestWorkflowLifecyclePresenter()))
        XCTAssertTrue(workflow.preflight([.screenRecording, .accessibility], featureName: "Guide").isGranted)
    }

    func testViewingHelpDoesNotInvalidateAnExternalGrant() {
        let service = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true))
        let workflow = makeWorkflow(permissions: service)
        workflow.presentPermissionSetupGuide(for: .screenRecording)
        XCTAssertFalse(workflow.screenRecordingSetupStartedThisRun)
        service.updateStatus(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true))
        workflow.refreshPermissions()
        XCTAssertTrue(workflow.permissionStatus.hasScreenRecording)
        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertNil(workflow.permissionSetupGuide)
        XCTAssertEqual(service.screenRecordingVerifierCallCount(), 0)
    }

    func testRevocationDuringExplicitProbeCannotPublishAStaleGrant() async {
        let barrier = DeferredBoolVerifier()
        let service = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true),
            screenRecordingVerifier: { await barrier.value() }
        )
        let workflow = makeWorkflow(permissions: service)
        let check = Task { await workflow.refreshPermissionsIncludingScreenRecordingProbe() }
        await barrier.waitForRequest()
        service.updateStatus(CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true))
        await barrier.resume(returning: true)
        await check.value
        XCTAssertFalse(workflow.permissionStatus.hasScreenRecording)
        XCTAssertFalse(workflow.hasVerifiedScreenRecordingAccess)
        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertTrue(service.requestedRequirements().isEmpty)
    }

    func testVideoWindowDiscoveryFailureReleasesPreparationAndKeepsVideoRecovery() async throws {
        let name = "PermissionSecondPassTests.windowDiscovery.\(UUID())"
        let defaults = makeDefaults(named: name)
        let service = PermissionRetryCaptureService(windowListHandler: { _ in throw ScreenCaptureError.permissionDenied })
        let model = AppModel(defaults: defaults,
            environment: AppEnvironment(defaults: defaults, permissions: TestCapturePermissionService()),
            recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
            captureService: service, screenRecordingService: ScreenRecordingService(),
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        defer {
            model.video.cancelPendingVideoRecording()
            model.video.dismissVideoStartRecovery()
            model.capture.dismissCaptureRecovery()
            defaults.removePersistentDomain(forName: name)
        }
        model.video.presentVideoWindowPicker()
        await waitUntil { service.windowListCount > 0 && !model.capture.isLoadingWindowChoices }
        XCTAssertFalse(model.video.blocksNewCapture)
        XCTAssertNil(model.video.pendingWindowPickerGeneration)
        XCTAssertNotNil(model.video.recordingStartRecovery)
        XCTAssertNil(model.capture.captureRecovery, "Video must not route discovery failures into screenshot retry")
    }

    func testVideoWindowSelectionHandlesPermissionRevokedAfterAudioPreflight() async {
        let name = "PermissionSecondPassTests.revokedBeforeWindowPicker.\(UUID())"
        let defaults = makeDefaults(named: name)
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true))
        let captureService = PermissionRetryCaptureService()
        let platform = TestScreenRecordingPlatform(microphoneAccess: {
            permissions.updateStatus(CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true))
        })
        let model = AppModel(defaults: defaults,
            environment: AppEnvironment(defaults: defaults, permissions: permissions),
            recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
            captureService: captureService,
            screenRecordingService: ScreenRecordingService(permissions: permissions, platform: platform),
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        defer {
            model.video.cancelPendingVideoRecording()
            model.video.dismissVideoStartRecovery()
            model.permissions.dismissPermissionSetupGuide()
            defaults.removePersistentDomain(forName: name)
        }
        model.video.recordingPreferences.recordsMicrophone = true
        model.video.presentVideoWindowPicker()
        await waitUntil { !model.permissions.permissionStatus.hasScreenRecording }
        await Task.yield()
        XCTAssertFalse(model.video.blocksNewCapture)
        XCTAssertNotNil(model.video.recordingStartRecovery)
        XCTAssertEqual(captureService.windowListCount, 0)
        XCTAssertTrue(permissions.requestedRequirements().isEmpty, "Discovery should report the loss, not trigger another prompt")
    }

    func testCancelledVideoWindowDiscoveryCannotReopenPicker() async {
        let name = "PermissionSecondPassTests.cancelWindowDiscovery.\(UUID())"
        let defaults = makeDefaults(named: name)
        let barrier = DeferredBoolVerifier()
        let service = PermissionRetryCaptureService(windowListHandler: { _ in
            _ = await barrier.value()
            return []
        })
        let model = AppModel(defaults: defaults,
            environment: AppEnvironment(defaults: defaults, permissions: TestCapturePermissionService()),
            recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
            captureService: service, screenRecordingService: ScreenRecordingService(),
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        defer {
            model.capture.cancelScreenshotWindowPicker()
            defaults.removePersistentDomain(forName: name)
        }
        model.video.presentVideoWindowPicker()
        await barrier.waitForRequest()
        let originalTask = model.video.recordingStartTask
        model.video.cancelPendingVideoRecording()
        XCTAssertFalse(model.capture.isWorking)
        XCTAssertFalse(model.capture.isLoadingWindowChoices)
        await barrier.resume(returning: true)
        await originalTask?.value
        XCTAssertFalse(model.capture.isShowingWindowPicker)
        XCTAssertFalse(model.video.blocksNewCapture)
        XCTAssertNil(model.video.recordingStartRecovery)
    }

    func testLateCancelledDiscoveryCannotOverwriteANewerVideoPicker() async {
        let name = "PermissionSecondPassTests.replacedWindowDiscovery.\(UUID())"
        let defaults = makeDefaults(named: name)
        let barrier = DeferredBoolVerifier()
        let oldWindow = makeCaptureWindow(id: 401)
        let newWindow = makeCaptureWindow(id: 402)
        let service = PermissionRetryCaptureService(windowListHandler: { request in
            if request == 1 {
                _ = await barrier.value()
                return [oldWindow]
            }
            return [newWindow]
        })
        let model = AppModel(defaults: defaults,
            environment: AppEnvironment(defaults: defaults, permissions: TestCapturePermissionService()),
            recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
            captureService: service, screenRecordingService: ScreenRecordingService(),
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        defer {
            model.video.cancelPendingVideoRecording()
            defaults.removePersistentDomain(forName: name)
        }
        model.video.presentVideoWindowPicker()
        await barrier.waitForRequest()
        let oldTask = model.video.recordingStartTask
        model.video.cancelPendingVideoRecording()
        model.video.presentVideoWindowPicker()
        await waitUntil { model.capture.isShowingWindowPicker }
        XCTAssertEqual(model.capture.availableWindows.map(\.id), [newWindow.id])
        let newGeneration = model.video.recordingLifecycle.generation
        await barrier.resume(returning: true)
        await oldTask?.value
        XCTAssertTrue(model.capture.isShowingWindowPicker)
        XCTAssertEqual(model.capture.availableWindows.map(\.id), [newWindow.id])
        XCTAssertEqual(model.video.recordingLifecycle.generation, newGeneration)
        XCTAssertNil(model.video.recordingStartRecovery)
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

final class TestWorkflowLifecyclePresenter: WorkflowLifecyclePresenting {
    var presentedErrors: [String] = []
    var didRequestMainWindowPresentation = false
    var workingMessages: [String] = []

    func presentError(_ message: String) {
        presentedErrors.append(message)
    }

    func clearError() {
        presentedErrors = []
    }

    func updateWorkingMessage(_ message: String) {
        workingMessages.append(message)
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

actor DeferredBoolVerifier {
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
    private var verifierCallCount = 0

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
        lock.withLock {
            verifierCallCount += 1
        }
        return await verifier()
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

    func screenRecordingVerifierCallCount() -> Int {
        lock.withLock { verifierCallCount }
    }
}

private final class PermissionRetryCaptureService: ScreenCaptureServiceType, @unchecked Sendable {
    private let lock = NSLock()
    private var fullscreenCaptures = 0
    private var windowLists = 0
    private let windowListHandler: @Sendable (Int) async throws -> [CaptureWindowSummary]

    init(windowListHandler: @escaping @Sendable (Int) async throws -> [CaptureWindowSummary] = { _ in [] }) {
        self.windowListHandler = windowListHandler
    }

    var windowListCount: Int { lock.withLock { windowLists } }

    var fullscreenCaptureCount: Int {
        lock.withLock { fullscreenCaptures }
    }

    func listWindows(excluding processID: pid_t, includeThumbnails: Bool) async throws -> [CaptureWindowSummary] {
        let request = lock.withLock { windowLists += 1; return windowLists }
        return try await windowListHandler(request)
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
