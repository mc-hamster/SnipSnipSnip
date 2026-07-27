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
    var captureDestination: AutomationCaptureDestination
    var appendAfterCompositionItemID: UUID?
    var replaceCompositionItemID: UUID?
    var appearance: AutomationOutputAppearance
    var output: AutomationOutput

    init(
        id: UUID = UUID(),
        source: AutomationSource,
        command: AutomationCommand,
        interactionPolicy: AutomationInteractionPolicy = .never,
        privacy: AutomationPrivacyOptions = AutomationPrivacyOptions(),
        captureDestination: AutomationCaptureDestination = .new,
        appendAfterCompositionItemID: UUID? = nil,
        replaceCompositionItemID: UUID? = nil,
        appearance: AutomationOutputAppearance = .appDefault,
        output: AutomationOutput = .appDefault
    ) {
        self.id = id
        self.source = source
        self.command = command
        self.interactionPolicy = interactionPolicy
        self.privacy = privacy
        self.captureDestination = captureDestination
        self.appendAfterCompositionItemID = appendAfterCompositionItemID
        self.replaceCompositionItemID = replaceCompositionItemID
        self.appearance = appearance
        self.output = output
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case command
        case interactionPolicy
        case privacy
        case captureDestination
        case appendAfterCompositionItemID
        case replaceCompositionItemID
        case appearance
        case output
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        source = try container.decode(AutomationSource.self, forKey: .source)
        command = try container.decode(AutomationCommand.self, forKey: .command)
        interactionPolicy = try container.decode(AutomationInteractionPolicy.self, forKey: .interactionPolicy)
        privacy = try container.decode(AutomationPrivacyOptions.self, forKey: .privacy)
        captureDestination = try container.decodeIfPresent(AutomationCaptureDestination.self, forKey: .captureDestination) ?? .new
        appendAfterCompositionItemID = try container.decodeIfPresent(UUID.self, forKey: .appendAfterCompositionItemID)
        replaceCompositionItemID = try container.decodeIfPresent(UUID.self, forKey: .replaceCompositionItemID)
        appearance = try container.decodeIfPresent(AutomationOutputAppearance.self, forKey: .appearance) ?? .appDefault
        output = try container.decode(AutomationOutput.self, forKey: .output)
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
    case composition(CompositionAutomationCommand)
    case guide(GuideAutomationCommand)
}

nonisolated enum AutomationCaptureDestination: String, Codable, CaseIterable, Equatable, Sendable {
    case new
    case append
    case replace
}

nonisolated enum AutomationOutputAppearance: String, Codable, CaseIterable, Equatable, Sendable {
    case appDefault
    case plain
    case styled
}

nonisolated enum CompositionAutomationCommand: Codable, Equatable, Sendable {
    case setLayout(AutomationCompositionLayoutCommand)
    case setCompareMode(AutomationCompositionCompareCommand)
    case applyTemplate(AutomationCompositionTemplateCommand)
}

