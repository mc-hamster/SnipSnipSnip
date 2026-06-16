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
        let source = AutomationSource(kind: .commandLine, caller: "snipsnipsnipctl")

        guard let first = cursor.next() else {
            return failure("Missing command.", wantsJSON: json, exitCode: 64)
        }

        let interactionPolicy: AutomationInteractionPolicy = cursor.contains("--interactive") ? .requireUserSelection : .never
        let privacy = AutomationPrivacyOptions(privateCapture: cursor.contains("--private"))

        switch first {
        case "status":
            return success(AutomationRequest(source: source, command: .status, output: .none), wantsJSON: json)
        case "presets":
            return parsePresets(cursor: &cursor, source: source, json: json, interactionPolicy: interactionPolicy, privacy: privacy)
        case "capture":
            return parseCapture(cursor: &cursor, source: source, json: json, interactionPolicy: interactionPolicy, privacy: privacy)
        case "repeat-last":
            let output = parseOutput(cursor: &cursor, defaultFormat: .png) ?? .openEditor
            return success(AutomationRequest(source: source, command: .repeatLastCapture, interactionPolicy: interactionPolicy, privacy: privacy, output: output), wantsJSON: json)
        case "export":
            guard cursor.next() == "current" else {
                return failure("Expected `export current`.", wantsJSON: json, exitCode: 64)
            }
            let format = cursor.value(after: "--format").flatMap(AutomationExportFormat.init(rawValue:)) ?? .png
            let output = parseOutput(cursor: &cursor, defaultFormat: format) ?? .saveFile(AutomationFileOutput(url: nil, format: format))
            return success(AutomationRequest(source: source, command: .exportCurrent(ExportCurrentAutomationCommand(format: format)), interactionPolicy: interactionPolicy, privacy: privacy, output: output), wantsJSON: json)
        case "open":
            guard let path = cursor.value(after: "--file") ?? cursor.next() else {
                return failure("Open requires a file path.", wantsJSON: json, exitCode: 64)
            }
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let output = parseOutput(cursor: &cursor, defaultFormat: .png) ?? .openEditor
            return success(AutomationRequest(source: source, command: .openDocument(OpenDocumentAutomationCommand(url: url)), interactionPolicy: interactionPolicy, privacy: privacy, output: output), wantsJSON: json)
        default:
            return failure("Unknown command `\(first)`.", wantsJSON: json, exitCode: 64)
        }
    }

    private static func parsePresets(
        cursor: inout ArgumentCursor,
        source: AutomationSource,
        json: Bool,
        interactionPolicy: AutomationInteractionPolicy,
        privacy: AutomationPrivacyOptions
    ) -> AutomationCLIParseResult {
        guard let action = cursor.next() else {
            return failure("Expected `presets list` or `presets run`.", wantsJSON: json, exitCode: 64)
        }

        switch action {
        case "list":
            return success(AutomationRequest(source: source, command: .listPresets, output: .none), wantsJSON: json)
        case "run":
            let id = cursor.value(after: "--id").flatMap(UUID.init(uuidString:))
            let name = cursor.value(after: "--name")
            let output = parseOutput(cursor: &cursor, defaultFormat: .png) ?? .openEditor
            return success(AutomationRequest(
                source: source,
                command: .runPreset(RunPresetAutomationCommand(id: id, name: name)),
                interactionPolicy: interactionPolicy,
                privacy: privacy,
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
        privacy: AutomationPrivacyOptions
    ) -> AutomationCLIParseResult {
        guard let targetName = cursor.next() else {
            return failure("Capture requires a target.", wantsJSON: json, exitCode: 64)
        }

        let output = parseOutput(cursor: &cursor, defaultFormat: .png) ?? .openEditor
        let options = CaptureAutomationOptions(
            delay: cursor.value(after: "--delay").flatMap { Int($0) }.map { .seconds($0) } ?? .appDefault,
            includesCursor: cursor.contains("--include-cursor") ? true : nil,
            windowUIMap: cursor.contains("--ui-map") ? .enabled : .appDefault
        )

        let target: CaptureAutomationTarget
        switch targetName {
        case "fullscreen":
            let mode: AutomationFullscreenDisplayMode
            switch cursor.value(after: "--display")?.lowercased() {
            case "current":
                mode = .current
            case "selected":
                mode = .selected
            case "all":
                mode = .all
            default:
                mode = .appDefault
            }
            target = .fullscreen(FullscreenCaptureTarget(displayMode: mode))
        case "frontmost-window":
            target = .frontmostWindow
        case "region":
            if cursor.contains("--interactive") {
                target = .interactiveRegion
            } else if let rect = cursor.value(after: "--rect").flatMap(parseRect) {
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
            output: output
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

    private static func parseRect(_ value: String) -> CGRect? {
        let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.count == 4 else {
            return nil
        }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]).gscIntegralStandardized
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
