import AppIntents
import CoreGraphics
import Foundation
import OSLog

nonisolated enum AutomationIntentGuideAction: String, AppEnum {
    case startWindow, startApp, startRegion, startDisplay
    case pause, resume, addStep, stop
    case exportPDF, exportGIF, exportAPNG, exportFullMotion, exportHighlights, exportSlideshow, exportImages, exportZIP

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Guide Action"
    static let caseDisplayRepresentations: [AutomationIntentGuideAction: DisplayRepresentation] = [
        .startWindow: "Start · Window", .startApp: "Start · App", .startRegion: "Start · Region", .startDisplay: "Start · Display",
        .pause: "Pause", .resume: "Resume", .addStep: "Add Manual Step", .stop: "Stop",
        .exportPDF: "Export PDF", .exportGIF: "Export GIF", .exportAPNG: "Export APNG", .exportFullMotion: "Export Full Motion MP4",
        .exportHighlights: "Export Action Highlights MP4", .exportSlideshow: "Export Slideshow MP4", .exportImages: "Export Images", .exportZIP: "Export ZIP"
    ]

    var command: GuideAutomationCommand {
        switch self {
        case .startWindow: .start(.window)
        case .startApp: .start(.app)
        case .startRegion: .start(.region)
        case .startDisplay: .start(.display)
        case .pause: .pause
        case .resume: .resume
        case .addStep: .addStep
        case .stop: .stop
        case .exportPDF: .export(.pdf)
        case .exportGIF: .export(.gif)
        case .exportAPNG: .export(.apng)
        case .exportFullMotion: .export(.fullMotionMP4)
        case .exportHighlights: .export(.highlightMP4)
        case .exportSlideshow: .export(.slideshowMP4)
        case .exportImages: .export(.images)
        case .exportZIP: .export(.zip)
        }
    }
}

nonisolated enum AutomationIntentOutputDestination: String, AppEnum {
    case openEditor
    case clipboard
    case file
    case floatReference
    case none

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Output Destination"

    static let caseDisplayRepresentations: [AutomationIntentOutputDestination: DisplayRepresentation] = [
        .openEditor: "Open Editor",
        .clipboard: "Clipboard",
        .file: "File",
        .floatReference: "Floating Reference",
        .none: "None"
    ]
}

nonisolated enum AutomationIntentExportFormat: String, AppEnum {
    case png
    case jpeg
    case pdf
    case sss

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Export Format"

    static let caseDisplayRepresentations: [AutomationIntentExportFormat: DisplayRepresentation] = [
        .png: "PNG",
        .jpeg: "JPEG",
        .pdf: "PDF",
        .sss: "Editable SnipSnipSnip Document"
    ]

    var automationFormat: AutomationExportFormat {
        switch self {
        case .png:
            return .png
        case .jpeg:
            return .jpeg
        case .pdf:
            return .pdf
        case .sss:
            return .sss
        }
    }
}

nonisolated enum AutomationIntentFullscreenDisplayMode: String, AppEnum {
    case appDefault
    case current
    case selected
    case all

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Fullscreen Display"

    static let caseDisplayRepresentations: [AutomationIntentFullscreenDisplayMode: DisplayRepresentation] = [
        .appDefault: "App Default",
        .current: "Current Display",
        .selected: "Selected Display",
        .all: "All Displays"
    ]

    var automationDisplayMode: AutomationFullscreenDisplayMode {
        switch self {
        case .appDefault:
            return .appDefault
        case .current:
            return .current
        case .selected:
            return .selected
        case .all:
            return .all
        }
    }
}

nonisolated enum AutomationIntentCaptureDelay: String, AppEnum {
    case appDefault
    case immediate
    case threeSeconds
    case fiveSeconds
    case tenSeconds

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Capture Delay"

    static let caseDisplayRepresentations: [AutomationIntentCaptureDelay: DisplayRepresentation] = [
        .appDefault: "App Default",
        .immediate: "Immediate",
        .threeSeconds: "3 Seconds",
        .fiveSeconds: "5 Seconds",
        .tenSeconds: "10 Seconds"
    ]

    var automationDelay: AutomationCaptureDelay {
        switch self {
        case .appDefault:
            return .appDefault
        case .immediate:
            return .immediate
        case .threeSeconds:
            return .seconds(3)
        case .fiveSeconds:
            return .seconds(5)
        case .tenSeconds:
            return .seconds(10)
        }
    }
}

nonisolated enum AutomationIntentCursorMode: String, AppEnum {
    case appDefault
    case include
    case exclude

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Cursor"

    static let caseDisplayRepresentations: [AutomationIntentCursorMode: DisplayRepresentation] = [
        .appDefault: "App Default",
        .include: "Include Cursor",
        .exclude: "Exclude Cursor"
    ]

    var includesCursor: Bool? {
        switch self {
        case .appDefault:
            return nil
        case .include:
            return true
        case .exclude:
            return false
        }
    }
}

nonisolated enum AutomationIntentUIMapMode: String, AppEnum {
    case appDefault
    case enabled
    case disabled

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "UI Map"

    static let caseDisplayRepresentations: [AutomationIntentUIMapMode: DisplayRepresentation] = [
        .appDefault: "App Default",
        .enabled: "Enabled",
        .disabled: "Disabled"
    ]

    var automationTriState: AutomationTriState {
        switch self {
        case .appDefault:
            return .appDefault
        case .enabled:
            return .enabled
        case .disabled:
            return .disabled
        }
    }
}

