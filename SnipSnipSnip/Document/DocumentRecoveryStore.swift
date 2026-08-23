import CoreGraphics
import Foundation

nonisolated struct DocumentHistoryEntry: Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let title: String
    let label: String
    let changeSummary: String?
    let savedAt: Date
    let packageURL: URL
    let previewAssetURL: URL?
    let sourceDocumentURL: URL?
    let hasUnsavedChanges: Bool
    let searchableText: String
    let packageSizeBytes: Int64?
    let deletedAt: Date?

    var historySummary: String {
        changeSummary ?? label
    }

    var historySummaryHelp: String? {
        changeSummary
    }

    /// Searchable filenames, OCR, and annotation text must remain search-only.
    /// Library rows use a neutral title so screen sharing and accessibility
    /// inspection do not repeat captured or filesystem context.
    var libraryDisplayTitle: String {
        "Screenshot"
    }

    var libraryMenuTitle: String {
        "\(libraryDisplayTitle) — \(savedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    func updating(searchableText: String) -> DocumentHistoryEntry {
        DocumentHistoryEntry(
            id: id,
            sessionID: sessionID,
            title: title,
            label: label,
            changeSummary: changeSummary,
            savedAt: savedAt,
            packageURL: packageURL,
            previewAssetURL: previewAssetURL,
            sourceDocumentURL: sourceDocumentURL,
            hasUnsavedChanges: hasUnsavedChanges,
            searchableText: searchableText,
            packageSizeBytes: packageSizeBytes,
            deletedAt: deletedAt
        )
    }

    func matchesSearchQuery(_ query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return true
        }

        let searchTokens = [title, label, sourceDocumentURL?.lastPathComponent, searchableText]
            .compactMap { $0 }
            .joined(separator: " ")
            .localizedLowercase

        return searchTokens.contains(normalizedQuery.localizedLowercase)
    }
}

nonisolated struct DocumentHistoryPage: Sendable {
    let entries: [DocumentHistoryEntry]
    let totalCount: Int
    let offset: Int

    var hasMore: Bool {
        offset + entries.count < totalCount
    }
}

nonisolated struct PendingRecoverySession: Identifiable, Sendable {
    let id: UUID
    let title: String
    let latestEntry: DocumentHistoryEntry
}

nonisolated struct RecoveryPresentationState: Sendable {
    let historyEntries: [DocumentHistoryEntry]
    let allCaptureHistoryEntries: [DocumentHistoryEntry]
    let recentSnipEntries: [DocumentHistoryEntry]
    let recycleBinEntries: [DocumentHistoryEntry]
    let pendingRecoverySession: PendingRecoverySession?
}

nonisolated struct DocumentArchivePruneResult: Equatable, Sendable {
    let archiveSizeBytes: Int64
    let didPrune: Bool
}

