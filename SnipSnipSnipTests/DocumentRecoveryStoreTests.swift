import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

final class DocumentRecoveryStoreTests: XCTestCase {
    func testSaveCheckpointCreatesHistoryAndPendingRecoveryEntry() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(title: "Draft.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Draft.sss",
            sourceDocumentURL: nil,
            label: "Autosave",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let history = store.historyEntries(for: sessionID)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.label, "Autosave")
        XCTAssertEqual(history.first?.previewAssetURL?.lastPathComponent, "preview.png")
        let entry = try XCTUnwrap(history.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.packageURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.packageURL.appendingPathComponent("base.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionBaseImageURL(from: entry).path))

        let pendingRecovery = try XCTUnwrap(store.latestPendingRecovery())
        XCTAssertEqual(pendingRecovery.id, sessionID)
        XCTAssertEqual(pendingRecovery.latestEntry.label, "Autosave")
        XCTAssertTrue(pendingRecovery.latestEntry.hasUnsavedChanges)

        let restored = try store.restoreDocument(from: entry)
        XCTAssertEqual(restored.session, document.session)
        XCTAssertEqual(restored.capture.sourceRect, document.capture.sourceRect)

        try store.clearPendingRecovery(for: sessionID)
        XCTAssertNil(store.latestPendingRecovery())

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testRecoveryCheckpointsShareBaseImageAcrossSession() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(title: "Draft.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Draft.sss",
            sourceDocumentURL: nil,
            label: "Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )
        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Draft.sss",
            sourceDocumentURL: nil,
            label: "Autosave",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let history = store.historyEntries(for: sessionID)
        XCTAssertEqual(history.count, 2)
        let firstEntry = try XCTUnwrap(history.first)
        let sharedBaseURL = sessionBaseImageURL(from: firstEntry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedBaseURL.path))

        for entry in history {
            XCTAssertFalse(FileManager.default.fileExists(atPath: entry.packageURL.appendingPathComponent("base.png").path))
            XCTAssertEqual(sessionBaseImageURL(from: entry), sharedBaseURL)

            let restored = try store.restoreDocument(from: entry)
            XCTAssertEqual(restored.capture.image.width, document.capture.image.width)
            XCTAssertEqual(restored.capture.image.height, document.capture.image.height)
            XCTAssertEqual(samplePixel(in: restored.capture.image, topLeftX: 3, topLeftY: 4), samplePixel(in: document.capture.image, topLeftX: 3, topLeftY: 4))
        }

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testRecoveryDisplayPreviewCanRerenderFromSharedBaseImage() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(title: "Draft.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Draft.sss",
            sourceDocumentURL: nil,
            label: "Autosave",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let entry = try XCTUnwrap(store.historyEntries(for: sessionID).first)
        let mismatchedPreview = makeCoordinateImage(width: 96, height: 64)
        try ImageExporter.pngData(for: mismatchedPreview)
            .write(to: entry.packageURL.appendingPathComponent("preview.png"), options: .atomic)

        let displayPreview = try XCTUnwrap(SSSDocumentPackage.loadDisplayPreview(from: entry.packageURL))

        XCTAssertEqual(displayPreview.source, "rerendered-package")
        XCTAssertEqual(displayPreview.image.width, document.capture.image.width)
        XCTAssertEqual(displayPreview.image.height, document.capture.image.height)
        XCTAssertEqual(samplePixel(in: displayPreview.image, topLeftX: 20, topLeftY: 15), samplePixel(in: document.capture.image, topLeftX: 20, topLeftY: 15))

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testPendingRecoveryEntriesReturnRecentDraftsExcludingActiveSession() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let firstDocument = makeDocument()
        let secondDocument = makeDocument()
        let firstSessionID = try store.createSession(title: "First.sss", sourceDocumentURL: nil)
        let secondSessionID = try store.createSession(title: "Second.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: firstSessionID,
            title: "First.sss",
            sourceDocumentURL: nil,
            label: "Recent Snip",
            document: firstDocument,
            previewImage: firstDocument.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )
        try store.saveCheckpoint(
            sessionID: secondSessionID,
            title: "Second.sss",
            sourceDocumentURL: nil,
            label: "Recent Snip",
            document: secondDocument,
            previewImage: secondDocument.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let allEntries = store.pendingRecoveryEntries()
        XCTAssertEqual(Set(allEntries.map(\.sessionID)), Set([firstSessionID, secondSessionID]))

        let entriesExcludingFirst = store.pendingRecoveryEntries(excluding: firstSessionID)
        XCTAssertEqual(entriesExcludingFirst.map(\.sessionID), [secondSessionID])

        let limitedEntries = store.pendingRecoveryEntries(limit: 1)
        XCTAssertEqual(limitedEntries.count, 1)

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testDeleteHistoryEntryMovesCheckpointToRecycleBin() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(title: "Draft.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Draft.sss",
            sourceDocumentURL: nil,
            label: "First",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )
        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Draft.sss",
            sourceDocumentURL: nil,
            label: "Second",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let entry = try XCTUnwrap(store.historyEntries(for: sessionID).first)
        let packageURL = entry.packageURL

        try store.deleteHistoryEntry(entry)

        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
        XCTAssertEqual(store.historyEntries(for: sessionID).count, 1)
        XCTAssertEqual(store.recycledHistoryEntries().map(\.id), [entry.id])
        XCTAssertNotNil(store.recycledHistoryEntries().first?.deletedAt)

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testRestoreRecycledHistoryEntryReturnsCheckpointToHistory() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(title: "Draft.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Draft.sss",
            sourceDocumentURL: nil,
            label: "Autosave",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let entry = try XCTUnwrap(store.historyEntries(for: sessionID).first)
        try store.deleteHistoryEntry(entry)
        let recycledEntry = try XCTUnwrap(store.recycledHistoryEntries().first)

        try store.restoreRecycledHistoryEntry(recycledEntry)

        XCTAssertTrue(store.recycledHistoryEntries().isEmpty)
        XCTAssertEqual(store.historyEntries(for: sessionID).map(\.id), [entry.id])
        XCTAssertNotNil(store.latestPendingRecovery())

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testRecycleBinPresentsDeletedSnipOnceAndRestoresAllCheckpoints() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(title: "Draft.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Draft.sss",
            sourceDocumentURL: nil,
            label: "Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )
        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Draft.sss",
            sourceDocumentURL: nil,
            label: "Autosave",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        try store.deleteHistoryEntries(for: sessionID)

        let recycledEntries = store.recycledHistoryEntries()
        XCTAssertEqual(recycledEntries.count, 1)
        XCTAssertEqual(recycledEntries.first?.sessionID, sessionID)
        XCTAssertTrue(store.historyEntries(for: sessionID).isEmpty)

        try store.restoreRecycledHistoryEntry(try XCTUnwrap(recycledEntries.first))

        XCTAssertTrue(store.recycledHistoryEntries().isEmpty)
        XCTAssertEqual(store.historyEntries(for: sessionID).count, 2)

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testEmptyRecycleBinPermanentlyRemovesDeletedPackages() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(title: "Draft.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Draft.sss",
            sourceDocumentURL: nil,
            label: "Autosave",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let entry = try XCTUnwrap(store.historyEntries(for: sessionID).first)
        let packageURL = entry.packageURL
        try store.deleteHistoryEntry(entry)

        try store.emptyRecycleBin()

        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
        XCTAssertTrue(store.recycledHistoryEntries().isEmpty)

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testPruneRecycleBinPermanentlyRemovesExpiredDeletedPackages() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(title: "Draft.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Draft.sss",
            sourceDocumentURL: nil,
            label: "Autosave",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let entry = try XCTUnwrap(store.historyEntries(for: sessionID).first)
        let packageURL = entry.packageURL
        try store.deleteHistoryEntry(entry)

        XCTAssertFalse(try store.pruneRecycleBin(deletedBefore: .distantPast))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))

        XCTAssertTrue(try store.pruneRecycleBin(deletedBefore: .distantFuture))
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
        XCTAssertTrue(store.recycledHistoryEntries().isEmpty)

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testDeletePendingRecoverySessionsClearsRecentSnipsExceptExcludedSession() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let activeSessionID = try store.createSession(title: "Active.sss", sourceDocumentURL: nil)
        let recentSessionID = try store.createSession(title: "Recent.sss", sourceDocumentURL: nil)

        for sessionID in [activeSessionID, recentSessionID] {
            try store.saveCheckpoint(
                sessionID: sessionID,
                title: "Draft.sss",
                sourceDocumentURL: nil,
                label: "Recent Snip",
                document: document,
                previewImage: document.capture.image,
                pendingRecovery: true,
                hasUnsavedChanges: true
            )
        }

        try store.deletePendingRecoverySessions(excluding: activeSessionID)

        XCTAssertEqual(store.pendingRecoveryEntries().map(\.sessionID), [activeSessionID])
        XCTAssertTrue(store.historyEntries(for: recentSessionID).isEmpty)

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testPresentationStateCombinesHistoryCaptureAndRecentEntries() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let activeSessionID = try store.createSession(title: "Active.sss", sourceDocumentURL: nil)
        let recentSessionID = try store.createSession(title: "Recent.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: activeSessionID,
            title: "Active.sss",
            sourceDocumentURL: nil,
            label: "Autosave",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        try store.saveCheckpoint(
            sessionID: recentSessionID,
            title: "Recent.sss",
            sourceDocumentURL: nil,
            label: "Recent Snip",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let state = store.presentationState(
            currentSessionID: activeSessionID,
            captureHistoryLimit: 10,
            recentSnipLimit: 10,
            recycleBinLimit: 10
        )

        XCTAssertEqual(state.historyEntries.map(\ .sessionID), [activeSessionID])
        XCTAssertEqual(state.historyEntries.map(\ .label), ["Autosave"])
        XCTAssertEqual(state.recentSnipEntries.map(\ .sessionID), [recentSessionID])
        XCTAssertTrue(state.allCaptureHistoryEntries.contains(where: { $0.sessionID == activeSessionID }))
        XCTAssertTrue(state.allCaptureHistoryEntries.contains(where: { $0.sessionID == recentSessionID }))
        XCTAssertNotNil(state.pendingRecoverySession)

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testAllHistoryEntriesExposeSearchableMetadata() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let capture = makeCapturedScreenshot(sourceName: "Marketing Dashboard")
        let text = Annotation.makeText(at: CGPoint(x: 6, y: 8)).updatingText("Premium Flow")
        let callout = Annotation.makeCallout(at: CGPoint(x: 10, y: 12), number: 4).updatingText("Upload this")
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height),
            annotations: [text, callout],
            selectedAnnotationIDs: []
        )
        let document = makeEditableDocument(
            capture: capture,
            session: makeEditorDocumentSession(initialSnapshot: snapshot)
        )
        let sessionID = try store.createSession(title: "Searchable.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Searchable.sss",
            sourceDocumentURL: nil,
            label: "Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let entry = try XCTUnwrap(store.allHistoryEntries(limit: 1).first)
        XCTAssertTrue(entry.searchableText.contains("Marketing Dashboard"))
        XCTAssertTrue(entry.searchableText.contains("Premium Flow"))
        XCTAssertTrue(entry.searchableText.contains("Upload this"))
        XCTAssertGreaterThan(entry.packageSizeBytes ?? 0, 0)
        XCTAssertTrue(entry.matchesSearchQuery("premium flow"))
        XCTAssertTrue(entry.matchesSearchQuery("marketing dashboard"))

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testUpdateCheckpointSearchableTextUpdatesPersistedHistoryMetadata() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(title: "Draft.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Draft.sss",
            sourceDocumentURL: nil,
            label: "Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let originalEntry = try XCTUnwrap(store.historyEntries(for: sessionID).first)
        XCTAssertFalse(originalEntry.searchableText.contains("recognized overlay text"))

        try store.updateCheckpointSearchableText(
            sessionID: sessionID,
            checkpointID: originalEntry.id,
            searchableText: "recognized overlay text"
        )

        let updatedEntry = try XCTUnwrap(store.historyEntries(for: sessionID).first)
        XCTAssertEqual(updatedEntry.searchableText, "recognized overlay text")
        XCTAssertTrue(updatedEntry.matchesSearchQuery("overlay text"))

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testSearchHistoryEntriesUsesPersistedIndexAcrossStoreInstances() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let launchSessionID = try store.createSession(title: "Launch Notes.sss", sourceDocumentURL: nil)
        let supportSessionID = try store.createSession(title: "Support Flow.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: launchSessionID,
            title: "Launch Notes.sss",
            sourceDocumentURL: nil,
            label: "Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )
        let launchEntry = try XCTUnwrap(store.historyEntries(for: launchSessionID).first)
        try store.updateCheckpointSearchableText(
            sessionID: launchSessionID,
            checkpointID: launchEntry.id,
            searchableText: "customer onboarding premium dashboard"
        )

        try store.saveCheckpoint(
            sessionID: supportSessionID,
            title: "Support Flow.sss",
            sourceDocumentURL: nil,
            label: "Autosave",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let reopenedStore = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let matches = reopenedStore.searchHistoryEntries(matching: "premium dashboard")

        XCTAssertEqual(matches.map(\.sessionID), [launchSessionID])
        XCTAssertEqual(matches.first?.title, "Launch Notes.sss")

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testSearchIndexReflectsRecycleBinDeletesAndRestores() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(title: "Indexed Delete.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Indexed Delete.sss",
            sourceDocumentURL: nil,
            label: "Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )
        let entry = try XCTUnwrap(store.historyEntries(for: sessionID).first)

        XCTAssertEqual(store.searchHistoryEntries(matching: "indexed").map(\.id), [entry.id])

        try store.deleteHistoryEntry(entry)
        XCTAssertTrue(store.searchHistoryEntries(matching: "indexed").isEmpty)

        let recycledEntry = try XCTUnwrap(store.recycledHistoryEntries().first)
        try store.restoreRecycledHistoryEntry(recycledEntry)
        XCTAssertEqual(store.searchHistoryEntries(matching: "indexed").map(\.id), [entry.id])

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testArchiveSizeAndClearArchive() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(title: "Archive.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Archive.sss",
            sourceDocumentURL: nil,
            label: "Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        XCTAssertGreaterThan(try store.archiveSizeInBytes(), 0)

        try store.clearArchive()

        XCTAssertEqual(try store.archiveSizeInBytes(), 0)
        XCTAssertTrue(store.allHistoryEntries(limit: nil).isEmpty)

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testConcurrentCheckpointSavesKeepRecoveryStoreConsistent() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let sessionID = try store.createSession(title: "Concurrent.sss", sourceDocumentURL: nil)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    let document = makeEditableDocument(
                        capture: makeCapturedScreenshot(
                            image: makeCoordinateImage(width: 32, height: 24, pattern: .weighted(xMultiplier: 11, yMultiplier: 13, includeBlueSum: true)),
                            bounds: CGRect(x: 40, y: 50, width: 32, height: 24)
                        ),
                        session: makeEditorDocumentSession(
                            initialSnapshot: makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 32, height: 24)),
                            currentSnapshot: makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 32, height: 24))
                        )
                    )
                    try store.saveCheckpoint(
                        sessionID: sessionID,
                        title: "Concurrent.sss",
                        sourceDocumentURL: nil,
                        label: "Checkpoint \(index)",
                        document: document,
                        previewImage: document.capture.image,
                        pendingRecovery: true,
                        hasUnsavedChanges: true
                    )
                }
            }

            try await group.waitForAll()
        }

        let historyEntries = store.historyEntries(for: sessionID)
        XCTAssertEqual(historyEntries.count, 6)
        XCTAssertEqual(Set(historyEntries.map(\.label)).count, 6)
        XCTAssertEqual(store.allHistoryEntries(limit: nil).filter { $0.sessionID == sessionID }.count, 6)
    }

    func testPruneArchiveDeletesOldestCheckpointsFirst() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(title: "Archive.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Archive.sss",
            sourceDocumentURL: nil,
            label: "First",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let firstEntry = try XCTUnwrap(store.historyEntries(for: sessionID).first(where: { $0.label == "First" }))
        let firstPackageSize = try directorySize(at: firstEntry.packageURL)

        Thread.sleep(forTimeInterval: 1.1)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Archive.sss",
            sourceDocumentURL: nil,
            label: "Second",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let historyBeforePrune = store.historyEntries(for: sessionID)
        let secondEntry = try XCTUnwrap(historyBeforePrune.first(where: { $0.label == "Second" }))
        let totalArchiveSize = try store.archiveSizeInBytes()
        let secondPackageSize = try directorySize(at: secondEntry.packageURL)
        let sharedMetadataSize = max(totalArchiveSize - firstPackageSize - secondPackageSize, 0)

        let didPrune = try store.pruneArchiveIfNeeded(maximumSizeBytes: sharedMetadataSize + secondPackageSize)

        XCTAssertTrue(didPrune)
        XCTAssertFalse(store.historyEntries(for: sessionID).contains(where: { $0.label == "First" }))
        XCTAssertLessThanOrEqual(try store.archiveSizeInBytes(), sharedMetadataSize + secondPackageSize)

        try? FileManager.default.removeItem(at: rootURL)
    }

    private func makeDocument() -> EditableScreenshotDocument {
        let image = makeCoordinateImage(width: 32, height: 24, pattern: .weighted(xMultiplier: 11, yMultiplier: 13, includeBlueSum: true))
        let capture = makeCapturedScreenshot(
            image: image,
            bounds: CGRect(x: 40, y: 50, width: 32, height: 24)
        )
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 32, height: 24),
            annotations: [Annotation.makeRectangle(in: CGRect(x: 2, y: 2, width: 10, height: 8))],
            selectedAnnotationIDs: []
        )
        let session = makeEditorDocumentSession(initialSnapshot: snapshot)

        return makeEditableDocument(capture: capture, session: session)
    }

    private func directorySize(at url: URL) throws -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(resourceKeys))
        var totalSize: Int64 = 0

        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)

            guard values.isRegularFile == true else {
                continue
            }

            totalSize += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }

        return totalSize
    }

    private func sessionBaseImageURL(from entry: DocumentHistoryEntry) -> URL {
        entry.packageURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("base.png")
    }
}
