import AppKit
import Foundation

struct SupportDiagnostics: Codable, Equatable {
    struct AppInfo: Codable, Equatable {
        let name: String
        let version: String
        let build: String
        let bundleIdentifier: String
        let buildTarget: String
    }

    struct SystemInfo: Codable, Equatable {
        let macOSVersion: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
    }

    struct FeatureFlagInfo: Codable, Equatable {
        let presentationStyling: Bool
        let scrollingCapture: Bool
        let accessibilityAutomation: Bool
        let connectedDeviceCapture: Bool
    }

    struct PermissionInfo: Codable, Equatable {
        let screenRecording: Bool
        let accessibility: Bool
        let captureReady: Bool
        let missingRequirements: [String]
    }

    struct DisplayInfo: Codable, Equatable {
        let count: Int
        let displays: [Display]

        struct Display: Codable, Equatable {
            let index: Int
            let pixelWidth: Int
            let pixelHeight: Int
            let scale: Double
            let isMain: Bool
        }
    }

    struct StorageInfo: Codable, Equatable {
        let archiveMaximumSizeMB: Int
        let archiveCurrentSizeLabel: String
        let archiveUsesDefaultLocation: Bool
        let recycleBinItemCount: Int
        let recycleBinRetentionDays: Int
        let clipboardHistoryEnabled: Bool
        let clipboardItemCount: Int
        let clipboardMaximumItems: Int
        let clipboardMaximumStorageMB: Int
    }

    struct EditorInfo: Codable, Equatable {
        let hasScreenshotEditor: Bool
        let annotationCount: Int
        let selectedAnnotationCount: Int
        let hasVideoEditor: Bool
        let isRecordingVideo: Bool
        let activeVideoRecordingKind: String?
    }

    struct RecentStatusInfo: Codable, Equatable {
        let appError: String?
        let editorError: String?
        let videoError: String?
        let launchAtLoginStatus: String
        let workingMessage: String?
    }

    let generatedAt: Date
    let app: AppInfo
    let system: SystemInfo
    let features: FeatureFlagInfo
    let permissions: PermissionInfo
    let displays: DisplayInfo
    let storage: StorageInfo
    let editor: EditorInfo
    let recentStatus: RecentStatusInfo

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

enum SupportDiagnosticsBuilder {
    @MainActor
    static func make(model: AppModel, generatedAt: Date = Date()) -> SupportDiagnostics {
        SupportDiagnostics(
            generatedAt: generatedAt,
            app: appInfo(),
            system: systemInfo(),
            features: featureInfo(),
            permissions: permissionInfo(from: model),
            displays: displayInfo(),
            storage: storageInfo(from: model),
            editor: editorInfo(from: model),
            recentStatus: recentStatusInfo(from: model)
        )
    }

    private static func appInfo() -> SupportDiagnostics.AppInfo {
        let bundle = Bundle.main
        return SupportDiagnostics.AppInfo(
            name: AppBranding.displayName,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            buildTarget: BuildTarget.current.rawValue
        )
    }

    private static func systemInfo() -> SupportDiagnostics.SystemInfo {
        let processInfo = ProcessInfo.processInfo
        return SupportDiagnostics.SystemInfo(
            macOSVersion: processInfo.operatingSystemVersionString,
            processorCount: processInfo.processorCount,
            physicalMemoryBytes: processInfo.physicalMemory
        )
    }

    private static func featureInfo() -> SupportDiagnostics.FeatureFlagInfo {
        SupportDiagnostics.FeatureFlagInfo(
            presentationStyling: FeatureFlags.presentationStylingEnabled,
            scrollingCapture: FeatureFlags.scrollingCaptureEnabled,
            accessibilityAutomation: FeatureFlags.accessibilityAutomationEnabled,
            connectedDeviceCapture: FeatureFlags.connectedDeviceCaptureEnabled
        )
    }

    @MainActor
    private static func permissionInfo(from model: AppModel) -> SupportDiagnostics.PermissionInfo {
        SupportDiagnostics.PermissionInfo(
            screenRecording: model.permissionStatus.hasScreenRecording,
            accessibility: model.permissionStatus.hasAccessibility,
            captureReady: model.permissionStatus.isCaptureReady,
            missingRequirements: model.permissionStatus.missingRequirements.map(\.title)
        )
    }

    @MainActor
    private static func displayInfo() -> SupportDiagnostics.DisplayInfo {
        let displays = NSScreen.screens.enumerated().map { index, screen in
            SupportDiagnostics.DisplayInfo.Display(
                index: index + 1,
                pixelWidth: Int((screen.frame.width * screen.backingScaleFactor).rounded()),
                pixelHeight: Int((screen.frame.height * screen.backingScaleFactor).rounded()),
                scale: Double(screen.backingScaleFactor),
                isMain: screen == NSScreen.main
            )
        }

        return SupportDiagnostics.DisplayInfo(count: displays.count, displays: displays)
    }

    @MainActor
    private static func storageInfo(from model: AppModel) -> SupportDiagnostics.StorageInfo {
        SupportDiagnostics.StorageInfo(
            archiveMaximumSizeMB: model.archiveMaximumSizeMB,
            archiveCurrentSizeLabel: model.archiveSizeLabel,
            archiveUsesDefaultLocation: model.usesDefaultArchiveLocation,
            recycleBinItemCount: model.recycleBinEntries.count,
            recycleBinRetentionDays: model.recycleBinRetentionDays,
            clipboardHistoryEnabled: model.clipboardPreferences.isEnabled,
            clipboardItemCount: model.clipboardHistoryItems.count,
            clipboardMaximumItems: model.clipboardPreferences.maxItemCount,
            clipboardMaximumStorageMB: model.clipboardPreferences.maxStorageMB
        )
    }

    @MainActor
    private static func editorInfo(from model: AppModel) -> SupportDiagnostics.EditorInfo {
        SupportDiagnostics.EditorInfo(
            hasScreenshotEditor: model.editorController != nil,
            annotationCount: model.editorController?.snapshot.annotations.count ?? 0,
            selectedAnnotationCount: model.editorController?.selectedCount ?? 0,
            hasVideoEditor: model.videoEditorController != nil,
            isRecordingVideo: model.isRecordingVideo,
            activeVideoRecordingKind: model.activeVideoRecording == nil ? nil : "active"
        )
    }

    @MainActor
    private static func recentStatusInfo(from model: AppModel) -> SupportDiagnostics.RecentStatusInfo {
        SupportDiagnostics.RecentStatusInfo(
            appError: sanitizedStatus(model.errorMessage),
            editorError: sanitizedStatus(model.editorController?.errorMessage),
            videoError: sanitizedStatus(model.videoEditorController?.errorMessage),
            launchAtLoginStatus: model.launchAtLoginStatus.stateLabel,
            workingMessage: model.isWorking ? sanitizedStatus(model.workingMessage) : nil
        )
    }

    private static func sanitizedStatus(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let withoutPaths = trimmed.replacingOccurrences(
            of: #"(/Users|/Volumes|/private|/tmp)/[^\s]+"#,
            with: "[path]",
            options: .regularExpression
        )

        if withoutPaths.count <= 240 {
            return withoutPaths
        }

        let endIndex = withoutPaths.index(withoutPaths.startIndex, offsetBy: 240)
        return String(withoutPaths[..<endIndex]) + "..."
    }
}
