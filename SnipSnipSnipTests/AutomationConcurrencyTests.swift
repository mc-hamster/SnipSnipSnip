import Foundation
import XCTest
@testable import SnipSnipSnip

@MainActor
final class AutomationConcurrencyTests: XCTestCase {
    func testConcurrentMutationsFailBusyWhileQueriesRemainAvailable() async throws {
        let host = SuspendedAutomationHost()
        let service = AppAutomationService(host: host)
        let capture = AutomationRequest(source: .init(kind: .commandLine), command: .capture(.init(target: .frontmostWindow)), output: .none)
        let first = Task { await service.perform(capture) }
        await waitUntil { host.pending != nil }
        XCTAssertNotNil(host.pending)
        let export = AutomationRequest(source: .init(kind: .appleScript), command: .exportCurrent(.init(format: .png)), output: .none)
        let rejected = await service.perform(export)
        XCTAssertEqual(rejected.error?.code, .busy)
        let status = await service.perform(.init(source: .init(kind: .urlScheme), command: .status, output: .none))
        XCTAssertEqual(status.status, .succeeded)
        let presets = await service.perform(.init(source: .init(kind: .appIntent), command: .listPresets, output: .none))
        XCTAssertEqual(presets.status, .succeeded)
        XCTAssertEqual(host.exportCount, 0)
        host.pending?.resume()
        host.pending = nil
        let completed = await first.value
        XCTAssertEqual(completed.status, .succeeded)
        let next = await service.perform(export)
        XCTAssertEqual(next.status, .succeeded)
        XCTAssertEqual(host.exportCount, 1)
    }

    func testPendingPickerBlocksMutationUntilCancelledOrCompleted() async {
        let host = SuspendedAutomationHost()
        let service = AppAutomationService(host: host)
        host.hasPendingInteractiveAutomationCapture = true
        let request = AutomationRequest(source: .init(kind: .commandLine), command: .exportCurrent(.init(format: .png)), output: .none)
        let rejected = await service.perform(request)
        XCTAssertEqual(rejected.error?.code, .busy)
        host.hasPendingInteractiveAutomationCapture = false
        let accepted = await service.perform(request)
        XCTAssertEqual(accepted.status, .succeeded)
    }
}

@MainActor
private final class SuspendedAutomationHost: AutomationHost {
    var hasPendingInteractiveAutomationCapture = false
    var pending: CheckedContinuation<Void, Never>?
    var exportCount = 0
    var automationCapabilities: AutomationCapabilities {
        .init(supportsURLScheme: true, supportsAppleScript: true, supportsCLI: true, supportsAppIntents: true,
              supportsCapturePresets: true, supportsPrivateCapture: true, supportsUIMap: false,
              supportsScrollingCapture: false, supportsConnectedDeviceCapture: false,
              supportsCurrentEditorExport: true, supportsGuide: false)
    }
    var automationPermissionSummary: AutomationPermissionSummary {
        .init(hasScreenRecording: true, hasAccessibility: false, hasMicrophone: false)
    }
    var automationCapturePresets: [AutomationPresetSummary] { [] }
    func captureAutomation(_ command: CaptureAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope {
        await withCheckedContinuation { pending = $0 }
        return .success(requestID: request.id)
    }
    func exportCurrentAutomationDocument(_ command: ExportCurrentAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope {
        exportCount += 1
        return .success(requestID: request.id)
    }
    func runAutomationPreset(_ command: RunPresetAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope { .success(requestID: request.id) }
    func repeatLastAutomationCapture(_ request: AutomationRequest) async -> AutomationResultEnvelope { .success(requestID: request.id) }
    func openAutomationDocument(_ command: OpenDocumentAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope { .success(requestID: request.id) }
    func compositionAutomation(_ command: CompositionAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope { .success(requestID: request.id) }
    func guideAutomation(_ command: GuideAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope { .success(requestID: request.id) }
}
