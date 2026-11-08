import CoreGraphics
import Foundation

/// Explicit selection includes app panels; automatic frontmost capture keeps
/// its established normal-window behavior. Neither policy requires Accessibility.
nonisolated enum WindowCaptureEligibility {
    case explicitWindow
    case automaticFrontmost

    func allows(_ window: ScreenWindowSnapshot, excluding processID: pid_t) -> Bool {
        guard window.ownerPID != processID,
              window.isOnScreen,
              window.frame.width >= 60, window.frame.height >= 40 else {
            return false
        }

        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        switch self {
        case .automaticFrontmost:
            return window.layer == normalLevel
        case .explicitWindow:
            guard window.ownerPID > 0,
                  window.frame.minX.isFinite, window.frame.minY.isFinite,
                  window.frame.width.isFinite, window.frame.height.isFinite,
                  !Self.isSystemSurfaceOwner(window) else {
                return false
            }
            // Include floating, modal, utility, and custom app levels below the
            // Dock. Desktop levels and higher menu/overlay levels remain excluded.
            return window.layer >= normalLevel && window.layer < Int(CGWindowLevelForKey(.dockWindow))
        }
    }

    private static func isSystemSurfaceOwner(_ window: ScreenWindowSnapshot) -> Bool {
        let bundleID = window.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !bundleID.isEmpty {
            return systemSurfaceBundleIDs.contains(bundleID)
        }
        // Some WindowServer records lack an application bundle identifier.
        // Only use the owner-name fallback when that stronger identity is absent.
        return systemSurfaceOwnerNames.contains(window.ownerName.lowercased())
    }

    private static let systemSurfaceBundleIDs: Set<String> = [
        "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.windowmanager", "com.apple.windowserver", "com.apple.loginwindow",
        "com.apple.notificationcenterui", "com.apple.spotlight"
    ]

    private static let systemSurfaceOwnerNames: Set<String> = [
        "dock", "systemuiserver", "controlcenter", "control center",
        "windowmanager", "windowserver", "window server", "loginwindow",
        "notificationcenter", "notification center", "spotlight"
    ]
}
