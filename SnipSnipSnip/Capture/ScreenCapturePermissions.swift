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
            return "Scrolling Capture, so SnipSnipSnip can scroll the selected app while capturing."
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

    static func availableCases(for target: BuildTarget = .current) -> [CapturePermissionRequirement] {
        var requirements: [CapturePermissionRequirement] = [.screenRecording]
        if FeatureFlags.scrollingCaptureEnabled(for: target) {
            requirements.append(.accessibility)
        }
        return requirements
    }

    static var availableCases: [CapturePermissionRequirement] {
        availableCases(for: .current)
    }
}

nonisolated struct CapturePermissionStatus: Equatable {
    let hasScreenRecording: Bool
    let hasAccessibility: Bool

    private func availableRequirements(for target: BuildTarget = .current) -> [CapturePermissionRequirement] {
        CapturePermissionRequirement.availableCases(for: target)
    }

    var isCaptureReady: Bool {
        isCaptureReady(for: .current)
    }

    func isCaptureReady(for target: BuildTarget = .current) -> Bool {
        missingRequirements(for: target).isEmpty
    }

    var missingRequirements: [CapturePermissionRequirement] {
        missingRequirements(for: .current)
    }

    func missingRequirements(for target: BuildTarget = .current) -> [CapturePermissionRequirement] {
        availableRequirements(for: target).filter { !hasAccess(to: $0) }
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

    static var currentAppName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "SnipSnipSnip"
    }

    static var currentAppURL: URL {
        Bundle.main.bundleURL
    }

    static var currentAppPath: String {
        currentAppURL.path
    }

    static func verifyScreenRecordingAccess() async -> Bool {
        await screenRecordingAccessVerifier()
    }

    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestAccess(for requirement: CapturePermissionRequirement) -> Bool {
        switch requirement {
        case .screenRecording:
            return requestScreenRecordingAccess()
        case .accessibility:
            guard FeatureFlags.accessibilityAutomationEnabled || FeatureFlags.uiMapEnabled else {
                return false
            }
            return requestAccessibilityAccess()
        }
    }

    static func openSystemSettings(for requirement: CapturePermissionRequirement) {
        NSWorkspace.shared.open(requirement.settingsURL)
    }

    static func revealCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([currentAppURL])
    }

    static func copyCurrentAppPathToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentAppPath, forType: .string)
    }

    static func indicatesScreenRecordingPermissionFailure(_ error: Error) -> Bool {
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
