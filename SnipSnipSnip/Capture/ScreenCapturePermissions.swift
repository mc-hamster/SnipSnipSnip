import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

nonisolated enum CapturePermissionRequirement: CaseIterable, Identifiable {
    case screenRecording
    case accessibility

    var id: String {
        switch self {
        case .screenRecording:
            return "screen-recording"
        case .accessibility:
            return "accessibility"
        }
    }

    var title: String {
        switch self {
        case .screenRecording:
            return "Screen Recording"
        case .accessibility:
            return "Accessibility"
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording:
            return "display"
        case .accessibility:
            return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }

    var requiredFor: String {
        switch self {
        case .screenRecording:
            return "Captures, recordings, and live window thumbnails."
        case .accessibility:
            return "Scrolling Capture and Window UI Map workflows."
        }
    }

    var settingsURL: URL {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }

    static func availableCases(for capabilities: AppCapabilitySnapshot) -> [CapturePermissionRequirement] {
        var requirements: [CapturePermissionRequirement] = [.screenRecording]
        if capabilities.isEnabled(.scrollingCapture) {
            requirements.append(.accessibility)
        }
        return requirements
    }
}

nonisolated struct CapturePermissionStatus: Equatable {
    let hasScreenRecording: Bool
    let hasAccessibility: Bool

    func isCaptureReady(for capabilities: AppCapabilitySnapshot) -> Bool {
        missingRequirements(for: capabilities).isEmpty
    }

    func missingRequirements(for capabilities: AppCapabilitySnapshot) -> [CapturePermissionRequirement] {
        CapturePermissionRequirement.availableCases(for: capabilities).filter { !hasAccess(to: $0) }
    }

    func hasAccess(to requirement: CapturePermissionRequirement) -> Bool {
        switch requirement {
        case .screenRecording:
            return hasScreenRecording
        case .accessibility:
            return hasAccessibility
        }
    }

    static func current() -> CapturePermissionStatus {
        return CapturePermissionStatus(
            hasScreenRecording: ScreenCapturePermissions.screenRecordingStatusProvider(),
            hasAccessibility: ScreenCapturePermissions.accessibilityStatusProvider()
        )
    }
}

enum ScreenCapturePermissions {
    nonisolated(unsafe) static var screenRecordingStatusProvider: @Sendable () -> Bool = {
        CGPreflightScreenCaptureAccess()
    }

    nonisolated(unsafe) static var accessibilityStatusProvider: @Sendable () -> Bool = {
        AXIsProcessTrusted()
    }

    nonisolated(unsafe) static var screenRecordingAccessVerifier: @Sendable () async -> Bool = {
        await verifyScreenRecordingAccessWithShareableContentProbe()
    }

    nonisolated(unsafe) static var screenRecordingAccessRequester: @Sendable () -> Bool = {
        CGRequestScreenCaptureAccess()
    }

    nonisolated(unsafe) static var accessibilityAccessRequester: @Sendable () -> Bool = {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    nonisolated(unsafe) static var systemSettingsOpener: @Sendable (CapturePermissionRequirement) -> Void = { requirement in
        NSWorkspace.shared.open(requirement.settingsURL)
    }

    static var currentAppName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? AppBranding.displayName
    }

    static var currentAppURL: URL {
        Bundle.main.bundleURL
    }

    static var currentAppPath: String {
        currentAppURL.path
    }

    nonisolated static func verifyScreenRecordingAccess() async -> Bool {
        await screenRecordingAccessVerifier()
    }

    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        screenRecordingAccessRequester()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        accessibilityAccessRequester()
    }

    @discardableResult
    static func requestAccess(for requirement: CapturePermissionRequirement) -> Bool {
        switch requirement {
        case .screenRecording:
            return requestScreenRecordingAccess()
        case .accessibility:
            return requestAccessibilityAccess()
        }
    }

    static func openSystemSettings(for requirement: CapturePermissionRequirement) {
        systemSettingsOpener(requirement)
    }

    static func revealCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([currentAppURL])
    }

    static func copyCurrentAppPathToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentAppPath, forType: .string)
    }

    nonisolated static func indicatesScreenRecordingPermissionFailure(_ error: Error) -> Bool {
        if let error = error as? ScreenCaptureError, error == .permissionDenied {
            return true
        }

        if let error = error as? ScreenRecordingError,
           case .permissionDenied = error {
            return true
        }

        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()

        if description.contains("tcc") && description.contains("capture") {
            return true
        }

        if description.contains("screen recording") && description.contains("permission") {
            return true
        }

        if description.contains("user declined") && description.contains("capture") {
            return true
        }

        return false
    }

    private static func verifyScreenRecordingAccessWithShareableContentProbe() async -> Bool {
        await withCheckedContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if error != nil {
                    continuation.resume(returning: false)
                    return
                }

                continuation.resume(returning: content != nil)
            }
        }
    }
}
