import XCTest
@testable import SnipSnipSnip

final class CapturePermissionStatusTests: XCTestCase {
    func testAppBrandingDisplayNameReflectsBuildTarget() {
        XCTAssertEqual(AppBranding.displayName(for: .release), "SnipSnipSnip")
        XCTAssertEqual(AppBranding.displayName(for: .selfRelease), "SnipSnipSnip Pro")
    }

    func testAppBrandingDoesNotDuplicateExistingProSuffix() {
        XCTAssertEqual(
            AppBranding.branded("Welcome to SnipSnipSnip", for: .selfRelease),
            "Welcome to SnipSnipSnip Pro"
        )
        XCTAssertEqual(
            AppBranding.branded("Update SnipSnipSnip Pro from GitHub", for: .selfRelease),
            "Update SnipSnipSnip Pro from GitHub"
        )
        XCTAssertEqual(
            AppBranding.branded("Open SnipSnipSnip from SnipSnipSnip Pro", for: .selfRelease),
            "Open SnipSnipSnip Pro from SnipSnipSnip Pro"
        )
    }

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

        XCTAssertTrue(FeatureFlags.uiMapEnabled(for: .dev))
        XCTAssertFalse(FeatureFlags.uiMapEnabled(for: .internalTesting))
        XCTAssertFalse(FeatureFlags.uiMapEnabled(for: .externalTesting))
        XCTAssertFalse(FeatureFlags.uiMapEnabled(for: .release))
        XCTAssertTrue(FeatureFlags.uiMapEnabled(for: .selfRelease))
    }

    func testCaptureReadyRequiresScreenRecordingOnlyWhenScrollingFeatureDisabled() {
        let releaseCapabilities = BuildTargetCapabilityProvider().snapshot(for: .release)

        XCTAssertTrue(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true).isCaptureReady(for: releaseCapabilities))
        XCTAssertTrue(CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false).isCaptureReady(for: releaseCapabilities))
        XCTAssertFalse(CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true).isCaptureReady(for: releaseCapabilities))
        XCTAssertFalse(CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false).isCaptureReady(for: releaseCapabilities))
    }

    func testMissingRequirementsReflectReleasePermissionModel() {
        let releaseCapabilities = BuildTargetCapabilityProvider().snapshot(for: .release)

        XCTAssertEqual(
            CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true).missingRequirements(for: releaseCapabilities),
            [.screenRecording]
        )
        XCTAssertEqual(
            CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false).missingRequirements(for: releaseCapabilities),
            []
        )
        XCTAssertEqual(
            CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false).missingRequirements(for: releaseCapabilities),
            [.screenRecording]
        )
    }
}
