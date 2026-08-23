import Foundation

nonisolated enum OnboardingPresentationMode: Equatable {
    case firstRun
    case replay
}

nonisolated enum OnboardingResumeCheckpoint: String {
    case clipboard

    // Retained so an interrupted setup from the earlier onboarding flow can
    // still resume safely after updating.
    case firstSnip

    var currentStep: OnboardingResumeCheckpoint {
        switch self {
        case .clipboard, .firstSnip:
            return .clipboard
        }
    }
}

nonisolated enum OnboardingCompletionPolicy {
    static func canComplete(
        mode: OnboardingPresentationMode,
        hasScreenRecording: Bool,
        hasMadeClipboardChoice: Bool
    ) -> Bool {
        mode == .replay || (hasScreenRecording && hasMadeClipboardChoice)
    }
}

enum LastCaptureRequest {
    case region(CGRect)
    case scrolling(CGRect)
    case window(CaptureWindowSummary)
    case frontmostWindow
    case fullscreen
    case connectedDevice(ConnectedAppleDevice)

    var canIncludeWindowUIMap: Bool {
        switch self {
        case .window, .frontmostWindow:
            return true
        case .region, .scrolling, .fullscreen, .connectedDevice:
            return false
        }
    }
}

nonisolated struct UIMapCaptureEligibility: Equatable, Sendable {
    var featureFlagEnabled: Bool
    var userEnabled: Bool
    var captureKind: CaptureKind
    var hasSourceWindowIdentity: Bool
    var hasAccessibility: Bool

    var isWindowCapture: Bool {
        captureKind == .window
    }

    var canAttemptCapture: Bool {
        featureFlagEnabled
            && userEnabled
            && isWindowCapture
            && hasSourceWindowIdentity
    }

    var shouldCapture: Bool {
        canAttemptCapture && hasAccessibility
    }

    var needsAccessibilityAccess: Bool {
        canAttemptCapture && !hasAccessibility
    }

    var skipReason: String? {
        if !featureFlagEnabled {
            return "feature flag disabled"
        }

        if !userEnabled {
            return "user preference disabled"
        }

        if !isWindowCapture {
            return "UI Map is limited to Window captures"
        }

        if !hasSourceWindowIdentity {
            return "window capture has no source window identity"
        }

        if !hasAccessibility {
            return "Accessibility access missing"
        }

        return nil
    }
}

enum WindowPickerMode {
    case screenshot
    case videoRecording
    case capturePresetReplacement(CapturePreset.ID)
}

enum AppSettingsTab: Hashable, CaseIterable {
    case general
    case capture
    case presets
    case editorOutput
    case shortcuts
    case recording
    case guide
    case library
    case privacy
}

enum LibrarySettingsSection: String, CaseIterable, Identifiable {
    case snips
    case clipboard

    var id: String { rawValue }
    var title: String {
        switch self {
        case .snips: "Snips"
        case .clipboard: "Clipboard"
        }
    }
}

struct PermissionSetupGuide: Identifiable {
    let id = UUID()
    let requirement: CapturePermissionRequirement
    let appName: String
    let appPath: String
}

struct InteractiveCaptureAutosaveSuspension {
    let editorControllerID: ObjectIdentifier?
}

enum EditableRedactionSaveDecision {
    case saveEditable
    case exportFlattenedPNG
    case cancel
}

enum DocumentFormatMigrationDecision {
    case saveV7
    case saveCopy
    case cancel
}

