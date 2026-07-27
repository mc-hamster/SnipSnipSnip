import AppKit
import CoreGraphics
import Foundation

@MainActor
enum AutomationAppleScriptBridge {
    private static weak var automation: AutomationWorkflowModel?
    private static var automationService: (any AutomationService)?

    static func configure(automation: AutomationWorkflowModel, automationService: any AutomationService) {
        self.automation = automation
        self.automationService = automationService
    }

    static func result(for request: AutomationRequest) async -> AutomationResultEnvelope {
        guard automation != nil, let automationService else {
            return .failure(requestID: request.id, code: .internalError, message: "SnipSnipSnip is not ready for automation.")
        }
        return await result(for: request, using: automationService)
    }

    static func result(
        for request: AutomationRequest,
        using automationService: any AutomationService
    ) async -> AutomationResultEnvelope {
        await automationService.perform(request)
    }
}

/// Cocoa owns this reference while the Apple Event is suspended. The wrapper
/// is used only to resume that same command exactly once on the main actor.
private nonisolated struct SuspendedAppleScriptCommand:
    @unchecked Sendable
{
    let value: NSScriptCommand
}

nonisolated class SSSAutomationScriptCommand: NSScriptCommand {
    var automationSource: AutomationSource {
        AutomationSource(kind: .appleScript, caller: "AppleScript")
    }

    override func performDefaultImplementation() -> Any? {
        let request = request()
        if let error = malformedArgumentError() ?? request.validationError {
            return AutomationJSON.string(for: .failure(
                requestID: request.id,
                code: error.code,
                message: error.message
            ))
        }

        // NSScriptCommand's suspension API keeps AppleScript synchronous from
        // the caller's perspective without blocking the main actor. The CLI
        // uses this same Apple Event and therefore receives the authoritative
        // result only after capture, composition mutation, and file output have
        // actually completed. Interactive pickers are the deliberate exception:
        // the service itself returns an acceptedInteractiveWorkflow result.
        suspendExecution()
        let suspendedCommand = SuspendedAppleScriptCommand(value: self)
        Task { @MainActor [suspendedCommand] in
            let result = await AutomationAppleScriptBridge.result(for: request)
            suspendedCommand.value.resumeExecution(
                withResult: AutomationJSON.string(for: result)
            )
        }
        return nil
    }

    func request() -> AutomationRequest {
        AutomationRequest(source: automationSource, command: .status, output: .none)
    }

    func stringArgument(_ name: String) -> String? {
        (evaluatedArguments?[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hasArgument(_ name: String) -> Bool {
        evaluatedArguments?[name] != nil
    }

    func boolArgument(_ name: String) -> Bool {
        evaluatedArguments?[name] as? Bool ?? false
    }

    func optionalBoolArgument(_ name: String) -> Bool? {
        evaluatedArguments?[name] as? Bool
    }

    func doubleArgument(_ name: String) -> Double? {
        if let number = evaluatedArguments?[name] as? NSNumber {
            return number.doubleValue
        }
        return stringArgument(name).flatMap(Double.init)
    }

    func uuidArgument(_ name: String) -> UUID? {
        stringArgument(name).flatMap(UUID.init(uuidString:))
    }

    func malformedArgumentError() -> AutomationError? {
        if let value = stringArgument("destination"),
           !value.isEmpty,
           AutomationCaptureDestination(rawValue: value.lowercased()) == nil {
            return AutomationError(
                code: .invalidRequest,
                message: "Capture destination must be new, append, or replace."
            )
        }
        for (name, label) in [
            ("afterItemID", "Append-after item id"),
            ("replaceItemID", "Replacement item id"),
            ("firstItemID", "First comparison item id"),
            ("secondItemID", "Second comparison item id"),
        ] {
            if let value = stringArgument(name),
               !value.isEmpty,
               UUID(uuidString: value) == nil {
                return AutomationError(
                    code: .invalidRequest,
                    message: "\(label) must be a UUID."
                )
            }
        }
        if let value = stringArgument("appearance"),
           !value.isEmpty,
           !["app-default", "appdefault", "plain", "styled"].contains(value.lowercased()) {
            return AutomationError(
                code: .invalidRequest,
                message: "Appearance must be app-default, plain, or styled."
            )
        }
        if let value = stringArgument("format"),
           !value.isEmpty,
           AutomationExportFormat(rawValue: value.lowercased()) == nil,
           !(self is SSSGuideCommand) {
            return AutomationError(
                code: .invalidRequest,
                message: "Export format must be png, jpeg, pdf, sss, gif, apng, mp4, or html."
            )
        }
        if let value = stringArgument("output"),
           !value.isEmpty,
           !["clipboard", "copy", "editor", "open-editor", "float", "none"]
            .contains(value.lowercased()) {
            return AutomationError(
                code: .invalidRequest,
                message: "Output must be editor, clipboard, float, or none."
            )
        }
        return nil
    }

    func captureDestinationArgument() -> AutomationCaptureDestination {
        stringArgument("destination")
            .map { $0.lowercased() }
            .flatMap(AutomationCaptureDestination.init(rawValue:)) ?? .new
    }

    func appearanceArgument() -> AutomationOutputAppearance {
        switch stringArgument("appearance")?.lowercased() {
        case "plain":
            return .plain
        case "styled":
            return .styled
        default:
            return .appDefault
        }
    }

    func outputArgument(default defaultOutput: AutomationOutput = .openEditor) -> AutomationOutput {
        if let outputPath = stringArgument("outputPath"), !outputPath.isEmpty {
            let format = stringArgument("format").map { $0.lowercased() }.flatMap(AutomationExportFormat.init(rawValue:)) ?? .png
            let file = AutomationFileOutput(
                url: URL(fileURLWithPath: NSString(string: outputPath).expandingTildeInPath),
                format: format,
                overwrite: boolArgument("overwrite")
            )
            return format == .sss ? .saveEditableDocument(file) : .saveFile(file)
        }

        guard let output = stringArgument("output")?.lowercased(), !output.isEmpty else {
            return defaultOutput
        }

        switch output {
        case "clipboard", "copy":
            return .copyRenderedImage
        case "editor", "open-editor":
            return .openEditor
        case "float":
            return .floatReference
        case "none":
            return .none
        default:
            return defaultOutput
        }
    }

    func rectArgument() -> CGRect? {
        guard let rect = stringArgument("rect") else {
            return nil
        }

        let parts = rect
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.count == 4 else {
            return nil
        }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]).gscIntegralStandardized
    }

    func displayModeArgument() -> AutomationFullscreenDisplayMode {
        switch stringArgument("display")?.lowercased() {
        case "current":
            return .current
        case "selected":
            return .selected
        case "all", "all-displays":
            return .all
        default:
            return .appDefault
        }
    }
}

@objc(SSSAutomationStatusCommand)
final class SSSAutomationStatusCommand: SSSAutomationScriptCommand {
    override func request() -> AutomationRequest {
        AutomationRequest(source: automationSource, command: .status, output: .none)
    }
}

@objc(SSSListCapturePresetsCommand)
final class SSSListCapturePresetsCommand: SSSAutomationScriptCommand {
    override func request() -> AutomationRequest {
        AutomationRequest(source: automationSource, command: .listPresets, output: .none)
    }
}

@objc(SSSRunCapturePresetCommand)
final class SSSRunCapturePresetCommand: SSSAutomationScriptCommand {
    override func request() -> AutomationRequest {
        let id = stringArgument("id").flatMap(UUID.init(uuidString:))
        let name = stringArgument("name")
        return AutomationRequest(
            source: automationSource,
            command: .runPreset(RunPresetAutomationCommand(id: id, name: name)),
            interactionPolicy: .promptIfNeeded,
            privacy: AutomationPrivacyOptions(privateCapture: boolArgument("privateCapture")),
            captureDestination: captureDestinationArgument(),
            appendAfterCompositionItemID: uuidArgument("afterItemID"),
            replaceCompositionItemID: uuidArgument("replaceItemID"),
            appearance: appearanceArgument(),
            output: outputArgument()
        )
    }
}

@objc(SSSCaptureFullscreenCommand)
final class SSSCaptureFullscreenCommand: SSSAutomationScriptCommand {
    override func malformedArgumentError() -> AutomationError? {
        if let error = super.malformedArgumentError() {
            return error
        }
        if let value = stringArgument("display"),
           !value.isEmpty,
           !["app-default", "appdefault", "current", "selected", "all", "all-displays"]
            .contains(value.lowercased()) {
            return AutomationError(
                code: .invalidRequest,
                message: "Display must be app-default, current, selected, or all."
            )
        }
        return nil
    }

    override func request() -> AutomationRequest {
        AutomationRequest(
            source: automationSource,
            command: .capture(CaptureAutomationCommand(target: .fullscreen(FullscreenCaptureTarget(displayMode: displayModeArgument())))),
            interactionPolicy: .promptIfNeeded,
            privacy: AutomationPrivacyOptions(privateCapture: boolArgument("privateCapture")),
            captureDestination: captureDestinationArgument(),
            appendAfterCompositionItemID: uuidArgument("afterItemID"),
            replaceCompositionItemID: uuidArgument("replaceItemID"),
            appearance: appearanceArgument(),
            output: outputArgument()
        )
    }
}

@objc(SSSCaptureFrontmostWindowCommand)
final class SSSCaptureFrontmostWindowCommand: SSSAutomationScriptCommand {
    override func request() -> AutomationRequest {
        AutomationRequest(
            source: automationSource,
            command: .capture(CaptureAutomationCommand(target: .frontmostWindow)),
            interactionPolicy: .promptIfNeeded,
            privacy: AutomationPrivacyOptions(privateCapture: boolArgument("privateCapture")),
            captureDestination: captureDestinationArgument(),
            appendAfterCompositionItemID: uuidArgument("afterItemID"),
            replaceCompositionItemID: uuidArgument("replaceItemID"),
            appearance: appearanceArgument(),
            output: outputArgument()
        )
    }
}

@objc(SSSCaptureRegionCommand)
final class SSSCaptureRegionCommand: SSSAutomationScriptCommand {
    override func malformedArgumentError() -> AutomationError? {
        if let error = super.malformedArgumentError() {
            return error
        }
        if hasArgument("rect"),
           rectArgument() == nil {
            return AutomationError(
                code: .invalidRequest,
                message: "Region rectangle must contain four finite numbers: x,y,width,height."
            )
        }
        return nil
    }

    override func request() -> AutomationRequest {
        let target: CaptureAutomationTarget
        let policy: AutomationInteractionPolicy
        if let rect = rectArgument(), !boolArgument("interactive") {
            target = .region(RegionCaptureSelector(rect: rect))
            policy = .promptIfNeeded
        } else {
            target = .interactiveRegion
            policy = .requireUserSelection
        }

        return AutomationRequest(
            source: automationSource,
            command: .capture(CaptureAutomationCommand(target: target)),
            interactionPolicy: policy,
            privacy: AutomationPrivacyOptions(privateCapture: boolArgument("privateCapture")),
            captureDestination: captureDestinationArgument(),
            appendAfterCompositionItemID: uuidArgument("afterItemID"),
            replaceCompositionItemID: uuidArgument("replaceItemID"),
            appearance: appearanceArgument(),
            output: outputArgument()
        )
    }
}

@objc(SSSCaptureWindowCommand)
final class SSSCaptureWindowCommand: SSSAutomationScriptCommand {
    override func request() -> AutomationRequest {
        AutomationRequest(
            source: automationSource,
            command: .capture(CaptureAutomationCommand(target: .interactiveWindow)),
            interactionPolicy: .requireUserSelection,
            privacy: AutomationPrivacyOptions(privateCapture: boolArgument("privateCapture")),
            captureDestination: captureDestinationArgument(),
            appendAfterCompositionItemID: uuidArgument("afterItemID"),
            replaceCompositionItemID: uuidArgument("replaceItemID"),
            appearance: appearanceArgument(),
            output: outputArgument()
        )
    }
}

@objc(SSSRepeatLastCaptureCommand)
final class SSSRepeatLastCaptureCommand: SSSAutomationScriptCommand {
    override func request() -> AutomationRequest {
        AutomationRequest(
            source: automationSource,
            command: .repeatLastCapture,
            interactionPolicy: .promptIfNeeded,
            captureDestination: captureDestinationArgument(),
            appendAfterCompositionItemID: uuidArgument("afterItemID"),
            replaceCompositionItemID: uuidArgument("replaceItemID"),
            appearance: appearanceArgument(),
            output: outputArgument()
        )
    }
}

@objc(SSSOpenSnipDocumentCommand)
final class SSSOpenSnipDocumentCommand: SSSAutomationScriptCommand {
    override func request() -> AutomationRequest {
        let path = stringArgument("path") ?? ""
        return AutomationRequest(
            source: automationSource,
            command: .openDocument(OpenDocumentAutomationCommand(url: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))),
            interactionPolicy: .promptIfNeeded,
            appearance: appearanceArgument(),
            output: outputArgument()
        )
    }
}

