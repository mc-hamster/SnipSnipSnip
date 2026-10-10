import Foundation

/// UI visibility follows supported features, including when preferences were
/// saved by another edition. This never checks or requests native permission.
nonisolated enum PermissionSettingsAvailability {
    static func showsAccessibility(
        capabilities: AppCapabilitySnapshot,
        uiMapEnabled: Bool,
        recordsKeyboardShortcuts: Bool
    ) -> Bool {
        capabilities.isEnabled(.scrollingCapture)
            || capabilities.isEnabled(.guideCapture)
            || (capabilities.isEnabled(.uiMap) && uiMapEnabled)
            || (capabilities.isEnabled(.videoShortcutCapture) && recordsKeyboardShortcuts)
    }
}
