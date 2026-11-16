import AppKit
import SwiftUI
import XCTest
@testable import SnipSnipSnip

@MainActor
final class PermissionWorkflowModelTests: XCTestCase {
    func testUIMapSetupIsExplicitAndPreservesUsableScreenRecording() async throws {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions, scheduler: SlowScheduler())
        let view = NSHostingView(rootView: UIMapAccessView(permissions: workflow, capabilities: testCapabilities)
            .padding(18).frame(width: 430, height: 450, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.sizingOptions = []
        let window = HostedViewTestSupport.host(view, size: CGSize(width: 430, height: 450))
        defer { workflow.dismissPermissionSetupGuide(); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(permissions.requestedRequirements().isEmpty, "Showing setup must not request access")
        let setup = try XCTUnwrap(HostedViewTestSupport.find("permissions.accessibility.action", in: view))
        XCTAssertTrue(setup.accessibilityPerformPress())
        XCTAssertEqual(permissions.requestedRequirements(), [.accessibility])
        XCTAssertTrue(workflow.permissionStatus.hasScreenRecording)
        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertEqual(permissions.screenRecordingVerifierCallCount(), 0)
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let settings = try XCTUnwrap(HostedViewTestSupport.find("permissions.setup.openSettings", in: view))
        XCTAssertTrue(window.frame.contains(settings.accessibilityFrame()))
        XCTAssertTrue(settings.accessibilityPerformPress())
        XCTAssertEqual(permissions.openedSettingsRequirements(), [.accessibility])
        permissions.updateStatus(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true))
        workflow.refreshPermissions()
        XCTAssertNil(workflow.permissionSetupGuide)
        XCTAssertTrue(workflow.permissionStatus.hasScreenRecording)
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let manage = try XCTUnwrap(HostedViewTestSupport.find("permissions.accessibility.action", in: view))
        XCTAssertTrue(manage.accessibilityPerformPress())
        XCTAssertEqual(permissions.openedSettingsRequirements(), [.accessibility, .accessibility])
        XCTAssertEqual(permissions.requestedRequirements(), [.accessibility])
        add(try HostedViewTestSupport.attachment(of: view, name: "UI Map access — Allowed"))
    }

    func testAppStoreUIMapSetupIsAbsentAndDoesNotRequestAccess() async throws {
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        let workflow = makeWorkflow(permissions: permissions)
        let view = NSHostingView(rootView: UIMapAccessView(permissions: workflow,
            capabilities: BuildTargetCapabilityProvider().snapshot(for: .release)))
        let window = HostedViewTestSupport.host(view, size: CGSize(width: 430, height: 200))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(HostedViewTestSupport.find("permissions.uiMap", in: view))
        XCTAssertNil(HostedViewTestSupport.find("permissions.accessibility.action", in: view))
        XCTAssertTrue(permissions.requestedRequirements().isEmpty)
    }

    func testOnboardingUIMapChoiceEnablesCaptureOnlyAfterAnExplicitAction() async throws {
        let name = "PermissionWorkflowModelTests.onboardingUIMap.\(UUID())"
        let defaults = makeDefaults(named: name)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        let model = AppModel(defaults: defaults,
            environment: AppEnvironment(defaults: defaults, permissions: permissions),
            recoveryStore: DocumentRecoveryStore(baseURL: root), captureService: PermissionRetryCaptureService(),
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        model.lifecycle.saveOnboardingResumeCheckpoint(.clipboard)
        model.lifecycle.acknowledgeOnboardingClipboardChoice()
        let view = NSHostingView(rootView: OnboardingView(lifecycle: model.lifecycle, permissions: model.permissions,
            clipboard: model.clipboard, quickControls: model.quickControls, capture: model.capture,
            capabilities: model.capabilities, completeOnboarding: {})
            .frame(width: 720, height: 460).background(Color(nsColor: .windowBackgroundColor)))
        view.sizingOptions = []
        let window = HostedViewTestSupport.host(view, size: CGSize(width: 720, height: 460))
        defer { model.permissions.dismissPermissionSetupGuide(); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(model.capture.uiMapEnabled)
        XCTAssertTrue(permissions.requestedRequirements().isEmpty)
        let next = try XCTUnwrap(HostedViewTestSupport.find("onboarding.primary", in: view))
        XCTAssertTrue(next.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let toggle = try XCTUnwrap(HostedViewTestSupport.find("onboarding.uiMap.enabled", in: view))
        XCTAssertTrue(window.frame.contains(toggle.accessibilityFrame()))
        _ = toggle.accessibilityPerformPress()
        XCTAssertTrue(model.capture.uiMapEnabled)
        XCTAssertEqual(permissions.requestedRequirements(), [.accessibility])
        XCTAssertTrue(model.permissions.permissionStatus.hasScreenRecording)
        XCTAssertTrue(OnboardingCompletionPolicy.canComplete(mode: .firstRun,
            hasScreenRecording: model.permissions.permissionStatus.hasScreenRecording, hasMadeClipboardChoice: true))
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(model.capture.uiMapEnabled)
        let currentToggle = try XCTUnwrap(HostedViewTestSupport.find("onboarding.uiMap.enabled", in: view))
        XCTAssertEqual((currentToggle.accessibilityValue() as? NSNumber)?.boolValue, true)
        add(try HostedViewTestSupport.attachment(of: view, name: "Onboarding UI Map — Needs Access"))
    }

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

    func testSuccessfulProbeCannotOverrideTheServicesPassiveGate() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true),
            screenRecordingVerifier: { true }
        )
        let workflow = makeWorkflow(permissions: permissions)

        await workflow.refreshPermissionsIncludingScreenRecordingProbe()

        XCTAssertNil(workflow.activePermissionRequest)
        XCTAssertNil(workflow.permissionSetupGuide)
        XCTAssertEqual(workflow.permissionStatus, CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true))
        do {
            _ = try await ScreenCaptureService(permissions: permissions).listWindows(includeThumbnails: false)
            XCTFail("Capture must use the same denied gate as the workflow")
        } catch ScreenCaptureError.permissionDenied {
        } catch { XCTFail("Unexpected capture error: \(error)") }
        do {
            _ = try await ScreenRecordingService(permissions: permissions).startFullscreenRecording(preferences: VideoRecordingPreferences())
            XCTFail("Recording must use the same denied gate as the workflow")
        } catch ScreenRecordingError.permissionDenied {
        } catch { XCTFail("Unexpected recording error: \(error)") }

    }

