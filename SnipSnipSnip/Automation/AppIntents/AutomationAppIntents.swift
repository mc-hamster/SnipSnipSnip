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

    nonisolated func validateCompositionCaptureItemIDs(
        appendAfterItemID: String?,
        replaceItemID: String?
    ) throws {
        for (value, label) in [
            (appendAfterItemID, "Append-after composition item ID"),
            (replaceItemID, "Replacement composition item ID"),
        ] {
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            guard UUID(uuidString: value) != nil else {
                throw AutomationIntentFailure(message: "\(label) must be a UUID.")
            }
        }
    }

    nonisolated func validateUUIDString(
        _ value: String?,
        label: String
    ) throws {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }
        guard UUID(uuidString: value) != nil else {
            throw AutomationIntentFailure(message: "\(label) must be a UUID.")
        }
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

    @Parameter(title: "Capture Destination")
    var captureDestination: AutomationIntentCaptureDestination?

    @Parameter(title: "Append After Composition Item ID", description: "UUID of the item after which to insert when Capture Destination is Append.")
    var appendAfterCompositionItemID: String?

    @Parameter(title: "Replace Composition Item ID", description: "UUID of the item to replace when Capture Destination is Replace.")
    var replaceCompositionItemID: String?

    @Parameter(title: "Appearance")
    var appearance: AutomationIntentOutputAppearance?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .runPreset(RunPresetAutomationCommand(id: preset.id)),
            interactionPolicy: .promptIfNeeded,
            privacy: AutomationIntentRequestFactory.privacy(privateCapture: privateCapture),
            captureDestination: captureDestination,
            appendAfterCompositionItemID: appendAfterCompositionItemID,
            replaceCompositionItemID: replaceCompositionItemID,
            appearance: appearance,
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try validateCompositionCaptureItemIDs(
            appendAfterItemID: appendAfterCompositionItemID,
            replaceItemID: replaceCompositionItemID
        )
        return try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct CaptureFullscreenIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Capture SnipSnipSnip Screen"
    static let description = IntentDescription(
        "Capture a screen with SnipSnipSnip."
    )

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

    @Parameter(title: "Capture Destination")
    var captureDestination: AutomationIntentCaptureDestination?

    @Parameter(title: "Append After Composition Item ID", description: "UUID of the item after which to insert when Capture Destination is Append.")
    var appendAfterCompositionItemID: String?

    @Parameter(title: "Replace Composition Item ID", description: "UUID of the item to replace when Capture Destination is Replace.")
    var replaceCompositionItemID: String?

    @Parameter(title: "Appearance")
    var appearance: AutomationIntentOutputAppearance?

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
            captureDestination: captureDestination,
            appendAfterCompositionItemID: appendAfterCompositionItemID,
            replaceCompositionItemID: replaceCompositionItemID,
            appearance: appearance,
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try validateCompositionCaptureItemIDs(
            appendAfterItemID: appendAfterCompositionItemID,
            replaceItemID: replaceCompositionItemID
        )
        return try await performAutomationSilently(automationRequest(), client: client)
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

    @Parameter(title: "Capture Destination")
    var captureDestination: AutomationIntentCaptureDestination?

    @Parameter(title: "Append After Composition Item ID", description: "UUID of the item after which to insert when Capture Destination is Append.")
    var appendAfterCompositionItemID: String?

    @Parameter(title: "Replace Composition Item ID", description: "UUID of the item to replace when Capture Destination is Replace.")
    var replaceCompositionItemID: String?

    @Parameter(title: "Appearance")
    var appearance: AutomationIntentOutputAppearance?

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
            captureDestination: captureDestination,
            appendAfterCompositionItemID: appendAfterCompositionItemID,
            replaceCompositionItemID: replaceCompositionItemID,
            appearance: appearance,
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try validateCompositionCaptureItemIDs(
            appendAfterItemID: appendAfterCompositionItemID,
            replaceItemID: replaceCompositionItemID
        )
        return try await performAutomationSilently(automationRequest(), client: client)
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

    @Parameter(title: "Capture Destination")
    var captureDestination: AutomationIntentCaptureDestination?

    @Parameter(title: "Append After Composition Item ID", description: "UUID of the item after which to insert when Capture Destination is Append.")
    var appendAfterCompositionItemID: String?

    @Parameter(title: "Replace Composition Item ID", description: "UUID of the item to replace when Capture Destination is Replace.")
    var replaceCompositionItemID: String?

    @Parameter(title: "Appearance")
    var appearance: AutomationIntentOutputAppearance?

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
            captureDestination: captureDestination,
            appendAfterCompositionItemID: appendAfterCompositionItemID,
            replaceCompositionItemID: replaceCompositionItemID,
            appearance: appearance,
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try validateCompositionCaptureItemIDs(
            appendAfterItemID: appendAfterCompositionItemID,
            replaceItemID: replaceCompositionItemID
        )
        return try await performAutomationSilently(automationRequest(), client: client)
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

    @Parameter(title: "Capture Destination")
    var captureDestination: AutomationIntentCaptureDestination?

    @Parameter(title: "Append After Composition Item ID", description: "UUID of the item after which to insert when Capture Destination is Append.")
    var appendAfterCompositionItemID: String?

    @Parameter(title: "Replace Composition Item ID", description: "UUID of the item to replace when Capture Destination is Replace.")
    var replaceCompositionItemID: String?

    @Parameter(title: "Appearance")
    var appearance: AutomationIntentOutputAppearance?

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
            captureDestination: captureDestination,
            appendAfterCompositionItemID: appendAfterCompositionItemID,
            replaceCompositionItemID: replaceCompositionItemID,
            appearance: appearance,
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try validateCompositionCaptureItemIDs(
            appendAfterItemID: appendAfterCompositionItemID,
            replaceItemID: replaceCompositionItemID
        )
        return try await performAutomationSilently(automationRequest(), client: client)
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

    @Parameter(title: "Capture Destination")
    var captureDestination: AutomationIntentCaptureDestination?

    @Parameter(title: "Append After Composition Item ID", description: "UUID of the item after which to insert when Capture Destination is Append.")
    var appendAfterCompositionItemID: String?

    @Parameter(title: "Replace Composition Item ID", description: "UUID of the item to replace when Capture Destination is Replace.")
    var replaceCompositionItemID: String?

    @Parameter(title: "Appearance")
    var appearance: AutomationIntentOutputAppearance?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .repeatLastCapture,
            interactionPolicy: .promptIfNeeded,
            captureDestination: captureDestination,
            appendAfterCompositionItemID: appendAfterCompositionItemID,
            replaceCompositionItemID: replaceCompositionItemID,
            appearance: appearance,
            output: AutomationIntentRequestFactory.output(
                destination: output,
                filePath: outputFile,
                format: format,
                overwrite: overwrite
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try validateCompositionCaptureItemIDs(
            appendAfterItemID: appendAfterCompositionItemID,
            replaceItemID: replaceCompositionItemID
        )
        return try await performAutomationSilently(automationRequest(), client: client)
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

    @Parameter(title: "Appearance")
    var appearance: AutomationIntentOutputAppearance?

    nonisolated init() {}

    func automationRequest(documentURL: URL) -> AutomationRequest {
        AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .openDocument(OpenDocumentAutomationCommand(url: documentURL)),
            interactionPolicy: .promptIfNeeded,
            appearance: appearance,
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

    @Parameter(title: "Appearance")
    var appearance: AutomationIntentOutputAppearance?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        let selectedFormat = format ?? .png
        let file = AutomationFileOutput(
            url: AutomationIntentRequestFactory.fileURL(from: outputFile),
            format: selectedFormat.automationFormat
        )
        return AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .exportCurrent(ExportCurrentAutomationCommand(format: selectedFormat.automationFormat)),
            interactionPolicy: .promptIfNeeded,
            appearance: appearance,
            output: AutomationIntentRequestFactory.output(
                destination: .file,
                filePath: outputFile,
                format: selectedFormat,
                overwrite: overwrite,
                default: selectedFormat == .sss
                    ? .saveEditableDocument(file)
                    : .saveFile(file)
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct AddCaptureToCompositionIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Add Capture to SnipSnipSnip Composition"
    static let description = IntentDescription("Capture another image and append it to the current editable composition.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Capture Source")
    var source: AutomationIntentCompositionCaptureSource?

    @Parameter(title: "Display")
    var display: AutomationIntentFullscreenDisplayMode?

    @Parameter(title: "Append After Item ID", description: "Optional UUID of the composition item after which to insert.")
    var appendAfterItemID: String?

    @Parameter(title: "Private Capture")
    var privateCapture: Bool?

    @Parameter(title: "Appearance")
    var appearance: AutomationIntentOutputAppearance?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        let mapped = (source ?? .region).automationCommand(display: display)
        return AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: mapped.command,
            interactionPolicy: mapped.policy,
            privacy: AutomationIntentRequestFactory.privacy(
                privateCapture: privateCapture
            ),
            captureDestination: .append,
            appendAfterCompositionItemID: appendAfterItemID,
            appearance: appearance,
            output: .openEditor
        )
    }

    func perform() async throws -> some IntentResult {
        try validateCompositionCaptureItemIDs(
            appendAfterItemID: appendAfterItemID,
            replaceItemID: nil
        )
        return try await performAutomationSilently(
            automationRequest(),
            client: client
        )
    }
}

