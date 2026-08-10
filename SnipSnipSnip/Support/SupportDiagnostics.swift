import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum SupportDiagnosticsExporter {
    static func export(
        snapshot: SupportDiagnosticsSnapshot,
        clock: any ClockProviding,
        presentError: (Error) -> Void
    ) {
        let diagnostics = SupportDiagnosticsBuilder.make(snapshot: snapshot, generatedAt: clock.now())
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.nameFieldStringValue = "SnipSnipSnip-Diagnostics-\(diagnosticsTimestamp(clock: clock)).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try diagnostics.jsonData().write(to: url, options: .atomic)
        } catch {
            presentError(error)
        }
    }

    private static func diagnosticsTimestamp(clock: any ClockProviding) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: clock.now())
    }
}

@MainActor
struct SupportDiagnosticsSnapshot {
    let capabilities: AppCapabilitySnapshot
    let permissionStatus: CapturePermissionStatus
    let missingPermissionRequirements: [CapturePermissionRequirement]
    let displays: [ScreenDisplaySnapshot]
    let mainDisplayID: CGDirectDisplayID?
    let archiveMaximumSizeMB: Int
    let archiveCurrentSizeLabel: String
    let archiveUsesDefaultLocation: Bool
    let recycleBinItemCount: Int
    let recycleBinRetentionDays: Int
    let clipboardHistoryEnabled: Bool
    let clipboardItemCount: Int
    let clipboardMaximumItems: Int
    let clipboardMaximumStorageMB: Int
    let hasScreenshotEditor: Bool
    let annotationCount: Int
    let selectedAnnotationCount: Int
    let hasVideoEditor: Bool
    let isRecordingVideo: Bool
    let activeVideoRecordingKind: String?
    let connectedDeviceFeatureEnabled: Bool
    let listedDeviceCount: Int
    let previewSessionActive: Bool
    let isLoadingDevices: Bool
    let connectedDeviceEmptyStateMessage: String?
    let appError: String?
    let editorError: String?
    let videoError: String?
    let launchAtLoginStatus: String
    let workingMessage: String?
    let guideState: String
    let guideStepCount: Int
    let guideSourceKind: String?
    let guideSourceVideoEnabled: Bool
    let guideStorageEstimateMB: Int
    let guideLastFailureCategory: String?
    let guideExporterStatus: String

