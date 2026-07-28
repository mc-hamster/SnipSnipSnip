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
        for key in ["private", "interactive", "overwrite", "reveal"] {
            if query.string(key) != nil, query.bool(key) == nil {
                return nil
            }
        }
        if let outputValue = query.string("output"),
           ![
               "editor",
               "open-editor",
               "clipboard",
               "copy",
               "float",
               "reference",
               "none",
               "file",
           ].contains(outputValue.lowercased()) {
            return nil
        }
        if query.string("output")?.lowercased() == "file",
           path != "/export/current" {
            return nil
        }
        if path != "/guide/export",
           let formatValue = query.string("format"),
           AutomationExportFormat(rawValue: formatValue.lowercased()) == nil {
            return nil
        }
        let source = AutomationSource(kind: .urlScheme, caller: query.string("caller"))
        let output = query.urlOutput(default: defaultOutput(for: path))
        let privacy = AutomationPrivacyOptions(privateCapture: query.bool("private") ?? false)
        let policy: AutomationInteractionPolicy = query.bool("interactive") == true ? .requireUserSelection : .promptIfNeeded
        let destinationValue = query.string("destination")
        if let destinationValue,
           AutomationCaptureDestination(rawValue: destinationValue.lowercased()) == nil {
            return nil
        }
        let captureDestination = destinationValue
            .flatMap { AutomationCaptureDestination(rawValue: $0.lowercased()) } ?? .new
        let appendAfterItemValue = query.string("after")
        if let appendAfterItemValue, UUID(uuidString: appendAfterItemValue) == nil {
            return nil
        }
        let appendAfterCompositionItemID = appendAfterItemValue.flatMap(UUID.init(uuidString:))
        let canonicalItemValue = query.string("item")
        let legacyReplaceItemValue = query.string("replaceItemID")
        if let canonicalItemValue,
           let legacyReplaceItemValue,
           canonicalItemValue != legacyReplaceItemValue {
            return nil
        }
        let replaceItemValue = canonicalItemValue ?? legacyReplaceItemValue
        if let replaceItemValue, UUID(uuidString: replaceItemValue) == nil {
            return nil
        }
        let replaceCompositionItemID = replaceItemValue.flatMap(UUID.init(uuidString:))
        let appearanceValue = query.string("appearance")
        if let appearanceValue, AutomationOutputAppearance(urlValue: appearanceValue) == nil {
            return nil
        }
        let appearance = appearanceValue.flatMap(AutomationOutputAppearance.init(urlValue:)) ?? .appDefault

        func request(
            _ command: AutomationCommand,
            interactionPolicy: AutomationInteractionPolicy = policy,
            output requestOutput: AutomationOutput = output,
            usesCaptureDestination: Bool = false
        ) -> AutomationRequest {
            AutomationRequest(
                source: source,
                command: command,
                interactionPolicy: interactionPolicy,
                privacy: privacy,
                captureDestination: usesCaptureDestination ? captureDestination : .new,
                appendAfterCompositionItemID: usesCaptureDestination ? appendAfterCompositionItemID : nil,
                replaceCompositionItemID: usesCaptureDestination ? replaceCompositionItemID : nil,
                appearance: appearance,
                output: requestOutput
            )
        }

        switch path {
        case "/status":
            return request(.status, interactionPolicy: .promptIfNeeded, output: .none)
        case "/presets/run":
            let command = RunPresetAutomationCommand(id: query.uuid("id"), name: query.string("name"))
            return request(.runPreset(command), usesCaptureDestination: true)
        case "/capture/fullscreen":
            if let displayValue = query.string("display"),
               ![
                   "app-default",
                   "appdefault",
                   "current",
                   "selected",
                   "all",
                   "all-displays",
               ].contains(displayValue.lowercased()) {
                return nil
            }
            let displayMode = AutomationFullscreenDisplayMode(urlValue: query.string("display"))
            let command = CaptureAutomationCommand(target: .fullscreen(FullscreenCaptureTarget(displayMode: displayMode)))
            return request(.capture(command), interactionPolicy: .promptIfNeeded, usesCaptureDestination: true)
        case "/capture/frontmost-window":
            let command = CaptureAutomationCommand(target: .frontmostWindow)
            return request(.capture(command), interactionPolicy: .promptIfNeeded, usesCaptureDestination: true)
        case "/capture/region":
            let command: CaptureAutomationCommand
            if query.bool("interactive") == true {
                command = CaptureAutomationCommand(target: .interactiveRegion)
            } else if let rect = query.rect() {
                command = CaptureAutomationCommand(target: .region(RegionCaptureSelector(rect: rect)))
            } else if ["rect", "x", "y", "width", "height"].contains(
                where: { query.string($0) != nil }
            ) {
                return nil
            } else {
                command = CaptureAutomationCommand(target: .interactiveRegion)
            }
            return request(.capture(command), usesCaptureDestination: true)
        case "/capture/window":
            let command = CaptureAutomationCommand(target: .interactiveWindow)
            return request(.capture(command), interactionPolicy: .requireUserSelection, usesCaptureDestination: true)
        case "/repeat-last":
            return request(.repeatLastCapture, usesCaptureDestination: true)
        case "/export/current":
            guard let formatValue = query.string("format"),
                  let format = AutomationExportFormat(rawValue: formatValue.lowercased()) else {
                return nil
            }
            return request(.exportCurrent(ExportCurrentAutomationCommand(format: format)))
        case "/composition/layout":
            guard let layoutValue = query.string("layout"),
                  let layout = AutomationCompositionLayout(rawValue: layoutValue.lowercased()) else {
                return nil
            }
            let axisValue = query.string("axis")
            if let axisValue,
               AutomationCompositionAxis(rawValue: axisValue.lowercased()) == nil {
                return nil
            }
            for key in ["gridColumns", "stepStartIndex"] {
                if query.string(key) != nil, query.int(key) == nil {
                    return nil
                }
            }
            for key in ["targetAspectRatio", "freeformWidth", "freeformHeight"] {
                if query.string(key) != nil, query.double(key) == nil {
                    return nil
                }
            }
            let stepNumberingValue = query.string("stepNumbering")
            if let stepNumberingValue,
               AutomationCompositionStepNumberingStyle(urlValue: stepNumberingValue) == nil {
                return nil
            }
            let stepCaptionsValue = query.string("stepCaptions")
            if stepCaptionsValue != nil, query.bool("stepCaptions") == nil {
                return nil
            }
            let stepConnectorValue = query.string("stepConnector")
            if let stepConnectorValue,
               AutomationCompositionStepConnectorStyle(rawValue: stepConnectorValue.lowercased()) == nil {
                return nil
            }
            return request(
                .composition(.setLayout(AutomationCompositionLayoutCommand(
                    layout: layout,
                    axis: axisValue.flatMap { AutomationCompositionAxis(rawValue: $0.lowercased()) },
                    gridColumns: query.int("gridColumns"),
                    targetAspectRatio: query.double("targetAspectRatio"),
                    freeformCanvasWidth: query.double("freeformWidth"),
                    freeformCanvasHeight: query.double("freeformHeight"),
                    stepNumberingStyle: stepNumberingValue.flatMap(AutomationCompositionStepNumberingStyle.init(urlValue:)),
                    stepStartIndex: query.int("stepStartIndex"),
                    stepShowsCaptions: query.bool("stepCaptions"),
                    stepConnectorStyle: stepConnectorValue.flatMap {
                        AutomationCompositionStepConnectorStyle(rawValue: $0.lowercased())
                    }
                ))),
                output: .none
            )
        case "/composition/compare":
            guard let modeValue = query.string("mode"),
                  let mode = AutomationCompositionCompareMode(urlValue: modeValue) else {
                return nil
            }
            let firstItemValue = query.string("firstItemID")
            let secondItemValue = query.string("secondItemID")
            if let firstItemValue, UUID(uuidString: firstItemValue) == nil {
                return nil
            }
            if let secondItemValue, UUID(uuidString: secondItemValue) == nil {
                return nil
            }
            let axisValue = query.string("axis")
            if let axisValue,
               AutomationCompositionAxis(rawValue: axisValue.lowercased()) == nil {
                return nil
            }
            for key in ["wipePosition", "overlayOpacity", "blinkInterval", "differenceIntensity", "highlightThreshold"] {
                if query.string(key) != nil, query.double(key) == nil {
                    return nil
                }
            }
            return request(
                .composition(.setCompareMode(AutomationCompositionCompareCommand(
                    mode: mode,
                    firstItemID: firstItemValue.flatMap(UUID.init(uuidString:)),
                    secondItemID: secondItemValue.flatMap(UUID.init(uuidString:)),
                    axis: axisValue.flatMap { AutomationCompositionAxis(rawValue: $0.lowercased()) },
                    wipePosition: query.double("wipePosition"),
                    overlayOpacity: query.double("overlayOpacity"),
                    blinkInterval: query.double("blinkInterval"),
                    differenceIntensity: query.double("differenceIntensity"),
                    changeHighlightColorHex: query.string("highlightColor"),
                    changeHighlightThreshold: query.double("highlightThreshold"),
                    primaryLabel: query.string("primaryLabel"),
                    secondaryLabel: query.string("secondaryLabel")
                ))),
                output: .none
            )
        case "/composition/template":
            let id = query.string("id")
            let name = query.string("name")
            guard id?.isEmpty == false || name?.isEmpty == false else {
                return nil
            }
            return request(
                .composition(.applyTemplate(
                    AutomationCompositionTemplateCommand(id: id, name: name)
                )),
                output: .none
            )
        case "/guide/start":
            let target = query.string("target").flatMap(GuideAutomationTarget.init(rawValue:)) ?? .window
            return request(.guide(.start(target)), output: .none)
        case "/guide/pause":
            return request(.guide(.pause), output: .none)
        case "/guide/resume":
            return request(.guide(.resume), output: .none)
        case "/guide/add-step":
            return request(.guide(.addStep), output: .none)
        case "/guide/stop":
            return request(.guide(.stop), output: .none)
        case "/guide/export":
            guard let value = query.string("format"), let format = GuideAutomationExportFormat(rawValue: value) else { return nil }
            return request(.guide(.export(format)), output: .none)
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

        func double(_ name: String) -> Double? {
            string(name).flatMap(Double.init)
        }

        func int(_ name: String) -> Int? {
            string(name).flatMap(Int.init)
        }

        func rect() -> CGRect? {
            if let value = string("rect") {
                return AutomationValueParser.rect(value)
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
            case "file":
                let format = string("format")
                    .flatMap { AutomationExportFormat(rawValue: $0.lowercased()) } ?? .png
                let url = string("outputPath").map {
                    URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
                }
                let file = AutomationFileOutput(
                    url: url,
                    format: format,
                    overwrite: bool("overwrite") ?? false,
                    revealInFinder: bool("reveal") ?? false
                )
                return format == .sss ? .saveEditableDocument(file) : .saveFile(file)
            default:
                return defaultOutput
            }
        }
    }
}

private extension AutomationOutputAppearance {
    nonisolated init?(urlValue: String) {
        switch urlValue.lowercased() {
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

private extension AutomationCompositionCompareMode {
    nonisolated init?(urlValue: String) {
        switch urlValue.lowercased().replacingOccurrences(of: "-", with: "") {
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

private extension AutomationCompositionStepNumberingStyle {
    nonisolated init?(urlValue: String) {
        switch urlValue.lowercased().replacingOccurrences(of: "-", with: "") {
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
