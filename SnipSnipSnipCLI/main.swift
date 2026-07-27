import Foundation

struct CLI {
    var arguments: [String]

    func run() -> Int32 {
        guard let command = appleScriptCommand() else {
            printError("Invalid snipsnipsnipctl command.")
            return 64
        }

        let source = """
        tell application id "com.oontz.SnipSnipSnip"
            \(command)
        end tell
        """

        var error: NSDictionary?
        guard let script = NSAppleScript(source: source),
              let result = script.executeAndReturnError(&error).stringValue else {
            if let error {
                printError(String(describing: error))
            }
            return 70
        }

        print(result)
        return CLIExitCodeMapper.exitCode(for: result)
    }

    private func appleScriptCommand() -> String? {
        let valueFlags: Set<String> = [
            "--after-item-id",
            "--appearance",
            "--axis",
            "--blink-interval",
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
                return nil
            }
        }

        var cursor = ArgumentCursor(arguments)
        _ = cursor.consumeFlag("--json")
        guard let first = cursor.next() else {
            return nil
        }
        if cursor.contains("--after-item-id") {
            guard let appendAfterItemID = cursor.value(after: "--after-item-id"),
                  UUID(uuidString: appendAfterItemID) != nil else {
                return nil
            }
        }
        if cursor.contains("--after-item-id"),
           cursor.value(after: "--destination")?.lowercased() != "append" {
            return nil
        }

