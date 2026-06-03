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
        if let changeSummary {
            return changeSummary
        }

        let genericCandidates = [
            label,
            title,
            (title as NSString).deletingPathExtension,
            "capture",
            "autosave",
            "recent snip",
            "saved",
            "display",
            "window",
            "fullscreen"
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase }

        let lines = searchableText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            let normalized = line.localizedLowercase

            if genericCandidates.contains(normalized) || normalized.hasPrefix("display ") {
                continue
            }

            return line
        }

        return label
    }

    var historySummaryHelp: String? {
        changeSummary
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

nonisolated final class DocumentRecoveryStore: @unchecked Sendable {
    private static let maxCheckpointCount = 12
    private static let sharedBaseImageName = SSSDocumentPackage.baseImageFilename
    private static let sharedBaseImageRelativePath = "../../\(SSSDocumentPackage.baseImageFilename)"

    private let accessLock = NSRecursiveLock()
    private let fileManager: FileManager
    private let rootURL: URL
    private let sessionsURL: URL
    private let searchIndexURL: URL

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

    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager

        rootURL = baseURL ?? Self.defaultArchiveURL(fileManager: fileManager)

        sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        searchIndexURL = rootURL.appendingPathComponent("search-index.json")
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
        try withLockedAccess {
            guard maximumSizeBytes > 0 else {
                return false
            }

            var currentSize = try archiveSizeInBytes()

            guard currentSize > maximumSizeBytes else {
                return false
            }

            var didPrune = false
            let sessions = try allSessionRecords()
            var remainingCheckpointsBySession = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.checkpoints.count) })
            let oldestFirstEntries = sessions
                .flatMap { session in
                    session.checkpoints.map { historyEntry(from: $0, in: session) }
                }
                .sorted { $0.savedAt < $1.savedAt }

            for entry in oldestFirstEntries where currentSize > maximumSizeBytes {
                let deletionSize: Int64

                if remainingCheckpointsBySession[entry.sessionID] == 1 {
                    deletionSize = try directorySize(at: sessionDirectory(for: entry.sessionID))
                } else {
                    deletionSize = try (entry.packageSizeBytes ?? directorySize(at: entry.packageURL))
                }

                try permanentlyDeleteHistoryEntry(entry)
                currentSize = max(0, currentSize - deletionSize)
                if let remaining = remainingCheckpointsBySession[entry.sessionID] {
                    remainingCheckpointsBySession[entry.sessionID] = max(remaining - 1, 0)
                }
                didPrune = true
            }

            return didPrune
        }
    }

    func clearArchive() throws {
        try withLockedAccess {
            guard fileManager.fileExists(atPath: rootURL.path) else {
                return
            }

            try fileManager.removeItem(at: rootURL)
            try ensureRootDirectories()
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
                checkpoints: []
            ))
            return sessionID
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
        hasUnsavedChanges: Bool
    ) throws {
        try withLockedAccess {
            try ensureRootDirectories()

            var session = try loadSessionRecord(id: sessionID) ?? RecoverySessionRecord(
                id: sessionID,
                title: title,
                sourceDocumentPath: sourceDocumentURL?.path,
                createdAt: Date(),
                updatedAt: Date(),
                pendingRecovery: pendingRecovery,
                baseImageName: nil,
                checkpoints: []
            )

            let checkpointID = UUID()
            let packageName = "checkpoint-\(checkpointID.uuidString).sss"
            let packageURL = checkpointsDirectory(for: sessionID).appendingPathComponent(packageName, isDirectory: true)
            let sharedBaseImageURL = sessionBaseImageURL(for: sessionID)
            let searchableText = SSSDocumentPackage.searchableText(for: document)
            let changeSummary = RecoveryCheckpointSummary.summary(for: document.session, fallbackLabel: label)
            try fileManager.createDirectory(at: checkpointsDirectory(for: sessionID), withIntermediateDirectories: true)
            try SSSDocumentPackage.save(
                document: document,
                previewImage: previewImage,
                to: packageURL,
                baseImageStorage: .shared(
                    assetName: Self.sharedBaseImageRelativePath,
                    fileURL: sharedBaseImageURL
                )
            )
            let packageSizeBytes = try directorySize(at: packageURL)

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
                packageSizeBytes: packageSizeBytes
            ))
            session.checkpoints.sort { $0.savedAt > $1.savedAt }

            if session.checkpoints.count > Self.maxCheckpointCount {
                let overflow = session.checkpoints.suffix(from: Self.maxCheckpointCount)
                for checkpoint in overflow {
                    try? fileManager.removeItem(at: checkpointsDirectory(for: sessionID).appendingPathComponent(checkpoint.packageName))
                }
                session.checkpoints = Array(session.checkpoints.prefix(Self.maxCheckpointCount))
            }

            try saveSessionRecord(session)
        }
    }

    func historyEntries(for sessionID: UUID) -> [DocumentHistoryEntry] {
        withLockedAccess {
            guard let session = try? loadSessionRecord(id: sessionID) else {
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
            guard let records = try? allSessionRecords() else {
                return []
            }

            let entries = records.compactMap { session -> DocumentHistoryEntry? in
                guard session.pendingRecovery,
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
            try SSSDocumentPackage.load(from: entry.packageURL)
        }
    }

    func incompatibleHistoryEntries() -> [DocumentHistoryEntry] {
        withLockedAccess {
            guard let sessions = try? allSessionRecords() else {
                return []
            }

            return sessions
                .flatMap { session in
                    session.checkpoints.map { historyEntry(from: $0, in: session) }
                }
                .filter { entry in
                    SSSDocumentPackage.compatibilityStatus(at: entry.packageURL).isUnsupportedFormatVersion
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
            try? fileManager.removeItem(at: checkpointsDirectory(for: entry.sessionID).appendingPathComponent(checkpoint.packageName))

            if session.checkpoints.isEmpty {
                try? fileManager.removeItem(at: sessionDirectory(for: entry.sessionID))
                try? removeSearchIndexEntries(for: entry.sessionID)
                return
            }

            session.updatedAt = Date()
            try saveSessionRecord(session)
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

            for checkpoint in deletedCheckpoints {
                try? fileManager.removeItem(at: checkpointsDirectory(for: entry.sessionID).appendingPathComponent(checkpoint.packageName))
            }
            session.checkpoints.removeAll { $0.deletedAt != nil }

            if session.checkpoints.isEmpty {
                try? fileManager.removeItem(at: sessionDirectory(for: entry.sessionID))
                try? removeSearchIndexEntries(for: entry.sessionID)
                return
            }

            session.updatedAt = Date()
            try saveSessionRecord(session)
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
            guard let index = try? loadSearchIndex() else {
                return []
            }

            let entries = index.entries
                .filter { $0.deletedAt == nil }
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
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase

            guard !normalizedQuery.isEmpty else {
                return allHistoryEntries(limit: limit)
            }

            guard let index = try? loadSearchIndex() else {
                return []
            }

            let entries = index.entries
                .filter { $0.deletedAt == nil && $0.matches(normalizedQuery) }
                .map { historyEntry(from: $0) }
                .sorted { $0.savedAt > $1.savedAt }

            guard let limit else {
                return entries
            }

            return Array(entries.prefix(limit))
        }
    }

    func recycledHistoryEntries(limit: Int? = nil) -> [DocumentHistoryEntry] {
        withLockedAccess {
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

        return index.entries
            .filter { $0.deletedAt != nil }
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
            guard let index = try? loadSearchIndex() else {
                return RecoveryPresentationState(
                    historyEntries: [],
                    allCaptureHistoryEntries: [],
                    recentSnipEntries: [],
                    recycleBinEntries: [],
                    pendingRecoverySession: nil
                )
            }

            let historyEntries: [DocumentHistoryEntry]

            if let currentSessionID {
                historyEntries = index.entries
                    .filter { $0.sessionID == currentSessionID }
                    .filter { $0.deletedAt == nil }
                    .sorted { $0.savedAt > $1.savedAt }
                    .map { historyEntry(from: $0, derivingLegacySummary: true) }
            } else {
                historyEntries = []
            }

            let allCaptureHistoryEntries = index.entries
                .filter { $0.deletedAt == nil }
                .map { historyEntry(from: $0) }
                .sorted { $0.savedAt > $1.savedAt }

            let pendingEntries = Dictionary(grouping: index.entries.filter { $0.pendingRecovery && $0.deletedAt == nil }, by: \.sessionID)
                .values
                .compactMap { sessionEntries in
                    sessionEntries.max { $0.savedAt < $1.savedAt }.map { historyEntry(from: $0) }
                }
                .sorted { $0.savedAt > $1.savedAt }

            let recentSnipEntries = pendingEntries.filter { $0.sessionID != currentSessionID }
            let pendingRecoverySession = pendingEntries.first.map {
                PendingRecoverySession(id: $0.sessionID, title: $0.title, latestEntry: $0)
            }
            let recycleBinEntriesBySessionID = Dictionary(grouping: index.entries.filter { $0.deletedAt != nil }.map { historyEntry(from: $0) }, by: \.sessionID)
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

    private func saveSessionRecord(_ session: RecoverySessionRecord) throws {
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
            previewAssetURL = SSSDocumentPackage.previewAssetURL(in: packageURL)
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
            searchableText: checkpoint.searchableText ?? SSSDocumentPackage.loadSearchableText(from: packageURL),
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
            previewAssetURL = SSSDocumentPackage.previewAssetURL(in: packageURL)
        }

        if let persistedSummary = indexEntry.changeSummary {
            changeSummary = persistedSummary
        } else if derivingLegacySummary,
                  let document = try? SSSDocumentPackage.load(from: packageURL) {
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
        let index = RecoverySearchIndex(entries: try allSessionRecords().flatMap(Self.searchIndexEntries(for:)))
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
        session.checkpoints.map { checkpoint in
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
}

nonisolated private struct RecoverySessionRecord: Codable {
    var id: UUID
    var title: String
    var sourceDocumentPath: String?
    var createdAt: Date
    var updatedAt: Date
    var pendingRecovery: Bool
    // TODO(Phase 5+): Remove support for older recovery sessions whose checkpoints each embed base.png.
    var baseImageName: String?
    var checkpoints: [RecoveryCheckpointRecord]
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
            return "Presentation changed"
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
        switch annotation.kind {
        case .rectangle:
            return "Rectangle"
        case .ellipse:
            return "Ellipse"
        case .line:
            return "Line"
        case .arrow:
            return "Arrow"
        case .freehand:
            return "Freehand"
        case .highlighter:
            return "Highlighter"
        case .highlight:
            return "Highlight Box"
        case .text:
            return "Text"
        case .callout:
            return "Callout"
        case .measurement:
            return "Ruler"
        case .spotlight:
            return "Spotlight"
        case let .imageOverlay(shape):
            return shape.role == .capturedCursor ? "Cursor" : "Image"
        case let .redaction(shape):
            return shape.mode.label
        }
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
