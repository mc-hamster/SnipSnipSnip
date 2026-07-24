import AppIntents
import Foundation
import OSLog
import UniformTypeIdentifiers

private struct AutomationIntentFailure: LocalizedError {
    var message: String

    var errorDescription: String? {
        message
    }
}

protocol AutomationPerformingIntent: AppIntent {}

extension AutomationPerformingIntent {
    nonisolated static var supportedModes: IntentModes {
        [.background, .foreground(.dynamic)]
    }

    nonisolated func performAutomationSilently(
        _ request: AutomationRequest,
        client: AutomationIntentClient
    ) async throws -> some IntentResult {
        ShortcutsAutomationLog.logger.info(
            "intent.perform silent start requestID=\(request.id.uuidString, privacy: .public) \(request.debugSummary, privacy: .public)"
        )
        if request.requiresAppIntentForeground {
            ShortcutsAutomationLog.logger.info(
                "intent.perform continueInForeground requestID=\(request.id.uuidString, privacy: .public)"
            )
            try await continueInForeground(
                "Continue in SnipSnipSnip to finish this automation.",
                alwaysConfirm: false
            )
        }

        let result = await client.perform(request)
        ShortcutsAutomationLog.logger.info(
            "intent.perform silent result requestID=\(request.id.uuidString, privacy: .public) \(result.debugSummary, privacy: .public)"
        )
        if let error = result.error {
            ShortcutsAutomationLog.logger.error(
                "intent.perform silent throwing requestID=\(request.id.uuidString, privacy: .public) code=\(error.code.rawValue, privacy: .public) message=\(error.message, privacy: .public)"
            )
            throw AutomationIntentFailure(message: error.message)
        }
        return .result()
    }

    nonisolated func performAutomationWithDialog(
        _ request: AutomationRequest,
        client: AutomationIntentClient
    ) async throws -> some IntentResult & ProvidesDialog {
        ShortcutsAutomationLog.logger.info(
            "intent.perform dialog start requestID=\(request.id.uuidString, privacy: .public) \(request.debugSummary, privacy: .public)"
        )
        let result = await client.perform(request)
        ShortcutsAutomationLog.logger.info(
            "intent.perform dialog result requestID=\(request.id.uuidString, privacy: .public) \(result.debugSummary, privacy: .public)"
        )
        if let error = result.error {
            ShortcutsAutomationLog.logger.error(
                "intent.perform dialog throwing requestID=\(request.id.uuidString, privacy: .public) code=\(error.code.rawValue, privacy: .public) message=\(error.message, privacy: .public)"
            )
            throw AutomationIntentFailure(message: error.message)
        }
        return .result(dialog: AutomationIntentResultFormatter.dialog(for: result))
    }
}

protocol PassiveAutomationIntent: AutomationPerformingIntent {}

extension PassiveAutomationIntent {
    nonisolated static var supportedModes: IntentModes {
        .background
    }
}

struct AutomationStatusIntent: @preconcurrency PassiveAutomationIntent {
    static let title: LocalizedStringResource = "Get SnipSnipSnip Automation Status"
    static let description = IntentDescription("Check SnipSnipSnip automation capabilities and permissions.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .status,
            output: .none
        )
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await performAutomationWithDialog(automationRequest(), client: client)
    }
}

struct ListCapturePresetsIntent: @preconcurrency PassiveAutomationIntent {
    static let title: LocalizedStringResource = "List SnipSnipSnip Capture Presets"
    static let description = IntentDescription("List the capture presets available to SnipSnipSnip automation.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .listPresets,
            output: .none
        )
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await performAutomationWithDialog(automationRequest(), client: client)
    }
}

