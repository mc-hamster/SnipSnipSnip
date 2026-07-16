import CoreGraphics
import Foundation

nonisolated enum AutomationSourceKind: String, Codable, Equatable, Sendable {
    case commandLine
    case appleScript
    case urlScheme
    case appIntent
    case internalCommand
}

nonisolated struct AutomationSource: Codable, Equatable, Sendable {
    var kind: AutomationSourceKind
    var caller: String?

    init(kind: AutomationSourceKind, caller: String? = nil) {
        self.kind = kind
        self.caller = caller
    }
}

nonisolated enum AutomationInteractionPolicy: String, Codable, Equatable, Sendable {
    case never
    case promptIfNeeded
    case requireUserSelection
}

nonisolated struct AutomationPrivacyOptions: Codable, Equatable, Sendable {
    var privateCapture: Bool

    init(privateCapture: Bool = false) {
        self.privateCapture = privateCapture
    }
}

nonisolated struct AutomationRequest: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var source: AutomationSource
    var command: AutomationCommand
    var interactionPolicy: AutomationInteractionPolicy
    var privacy: AutomationPrivacyOptions
    var output: AutomationOutput

    init(
        id: UUID = UUID(),
        source: AutomationSource,
        command: AutomationCommand,
        interactionPolicy: AutomationInteractionPolicy = .never,
        privacy: AutomationPrivacyOptions = AutomationPrivacyOptions(),
        output: AutomationOutput = .appDefault
    ) {
        self.id = id
        self.source = source
        self.command = command
        self.interactionPolicy = interactionPolicy
        self.privacy = privacy
        self.output = output
    }
}

nonisolated enum AutomationCommand: Codable, Equatable, Sendable {
    case status
    case listPresets
    case runPreset(RunPresetAutomationCommand)
    case capture(CaptureAutomationCommand)
    case repeatLastCapture
    case openDocument(OpenDocumentAutomationCommand)
    case exportCurrent(ExportCurrentAutomationCommand)
    case guide(GuideAutomationCommand)
}

nonisolated enum GuideAutomationCommand: Codable, Equatable, Sendable {
    case start(GuideAutomationTarget)
    case pause
    case resume
    case addStep
    case stop
    case export(GuideAutomationExportFormat)
}

nonisolated enum GuideAutomationTarget: String, Codable, CaseIterable, Equatable, Sendable {
    case window
    case app
    case region
    case display
}

nonisolated enum GuideAutomationExportFormat: String, Codable, CaseIterable, Equatable, Sendable {
    case pdf
    case gif
    case apng
    case fullMotionMP4 = "mp4-full"
    case highlightMP4 = "mp4-highlights"
    case slideshowMP4 = "mp4-slideshow"
    case images
    case zip

    var guideFormat: GuideExportFormat {
        switch self {
        case .pdf: .pdf
        case .gif: .gif
        case .apng: .apng
        case .fullMotionMP4: .fullMotionMP4
        case .highlightMP4: .highlightMP4
        case .slideshowMP4: .slideshowMP4
        case .images: .stepImages
        case .zip: .zip
        }
    }
}