@objc(SSSExportCurrentScreenshotCommand)
final class SSSExportCurrentScreenshotCommand: SSSAutomationScriptCommand {
    override func request() -> AutomationRequest {
        let format = stringArgument("format").map { $0.lowercased() }.flatMap(AutomationExportFormat.init(rawValue:)) ?? .png
        return AutomationRequest(
            source: automationSource,
            command: .exportCurrent(ExportCurrentAutomationCommand(format: format)),
            interactionPolicy: .promptIfNeeded,
            appearance: appearanceArgument(),
            output: outputArgument(default: .none)
        )
    }
}

@objc(SSSSetCompositionLayoutCommand)
final class SSSSetCompositionLayoutCommand: SSSAutomationScriptCommand {
    override func malformedArgumentError() -> AutomationError? {
        if let error = super.malformedArgumentError() {
            return error
        }
        guard let layout = stringArgument("layout"),
              AutomationCompositionLayout(rawValue: layout.lowercased()) != nil else {
            return AutomationError(
                code: .invalidRequest,
                message: "Composition layout must be auto, compare, steps, row, column, grid, or freeform."
            )
        }
        if let axis = stringArgument("axis"),
           AutomationCompositionAxis(rawValue: axis.lowercased()) == nil {
            return AutomationError(
                code: .invalidRequest,
                message: "Composition axis must be horizontal or vertical."
            )
        }
        for (name, label) in [
            ("gridColumns", "Grid columns"),
            ("targetAspectRatio", "Target aspect ratio"),
            ("freeformWidth", "Freeform width"),
            ("freeformHeight", "Freeform height"),
            ("stepStartIndex", "Step start index"),
        ] where hasArgument(name) {
            guard let value = doubleArgument(name), value.isFinite else {
                return AutomationError(
                    code: .invalidRequest,
                    message: "\(label) must be a finite number."
                )
            }
        }
        for (name, label) in [
            ("gridColumns", "Grid columns"),
            ("stepStartIndex", "Step start index"),
        ] where hasArgument(name) {
            guard let value = doubleArgument(name),
                  value.rounded(.towardZero) == value else {
                return AutomationError(
                    code: .invalidRequest,
                    message: "\(label) must be an integer."
                )
            }
        }
        if let value = stringArgument("stepNumbering") {
            let normalized = value.lowercased().replacingOccurrences(of: "-", with: "")
            guard [
                "none",
                "decimal",
                "uppercaseletters",
                "lowercaseletters",
                "uppercaseroman",
                "lowercaseroman",
            ].contains(normalized) else {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Step numbering has an unsupported value."
                )
            }
        }
        if let value = stringArgument("stepConnector"),
           AutomationCompositionStepConnectorStyle(rawValue: value.lowercased()) == nil {
            return AutomationError(
                code: .invalidRequest,
                message: "Step connector must be none, line, or arrow."
            )
        }
        return nil
    }

    override func request() -> AutomationRequest {
        let layout = stringArgument("layout")
            .map { $0.lowercased() }
            .flatMap(AutomationCompositionLayout.init(rawValue:)) ?? .auto
        let axis = stringArgument("axis")
            .map { $0.lowercased() }
            .flatMap(AutomationCompositionAxis.init(rawValue:))
        let stepNumberingStyle: AutomationCompositionStepNumberingStyle?
        switch stringArgument("stepNumbering")?
            .lowercased()
            .replacingOccurrences(of: "-", with: "") {
        case "none": stepNumberingStyle = AutomationCompositionStepNumberingStyle.none
        case "decimal": stepNumberingStyle = .decimal
        case "uppercaseletters": stepNumberingStyle = .uppercaseLetters
        case "lowercaseletters": stepNumberingStyle = .lowercaseLetters
        case "uppercaseroman": stepNumberingStyle = .uppercaseRoman
        case "lowercaseroman": stepNumberingStyle = .lowercaseRoman
        default: stepNumberingStyle = nil
        }
        let stepConnectorStyle = stringArgument("stepConnector")
            .map { $0.lowercased() }
            .flatMap(AutomationCompositionStepConnectorStyle.init(rawValue:))
        return AutomationRequest(
            source: automationSource,
            command: .composition(.setLayout(AutomationCompositionLayoutCommand(
                layout: layout,
                axis: axis,
                gridColumns: doubleArgument("gridColumns").map(Int.init),
                targetAspectRatio: doubleArgument("targetAspectRatio"),
                freeformCanvasWidth: doubleArgument("freeformWidth"),
                freeformCanvasHeight: doubleArgument("freeformHeight"),
                stepNumberingStyle: stepNumberingStyle,
                stepStartIndex: doubleArgument("stepStartIndex").map(Int.init),
                stepShowsCaptions: optionalBoolArgument("stepCaptions"),
                stepConnectorStyle: stepConnectorStyle
            ))),
            interactionPolicy: .promptIfNeeded,
            output: .none
        )
    }
}

