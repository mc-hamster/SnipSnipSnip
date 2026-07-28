import CoreGraphics
import Foundation

nonisolated struct AutomationCLIParseResult: Equatable {
    var request: AutomationRequest?
    var wantsJSON: Bool
    var exitCode: Int32
    var errorMessage: String?
}

nonisolated enum AutomationCLIParser {
    static func parse(_ arguments: [String]) -> AutomationCLIParseResult {
        var cursor = ArgumentCursor(arguments)
        let json = cursor.consumeFlag("--json")
        if let flag = firstFlagMissingValue(in: arguments) {
            return failure(
                "\(flag) requires a value.",
                wantsJSON: json,
                exitCode: 64
            )
        }
        let source = AutomationSource(kind: .commandLine, caller: "snipsnipsnipctl")

        guard let first = cursor.next() else {
            return failure("Missing command.", wantsJSON: json, exitCode: 64)
        }
        if first != "guide",
           let formatValue = cursor.value(after: "--format"),
           AutomationExportFormat(rawValue: formatValue.lowercased()) == nil {
            return failure(
                "Format must be png, jpeg, pdf, sss, gif, apng, mp4, or html.",
                wantsJSON: json,
                exitCode: 64
            )
        }

        let interactionPolicy: AutomationInteractionPolicy = cursor.contains("--interactive") ? .requireUserSelection : .never
        let privacy = AutomationPrivacyOptions(privateCapture: cursor.contains("--private"))
        let captureDestination: AutomationCaptureDestination
        if let value = cursor.value(after: "--destination") {
            guard let parsed = AutomationCaptureDestination(rawValue: value.lowercased()) else {
                return failure("Destination must be new, append, or replace.", wantsJSON: json, exitCode: 64)
            }
            captureDestination = parsed
        } else {
            captureDestination = .new
        }
        let appendAfterCompositionItemID: UUID?
        if cursor.contains("--after-item-id") {
            guard let value = cursor.value(after: "--after-item-id") else {
                return failure("Append-after item id requires a UUID.", wantsJSON: json, exitCode: 64)
            }
            guard let parsed = UUID(uuidString: value) else {
                return failure("Append-after item id must be a UUID.", wantsJSON: json, exitCode: 64)
            }
            appendAfterCompositionItemID = parsed
        } else {
            appendAfterCompositionItemID = nil
        }
        if appendAfterCompositionItemID != nil, captureDestination != .append {
            return failure(
                "Append-after item id requires --destination append.",
                wantsJSON: json,
                exitCode: 64
            )
        }
        let replaceCompositionItemID: UUID?
        if let value = cursor.value(after: "--replace-item-id") {
            guard let parsed = UUID(uuidString: value) else {
                return failure("Replace item id must be a UUID.", wantsJSON: json, exitCode: 64)
            }
            replaceCompositionItemID = parsed
        } else {
            replaceCompositionItemID = nil
        }
        let appearance: AutomationOutputAppearance
        if let value = cursor.value(after: "--appearance") {
            guard let parsed = AutomationOutputAppearance(cliValue: value) else {
                return failure("Appearance must be app-default, plain, or styled.", wantsJSON: json, exitCode: 64)
            }
            appearance = parsed
        } else {
            appearance = .appDefault
        }

        switch first {
        case "status":
            return success(AutomationRequest(source: source, command: .status, appearance: appearance, output: .none), wantsJSON: json)
        case "presets":
            return parsePresets(
                cursor: &cursor,
                source: source,
                json: json,
                interactionPolicy: interactionPolicy,
                privacy: privacy,
                captureDestination: captureDestination,
                appendAfterCompositionItemID: appendAfterCompositionItemID,
                replaceCompositionItemID: replaceCompositionItemID,
                appearance: appearance
            )
        case "capture":
            return parseCapture(
                cursor: &cursor,
                source: source,
                json: json,
                interactionPolicy: interactionPolicy,
                privacy: privacy,
                captureDestination: captureDestination,
                appendAfterCompositionItemID: appendAfterCompositionItemID,
                replaceCompositionItemID: replaceCompositionItemID,
                appearance: appearance
            )
        case "composition":
            return parseComposition(cursor: &cursor, source: source, json: json, privacy: privacy, appearance: appearance)
        case "guide":
            return parseGuide(
                cursor: &cursor,
                source: source,
                json: json,
                interactionPolicy: interactionPolicy,
                privacy: privacy,
                appearance: appearance
            )
        case "repeat-last":
            let output = parseOutput(cursor: &cursor, defaultFormat: .png) ?? .openEditor
            return success(AutomationRequest(
                source: source,
                command: .repeatLastCapture,
                interactionPolicy: interactionPolicy,
                privacy: privacy,
                captureDestination: captureDestination,
                appendAfterCompositionItemID: appendAfterCompositionItemID,
                replaceCompositionItemID: replaceCompositionItemID,
                appearance: appearance,
                output: output
            ), wantsJSON: json)
        case "export":
            guard cursor.next() == "current" else {
                return failure("Expected `export current`.", wantsJSON: json, exitCode: 64)
            }
            let format = cursor.value(after: "--format").flatMap(AutomationExportFormat.init(rawValue:)) ?? .png
            let output = parseOutput(cursor: &cursor, defaultFormat: format) ?? .saveFile(AutomationFileOutput(url: nil, format: format))
            return success(AutomationRequest(
                source: source,
                command: .exportCurrent(ExportCurrentAutomationCommand(format: format)),
                interactionPolicy: interactionPolicy,
                privacy: privacy,
                appearance: appearance,
                output: output
            ), wantsJSON: json)
        case "open":
            guard let path = cursor.value(after: "--file") ?? cursor.next() else {
                return failure("Open requires a file path.", wantsJSON: json, exitCode: 64)
            }
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let output = parseOutput(cursor: &cursor, defaultFormat: .png) ?? .openEditor
            return success(AutomationRequest(
                source: source,
                command: .openDocument(OpenDocumentAutomationCommand(url: url)),
                interactionPolicy: interactionPolicy,
                privacy: privacy,
                appearance: appearance,
                output: output
            ), wantsJSON: json)
        default:
            return failure("Unknown command `\(first)`.", wantsJSON: json, exitCode: 64)
        }
    }

    private static func parseGuide(
        cursor: inout ArgumentCursor,
        source: AutomationSource,
        json: Bool,
        interactionPolicy: AutomationInteractionPolicy,
        privacy: AutomationPrivacyOptions,
        appearance: AutomationOutputAppearance
    ) -> AutomationCLIParseResult {
        guard let action = cursor.next() else {
            return failure("Expected `guide start|pause|resume|add-step|stop|export`.", wantsJSON: json, exitCode: 64)
        }
        let command: GuideAutomationCommand
        switch action {
        case "start":
            guard let targetValue = cursor.value(after: "--target"),
                  let target = GuideAutomationTarget(rawValue: targetValue.lowercased()) else {
                return failure("Guide start requires --target window|app|region|display.", wantsJSON: json, exitCode: 64)
            }
            command = .start(target)
        case "pause": command = .pause
        case "resume": command = .resume
        case "add-step": command = .addStep
        case "stop": command = .stop
        case "export":
            guard let formatValue = cursor.value(after: "--format"),
                  let format = GuideAutomationExportFormat(rawValue: formatValue.lowercased()) else {
                return failure("Guide export requires --format pdf|gif|apng|mp4-full|mp4-highlights|mp4-slideshow|images|zip.", wantsJSON: json, exitCode: 64)
            }
            command = .export(format)
        default:
            return failure("Expected `guide start|pause|resume|add-step|stop|export`.", wantsJSON: json, exitCode: 64)
        }
        return success(
            AutomationRequest(
                source: source,
                command: .guide(command),
                interactionPolicy: interactionPolicy,
                privacy: privacy,
                appearance: appearance,
                output: .none
            ),
            wantsJSON: json
        )
    }

    private static func parsePresets(
        cursor: inout ArgumentCursor,
        source: AutomationSource,
        json: Bool,
        interactionPolicy: AutomationInteractionPolicy,
        privacy: AutomationPrivacyOptions,
        captureDestination: AutomationCaptureDestination,
        appendAfterCompositionItemID: UUID?,
        replaceCompositionItemID: UUID?,
        appearance: AutomationOutputAppearance
    ) -> AutomationCLIParseResult {
        guard let action = cursor.next() else {
            return failure("Expected `presets list` or `presets run`.", wantsJSON: json, exitCode: 64)
        }

        switch action {
        case "list":
            return success(AutomationRequest(source: source, command: .listPresets, appearance: appearance, output: .none), wantsJSON: json)
        case "run":
            let idValue = cursor.value(after: "--id")
            if let idValue, UUID(uuidString: idValue) == nil {
                return failure(
                    "Preset id must be a UUID.",
                    wantsJSON: json,
                    exitCode: 64
                )
            }
            let id = idValue.flatMap(UUID.init(uuidString:))
            let name = cursor.value(after: "--name")
            let output = parseOutput(cursor: &cursor, defaultFormat: .png) ?? .openEditor
            return success(AutomationRequest(
                source: source,
                command: .runPreset(RunPresetAutomationCommand(id: id, name: name)),
                interactionPolicy: interactionPolicy,
                privacy: privacy,
                captureDestination: captureDestination,
                appendAfterCompositionItemID: appendAfterCompositionItemID,
                replaceCompositionItemID: replaceCompositionItemID,
                appearance: appearance,
                output: output
            ), wantsJSON: json)
        default:
            return failure("Expected `presets list` or `presets run`.", wantsJSON: json, exitCode: 64)
        }
    }

    private static func parseCapture(
        cursor: inout ArgumentCursor,
        source: AutomationSource,
        json: Bool,
        interactionPolicy: AutomationInteractionPolicy,
        privacy: AutomationPrivacyOptions,
        captureDestination: AutomationCaptureDestination,
        appendAfterCompositionItemID: UUID?,
        replaceCompositionItemID: UUID?,
        appearance: AutomationOutputAppearance
    ) -> AutomationCLIParseResult {
        guard let targetName = cursor.next() else {
            return failure("Capture requires a target.", wantsJSON: json, exitCode: 64)
        }

        let output = parseOutput(cursor: &cursor, defaultFormat: .png) ?? .openEditor
        let delayValue = cursor.value(after: "--delay")
        if let delayValue, Int(delayValue) == nil {
            return failure(
                "Capture delay must be an integer.",
                wantsJSON: json,
                exitCode: 64
            )
        }
        let options = CaptureAutomationOptions(
            delay: delayValue.flatMap { Int($0) }.map { .seconds($0) } ?? .appDefault,
            includesCursor: cursor.contains("--include-cursor") ? true : nil,
            windowUIMap: cursor.contains("--ui-map") ? .enabled : .appDefault
        )

        let target: CaptureAutomationTarget
        switch targetName {
        case "fullscreen":
            let mode: AutomationFullscreenDisplayMode
            switch cursor.value(after: "--display")?.lowercased() {
            case nil, "app-default", "appdefault":
                mode = .appDefault
            case "current":
                mode = .current
            case "selected":
                mode = .selected
            case "all":
                mode = .all
            default:
                return failure(
                    "Fullscreen display must be app-default, current, selected, or all.",
                    wantsJSON: json,
                    exitCode: 64
                )
            }
            target = .fullscreen(FullscreenCaptureTarget(displayMode: mode))
        case "frontmost-window":
            target = .frontmostWindow
        case "region":
            if cursor.contains("--interactive") {
                target = .interactiveRegion
            } else if let rect = cursor.value(after: "--rect").flatMap({
                AutomationValueParser.rect($0)
            }) {
                target = .region(RegionCaptureSelector(rect: rect))
            } else {
                return failure("Region capture requires --rect or --interactive.", wantsJSON: json, exitCode: 64)
            }
        case "window":
            guard cursor.contains("--interactive") else {
                return failure("Window capture currently requires --interactive.", wantsJSON: json, exitCode: 64)
            }
            target = .interactiveWindow
        default:
            return failure("Unknown capture target `\(targetName)`.", wantsJSON: json, exitCode: 64)
        }

        return success(AutomationRequest(
            source: source,
            command: .capture(CaptureAutomationCommand(target: target, options: options)),
            interactionPolicy: interactionPolicy,
            privacy: privacy,
            captureDestination: captureDestination,
            appendAfterCompositionItemID: appendAfterCompositionItemID,
            replaceCompositionItemID: replaceCompositionItemID,
            appearance: appearance,
            output: output
        ), wantsJSON: json)
    }

    private static func parseComposition(
        cursor: inout ArgumentCursor,
        source: AutomationSource,
        json: Bool,
        privacy: AutomationPrivacyOptions,
        appearance: AutomationOutputAppearance
    ) -> AutomationCLIParseResult {
        guard let action = cursor.next() else {
            return failure("Expected `composition layout`, `composition compare`, or `composition template`.", wantsJSON: json, exitCode: 64)
        }

        let command: CompositionAutomationCommand
        switch action {
        case "layout":
            guard let layoutValue = cursor.value(after: "--layout"),
                  let layout = AutomationCompositionLayout(cliValue: layoutValue) else {
                return failure(
                    "Composition layout requires --layout auto|compare|steps|row|column|grid|freeform.",
                    wantsJSON: json,
                    exitCode: 64
                )
            }
            let axisValue = cursor.value(after: "--axis")
            if let axisValue, AutomationCompositionAxis(cliValue: axisValue) == nil {
                return failure("Composition axis must be horizontal or vertical.", wantsJSON: json, exitCode: 64)
            }
            let gridColumnsValue = cursor.value(after: "--grid-columns")
            let targetAspectRatioValue = cursor.value(after: "--target-aspect-ratio")
            let freeformWidthValue = cursor.value(after: "--freeform-width")
            let freeformHeightValue = cursor.value(after: "--freeform-height")
            let stepStartIndexValue = cursor.value(after: "--step-start-index")
            for (value, label) in [
                (gridColumnsValue, "Grid columns"),
                (stepStartIndexValue, "Step start index"),
            ] {
                if let value, Int(value) == nil {
                    return failure("\(label) must be an integer.", wantsJSON: json, exitCode: 64)
                }
            }
            for (value, label) in [
                (targetAspectRatioValue, "Target aspect ratio"),
                (freeformWidthValue, "Freeform width"),
                (freeformHeightValue, "Freeform height"),
            ] {
                if let value, Double(value) == nil {
                    return failure("\(label) must be a number.", wantsJSON: json, exitCode: 64)
                }
            }
            let stepNumberingValue = cursor.value(after: "--step-numbering")
            if let stepNumberingValue,
               AutomationCompositionStepNumberingStyle(cliValue: stepNumberingValue) == nil {
                return failure(
                    "Step numbering must be none, decimal, uppercase-letters, lowercase-letters, uppercase-roman, or lowercase-roman.",
                    wantsJSON: json,
                    exitCode: 64
                )
            }
            let stepCaptionsValue = cursor.value(after: "--step-captions")
            if let stepCaptionsValue, parseBool(stepCaptionsValue) == nil {
                return failure("Step captions must be true or false.", wantsJSON: json, exitCode: 64)
            }
            let stepConnectorValue = cursor.value(after: "--step-connector")
            if let stepConnectorValue,
               AutomationCompositionStepConnectorStyle(cliValue: stepConnectorValue) == nil {
                return failure("Step connector must be none, line, or arrow.", wantsJSON: json, exitCode: 64)
            }
            let axis = axisValue.flatMap(AutomationCompositionAxis.init(cliValue:))
            command = .setLayout(AutomationCompositionLayoutCommand(
                layout: layout,
                axis: axis,
                gridColumns: gridColumnsValue.flatMap(Int.init),
                targetAspectRatio: targetAspectRatioValue.flatMap(Double.init),
                freeformCanvasWidth: freeformWidthValue.flatMap(Double.init),
                freeformCanvasHeight: freeformHeightValue.flatMap(Double.init),
                stepNumberingStyle: stepNumberingValue.flatMap(AutomationCompositionStepNumberingStyle.init(cliValue:)),
                stepStartIndex: stepStartIndexValue.flatMap(Int.init),
                stepShowsCaptions: stepCaptionsValue.flatMap(parseBool),
                stepConnectorStyle: stepConnectorValue.flatMap(AutomationCompositionStepConnectorStyle.init(cliValue:))
            ))
        case "compare":
            guard let modeValue = cursor.value(after: "--mode"),
                  let mode = AutomationCompositionCompareMode(cliValue: modeValue) else {
                return failure(
                    "Composition compare requires --mode sideBySide|overlay|wipe|blink|difference|changeHighlight.",
                    wantsJSON: json,
                    exitCode: 64
                )
            }
            let firstItemValue = cursor.value(after: "--first-item-id")
            let secondItemValue = cursor.value(after: "--second-item-id")
            if let firstItemValue, UUID(uuidString: firstItemValue) == nil {
                return failure("Composition item ids must be UUIDs.", wantsJSON: json, exitCode: 64)
            }
            if let secondItemValue, UUID(uuidString: secondItemValue) == nil {
                return failure("Composition item ids must be UUIDs.", wantsJSON: json, exitCode: 64)
            }
            let axisValue = cursor.value(after: "--axis")
            if let axisValue, AutomationCompositionAxis(cliValue: axisValue) == nil {
                return failure("Composition axis must be horizontal or vertical.", wantsJSON: json, exitCode: 64)
            }
            let wipePositionValue = cursor.value(after: "--wipe-position")
            let overlayOpacityValue = cursor.value(after: "--overlay-opacity")
            let blinkIntervalValue = cursor.value(after: "--blink-interval")
            let differenceIntensityValue = cursor.value(after: "--difference-intensity")
            let highlightThresholdValue = cursor.value(after: "--highlight-threshold")
            for value in [
                wipePositionValue,
                overlayOpacityValue,
                blinkIntervalValue,
                differenceIntensityValue,
                highlightThresholdValue,
            ] {
                if let value, Double(value) == nil {
                    return failure("Composition comparison numeric settings must be numbers.", wantsJSON: json, exitCode: 64)
                }
            }
            command = .setCompareMode(AutomationCompositionCompareCommand(
                mode: mode,
                firstItemID: firstItemValue.flatMap(UUID.init(uuidString:)),
                secondItemID: secondItemValue.flatMap(UUID.init(uuidString:)),
                axis: axisValue.flatMap(AutomationCompositionAxis.init(cliValue:)),
                wipePosition: wipePositionValue.flatMap(Double.init),
                overlayOpacity: overlayOpacityValue.flatMap(Double.init),
                blinkInterval: blinkIntervalValue.flatMap(Double.init),
                differenceIntensity: differenceIntensityValue.flatMap(Double.init),
                changeHighlightColorHex: cursor.value(after: "--highlight-color"),
                changeHighlightThreshold: highlightThresholdValue.flatMap(Double.init),
                primaryLabel: cursor.value(after: "--primary-label"),
                secondaryLabel: cursor.value(after: "--secondary-label")
            ))
        case "template":
            let id = cursor.value(after: "--id")
            let name = cursor.value(after: "--name")
            guard id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    || name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return failure(
                    "Composition template requires --id or --name.",
                    wantsJSON: json,
                    exitCode: 64
                )
            }
            command = .applyTemplate(
                AutomationCompositionTemplateCommand(id: id, name: name)
            )
        default:
            return failure("Expected `composition layout`, `composition compare`, or `composition template`.", wantsJSON: json, exitCode: 64)
        }

        return success(AutomationRequest(
            source: source,
            command: .composition(command),
            interactionPolicy: .promptIfNeeded,
            privacy: privacy,
            appearance: appearance,
            output: .none
        ), wantsJSON: json)
    }

    private static func parseOutput(cursor: inout ArgumentCursor, defaultFormat: AutomationExportFormat) -> AutomationOutput? {
        if cursor.consumeFlag("--copy") {
            return .copyRenderedImage
        }

        if cursor.consumeFlag("--open-editor") {
            return .openEditor
        }

        if cursor.consumeFlag("--float") {
            return .floatReference
        }

        guard let outputPath = cursor.value(after: "--output") else {
            return nil
        }

        let format = cursor.value(after: "--format").flatMap(AutomationExportFormat.init(rawValue:)) ?? defaultFormat
        let url = URL(fileURLWithPath: NSString(string: outputPath).expandingTildeInPath)
        let file = AutomationFileOutput(
            url: url,
            format: format,
            overwrite: cursor.contains("--overwrite"),
            revealInFinder: cursor.contains("--reveal")
        )

        return format == .sss ? .saveEditableDocument(file) : .saveFile(file)
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func success(_ request: AutomationRequest, wantsJSON: Bool) -> AutomationCLIParseResult {
        if let error = request.validationError {
            return failure(error.message, wantsJSON: wantsJSON, exitCode: 64)
        }
        return AutomationCLIParseResult(request: request, wantsJSON: wantsJSON, exitCode: 0, errorMessage: nil)
    }

    private static func failure(_ message: String, wantsJSON: Bool, exitCode: Int32) -> AutomationCLIParseResult {
        AutomationCLIParseResult(request: nil, wantsJSON: wantsJSON, exitCode: exitCode, errorMessage: message)
    }

    private static func firstFlagMissingValue(
        in arguments: [String]
    ) -> String? {
        let valueFlags: Set<String> = [
            "--after-item-id",
            "--appearance",
            "--axis",
            "--blink-interval",
            "--delay",
            "--destination",
            "--difference-intensity",
            "--display",
            "--file",
            "--first-item-id",
            "--format",
            "--freeform-height",
            "--freeform-width",
            "--grid-columns",
            "--highlight-color",
            "--highlight-threshold",
            "--id",
            "--layout",
            "--mode",
            "--name",
            "--output",
            "--overlay-opacity",
            "--primary-label",
            "--rect",
            "--replace-item-id",
            "--second-item-id",
            "--secondary-label",
            "--step-captions",
            "--step-connector",
            "--step-numbering",
            "--step-start-index",
            "--target",
            "--target-aspect-ratio",
            "--wipe-position",
        ]
        for (index, argument) in arguments.enumerated()
        where valueFlags.contains(argument) {
            guard arguments.indices.contains(index + 1),
                  !arguments[index + 1].hasPrefix("--") else {
                return argument
            }
        }
        return nil
    }
}

