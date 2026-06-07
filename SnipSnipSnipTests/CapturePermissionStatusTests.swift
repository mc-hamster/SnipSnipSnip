import XCTest
@testable import SnipSnipSnip

final class CapturePermissionStatusTests: XCTestCase {
    func testScrollingFeatureFlagsAreEnabledOnlyForSelfRelease() {
        XCTAssertFalse(FeatureFlags.scrollingCaptureEnabled(for: .dev))
        XCTAssertFalse(FeatureFlags.scrollingCaptureEnabled(for: .internalTesting))
        XCTAssertFalse(FeatureFlags.scrollingCaptureEnabled(for: .externalTesting))
        XCTAssertFalse(FeatureFlags.scrollingCaptureEnabled(for: .release))
        XCTAssertTrue(FeatureFlags.scrollingCaptureEnabled(for: .selfRelease))

        XCTAssertFalse(FeatureFlags.accessibilityAutomationEnabled(for: .dev))
        XCTAssertFalse(FeatureFlags.accessibilityAutomationEnabled(for: .internalTesting))
        XCTAssertFalse(FeatureFlags.accessibilityAutomationEnabled(for: .externalTesting))
        XCTAssertFalse(FeatureFlags.accessibilityAutomationEnabled(for: .release))
        XCTAssertTrue(FeatureFlags.accessibilityAutomationEnabled(for: .selfRelease))

        XCTAssertTrue(FeatureFlags.connectedDeviceCaptureEnabled(for: .dev))
        XCTAssertFalse(FeatureFlags.connectedDeviceCaptureEnabled(for: .internalTesting))
        XCTAssertFalse(FeatureFlags.connectedDeviceCaptureEnabled(for: .externalTesting))
        XCTAssertFalse(FeatureFlags.connectedDeviceCaptureEnabled(for: .release))
        XCTAssertTrue(FeatureFlags.connectedDeviceCaptureEnabled(for: .selfRelease))
    }

    func testCaptureReadyRequiresScreenRecordingOnlyWhenScrollingFeatureDisabled() {
        let releaseTarget = BuildTarget.release

        XCTAssertTrue(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true).isCaptureReady(for: releaseTarget))
        XCTAssertTrue(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false).isCaptureReady(for: releaseTarget))
        XCTAssertFalse(CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true).isCaptureReady(for: releaseTarget))
        XCTAssertFalse(CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false).isCaptureReady(for: releaseTarget))
    }

    func testMissingRequirementsReflectReleasePermissionModel() {
        let releaseTarget = BuildTarget.release

        XCTAssertEqual(
            CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true).missingRequirements(for: releaseTarget),
            [.screenRecording]
        )
        XCTAssertEqual(
            CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false).missingRequirements(for: releaseTarget),
            []
        )
        XCTAssertEqual(
            CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false).missingRequirements(for: releaseTarget),
            [.screenRecording]
        )
    }
}