@objc(SSSSetCompositionCompareModeCommand)
final class SSSSetCompositionCompareModeCommand: SSSAutomationScriptCommand {
    override func malformedArgumentError() -> AutomationError? {
        if let error = super.malformedArgumentError() {
            return error
        }
        guard let mode = stringArgument("mode")?
            .lowercased()
            .replacingOccurrences(of: "-", with: ""),
              [
                  "sidebyside",
                  "overlay",
                  "wipe",
                  "blink",
                  "difference",
                  "changehighlight",
              ].contains(mode) else {
            return AutomationError(
                code: .invalidRequest,
                message: "Comparison mode must be side-by-side, overlay, wipe, blink, difference, or change-highlight."
            )
        }
        if let axis = stringArgument("axis"),
           AutomationCompositionAxis(rawValue: axis.lowercased()) == nil {
            return AutomationError(
                code: .invalidRequest,
                message: "Composition axis must be horizontal or vertical."
            )
        }
        for (name, label) in [
            ("wipePosition", "Wipe position"),
            ("overlayOpacity", "Overlay opacity"),
            ("blinkInterval", "Blink interval"),
            ("differenceIntensity", "Difference intensity"),
            ("highlightThreshold", "Highlight threshold"),
        ] where hasArgument(name) {
            guard let value = doubleArgument(name), value.isFinite else {
                return AutomationError(
                    code: .invalidRequest,
                    message: "\(label) must be a finite number."
                )
            }
        }
        return nil
    }

