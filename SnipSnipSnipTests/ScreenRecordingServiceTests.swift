import Foundation
import XCTest
@testable import SnipSnipSnip

@MainActor
final class ScreenRecordingServiceTests: XCTestCase {
    private struct ExpectedFailure: Error {}

    func testFullscreenRecordingDeniesBeforeFetchingSystemContentWhenScreenRecordingPermissionMissing() async {
        let service = ScreenRecordingService(
            permissions: TestCapturePermissionService(
                status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true)
            )
        )

        do {
            _ = try await service.startFullscreenRecording(preferences: VideoRecordingPreferences())
            XCTFail("Expected fullscreen recording to fail without Screen Recording permission.")
        } catch ScreenRecordingError.permissionDenied {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRegionRecordingSourceRectUsesDisplayLocalCrop() {
        let service = ScreenRecordingService()
        let display = DisplaySnapshot(
            displayID: 7,
            name: "Display",
            frame: CGRect(x: 100, y: 200, width: 1440, height: 900),
            scale: 2
        )

        let sourceRect = service.regionRecordingSourceRect(
            for: CGRect(x: 140, y: 260, width: 320, height: 180),
            in: display
        )

        XCTAssertEqual(sourceRect, CGRect(x: 40, y: 60, width: 320, height: 180))
    }

    func testRecordingOutputCompletionTrackerResumesAllWaitersForOutput() async throws {
        let tracker = RecordingOutputCompletionTracker()
        let token = ScreenRecordingSegmentToken()
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("segment-\(UUID().uuidString).mp4")

        tracker.track(token: token, outputURL: outputURL)

        let firstWaiter = Task { @MainActor in
            try await tracker.wait(for: token)
            return 1
        }
        let secondWaiter = Task { @MainActor in
            try await tracker.wait(for: token)
            return 2
        }

        await Task.yield()

        XCTAssertEqual(
            tracker.finish(token: token, result: .success(()))?.standardizedFileURL,
            outputURL.standardizedFileURL
        )

        let firstValue = try await firstWaiter.value
        let secondValue = try await secondWaiter.value

        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
    }

    func testRecordingOutputCompletionTrackerPropagatesFailureToPendingAndFutureWaiters() async {
        let tracker = RecordingOutputCompletionTracker()
        let token = ScreenRecordingSegmentToken()
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("segment-\(UUID().uuidString).mp4")

        tracker.track(token: token, outputURL: outputURL)

        let waiter = Task { @MainActor in
            try await tracker.wait(for: token)
        }

        await Task.yield()
        tracker.finishAll(with: .failure(ExpectedFailure()))

        do {
            try await waiter.value
            XCTFail("Expected the pending waiter to receive the failure result.")
        } catch is ExpectedFailure {
        } catch {
            XCTFail("Received unexpected error: \(error)")
        }

        do {
            try await tracker.wait(for: token)
            XCTFail("Expected subsequent waiters to receive the stored failure result.")
        } catch is ExpectedFailure {
        } catch {
            XCTFail("Received unexpected error: \(error)")
        }
    }

    func testUpdatingAudioOptionsWhileCapturingRotatesRecordingSegment() async throws {
        let platformSession = TestScreenRecordingPlatformSession()
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recording-\(UUID().uuidString).mp4")
        let initialPreferences = VideoRecordingPreferences()
        let initialConfiguration = ScreenRecordingConfiguration(
            width: 1280,
            height: 720,
            minimumFrameInterval: initialPreferences.frameRate.frameInterval,
            captureResolution: initialPreferences.quality.captureResolution,
            showsCursor: true,
            showsMouseClicks: true,
            capturesAudio: false,
            capturesMicrophone: false
        )
        let session = ScreenRecordingSession(
            platformSession: platformSession,
            configuration: initialConfiguration,
            outputURL: outputURL,
            kind: .fullscreen,
            sourceName: "Display",
            bounds: CGRect(x: 0, y: 0, width: 1280, height: 720),
            preferences: initialPreferences,
            platform: TestScreenRecordingPlatform(),
            files: SystemFileService(),
            clock: TestClock()
        )

        try session.startRecordingSegment()
        let firstToken = try XCTUnwrap(platformSession.segmentOutputURLs.keys.first)
        try await platformSession.startCapture()
        session.markCaptureStarted()

        let updateTask = Task { @MainActor in
            try await session.updateAudioOptions(recordsSystemAudio: true, recordsMicrophone: false)
        }
        await Task.yield()
        platformSession.finish(firstToken)
        try await updateTask.value

        XCTAssertEqual(platformSession.configurationUpdates.map(\.capturesAudio), [true])
        XCTAssertTrue(platformSession.isCapturing)
        XCTAssertFalse(platformSession.segmentOutputURLs.keys.contains(firstToken))
        XCTAssertEqual(platformSession.segmentOutputURLs.count, 1)
    }

    func testSessionStartWaitsForRecordingOutputConfirmation() async throws {
        let platformSession = TestScreenRecordingPlatformSession()
        platformSession.automaticallyStartsRecordingOutputs = false
        let session = makeSession(platformSession: platformSession)

        let startTask = Task { @MainActor in try await session.start() }
        await Task.yield()
        let token = try XCTUnwrap(platformSession.segmentOutputURLs.keys.first)
        XCTAssertFalse(startTask.isCancelled)

        platformSession.start(token)
        try await startTask.value
        XCTAssertTrue(platformSession.isCapturing)
    }

    func testSessionStartPropagatesOutputFailureBeforeConfirmation() async throws {
        let platformSession = TestScreenRecordingPlatformSession()
        platformSession.automaticallyStartsRecordingOutputs = false
        let session = makeSession(platformSession: platformSession)
        let startTask = Task { @MainActor in try await session.start() }
        await Task.yield()
        let token = try XCTUnwrap(platformSession.segmentOutputURLs.keys.first)

        platformSession.fail(token, error: ExpectedFailure())

        do {
            try await startTask.value
            XCTFail("Expected output startup failure.")
        } catch is ExpectedFailure {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(platformSession.isCapturing)
    }

    func testUnexpectedStreamFailureIsReportedOnce() async throws {
        let platformSession = TestScreenRecordingPlatformSession()
        let session = makeSession(platformSession: platformSession)
        var reportedFailures = 0
        session.terminalFailureHandler = { _ in reportedFailures += 1 }
        try await session.start()

        platformSession.stopWithError(ExpectedFailure())
        platformSession.stopWithError(ExpectedFailure())

        XCTAssertEqual(reportedFailures, 1)
    }

    func testTerminalFailureBeforeHandlerInstallationIsDeliveredOnce() {
        let platformSession = TestScreenRecordingPlatformSession()
        let session = makeSession(platformSession: platformSession)
        platformSession.stopWithError(ExpectedFailure())

        var reportedFailures = 0
        session.terminalFailureHandler = { _ in reportedFailures += 1 }
        session.terminalFailureHandler = { _ in reportedFailures += 1 }

        XCTAssertEqual(reportedFailures, 1)
    }

    func testRecordingOutputStartTrackerTimesOut() async {
        let tracker = RecordingOutputStartTracker()
        let token = ScreenRecordingSegmentToken()

        do {
            try await tracker.wait(for: token, timeoutNanoseconds: 1_000_000)
            XCTFail("Expected recording output startup to time out.")
        } catch ScreenRecordingError.recordingStartTimedOut {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConcurrentStopCallsShareOneFinalizationAttempt() async throws {
        let platformSession = TestScreenRecordingPlatformSession()
        platformSession.automaticallyFinishesRecordingOutputs = true
        let session = makeSession(platformSession: platformSession)
        try await session.start()

        let first = Task { @MainActor () -> Result<CapturedVideoRecording, Error> in
            do { return .success(try await session.stop()) }
            catch { return .failure(error) }
        }
        let second = Task { @MainActor () -> Result<CapturedVideoRecording, Error> in
            do { return .success(try await session.stop()) }
            catch { return .failure(error) }
        }
        _ = await (first.value, second.value)

        XCTAssertEqual(platformSession.stopCaptureCallCount, 1)
    }

    func testRecordingLifecycleRejectsDuplicateReservationAndIgnoresStaleReset() {
        let lifecycle = VideoRecordingLifecycleCoordinator()
        let first = lifecycle.reserveStart()

        XCTAssertNotNil(first)
        XCTAssertNil(lifecycle.reserveStart())
        XCTAssertEqual(lifecycle.phase, .preparing)
        XCTAssertFalse(lifecycle.transition(to: .paused, generation: try! XCTUnwrap(first)))
        lifecycle.reset(generation: UUID())
        XCTAssertEqual(lifecycle.phase, .preparing)
        lifecycle.reset(generation: try! XCTUnwrap(first))
        XCTAssertEqual(lifecycle.phase, .idle)
    }

    private func makeSession(
        platformSession: TestScreenRecordingPlatformSession
    ) -> ScreenRecordingSession {
        let preferences = VideoRecordingPreferences()
        return ScreenRecordingSession(
            platformSession: platformSession,
            configuration: ScreenRecordingConfiguration(
                width: 1280,
                height: 720,
                minimumFrameInterval: preferences.frameRate.frameInterval,
                captureResolution: preferences.quality.captureResolution,
                showsCursor: true,
                showsMouseClicks: true,
                capturesAudio: false,
                capturesMicrophone: false
            ),
            outputURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("recording-\(UUID().uuidString).mp4"),
            kind: .fullscreen,
            sourceName: "Display",
            bounds: CGRect(x: 0, y: 0, width: 1280, height: 720),
            preferences: preferences,
            platform: TestScreenRecordingPlatform(),
            files: SystemFileService(),
            clock: TestClock()
        )
    }
}
