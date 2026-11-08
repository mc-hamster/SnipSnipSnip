import XCTest
@testable import SnipSnipSnip

@MainActor
final class ConnectedDeviceRecoveryTests: XCTestCase {
    func testRecordingRetryPreservesIntentWhenAnotherSessionIsActive() async throws {
        try await assertRecordingIntentSurvivesEarlyFailureAndRetry(
            buildTarget: .dev,
            expectedError: .sessionAlreadyActive
        )
    }

    func testRecordingRetryPreservesIntentWhenConnectedDeviceCaptureIsUnavailable() async throws {
        try await assertRecordingIntentSurvivesEarlyFailureAndRetry(
            buildTarget: .release,
            expectedError: .publicScreenCaptureUnavailable
        )
    }

    private func assertRecordingIntentSurvivesEarlyFailureAndRetry(
        buildTarget: BuildTarget,
        expectedError: ConnectedDeviceCaptureError
    ) async throws {
        let name = "ConnectedDeviceRecoveryTests.\(UUID())"
        let defaults = makeDefaults(named: name)
        let model = AppModel(
            defaults: defaults,
            environment: AppEnvironment(
                defaults: defaults,
                buildTarget: buildTarget,
                permissions: TestCapturePermissionService()
            ),
            recoveryStore: DocumentRecoveryStore(
                baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)
            ),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        // Reserve a session without starting capture or requesting device access.
        // Both early exits must retain the same retry intent as later failures.
        let generation = try XCTUnwrap(model.video.recordingLifecycle.reserveStart())
        defer {
            model.video.recordingLifecycle.reset(generation: generation)
            model.capture.dismissCaptureRecovery()
            defaults.removePersistentDomain(forName: name)
        }

        let device = ConnectedAppleDevice(id: "test-device", name: "Test iPad")
        model.capture.recordConnectedDevice(device)
        await waitUntil { model.capture.captureRecovery != nil }

        XCTAssertEqual(try XCTUnwrap(model.capture.captureRecovery).message, expectedError.errorDescription)
        XCTAssertEqual(model.capture.pendingConnectedDevicePreviewIntent, .recording)

        model.capture.performCaptureRecovery(.retryLastCapture)
        await waitUntil { model.capture.captureRecovery != nil }

        XCTAssertEqual(try XCTUnwrap(model.capture.captureRecovery).message, expectedError.errorDescription)
        XCTAssertEqual(model.capture.pendingConnectedDevicePreviewIntent, .recording)
        guard case .connectedDevice(let retryDevice) = model.capture.pendingRecoveryRequest else {
            return XCTFail("Recording recovery must retain its connected-device target")
        }
        XCTAssertEqual(retryDevice, device)
    }
}
