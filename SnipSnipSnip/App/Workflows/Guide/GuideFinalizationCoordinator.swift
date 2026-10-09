import Foundation

@MainActor
final class GuideFinalizationReceipt {
    let document: EditableGuideDocument
    fileprivate var isDiscarded = false
    fileprivate var wasPresented = false

    fileprivate init(document: EditableGuideDocument) { self.document = document }
    var wasDiscarded: Bool { isDiscarded }
}

@MainActor
final class GuideFinalizationCoordinator {
    private final class Attempt {
        var task: Task<GuideFinalizationReceipt, Error>?
        var receipt: GuideFinalizationReceipt?
        var isDiscarded = false
        var exitContext: GuideExitContext?
    }
    private var active: Attempt?

    var isFinishing: Bool { active != nil }
    var exitContext: GuideExitContext? { active?.exitContext }

    func finish(context: GuideExitContext? = nil,
                using operation: @escaping @MainActor () async throws -> EditableGuideDocument?) async throws -> GuideFinalizationReceipt {
        if let task = active?.task { return try await task.value }
        let attempt = Attempt()
        attempt.exitContext = context
        active = attempt
        let task = Task { @MainActor in
            do {
                guard let document = try await operation() else {
                    throw AutomationExecutionError(code: .noActiveGuide, message: "There is no active Guide to finalize.")
                }
                let receipt = GuideFinalizationReceipt(document: document)
                receipt.isDiscarded = attempt.isDiscarded
                attempt.receipt = receipt
                return receipt
            } catch {
                if attempt.isDiscarded { throw CancellationError() }
                throw error
            }
        }
        attempt.task = task
        do { return try await task.value }
        catch {
            if active === attempt { active = nil }
            throw error
        }
    }

    /// Keep the attempt and its exit context alive until a caller has handled
    /// the document. Coordinator.stop can clear its project before publication.
    func complete(_ receipt: GuideFinalizationReceipt) {
        if active?.receipt === receipt { active = nil }
    }

    @discardableResult
    func discardCurrentResult() -> Task<GuideFinalizationReceipt, Error>? {
        active?.isDiscarded = true
        active?.receipt?.isDiscarded = true
        return active?.task
    }

    func shouldPresent(_ receipt: GuideFinalizationReceipt) -> Bool {
        guard !receipt.isDiscarded, !receipt.wasPresented else { return false }
        receipt.wasPresented = true
        return true
    }
}
