import Foundation

nonisolated struct ArchiveBookmarkResolution: Sendable {
    let url: URL
    let isStale: Bool
}

nonisolated struct ArchiveBookmarkClient: Sendable {
    var create: @Sendable (URL) throws -> Data
    var resolve: @Sendable (Data) throws -> ArchiveBookmarkResolution
    var startAccess: @Sendable (URL) -> Bool
    var stopAccess: @Sendable (URL) -> Void
    var hasPermanentAccess: @Sendable (URL) -> Bool = { _ in false }

    static let live = ArchiveBookmarkClient(
        create: { url in
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        resolve: { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return ArchiveBookmarkResolution(url: url, isStale: stale)
        },
        startAccess: { $0.startAccessingSecurityScopedResource() },
        stopAccess: { $0.stopAccessingSecurityScopedResource() },
        hasPermanentAccess: { url in
#if APP_STORE_BUILD
            let target = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
            if home.lastPathComponent == "Data", home.pathComponents.contains("Containers"),
               target.starts(with: home.pathComponents) { return true }
            // This edition declares Downloads read/write access. Ordinary URLs
            // within permanent sandbox grants need no security-scope token.
            return NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true).contains {
                let root = URL(fileURLWithPath: $0).resolvingSymlinksInPath().pathComponents
                return target.starts(with: root)
            }
#else
            return false
#endif
        }
    )

    static var requiresSecurityScope: Bool {
#if APP_STORE_BUILD
        true
#else
        false
#endif
    }
}

nonisolated enum ArchiveFolderAccessError: LocalizedError, Equatable {
    case bookmarkUnavailable
    case accessUnavailable

    var errorDescription: String? {
        switch self {
        case .bookmarkUnavailable:
            "Access to the selected Snip History folder could not be saved or restored. Choose the folder again."
        case .accessUnavailable:
            "The selected Snip History folder is unavailable. Choose the folder again to restore access."
        }
    }
}

nonisolated struct ArchiveLocationResolution: Sendable {
    let requestedURL: URL?
    let error: ArchiveFolderAccessError?
    var accessibleURL: URL? { error == nil ? requestedURL : nil }
}

/// A store retains its access lease, including while a detached checkpoint or
/// maintenance operation finishes after the user switches storage locations.
nonisolated final class ArchiveFolderAccess: Sendable {
    let url: URL
    let didStartAccess: Bool
    let isAccessible: Bool
    private let client: ArchiveBookmarkClient

    init(url: URL, client: ArchiveBookmarkClient, requiresSecurityScope: Bool) {
        self.url = url
        self.client = client
        didStartAccess = client.startAccess(url)
        isAccessible = didStartAccess || !requiresSecurityScope || client.hasPermanentAccess(url)
    }

    deinit {
        if didStartAccess { client.stopAccess(url) }
    }
}

nonisolated struct PreparedArchiveLocation: Sendable {
    let requestedURL: URL?
    let access: ArchiveFolderAccess?
    let error: ArchiveFolderAccessError?
    var usableURL: URL? { error == nil ? requestedURL : nil }

    init(preferences: ArchivePreferenceStore) {
        let resolution = preferences.resolveLocation()
        requestedURL = resolution.requestedURL
        guard let url = resolution.accessibleURL else {
            access = nil
            error = resolution.error
            return
        }
        let lease = ArchiveFolderAccess(url: url, client: preferences.bookmarks,
                                        requiresSecurityScope: preferences.requiresSecurityScope)
        access = lease.isAccessible ? lease : nil
        error = lease.isAccessible ? nil : .accessUnavailable
    }
}
