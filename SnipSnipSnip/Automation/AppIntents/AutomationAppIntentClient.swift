import AppIntents
import CoreGraphics
import Foundation
import OSLog

nonisolated enum ShortcutsAutomationLog {
    static let logger = Logger(subsystem: "com.oontz.SnipSnipSnip", category: "ShortcutsAutomation")
}

nonisolated struct AutomationIntentClient: Sendable {
    private let performRequest: @MainActor @Sendable (AutomationRequest) async -> AutomationResultEnvelope
    private let capabilitiesRequest: @MainActor @Sendable (UUID) async -> AutomationResultEnvelope
    private let listCapturePresetsRequest: @MainActor @Sendable (UUID) async -> AutomationResultEnvelope

    init(
        performRequest: @escaping @MainActor @Sendable (AutomationRequest) async -> AutomationResultEnvelope,
        capabilitiesRequest: @escaping @MainActor @Sendable (UUID) async -> AutomationResultEnvelope,
        listCapturePresetsRequest: @escaping @MainActor @Sendable (UUID) async -> AutomationResultEnvelope
    ) {
        self.performRequest = performRequest
        self.capabilitiesRequest = capabilitiesRequest
        self.listCapturePresetsRequest = listCapturePresetsRequest
    }

    @MainActor
    static func live(automationService: any AutomationService) -> AutomationIntentClient {
        AutomationIntentClient(
            performRequest: { request in
                await automationService.perform(request)
            },
            capabilitiesRequest: { requestID in
                await automationService.capabilities(requestID: requestID)
            },
            listCapturePresetsRequest: { requestID in
                await automationService.listCapturePresets(requestID: requestID)
            }
        )
    }

    static var unavailable: AutomationIntentClient {
        AutomationIntentClient(
            performRequest: { request in
                .failure(
                    requestID: request.id,
                    code: .internalError,
                    message: "SnipSnipSnip is not ready for App Intents automation."
                )
            },
            capabilitiesRequest: { requestID in
                .failure(
                    requestID: requestID,
                    code: .internalError,
                    message: "SnipSnipSnip is not ready for App Intents automation."
                )
            },
            listCapturePresetsRequest: { requestID in
                .failure(
                    requestID: requestID,
                    code: .internalError,
                    message: "SnipSnipSnip is not ready for App Intents automation."
                )
            }
        )
    }

    func perform(_ request: AutomationRequest) async -> AutomationResultEnvelope {
        ShortcutsAutomationLog.logger.info(
            "client.perform start requestID=\(request.id.uuidString, privacy: .public) \(request.debugSummary, privacy: .public)"
        )
        let result = await performRequest(request)
        ShortcutsAutomationLog.logger.info(
            "client.perform finish requestID=\(request.id.uuidString, privacy: .public) \(result.debugSummary, privacy: .public)"
        )
        return result
    }

    func capabilities(requestID: UUID = UUID()) async -> AutomationResultEnvelope {
        ShortcutsAutomationLog.logger.info(
            "client.capabilities start requestID=\(requestID.uuidString, privacy: .public)"
        )
        let result = await capabilitiesRequest(requestID)
        ShortcutsAutomationLog.logger.info(
            "client.capabilities finish requestID=\(requestID.uuidString, privacy: .public) \(result.debugSummary, privacy: .public)"
        )
        return result
    }

    func listCapturePresets(requestID: UUID = UUID()) async -> AutomationResultEnvelope {
        ShortcutsAutomationLog.logger.info(
            "client.listCapturePresets start requestID=\(requestID.uuidString, privacy: .public)"
        )
        let result = await listCapturePresetsRequest(requestID)
        ShortcutsAutomationLog.logger.info(
            "client.listCapturePresets finish requestID=\(requestID.uuidString, privacy: .public) \(result.debugSummary, privacy: .public)"
        )
        return result
    }

    func capturePresetSummaries() async -> [AutomationPresetSummary] {
        let result = await listCapturePresets()
        guard result.status == .succeeded,
              case .presets(let presets)? = result.payload else {
            return []
        }
        return presets
    }
}

enum AutomationIntentDependencies {
    @MainActor
    static func configure(automationService: any AutomationService) {
        let client = AutomationIntentClient.live(automationService: automationService)
        AppDependencyManager.shared.add(dependency: client)
    }
}

nonisolated enum AutomationIntentResultFormatter {
    static func dialog(for result: AutomationResultEnvelope) -> IntentDialog {
        IntentDialog(LocalizedStringResource(stringLiteral: message(for: result)))
    }

    static func message(for result: AutomationResultEnvelope) -> String {
        if let error = result.error {
            return "SnipSnipSnip automation failed: \(error.message)"
        }

        if let warning = result.warnings.first {
            return warning.message
        }

        switch result.payload {
        case .preflight(let preflight):
            return preflight.isCaptureReady
                ? "SnipSnipSnip automation is ready."
                : "SnipSnipSnip needs Screen Recording permission before capture automation can run."
        case .presets(let presets):
            return presets.count == 1
                ? "1 capture preset is available."
                : "\(presets.count) capture presets are available."
        case .capture(let summary):
            if summary.acceptedInteractiveWorkflow {
                return "SnipSnipSnip accepted the capture workflow."
            }
            return "SnipSnipSnip captured \(summary.kind)."
        case .export:
            return "SnipSnipSnip exported the current screenshot."
        case .permissionStatus(let summary):
            return summary.hasScreenRecording
                ? "Screen Recording permission is allowed."
                : "Screen Recording permission is needed."
        case .capabilities, .none?, nil:
            return "SnipSnipSnip automation finished."
        }
    }
}

