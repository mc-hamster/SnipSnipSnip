import Foundation

/// Explains how a successful acquisition should shape the document workflow.
///
/// This is deliberately orthogonal to `CaptureIntent`: the intent provides the
/// generation-safe installation destination, while this role provides the
/// user-facing purpose and next stage.
nonisolated enum CaptureCompletionRole: String, Codable, Equatable, Sendable {
    case standalone
    case comparisonBefore
    case comparisonAfter
    case step
    case collectionItem
    case replacement
}

/// Per-operation choices from Create > Fine-tune. They are latched alongside
/// the destination and never write back to capture preferences.
nonisolated struct CaptureOneShotOptions: Equatable, Sendable {
    var captureDelay: CaptureDelay
    var includesCursor: Bool
    var privateCapture: Bool
    var windowUIMapEnabled: Bool

    init(
        captureDelay: CaptureDelay,
        includesCursor: Bool,
        privateCapture: Bool,
        windowUIMapEnabled: Bool
    ) {
        self.captureDelay = captureDelay
        self.includesCursor = includesCursor
        self.privateCapture = privateCapture
        self.windowUIMapEnabled = windowUIMapEnabled
    }

    func applying(to base: CaptureRunOptions) -> CaptureRunOptions {
        var resolved = base
        resolved.captureDelay = captureDelay
        resolved.includesCursor = includesCursor
        resolved.windowUIMapEnabled = windowUIMapEnabled
        return resolved
    }
}

nonisolated struct CaptureCompletionContext: Equatable, Sendable {
    var intent: CaptureIntent
    var role: CaptureCompletionRole
    var oneShotOptions: CaptureOneShotOptions?
    var presentationContext: WorkflowPresentationContext
    /// Identifies a persistent acquisition surface whose later captures must
    /// continue the same user goal. Derived append contexts retain this token,
    /// allowing the surface's close handler to clear only its own state.
    var persistentSurfaceSessionID: UUID?

    init(
        intent: CaptureIntent = .newDocument,
        role: CaptureCompletionRole = .standalone,
        oneShotOptions: CaptureOneShotOptions? = nil,
        presentationContext: WorkflowPresentationContext = .application,
        persistentSurfaceSessionID: UUID? = nil
    ) {
        self.intent = intent
        self.role = role
        self.oneShotOptions = oneShotOptions
        self.presentationContext = presentationContext
        self.persistentSurfaceSessionID = persistentSurfaceSessionID
    }

    static let standalone = CaptureCompletionContext()
}