    func testSuccessfulProbeWithMissingPassiveAccessStaysUnavailableOnRefresh() async {
        let permissions = MutablePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true),
            screenRecordingVerifier: { true }
        )
        let workflow = makeWorkflow(permissions: permissions)

        await workflow.refreshPermissionsIncludingScreenRecordingProbe()
        workflow.refreshPermissions()

        XCTAssertEqual(workflow.permissionStatus, CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true))
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

    func testPassiveDenialIsPublishedWhileVerificationIsInFlight() async {
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
        XCTAssertEqual(workflow.permissionStatus, CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true))

        await verifier.resume(returning: true)
        await refreshTask.value

        XCTAssertEqual(workflow.permissionStatus, CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true))
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

    func testVideoSourcesHandlePermissionRevokedAfterAudioPreflight() async {
        for source in [PermissionRestartVideoSource.window, .screen, .region] {
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
        switch source {
        case .window: model.video.presentVideoWindowPicker()
        case .screen: model.video.recordCurrentDisplay()
        case .region: model.video.recordRegion()
        }
        await waitUntil { !model.permissions.permissionStatus.hasScreenRecording }
        await Task.yield()
        XCTAssertFalse(model.video.blocksNewCapture)
        XCTAssertNotNil(model.video.recordingStartRecovery)
        XCTAssertEqual(captureService.windowListCount, 0)
        XCTAssertTrue(permissions.requestedRequirements().isEmpty, "Discovery should report the loss, not trigger another prompt")
        }
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

    func testVideoPickerOwnsDiscoveryFailureWhileBackgroundRefreshFailsLate() async {
        let name = "PermissionSecondPassTests.backgroundAndVideoDiscoveryFailure.\(UUID())"
        let defaults = makeDefaults(named: name)
        let backgroundBarrier = DeferredBoolVerifier()
        let videoBarrier = DeferredBoolVerifier()
        let service = PermissionRetryCaptureService(windowListHandler: { request in
            if request == 1 {
                _ = await backgroundBarrier.value()
                throw ScreenCaptureError.noWindowsAvailable
            }
            _ = await videoBarrier.value()
            throw ScreenCaptureError.permissionDenied
        })
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
        let backgroundTask = Task {
            await model.capture.loadAvailableWindows(requestAccessIfNeeded: false, presentPicker: false,
                showErrors: false, includeThumbnails: false)
        }
        await backgroundBarrier.waitForRequest()
        model.video.presentVideoWindowPicker()
        await waitUntil { service.windowListCount == 2 }
        guard service.windowListCount == 2 else {
            XCTFail("Video must start its own discovery while a background refresh is pending")
            await backgroundBarrier.resume(returning: true)
            _ = await backgroundTask.value
            return
        }
        await videoBarrier.waitForRequest()
        let videoTask = model.video.recordingStartTask
        let videoLoadID = model.capture.windowChoiceLoadID

        await backgroundBarrier.resume(returning: true)
        _ = await backgroundTask.value
        XCTAssertEqual(model.capture.windowChoiceLoadID, videoLoadID)
        XCTAssertTrue(model.capture.isLoadingWindowChoices)
        XCTAssertTrue(model.capture.isWorking)
        XCTAssertTrue(model.video.blocksNewCapture)
        XCTAssertNil(model.video.recordingStartRecovery)

        await videoBarrier.resume(returning: true)
        await videoTask?.value
        XCTAssertFalse(model.capture.isLoadingWindowChoices)
        XCTAssertFalse(model.capture.isWorking)
        XCTAssertFalse(model.capture.isShowingWindowPicker)
        XCTAssertFalse(model.video.blocksNewCapture)
        XCTAssertNil(model.video.pendingWindowPickerGeneration)
        XCTAssertNotNil(model.video.recordingStartRecovery)
        XCTAssertNil(model.capture.captureRecovery)
    }

    func testLateBackgroundDiscoveryCannotOverwriteVideoPickerWindows() async {
        let name = "PermissionSecondPassTests.backgroundDiscoveryReplacedByVideo.\(UUID())"
        let defaults = makeDefaults(named: name)
        let barrier = DeferredBoolVerifier()
        let oldWindow = makeCaptureWindow(id: 501)
        let newWindow = makeCaptureWindow(id: 502)
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
        let backgroundTask = Task {
            await model.capture.loadAvailableWindows(requestAccessIfNeeded: false, presentPicker: false,
                showErrors: false, includeThumbnails: false)
        }
        await barrier.waitForRequest()
        model.video.presentVideoWindowPicker()
        await waitUntil { model.capture.isShowingWindowPicker }
        XCTAssertEqual(model.capture.availableWindows.map(\.id), [newWindow.id])
        let generation = model.video.recordingLifecycle.generation

        await barrier.resume(returning: true)
        _ = await backgroundTask.value
        XCTAssertEqual(model.capture.availableWindows.map(\.id), [newWindow.id])
        XCTAssertEqual(model.video.recordingLifecycle.generation, generation)
        XCTAssertTrue(model.capture.isShowingWindowPicker)
        XCTAssertFalse(model.capture.isLoadingWindowChoices)
        XCTAssertFalse(model.capture.isWorking)
        XCTAssertNil(model.video.recordingStartRecovery)
        XCTAssertNil(model.capture.captureRecovery)
    }

    func testRepeatedExplicitPickerLoadKeepsLatestLoadingStateUntilCompletion() async {
        let name = "PermissionSecondPassTests.repeatedExplicitPicker.\(UUID())"
        let defaults = makeDefaults(named: name)
        let firstBarrier = DeferredBoolVerifier()
        let secondBarrier = DeferredBoolVerifier()
        let newWindow = makeCaptureWindow(id: 602)
        let service = PermissionRetryCaptureService(windowListHandler: { request in
            if request == 1 {
                _ = await firstBarrier.value()
                return []
            }
            _ = await secondBarrier.value()
            return [newWindow]
        })
        let model = AppModel(defaults: defaults,
            environment: AppEnvironment(defaults: defaults, permissions: TestCapturePermissionService()),
            recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
            captureService: service,
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        defer {
            model.capture.cancelScreenshotWindowPicker()
            defaults.removePersistentDomain(forName: name)
        }
        let firstTask = Task {
            await model.capture.loadAvailableWindows(requestAccessIfNeeded: false, presentPicker: true,
                showErrors: true, includeThumbnails: false)
        }
        await firstBarrier.waitForRequest()
        let secondTask = Task {
            await model.capture.loadAvailableWindows(requestAccessIfNeeded: false, presentPicker: true,
                showErrors: true, includeThumbnails: false)
        }
        await waitUntil { service.windowListCount == 2 }
        guard service.windowListCount == 2 else {
            XCTFail("The new explicit picker must start its own discovery")
            await firstBarrier.resume(returning: true)
            _ = await firstTask.value
            _ = await secondTask.value
            return
        }
        await secondBarrier.waitForRequest()
        let newestLoadID = model.capture.windowChoiceLoadID

        await firstBarrier.resume(returning: true)
        _ = await firstTask.value
        XCTAssertEqual(model.capture.windowChoiceLoadID, newestLoadID)
        XCTAssertTrue(model.capture.isLoadingWindowChoices)
        XCTAssertTrue(model.capture.isWorking)
        XCTAssertFalse(model.capture.isShowingWindowPicker)

        await secondBarrier.resume(returning: true)
        _ = await secondTask.value
        XCTAssertNil(model.capture.windowChoiceLoadID)
        XCTAssertFalse(model.capture.isLoadingWindowChoices)
        XCTAssertFalse(model.capture.isWorking)
        XCTAssertTrue(model.capture.isShowingWindowPicker)
        XCTAssertEqual(model.capture.availableWindows.map(\.id), [newWindow.id])
        XCTAssertNil(model.capture.captureRecovery)
    }

    func testDeferredFrontmostCaptureRequiresChoosingAWindowAfterPermissionSetup() async {
        for afterRestart in [false, true] {
            let name = "PermissionSecondPassTests.frontmostTarget.\(UUID())"
            let defaults = makeDefaults(named: name)
            let options = CaptureOneShotOptions(captureDelay: .immediate, includesCursor: false, privateCapture: false, windowUIMapEnabled: false)
            if afterRestart { PermissionRestartStore(defaults: defaults).save(.screenshot(.frontmostWindow, options)) }
            let service = PermissionRetryCaptureService()
            let model = AppModel(defaults: defaults,
                environment: AppEnvironment(defaults: defaults, permissions: TestCapturePermissionService()),
                recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
                captureService: service, shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
            defer {
                model.capture.cancelScreenshotWindowPicker()
                model.capture.dismissCaptureRecovery()
                defaults.removePersistentDomain(forName: name)
            }
            if !afterRestart {
                model.capture.pendingPermissionCommand = PendingCapturePermissionRequest(requirements: [.screenRecording],
                    command: .frontmostWindow, captureIntent: .newDocument, oneShotOptions: options)
                model.permissions.deferOperation(requiring: [.screenRecording], featureName: "Window Capture") { [weak model] in
                    guard let model else { return }
                    model.capture.retryPendingPermissionCommandIfSatisfied(model.permissions.permissionStatus)
                }
            }
            model.permissions.continueOperation()
            await waitUntil { model.capture.isShowingWindowPicker || model.capture.captureRecovery != nil }
            XCTAssertEqual(service.frontmostLookupCount, 0, "Setup may have brought System Settings to the front")
            XCTAssertTrue(model.capture.isShowingWindowPicker)
            XCTAssertNil(model.documents.editorController)
        }
    }

    func testRestoredUIMapWindowCaptureKeepsVisualOnlyAlternativeAndCurrentPrivacy() async throws {
        for command in [PendingCapturePermissionCommand.frontmostWindow, .windowPicker] {
            for hasScreenRecording in [false, true] {
                let name = "PermissionSecondPassTests.restoredUIMapFallback.\(UUID())"
                let defaults = makeDefaults(named: name)
                let options = CaptureOneShotOptions(captureDelay: .immediate, includesCursor: true, privateCapture: false, windowUIMapEnabled: true)
                PermissionRestartStore(defaults: defaults).save(.screenshot(command, options))
                let permissions = MutablePermissionService(status: CapturePermissionStatus(hasScreenRecording: hasScreenRecording, hasAccessibility: false))
                let service = PermissionRetryCaptureService()
                let model = AppModel(defaults: defaults,
                    environment: AppEnvironment(defaults: defaults, buildTarget: .dev, permissions: permissions),
                    recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
                    captureService: service, shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
                defer {
                    model.permissions.dismissPermissionSetupGuide()
                    model.capture.cancelScreenshotWindowPicker()
                    model.capture.dismissCaptureRecovery()
                    defaults.removePersistentDomain(forName: name)
                }
                model.capture.updateUIMapEnabled(true, requestAccessIfNeeded: false)
                model.capture.updatePrivateCaptureEnabled(true)

                let alternative = try XCTUnwrap(model.permissions.permissionContinuation?.alternative)
                alternative()

                let continuedOptions: CaptureOneShotOptions?
                if hasScreenRecording {
                    await waitUntil { model.capture.isShowingWindowPicker || model.capture.captureRecovery != nil }
                    XCTAssertTrue(model.capture.isShowingWindowPicker)
                    XCTAssertNil(model.permissions.permissionContinuation)
                    continuedOptions = model.capture.activeCaptureContext.oneShotOptions
                } else {
                    XCTAssertEqual(model.capture.pendingPermissionCommand?.requirements, [.screenRecording])
                    XCTAssertFalse(model.capture.isShowingWindowPicker)
                    continuedOptions = model.capture.pendingPermissionCommand?.oneShotOptions
                }
                var expectedOptions = options
                expectedOptions.windowUIMapEnabled = false
                expectedOptions.privateCapture = true
                XCTAssertEqual(continuedOptions, expectedOptions)
                XCTAssertTrue(model.capture.uiMapEnabled)
                XCTAssertFalse(permissions.requestedRequirements().contains(.accessibility))
                XCTAssertEqual(service.frontmostLookupCount, 0)
                XCTAssertNil(PermissionRestartStore(defaults: defaults).load(), "Private continuation must not retain a restart checkpoint")
                XCTAssertNil(model.documents.editorController)
            }
        }
    }

    func testTransientProbeFailureDoesNotRevokeAllowedAccessOrDemandRestart() async {
        let service = TestCapturePermissionService()
        var injected = service
        injected.screenRecordingProbe = { .unavailable(domain: "TransientScreenCaptureKit", code: -999) }
        let workflow = PermissionWorkflowModel(dependencies: PermissionWorkflowDependencies(
            capabilities: testCapabilities, permissions: injected,
            scheduler: ImmediateScheduler(), lifecycle: TestWorkflowLifecyclePresenter()))
        await workflow.refreshPermissionsIncludingScreenRecordingProbe()
        XCTAssertTrue(workflow.permissionStatus.hasScreenRecording)
        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertNotNil(workflow.screenRecordingVerificationMessage)
        workflow.refreshPermissions()
        XCTAssertTrue(workflow.permissionStatus.hasScreenRecording)
    }

    func testTransientProbeFailureWhileWaitingDoesNotClaimAccessOrRestart() async {
        var service = TestCapturePermissionService(status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true))
        service.screenRecordingProbe = { .unavailable(domain: "TransientScreenCaptureKit", code: -999) }
        let workflow = PermissionWorkflowModel(dependencies: PermissionWorkflowDependencies(
            capabilities: testCapabilities, permissions: service,
            scheduler: ImmediateScheduler(), lifecycle: TestWorkflowLifecyclePresenter()))
        workflow.requestPermission(.screenRecording)
        await workflow.refreshPermissionsIncludingScreenRecordingProbe()
        XCTAssertFalse(workflow.permissionStatus.hasScreenRecording)
        XCTAssertFalse(workflow.screenRecordingSetupNeedsAttention)
        XCTAssertNotNil(workflow.screenRecordingVerificationMessage)
        XCTAssertNotNil(workflow.permissionSetupGuide)
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
    private var frontmostLookups = 0
    var frontmostLookupCount: Int { lock.withLock { frontmostLookups } }
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
        lock.withLock { frontmostLookups += 1 }
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