    override func request() -> AutomationRequest {
        let normalizedMode = stringArgument("mode")?
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        let mode: AutomationCompositionCompareMode
        switch normalizedMode {
        case "overlay": mode = .overlay
        case "wipe": mode = .wipe
        case "blink": mode = .blink
        case "difference": mode = .difference
        case "changehighlight": mode = .changeHighlight
        default: mode = .sideBySide
        }
        let axis = stringArgument("axis")
            .map { $0.lowercased() }
            .flatMap(AutomationCompositionAxis.init(rawValue:))
        return AutomationRequest(
            source: automationSource,
            command: .composition(.setCompareMode(AutomationCompositionCompareCommand(
                mode: mode,
                firstItemID: uuidArgument("firstItemID"),
                secondItemID: uuidArgument("secondItemID"),
                axis: axis,
                wipePosition: doubleArgument("wipePosition"),
                overlayOpacity: doubleArgument("overlayOpacity"),
                blinkInterval: doubleArgument("blinkInterval"),
                differenceIntensity: doubleArgument("differenceIntensity"),
                changeHighlightColorHex: stringArgument("highlightColor"),
                changeHighlightThreshold: doubleArgument("highlightThreshold"),
                primaryLabel: stringArgument("primaryLabel"),
                secondaryLabel: stringArgument("secondaryLabel")
            ))),
            interactionPolicy: .promptIfNeeded,
            output: .none
        )
    }
}