struct ReplaceCompositionItemIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Replace SnipSnipSnip Composition Item"
    static let description = IntentDescription("Capture a new image and replace one item in the current editable composition.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Item ID", description: "UUID of the composition item to replace.")
    var itemID: String

    @Parameter(title: "Capture Source")
    var source: AutomationIntentCompositionCaptureSource?

    @Parameter(title: "Display")
    var display: AutomationIntentFullscreenDisplayMode?

    @Parameter(title: "Private Capture")
    var privateCapture: Bool?

    @Parameter(title: "Appearance")
    var appearance: AutomationIntentOutputAppearance?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        let mapped = (source ?? .region).automationCommand(display: display)
        return AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: mapped.command,
            interactionPolicy: mapped.policy,
            privacy: AutomationIntentRequestFactory.privacy(
                privateCapture: privateCapture
            ),
            captureDestination: .replace,
            replaceCompositionItemID: itemID,
            appearance: appearance,
            output: .openEditor
        )
    }

    func perform() async throws -> some IntentResult {
        try validateCompositionCaptureItemIDs(
            appendAfterItemID: nil,
            replaceItemID: itemID
        )
        return try await performAutomationSilently(
            automationRequest(),
            client: client
        )
    }
}

struct ExportCompositionIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Export SnipSnipSnip Composition"
    static let description = IntentDescription("Export the current multi-capture composition after all pending rendering and comparison work finishes.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Output File", description: "Absolute POSIX path or file URL.")
    var outputFile: String?

    @Parameter(title: "Format")
    var format: AutomationIntentExportFormat?

    @Parameter(title: "Overwrite")
    var overwrite: Bool?

    @Parameter(title: "Appearance")
    var appearance: AutomationIntentOutputAppearance?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        let selectedFormat = format ?? .png
        let file = AutomationFileOutput(
            url: AutomationIntentRequestFactory.fileURL(from: outputFile),
            format: selectedFormat.automationFormat
        )
        return AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .exportCurrent(
                ExportCurrentAutomationCommand(
                    format: selectedFormat.automationFormat
                )
            ),
            interactionPolicy: .promptIfNeeded,
            appearance: appearance,
            output: AutomationIntentRequestFactory.output(
                destination: .file,
                filePath: outputFile,
                format: selectedFormat,
                overwrite: overwrite,
                default: selectedFormat == .sss
                    ? .saveEditableDocument(file)
                    : .saveFile(file)
            )
        )
    }

    func perform() async throws -> some IntentResult {
        try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct SetCompositionLayoutIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Set SnipSnipSnip Composition Layout"
    static let description = IntentDescription("Set the layout of the current SnipSnipSnip multi-capture composition.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Layout")
    var layout: AutomationIntentCompositionLayout

    @Parameter(title: "Axis")
    var axis: AutomationIntentCompositionAxis?

    @Parameter(title: "Grid Columns")
    var gridColumns: Int?

    @Parameter(title: "Target Aspect Ratio")
    var targetAspectRatio: Double?

    @Parameter(title: "Freeform Canvas Width")
    var freeformCanvasWidth: Double?

    @Parameter(title: "Freeform Canvas Height")
    var freeformCanvasHeight: Double?

    @Parameter(title: "Step Numbering")
    var stepNumbering: AutomationIntentCompositionStepNumberingStyle?

    @Parameter(title: "Step Start Index")
    var stepStartIndex: Int?

    @Parameter(title: "Show Step Captions")
    var stepShowsCaptions: Bool?

    @Parameter(title: "Step Connector")
    var stepConnector: AutomationIntentCompositionStepConnectorStyle?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .composition(.setLayout(AutomationCompositionLayoutCommand(
                layout: layout.automationLayout,
                axis: axis?.automationAxis,
                gridColumns: gridColumns,
                targetAspectRatio: targetAspectRatio,
                freeformCanvasWidth: freeformCanvasWidth,
                freeformCanvasHeight: freeformCanvasHeight,
                stepNumberingStyle: stepNumbering?.automationStyle,
                stepStartIndex: stepStartIndex,
                stepShowsCaptions: stepShowsCaptions,
                stepConnectorStyle: stepConnector?.automationStyle
            ))),
            interactionPolicy: .promptIfNeeded,
            output: .none
        )
    }

    func perform() async throws -> some IntentResult {
        try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct ApplyCompositionTemplateIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Apply SnipSnipSnip Composition Template"
    static let description = IntentDescription("Apply a compatible built-in or saved template to the current composition.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Template ID")
    var templateID: String?

    @Parameter(title: "Template Name")
    var templateName: String?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .composition(.applyTemplate(
                AutomationCompositionTemplateCommand(
                    id: templateID,
                    name: templateName
                )
            )),
            interactionPolicy: .promptIfNeeded,
            output: .none
        )
    }

    func perform() async throws -> some IntentResult {
        try await performAutomationSilently(automationRequest(), client: client)
    }
}