    static func make(
        capabilities: AppCapabilitySnapshot,
        permissions: any CapturePermissionServicing,
        systemServices: AppSystemServices,
        lifecycle: AppLifecycleModel,
        permissionWorkflow: PermissionWorkflowModel,
        capture: CaptureWorkflowModel,
        documents: DocumentWorkflowModel,
        clipboard: ClipboardWorkflowModel,
        video: VideoWorkflowModel,
        guide: GuideWorkflowModel? = nil,
        archive: ArchiveWorkflowModel
    ) -> SupportDiagnosticsSnapshot {
        let permissionStatus = permissionWorkflow.permissionStatus
        let missingRequirements = permissions.availableSetupRequirements().filter {
            !permissionStatus.hasAccess(to: $0)
        }
        let editorController = documents.editorController
        let videoEditorController = documents.videoEditorController

        return SupportDiagnosticsSnapshot(
            capabilities: capabilities,
            permissionStatus: permissionStatus,
            missingPermissionRequirements: missingRequirements,
            displays: systemServices.screens.screens,
            mainDisplayID: systemServices.screens.mainScreen?.displayID,
            archiveMaximumSizeMB: archive.maximumSizeMB,
            archiveCurrentSizeLabel: archive.archiveSizeLabel,
            archiveUsesDefaultLocation: archive.usesDefaultArchiveLocation,
            recycleBinItemCount: documents.recycleBinEntries.count,
            recycleBinRetentionDays: archive.recycleBinRetentionDays,
            clipboardHistoryEnabled: clipboard.preferences.isEnabled,
            clipboardItemCount: clipboard.items.count,
            clipboardMaximumItems: clipboard.preferences.maxItemCount,
            clipboardMaximumStorageMB: clipboard.preferences.maxStorageMB,
            hasScreenshotEditor: editorController != nil,
            annotationCount: editorController?.snapshot.annotations.count ?? 0,
            selectedAnnotationCount: editorController?.selectedCount ?? 0,
            hasVideoEditor: videoEditorController != nil,
            isRecordingVideo: video.blocksNewCapture,
            activeVideoRecordingKind: video.blocksNewCapture ? String(describing: video.recordingLifecycle.phase) : nil,
            connectedDeviceFeatureEnabled: capabilities.isEnabled(.connectedDeviceCapture),
            listedDeviceCount: capture.connectedDevices.count,
            previewSessionActive: capture.isConnectedDeviceSessionActive,
            isLoadingDevices: capture.isLoadingConnectedDevices,
            connectedDeviceEmptyStateMessage: capture.connectedDeviceEmptyStateMessage,
            appError: lifecycle.errorMessage,
            editorError: editorController?.errorMessage,
            videoError: videoEditorController?.errorMessage,
            launchAtLoginStatus: lifecycle.launchAtLoginStatus.stateLabel,
            workingMessage: capture.isWorking ? lifecycle.workingMessage : nil,
            guideState: guide?.captureCoordinator.state.rawValue ?? "idle",
            guideStepCount: guide?.stepCount ?? 0,
            guideSourceKind: guide?.isActive == true ? guide?.selectedSourceKind : nil,
            guideSourceVideoEnabled: guide?.capturePreferences.sourceVideoEnabled ?? false,
            guideStorageEstimateMB: (guide?.storageEstimateMinutes ?? 0) * 18,
            guideLastFailureCategory: nil,
            guideExporterStatus: documents.guideEditorController == nil ? "idle" : "ready"
        )
    }
}

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

    struct ConnectedDeviceInfo: Codable, Equatable {
        let featureEnabled: Bool
        let listedDeviceCount: Int
        let previewSessionActive: Bool
        let isLoadingDevices: Bool
        let emptyStateMessage: String?
    }

    struct RecentStatusInfo: Codable, Equatable {
        let appError: String?
        let editorError: String?
        let videoError: String?
        let launchAtLoginStatus: String
        let workingMessage: String?
    }

    struct GuideInfo: Codable, Equatable {
        let state: String
        let stepCount: Int
        let sourceKind: String?
        let sourceVideoEnabled: Bool
        let storageEstimateMB: Int
        let lastCaptureFailureCategory: String?
        let exporterStatus: String
    }

    let generatedAt: Date
    let app: AppInfo
    let system: SystemInfo
    let features: FeatureFlagInfo
    let permissions: PermissionInfo
    let displays: DisplayInfo
    let storage: StorageInfo
    let editor: EditorInfo
    let connectedDevice: ConnectedDeviceInfo
    let recentStatus: RecentStatusInfo
    let guide: GuideInfo

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

