import CoreGraphics
import XCTest
@testable import SnipSnipSnip

@MainActor
final class CapturePresetStateRegressionTests: XCTestCase {
    func testFailedCopyOrExportPresetCannotAffectNextOrdinaryCapture() async throws {
        for outcome in [CapturePresetOutcome.copyToClipboard, .exportToFolder] {
            let fixture = makeFixture(failsFirstCapture: true)
            defer { fixture.cleanUp() }
            let preset = CapturePreset(name: "Failed preset", target: .fullscreen,
                options: CaptureRunOptions(), outcome: outcome)
            fixture.model.capture.capturePresets = [preset]
            fixture.model.capture.capturePreset(preset)
            await waitUntil { fixture.model.capture.captureRecovery != nil }
            XCTAssertNotNil(fixture.model.capture.captureRecovery)
            XCTAssertEqual(fixture.model.capture.pendingRecoveryCaptureContext?.workflowPreset?.outcome, outcome)
            XCTAssertNil(fixture.model.capture.activeCaptureContext.workflowPreset)

            fixture.model.capture.dismissCaptureRecovery()
            fixture.model.capture.captureCurrentDisplay()
            await waitUntil { !fixture.sink.captures.isEmpty }
            XCTAssertNil(try XCTUnwrap(fixture.sink.captures.first).workflowPreset,
                "An ordinary capture must not receive the failed preset's Copy/Export action")
        }
    }

    func testCancelledPresetWindowReplacementCannotAffectNextOrdinaryCapture() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let preset = CapturePreset(name: "Missing window", target: .window(SavedWindowTarget(window: makeCaptureWindow(id: 700))),
            options: CaptureRunOptions(), outcome: .copyToClipboard)
        fixture.model.capture.capturePresets = [preset]
        fixture.model.capture.capturePreset(preset)
        await waitUntil { fixture.model.capture.isShowingWindowPicker }
        XCTAssertTrue(fixture.model.capture.isShowingWindowPicker)
        XCTAssertEqual(fixture.model.capture.windowPickerCaptureContext?.workflowPreset?.id, preset.id)