struct RunCapturePresetIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Run SnipSnipSnip Capture Preset"
    static let description = IntentDescription("Run a saved SnipSnipSnip capture preset.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Preset")
    var preset: CapturePresetEntity

    @Parameter(title: "Output")
    var output: AutomationIntentOutputDestination?

    @Parameter(title: "Output File", description: "Absolute POSIX path or file URL.")
    var outputFile: String?

    @Parameter(title: "Format")
    var format: AutomationIntentExportFormat?

    @Parameter(title: "Overwrite")
    var overwrite: Bool?

    @Parameter(title: "Private Capture")
    var privateCapture: Bool?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .runPreset(RunPresetAutomationCommand(id: preset.id)),
            interactionPolicy: .promptIfNeeded,
            privacy: AutomationIntentRequestFactory.privacy(privateCapture: privateCapture),
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct CaptureFullscreenIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Capture SnipSnipSnip Fullscreen"
    static let description = IntentDescription("Capture the fullscreen target with SnipSnipSnip.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Display")
    var display: AutomationIntentFullscreenDisplayMode?

    @Parameter(title: "Output")
    var output: AutomationIntentOutputDestination?

    @Parameter(title: "Output File", description: "Absolute POSIX path or file URL.")
    var outputFile: String?

    @Parameter(title: "Format")
    var format: AutomationIntentExportFormat?

    @Parameter(title: "Overwrite")
    var overwrite: Bool?

    @Parameter(title: "Private Capture")
    var privateCapture: Bool?

    @Parameter(title: "Delay")
    var delay: AutomationIntentCaptureDelay?

    @Parameter(title: "Cursor")
    var cursor: AutomationIntentCursorMode?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        let target = CaptureAutomationTarget.fullscreen(
            FullscreenCaptureTarget(displayMode: (display ?? .appDefault).automationDisplayMode)
        )
        let options = AutomationIntentRequestFactory.captureOptions(
            delay: delay,
            cursor: cursor,
            windowUIMap: nil
        )

        return AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .capture(CaptureAutomationCommand(target: target, options: options)),
            interactionPolicy: .promptIfNeeded,
            privacy: AutomationIntentRequestFactory.privacy(privateCapture: privateCapture),
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct CaptureFrontmostWindowIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Capture SnipSnipSnip Frontmost Window"
    static let description = IntentDescription("Capture the frontmost eligible window with SnipSnipSnip.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Output")
    var output: AutomationIntentOutputDestination?

    @Parameter(title: "Output File", description: "Absolute POSIX path or file URL.")
    var outputFile: String?

    @Parameter(title: "Format")
    var format: AutomationIntentExportFormat?

    @Parameter(title: "Overwrite")
    var overwrite: Bool?

    @Parameter(title: "Private Capture")
    var privateCapture: Bool?

    @Parameter(title: "Delay")
    var delay: AutomationIntentCaptureDelay?

    @Parameter(title: "Cursor")
    var cursor: AutomationIntentCursorMode?

    @Parameter(title: "UI Map")
    var windowUIMap: AutomationIntentUIMapMode?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        let options = AutomationIntentRequestFactory.captureOptions(
            delay: delay,
            cursor: cursor,
            windowUIMap: windowUIMap
        )

        return AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .capture(CaptureAutomationCommand(target: .frontmostWindow, options: options)),
            interactionPolicy: .promptIfNeeded,
            privacy: AutomationIntentRequestFactory.privacy(privateCapture: privateCapture),
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct CaptureRegionIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Capture SnipSnipSnip Region"
    static let description = IntentDescription("Capture a fixed region or start interactive region capture with SnipSnipSnip.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Interactive")
    var interactive: Bool?

    @Parameter(title: "X")
    var x: Double?

    @Parameter(title: "Y")
    var y: Double?

    @Parameter(title: "Width")
    var width: Double?

    @Parameter(title: "Height")
    var height: Double?

    @Parameter(title: "Output")
    var output: AutomationIntentOutputDestination?

    @Parameter(title: "Output File", description: "Absolute POSIX path or file URL.")
    var outputFile: String?

    @Parameter(title: "Format")
    var format: AutomationIntentExportFormat?

    @Parameter(title: "Overwrite")
    var overwrite: Bool?

    @Parameter(title: "Private Capture")
    var privateCapture: Bool?

    @Parameter(title: "Delay")
    var delay: AutomationIntentCaptureDelay?

    @Parameter(title: "Cursor")
    var cursor: AutomationIntentCursorMode?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        let region = AutomationIntentRequestFactory.regionTarget(
            interactive: interactive,
            x: x,
            y: y,
            width: width,
            height: height
        )
        let options = AutomationIntentRequestFactory.captureOptions(
            delay: delay,
            cursor: cursor,
            windowUIMap: nil
        )

        return AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .capture(CaptureAutomationCommand(target: region.target, options: options)),
            interactionPolicy: region.policy,
            privacy: AutomationIntentRequestFactory.privacy(privateCapture: privateCapture),
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct CaptureWindowIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Capture SnipSnipSnip Window"
    static let description = IntentDescription("Start interactive window capture with SnipSnipSnip.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Output")
    var output: AutomationIntentOutputDestination?

    @Parameter(title: "Output File", description: "Absolute POSIX path or file URL.")
    var outputFile: String?

    @Parameter(title: "Format")
    var format: AutomationIntentExportFormat?

    @Parameter(title: "Overwrite")
    var overwrite: Bool?

    @Parameter(title: "Private Capture")
    var privateCapture: Bool?

    @Parameter(title: "Delay")
    var delay: AutomationIntentCaptureDelay?

    @Parameter(title: "Cursor")
    var cursor: AutomationIntentCursorMode?

    @Parameter(title: "UI Map")
    var windowUIMap: AutomationIntentUIMapMode?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        let options = AutomationIntentRequestFactory.captureOptions(
            delay: delay,
            cursor: cursor,
            windowUIMap: windowUIMap
        )

        return AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .capture(CaptureAutomationCommand(target: .interactiveWindow, options: options)),
            interactionPolicy: .requireUserSelection,
            privacy: AutomationIntentRequestFactory.privacy(privateCapture: privateCapture),
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct RepeatLastCaptureIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Repeat Last SnipSnipSnip Capture"
    static let description = IntentDescription("Repeat the last repeatable SnipSnipSnip capture.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Output")
    var output: AutomationIntentOutputDestination?

    @Parameter(title: "Output File", description: "Absolute POSIX path or file URL.")
    var outputFile: String?

    @Parameter(title: "Format")
    var format: AutomationIntentExportFormat?

    @Parameter(title: "Overwrite")
    var overwrite: Bool?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .repeatLastCapture,
            interactionPolicy: .promptIfNeeded,
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct OpenSnipDocumentIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Open SnipSnipSnip Document"
    static let description = IntentDescription("Open an editable SnipSnipSnip .sss document.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(
        title: "Document",
        supportedContentTypes: [UTType(exportedAs: "com.oontz.snipsnipsnip.document", conformingTo: .package)]
    )
    var document: IntentFile

    @Parameter(title: "Output")
    var output: AutomationIntentOutputDestination?

    @Parameter(title: "Output File", description: "Absolute POSIX path or file URL.")
    var outputFile: String?

    @Parameter(title: "Format")
    var format: AutomationIntentExportFormat?

    @Parameter(title: "Overwrite")
    var overwrite: Bool?

    nonisolated init() {}

    func automationRequest(documentURL: URL) -> AutomationRequest {
        AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .openDocument(OpenDocumentAutomationCommand(url: documentURL)),
            interactionPolicy: .promptIfNeeded,
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        guard let documentURL = document.fileURL else {
            throw AutomationIntentFailure(message: "Choose a file-backed .sss document.")
        }

        let didStartAccessing = documentURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                documentURL.stopAccessingSecurityScopedResource()
            }
        }

        return try await performAutomationSilently(automationRequest(documentURL: documentURL), client: client)
    }
}

struct ExportCurrentScreenshotIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Export Current SnipSnipSnip Screenshot"
    static let description = IntentDescription("Export the current SnipSnipSnip screenshot to a file.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Output File", description: "Absolute POSIX path or file URL.")
    var outputFile: String?

    @Parameter(title: "Format")
    var format: AutomationIntentExportFormat?

    @Parameter(title: "Overwrite")
    var overwrite: Bool?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        let selectedFormat = format ?? .png
        return AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .exportCurrent(ExportCurrentAutomationCommand(format: selectedFormat.automationFormat)),
            interactionPolicy: .promptIfNeeded,
            output: AutomationIntentRequestFactory.output(
                destination: .file,
                filePath: outputFile,
                format: selectedFormat,
                overwrite: overwrite,
                default: .saveFile(AutomationFileOutput(
                    url: AutomationIntentRequestFactory.fileURL(from: outputFile),
                    format: selectedFormat.automationFormat
                ))
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct GuideActionIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Control SnipSnipSnip Guide"
    static let description = IntentDescription("Start, control, stop, or export a SnipSnipSnip Guide.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Action")
    var action: AutomationIntentGuideAction

    @Parameter(title: "Private Guide")
    var privateGuide: Bool?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .guide(action.command),
            interactionPolicy: action == .startRegion ? .requireUserSelection : .promptIfNeeded,
            privacy: AutomationPrivacyOptions(privateCapture: privateGuide ?? false),
            output: .none
        )
    }

    func perform() async throws -> some IntentResult {
        try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct SnipSnipSnipAutomationShortcuts: AppShortcutsProvider {
    nonisolated static var shortcutTileColor: ShortcutTileColor {
        .blue
    }

    nonisolated static var appShortcuts: [AppIntents.AppShortcut] {
        AppIntents.AppShortcut(
            intent: CaptureFullscreenIntent(),
            phrases: [
                "Capture fullscreen with \(.applicationName)",
                "Take a fullscreen snip with \(.applicationName)"
            ],
            shortTitle: "Capture Fullscreen",
            systemImageName: "macwindow"
        )

        AppIntents.AppShortcut(
            intent: CaptureRegionIntent(),
            phrases: [
                "Capture a region with \(.applicationName)",
                "Take a region snip with \(.applicationName)"
            ],
            shortTitle: "Capture Region",
            systemImageName: "selection.pin.in.out"
        )

        AppIntents.AppShortcut(
            intent: CaptureWindowIntent(),
            phrases: [
                "Capture a window with \(.applicationName)",
                "Take a window snip with \(.applicationName)"
            ],
            shortTitle: "Capture Window",
            systemImageName: "rectangle.on.rectangle"
        )

        AppIntents.AppShortcut(
            intent: CaptureFrontmostWindowIntent(),
            phrases: [
                "Capture the frontmost window with \(.applicationName)",
                "Snip the frontmost window with \(.applicationName)"
            ],
            shortTitle: "Frontmost Window",
            systemImageName: "macwindow.on.rectangle"
        )

        AppIntents.AppShortcut(
            intent: RepeatLastCaptureIntent(),
            phrases: [
                "Repeat last capture with \(.applicationName)",
                "Repeat my last snip with \(.applicationName)"
            ],
            shortTitle: "Repeat Capture",
            systemImageName: "arrow.clockwise"
        )

        AppIntents.AppShortcut(
            intent: RunCapturePresetIntent(),
            phrases: [
                "Run a capture preset with \(.applicationName)",
                "Use a SnipSnipSnip preset with \(.applicationName)"
            ],
            shortTitle: "Run Preset",
            systemImageName: "star"
        )

        #if !APP_STORE_BUILD
        AppIntents.AppShortcut(
            intent: GuideActionIntent(),
            phrases: [
                "Start a guide with \(.applicationName)",
                "Control my guide with \(.applicationName)"
            ],
            shortTitle: "Guide",
            systemImageName: "list.number"
        )
        #endif
    }
}