nonisolated struct AutomationCompositionTemplateCommand: Codable, Equatable, Sendable {
    var id: String?
    var name: String?

    init(id: String? = nil, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

nonisolated enum AutomationCompositionLayout: String, Codable, CaseIterable, Equatable, Sendable {
    case auto
    case compare
    case steps
    case row
    case column
    case grid
    case freeform
}

nonisolated enum AutomationCompositionCompareMode: String, Codable, CaseIterable, Equatable, Sendable {
    case sideBySide
    case overlay
    case wipe
    case blink
    case difference
    case changeHighlight
}

nonisolated enum AutomationCompositionAxis: String, Codable, CaseIterable, Equatable, Sendable {
    case horizontal
    case vertical
}

nonisolated enum AutomationCompositionStepNumberingStyle: String, Codable, CaseIterable, Equatable, Sendable {
    case none
    case decimal
    case uppercaseLetters
    case lowercaseLetters
    case uppercaseRoman
    case lowercaseRoman
}

nonisolated enum AutomationCompositionStepConnectorStyle: String, Codable, CaseIterable, Equatable, Sendable {
    case none
    case line
    case arrow
}

nonisolated struct AutomationCompositionLayoutCommand: Codable, Equatable, Sendable {
    var layout: AutomationCompositionLayout
    var axis: AutomationCompositionAxis?
    var gridColumns: Int?
    var targetAspectRatio: Double?
    var freeformCanvasWidth: Double?
    var freeformCanvasHeight: Double?
    var stepNumberingStyle: AutomationCompositionStepNumberingStyle?
    var stepStartIndex: Int?
    var stepShowsCaptions: Bool?
    var stepConnectorStyle: AutomationCompositionStepConnectorStyle?

    init(
        layout: AutomationCompositionLayout,
        axis: AutomationCompositionAxis? = nil,
        gridColumns: Int? = nil,
        targetAspectRatio: Double? = nil,
        freeformCanvasWidth: Double? = nil,
        freeformCanvasHeight: Double? = nil,
        stepNumberingStyle: AutomationCompositionStepNumberingStyle? = nil,
        stepStartIndex: Int? = nil,
        stepShowsCaptions: Bool? = nil,
        stepConnectorStyle: AutomationCompositionStepConnectorStyle? = nil
    ) {
        self.layout = layout
        self.axis = axis
        self.gridColumns = gridColumns
        self.targetAspectRatio = targetAspectRatio
        self.freeformCanvasWidth = freeformCanvasWidth
        self.freeformCanvasHeight = freeformCanvasHeight
        self.stepNumberingStyle = stepNumberingStyle
        self.stepStartIndex = stepStartIndex
        self.stepShowsCaptions = stepShowsCaptions
        self.stepConnectorStyle = stepConnectorStyle
    }
}

nonisolated struct AutomationCompositionCompareCommand: Codable, Equatable, Sendable {
    var mode: AutomationCompositionCompareMode
    var firstItemID: UUID?
    var secondItemID: UUID?
    var axis: AutomationCompositionAxis?
    var wipePosition: Double?
    var overlayOpacity: Double?
    var blinkInterval: Double?
    var differenceIntensity: Double?
    var changeHighlightColorHex: String?
    var changeHighlightThreshold: Double?
    var primaryLabel: String?
    var secondaryLabel: String?

    init(
        mode: AutomationCompositionCompareMode,
        firstItemID: UUID? = nil,
        secondItemID: UUID? = nil,
        axis: AutomationCompositionAxis? = nil,
        wipePosition: Double? = nil,
        overlayOpacity: Double? = nil,
        blinkInterval: Double? = nil,
        differenceIntensity: Double? = nil,
        changeHighlightColorHex: String? = nil,
        changeHighlightThreshold: Double? = nil,
        primaryLabel: String? = nil,
        secondaryLabel: String? = nil
    ) {
        self.mode = mode
        self.firstItemID = firstItemID
        self.secondItemID = secondItemID
        self.axis = axis
        self.wipePosition = wipePosition
        self.overlayOpacity = overlayOpacity
        self.blinkInterval = blinkInterval
        self.differenceIntensity = differenceIntensity
        self.changeHighlightColorHex = changeHighlightColorHex
        self.changeHighlightThreshold = changeHighlightThreshold
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
    }
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
    case gif
    case apng
    case mp4
    case html
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
    case composition(AutomationCompositionSummary)
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
    case updatedComposition
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
    case noActiveComposition
    case compositionItemNotFound
    case compositionRequiresMultipleItems
    case incompatibleCompositionItems
    case unsupportedComparisonOutput
    case oversizedOutput
    case staleDestination
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
    var supportsGuide: Bool
    var supportsComposition: Bool

    init(
        supportsURLScheme: Bool,
        supportsAppleScript: Bool,
        supportsCLI: Bool,
        supportsAppIntents: Bool,
        supportsCapturePresets: Bool,
        supportsPrivateCapture: Bool,
        supportsUIMap: Bool,
        supportsScrollingCapture: Bool,
        supportsConnectedDeviceCapture: Bool,
        supportsCurrentEditorExport: Bool,
        supportsGuide: Bool,
        supportsComposition: Bool = false
    ) {
        self.supportsURLScheme = supportsURLScheme
        self.supportsAppleScript = supportsAppleScript
        self.supportsCLI = supportsCLI
        self.supportsAppIntents = supportsAppIntents
        self.supportsCapturePresets = supportsCapturePresets
        self.supportsPrivateCapture = supportsPrivateCapture
        self.supportsUIMap = supportsUIMap
        self.supportsScrollingCapture = supportsScrollingCapture
        self.supportsConnectedDeviceCapture = supportsConnectedDeviceCapture
        self.supportsCurrentEditorExport = supportsCurrentEditorExport
        self.supportsGuide = supportsGuide
        self.supportsComposition = supportsComposition
    }

    private enum CodingKeys: String, CodingKey {
        case supportsURLScheme
        case supportsAppleScript
        case supportsCLI
        case supportsAppIntents
        case supportsCapturePresets
        case supportsPrivateCapture
        case supportsUIMap
        case supportsScrollingCapture
        case supportsConnectedDeviceCapture
        case supportsCurrentEditorExport
        case supportsGuide
        case supportsComposition
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supportsURLScheme = try container.decode(Bool.self, forKey: .supportsURLScheme)
        supportsAppleScript = try container.decode(Bool.self, forKey: .supportsAppleScript)
        supportsCLI = try container.decode(Bool.self, forKey: .supportsCLI)
        supportsAppIntents = try container.decode(Bool.self, forKey: .supportsAppIntents)
        supportsCapturePresets = try container.decode(Bool.self, forKey: .supportsCapturePresets)
        supportsPrivateCapture = try container.decode(Bool.self, forKey: .supportsPrivateCapture)
        supportsUIMap = try container.decode(Bool.self, forKey: .supportsUIMap)
        supportsScrollingCapture = try container.decode(Bool.self, forKey: .supportsScrollingCapture)
        supportsConnectedDeviceCapture = try container.decode(Bool.self, forKey: .supportsConnectedDeviceCapture)
        supportsCurrentEditorExport = try container.decode(Bool.self, forKey: .supportsCurrentEditorExport)
        supportsGuide = try container.decode(Bool.self, forKey: .supportsGuide)
        supportsComposition = try container.decodeIfPresent(Bool.self, forKey: .supportsComposition) ?? false
    }
}

nonisolated struct AutomationCompositionSummary: Codable, Equatable, Sendable {
    var documentID: UUID?
    /// The item directly affected by the command, when the operation targets
    /// one item (append or replace). This is deliberately distinct from the
    /// editor's incidental selection.
    var itemID: UUID?
    var itemCount: Int
    var layout: AutomationCompositionLayout
    var compareMode: AutomationCompositionCompareMode?
    var selectedItemID: UUID?
    var isPrivate: Bool

    init(
        documentID: UUID? = nil,
        itemID: UUID? = nil,
        itemCount: Int,
        layout: AutomationCompositionLayout,
        compareMode: AutomationCompositionCompareMode? = nil,
        selectedItemID: UUID? = nil,
        isPrivate: Bool = false
    ) {
        self.documentID = documentID
        self.itemID = itemID
        self.itemCount = itemCount
        self.layout = layout
        self.compareMode = compareMode
        self.selectedItemID = selectedItemID
        self.isPrivate = isPrivate
    }
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
