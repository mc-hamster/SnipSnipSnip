import Foundation

/// Reject options that would otherwise be silently ignored or interpreted with
/// conflicting precedence before the shared parser constructs a request.
nonisolated enum AutomationCLIArgumentValidation {
    static func error(in arguments: [String]) -> String? {
        let switches: Set<String> = ["--json", "--interactive", "--private", "--copy", "--open-editor", "--float", "--overwrite", "--reveal", "--include-cursor", "--ui-map"]
        let output: Set<String> = ["--copy", "--open-editor", "--float", "--output", "--format", "--overwrite", "--reveal", "--appearance"]
        let capture: Set<String> = output.union(["--interactive", "--private", "--destination", "--after-item-id", "--replace-item-id"])
        let layout: Set<String> = ["--layout", "--axis", "--grid-columns", "--target-aspect-ratio", "--freeform-width", "--freeform-height", "--step-numbering", "--step-start-index", "--step-captions", "--step-connector"]
        let compare: Set<String> = ["--mode", "--axis", "--first-item-id", "--second-item-id", "--wipe-position", "--overlay-opacity", "--blink-interval", "--difference-intensity", "--highlight-color", "--highlight-threshold", "--primary-label", "--secondary-label"]
        let all = capture.union(layout).union(compare).union(["--id", "--name", "--file", "--target", "--display", "--rect", "--delay", "--include-cursor", "--ui-map", "--json"])
        var options = Set<String>()
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                positional.append(argument)
                index += 1
                continue
            }
            guard all.contains(argument) else { return "Unknown option \(argument)." }
            guard options.insert(argument).inserted else { return "Duplicate option \(argument)." }
            if !switches.contains(argument) {
                let permitsEmptyValue = ["--primary-label", "--secondary-label"].contains(argument)
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"),
                      permitsEmptyValue || !arguments[index + 1].isEmpty else {
                    return "\(argument) requires a value."
                }
                index += 1
            }
            index += 1
        }
        let allowed: Set<String>
        let expectedCount: Int
        switch positional.first {
        case "status": allowed = []; expectedCount = 1
        case "presets":
            allowed = positional.dropFirst().first == "list" ? [] : capture.union(["--id", "--name"])
            expectedCount = 2
        case "capture":
            allowed = capture.union(["--delay", "--include-cursor", "--ui-map"])
                .union(positional.dropFirst().first == "fullscreen" ? ["--display"] : [])
                .union(positional.dropFirst().first == "region" ? ["--rect"] : [])
            expectedCount = 2
        case "repeat-last": allowed = capture; expectedCount = 1
        case "export": allowed = output.union(["--interactive"]); expectedCount = 2
        case "open": allowed = output.union(["--file", "--interactive"]); expectedCount = options.contains("--file") ? 1 : 2
        case "composition":
            switch positional.dropFirst().first {
            case "layout": allowed = layout
            case "compare": allowed = compare
            default: allowed = ["--id", "--name"]
            }
            expectedCount = 2
        case "guide":
            switch positional.dropFirst().first {
            case "start": allowed = ["--target", "--private", "--interactive"]
            case "export": allowed = ["--format"]
            default: allowed = []
            }
            expectedCount = 2
        default: return "Unknown or missing command."
        }
        guard positional.count == expectedCount else { return "Unexpected or missing command arguments." }
        if let unexpected = options.subtracting(allowed.union(["--json"])).sorted().first {
            return "\(unexpected) is not supported by this command."
        }
        if options.intersection(["--copy", "--open-editor", "--float", "--output"]).count > 1 {
            return "Choose only one output destination."
        }
        if options.contains("--rect"), options.contains("--interactive") {
            return "Choose a fixed rectangle or interactive selection, not both."
        }
        if !options.contains("--output"), !options.intersection(["--overwrite", "--reveal"]).isEmpty {
            return "Overwrite and reveal require a file output path."
        }
        return nil
    }
}
