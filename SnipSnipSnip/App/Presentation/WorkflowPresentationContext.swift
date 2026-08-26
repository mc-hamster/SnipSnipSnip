import CoreGraphics
import Foundation

/// Describes the surface that launched a workflow without coupling the
/// workflow itself to that surface's controller or view model.
nonisolated struct WorkflowPresentationContext: Equatable, Sendable {
    nonisolated enum Origin: Equatable, Sendable {
        case application
        case quickControls
    }

    let origin: Origin
    let displayID: CGDirectDisplayID?

    static let application = WorkflowPresentationContext(
        origin: .application,
        displayID: nil
    )

    static func quickControls(
        displayID: CGDirectDisplayID?
    ) -> WorkflowPresentationContext {
        WorkflowPresentationContext(
            origin: .quickControls,
            displayID: displayID
        )
    }

    var shouldHideApplicationWindowForCapture: Bool {
        origin == .application
    }

    var shouldReturnToMainWindowAfterCancellation: Bool {
        origin == .application
    }
}