nonisolated final class DocumentRecoveryStore: @unchecked Sendable {
    private static let maxCheckpointCount = 12
    private static let sharedBaseImageName = SSSDocumentPackage.baseImageFilename
    private static let sharedBaseImageRelativePath = "../../\(SSSDocumentPackage.baseImageFilename)"
    private static let sharedCompositionAssetsDirectoryName =
        SSSDocumentPackage.recoveryCompositionAssetsDirectoryName
    static let privacyExclusionsDirectoryName = "privacy-exclusions"
    private static let privacyExclusionFilenameExtension = "excluded"

    private let accessLock = NSRecursiveLock()
    private let exclusionLock = NSLock()
    private let fileManager: FileManager
    private let files: any FileSystemServicing
    private let rootURL: URL
    private let sessionsURL: URL
    private let searchIndexURL: URL
    private let privacyExclusionsURL: URL
    private let checkpointPackageDidWrite: (@Sendable (UUID) -> Void)?
    private let checkpointSessionDidCommit: (@Sendable (UUID) -> Void)?
    private var registeredPrivacyExclusionIDs: Set<UUID> = []
    private var pendingPrivacyExclusionPersistenceIDs: Set<UUID> = []

    static func defaultArchiveURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("SnipSnipSnip", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }

    var archiveURL: URL {
        rootURL
    }

    init(
        fileManager: FileManager = .default,
        baseURL: URL? = nil,
        checkpointPackageDidWrite: (@Sendable (UUID) -> Void)? = nil,
        checkpointSessionDidCommit: (@Sendable (UUID) -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.files = SystemFileService(fileManager: fileManager)
        self.checkpointPackageDidWrite = checkpointPackageDidWrite
        self.checkpointSessionDidCommit = checkpointSessionDidCommit

        rootURL = baseURL ?? Self.defaultArchiveURL(fileManager: fileManager)

        sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        searchIndexURL = rootURL.appendingPathComponent("search-index.json")
        privacyExclusionsURL = rootURL.appendingPathComponent(
            Self.privacyExclusionsDirectoryName,
            isDirectory: true
        )
    }

    func archiveSizeInBytes() throws -> Int64 {
        try withLockedAccess {
            guard fileManager.fileExists(atPath: rootURL.path) else {
                return 0
            }

            return try directorySize(at: rootURL)
        }
    }

    @discardableResult
    func pruneArchiveIfNeeded(maximumSizeBytes: Int64) throws -> Bool {
        try pruneArchiveAndMeasure(maximumSizeBytes: maximumSizeBytes).didPrune
    }

    func pruneArchiveAndMeasure(
        maximumSizeBytes: Int64
    ) throws -> DocumentArchivePruneResult {
        try withLockedAccess {
            let archiveExists = fileManager.fileExists(atPath: rootURL.path)
            var currentSize = archiveExists ? try directorySize(at: rootURL) : 0

            guard maximumSizeBytes > 0, currentSize > maximumSizeBytes else {
                return DocumentArchivePruneResult(
                    archiveSizeBytes: currentSize,
                    didPrune: false
                )
            }

            var didPrune = false
            let sessions = try allSessionRecords()
            let oldestFirstEntries = sessions
                .flatMap { session in
                    session.checkpoints.map { historyEntry(from: $0, in: session) }
                }
                .sorted { $0.savedAt < $1.savedAt }

            for entry in oldestFirstEntries where currentSize > maximumSizeBytes {
                let sessionURL = sessionDirectory(for: entry.sessionID)
                let previousTrackedSize =
                    (try archiveItemSize(at: sessionURL))
                    + (try archiveItemSize(at: searchIndexURL))

                try permanentlyDeleteHistoryEntry(entry)

                // Only the session tree and search index can change here. Track
                // their exact delta instead of walking the entire archive after
                // every checkpoint deletion. This still accounts for shared
                // composition captures released by the deletion.
                let updatedTrackedSize =
                    (try archiveItemSize(at: sessionURL))
                    + (try archiveItemSize(at: searchIndexURL))
                currentSize = max(
                    0,
                    currentSize - previousTrackedSize + updatedTrackedSize
                )
                didPrune = true
            }

            return DocumentArchivePruneResult(
                archiveSizeBytes: currentSize,
                didPrune: didPrune
            )
        }
    }

    func clearArchive() throws {
        try withLockedAccess {
            guard fileManager.fileExists(atPath: rootURL.path) else {
                clearPrivacyExclusionRegistry()
                return
            }

            try fileManager.removeItem(at: rootURL)
            try ensureRootDirectories()
            clearPrivacyExclusionRegistry()
        }
    }

    func createSession(title: String, sourceDocumentURL: URL?) throws -> UUID {
        try withLockedAccess {
            let sessionID = UUID()
            try ensureRootDirectories()
            try saveSessionRecord(RecoverySessionRecord(
                id: sessionID,
                title: title,
                sourceDocumentPath: sourceDocumentURL?.path,
                createdAt: Date(),
                updatedAt: Date(),
                pendingRecovery: false,
                baseImageName: nil,
                checkpoints: [],
                isExcludedFromPresentation: false
            ))
            return sessionID
        }
    }

    /// Makes privacy exclusion visible before any potentially in-flight
    /// recovery writer reaches its manifest commit boundary. Persistence is
    /// completed separately so this operation never waits behind a large
    /// checkpoint package write.
    func registerPrivacyExclusion(for sessionID: UUID) {
        exclusionLock.lock()
        registeredPrivacyExclusionIDs.insert(sessionID)
        pendingPrivacyExclusionPersistenceIDs.insert(sessionID)
        exclusionLock.unlock()
    }

    /// Keeps pre-private checkpoints on disk while removing the session from
    /// Recovery, Recent Snips, Snip History, Recycle Bin, and
    /// search presentation. The standalone tombstone is committed before the
    /// mutable session record so an older writer can never clear the exclusion.
    func excludeSessionFromPresentation(_ sessionID: UUID) throws {
        registerPrivacyExclusion(for: sessionID)

        try withLockedAccess {
            try persistPrivacyExclusion(for: sessionID)
        }
    }

    func saveCheckpoint(
        sessionID: UUID,
        title: String,
        sourceDocumentURL: URL?,
        label: String,
        document: EditableScreenshotDocument,
        previewImage: CGImage,
        pendingRecovery: Bool,
        hasUnsavedChanges: Bool,
        includeUIMapSearchText: Bool
    ) throws {
        if document.isPrivate
            || document.compositionStoredAssets.contains(
                where: { $0.descriptor.isPrivate }
            ) {
            try excludeSessionFromPresentation(sessionID)
            return
        }

        try withLockedAccess {
            try ensureRootDirectories()
            retryPendingPrivacyExclusionPersistence()

            guard !isPrivacyExcluded(sessionID) else {
                return
            }

            var session = try loadSessionRecord(id: sessionID) ?? RecoverySessionRecord(
                id: sessionID,
                title: title,
                sourceDocumentPath: sourceDocumentURL?.path,
                createdAt: Date(),
                updatedAt: Date(),
                pendingRecovery: pendingRecovery,
                baseImageName: nil,
                checkpoints: [],
                isExcludedFromPresentation: false
            )

            let checkpointID = UUID()
            let packageName = "checkpoint-\(checkpointID.uuidString).sss"
            let packageURL = checkpointsDirectory(for: sessionID).appendingPathComponent(packageName, isDirectory: true)
            let sharedBaseImageURL = sessionBaseImageURL(for: sessionID)
            let sharedCompositionAssetsURL = sessionCompositionAssetsURL(
                for: sessionID
            )
            let searchableText = SSSDocumentPackage.searchableText(
                for: document,
                includeUIMapSearchText: includeUIMapSearchText
            )
            let changeSummary = RecoveryCheckpointSummary.summary(for: document.session, fallbackLabel: label)
            try fileManager.createDirectory(at: checkpointsDirectory(for: sessionID), withIntermediateDirectories: true)
            do {
                // Immutable pixels are written into the append-only session
                // store first. The checkpoint package and session manifest are
                // not committed until every referenced source is durable.
                try SSSDocumentPackage.save(
                    document: document,
                    previewImage: previewImage,
                    to: packageURL,
                    baseImageStorage: .shared(
                        assetName: Self.sharedBaseImageRelativePath,
                        fileURL: sharedBaseImageURL
                    ),
                    compositionAssetStorage: .sharedRecovery(
                        directoryURL: sharedCompositionAssetsURL
                    ),
                    includeUIMapSearchText: includeUIMapSearchText,
                    files: files
                )
                checkpointPackageDidWrite?(sessionID)
                let packageSizeBytes = try directorySize(at: packageURL)

                // A private capture can taint the session while this package is
                // being encoded. Never let that older write publish a manifest.
                guard !isPrivacyExcluded(sessionID) else {
                    discardUncommittedCheckpoint(
                        sessionID: sessionID,
                        packageURL: packageURL
                    )
                    return
                }

                session.title = title
                session.sourceDocumentPath = sourceDocumentURL?.path
                session.updatedAt = Date()
                session.pendingRecovery = pendingRecovery
                session.baseImageName = Self.sharedBaseImageName
                session.checkpoints.append(RecoveryCheckpointRecord(
                    id: checkpointID,
                    label: label,
                    changeSummary: changeSummary,
                    savedAt: session.updatedAt,
                    packageName: packageName,
                    hasUnsavedChanges: hasUnsavedChanges,
                    previewAssetName: SSSDocumentPackage.previewImageFilename,
                    searchableText: searchableText,
                    packageSizeBytes: packageSizeBytes,
                    compositionAssetIDs: document.compositionStoredAssets.map(
                        \.descriptor.id
                    )
                ))
                session.checkpoints.sort { $0.savedAt > $1.savedAt }

                let overflow: [RecoveryCheckpointRecord]
                if session.checkpoints.count > Self.maxCheckpointCount {
                    overflow = Array(
                        session.checkpoints.suffix(
                            from: Self.maxCheckpointCount
                        )
                    )
                    session.checkpoints = Array(
                        session.checkpoints.prefix(Self.maxCheckpointCount)
                    )
                } else {
                    overflow = []
                }

                // Commit the checkpoint manifest before removing anything
                // from older retained history.
                try saveSessionRecord(session)
                checkpointSessionDidCommit?(sessionID)

                // Close the small race between the precommit check and the
                // atomic session write. If privacy was registered during that
                // interval, remove the just-written checkpoint and force the
                // pending bit back to false.
                if isPrivacyExcluded(sessionID) {
                    try discardCommittedCheckpoint(
                        sessionID: sessionID,
                        checkpointID: checkpointID,
                        packageURL: packageURL
                    )
                    return
                }

                for checkpoint in overflow {
                    try? fileManager.removeItem(
                        at: checkpointsDirectory(for: sessionID)
                            .appendingPathComponent(checkpoint.packageName)
                    )
                }
                try pruneUnreferencedCompositionAssets(
                    sessionID: sessionID,
                    retainedCheckpoints: session.checkpoints
                )
            } catch {
                // If session.json contains the checkpoint, its atomic commit
                // succeeded and a later search-index failure must not tear it
                // back out. Otherwise remove the uncommitted package and any
                // newly orphaned shared assets.
                let persistedSession = try? loadSessionRecord(id: sessionID)
                if isPrivacyExcluded(sessionID) {
                    try? discardCommittedCheckpoint(
                        sessionID: sessionID,
                        checkpointID: checkpointID,
                        packageURL: packageURL
                    )
                    return
                }
                if persistedSession?.checkpoints.contains(where: {
                    $0.id == checkpointID
                }) == true {
                    try? pruneUnreferencedCompositionAssets(
                        sessionID: sessionID,
                        retainedCheckpoints: persistedSession?.checkpoints ?? []
                    )
                    return
                }
                try? fileManager.removeItem(at: packageURL)
                try? pruneUnreferencedCompositionAssets(
                    sessionID: sessionID,
                    retainedCheckpoints: persistedSession?.checkpoints ?? []
                )
                throw error
            }
        }
    }

    func historyEntries(for sessionID: UUID) -> [DocumentHistoryEntry] {
        withLockedAccess {
            retryPendingPrivacyExclusionPersistence()
            guard let session = try? loadSessionRecord(id: sessionID),
                  !isPrivacyExcluded(sessionID, knownSession: session) else {
                return []
            }

            return session.checkpoints
                .filter { $0.deletedAt == nil }
                .sorted { $0.savedAt > $1.savedAt }
                .map { historyEntry(from: $0, in: session) }
        }
    }

    func pendingRecoveryEntries(excluding excludedSessionID: UUID? = nil, limit: Int? = nil) -> [DocumentHistoryEntry] {
        withLockedAccess {
            retryPendingPrivacyExclusionPersistence()
            guard let records = try? allSessionRecords() else {
                return []
            }

            let entries = records.compactMap { session -> DocumentHistoryEntry? in
                guard session.pendingRecovery,
                      !isPrivacyExcluded(session.id, knownSession: session),
                      session.id != excludedSessionID,
                      let checkpoint = session.checkpoints.filter({ $0.deletedAt == nil }).max(by: { $0.savedAt < $1.savedAt }) else {
                    return nil
                }

                return historyEntry(from: checkpoint, in: session)
            }
            .sorted { $0.savedAt > $1.savedAt }

            guard let limit else {
                return entries
            }

            return Array(entries.prefix(limit))
        }
    }

    func latestPendingRecovery() -> PendingRecoverySession? {
        withLockedAccess {
            guard let entry = pendingRecoveryEntries(limit: 1).first else {
                return nil
            }

            return PendingRecoverySession(id: entry.sessionID, title: entry.title, latestEntry: entry)
        }
    }

    func restoreDocument(from entry: DocumentHistoryEntry) throws -> EditableScreenshotDocument {
        try withLockedAccess {
            try SSSDocumentPackage.load(
                from: entry.packageURL,
                allowsExternalRecoveryBase: true,
                files: files
            )
        }
    }

    func incompatibleHistoryEntries() -> [DocumentHistoryEntry] {
        withLockedAccess {
            retryPendingPrivacyExclusionPersistence()
            guard let sessions = try? allSessionRecords() else {
                return []
            }

            return sessions
                .filter {
                    !isPrivacyExcluded($0.id, knownSession: $0)
                }
                .flatMap { session in
                    session.checkpoints.map { historyEntry(from: $0, in: session) }
                }
                .filter { entry in
                    SSSDocumentPackage.compatibilityStatus(at: entry.packageURL, files: files).isUnsupportedFormatVersion
                }
                .sorted { $0.savedAt > $1.savedAt }
        }
    }

    func purgeHistoryEntriesAfterExternalRemoval(_ entries: [DocumentHistoryEntry]) throws {
        try withLockedAccess {
            let entryIDsBySessionID = Dictionary(grouping: entries, by: \.sessionID)
                .mapValues { Set($0.map(\.id)) }

            for (sessionID, entryIDs) in entryIDsBySessionID {
                guard var session = try loadSessionRecord(id: sessionID) else {
                    continue
                }

                session.checkpoints.removeAll { entryIDs.contains($0.id) }

                if session.checkpoints.isEmpty {
                    try? fileManager.removeItem(at: sessionDirectory(for: sessionID))
                    try? removeSearchIndexEntries(for: sessionID)
                    continue
                }

                session.pendingRecovery = session.pendingRecovery && session.checkpoints.contains { $0.deletedAt == nil }
                session.updatedAt = Date()
                try saveSessionRecord(session)
                try pruneUnreferencedCompositionAssets(
                    sessionID: sessionID,
                    retainedCheckpoints: session.checkpoints
                )
            }
        }
    }

    func clearPendingRecovery(for sessionID: UUID) throws {
        try withLockedAccess {
            guard var session = try loadSessionRecord(id: sessionID) else {
                return
            }

            session.pendingRecovery = false
            session.updatedAt = Date()
            try saveSessionRecord(session)
        }
    }

    func deleteHistoryEntry(_ entry: DocumentHistoryEntry) throws {
        try withLockedAccess {
            guard var session = try loadSessionRecord(id: entry.sessionID),
                  let checkpointIndex = session.checkpoints.firstIndex(where: { $0.id == entry.id }) else {
                return
            }

            session.checkpoints[checkpointIndex].deletedAt = Date()
            session.updatedAt = Date()
            try saveSessionRecord(session)
        }
    }

    func permanentlyDeleteHistoryEntry(_ entry: DocumentHistoryEntry) throws {
        try withLockedAccess {
            guard var session = try loadSessionRecord(id: entry.sessionID),
                  let checkpointIndex = session.checkpoints.firstIndex(where: { $0.id == entry.id }) else {
                return
            }

            let checkpoint = session.checkpoints.remove(at: checkpointIndex)

            if session.checkpoints.isEmpty {
                try? fileManager.removeItem(at: sessionDirectory(for: entry.sessionID))
                try? removeSearchIndexEntries(for: entry.sessionID)
                return
            }

            session.updatedAt = Date()
            try saveSessionRecord(session)
            try? fileManager.removeItem(
                at: checkpointsDirectory(for: entry.sessionID)
                    .appendingPathComponent(checkpoint.packageName)
            )
            try pruneUnreferencedCompositionAssets(
                sessionID: entry.sessionID,
                retainedCheckpoints: session.checkpoints
            )
        }
    }

    func permanentlyDeleteRecycledHistoryEntry(_ entry: DocumentHistoryEntry) throws {
        try withLockedAccess {
            guard var session = try loadSessionRecord(id: entry.sessionID) else {
                return
            }

            let deletedCheckpoints = session.checkpoints.filter { $0.deletedAt != nil }
            guard !deletedCheckpoints.isEmpty else {
                return
            }

            session.checkpoints.removeAll { $0.deletedAt != nil }

            if session.checkpoints.isEmpty {
                try? fileManager.removeItem(at: sessionDirectory(for: entry.sessionID))
                try? removeSearchIndexEntries(for: entry.sessionID)
                return
            }

            session.updatedAt = Date()
            try saveSessionRecord(session)
            for checkpoint in deletedCheckpoints {
                try? fileManager.removeItem(
                    at: checkpointsDirectory(for: entry.sessionID)
                        .appendingPathComponent(checkpoint.packageName)
                )
            }
            try pruneUnreferencedCompositionAssets(
                sessionID: entry.sessionID,
                retainedCheckpoints: session.checkpoints
            )
        }
    }

    func deleteHistoryEntries(for sessionID: UUID) throws {
        try withLockedAccess {
            guard var session = try loadSessionRecord(id: sessionID) else {
                return
            }

            let deletedAt = Date()
            for index in session.checkpoints.indices where session.checkpoints[index].deletedAt == nil {
                session.checkpoints[index].deletedAt = deletedAt
            }
            session.pendingRecovery = false
            session.updatedAt = Date()
            try saveSessionRecord(session)
        }
    }

    func restoreRecycledHistoryEntry(_ entry: DocumentHistoryEntry) throws {
        try withLockedAccess {
            guard var session = try loadSessionRecord(id: entry.sessionID),
                  session.checkpoints.contains(where: { $0.id == entry.id }) else {
                return
            }

            for index in session.checkpoints.indices {
                session.checkpoints[index].deletedAt = nil
            }
            session.pendingRecovery = true
            session.updatedAt = Date()
            try saveSessionRecord(session)
        }
    }

    func emptyRecycleBin() throws {
        try withLockedAccess {
            let entries = allRecycledHistoryEntries()

            for entry in entries {
                try permanentlyDeleteRecycledHistoryEntry(entry)
            }
        }
    }

    @discardableResult
    func pruneRecycleBin(deletedBefore cutoffDate: Date) throws -> Bool {
        try withLockedAccess {
            let expiredEntries = allRecycledHistoryEntries().filter { entry in
                guard let deletedAt = entry.deletedAt else {
                    return false
                }

                return deletedAt < cutoffDate
            }

            for entry in expiredEntries {
                try permanentlyDeleteHistoryEntry(entry)
            }

            return !expiredEntries.isEmpty
        }
    }

    func updateCheckpointSearchableText(
        sessionID: UUID,
        checkpointID: UUID,
        searchableText: String
    ) throws {
        try withLockedAccess {
            guard var session = try loadSessionRecord(id: sessionID),
                  let checkpointIndex = session.checkpoints.firstIndex(where: { $0.id == checkpointID }) else {
                return
            }

            session.checkpoints[checkpointIndex].searchableText = searchableText
            session.updatedAt = Date()
            try saveSessionRecord(session)
        }
    }

    func deleteSession(_ sessionID: UUID) throws {
        try withLockedAccess {
            guard var session = try loadSessionRecord(id: sessionID) else {
                return
            }

            let deletedAt = Date()
            for index in session.checkpoints.indices where session.checkpoints[index].deletedAt == nil {
                session.checkpoints[index].deletedAt = deletedAt
            }
            session.pendingRecovery = false
            session.updatedAt = Date()
            try saveSessionRecord(session)
        }
    }

    func deletePendingRecoverySessions(excluding excludedSessionID: UUID? = nil) throws {
        try withLockedAccess {
            let records = try allSessionRecords()

            for session in records where session.pendingRecovery && session.id != excludedSessionID {
                try? deleteSession(session.id)
            }
        }
    }

    func allHistoryEntries(limit: Int? = nil) -> [DocumentHistoryEntry] {
        withLockedAccess {
            retryPendingPrivacyExclusionPersistence()
            guard let index = try? loadSearchIndex() else {
                return []
            }
            let excludedSessionIDs = privacyExcludedSessionIDs()

            let entries = index.entries
                .filter {
                    $0.deletedAt == nil
                        && !excludedSessionIDs.contains($0.sessionID)
                }
                .map { historyEntry(from: $0) }
                .sorted { $0.savedAt > $1.savedAt }

            guard let limit else {
                return entries
            }

            return Array(entries.prefix(limit))
        }
    }

    func searchHistoryEntries(matching query: String, limit: Int? = nil) -> [DocumentHistoryEntry] {
        withLockedAccess {
            retryPendingPrivacyExclusionPersistence()
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase

            guard !normalizedQuery.isEmpty else {
                return allHistoryEntries(limit: limit)
            }

            guard let index = try? loadSearchIndex() else {
                return []
            }
            let excludedSessionIDs = privacyExcludedSessionIDs()

            let entries = index.entries
                .filter {
                    $0.deletedAt == nil
                        && !excludedSessionIDs.contains($0.sessionID)
                        && $0.matches(normalizedQuery)
                }
                .map { historyEntry(from: $0) }
                .sorted { $0.savedAt > $1.savedAt }

            guard let limit else {
                return entries
            }

            return Array(entries.prefix(limit))
        }
    }

    func snipHistorySessionPage(
        matching query: String,
        offset: Int,
        limit: Int
    ) -> DocumentHistoryPage {
        let matchingEntries = searchHistoryEntries(matching: query)
        let latestMatchingEntryBySession = Dictionary(
            grouping: matchingEntries,
            by: \.sessionID
        )
        .values
        .compactMap { sessionEntries in
            sessionEntries.max { $0.savedAt < $1.savedAt }
        }
        .sorted { $0.savedAt > $1.savedAt }

        return Self.page(
            latestMatchingEntryBySession,
            offset: offset,
            limit: limit
        )
    }

    func recentSnipPage(
        matching query: String,
        excluding excludedSessionID: UUID?,
        offset: Int,
        limit: Int
    ) -> DocumentHistoryPage {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = pendingRecoveryEntries(
            excluding: excludedSessionID
        )
        let matchingEntries = normalizedQuery.isEmpty
            ? entries
            : entries.filter { $0.matchesSearchQuery(normalizedQuery) }
        return Self.page(matchingEntries, offset: offset, limit: limit)
    }

    func recycledSnipPage(
        matching query: String,
        offset: Int,
        limit: Int
    ) -> DocumentHistoryPage {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = recycledHistoryEntries()
        let matchingEntries = normalizedQuery.isEmpty
            ? entries
            : entries.filter { $0.matchesSearchQuery(normalizedQuery) }
        return Self.page(matchingEntries, offset: offset, limit: limit)
    }

    func recycledHistoryEntries(limit: Int? = nil) -> [DocumentHistoryEntry] {
        withLockedAccess {
            retryPendingPrivacyExclusionPersistence()
            let entriesBySessionID = Dictionary(grouping: allRecycledHistoryEntries(), by: \.sessionID)
            let entries = entriesBySessionID.values
                .compactMap { sessionEntries in
                    sessionEntries.max {
                        ($0.deletedAt ?? .distantPast) < ($1.deletedAt ?? .distantPast)
                    }
                }
                .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }

            guard let limit else {
                return entries
            }

            return Array(entries.prefix(limit))
        }
    }

    private func allRecycledHistoryEntries() -> [DocumentHistoryEntry] {
        guard let index = try? loadSearchIndex() else {
            return []
        }
        let excludedSessionIDs = privacyExcludedSessionIDs()

        return index.entries
            .filter {
                $0.deletedAt != nil
                    && !excludedSessionIDs.contains($0.sessionID)
            }
            .map { historyEntry(from: $0) }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    func presentationState(
        currentSessionID: UUID?,
        captureHistoryLimit: Int,
        recentSnipLimit: Int,
        recycleBinLimit: Int
    ) -> RecoveryPresentationState {
        withLockedAccess {
            retryPendingPrivacyExclusionPersistence()
            guard let index = try? loadSearchIndex() else {
                return RecoveryPresentationState(
                    historyEntries: [],
                    allCaptureHistoryEntries: [],
                    recentSnipEntries: [],
                    recycleBinEntries: [],
                    pendingRecoverySession: nil
                )
            }
            let excludedSessionIDs = privacyExcludedSessionIDs()
            let visibleIndexEntries = index.entries.filter {
                !excludedSessionIDs.contains($0.sessionID)
            }

            let historyEntries: [DocumentHistoryEntry]

            if let currentSessionID {
                historyEntries = visibleIndexEntries
                    .filter { $0.sessionID == currentSessionID }
                    .filter { $0.deletedAt == nil }
                    .sorted { $0.savedAt > $1.savedAt }
                    .map { historyEntry(from: $0, derivingLegacySummary: true) }
            } else {
                historyEntries = []
            }

            let allCaptureHistoryEntries = visibleIndexEntries
                .filter { $0.deletedAt == nil }
                .map { historyEntry(from: $0) }
                .sorted { $0.savedAt > $1.savedAt }

            let pendingEntries = Dictionary(grouping: visibleIndexEntries.filter { $0.pendingRecovery && $0.deletedAt == nil }, by: \.sessionID)
                .values
                .compactMap { sessionEntries in
                    sessionEntries.max { $0.savedAt < $1.savedAt }.map { historyEntry(from: $0) }
                }
                .sorted { $0.savedAt > $1.savedAt }

            let recentSnipEntries = pendingEntries.filter { $0.sessionID != currentSessionID }
            let pendingRecoverySession = pendingEntries.first.map {
                PendingRecoverySession(id: $0.sessionID, title: $0.title, latestEntry: $0)
            }
            let recycleBinEntriesBySessionID = Dictionary(grouping: visibleIndexEntries.filter { $0.deletedAt != nil }.map { historyEntry(from: $0) }, by: \.sessionID)
            let recycleBinEntries = recycleBinEntriesBySessionID.values
                .compactMap { sessionEntries in
                    sessionEntries.max {
                        ($0.deletedAt ?? .distantPast) < ($1.deletedAt ?? .distantPast)
                    }
                }
                .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }

            return RecoveryPresentationState(
                historyEntries: historyEntries,
                allCaptureHistoryEntries: Array(allCaptureHistoryEntries.prefix(captureHistoryLimit)),
                recentSnipEntries: Array(recentSnipEntries.prefix(recentSnipLimit)),
                recycleBinEntries: Array(recycleBinEntries.prefix(recycleBinLimit)),
                pendingRecoverySession: pendingRecoverySession
            )
        }
    }

    private func withLockedAccess<T>(_ operation: () throws -> T) rethrows -> T {
        accessLock.lock()
        defer { accessLock.unlock() }
        return try operation()
    }

    private static func page(
        _ entries: [DocumentHistoryEntry],
        offset: Int,
        limit: Int
    ) -> DocumentHistoryPage {
        let resolvedOffset = min(max(offset, 0), entries.count)
        let resolvedLimit = max(limit, 1)
        let endIndex = min(resolvedOffset + resolvedLimit, entries.count)
        return DocumentHistoryPage(
            entries: Array(entries[resolvedOffset..<endIndex]),
            totalCount: entries.count,
            offset: resolvedOffset
        )
    }

    private func clearPrivacyExclusionRegistry() {
        exclusionLock.lock()
        registeredPrivacyExclusionIDs.removeAll()
        pendingPrivacyExclusionPersistenceIDs.removeAll()
        exclusionLock.unlock()
    }

    private func registeredPrivacyExclusions() -> Set<UUID> {
        exclusionLock.lock()
        defer { exclusionLock.unlock() }
        return registeredPrivacyExclusionIDs
    }

    private func pendingPrivacyExclusions() -> Set<UUID> {
        exclusionLock.lock()
        defer { exclusionLock.unlock() }
        return pendingPrivacyExclusionPersistenceIDs
    }

    private func rememberPrivacyExclusions(
        _ sessionIDs: Set<UUID>,
        tombstonesAreDurable: Bool
    ) {
        guard !sessionIDs.isEmpty else {
            return
        }

        exclusionLock.lock()
        registeredPrivacyExclusionIDs.formUnion(sessionIDs)
        if tombstonesAreDurable {
            pendingPrivacyExclusionPersistenceIDs.subtract(sessionIDs)
        } else {
            pendingPrivacyExclusionPersistenceIDs.formUnion(sessionIDs)
        }
        exclusionLock.unlock()
    }

    private func isPrivacyExcluded(
        _ sessionID: UUID,
        knownSession: RecoverySessionRecord? = nil
    ) -> Bool {
        if registeredPrivacyExclusions().contains(sessionID) {
            return true
        }

        if fileManager.fileExists(
            atPath: privacyExclusionTombstoneURL(for: sessionID).path
        ) {
            rememberPrivacyExclusions(
                [sessionID],
                tombstonesAreDurable: true
            )
            return true
        }

        if knownSession?.isExcludedFromPresentation == true {
            rememberPrivacyExclusions(
                [sessionID],
                tombstonesAreDurable: false
            )
            return true
        }

        if knownSession == nil,
           let loadedSession = try? loadSessionRecord(id: sessionID),
           loadedSession.isExcludedFromPresentation == true {
            rememberPrivacyExclusions(
                [sessionID],
                tombstonesAreDurable: false
            )
            return true
        }

        return false
    }

    private func privacyExcludedSessionIDs() -> Set<UUID> {
        var sessionIDs = registeredPrivacyExclusions()

        var tombstonedSessionIDs: Set<UUID> = []
        if let tombstoneURLs = try? fileManager.contentsOfDirectory(
            at: privacyExclusionsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            tombstonedSessionIDs.formUnion(tombstoneURLs.compactMap { url in
                guard url.pathExtension == Self.privacyExclusionFilenameExtension else {
                    return nil
                }
                return UUID(
                    uuidString: url.deletingPathExtension().lastPathComponent
                )
            })
            sessionIDs.formUnion(tombstonedSessionIDs)
        }

        var sessionRecordExclusionIDs: Set<UUID> = []
        if let sessions = try? allSessionRecords() {
            sessionRecordExclusionIDs.formUnion(
                sessions.lazy
                    .filter { $0.isExcludedFromPresentation == true }
                    .map(\.id)
            )
            sessionIDs.formUnion(sessionRecordExclusionIDs)
        }

        rememberPrivacyExclusions(
            tombstonedSessionIDs,
            tombstonesAreDurable: true
        )
        rememberPrivacyExclusions(
            sessionRecordExclusionIDs.subtracting(tombstonedSessionIDs),
            tombstonesAreDurable: false
        )
        return sessionIDs
    }

    private func privacyExclusionTombstoneURL(for sessionID: UUID) -> URL {
        privacyExclusionsURL
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension(Self.privacyExclusionFilenameExtension)
    }

    private func persistPrivacyExclusion(for sessionID: UUID) throws {
        var firstPersistenceError: Error?

        do {
            try fileManager.createDirectory(
                at: privacyExclusionsURL,
                withIntermediateDirectories: true
            )
            try Data().write(
                to: privacyExclusionTombstoneURL(for: sessionID),
                options: .atomic
            )
        } catch {
            firstPersistenceError = error
        }

        do {
            if var session = try loadSessionRecord(id: sessionID) {
                session.pendingRecovery = false
                session.isExcludedFromPresentation = true
                session.updatedAt = Date()
                try saveSessionRecord(session)
            }
        } catch {
            if firstPersistenceError == nil {
                firstPersistenceError = error
            }
        }

        // Search-index cleanup is redundant with query-time tombstone
        // filtering, but keeping the cache clean reduces work after relaunch.
        try? removeSearchIndexEntries(for: sessionID)

        let hasTombstone = fileManager.fileExists(
            atPath: privacyExclusionTombstoneURL(for: sessionID).path
        )
        let hasExcludedSessionRecord =
            (try? loadSessionRecord(id: sessionID))?
                .isExcludedFromPresentation == true

        if hasTombstone {
            rememberPrivacyExclusions(
                [sessionID],
                tombstonesAreDurable: true
            )
            return
        }

        if hasExcludedSessionRecord {
            rememberPrivacyExclusions(
                [sessionID],
                tombstonesAreDurable: false
            )
            return
        }

        throw firstPersistenceError
            ?? RecoveryPrivacyExclusionError.couldNotPersist(sessionID)
    }

    /// Failed low-disk writes remain fail-closed in memory and are retried on
    /// the next store interaction. Once either the standalone tombstone or the
    /// session flag is durable, a later store instance can enforce exclusion.
    private func retryPendingPrivacyExclusionPersistence() {
        for sessionID in pendingPrivacyExclusions() {
            try? persistPrivacyExclusion(for: sessionID)
        }
    }

    private func discardUncommittedCheckpoint(
        sessionID: UUID,
        packageURL: URL
    ) {
        try? fileManager.removeItem(at: packageURL)
        let retainedCheckpoints =
            (try? loadSessionRecord(id: sessionID))?.checkpoints ?? []
        try? pruneUnreferencedCompositionAssets(
            sessionID: sessionID,
            retainedCheckpoints: retainedCheckpoints
        )

        if retainedCheckpoints.isEmpty {
            try? fileManager.removeItem(at: sessionBaseImageURL(for: sessionID))
        }
    }

    private func discardCommittedCheckpoint(
        sessionID: UUID,
        checkpointID: UUID,
        packageURL: URL
    ) throws {
        guard var session = try loadSessionRecord(id: sessionID) else {
            try? fileManager.removeItem(at: packageURL)
            return
        }

        session.checkpoints.removeAll { $0.id == checkpointID }
        session.pendingRecovery = false
        session.isExcludedFromPresentation = true
        session.updatedAt = Date()
        try saveSessionRecord(session)
        try? fileManager.removeItem(at: packageURL)
        try pruneUnreferencedCompositionAssets(
            sessionID: sessionID,
            retainedCheckpoints: session.checkpoints
        )
    }

    private func ensureRootDirectories() throws {
        try fileManager.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
    }

    private func allSessionRecords() throws -> [RecoverySessionRecord] {
        try ensureRootDirectories()
        let sessionDirectories = try fileManager.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return sessionDirectories.compactMap { url in
            try? loadSessionRecord(fromDirectory: url)
        }
    }

    private func sessionDirectory(for sessionID: UUID) -> URL {
        sessionsURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    private func checkpointsDirectory(for sessionID: UUID) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent("checkpoints", isDirectory: true)
    }

    private func sessionBaseImageURL(for sessionID: UUID) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent(Self.sharedBaseImageName)
    }

    private func sessionCompositionAssetsURL(for sessionID: UUID) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent(
            Self.sharedCompositionAssetsDirectoryName,
            isDirectory: true
        )
    }

    /// Removes only immutable captures that no retained checkpoint references.
    /// Deleted checkpoints in the Recycle Bin remain in `retainedCheckpoints`
    /// and therefore keep their source pixels until permanent deletion.
    private func pruneUnreferencedCompositionAssets(
        sessionID: UUID,
        retainedCheckpoints: [RecoveryCheckpointRecord]
    ) throws {
        let assetsURL = sessionCompositionAssetsURL(for: sessionID)
        guard fileManager.fileExists(atPath: assetsURL.path) else {
            return
        }

        let retainedIDs = Set(
            retainedCheckpoints.flatMap { $0.compositionAssetIDs ?? [] }
        )
        let storedURLs = try fileManager.contentsOfDirectory(
            at: assetsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        for assetURL in storedURLs {
            guard assetURL.pathExtension.localizedLowercase == "png",
                  let id = UUID(
                    uuidString: assetURL.deletingPathExtension().lastPathComponent
                  ),
                  !retainedIDs.contains(id) else {
                continue
            }
            try fileManager.removeItem(at: assetURL)
        }
    }

    private func sessionMetadataURL(for sessionID: UUID) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent("session.json")
    }

    private func loadSessionRecord(id sessionID: UUID) throws -> RecoverySessionRecord? {
        try loadSessionRecord(fromDirectory: sessionDirectory(for: sessionID))
    }

    private func loadSessionRecord(fromDirectory directoryURL: URL) throws -> RecoverySessionRecord? {
        let metadataURL = directoryURL.appendingPathComponent("session.json")

        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecoverySessionRecord.self, from: Data(contentsOf: metadataURL))
    }

    private func saveSessionRecord(_ proposedSession: RecoverySessionRecord) throws {
        var session = proposedSession
        if isPrivacyExcluded(session.id, knownSession: session) {
            session.pendingRecovery = false
            session.isExcludedFromPresentation = true
        }

        let directoryURL = sessionDirectory(for: session.id)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(session)
        try data.write(to: sessionMetadataURL(for: session.id), options: .atomic)
        try updateSearchIndex(for: session)
    }

    private func historyEntry(from checkpoint: RecoveryCheckpointRecord, in session: RecoverySessionRecord) -> DocumentHistoryEntry {
        let packageURL = checkpointsDirectory(for: session.id).appendingPathComponent(checkpoint.packageName, isDirectory: true)
        let previewAssetURL: URL?

        if let previewAssetName = checkpoint.previewAssetName {
            let candidateURL = packageURL.appendingPathComponent(previewAssetName)
            previewAssetURL = fileManager.fileExists(atPath: candidateURL.path) ? candidateURL : nil
        } else {
            previewAssetURL = SSSDocumentPackage.previewAssetURL(in: packageURL, files: files)
        }

        return DocumentHistoryEntry(
            id: checkpoint.id,
            sessionID: session.id,
            title: session.title,
            label: checkpoint.label,
            changeSummary: checkpoint.changeSummary,
            savedAt: checkpoint.savedAt,
            packageURL: packageURL,
            previewAssetURL: previewAssetURL,
            sourceDocumentURL: session.sourceDocumentPath.map { URL(fileURLWithPath: $0) },
            hasUnsavedChanges: checkpoint.hasUnsavedChanges,
            searchableText: checkpoint.searchableText ?? SSSDocumentPackage.loadSearchableText(from: packageURL, files: files),
            packageSizeBytes: checkpoint.packageSizeBytes,
            deletedAt: checkpoint.deletedAt
        )
    }

    private func historyEntry(from indexEntry: RecoverySearchIndexEntry, derivingLegacySummary: Bool = false) -> DocumentHistoryEntry {
        let packageURL = checkpointsDirectory(for: indexEntry.sessionID).appendingPathComponent(indexEntry.packageName, isDirectory: true)
        let previewAssetURL: URL?
        let changeSummary: String?

        if let previewAssetName = indexEntry.previewAssetName {
            let candidateURL = packageURL.appendingPathComponent(previewAssetName)
            previewAssetURL = fileManager.fileExists(atPath: candidateURL.path) ? candidateURL : nil
        } else {
            previewAssetURL = SSSDocumentPackage.previewAssetURL(in: packageURL, files: files)
        }

        if let persistedSummary = indexEntry.changeSummary {
            changeSummary = persistedSummary
        } else if derivingLegacySummary,
                  let document = try? SSSDocumentPackage.load(
                    from: packageURL,
                    allowsExternalRecoveryBase: true,
                    files: files
                  ) {
            changeSummary = RecoveryCheckpointSummary.summary(for: document.session, fallbackLabel: indexEntry.label)
        } else {
            changeSummary = nil
        }

        return DocumentHistoryEntry(
            id: indexEntry.id,
            sessionID: indexEntry.sessionID,
            title: indexEntry.title,
            label: indexEntry.label,
            changeSummary: changeSummary,
            savedAt: indexEntry.savedAt,
            packageURL: packageURL,
            previewAssetURL: previewAssetURL,
            sourceDocumentURL: indexEntry.sourceDocumentPath.map { URL(fileURLWithPath: $0) },
            hasUnsavedChanges: indexEntry.hasUnsavedChanges,
            searchableText: indexEntry.searchableText,
            packageSizeBytes: indexEntry.packageSizeBytes,
            deletedAt: indexEntry.deletedAt
        )
    }

    private func loadSearchIndex() throws -> RecoverySearchIndex {
        try ensureRootDirectories()

        guard fileManager.fileExists(atPath: searchIndexURL.path) else {
            return try rebuildSearchIndex()
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let index = try decoder.decode(RecoverySearchIndex.self, from: Data(contentsOf: searchIndexURL))

            guard index.version == RecoverySearchIndex.currentVersion else {
                return try rebuildSearchIndex()
            }

            return index
        } catch {
            return try rebuildSearchIndex()
        }
    }

    @discardableResult
    private func rebuildSearchIndex() throws -> RecoverySearchIndex {
        let excludedSessionIDs = privacyExcludedSessionIDs()
        let index = RecoverySearchIndex(
            entries: try allSessionRecords()
                .filter { !excludedSessionIDs.contains($0.id) }
                .flatMap(Self.searchIndexEntries(for:))
        )
        try saveSearchIndex(index)
        return index
    }

    private func updateSearchIndex(for session: RecoverySessionRecord) throws {
        var index = try loadSearchIndex()
        index.entries.removeAll { $0.sessionID == session.id }
        index.entries.append(contentsOf: Self.searchIndexEntries(for: session))
        index.entries.sort { $0.savedAt > $1.savedAt }
        try saveSearchIndex(index)
    }

    private func removeSearchIndexEntries(for sessionID: UUID) throws {
        var index = try loadSearchIndex()
        index.entries.removeAll { $0.sessionID == sessionID }
        try saveSearchIndex(index)
    }

    private func saveSearchIndex(_ index: RecoverySearchIndex) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(index)
        try data.write(to: searchIndexURL, options: .atomic)
    }

    private static func searchIndexEntries(for session: RecoverySessionRecord) -> [RecoverySearchIndexEntry] {
        guard session.isExcludedFromPresentation != true else {
            return []
        }

        return session.checkpoints.map { checkpoint in
            RecoverySearchIndexEntry(
                id: checkpoint.id,
                sessionID: session.id,
                title: session.title,
                label: checkpoint.label,
                changeSummary: checkpoint.changeSummary,
                savedAt: checkpoint.savedAt,
                packageName: checkpoint.packageName,
                previewAssetName: checkpoint.previewAssetName,
                sourceDocumentPath: session.sourceDocumentPath,
                hasUnsavedChanges: checkpoint.hasUnsavedChanges,
                searchableText: checkpoint.searchableText ?? "",
                packageSizeBytes: checkpoint.packageSizeBytes,
                deletedAt: checkpoint.deletedAt,
                pendingRecovery: session.pendingRecovery
            )
        }
    }

    private func directorySize(at url: URL) throws -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(resourceKeys))

        var totalSize: Int64 = 0

        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)

            guard values.isRegularFile == true else {
                continue
            }

            let fileSize = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            totalSize += Int64(fileSize)
        }

        return totalSize
    }

    private func archiveItemSize(at url: URL) throws -> Int64 {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if isDirectory.boolValue {
            return try directorySize(at: url)
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey
        ]
        let values = try url.resourceValues(forKeys: resourceKeys)
        guard values.isRegularFile == true else {
            return 0
        }

        return Int64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
        )
    }
}

