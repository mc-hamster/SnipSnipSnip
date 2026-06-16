import CoreGraphics
import Foundation

nonisolated enum AutomationURLRouter {
    static let versionHost = "v1"

    static func request(from url: URL) -> AutomationRequest? {
        guard url.scheme == AppImportURL.scheme,
              url.host == versionHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let query = Query(components.queryItems ?? [])
        let path = components.path
        let source = AutomationSource(kind: .urlScheme, caller: query.string("caller"))
        let output = query.urlOutput(default: defaultOutput(for: path))
        let privacy = AutomationPrivacyOptions(privateCapture: query.bool("private") ?? false)
        let policy: AutomationInteractionPolicy = query.bool("interactive") == true ? .requireUserSelection : .promptIfNeeded

        switch path {
        case "/status":
            return AutomationRequest(source: source, command: .status, interactionPolicy: .promptIfNeeded, privacy: privacy, output: .none)
        case "/presets/run":
            let command = RunPresetAutomationCommand(id: query.uuid("id"), name: query.string("name"))
            return AutomationRequest(source: source, command: .runPreset(command), interactionPolicy: policy, privacy: privacy, output: output)
        case "/capture/fullscreen":
            let displayMode = AutomationFullscreenDisplayMode(urlValue: query.string("display"))
            let command = CaptureAutomationCommand(target: .fullscreen(FullscreenCaptureTarget(displayMode: displayMode)))
            return AutomationRequest(source: source, command: .capture(command), interactionPolicy: .promptIfNeeded, privacy: privacy, output: output)
        case "/capture/frontmost-window":
            let command = CaptureAutomationCommand(target: .frontmostWindow)
            return AutomationRequest(source: source, command: .capture(command), interactionPolicy: .promptIfNeeded, privacy: privacy, output: output)
        case "/capture/region":
            let command: CaptureAutomationCommand
            if query.bool("interactive") == true {
                command = CaptureAutomationCommand(target: .interactiveRegion)
            } else if let rect = query.rect() {
                command = CaptureAutomationCommand(target: .region(RegionCaptureSelector(rect: rect)))
            } else {
                command = CaptureAutomationCommand(target: .interactiveRegion)
            }
            return AutomationRequest(source: source, command: .capture(command), interactionPolicy: policy, privacy: privacy, output: output)
        case "/capture/window":
            let command = CaptureAutomationCommand(target: .interactiveWindow)
            return AutomationRequest(source: source, command: .capture(command), interactionPolicy: .requireUserSelection, privacy: privacy, output: output)
        case "/repeat-last":
            return AutomationRequest(source: source, command: .repeatLastCapture, interactionPolicy: policy, privacy: privacy, output: output)
        default:
            return nil
        }
    }

    static func isAutomationURL(_ url: URL) -> Bool {
        request(from: url) != nil
    }

    private static func defaultOutput(for path: String) -> AutomationOutput {
        path == "/status" ? .none : .openEditor
    }
}

private extension AutomationURLRouter {
    nonisolated struct Query {
        private let items: [URLQueryItem]

        init(_ items: [URLQueryItem]) {
            self.items = items
        }

        func string(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func bool(_ name: String) -> Bool? {
            guard let value = string(name)?.lowercased(), !value.isEmpty else {
                return nil
            }

            switch value {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }

        func uuid(_ name: String) -> UUID? {
            string(name).flatMap(UUID.init(uuidString:))
        }

        func rect() -> CGRect? {
            if let value = string("rect") {
                let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard parts.count == 4 else {
                    return nil
                }
                return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]).gscIntegralStandardized
            }

            guard let x = string("x").flatMap(Double.init),
                  let y = string("y").flatMap(Double.init),
                  let width = string("width").flatMap(Double.init),
                  let height = string("height").flatMap(Double.init) else {
                return nil
            }

            return CGRect(x: x, y: y, width: width, height: height).gscIntegralStandardized
        }

        func urlOutput(default defaultOutput: AutomationOutput) -> AutomationOutput {
            guard let output = string("output")?.lowercased(), !output.isEmpty else {
                return defaultOutput
            }

            switch output {
            case "editor", "open-editor":
                return .openEditor
            case "clipboard", "copy":
                return .copyRenderedImage
            case "float", "reference":
                return .floatReference
            case "none":
                return .none
            default:
                return defaultOutput
            }
        }
    }
}

private extension AutomationFullscreenDisplayMode {
    nonisolated init(urlValue: String?) {
        switch urlValue?.lowercased() {
        case "current":
            self = .current
        case "selected":
            self = .selected
        case "all", "all-displays":
            self = .all
        default:
            self = .appDefault
        }
    }
}