nonisolated struct RunPresetAutomationCommand: Codable, Equatable, Sendable {
    var id: UUID?
    var name: String?

    init(id: UUID? = nil, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

nonisolated struct CaptureAutomationCommand: Codable, Equatable, Sendable {
    var target: CaptureAutomationTarget
    var options: CaptureAutomationOptions

    init(target: CaptureAutomationTarget, options: CaptureAutomationOptions = CaptureAutomationOptions()) {
        self.target = target
        self.options = options
    }
}

nonisolated enum CaptureAutomationTarget: Codable, Equatable, Sendable {
    case fullscreen(FullscreenCaptureTarget)
    case frontmostWindow
    case region(RegionCaptureSelector)
    case interactiveRegion
    case interactiveWindow
}

nonisolated struct FullscreenCaptureTarget: Codable, Equatable, Sendable {
    var displayMode: AutomationFullscreenDisplayMode

    init(displayMode: AutomationFullscreenDisplayMode = .appDefault) {
        self.displayMode = displayMode
    }
}

nonisolated enum AutomationFullscreenDisplayMode: String, Codable, Equatable, Sendable {
    case appDefault
    case current
    case selected
    case all
}

nonisolated struct RegionCaptureSelector: Codable, Equatable, Sendable {
    var rect: CGRect

    init(rect: CGRect) {
        self.rect = rect.gscIntegralStandardized
    }
}

nonisolated struct CaptureAutomationOptions: Codable, Equatable, Sendable {
    var delay: AutomationCaptureDelay
    var includesCursor: Bool?
    var windowUIMap: AutomationTriState

    init(
        delay: AutomationCaptureDelay = .appDefault,
        includesCursor: Bool? = nil,
        windowUIMap: AutomationTriState = .appDefault
    ) {
        self.delay = delay
        self.includesCursor = includesCursor
        self.windowUIMap = windowUIMap
    }
}

nonisolated enum AutomationCaptureDelay: Codable, Equatable, Sendable {
    case appDefault
    case immediate
    case seconds(Int)
}

nonisolated enum AutomationTriState: String, Codable, Equatable, Sendable {
    case appDefault
    case enabled
    case disabled
}

nonisolated struct OpenDocumentAutomationCommand: Codable, Equatable, Sendable {
    var url: URL

    init(url: URL) {
        self.url = url
    }
}

nonisolated struct ExportCurrentAutomationCommand: Codable, Equatable, Sendable {
    var format: AutomationExportFormat

    init(format: AutomationExportFormat = .png) {
        self.format = format
    }
}

nonisolated enum AutomationOutput: Codable, Equatable, Sendable {
    case appDefault
    case openEditor
    case copyRenderedImage
    case saveFile(AutomationFileOutput)
    case saveEditableDocument(AutomationFileOutput)
    case floatReference
    case none
}

nonisolated struct AutomationFileOutput: Codable, Equatable, Sendable {
    var url: URL?
    var format: AutomationExportFormat
    var overwrite: Bool
    var revealInFinder: Bool

    init(
        url: URL?,
        format: AutomationExportFormat = .png,
        overwrite: Bool = false,
        revealInFinder: Bool = false
    ) {
        self.url = url
        self.format = format
        self.overwrite = overwrite
        self.revealInFinder = revealInFinder
    }
}

nonisolated enum AutomationExportFormat: String, Codable, CaseIterable, Equatable, Sendable {
    case png
    case jpeg
    case pdf
    case sss
}

nonisolated struct AutomationResultEnvelope: Codable, Equatable, Sendable {
    var requestID: UUID
    var status: AutomationStatus
    var payload: AutomationPayload?
    var outputs: [AutomationOutputResult]
    var warnings: [AutomationWarning]
    var error: AutomationError?

    init(
        requestID: UUID,
        status: AutomationStatus,
        payload: AutomationPayload? = nil,
        outputs: [AutomationOutputResult] = [],
        warnings: [AutomationWarning] = [],
        error: AutomationError? = nil
    ) {
        self.requestID = requestID
        self.status = status
        self.payload = payload
        self.outputs = outputs
        self.warnings = warnings
        self.error = error
    }

    static func success(
        requestID: UUID,
        payload: AutomationPayload? = nil,
        outputs: [AutomationOutputResult] = [],
        warnings: [AutomationWarning] = []
    ) -> AutomationResultEnvelope {
        AutomationResultEnvelope(
            requestID: requestID,
            status: .succeeded,
            payload: payload,
            outputs: outputs,
            warnings: warnings
        )
    }

    static func failure(
        requestID: UUID,
        code: AutomationErrorCode,
        message: String,
        warnings: [AutomationWarning] = []
    ) -> AutomationResultEnvelope {
        AutomationResultEnvelope(
            requestID: requestID,
            status: .failed,
            warnings: warnings,
            error: AutomationError(code: code, message: message)
        )
    }
}

nonisolated enum AutomationPayload: Codable, Equatable, Sendable {
    case preflight(AutomationPermissionPreflight)
    case capabilities(AutomationCapabilities)
    case presets([AutomationPresetSummary])
    case capture(AutomationCaptureSummary)
    case export(AutomationExportSummary)
    case permissionStatus(AutomationPermissionSummary)
    case guide(AutomationGuideSummary)
    case none
}

nonisolated enum AutomationStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
}

nonisolated struct AutomationOutputResult: Codable, Equatable, Sendable {
    var kind: AutomationOutputResultKind
    var url: URL?
    var format: AutomationExportFormat?
    var message: String?

    init(
        kind: AutomationOutputResultKind,
        url: URL? = nil,
        format: AutomationExportFormat? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.url = url
        self.format = format
        self.message = message
    }
}

nonisolated enum AutomationOutputResultKind: String, Codable, Equatable, Sendable {
    case openedEditor
    case copiedClipboard
    case savedFile
    case savedEditableDocument
    case floatedReference
    case acceptedInteractiveWorkflow
    case none
}

nonisolated struct AutomationWarning: Codable, Equatable, Sendable {
    var code: String
    var message: String
}

nonisolated struct AutomationError: Codable, Equatable, Sendable {
    var code: AutomationErrorCode
    var message: String
}

nonisolated enum AutomationErrorCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case busy
    case permissionDenied
    case confirmationRequired
    case userCancelled
    case targetUnavailable
    case featureUnavailable
    case proFeatureRequired
    case unsupportedOutput
    case outputFailed
    case internalError
    case noActiveGuide
    case guideAlreadyActive
    case guideHasNoSteps
    case guideSourceMediaUnavailable
    case guideFinalizationFailed
}

nonisolated struct AutomationCapabilities: Codable, Equatable, Sendable {
    var supportsURLScheme: Bool
    var supportsAppleScript: Bool
    var supportsCLI: Bool
    var supportsAppIntents: Bool
    var supportsCapturePresets: Bool
    var supportsPrivateCapture: Bool
    var supportsUIMap: Bool
    var supportsScrollingCapture: Bool
    var supportsConnectedDeviceCapture: Bool
    var supportsCurrentEditorExport: Bool
    var supportsGuide: Bool = true
}

nonisolated struct AutomationGuideSummary: Codable, Equatable, Sendable {
    var state: String
    var stepCount: Int
    var source: String?
    var sourceVideoEnabled: Bool
}

nonisolated struct AutomationPresetSummary: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var target: String
    var targetLabel: String
    var createdAt: Date
    var updatedAt: Date
}

nonisolated struct AutomationCaptureSummary: Codable, Equatable, Sendable {
    var kind: String
    var sourceName: String?
    var acceptedInteractiveWorkflow: Bool
}

nonisolated struct AutomationExportSummary: Codable, Equatable, Sendable {
    var format: AutomationExportFormat?
    var source: String
}

nonisolated struct AutomationPermissionSummary: Codable, Equatable, Sendable {
    var hasScreenRecording: Bool
    var hasAccessibility: Bool
    var hasMicrophone: Bool
}

nonisolated struct AutomationPermissionPreflight: Codable, Equatable, Sendable {
    var capabilities: AutomationCapabilities
    var permissions: AutomationPermissionSummary

    var isCaptureReady: Bool {
        permissions.hasScreenRecording
    }
}
