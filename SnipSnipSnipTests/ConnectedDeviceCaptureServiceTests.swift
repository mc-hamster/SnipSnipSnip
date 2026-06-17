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

    func testConnectedDeviceCaptureErrorExplainsPreviewInterruptions() {
        XCTAssertEqual(
            ConnectedDeviceCaptureError.previewInterrupted("The connected-device video stream is in use by another app.").errorDescription,
            "Connected-device preview was interrupted: The connected-device video stream is in use by another app."
        )
        XCTAssertEqual(
            ConnectedDeviceCaptureError.noVideoFramesReceived.errorDescription,
            "No video frames were received from the connected device. Keep the device awake and unlocked, confirm Trust This Computer if prompted, then try Refresh Devices."
        )
    }

    func testConnectedDeviceCaptureErrorExplainsCameraPermissionPurpose() {
        XCTAssertEqual(
            ConnectedDeviceCaptureError.cameraPermissionNotDetermined.errorDescription,
            "Connected-device capture needs Camera access because macOS exposes trusted iPhone and iPad screens as video sources. Choose a connected device to continue."
        )
        XCTAssertEqual(
            ConnectedDeviceCaptureError.cameraPermissionDenied.errorDescription,
            "Camera access is required for connected iPhone and iPad preview, screenshots, and recordings because macOS exposes those screens as video sources."
        )
    }

    func testConnectedDeviceKindsUseExpectedMetadataValues() {
        XCTAssertEqual(CaptureKind.connectedDevice.rawValue, "connectedDevice")
        XCTAssertEqual(VideoRecordingKind.connectedDevice.rawValue, "connectedDevice")
        XCTAssertEqual(VideoRecordingKind.connectedDevice.label, "Connected Device")
    }
}