private extension AutomationOutputAppearance {
    nonisolated init?(cliValue: String) {
        switch cliValue.lowercased() {
        case "app-default", "appdefault":
            self = .appDefault
        case "plain":
            self = .plain
        case "styled":
            self = .styled
        default:
            return nil
        }
    }
}

private extension AutomationCompositionLayout {
    nonisolated init?(cliValue: String) {
        self.init(rawValue: cliValue.lowercased())
    }
}

private extension AutomationCompositionCompareMode {
    nonisolated init?(cliValue: String) {
        switch cliValue.lowercased().replacingOccurrences(of: "-", with: "") {
        case "sidebyside":
            self = .sideBySide
        case "overlay":
            self = .overlay
        case "wipe":
            self = .wipe
        case "blink":
            self = .blink
        case "difference":
            self = .difference
        case "changehighlight":
            self = .changeHighlight
        default:
            return nil
        }
    }
}

private extension AutomationCompositionAxis {
    nonisolated init?(cliValue: String) {
        self.init(rawValue: cliValue.lowercased())
    }
}

private extension AutomationCompositionStepNumberingStyle {
    nonisolated init?(cliValue: String) {
        switch cliValue.lowercased().replacingOccurrences(of: "-", with: "") {
        case "none":
            self = .none
        case "decimal":
            self = .decimal
        case "uppercaseletters":
            self = .uppercaseLetters
        case "lowercaseletters":
            self = .lowercaseLetters
        case "uppercaseroman":
            self = .uppercaseRoman
        case "lowercaseroman":
            self = .lowercaseRoman
        default:
            return nil
        }
    }
}

private extension AutomationCompositionStepConnectorStyle {
    nonisolated init?(cliValue: String) {
        self.init(rawValue: cliValue.lowercased())
    }
}

nonisolated struct ArgumentCursor: Equatable {
    private var arguments: [String]
    private var consumed = Set<Int>()
    private var index = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func next() -> String? {
        while index < arguments.count {
            defer { index += 1 }
            guard !consumed.contains(index) else {
                continue
            }
            return arguments[index]
        }
        return nil
    }

    func contains(_ flag: String) -> Bool {
        arguments.contains(flag)
    }

    mutating func consumeFlag(_ flag: String) -> Bool {
        guard let flagIndex = arguments.firstIndex(of: flag) else {
            return false
        }
        consumed.insert(flagIndex)
        return true
    }

    mutating func value(after flag: String) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag),
              arguments.indices.contains(flagIndex + 1) else {
            return nil
        }
        consumed.insert(flagIndex)
        consumed.insert(flagIndex + 1)
        return arguments[flagIndex + 1]
    }
}