enum SupportDiagnosticsBuilder {
    @MainActor
    static func make(snapshot: SupportDiagnosticsSnapshot, generatedAt: Date = Date()) -> SupportDiagnostics {
        SupportDiagnostics(
            generatedAt: generatedAt,
            app: appInfo(),
            system: systemInfo(),
            features: featureInfo(from: snapshot.capabilities),
            permissions: permissionInfo(from: snapshot),
            displays: displayInfo(from: snapshot),
            storage: storageInfo(from: snapshot),
            editor: editorInfo(from: snapshot),
            connectedDevice: connectedDeviceInfo(from: snapshot),
            recentStatus: recentStatusInfo(from: snapshot),
            guide: SupportDiagnostics.GuideInfo(
                state: snapshot.guideState,
                stepCount: snapshot.guideStepCount,
                sourceKind: snapshot.guideSourceKind,
                sourceVideoEnabled: snapshot.guideSourceVideoEnabled,
                storageEstimateMB: snapshot.guideStorageEstimateMB,
                lastCaptureFailureCategory: snapshot.guideLastFailureCategory,
                exporterStatus: snapshot.guideExporterStatus
            )
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

    private static func featureInfo(from capabilities: AppCapabilitySnapshot) -> SupportDiagnostics.FeatureFlagInfo {
        SupportDiagnostics.FeatureFlagInfo(
            scrollingCapture: capabilities.isEnabled(.scrollingCapture),
            accessibilityAutomation: capabilities.isEnabled(.accessibilityAutomation),
            connectedDeviceCapture: capabilities.isEnabled(.connectedDeviceCapture)
        )
    }

    @MainActor
    private static func permissionInfo(from snapshot: SupportDiagnosticsSnapshot) -> SupportDiagnostics.PermissionInfo {
        return SupportDiagnostics.PermissionInfo(
            screenRecording: snapshot.permissionStatus.hasScreenRecording,
            accessibility: snapshot.permissionStatus.hasAccessibility,
            captureReady: snapshot.missingPermissionRequirements.isEmpty,
            missingRequirements: snapshot.missingPermissionRequirements.map(\.title)
        )
    }

    @MainActor
    private static func displayInfo(from snapshot: SupportDiagnosticsSnapshot) -> SupportDiagnostics.DisplayInfo {
        let displays = snapshot.displays.enumerated().map { index, display in
            SupportDiagnostics.DisplayInfo.Display(
                index: index + 1,
                pixelWidth: Int((display.frame.width * display.backingScaleFactor).rounded()),
                pixelHeight: Int((display.frame.height * display.backingScaleFactor).rounded()),
                scale: Double(display.backingScaleFactor),
                isMain: display.displayID == snapshot.mainDisplayID
            )
        }

        return SupportDiagnostics.DisplayInfo(count: displays.count, displays: displays)
    }

    @MainActor
    private static func storageInfo(from snapshot: SupportDiagnosticsSnapshot) -> SupportDiagnostics.StorageInfo {
        SupportDiagnostics.StorageInfo(
            archiveMaximumSizeMB: snapshot.archiveMaximumSizeMB,
            archiveCurrentSizeLabel: snapshot.archiveCurrentSizeLabel,
            archiveUsesDefaultLocation: snapshot.archiveUsesDefaultLocation,
            recycleBinItemCount: snapshot.recycleBinItemCount,
            recycleBinRetentionDays: snapshot.recycleBinRetentionDays,
            clipboardHistoryEnabled: snapshot.clipboardHistoryEnabled,
            clipboardItemCount: snapshot.clipboardItemCount,
            clipboardMaximumItems: snapshot.clipboardMaximumItems,
            clipboardMaximumStorageMB: snapshot.clipboardMaximumStorageMB
        )
    }

    @MainActor
    private static func editorInfo(from snapshot: SupportDiagnosticsSnapshot) -> SupportDiagnostics.EditorInfo {
        SupportDiagnostics.EditorInfo(
            hasScreenshotEditor: snapshot.hasScreenshotEditor,
            annotationCount: snapshot.annotationCount,
            selectedAnnotationCount: snapshot.selectedAnnotationCount,
            hasVideoEditor: snapshot.hasVideoEditor,
            isRecordingVideo: snapshot.isRecordingVideo,
            activeVideoRecordingKind: snapshot.activeVideoRecordingKind
        )
    }

    @MainActor
    private static func connectedDeviceInfo(from snapshot: SupportDiagnosticsSnapshot) -> SupportDiagnostics.ConnectedDeviceInfo {
        SupportDiagnostics.ConnectedDeviceInfo(
            featureEnabled: snapshot.connectedDeviceFeatureEnabled,
            listedDeviceCount: snapshot.listedDeviceCount,
            previewSessionActive: snapshot.previewSessionActive,
            isLoadingDevices: snapshot.isLoadingDevices,
            emptyStateMessage: sanitizedStatus(snapshot.connectedDeviceEmptyStateMessage)
        )
    }

    @MainActor
    private static func recentStatusInfo(from snapshot: SupportDiagnosticsSnapshot) -> SupportDiagnostics.RecentStatusInfo {
        SupportDiagnostics.RecentStatusInfo(
            appError: sanitizedStatus(snapshot.appError),
            editorError: sanitizedStatus(snapshot.editorError),
            videoError: sanitizedStatus(snapshot.videoError),
            launchAtLoginStatus: snapshot.launchAtLoginStatus,
            workingMessage: sanitizedStatus(snapshot.workingMessage)
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
            of: #"(/Users|/Volumes|/private|/tmp)/[^,.;\n\r]+"#,
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
