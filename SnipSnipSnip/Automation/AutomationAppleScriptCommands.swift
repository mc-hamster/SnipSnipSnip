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

    nonisolated static func jsonResult(for request: AutomationRequest, enqueueOnly: Bool = false) -> String {
        let result: AutomationResultEnvelope

        if Thread.isMainThread {
            result = MainActor.assumeIsolated {
                performOrEnqueue(request, enqueueOnly: enqueueOnly)
            }
        } else {
            var bridgedResult: AutomationResultEnvelope?
            DispatchQueue.main.sync {
                bridgedResult = MainActor.assumeIsolated {
                    performOrEnqueue(request, enqueueOnly: enqueueOnly)
                }
            }
            result = bridgedResult ?? .failure(requestID: request.id, code: .internalError, message: "Automation bridge is not available.")
        }

        return AutomationJSON.string(for: result)
    }

    private static func performOrEnqueue(_ request: AutomationRequest, enqueueOnly: Bool) -> AutomationResultEnvelope {
        guard let automation else {
            return .failure(requestID: request.id, code: .internalError, message: "SnipSnipSnip is not ready for automation.")
        }

        switch request.command {
        case .status:
            return .success(requestID: request.id, payload: .preflight(automation.automationPermissionPreflight), outputs: [.init(kind: .none)])
        case .listPresets:
            return .success(requestID: request.id, payload: .presets(automation.automationCapturePresets), outputs: [.init(kind: .none)])
        default:
            guard let automationService else {
                return .failure(requestID: request.id, code: .internalError, message: "SnipSnipSnip is not ready for automation.")
            }

            Task { @MainActor in
                _ = await automationService.perform(request)
            }

            if enqueueOnly {
                return .success(
                    requestID: request.id,
                    payload: .capture(AutomationCaptureSummary(kind: "appleScript", sourceName: nil, acceptedInteractiveWorkflow: true)),
                    outputs: [.init(kind: .acceptedInteractiveWorkflow)]
                )
            }

            return .success(
                requestID: request.id,
                payload: AutomationPayload.none,
                outputs: [.init(kind: .acceptedInteractiveWorkflow)]
            )
        }
    }
}

nonisolated class SSSAutomationScriptCommand: NSScriptCommand {
    var automationSource: AutomationSource {
        AutomationSource(kind: .appleScript, caller: "AppleScript")
    }

    override func performDefaultImplementation() -> Any? {
        AutomationAppleScriptBridge.jsonResult(for: request(), enqueueOnly: true)
    }

    func request() -> AutomationRequest {
        AutomationRequest(source: automationSource, command: .status, output: .none)
    }

    func stringArgument(_ name: String) -> String? {
        (evaluatedArguments?[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func boolArgument(_ name: String) -> Bool {
        evaluatedArguments?[name] as? Bool ?? false
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
            output: outputArgument()
        )
    }
}

@objc(SSSCaptureFullscreenCommand)
final class SSSCaptureFullscreenCommand: SSSAutomationScriptCommand {
    override func request() -> AutomationRequest {
        AutomationRequest(
            source: automationSource,
            command: .capture(CaptureAutomationCommand(target: .fullscreen(FullscreenCaptureTarget(displayMode: displayModeArgument())))),
            interactionPolicy: .promptIfNeeded,
            privacy: AutomationPrivacyOptions(privateCapture: boolArgument("privateCapture")),
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
            output: outputArgument()
        )
    }
}

@objc(SSSCaptureRegionCommand)
final class SSSCaptureRegionCommand: SSSAutomationScriptCommand {
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
            output: outputArgument(default: .none)
        )
    }
}
