import Foundation

/// Fastlane stamps released builds with one of these target names through
/// `SNIP_BUILD_TARGET`. Local Xcode Debug builds default to `Dev`, while
/// local Xcode Release builds default to `Release` unless overridden.
nonisolated enum BuildTarget: String, Sendable {
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

/// Compatibility-only build-gated feature identifiers.
///
/// New app code should depend on `AppEnvironment.capabilities`; keep
/// `FeatureFlags` as a bridge for legacy tests and compatibility callsites.
nonisolated enum FeatureToggle: Sendable {
    case scrollingCapture
    case accessibilityAutomation
    case connectedDeviceCapture
    case uiMap
    case proUpdateCheck
}

/// Single source of truth for feature availability by build target.
///
/// Change this table when a feature should move between Dev, Internal,
/// External, and Release builds.
nonisolated enum BuildTargetFeatureMatrix {
    private static let enabledFeaturesByTarget: [BuildTarget: Set<FeatureToggle>] = [
        .dev: [
          .connectedDeviceCapture,
          .uiMap,
        ],
        .internalTesting: [],
        .externalTesting: [],
        .release: [],
        .selfRelease: [
            .scrollingCapture,
            .accessibilityAutomation,
            .connectedDeviceCapture,
            .uiMap,
            .proUpdateCheck,
        ],
    ]

    static func isEnabled(_ feature: FeatureToggle, for target: BuildTarget = .current) -> Bool {
        enabledFeaturesByTarget[target, default: []].contains(feature)
    }
}

nonisolated enum FeatureFlags {
    private static let capabilityProvider = BuildTargetCapabilityProvider()

    static func scrollingCaptureEnabled(for target: BuildTarget = .current) -> Bool {
        capabilityProvider.snapshot(for: target).isEnabled(.scrollingCapture)
    }

    static var scrollingCaptureEnabled: Bool {
        scrollingCaptureEnabled(for: .current)
    }

    static func accessibilityAutomationEnabled(for target: BuildTarget = .current) -> Bool {
        capabilityProvider.snapshot(for: target).isEnabled(.accessibilityAutomation)
    }

    static var accessibilityAutomationEnabled: Bool {
        accessibilityAutomationEnabled(for: .current)
    }

    static func connectedDeviceCaptureEnabled(for target: BuildTarget = .current) -> Bool {
        capabilityProvider.snapshot(for: target).isEnabled(.connectedDeviceCapture)
    }

    static var connectedDeviceCaptureEnabled: Bool {
        connectedDeviceCaptureEnabled(for: .current)
    }

    static func uiMapEnabled(for target: BuildTarget = .current) -> Bool {
        capabilityProvider.snapshot(for: target).isEnabled(.uiMap)
    }

    static var uiMapEnabled: Bool {
        uiMapEnabled(for: .current)
    }

    static func proUpdateCheckEnabled(for target: BuildTarget = .current) -> Bool {
        capabilityProvider.snapshot(for: target).isEnabled(.proUpdateCheck)
    }

    static var proUpdateCheckEnabled: Bool {
        proUpdateCheckEnabled(for: .current)
    }
}

nonisolated enum AppBranding {
    private static let standardDisplayName = "SnipSnipSnip"
    private static let proDisplayName = "SnipSnipSnip Pro"

    static var displayName: String {
        displayName(for: .current)
    }

    static func displayName(for target: BuildTarget) -> String {
        target == .selfRelease ? proDisplayName : standardDisplayName
    }

    static func branded(_ text: String, for target: BuildTarget = .current) -> String {
        let targetDisplayName = displayName(for: target)
        guard targetDisplayName != standardDisplayName else {
            return text
        }

        var result = ""
        var searchStart = text.startIndex

        while let range = text[searchStart...].range(of: standardDisplayName) {
            result.append(contentsOf: text[searchStart..<range.lowerBound])
            result.append(contentsOf: text[range.upperBound...].hasPrefix(" Pro") ? standardDisplayName : targetDisplayName)
            searchStart = range.upperBound
        }

        result.append(contentsOf: text[searchStart...])
        return result
    }
}