nonisolated enum AppModelPreferenceKey {
    static let autoCopyEnabled = "appModel.autoCopyEnabled"
    static let autoRefreshWindowsEnabled = "appModel.autoRefreshWindowsEnabled"
    static let archiveLocationBookmarkData = "appModel.archiveLocationBookmarkData"
    static let archiveLocationPath = "appModel.archiveLocationPath"
    static let archiveMaximumSizeMB = "appModel.archiveMaximumSizeMB"
    static let captureAutomationPreferences = "appModel.captureAutomationPreferences"
    static let captureDelay = "appModel.captureDelay"
    static let capturePresets = "appModel.capturePresets"
    static let clipboardPreferences = "appModel.clipboardPreferences"
    static let screenshotIncludesCursor = "appModel.screenshotIncludesCursor"
    static let screenshotFullscreenDisplayMode = "appModel.screenshotFullscreenDisplayMode"
    static let selectedScreenshotFullscreenDisplayID = "appModel.selectedScreenshotFullscreenDisplayID"
    static let screenshotJPEGQuality = "appModel.screenshotJPEGQuality"
    static let editorSingleKeyToolShortcutsEnabled = "appModel.editorSingleKeyToolShortcutsEnabled"
    static let editorStartupToolPreference = "appModel.editorStartupToolPreference"
    static let editorLastUsedTool = "appModel.editorLastUsedTool"
    static let completedOnboardingVersion = "appModel.completedOnboardingVersion"
    static let onboardingResumeCheckpoint = "appModel.onboardingResumeCheckpoint"
    static let onboardingClipboardChoiceAcknowledged = "appModel.onboardingClipboardChoiceAcknowledged"
    static let editorCropOutsideOverlayAlpha = "appModel.editorCropOutsideOverlayAlpha"
    static let editorOutOfCapturePatternSettings = "appModel.editorOutOfCapturePatternSettings"
    static let presentationScenesRootPath = "appModel.presentationScenesRootPath"
    static let uiMapPinnedOverlayDefaults = "appModel.uiMapPinnedOverlayDefaults"
    static let hasDismissedWelcomeCard = "appModel.hasDismissedWelcomeCard"
    static let hasPresentedWelcomeWindow = "appModel.hasPresentedWelcomeWindow"
    static let hasPresentedGuideDocumentProNotice = "appModel.hasPresentedGuideDocumentProNotice"
    static let regionCaptureOverlayMode = "appModel.regionCaptureOverlayMode"
    static let regionCaptureShowsActionControls = "appModel.regionCaptureShowsActionControls"
    static let regionCaptureAdvancedControlsEnabled = "appModel.regionCaptureAdvancedControlsEnabled"
    static let recycleBinRetentionDays = "appModel.recycleBinRetentionDays"
    static let recycleBinRetentionDefaultMigrationCompleted = "appModel.recycleBinRetentionDefaultMigrationCompleted"
    static let screenInspectorPreferences = "appModel.screenInspectorPreferences"
    static let screenRulerPreferences = "appModel.screenRulerPreferences"
    static let screenshotFilenameTemplate = "appModel.screenshotFilenameTemplate"
    static let screenshotDragOutFormat = "appModel.screenshotDragOutFormat"
    static let privateCaptureEnabled = "appModel.privateCaptureEnabled"
    static let quickControlsPreferences = "appModel.quickControlsPreferences"
    static let uiMapEnabled = "appModel.uiMapEnabled"
    static let videoExportPreferences = "appModel.videoExportPreferences"
    static let videoRecordingPreferences = "appModel.videoRecordingPreferences"
}

nonisolated struct EditorOutOfCapturePatternSettings: Codable, Equatable {
    nonisolated static let `default` = EditorOutOfCapturePatternSettings(
        isEnabled: true,
        spacing: 34,
        lineOpacity: 0.10,
        dotOpacity: 0.10,
        dotDiameter: 5
    )

    var isEnabled: Bool
    var spacing: CGFloat
    var lineOpacity: CGFloat
    var dotOpacity: CGFloat
    var dotDiameter: CGFloat

    var spacingDescription: String {
        "\(Int(round(spacing))) px"
    }

    var lineOpacityDescription: String {
        String(format: "%d%%", Int(round(lineOpacity * 100)))
    }

    var dotOpacityDescription: String {
        String(format: "%d%%", Int(round(dotOpacity * 100)))
    }

    var dotDiameterDescription: String {
        "\(Int(round(dotDiameter))) px"
    }
}
