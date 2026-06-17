import AppKit
import Foundation

@MainActor
protocol AutomationService {
    func perform(_ request: AutomationRequest) async -> AutomationResultEnvelope
    func capabilities(requestID: UUID) async -> AutomationResultEnvelope
    func listCapturePresets(requestID: UUID) async -> AutomationResultEnvelope
}

@MainActor
protocol AutomationHost: AnyObject {
    var automationCapabilities: AutomationCapabilities { get }
    var automationPermissionSummary: AutomationPermissionSummary { get }
    var automationCapturePresets: [AutomationPresetSummary] { get }

    func performAutomation(_ request: AutomationRequest) async -> AutomationResultEnvelope
}

@MainActor
protocol AutomationOutputWriter {
    func writeAutomationOutput(_ output: AutomationOutput) async throws -> [AutomationOutputResult]
}

@MainActor
extension AutomationHost {
    var automationPermissionPreflight: AutomationPermissionPreflight {
        AutomationPermissionPreflight(
            capabilities: automationCapabilities,
            permissions: automationPermissionSummary
        )
    }
}

@MainActor
final class AppAutomationService: AutomationService {
    private weak var host: AutomationHost?

    init(host: AutomationHost) {
        self.host = host
    }

    func perform(_ request: AutomationRequest) async -> AutomationResultEnvelope {
        if let validationError = request.validationError {
            return .failure(requestID: request.id, code: validationError.code, message: validationError.message)
        }

        guard let host else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation host is not available.")
        }

        switch request.command {
        case .status:
            return await capabilities(requestID: request.id)
        case .listPresets:
            return await listCapturePresets(requestID: request.id)
        default:
            return await host.performAutomation(request)
        }
    }

    func capabilities(requestID: UUID) async -> AutomationResultEnvelope {
        guard let host else {
            return .failure(requestID: requestID, code: .internalError, message: "Automation host is not available.")
        }

        return .success(
            requestID: requestID,
            payload: .preflight(host.automationPermissionPreflight),
            outputs: [.init(kind: .none)],
            warnings: [],
        )
    }

    func listCapturePresets(requestID: UUID) async -> AutomationResultEnvelope {
        guard let host else {
            return .failure(requestID: requestID, code: .internalError, message: "Automation host is not available.")
        }

        return .success(
            requestID: requestID,
            payload: .presets(host.automationCapturePresets),
            outputs: [.init(kind: .none)]
        )
    }
}

nonisolated enum AutomationJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func string(for result: AutomationResultEnvelope) -> String {
        guard let data = try? encoder.encode(result),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"status\":\"failed\",\"error\":{\"code\":\"internalError\",\"message\":\"Could not encode automation result.\"}}"
        }
        return string
    }
}
