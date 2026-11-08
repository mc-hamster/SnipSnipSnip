import AppKit
#if !APP_STORE_BUILD
@preconcurrency import ApplicationServices
#endif
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
            return "accessibility"
        }
    }

    var requiredFor: String {
        switch self {
        case .screenRecording:
            return "Captures, recordings, and live window thumbnails."
        case .accessibility:
            return "Guide and other Accessibility-assisted workflows."
        }
    }

    var settingsPaneTitle: String {
        self == .screenRecording ? "Screen & System Audio Recording" : "Accessibility"
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
        if capabilities.isEnabled(.scrollingCapture)
            || capabilities.isEnabled(.accessibilityAutomation)
            || capabilities.isEnabled(.uiMap)
            || capabilities.isEnabled(.guideCapture) {
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

nonisolated enum ScreenRecordingAccessProbeResult: Equatable, Sendable {
    case available
    case permissionDenied
    case unavailable(domain: String, code: Int)

    var isAvailable: Bool { self == .available }
}

enum ScreenCapturePermissions {
    nonisolated(unsafe) static var screenRecordingStatusProvider: @Sendable () -> Bool = {
        CGPreflightScreenCaptureAccess()
    }

    nonisolated(unsafe) static var accessibilityStatusProvider: @Sendable () -> Bool = {
#if APP_STORE_BUILD
        false
#else
        AXIsProcessTrusted()
#endif
    }

    nonisolated(unsafe) static var screenRecordingAccessProbe: @Sendable () async -> ScreenRecordingAccessProbeResult = {
        await verifyScreenRecordingAccessWithShareableContentProbe()
    }

    // Boolean compatibility for existing clients. The workflow uses the typed
    // probe so a transport failure cannot masquerade as a permission denial.
    nonisolated static var screenRecordingAccessVerifier: @Sendable () async -> Bool {
        get {
            let probe = screenRecordingAccessProbe
            return { await probe().isAvailable }
        }
        set {
            screenRecordingAccessProbe = { await newValue() ? .available : .permissionDenied }
        }
    }

    nonisolated(unsafe) static var screenRecordingAccessRequester: @Sendable () -> Bool = {
        CGRequestScreenCaptureAccess()
    }

    nonisolated(unsafe) static var accessibilityAccessRequester: @Sendable () -> Bool = {
#if APP_STORE_BUILD
        false
#else
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
#endif
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

    nonisolated static func probeScreenRecordingAccess() async -> ScreenRecordingAccessProbeResult {
        await screenRecordingAccessProbe()
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
        if nsError.domain == SCStreamErrorDomain {
            // Known framework codes take precedence over translated prose.
            return nsError.code == SCStreamError.Code.userDeclined.rawValue
        }
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

    nonisolated static func classifyScreenRecordingProbe(hasContent: Bool, error: Error?) -> ScreenRecordingAccessProbeResult {
        if let error {
            let nativeError = error as NSError
            if nativeError.domain == SCStreamErrorDomain && nativeError.code == SCStreamError.Code.userDeclined.rawValue {
                return .permissionDenied
            }
            return .unavailable(domain: nativeError.domain, code: nativeError.code)
        }
        return hasContent ? .available : .unavailable(domain: "ScreenCaptureKit", code: 0)
    }

    private static func verifyScreenRecordingAccessWithShareableContentProbe() async -> ScreenRecordingAccessProbeResult {
        await withCheckedContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                continuation.resume(returning: classifyScreenRecordingProbe(hasContent: content != nil, error: error))
            }
        }
    }
}