nonisolated private struct RecoverySessionRecord: Codable {
    var id: UUID
    var title: String
    var sourceDocumentPath: String?
    var createdAt: Date
    var updatedAt: Date
    var pendingRecovery: Bool
    var baseImageName: String?
    var checkpoints: [RecoveryCheckpointRecord]
    var isExcludedFromPresentation: Bool?
}

nonisolated private struct RecoveryCheckpointRecord: Codable {
    var id: UUID
    var label: String
    var changeSummary: String?
    var savedAt: Date
    var packageName: String
    var hasUnsavedChanges: Bool
    var previewAssetName: String?
    var searchableText: String?
    var packageSizeBytes: Int64?
    var deletedAt: Date?
    var compositionAssetIDs: [UUID]?
}

nonisolated private struct RecoverySearchIndex: Codable {
    static let currentVersion = 1

    var version = currentVersion
    var entries: [RecoverySearchIndexEntry]
}

nonisolated private struct RecoverySearchIndexEntry: Codable {
    var id: UUID
    var sessionID: UUID
    var title: String
    var label: String
    var changeSummary: String?
    var savedAt: Date
    var packageName: String
    var previewAssetName: String?
    var sourceDocumentPath: String?
    var hasUnsavedChanges: Bool
    var searchableText: String
    var packageSizeBytes: Int64?
    var deletedAt: Date?
    var pendingRecovery: Bool

    func matches(_ normalizedQuery: String) -> Bool {
        let searchTokens = [title, label, sourceDocumentPath.map { URL(fileURLWithPath: $0).lastPathComponent }, searchableText]
            .compactMap { $0 }
            .joined(separator: " ")
            .localizedLowercase

        return searchTokens.contains(normalizedQuery)
    }
}

