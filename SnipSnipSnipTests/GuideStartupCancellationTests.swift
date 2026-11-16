#if !APP_STORE_BUILD
import CoreGraphics
import XCTest
@testable import SnipSnipSnip

@MainActor
final class GuideStartupCancellationTests: XCTestCase {
    func testDiscardOrStopDuringMediaCreationCannotStartCaptureLater() async {
        for usesStop in [false, true] {
            let barrier = DeferredBoolVerifier()
            let session = TestScreenRecordingPlatformSession()
            let coordinator = makeCoordinator { _, _ in
                _ = await barrier.value()
                return session
            }
            let startupTask = start(coordinator)
            await barrier.waitForRequest()
            XCTAssertEqual(coordinator.state, .starting)
            if usesStop { _ = try? await coordinator.stop() }
            else { await coordinator.discard() }
            XCTAssertEqual(coordinator.state, .idle)
            XCTAssertNil(coordinator.project)

            await barrier.resume(returning: true)
            await assertCancelled(startupTask)

            XCTAssertEqual(coordinator.state, .idle)
            XCTAssertNil(coordinator.project)
            XCTAssertFalse(session.isCapturing)
            XCTAssertEqual(session.stopCaptureCallCount, 1, "Late-created local media must be discarded")
        }
    }

    func testLateCreationFailureCannotResetNewerGuideStartup() async {
        let oldBarrier = DeferredBoolVerifier()
        let newBarrier = DeferredBoolVerifier()
        let newSession = TestScreenRecordingPlatformSession()
        var count = 0
        let coordinator = makeCoordinator { _, _ in
            count += 1
            if count == 1 {
                _ = await oldBarrier.value()
                throw ScreenRecordingError.permissionDenied
            }
            _ = await newBarrier.value()
            return newSession
        }
        let oldStart = start(coordinator)
        await oldBarrier.waitForRequest()
        await coordinator.discard()
        let newStart = start(coordinator)
        await newBarrier.waitForRequest()
        let newProjectID = coordinator.project?.id

        await oldBarrier.resume(returning: true)
        await assertCancelled(oldStart)

        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertEqual(coordinator.project?.id, newProjectID)
        XCTAssertNotNil(newProjectID)
        XCTAssertEqual(newSession.stopCaptureCallCount, 0)
        await coordinator.discard()
        await newBarrier.resume(returning: true)
        await assertCancelled(newStart)
    }

    func testLateMediaStartIsStoppedWithoutChangingNewerGuide() async {
        let oldBarrier = DeferredBoolVerifier()
        let newBarrier = DeferredBoolVerifier()
        let oldSession = DeferredGuideStartupSession(barrier: oldBarrier)
        let newSession = TestScreenRecordingPlatformSession()
        var count = 0
        let coordinator = makeCoordinator { _, _ in
            count += 1
            if count == 1 { return oldSession }
            _ = await newBarrier.value()
            return newSession
        }
        let oldStart = start(coordinator)
        await oldBarrier.waitForRequest()
        await coordinator.discard()
        XCTAssertEqual(oldSession.stopCount, 1)
        let newStart = start(coordinator)
        await newBarrier.waitForRequest()
        let newProjectID = coordinator.project?.id

        await oldBarrier.resume(returning: true)
        await assertCancelled(oldStart)

        XCTAssertEqual(oldSession.stopCount, 2, "A backend start that finishes after Stop must be stopped again")
        XCTAssertFalse(oldSession.isCapturing)
        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertEqual(coordinator.project?.id, newProjectID)
        XCTAssertEqual(newSession.stopCaptureCallCount, 0)
        await coordinator.discard()
        await newBarrier.resume(returning: true)
        await assertCancelled(newStart)
    }

    private func start(_ coordinator: GuideCaptureCoordinator) -> Task<Void, Error> {
        var preferences = GuideCapturePreferences()
        preferences.sourceVideoEnabled = false
        preferences.capturesSystemAudio = false
        preferences.capturesMicrophone = false
        return Task {
            try await coordinator.start(source: .displays(.selected([1])), preferences: preferences,
                exportSettings: GuideExportSettings(), theme: GuideTheme(), logoImage: nil,
                privateCapture: true, guideShortcutKeyCode: 5)
        }
    }

    private func assertCancelled(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        switch await task.result {
        case .success: XCTFail("Discarded Guide startup must not succeed", file: file, line: line)
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
    }

    private func makeCoordinator(
        makeSession: @escaping @MainActor (ScreenRecordingTarget, ScreenRecordingConfiguration) async throws -> any ScreenRecordingPlatformSession
    ) -> GuideCaptureCoordinator {
        let permissions = TestCapturePermissionService()
        let base = AppSystemServices.live(permissions: permissions)
        let platform = TestScreenRecordingPlatform(content: ScreenContentSnapshot(displays: [
            DisplaySnapshot(displayID: 1, name: "Startup fixture", frame: CGRect(x: 0, y: 0, width: 160, height: 100), scale: 1)
        ], windows: [], applications: []), makeSessionHandler: makeSession)
        let services = AppSystemServices(files: base.files, workspace: TestWorkspaceService(),
            screens: TestScreenTopologyService(), mouse: TestMouseLocationService(),
            windowFocus: TestApplicationWindowFocusService(), bundle: base.bundle, pasteboard: base.pasteboard,
            clock: TestClock(), ids: base.ids, scheduler: base.scheduler, permissions: permissions,
            accessibility: TestGuideAccessibility(), screenCapturePlatform: TestScreenCapturePlatform(),
            screenRecordingPlatform: platform, connectedDevicePlatform: base.connectedDevicePlatform)
        return GuideCaptureCoordinator(systemServices: services)
    }
}

@MainActor
private final class DeferredGuideStartupSession: ScreenRecordingPlatformSession {
    let barrier: DeferredBoolVerifier
    var isCapturing = false
    var stopCount = 0
    init(barrier: DeferredBoolVerifier) { self.barrier = barrier }
    func setEventSink(_ sink: (any ScreenRecordingPlatformEventSink)?) {}
    func startCapture() async throws {
        _ = await barrier.value()
        isCapturing = true
    }
    func stopCapture() async throws { stopCount += 1; isCapturing = false }
    func updateConfiguration(_ configuration: ScreenRecordingConfiguration) async throws {}
    func startRecordingSegment(to outputURL: URL) throws -> ScreenRecordingSegmentToken {
        XCTFail("The startup fixture must not record source media")
        throw CancellationError()
    }
    func removeRecordingSegment(_ token: ScreenRecordingSegmentToken) throws {}
}


#endif
