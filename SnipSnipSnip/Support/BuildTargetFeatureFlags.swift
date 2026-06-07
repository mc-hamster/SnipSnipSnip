import Foundation

/// Fastlane stamps released builds with one of these target names through
/// `SNIP_BUILD_TARGET`. Local Xcode Debug builds default to `Dev`, while
/// local Xcode Release builds default to `Release` unless overridden.
nonisolated enum BuildTarget: String {
    case release = "Release"
    case selfRelease = "Self Release"
    case internalTesting = "Internal"
    case externalTesting = "External"
    case dev = "Dev"

    static var current: BuildTarget {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "SnipBuildTarget") as? String,
              let target = BuildTarget(rawValue: rawValue) else {
            return .dev
        }

        return target
    }
}

/// Add new build-gated features here, then expose them through `FeatureFlags`.
nonisolated enum FeatureToggle {
    case presentationStyling
    case scrollingCapture
    case accessibilityAutomation
    case connectedDeviceCapture
}

/// Single source of truth for feature availability by build target.
///
/// Change this table when a feature should move between Dev, Internal,
/// External, and Release builds.
nonisolated enum BuildTargetFeatureMatrix {
    private static let enabledFeaturesByTarget: [BuildTarget: Set<FeatureToggle>] = [
        .dev: [
          .presentationStyling,
          .connectedDeviceCapture,
        ],
        .internalTesting: [
          .presentationStyling,
        ],
        .externalTesting: [
          .presentationStyling,
        ],
        .release: [
          .presentationStyling,
        ],
        .selfRelease: [
            .scrollingCapture,
            .accessibilityAutomation,
            .connectedDeviceCapture,
        ],
    ]

    static func isEnabled(_ feature: FeatureToggle, for target: BuildTarget = .current) -> Bool {
        enabledFeaturesByTarget[target, default: []].contains(feature)
    }
}

nonisolated enum FeatureFlags {
    static func presentationStylingEnabled(for target: BuildTarget = .current) -> Bool {
        BuildTargetFeatureMatrix.isEnabled(.presentationStyling, for: target)
    }

    static var presentationStylingEnabled: Bool {
        presentationStylingEnabled(for: .current)
    }

    static func scrollingCaptureEnabled(for target: BuildTarget = .current) -> Bool {
#if APP_STORE_BUILD
        false
#else
        BuildTargetFeatureMatrix.isEnabled(.scrollingCapture, for: target)
#endif
    }

    static var scrollingCaptureEnabled: Bool {
        scrollingCaptureEnabled(for: .current)
    }

    static func accessibilityAutomationEnabled(for target: BuildTarget = .current) -> Bool {
#if APP_STORE_BUILD
        false
#else
        BuildTargetFeatureMatrix.isEnabled(.accessibilityAutomation, for: target)
#endif
    }

    static var accessibilityAutomationEnabled: Bool {
        accessibilityAutomationEnabled(for: .current)
    }

    static func connectedDeviceCaptureEnabled(for target: BuildTarget = .current) -> Bool {
#if APP_STORE_BUILD
        false
#else
        BuildTargetFeatureMatrix.isEnabled(.connectedDeviceCapture, for: target)
#endif
    }

    static var connectedDeviceCaptureEnabled: Bool {
        connectedDeviceCaptureEnabled(for: .current)
    }
}

nonisolated enum AppBranding {
    static var displayName: String {
        BuildTarget.current == .selfRelease ? "SnipSnipSnip Pro" : "SnipSnipSnip"
    }

    static func branded(_ text: String) -> String {
        text.replacingOccurrences(of: "SnipSnipSnip", with: displayName)
    }
}