struct SetCompositionCompareModeIntent: @preconcurrency AutomationPerformingIntent {
    static let title: LocalizedStringResource = "Set SnipSnipSnip Comparison Mode"
    static let description = IntentDescription("Configure comparison behavior for the current SnipSnipSnip composition.")

    @Dependency(default: AutomationIntentClient.unavailable)
    private var client: AutomationIntentClient

    @Parameter(title: "Mode")
    var mode: AutomationIntentCompositionCompareMode

    @Parameter(title: "First Item ID")
    var firstItemID: String?

    @Parameter(title: "Second Item ID")
    var secondItemID: String?

    @Parameter(title: "Axis")
    var axis: AutomationIntentCompositionAxis?

    @Parameter(title: "Wipe Position", description: "Value from 0 through 1.")
    var wipePosition: Double?

    @Parameter(title: "Overlay Opacity", description: "Value from 0 through 1.")
    var overlayOpacity: Double?

    @Parameter(title: "Blink Interval", description: "Seconds between images.")
    var blinkInterval: Double?

    @Parameter(title: "Difference Intensity", description: "Value from 0 through 1.")
    var differenceIntensity: Double?

    @Parameter(title: "Highlight Color", description: "Hex color as #RRGGBB or #RRGGBBAA.")
    var highlightColor: String?