nonisolated private enum RecoveryPrivacyExclusionError: Error {
    case couldNotPersist(UUID)
}

nonisolated private enum RecoveryCheckpointSummary {
    static func summary(for session: EditorDocumentSession, fallbackLabel: String) -> String {
        let previousSnapshot = session.undoStack.last ?? session.initialSnapshot
        let currentSnapshot = session.currentSnapshot

        if let annotationSummary = annotationSummary(from: previousSnapshot, to: currentSnapshot) {
            return annotationSummary
        }

        if currentSnapshot.cropRect != previousSnapshot.cropRect {
            return "Crop changed"
        }

        if currentSnapshot.presentation != previousSnapshot.presentation {
            return "Polish changed"
        }

        return fallbackLabel
    }

    private static func annotationSummary(from previousSnapshot: EditorSnapshot, to currentSnapshot: EditorSnapshot) -> String? {
        let previousByID = Dictionary(uniqueKeysWithValues: previousSnapshot.annotations.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: currentSnapshot.annotations.map { ($0.id, $0) })

        let added = currentSnapshot.annotations.filter { previousByID[$0.id] == nil }
        let removed = previousSnapshot.annotations.filter { currentByID[$0.id] == nil }
        let updatedPairs = currentSnapshot.annotations.compactMap { annotation -> (Annotation, Annotation)? in
            guard let previous = previousByID[annotation.id], previous != annotation else {
                return nil
            }

            return (previous, annotation)
        }

        if let updatedTextSummary = updatedTextSummary(for: updatedPairs) {
            return updatedTextSummary
        }

        if !added.isEmpty {
            return addedAnnotationsSummary(added)
        }

        if !removed.isEmpty {
            return removedAnnotationsSummary(removed)
        }

        if let updatedAnnotation = updatedPairs.first?.1 {
            return "\(annotationKindName(for: updatedAnnotation)) edited"
        }

        return nil
    }

    private static func updatedTextSummary(for updatedPairs: [(Annotation, Annotation)]) -> String? {
        guard updatedPairs.count == 1 else {
            return nil
        }

        let (previous, current) = updatedPairs[0]

        switch (previous.kind, current.kind) {
        case let (.text(previousShape), .text(currentShape)) where previousShape.text != currentShape.text:
            return "Text: \(quotedSnippet(currentShape.text))"
        case let (.callout(previousShape), .callout(currentShape)) where previousShape.text != currentShape.text:
            return "Callout: \(quotedSnippet(currentShape.text))"
        case let (.arrow(previousShape), .arrow(currentShape)) where previousShape.label != currentShape.label && !currentShape.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "Arrow label: \(quotedSnippet(currentShape.label))"
        default:
            return nil
        }
    }

    private static func addedAnnotationsSummary(_ annotations: [Annotation]) -> String {
        if annotations.count == 1, let detail = detailedAnnotationSummary(for: annotations[0]) {
            return detail
        }

        return groupedAnnotationSummary(for: annotations)
    }

    private static func removedAnnotationsSummary(_ annotations: [Annotation]) -> String {
        if annotations.count == 1 {
            return "\(annotationKindName(for: annotations[0])) deleted"
        }

        return "\(groupedAnnotationSummary(for: annotations)) deleted"
    }

    private static func groupedAnnotationSummary(for annotations: [Annotation]) -> String {
        let grouped = Dictionary(grouping: annotations, by: annotationKindName)
        let ordered = grouped.keys.sorted()
        let parts = ordered.prefix(2).map { key -> String in
            let count = grouped[key]?.count ?? 0
            return count == 1 ? key : pluralized(key, count: count)
        }

        let summary = parts.joined(separator: " + ")
        return grouped.count > 2 ? summary + " + more" : summary
    }

    private static func detailedAnnotationSummary(for annotation: Annotation) -> String? {
        switch annotation.kind {
        case let .text(shape):
            return "Text: \(quotedSnippet(shape.text))"
        case let .callout(shape):
            return "Callout: \(quotedSnippet(shape.text))"
        case let .arrow(shape):
            let trimmed = shape.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "Arrow label: \(quotedSnippet(trimmed))"
            }
            return "Arrow"
        default:
            return nil
        }
    }

    private static func annotationKindName(for annotation: Annotation) -> String {
        annotation.kind.displayName
    }

    private static func pluralized(_ noun: String, count: Int) -> String {
        let lowercased = noun.lowercased()

        if lowercased == "freehand" {
            return "\(count) freehand marks"
        }

        if lowercased == "highlighter" {
            return "\(count) highlighter marks"
        }

        if lowercased == "highlight box" {
            return "\(count) highlight boxes"
        }

        if lowercased == "blur" || lowercased == "pixelate" || lowercased == "redact" {
            return "\(count) \(lowercased) areas"
        }

        return "\(count) \(lowercased)s"
    }

    private static func quotedSnippet(_ text: String, limit: Int = 44) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard normalized.count > limit else {
            return normalized
        }

        let limitIndex = normalized.index(normalized.startIndex, offsetBy: limit)
        let prefix = String(normalized[..<limitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + "…"
    }
}
