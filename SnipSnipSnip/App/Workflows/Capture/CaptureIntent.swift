import Foundation

/// Identifies where a completed capture belongs.
///
/// The generation token prevents a delayed or retried capture from mutating a
/// different editor document that happens to be active when capture completes.
nonisolated enum CaptureIntent: Equatable, Sendable {
    case newDocument
    case append(documentGenerationID: UUID, afterItemID: UUID?)
    case replace(documentGenerationID: UUID, itemID: UUID)

    nonisolated var documentGenerationID: UUID? {
        switch self {
        case .newDocument:
            nil
        case let .append(documentGenerationID, _),
             let .replace(documentGenerationID, _):
            documentGenerationID
        }
    }
}
