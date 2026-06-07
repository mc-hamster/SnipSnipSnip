import XCTest
@testable import SnipSnipSnip

final class ConnectedDeviceCaptureServiceTests: XCTestCase {
    func testConnectedDeviceCaptureErrorExplainsMissingBuildConfiguration() {
        XCTAssertEqual(
            ConnectedDeviceCaptureError.missingCaptureConfiguration([
                "NSCameraUsageDescription",
                "NSCameraUseExternalDeviceType",
            ]).errorDescription,
            "Connected-device capture is enabled, but this app build is missing required camera configuration: NSCameraUsageDescription, NSCameraUseExternalDeviceType. Use the Dev Debug configuration file or the self-release configuration so the camera entitlement and Info.plist keys are included."
        )
    }

    func testConnectedDeviceCaptureErrorExplainsPublicAPIConstraint() {
        XCTAssertEqual(
            ConnectedDeviceCaptureError.publicScreenCaptureUnavailable.errorDescription,
            "Connected iPhone and iPad screen capture is not available through public macOS APIs. SnipSnipSnip cannot use private device services or QuickTime automation in an App Store-safe build."
        )
    }

    func testConnectedDeviceKindsUseExpectedMetadataValues() {
        XCTAssertEqual(CaptureKind.connectedDevice.rawValue, "connectedDevice")
        XCTAssertEqual(VideoRecordingKind.connectedDevice.rawValue, "connectedDevice")
        XCTAssertEqual(VideoRecordingKind.connectedDevice.label, "Connected Device")
    }
}
