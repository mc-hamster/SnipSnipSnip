import Combine
import Foundation

nonisolated enum CreationPlanStartResult: Equatable, Sendable {
    case started
    case awaitingExistingSelection
    case awaitingConnectedDeviceSelection
    case cancelled
    case unavailable(String)
}

/// Transactional setup owner for the intent-driven Create sheet.
///
/// The draft is local to this object. Starting a plan delegates acquisition to
/// the supplied handler; no capture or document state is touched before that
/// point. Failed or cancelled starts keep the draft available for correction.
@MainActor
final class CreationWorkflowModel: ObservableObject {
    typealias StartHandler = @MainActor (CreationPlan) ->
        CreationPlanStartResult

    let capabilities: AppCapabilitySnapshot
    @Published private(set) var isShowingQuickStart = false
    @Published var draft: CreationDraft
    @Published private(set) var startErrorMessage: String?
    @Published private(set) var pendingExistingSourcePlan: CreationPlan?
    @Published private(set) var pendingConnectedDevicePlan: CreationPlan?

    var startHandler: StartHandler?
    var connectedDeviceSelectionHandler:
        (@MainActor (ConnectedAppleDevice, CreationPlan) -> Void)?
    var defaultDraftProvider: @MainActor () -> CreationDraft

    init(
        capabilities: AppCapabilitySnapshot,
        draft: CreationDraft = .default,
        defaultDraftProvider: (@MainActor () -> CreationDraft)? = nil,
        startHandler: StartHandler? = nil
    ) {
        self.capabilities = capabilities
        self.draft = draft.normalized(for: capabilities)
        self.pendingExistingSourcePlan = nil
        self.pendingConnectedDevicePlan = nil
        self.defaultDraftProvider = defaultDraftProvider ?? { .default }
        self.startHandler = startHandler
    }

    var isGuideCreationAvailable: Bool {
        capabilities.isEnabled(.guideCapture)
    }

    var availableExistingSources: [CreationExistingSource] {
        let available = CreationExistingSource.allCases.filter {
            CreationDraft(
                source: .existing($0)
            ).normalized(for: capabilities).source == .existing($0)
        }
        let hasHistorySource = available.contains(.captureHistory)

        return available.filter {
            // Recent Snips and retained checkpoints are presented through one
            // Snip Library source. Keep legacy cases decodable, and retain the
            // Archive-backed source as a fallback for capability snapshots
            // that do not expose recovery history.
            switch $0 {
            case .recentSnips:
                return false
            case .archive:
                return !hasHistorySource
            case .files, .clipboard, .captureHistory:
                return true
            }
        }
    }

    func presentQuickStart(
        prefilledDraft: CreationDraft? = nil
    ) {
        if let prefilledDraft {
            draft = prefilledDraft.normalized(for: capabilities)
        } else {
            draft = defaultDraftProvider().normalized(
                for: capabilities
            )
        }
        startErrorMessage = nil
        isShowingQuickStart = true
    }

    func cancelQuickStart() {
        isShowingQuickStart = false
        startErrorMessage = nil
        pendingExistingSourcePlan = nil
        pendingConnectedDevicePlan = nil
        draft = .default.normalized(for: capabilities)
    }

    @discardableResult
    func commitQuickStart() -> CreationPlanStartResult {
        let normalizedDraft = draft.normalized(for: capabilities)
        draft = normalizedDraft
        let plan = normalizedDraft.plan(for: capabilities)

        guard let startHandler else {
            let result = CreationPlanStartResult.unavailable(
                "Creation workflow is not connected."
            )
            startErrorMessage = result.errorMessage
            return result
        }

        let result = startHandler(plan)
        switch result {
        case .started:
            isShowingQuickStart = false
            startErrorMessage = nil
            pendingExistingSourcePlan = nil
            pendingConnectedDevicePlan = nil
            draft = .default.normalized(for: capabilities)
        case .awaitingExistingSelection:
            isShowingQuickStart = false
            startErrorMessage = nil
            pendingExistingSourcePlan = plan
            pendingConnectedDevicePlan = nil
        case .awaitingConnectedDeviceSelection:
            isShowingQuickStart = false
            startErrorMessage = nil
            pendingExistingSourcePlan = nil
            pendingConnectedDevicePlan = plan
        case .cancelled:
            startErrorMessage = nil
        case .unavailable:
            startErrorMessage = result.errorMessage
        }
        return result
    }

    /// Called only after the user chooses and successfully installs an exact
    /// Recent, History, or Archive item.
    func completeExistingSourceSelection() {
        pendingExistingSourcePlan = nil
        startErrorMessage = nil
        draft = .default.normalized(for: capabilities)
    }

    /// Exact-item selection is transactional. Cancelling reopens the original
    /// setup draft and never substitutes the first available history item.
    func cancelExistingSourceSelection() {
        guard pendingExistingSourcePlan != nil else {
            return
        }
        pendingExistingSourcePlan = nil
        startErrorMessage = nil
        isShowingQuickStart = true
    }

    /// Starts a connected-device preview only after the user explicitly
    /// chooses the target device. The goal and one-shot capture options remain
    /// latched in the pending plan throughout device discovery.
    func selectConnectedDevice(_ device: ConnectedAppleDevice) {
        guard let plan = pendingConnectedDevicePlan,
              let connectedDeviceSelectionHandler else {
            return
        }
        pendingConnectedDevicePlan = nil
        startErrorMessage = nil
        draft = .default.normalized(for: capabilities)
        connectedDeviceSelectionHandler(device, plan)
    }

    /// Device discovery and selection are still part of the transactional
    /// Create setup. Cancelling returns to the exact draft instead of silently
    /// falling back to another capture source.
    func cancelConnectedDeviceSelection() {
        guard pendingConnectedDevicePlan != nil else {
            return
        }
        pendingConnectedDevicePlan = nil
        startErrorMessage = nil
        isShowingQuickStart = true
    }
}

private nonisolated extension CreationPlanStartResult {
    var errorMessage: String? {
        if case .unavailable(let message) = self {
            return message
        }
        return nil
    }
}
