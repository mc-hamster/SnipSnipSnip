import CoreGraphics
import XCTest
@testable import SnipSnipSnip

@MainActor
final class ManualScrollingStreamTests: XCTestCase {
    func testStreamingUsesScreenPermissionOnlyAndDrainsFramesOnStop() async throws {
        let cancellation = ScrollingCaptureCancellation()
        let session = Session(offsets: [0, 20, 40, 30, 50])
        session.onTake = { index in if index == 2 { cancellation.finish() } }
        let service = makeService(session: session)
        let result = try await service.capture(request: request, cancellation: cancellation)
        assertScrollingRows(in: result.image, expectedHeight: 130)
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testCancellingDuringFrameProcessingStopsTheStream() async throws {
        let cancellation = ScrollingCaptureCancellation()
        let session = Session(offsets: [0, 20, 40])
        session.onTake = { index in if index == 1 { cancellation.cancel() } }
        do {
            _ = try await makeService(session: session).capture(request: request, cancellation: cancellation)
            XCTFail("Cancel must not publish an image")
        } catch ScrollingCaptureError.cancelled {}
        XCTAssertEqual(session.stopCount, 1)
    }

    func testStreamFailureKeepsConnectedContentAndStopsResources() async throws {
        let session = Session(offsets: [0, 20, 40])
        session.errorAfterFrames = true
        do {
            _ = try await makeService(session: session).capture(request: request, cancellation: ScrollingCaptureCancellation())
            XCTFail("Expected stream failure")
        } catch let error as ScrollingCaptureInterruptedError {
            assertScrollingRows(in: error.partialResult.image, expectedHeight: 120)
        }
        XCTAssertEqual(session.stopCount, 1)
    }

    func testIdleStreamRemainsCancellableWithoutNewScreenFrames() async throws {
        let cancellation = ScrollingCaptureCancellation()
        let session = Session(offsets: [0])
        session.onTake = { index in if index > 4 { cancellation.cancel() } }
        do {
            _ = try await makeService(session: session).capture(request: request, cancellation: cancellation)
            XCTFail("Idle is not completion")
        } catch ScrollingCaptureError.cancelled {}
        XCTAssertEqual(session.stopCount, 1)
    }

    private var request: ScrollingCaptureRequest {
        ScrollingCaptureRequest(viewportRect: CGRect(x: 0, y: 0, width: 48, height: 80), mode: .manual)
    }

    private func makeService(session: Session) -> ManualScrollingCaptureService {
        let platform = TestScreenCapturePlatform(
            content: ScreenContentSnapshot(displays: [DisplaySnapshot(displayID: 1, name: "Fixture", frame: request.viewportRect, scale: 1)], windows: [], applications: []),
            imageProvider: { _ in XCTFail("Streaming must not poll screenshots"); throw ScrollingCaptureError.firstFrameUnavailable },
            scrollingSessionProvider: { request in
                XCTAssertFalse(request.configuration.showsCursor)
                XCTAssertEqual(request.configuration.sourceRect, CGRect(x: 0, y: 0, width: 48, height: 80))
                XCTAssertEqual(request.target, .display(1, excludingProcessID: ProcessInfo.processInfo.processIdentifier))
                return session
            }
        )
        let capture = ScreenCaptureService(
            permissions: TestCapturePermissionService(status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false)),
            platform: platform, workspace: TestWorkspaceService(), screens: TestScreenTopologyService(),
            mouse: TestMouseLocationService(), windowFocus: TestApplicationWindowFocusService(), clock: TestClock()
        )
        return ManualScrollingCaptureService(captureService: capture, scheduler: ImmediateScheduler())
    }

    private struct ImmediateScheduler: Scheduling {
        nonisolated func sleep(nanoseconds: UInt64) async throws { try Task.checkCancellation(); await Task.yield() }
    }
    private final class Session: ScrollingFrameSession {
        var images: [CGImage]
        var calls = 0
        var stopCount = 0
        var errorAfterFrames = false
        var onTake: ((Int) -> Void)?
        init(offsets: [Int]) { images = offsets.map { offset in makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + offset }) } }
        func nextFrame() throws -> CGImage? {
            let index = calls
            calls += 1
            onTake?(index)
            if !images.isEmpty { return images.removeFirst() }
            if errorAfterFrames { throw ScreenCapturePlatformError.imageUnavailable }
            return nil
        }
        func stop() async { if stopCount == 0 { stopCount = 1 } }
    }
}
