import Foundation
import OSLog

/// Shared identity checks. Identity is unique within a scope, not across
/// snapshots or captures: copying an item intentionally reuses its asset and
/// annotation IDs in a separate editing scope.
nonisolated enum IdentityIntegrity {
    static func firstDuplicate<ID: Hashable>(in ids: some Sequence<ID>) -> ID? {
        var seen: Set<ID> = []
        for id in ids where !seen.insert(id).inserted { return id }
        return nil
    }
}

nonisolated struct EditorIdentityViolation: LocalizedError, Equatable, Sendable {
    enum Scope: String, Sendable {
        case annotations
        case compositionItems
        case itemAnnotations
        case canvasAnnotations
        case compositionAssets
    }

    let scope: Scope
    let ownerID: UUID?
    let duplicateID: UUID

    var errorDescription: String? { "The image arrangement contains conflicting entries." }

    var persistenceReason: String {
        switch scope {
        case .annotations, .itemAnnotations, .canvasAnnotations:
            return "duplicate annotation IDs"
        case .compositionItems:
            return "duplicate composition item IDs"
        case .compositionAssets:
            return "duplicate or inconsistent capture asset IDs"
        }
    }
}

nonisolated enum EditorIdentityIntegrity {
    private static let logger = Logger(subsystem: "com.oontz.SnipSnipSnip", category: "EditorIntegrity")

    static func violation(in snapshot: EditorSnapshot) -> EditorIdentityViolation? {
        if let id = IdentityIntegrity.firstDuplicate(in: snapshot.annotations.lazy.map(\.id)) {
            return EditorIdentityViolation(scope: .annotations, ownerID: nil, duplicateID: id)
        }
        guard let composition = snapshot.composition else { return nil }
        if let id = IdentityIntegrity.firstDuplicate(in: composition.items.lazy.map(\.id)) {
            return EditorIdentityViolation(scope: .compositionItems, ownerID: nil, duplicateID: id)
        }
        for item in composition.items {
            if let id = IdentityIntegrity.firstDuplicate(in: item.editState.annotations.lazy.map(\.id)) {
                return EditorIdentityViolation(scope: .itemAnnotations, ownerID: item.id, duplicateID: id)
            }
        }
        if let id = IdentityIntegrity.firstDuplicate(in: composition.canvas.annotations.lazy.map(\.id)) {
            return EditorIdentityViolation(scope: .canvasAnnotations, ownerID: nil, duplicateID: id)
        }
        return nil
    }

    static func validate(_ session: EditorDocumentSession) throws {
        for snapshot in [session.initialSnapshot, session.currentSnapshot] + session.undoStack + session.redoStack {
            if let violation = violation(in: snapshot) { throw violation }
        }
    }

    static func report(_ violation: EditorIdentityViolation, context: String) {
        // Metadata only: no annotation text, screenshot pixels, filenames, or
        // captured application/window names enter the diagnostic log.
        logger.error("Rejected editor state: context=\(context, privacy: .public) scope=\(violation.scope.rawValue, privacy: .public)")
    }
}