    @Parameter(title: "Highlight Threshold", description: "Value from 0 through 1.")
    var highlightThreshold: Double?

    @Parameter(title: "Primary Label")
    var primaryLabel: String?

    @Parameter(title: "Secondary Label")
    var secondaryLabel: String?

    nonisolated init() {}

    func automationRequest() -> AutomationRequest {
        AutomationIntentRequestFactory.request(
            caller: String(describing: Self.self),
            command: .composition(.setCompareMode(AutomationCompositionCompareCommand(
                mode: mode.automationMode,
                firstItemID: firstItemID.flatMap(UUID.init(uuidString:)),
                secondItemID: secondItemID.flatMap(UUID.init(uuidString:)),
                axis: axis?.automationAxis,
                wipePosition: wipePosition,
                overlayOpacity: overlayOpacity,
                blinkInterval: blinkInterval,
                differenceIntensity: differenceIntensity,
                changeHighlightColorHex: highlightColor,
                changeHighlightThreshold: highlightThreshold,
                primaryLabel: primaryLabel,
                secondaryLabel: secondaryLabel
            ))),
            interactionPolicy: .promptIfNeeded,
            output: .none
        )
    }

    func perform() async throws -> some IntentResult {
        try validateUUIDString(firstItemID, label: "First item ID")
        try validateUUIDString(secondItemID, label: "Second item ID")
        return try await performAutomationSilently(automationRequest(), client: client)
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
                "Capture a screen with \(.applicationName)",
                "Take a screen snip with \(.applicationName)"
            ],
            shortTitle: "Capture Screen",
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
            intent: RunCapturePresetIntent(),
            phrases: [
                "Run a capture preset with \(.applicationName)",
                "Use a SnipSnipSnip preset with \(.applicationName)"
            ],
            shortTitle: "Run Preset",
            systemImageName: "star"
        )

        AppIntents.AppShortcut(
            intent: AddCaptureToCompositionIntent(),
            phrases: [
                "Add a capture to my composition with \(.applicationName)",
                "Append a snip with \(.applicationName)"
            ],
            shortTitle: "Add to Composition",
            systemImageName: "rectangle.stack.badge.plus"
        )

        AppIntents.AppShortcut(
            intent: ReplaceCompositionItemIntent(),
            phrases: [
                "Replace a composition item with \(.applicationName)"
            ],
            shortTitle: "Replace Item",
            systemImageName: "rectangle.2.swap"
        )

        AppIntents.AppShortcut(
            intent: ExportCompositionIntent(),
            phrases: [
                "Export my composition with \(.applicationName)"
            ],
            shortTitle: "Export Composition",
            systemImageName: "square.and.arrow.up"
        )

        AppIntents.AppShortcut(
            intent: SetCompositionLayoutIntent(),
            phrases: [
                "Set composition layout with \(.applicationName)",
                "Arrange my captures with \(.applicationName)"
            ],
            shortTitle: "Set Layout",
            systemImageName: "rectangle.3.group"
        )

        AppIntents.AppShortcut(
            intent: SetCompositionCompareModeIntent(),
            phrases: [
                "Compare captures with \(.applicationName)",
                "Set comparison mode with \(.applicationName)"
            ],
            shortTitle: "Compare Captures",
            systemImageName: "square.split.2x1"
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