nonisolated struct CapturePresetEntity: AppEntity, Identifiable, Equatable {
    let id: UUID
    let name: String
    let target: String
    let targetLabel: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Capture Preset"
    static let defaultQuery = CapturePresetQuery()

    init(id: UUID, name: String, target: String, targetLabel: String) {
        self.id = id
        self.name = name
        self.target = target
        self.targetLabel = targetLabel
    }

    init(summary: AutomationPresetSummary) {
        self.init(
            id: summary.id,
            name: summary.name,
            target: summary.target,
            targetLabel: summary.targetLabel
        )
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: LocalizedStringResource(stringLiteral: targetLabel)
        )
    }
}

struct CapturePresetQuery: EntityQuery {
    @Dependency(default: AutomationIntentClient.unavailable)
    private var dependencyClient: AutomationIntentClient
    private let clientOverride: AutomationIntentClient?

    init() {
        clientOverride = nil
    }

    init(client: AutomationIntentClient) {
        clientOverride = client
    }

    func entities(for identifiers: [CapturePresetEntity.ID]) async throws -> [CapturePresetEntity] {
        let presets = await client.capturePresetSummaries()
        return presets
            .filter { identifiers.contains($0.id) }
            .map(CapturePresetEntity.init(summary:))
    }

    func suggestedEntities() async throws -> [CapturePresetEntity] {
        await client.capturePresetSummaries()
            .map(CapturePresetEntity.init(summary:))
    }

    private var client: AutomationIntentClient {
        clientOverride ?? dependencyClient
    }
}

nonisolated enum AutomationIntentRequestFactory {
    static func source(caller: String) -> AutomationSource {
        AutomationSource(kind: .appIntent, caller: caller)
    }

    static func request(
        caller: String,
        command: AutomationCommand,
        interactionPolicy: AutomationInteractionPolicy = .never,
        privacy: AutomationPrivacyOptions = AutomationPrivacyOptions(),
        output: AutomationOutput = .appDefault
    ) -> AutomationRequest {
        AutomationRequest(
            source: source(caller: caller),
            command: command,
            interactionPolicy: interactionPolicy,
            privacy: privacy,
            output: output
        )
    }

    static func output(
        destination: AutomationIntentOutputDestination?,
        filePath: String?,
        format: AutomationIntentExportFormat?,
        overwrite: Bool?,
        default defaultOutput: AutomationOutput = .openEditor
    ) -> AutomationOutput {
        guard let destination else {
            ShortcutsAutomationLog.logger.info(
                "intent.output default destination=nil filePath=\(filePath ?? "nil", privacy: .public) format=\(format?.rawValue ?? "nil", privacy: .public) overwrite=\(overwrite.map(String.init(describing:)) ?? "nil", privacy: .public) output=\(defaultOutput.debugSummary, privacy: .public)"
            )
            return defaultOutput
        }

        let resolvedOutput: AutomationOutput
        switch destination {
        case .openEditor:
            resolvedOutput = .openEditor
        case .clipboard:
            resolvedOutput = .copyRenderedImage
        case .floatReference:
            resolvedOutput = .floatReference
        case .none:
            resolvedOutput = .none
        case .file:
            let automationFormat = (format ?? .png).automationFormat
            let file = AutomationFileOutput(
                url: fileURL(from: filePath),
                format: automationFormat,
                overwrite: overwrite ?? false
            )
            resolvedOutput = automationFormat == .sss ? .saveEditableDocument(file) : .saveFile(file)
        }

        ShortcutsAutomationLog.logger.info(
            "intent.output mapped destination=\(destination.rawValue, privacy: .public) filePath=\(filePath ?? "nil", privacy: .public) format=\(format?.rawValue ?? "nil", privacy: .public) overwrite=\(overwrite.map(String.init(describing:)) ?? "nil", privacy: .public) output=\(resolvedOutput.debugSummary, privacy: .public)"
        )
        return resolvedOutput
    }

    static func fileURL(from filePath: String?) -> URL? {
        guard let trimmedPath = filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedPath.isEmpty else {
            ShortcutsAutomationLog.logger.info("intent.fileURL empty input")
            return nil
        }

        if let url = URL(string: trimmedPath),
           url.isFileURL {
            ShortcutsAutomationLog.logger.info(
                "intent.fileURL fileURL input=\(trimmedPath, privacy: .public) output=\(url.path, privacy: .public)"
            )
            return url
        }

        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        ShortcutsAutomationLog.logger.info(
            "intent.fileURL path input=\(trimmedPath, privacy: .public) expanded=\(expandedPath, privacy: .public) output=\(url.path, privacy: .public)"
        )
        return url
    }

    static func captureOptions(
        delay: AutomationIntentCaptureDelay?,
        cursor: AutomationIntentCursorMode?,
        windowUIMap: AutomationIntentUIMapMode?
    ) -> CaptureAutomationOptions {
        CaptureAutomationOptions(
            delay: (delay ?? .appDefault).automationDelay,
            includesCursor: (cursor ?? .appDefault).includesCursor,
            windowUIMap: (windowUIMap ?? .appDefault).automationTriState
        )
    }

    static func privacy(privateCapture: Bool?) -> AutomationPrivacyOptions {
        AutomationPrivacyOptions(privateCapture: privateCapture ?? false)
    }

    static func regionTarget(
        interactive: Bool?,
        x: Double?,
        y: Double?,
        width: Double?,
        height: Double?
    ) -> (target: CaptureAutomationTarget, policy: AutomationInteractionPolicy) {
        let hasAnyCoordinate = [x, y, width, height].contains { $0 != nil }
        guard interactive != true, hasAnyCoordinate else {
            return (.interactiveRegion, .requireUserSelection)
        }

        let rect = CGRect(
            x: x ?? 0,
            y: y ?? 0,
            width: width ?? 0,
            height: height ?? 0
        )
        return (.region(RegionCaptureSelector(rect: rect)), .promptIfNeeded)
    }
}
