import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class ScreenToolsAuditTests: XCTestCase {
    func testInspectorDoesNotSampleWhileScreenAccessNeedsSetup() async throws {
        let probe = ScreenToolsCaptureProbe()
        let denied = TestCapturePermissionService(status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false))
        let model = ScreenInspectorWindowModel(preferences: .default,
            capturePlatform: TestScreenCapturePlatform(imageProvider: { _ in
                probe.recordCapture()
                throw ScreenCaptureError.permissionDenied
            }), permissions: denied)
        model.sample = ScreenInspectorSample(image: makeCoordinateImage(width: 4, height: 4),
            cursorLocation: .zero, sourceRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            color: ScreenInspectorPixelColor(red: 1, green: 2, blue: 3, alpha: 255))
        model.start()
        defer { model.stop() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.captureCount, 0)
        XCTAssertNil(model.sample, "Stale pixels must not cover the setup guidance")
    }

    func testInspectorPermissionFailureStopsRepeatedSamplingAndClearsStalePixels() async throws {
        let probe = ScreenToolsCaptureProbe()
        let service = TestCapturePermissionService()
        let permissions = PermissionWorkflowModel(dependencies: PermissionWorkflowDependencies(
            capabilities: testCapabilities, permissions: service, scheduler: SystemScheduler(), lifecycle: TestWorkflowLifecyclePresenter()))
        let model = ScreenInspectorWindowModel(preferences: .default,
            capturePlatform: TestScreenCapturePlatform(imageProvider: { _ in
                probe.recordCapture()
                throw ScreenCaptureError.permissionDenied
            }), permissions: service, permissionWorkflow: permissions)
        model.start()
        defer { model.stop() }
        await waitUntil { !permissions.permissionStatus.hasScreenRecording }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.captureCount, 1)
        XCTAssertFalse(model.hasScreenRecordingAccess)
        XCTAssertNil(model.sample)
        XCTAssertTrue(permissions.screenRecordingSetupNeedsAttention)
    }

    func testRulerClickCyclesAllEdgeAndOriginCombinationsLocally() {
        for kind in [ScreenRulerKind.horizontal, .vertical] {
            let model = ScreenRulerWindowModel(kind: kind, preferences: .default)
            let original = model.preferences
            var states = Set<String>()
            for _ in 0..<4 {
                states.insert("\(model.preferences.horizontalTickEdge)-\(model.preferences.horizontalOrigin)-\(model.preferences.verticalTickEdge)-\(model.preferences.verticalOrigin)")
                model.toggleTickEdge()
            }
            XCTAssertEqual(states.count, 4)
            XCTAssertEqual(model.preferences, original)
        }
    }
}

private final class ScreenToolsCaptureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var captureCount: Int { lock.withLock { count } }
    func recordCapture() { lock.withLock { count += 1 } }
}