@objc(SSSApplyCompositionTemplateCommand)
final class SSSApplyCompositionTemplateCommand: SSSAutomationScriptCommand {
    override func request() -> AutomationRequest {
        AutomationRequest(
            source: automationSource,
            command: .composition(.applyTemplate(
                AutomationCompositionTemplateCommand(
                    id: stringArgument("id"),
                    name: stringArgument("name")
                )
            )),
            interactionPolicy: .promptIfNeeded,
            output: .none
        )
    }
}

@objc(SSSGuideCommand)
final class SSSGuideCommand: SSSAutomationScriptCommand {
    override func malformedArgumentError() -> AutomationError? {
        if let error = super.malformedArgumentError() {
            return error
        }
        guard let action = stringArgument("action")?.lowercased(),
              ["start", "pause", "resume", "add-step", "add step", "stop", "export"]
                .contains(action) else {
            return AutomationError(
                code: .invalidRequest,
                message: "Guide action must be start, pause, resume, add-step, stop, or export."
            )
        }
        if action == "start",
           let target = stringArgument("target"),
           GuideAutomationTarget(rawValue: target.lowercased()) == nil {
            return AutomationError(
                code: .invalidRequest,
                message: "Guide target must be window, app, region, or display."
            )
        }
        if action == "export" {
            guard let format = stringArgument("format"),
                  GuideAutomationExportFormat(rawValue: format.lowercased()) != nil else {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Guide export format is invalid."
                )
            }
        }
        return nil
    }

    override func request() -> AutomationRequest {
        let action = stringArgument("action")?.lowercased() ?? "start"
        let command: GuideAutomationCommand
        switch action {
        case "start":
            command = .start(GuideAutomationTarget(rawValue: stringArgument("target")?.lowercased() ?? "window") ?? .window)
        case "pause": command = .pause
        case "resume": command = .resume
        case "add-step", "add step": command = .addStep
        case "stop": command = .stop
        case "export":
            command = .export(GuideAutomationExportFormat(rawValue: stringArgument("format")?.lowercased() ?? "pdf") ?? .pdf)
        default: command = .start(.window)
        }
        return AutomationRequest(
            source: automationSource,
            command: .guide(command),
            interactionPolicy: action == "start" && stringArgument("target")?.lowercased() == "region" ? .requireUserSelection : .promptIfNeeded,
            privacy: AutomationPrivacyOptions(privateCapture: boolArgument("privateCapture")),
            output: .none
        )
    }
}