        switch first {
        case "status":
            return "automationStatus"
        case "presets":
            guard let action = cursor.next() else {
                return nil
            }
            switch action {
            case "list":
                return "listCapturePresets"
            case "run":
                var arguments: [String] = []
                if let id = cursor.value(after: "--id") {
                    arguments.append("id:\"\(escape(id))\"")
                }
                if let name = cursor.value(after: "--name") {
                    arguments.append("name:\"\(escape(name))\"")
                }
                arguments.append(contentsOf: outputParts(cursor: &cursor))
                if cursor.contains("--private") {
                    arguments.append("privateCapture:true")
                }
                return appleScriptCommand("runCapturePreset", arguments: arguments)
            default:
                return nil
            }
        case "capture":
            guard let target = cursor.next() else {
                return nil
            }
            let commandName: String
            switch target {
            case "fullscreen":
                commandName = "captureFullscreen"
            case "frontmost-window":
                commandName = "captureFrontmostWindow"
            case "region":
                commandName = "captureRegion"
            case "window":
                commandName = "captureWindow"
            default:
                return nil
            }

            var arguments: [String] = []
            if target == "fullscreen", let display = cursor.value(after: "--display") {
                arguments.append("display:\"\(escape(display))\"")
            }
            if target == "region" {
                guard cursor.contains("--interactive") || cursor.value(after: "--rect") != nil else {
                    return nil
                }
                if let rect = cursor.value(after: "--rect") {
                    arguments.append("rect:\"\(escape(rect))\"")
                }
                if cursor.contains("--interactive") {
                    arguments.append("interactive:true")
                }
            }
            if target == "window" {
                guard cursor.contains("--interactive") else {
                    return nil
                }
                arguments.append("interactive:true")
            }
            arguments.append(contentsOf: outputParts(cursor: &cursor))
            if cursor.contains("--private") {
                arguments.append("privateCapture:true")
            }
            return appleScriptCommand(commandName, arguments: arguments)
        case "composition":
            guard let action = cursor.next() else {
                return nil
            }
            switch action {
            case "layout":
                guard let layout = cursor.value(after: "--layout"),
                      ["auto", "compare", "steps", "row", "column", "grid", "freeform"]
                        .contains(layout.lowercased()) else {
                    return nil
                }
                var arguments = ["layout:\"\(escape(layout.lowercased()))\""]
                if let axis = cursor.value(after: "--axis") {
                    guard ["horizontal", "vertical"].contains(axis.lowercased()) else {
                        return nil
                    }
                    arguments.append("axis:\"\(escape(axis.lowercased()))\"")
                }
                for (flag, argument) in [
                    ("--step-numbering", "stepNumbering"),
                    ("--step-connector", "stepConnector"),
                ] {
                    if let value = cursor.value(after: flag) {
                        let normalized = value.lowercased()
                        if flag == "--step-numbering",
                           ![
                               "none",
                               "decimal",
                               "uppercase-letters",
                               "lowercase-letters",
                               "uppercase-roman",
                               "lowercase-roman",
                           ]
                            .contains(normalized) {
                            return nil
                        }
                        if flag == "--step-connector",
                           !["none", "line", "arrow"].contains(normalized) {
                            return nil
                        }
                        arguments.append("\(argument):\"\(escape(value))\"")
                    }
                }
                for (flag, argument) in [
                    ("--grid-columns", "gridColumns"),
                    ("--step-start-index", "stepStartIndex"),
                ] {
                    if let value = cursor.value(after: flag) {
                        guard Int(value) != nil else {
                            return nil
                        }
                        arguments.append("\(argument):\(value)")
                    }
                }
                for (flag, argument) in [
                    ("--target-aspect-ratio", "targetAspectRatio"),
                    ("--freeform-width", "freeformWidth"),
                    ("--freeform-height", "freeformHeight"),
                ] {
                    if let value = cursor.value(after: flag) {
                        guard let number = Double(value), number.isFinite else {
                            return nil
                        }
                        arguments.append("\(argument):\(value)")
                    }
                }
                if let value = cursor.value(after: "--step-captions") {
                    switch value.lowercased() {
                    case "1", "true", "yes", "on":
                        arguments.append("stepCaptions:true")
                    case "0", "false", "no", "off":
                        arguments.append("stepCaptions:false")
                    default:
                        return nil
                    }
                }
                return appleScriptCommand("setCompositionLayout", arguments: arguments)
            case "compare":
                guard let mode = cursor.value(after: "--mode"),
                      ["side-by-side", "sidebyside", "overlay", "wipe", "blink", "difference", "change-highlight", "changehighlight"]
                        .contains(mode.lowercased()) else {
                    return nil
                }
                var arguments = ["mode:\"\(escape(mode.lowercased()))\""]
                for (flag, argument) in [
                    ("--first-item-id", "firstItemID"),
                    ("--second-item-id", "secondItemID"),
                    ("--axis", "axis"),
                    ("--highlight-color", "highlightColor"),
                    ("--primary-label", "primaryLabel"),
                    ("--secondary-label", "secondaryLabel"),
                ] {
                    if let value = cursor.value(after: flag) {
                        if ["--first-item-id", "--second-item-id"].contains(flag),
                           UUID(uuidString: value) == nil {
                            return nil
                        }
                        if flag == "--axis",
                           !["horizontal", "vertical"].contains(value.lowercased()) {
                            return nil
                        }
                        arguments.append("\(argument):\"\(escape(value))\"")
                    }
                }
                for (flag, argument) in [
                    ("--wipe-position", "wipePosition"),
                    ("--overlay-opacity", "overlayOpacity"),
                    ("--blink-interval", "blinkInterval"),
                    ("--difference-intensity", "differenceIntensity"),
                    ("--highlight-threshold", "highlightThreshold"),
                ] {
                    if let value = cursor.value(after: flag) {
                        guard let number = Double(value), number.isFinite else {
                            return nil
                        }
                        arguments.append("\(argument):\(value)")
                    }
                }
                return appleScriptCommand("setCompositionCompareMode", arguments: arguments)
            case "template":
                var arguments: [String] = []
                if let id = cursor.value(after: "--id"),
                   !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    arguments.append("id:\"\(escape(id))\"")
                }
                if let name = cursor.value(after: "--name"),
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    arguments.append("name:\"\(escape(name))\"")
                }
                guard !arguments.isEmpty else {
                    return nil
                }
                return appleScriptCommand(
                    "applyCompositionTemplate",
                    arguments: arguments
                )
            default:
                return nil
            }
        case "guide":
            guard let action = cursor.next() else {
                return nil
            }
            var arguments = ["action:\"\(escape(action))\""]
            switch action {
            case "start":
                guard let target = cursor.value(after: "--target"),
                      ["window", "app", "region", "display"].contains(target.lowercased()) else {
                    return nil
                }
                arguments.append("target:\"\(escape(target.lowercased()))\"")
                if cursor.contains("--private") {
                    arguments.append("privateCapture:true")
                }
            case "pause", "resume", "add-step", "stop":
                break
            case "export":
                guard let format = cursor.value(after: "--format"),
                      ["pdf", "gif", "apng", "mp4-full", "mp4-highlights", "mp4-slideshow", "images", "zip"]
                        .contains(format.lowercased()) else {
                    return nil
                }
                arguments.append("format:\"\(escape(format.lowercased()))\"")
            default:
                return nil
            }
            return appleScriptCommand("guide", arguments: arguments)
        case "repeat-last":
            return appleScriptCommand("repeatLastCapture", arguments: outputParts(cursor: &cursor))
        case "export":
            guard cursor.next() == "current" else {
                return nil
            }
            var arguments: [String] = []
            if let format = cursor.value(after: "--format") {
                arguments.append("format:\"\(escape(format))\"")
            }
            arguments.append(contentsOf: outputParts(cursor: &cursor))
            return appleScriptCommand("exportCurrentScreenshot", arguments: arguments)
        case "open":
            let path = cursor.value(after: "--file") ?? cursor.next()
            guard let path else {
                return nil
            }
            var arguments = ["path:\"\(escape((path as NSString).expandingTildeInPath))\""]
            arguments.append(contentsOf: outputParts(cursor: &cursor))
            return appleScriptCommand("openSnipDocument", arguments: arguments)
        default:
            return nil
        }
    }

    private func outputParts(cursor: inout ArgumentCursor) -> [String] {
        var parts: [String] = []

        if cursor.consumeFlag("--copy") {
            parts.append("output:\"clipboard\"")
        } else if cursor.consumeFlag("--open-editor") {
            parts.append("output:\"editor\"")
        } else if cursor.consumeFlag("--float") {
            parts.append("output:\"float\"")
        }

        if let output = cursor.value(after: "--output") {
            parts.append("outputPath:\"\(escape((output as NSString).expandingTildeInPath))\"")
        }

        if let format = cursor.value(after: "--format") {
            parts.append("format:\"\(escape(format))\"")
        }

        if cursor.contains("--overwrite") {
            parts.append("overwrite:true")
        }

        if let destination = cursor.value(after: "--destination") {
            parts.append("destination:\"\(escape(destination))\"")
        }

        if let appendAfterItemID = cursor.value(after: "--after-item-id") {
            parts.append("afterItemID:\"\(escape(appendAfterItemID))\"")
        }

        if let replaceItemID = cursor.value(after: "--replace-item-id") {
            parts.append("replaceItemID:\"\(escape(replaceItemID))\"")
        }

        if let appearance = cursor.value(after: "--appearance") {
            parts.append("appearance:\"\(escape(appearance))\"")
        }

        return parts
    }

    private func appleScriptCommand(_ name: String, arguments: [String]) -> String {
        guard !arguments.isEmpty else {
            return name
        }
        return "\(name) given \(arguments.joined(separator: ", "))"
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

}

struct ArgumentCursor {
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

func printError(_ value: String) {
    FileHandle.standardError.write(Data((value + "\n").utf8))
}

exit(CLI(arguments: Array(CommandLine.arguments.dropFirst())).run())