extension AutomationRequest {
    nonisolated var requiresAppIntentForeground: Bool {
        if output.requiresAppIntentForeground {
            return true
        }

        switch command {
        case .capture(let command):
            switch command.target {
            case .interactiveRegion, .interactiveWindow:
                return true
            case .fullscreen, .frontmostWindow, .region:
                return false
            }
        case .repeatLastCapture:
            return true
        case .status, .listPresets, .runPreset, .openDocument, .exportCurrent:
            return false
        }
    }
}

extension AutomationOutput {
    nonisolated var requiresAppIntentForeground: Bool {
        switch self {
        case .appDefault, .openEditor, .floatReference:
            return true
        case .copyRenderedImage, .saveFile, .saveEditableDocument, .none:
            return false
        }
    }
}

extension AutomationRequest {
    nonisolated var debugSummary: String {
        "source=\(source.kind.rawValue) caller=\(source.caller ?? "nil") command=\(command.debugSummary) interaction=\(interactionPolicy.rawValue) private=\(privacy.privateCapture) output=\(output.debugSummary) validation=\(validationError?.message ?? "none") foreground=\(requiresAppIntentForeground)"
    }
}

extension AutomationCommand {
    nonisolated var debugSummary: String {
        switch self {
        case .status:
            return "status"
        case .listPresets:
            return "listPresets"
        case .runPreset(let command):
            return "runPreset(id=\(command.id?.uuidString ?? "nil"), name=\(command.name ?? "nil"))"
        case .capture(let command):
            return "capture(target=\(command.target.debugSummary), delay=\(command.options.delay.debugSummary), cursor=\(command.options.includesCursor.map(String.init(describing:)) ?? "nil"), uiMap=\(command.options.windowUIMap.rawValue))"
        case .repeatLastCapture:
            return "repeatLastCapture"
        case .openDocument(let command):
            return "openDocument(url=\(command.url.path))"
        case .exportCurrent(let command):
            return "exportCurrent(format=\(command.format.rawValue))"
        }
    }
}

extension CaptureAutomationTarget {
    nonisolated var debugSummary: String {
        switch self {
        case .fullscreen(let target):
            return "fullscreen(display=\(target.displayMode.rawValue))"
        case .frontmostWindow:
            return "frontmostWindow"
        case .region(let selector):
            return "region(rect=\(selector.rect.debugDescription))"
        case .interactiveRegion:
            return "interactiveRegion"
        case .interactiveWindow:
            return "interactiveWindow"
        }
    }
}

extension AutomationCaptureDelay {
    nonisolated var debugSummary: String {
        switch self {
        case .appDefault:
            return "appDefault"
        case .immediate:
            return "immediate"
        case .seconds(let seconds):
            return "\(seconds)s"
        }
    }
}

extension AutomationOutput {
    nonisolated var debugSummary: String {
        switch self {
        case .appDefault:
            return "appDefault"
        case .openEditor:
            return "openEditor"
        case .copyRenderedImage:
            return "copyRenderedImage"
        case .saveFile(let file):
            return "saveFile(url=\(file.url?.path ?? "nil"), format=\(file.format.rawValue), overwrite=\(file.overwrite), reveal=\(file.revealInFinder))"
        case .saveEditableDocument(let file):
            return "saveEditableDocument(url=\(file.url?.path ?? "nil"), format=\(file.format.rawValue), overwrite=\(file.overwrite), reveal=\(file.revealInFinder))"
        case .floatReference:
            return "floatReference"
        case .none:
            return "none"
        }
    }
}

extension AutomationResultEnvelope {
    nonisolated var debugSummary: String {
        let outputSummary = outputs.map(\.debugSummary).joined(separator: ",")
        return "status=\(status.rawValue) payload=\(payload?.debugSummary ?? "nil") outputs=[\(outputSummary)] warnings=\(warnings.count) error=\(error?.message ?? "nil")"
    }
}

extension AutomationPayload {
    nonisolated var debugSummary: String {
        switch self {
        case .preflight(let preflight):
            return "preflight(captureReady=\(preflight.isCaptureReady))"
        case .capabilities:
            return "capabilities"
        case .presets(let presets):
            return "presets(count=\(presets.count))"
        case .capture(let summary):
            return "capture(kind=\(summary.kind), source=\(summary.sourceName ?? "nil"), interactive=\(summary.acceptedInteractiveWorkflow))"
        case .export(let summary):
            return "export(format=\(summary.format?.rawValue ?? "nil"), source=\(summary.source))"
        case .permissionStatus(let summary):
            return "permissionStatus(screen=\(summary.hasScreenRecording), accessibility=\(summary.hasAccessibility))"
        case .none:
            return "none"
        }
    }
}

extension AutomationOutputResult {
    nonisolated var debugSummary: String {
        "kind=\(kind.rawValue), url=\(url?.path ?? "nil"), format=\(format?.rawValue ?? "nil")"
    }
}