        fixture.model.capture.cancelScreenshotWindowPicker()
        fixture.model.capture.captureCurrentDisplay()
        await waitUntil { !fixture.sink.captures.isEmpty }
        XCTAssertNil(try XCTUnwrap(fixture.sink.captures.first).workflowPreset)
    }

    func testPresetRetryRetainsOriginalOptionsAndOutcomeAfterSettingsChange() async throws {
        let fixture = makeFixture(failsFirstCapture: true)
        defer { fixture.cleanUp() }
        let preset = CapturePreset(name: "Retry preset", target: .fullscreen,
            options: CaptureRunOptions(includesCursor: false), outcome: .copyToClipboard)
        fixture.model.capture.capturePresets = [preset]
        fixture.model.capture.capturePreset(preset)
        await waitUntil { fixture.model.capture.captureRecovery != nil }
        XCTAssertNotNil(fixture.model.capture.captureRecovery)
        fixture.model.capture.capturePresets[0].outcome = .exportToFolder
        fixture.model.capture.capturePresets[0].options.includesCursor = true

        fixture.model.capture.performCaptureRecovery(.retryLastCapture)
        await waitUntil { !fixture.sink.captures.isEmpty }
        let result = try XCTUnwrap(fixture.sink.captures.first)
        XCTAssertEqual(result.workflowPreset?.outcome, .copyToClipboard)
        XCTAssertFalse(result.runOptions.includesCursor)
        XCTAssertNil(fixture.model.capture.activeCaptureContext.workflowPreset)
    }

    func testSuccessfulPresetStillDeliversItsOwnCopyOrExportOutcome() async throws {
        for outcome in [CapturePresetOutcome.copyToClipboard, .exportToFolder] {
            let fixture = makeFixture()
            defer { fixture.cleanUp() }
            let preset = CapturePreset(name: "Successful preset", target: .fullscreen,
                options: CaptureRunOptions(), outcome: outcome)
            fixture.model.capture.capturePresets = [preset]
            fixture.model.capture.capturePreset(preset)
            await waitUntil { !fixture.sink.captures.isEmpty }
            XCTAssertEqual(try XCTUnwrap(fixture.sink.captures.first).workflowPreset?.outcome, outcome)
            XCTAssertNil(fixture.model.capture.activeCaptureContext.workflowPreset)
        }
    }

    func testLatePresetCompletionCannotUseOrClearNewerAttemptOutcome() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let preset = CapturePreset(name: "Same preset", target: .fullscreen,
            options: CaptureRunOptions(), outcome: .copyToClipboard)
        var oldContext = CaptureCompletionContext.standalone
        oldContext.workflowPreset = preset
        oldContext.workflowPresetRunID = UUID()
        var newContext = oldContext
        newContext.workflowPreset?.outcome = .exportToFolder
        newContext.workflowPresetRunID = UUID()
        fixture.model.capture.activeCaptureContext = newContext

        try fixture.model.capture.completeCapture(makeCapturedScreenshot(), request: .fullscreen,
            isPrivateCapture: false, shouldAttemptUIMapCapture: false, completionContext: oldContext)
        XCTAssertEqual(try XCTUnwrap(fixture.sink.captures.first).workflowPreset?.outcome, .copyToClipboard)
        XCTAssertEqual(fixture.model.capture.activeCaptureContext, newContext)

        try fixture.model.capture.completeCapture(makeCapturedScreenshot(), request: .fullscreen,
            isPrivateCapture: false, shouldAttemptUIMapCapture: false, completionContext: newContext)
        XCTAssertEqual(try XCTUnwrap(fixture.sink.captures.last).workflowPreset?.outcome, .exportToFolder)
        XCTAssertNil(fixture.model.capture.activeCaptureContext.workflowPreset)
    }

    private func makeFixture(failsFirstCapture: Bool = false)
        -> (model: AppModel, sink: PresetCaptureOutputRecorder, cleanUp: () -> Void) {
        let name = "CapturePresetStateRegressionTests.\(UUID())"
        let defaults = makeDefaults(named: name)
        let responses = PresetCaptureResponses(failsFirstCapture: failsFirstCapture)
        let platform = TestScreenCapturePlatform(content: ScreenContentSnapshot(displays: [
            DisplaySnapshot(displayID: 1, name: "Fixture display", frame: CGRect(x: 0, y: 0, width: 64, height: 48), scale: 1)
        ], windows: [], applications: []), imageProvider: { _ in try responses.image() })
        let service = ScreenCaptureService(permissions: TestCapturePermissionService(), platform: platform,
            workspace: TestWorkspaceService(), screens: TestScreenTopologyService(),
            mouse: TestMouseLocationService(), windowFocus: TestApplicationWindowFocusService(), clock: TestClock())
        let model = AppModel(defaults: defaults,
            environment: AppEnvironment(defaults: defaults, permissions: TestCapturePermissionService()),
            recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
            captureService: service, shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        let sink = PresetCaptureOutputRecorder()
        model.capture.outputSink = sink
        return (model, sink, {
            model.capture.cancelScreenshotWindowPicker()
            model.capture.dismissCaptureRecovery()
            model.permissions.dismissPermissionSetupGuide()
            defaults.removePersistentDomain(forName: name)
        })
    }
}

private final class PresetCaptureResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail: Bool
    init(failsFirstCapture: Bool) { shouldFail = failsFirstCapture }
    func image() throws -> CGImage {
        let fails = lock.withLock {
            let result = shouldFail
            shouldFail = false
            return result
        }
        if fails { throw ScreenCaptureError.bitmapContextCreationFailed }
        return makeCoordinateImage(width: 64, height: 48)
    }
}

@MainActor
private final class PresetCaptureOutputRecorder: WorkflowOutputSink {
    var captures: [CaptureWorkflowResult] = []
    func handle(_ output: CaptureWorkflowOutput) {
        if case .captureCompleted(let result) = output { captures.append(result) }
    }
    func handle(_ output: LifecycleWorkflowOutput) {}
    func handle(_ output: PermissionWorkflowOutput) {}
    func handle(_ output: DocumentWorkflowOutput) {}
    func handle(_ output: ClipboardWorkflowOutput) {}
    func handle(_ output: VideoWorkflowOutput) {}
    func handle(_ output: GuideWorkflowOutput) {}
    func handle(_ output: ArchiveWorkflowOutput) {}
    func handle(_ output: ToolWorkflowOutput) {}
}
