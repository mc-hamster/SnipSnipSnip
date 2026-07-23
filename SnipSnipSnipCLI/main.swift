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
        return exitCode(for: result)
    }

    private func appleScriptCommand() -> String? {
        var cursor = ArgumentCursor(arguments)
        _ = cursor.consumeFlag("--json")
        guard let first = cursor.next() else {
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

    private func exitCode(for json: String) -> Int32 {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else {
            return 0
        }

        if status == "succeeded" {
            return 0
        }

        let error = object["error"] as? [String: Any]
        switch error?["code"] as? String {
        case "invalidRequest":
            return 64
        case "featureUnavailable", "targetUnavailable", "proFeatureRequired":
            return 69
        case "outputFailed":
            return 74
        case "permissionDenied", "confirmationRequired":
            return 77
        case "userCancelled":
            return 130
        default:
            return 70
        }
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
