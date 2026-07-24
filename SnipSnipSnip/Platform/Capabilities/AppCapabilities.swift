import Foundation

nonisolated enum AppCapability: String, CaseIterable, Hashable, Sendable {
    case regionCapture
    case windowCapture
    case frontmostWindowCapture
    case fullscreenCapture
    case repeatCapture
    case timerCapture
    case scrollingCapture
    case connectedDeviceCapture
    case editor
    case presentation
    case clipboardHistory
    case automation
    case privateCapture
    case uiMap
    case accessibilityAutomation
    case screenRecording
    case guideCapture
    case screenRuler
    case screenInspector
    case archive
    case recovery
    case export
    case proUpdateCheck
}

nonisolated struct AppCapabilitySnapshot: Equatable, Sendable {
    let buildTarget: BuildTarget
    private let enabledCapabilities: Set<AppCapability>

    init(buildTarget: BuildTarget, enabledCapabilities: Set<AppCapability>) {
        self.buildTarget = buildTarget
        self.enabledCapabilities = enabledCapabilities
    }

    func isEnabled(_ capability: AppCapability) -> Bool {
        enabledCapabilities.contains(capability)
    }

    func contains(_ capability: AppCapability) -> Bool {
        isEnabled(capability)
    }
}

nonisolated protocol AppCapabilityProvider {
    func snapshot(for target: BuildTarget) -> AppCapabilitySnapshot
}

nonisolated struct BuildTargetCapabilityProvider: AppCapabilityProvider {
    init() {}

    func snapshot(for target: BuildTarget = .current) -> AppCapabilitySnapshot {
        var enabled = Self.alwaysEnabledCapabilities

        if isBuildGatedFeatureEnabled(.scrollingCapture, for: target) {
            enabled.insert(.scrollingCapture)
        }

        if isBuildGatedFeatureEnabled(.accessibilityAutomation, for: target) {
            enabled.insert(.accessibilityAutomation)
        }

        if isBuildGatedFeatureEnabled(.connectedDeviceCapture, for: target) {
            enabled.insert(.connectedDeviceCapture)
        }

        if isBuildGatedFeatureEnabled(.uiMap, for: target) {
            enabled.insert(.uiMap)
        }

        if isBuildGatedFeatureEnabled(.guideCapture, for: target) {
            enabled.insert(.guideCapture)
        }

        if isBuildGatedFeatureEnabled(.proUpdateCheck, for: target) {
            enabled.insert(.proUpdateCheck)
        }

        return AppCapabilitySnapshot(buildTarget: target, enabledCapabilities: enabled)
    }

    func currentSnapshot() -> AppCapabilitySnapshot {
        snapshot(for: .current)
    }

    private static let alwaysEnabledCapabilities: Set<AppCapability> = [
        .regionCapture,
        .windowCapture,
        .frontmostWindowCapture,
        .fullscreenCapture,
        .repeatCapture,
        .timerCapture,
        .editor,
        .presentation,
        .clipboardHistory,
        .automation,
        .privateCapture,
        .screenRecording,
        .screenRuler,
        .screenInspector,
        .archive,
        .recovery,
        .export,
    ]

    private func isBuildGatedFeatureEnabled(_ feature: FeatureToggle, for target: BuildTarget) -> Bool {
#if APP_STORE_BUILD
        false
#else
        BuildTargetFeatureMatrix.isEnabled(feature, for: target)
#endif
    }
}
