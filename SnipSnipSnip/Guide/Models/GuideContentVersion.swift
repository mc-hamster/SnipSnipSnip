import Foundation

/// Identifies content, excluding selection, search, thumbnails, and save status.
nonisolated struct GuideContentVersion: Equatable, Sendable {
    let sessionID: UUID
    let revision: UInt64
}

nonisolated struct GuideExportReceipt: Sendable {
    let version: GuideContentVersion
    let urls: [URL]

    func currentURLs(for version: GuideContentVersion?) -> [URL] {
        self.version == version ? urls : []
    }
}
