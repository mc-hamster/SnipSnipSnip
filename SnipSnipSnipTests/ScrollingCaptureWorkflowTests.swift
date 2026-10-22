import CoreGraphics
import XCTest
@testable import SnipSnipSnip

@MainActor
final class ScrollingCaptureWorkflowTests: XCTestCase {
    private let region = CGRect(x: 20, y: 30, width: 200, height: 120)
    private let origin = WorkflowPresentationContext.quickControls(displayID: 7)

    func testRepeatProtectsEditingAndRestoresPresentationAfterTargetFailure() async {
        let fixture = ScrollingWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.workflow.prepareCaptureIntent(.newDocument, presentationContext: origin)

        fixture.workflow.repeatScrollingCapture(region)
        await waitUntil { fixture.workflow.captureRecovery != nil }

        XCTAssertEqual(fixture.probe.resolveCount, 1)
        XCTAssertTrue(fixture.probe.wasInteractive)
        XCTAssertTrue(fixture.probe.wasPrivacyLocked)
        XCTAssertEqual(fixture.windows.hiddenContexts, [origin])
        XCTAssertEqual(fixture.windows.restoreCount, 1)
        XCTAssertFalse(fixture.workflow.isWorking)
        XCTAssertFalse(fixture.workflow.isInteractiveCaptureActive)
        XCTAssertFalse(fixture.workflow.isCapturePrivacyLocked)
    }

    func testChooseAnotherAreaReleasesRepeatBeforeStartingSelectionAndPreservesOrigin() async {
        let fixture = ScrollingWorkflowFixture(failsTarget: false, confirmation: .chooseAnotherArea)
        defer { fixture.cleanUp() }
        fixture.workflow.prepareCaptureIntent(.newDocument, presentationContext: origin)

        fixture.workflow.repeatScrollingCapture(region)
        // The replacement selector's fake capture backend has no displays. It
        // fails before constructing a native selection window or asking consent.
        await waitUntil { fixture.workflow.captureRecovery != nil }

        XCTAssertEqual(fixture.probe.serviceCount, 2)
        XCTAssertEqual(fixture.windows.hiddenContexts, [origin, origin])
        XCTAssertEqual(fixture.windows.restoreCount, 2)
        XCTAssertFalse(fixture.workflow.isInteractiveCaptureActive)
        XCTAssertFalse(fixture.workflow.isWorking)
    }

    func testQueuedRepeatRequestsCannotStartTwoScrollingSessions() async {
        let fixture = ScrollingWorkflowFixture()
        defer { fixture.cleanUp() }

        fixture.workflow.repeatScrollingCapture(region)
        fixture.workflow.repeatScrollingCapture(region)
        await waitUntil { fixture.workflow.captureRecovery != nil }

        XCTAssertEqual(fixture.probe.resolveCount, 1)
        XCTAssertEqual(fixture.windows.hiddenContexts.count, 1)
        XCTAssertEqual(fixture.windows.restoreCount, 1)
    }

    func testChooseAnotherAreaRecoveryPreservesQuickControlsOrigin() async {
        let fixture = ScrollingWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.workflow.pendingRecoveryCaptureContext = CaptureCompletionContext(
            intent: .newDocument, role: .standalone, presentationContext: origin
        )
        fixture.workflow.pendingRecoveryRequest = .scrolling(region)

        fixture.workflow.performCaptureRecovery(.chooseAnotherArea)
        await waitUntil { fixture.workflow.captureRecovery != nil }

        XCTAssertEqual(fixture.windows.hiddenContexts, [origin])
        XCTAssertEqual(fixture.windows.restoreCount, 1)
    }
}

@MainActor
private final class ScrollingWorkflowFixture {
    let workflow: CaptureWorkflowModel
    let windows: ScrollingWorkflowWindowPresenter
    let probe: ScrollingWorkflowProbe
    private let suite: String
    private let defaults: UserDefaults

    init(failsTarget: Bool = true, confirmation: ScrollingCaptureTargetConfirmation.Choice = .cancel) {
        let suite = "ScrollingWorkflowTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suite)
        let windows = ScrollingWorkflowWindowPresenter()
        let probe = ScrollingWorkflowProbe()
        self.suite = suite
        self.defaults = defaults
        self.windows = windows
        self.probe = probe
        let permissions = TestCapturePermissionService()
        let environment = AppEnvironment(defaults: defaults, buildTarget: .dev, permissions: permissions)
        let lifecycle = TestWorkflowLifecyclePresenter()
        let gate = PermissionWorkflowModel(dependencies: PermissionWorkflowDependencies(
            capabilities: environment.capabilities, permissions: permissions,
            scheduler: environment.systemServices.scheduler, lifecycle: lifecycle
        ))
        workflow = CaptureWorkflowModel(
            dependencies: CaptureWorkflowDependencies(
                capabilities: environment.capabilities, systemServices: environment.systemServices,
                appWindowPresenter: windows, permissions: gate, lifecycle: lifecycle,
                makeScrollingCaptureService: { backend in
                    probe.serviceCount += 1
                    return ScrollingCaptureService(captureService: backend, permissions: permissions, driverFactory: { _ in
                        probe.resolveCount += 1
                        probe.wasInteractive = probe.workflow?.isInteractiveCaptureActive == true
                        probe.wasPrivacyLocked = probe.workflow?.isCapturePrivacyLocked == true
                        if failsTarget { throw ScrollingCaptureError.noScrollableTarget }
                        return ScrollingTestDriver(reportedPosition: nil)
                    })
                },
                preferenceStore: environment.preferenceStores.capture,
                automationPreferenceStore: environment.preferenceStores.automation,
                confirmScrollingTarget: { _ in confirmation }
            ),
            captureService: ScreenCaptureService(), uiMapCaptureService: environment.makeUIMapCaptureService(),
            connectedDeviceCaptureService: environment.makeConnectedDeviceCaptureService()
        )
        probe.workflow = workflow
    }

    func cleanUp() {
        workflow.dismissCaptureRecovery()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class ScrollingWorkflowProbe {
    weak var workflow: CaptureWorkflowModel?
    var serviceCount = 0
    var resolveCount = 0
    var wasInteractive = false
    var wasPrivacyLocked = false
}

@MainActor
private final class ScrollingWorkflowWindowPresenter: AppWindowPresenting {
    var hiddenContexts: [WorkflowPresentationContext] = []
    var restoreCount = 0
    func hideAppWindowIfNeeded(for context: WorkflowPresentationContext) -> AppWindowVisibilityToken? {
        hiddenContexts.append(context)
        return nil
    }
    func restoreAppWindowIfNeeded(_ token: AppWindowVisibilityToken?) { restoreCount += 1 }
    func keepAppWindowHidden(_ token: AppWindowVisibilityToken?) {}
    func promoteToRegularApp() {}
    func demoteToAccessoryIfPossible() {}
    func activateApp() {}
}
