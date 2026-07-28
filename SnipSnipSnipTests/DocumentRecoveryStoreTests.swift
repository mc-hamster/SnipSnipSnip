import CoreGraphics
import Dispatch
import Foundation
import ImageIO
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
        XCTAssertEqual(
            editorSessionRemovingComposition(from: restored.session),
            document.session
        )
        let restoredComposition = try XCTUnwrap(
            restored.session.currentSnapshot.composition
        )
        XCTAssertFalse(restoredComposition.isActivated)
        XCTAssertEqual(restoredComposition.items.count, 1)
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

        let displayPreview = try XCTUnwrap(
            SSSDocumentPackage.loadDisplayPreview(
                from: entry.packageURL,
                allowsExternalRecoveryBase: true
            )
        )

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

        let pruneResult = try store.pruneArchiveAndMeasure(
            maximumSizeBytes: sharedMetadataSize + secondPackageSize
        )

        XCTAssertTrue(pruneResult.didPrune)
        XCTAssertFalse(store.historyEntries(for: sessionID).contains(where: { $0.label == "First" }))
        XCTAssertLessThanOrEqual(pruneResult.archiveSizeBytes, sharedMetadataSize + secondPackageSize)
        XCTAssertEqual(pruneResult.archiveSizeBytes, try store.archiveSizeInBytes())

        try? FileManager.default.removeItem(at: rootURL)
    }

    func testCompositionCheckpointsShareAppendOnlyCaptureAssetsAcrossSession() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let assetID = UUID()
        let image = makeCoordinateImage(width: 28, height: 20)
        let document = try makeCompositionDocument(
            assetImages: [assetID: image],
            initialAssetIDs: [assetID],
            currentAssetIDs: [assetID]
        )
        let sessionID = try store.createSession(
            title: "Composition.sss",
            sourceDocumentURL: nil
        )

        for label in ["Capture", "Autosave"] {
            try store.saveCheckpoint(
                sessionID: sessionID,
                title: "Composition.sss",
                sourceDocumentURL: nil,
                label: label,
                document: document,
                previewImage: document.capture.image,
                pendingRecovery: true,
                hasUnsavedChanges: true
            )
        }

        let entries = store.historyEntries(for: sessionID)
        XCTAssertEqual(entries.count, 2)
        let sharedAssetsURL = sessionCompositionAssetsURL(from: try XCTUnwrap(entries.first))
        let sharedAssets = try FileManager.default.contentsOfDirectory(
            at: sharedAssetsURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(sharedAssets.map(\.lastPathComponent), ["\(assetID.uuidString).png"])

        for entry in entries {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: entry.packageURL
                        .appendingPathComponent("assets/captures", isDirectory: true)
                        .path
                )
            )
            let restored = try store.restoreDocument(from: entry)
            XCTAssertEqual(restored.session, document.session)
            XCTAssertEqual(
                restored.compositionStoredAssets.map(\.descriptor.id),
                [assetID]
            )
        }
    }

    func testRecoveryRetainsAssetsReferencedOnlyByInitialUndoAndRedoSnapshots() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let assetIDs = (0..<4).map { _ in UUID() }
        let assetImages = Dictionary(uniqueKeysWithValues: assetIDs.enumerated().map {
            (
                $0.element,
                makeCoordinateImage(
                    width: 24 + $0.offset,
                    height: 18 + $0.offset
                )
            )
        })
        let document = try makeCompositionDocument(
            assetImages: assetImages,
            initialAssetIDs: [assetIDs[0]],
            currentAssetIDs: [assetIDs[1]],
            undoAssetIDs: [[assetIDs[2]]],
            redoAssetIDs: [[assetIDs[3]]]
        )
        let sessionID = try store.createSession(
            title: "History Assets.sss",
            sourceDocumentURL: nil
        )

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "History Assets.sss",
            sourceDocumentURL: nil,
            label: "Autosave",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let entry = try XCTUnwrap(store.historyEntries(for: sessionID).first)
        let storedNames = Set(
            try FileManager.default.contentsOfDirectory(
                at: sessionCompositionAssetsURL(from: entry),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )
        XCTAssertEqual(
            storedNames,
            Set(assetIDs.map { "\($0.uuidString).png" })
        )

        let restored = try store.restoreDocument(from: entry)
        XCTAssertEqual(restored.session, document.session)
        XCTAssertEqual(
            Set(restored.compositionStoredAssets.map(\.descriptor.id)),
            Set(assetIDs)
        )
    }

    func testSoftDeleteRetainsSharedAssetsAndPermanentDeletePrunesOnlyUnreferenced() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let firstID = UUID()
        let secondID = UUID()
        let first = try makeCompositionDocument(
            assetImages: [firstID: makeCoordinateImage(width: 20, height: 16)],
            initialAssetIDs: [firstID],
            currentAssetIDs: [firstID]
        )
        let second = try makeCompositionDocument(
            assetImages: [secondID: makeCoordinateImage(width: 22, height: 18)],
            initialAssetIDs: [secondID],
            currentAssetIDs: [secondID]
        )
        let sessionID = try store.createSession(title: "Prune.sss", sourceDocumentURL: nil)

        for (label, document) in [("First", first), ("Second", second)] {
            try store.saveCheckpoint(
                sessionID: sessionID,
                title: "Prune.sss",
                sourceDocumentURL: nil,
                label: label,
                document: document,
                previewImage: document.capture.image,
                pendingRecovery: true,
                hasUnsavedChanges: true
            )
        }

        let firstEntry = try XCTUnwrap(
            store.historyEntries(for: sessionID).first { $0.label == "First" }
        )
        let assetsURL = sessionCompositionAssetsURL(from: firstEntry)
        let firstAssetURL = assetsURL.appendingPathComponent("\(firstID.uuidString).png")
        let secondAssetURL = assetsURL.appendingPathComponent("\(secondID.uuidString).png")

        try store.deleteHistoryEntry(firstEntry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAssetURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondAssetURL.path))

        let recycled = try XCTUnwrap(
            store.recycledHistoryEntries().first { $0.id == firstEntry.id }
        )
        try store.permanentlyDeleteHistoryEntry(recycled)

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstAssetURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondAssetURL.path))
        XCTAssertEqual(
            try store.restoreDocument(
                from: XCTUnwrap(
                    store.historyEntries(for: sessionID).first {
                        $0.label == "Second"
                    }
                )
            ).compositionStoredAssets.map(\.descriptor.id),
            [secondID]
        )
    }

    func testImmutableAssetConflictLeavesPriorCheckpointAndPixelsReadable() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let assetID = UUID()
        let originalImage = makeCoordinateImage(width: 24, height: 18)
        let conflictingImage = makeSolidImage(
            width: 24,
            height: 18,
            color: PixelSample(red: 220, green: 20, blue: 40, alpha: 255)
        )
        let original = try makeCompositionDocument(
            assetImages: [assetID: originalImage],
            initialAssetIDs: [assetID],
            currentAssetIDs: [assetID]
        )
        let conflicting = try makeCompositionDocument(
            assetImages: [assetID: conflictingImage],
            initialAssetIDs: [assetID],
            currentAssetIDs: [assetID]
        )
        let sessionID = try store.createSession(title: "Atomic.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Atomic.sss",
            sourceDocumentURL: nil,
            label: "Original",
            document: original,
            previewImage: original.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        XCTAssertThrowsError(
            try store.saveCheckpoint(
                sessionID: sessionID,
                title: "Atomic.sss",
                sourceDocumentURL: nil,
                label: "Conflicting",
                document: conflicting,
                previewImage: conflicting.capture.image,
                pendingRecovery: true,
                hasUnsavedChanges: true
            )
        ) {
            guard case SSSDocumentError.compositionAssetConflict(let conflictingID) = $0,
                  conflictingID == assetID else {
                return XCTFail("Expected immutable asset conflict, got \($0)")
            }
        }

        let entries = store.historyEntries(for: sessionID)
        XCTAssertEqual(entries.map(\.label), ["Original"])
        let restored = try store.restoreDocument(from: XCTUnwrap(entries.first))
        let stored = try XCTUnwrap(restored.compositionStoredAssets.first)
        let decoded = try XCTUnwrap(
            CGImageSourceCreateWithData(try XCTUnwrap(stored.encodedPNG) as CFData, nil)
        )
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(
            samplePixel(in: image, topLeftX: 5, topLeftY: 6),
            samplePixel(in: originalImage, topLeftX: 5, topLeftY: 6)
        )
    }

    func testPrivateCompositionCannotWriteRecoveryPixelsAndHidesOlderSession() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let publicID = UUID()
        let privateID = UUID()
        let publicDocument = try makeCompositionDocument(
            assetImages: [publicID: makeCoordinateImage(width: 20, height: 14)],
            initialAssetIDs: [publicID],
            currentAssetIDs: [publicID]
        )
        let privateDocument = try makeCompositionDocument(
            assetImages: [privateID: makeCoordinateImage(width: 22, height: 16)],
            initialAssetIDs: [privateID],
            currentAssetIDs: [privateID],
            privateAssetIDs: [privateID]
        )
        let sessionID = try store.createSession(
            title: "Private Taint.sss",
            sourceDocumentURL: nil
        )

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Private Taint.sss",
            sourceDocumentURL: nil,
            label: "Before Private Capture",
            document: publicDocument,
            previewImage: publicDocument.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )
        let publicEntry = try XCTUnwrap(
            store.historyEntries(for: sessionID).first
        )
        let assetsURL = sessionCompositionAssetsURL(from: publicEntry)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Private Taint.sss",
            sourceDocumentURL: nil,
            label: "Must Not Persist",
            document: privateDocument,
            previewImage: privateDocument.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        XCTAssertTrue(store.historyEntries(for: sessionID).isEmpty)
        XCTAssertNil(store.latestPendingRecovery())
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: assetsURL
                    .appendingPathComponent("\(publicID.uuidString).png")
                    .path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: assetsURL
                    .appendingPathComponent("\(privateID.uuidString).png")
                    .path
            )
        )
        XCTAssertEqual(
            try store.restoreDocument(from: publicEntry)
                .compositionStoredAssets.map(\.descriptor.id),
            [publicID],
            "Pre-private checkpoints may remain readable by their already-held internal entry."
        )
        let state = store.presentationState(
            currentSessionID: sessionID,
            captureHistoryLimit: 20,
            recentSnipLimit: 20,
            recycleBinLimit: 20
        )
        XCTAssertTrue(state.historyEntries.isEmpty)
        XCTAssertTrue(state.allCaptureHistoryEntries.isEmpty)
        XCTAssertTrue(state.recentSnipEntries.isEmpty)
        XCTAssertTrue(state.recycleBinEntries.isEmpty)
        XCTAssertNil(state.pendingRecoverySession)
    }

    func testPrivacyExclusionWinsAgainstCheckpointAlreadyEncoding() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let seedStore = retainForTestLifetime(
            DocumentRecoveryStore(baseURL: rootURL)
        )
        let document = makeDocument()
        let sessionID = try seedStore.createSession(
            title: "Racing Private Taint.sss",
            sourceDocumentURL: nil
        )
        try seedStore.saveCheckpoint(
            sessionID: sessionID,
            title: "Racing Private Taint.sss",
            sourceDocumentURL: nil,
            label: "Before Private Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let packageDidWrite = DispatchSemaphore(value: 0)
        let allowCommitCheck = DispatchSemaphore(value: 0)
        let racingStore = retainForTestLifetime(
            DocumentRecoveryStore(
                baseURL: rootURL,
                checkpointPackageDidWrite: { _ in
                    packageDidWrite.signal()
                    _ = allowCommitCheck.wait(timeout: .now() + 10)
                }
            )
        )
        let writer = Task.detached(priority: .userInitiated) {
            let image = makeCoordinateImage(width: 32, height: 24)
            let capture = makeCapturedScreenshot(image: image)
            let snapshot = makeEditorSnapshot(
                cropRect: CGRect(x: 0, y: 0, width: 32, height: 24)
            )
            let delayedDocument = makeEditableDocument(
                capture: capture,
                session: makeEditorDocumentSession(
                    initialSnapshot: snapshot,
                    currentSnapshot: snapshot
                )
            )
            try racingStore.saveCheckpoint(
                sessionID: sessionID,
                title: "Racing Private Taint.sss",
                sourceDocumentURL: nil,
                label: "Delayed Autosave",
                document: delayedDocument,
                previewImage: delayedDocument.capture.image,
                pendingRecovery: true,
                hasUnsavedChanges: true
            )
        }

        XCTAssertEqual(
            packageDidWrite.wait(timeout: .now() + 10),
            .success,
            "The test writer never reached the precommit boundary."
        )
        racingStore.registerPrivacyExclusion(for: sessionID)
        allowCommitCheck.signal()
        try await writer.value
        try racingStore.excludeSessionFromPresentation(sessionID)

        let checkpointsURL = rootURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("checkpoints", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: checkpointsURL,
                includingPropertiesForKeys: nil
            ).count,
            1,
            "The checkpoint encoded before privacy taint must be discarded before manifest commit."
        )
        XCTAssertTrue(racingStore.historyEntries(for: sessionID).isEmpty)
        XCTAssertTrue(racingStore.pendingRecoveryEntries().isEmpty)
        XCTAssertNil(racingStore.latestPendingRecovery())

        let reopenedStore = retainForTestLifetime(
            DocumentRecoveryStore(baseURL: rootURL)
        )
        XCTAssertTrue(reopenedStore.historyEntries(for: sessionID).isEmpty)
        try reopenedStore.saveCheckpoint(
            sessionID: sessionID,
            title: "Racing Private Taint.sss",
            sourceDocumentURL: nil,
            label: "Later Autosave",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: checkpointsURL,
                includingPropertiesForKeys: nil
            ).count,
            1,
            "A durable exclusion must reject writers created after relaunch."
        )
    }

    func testPrivacyExclusionCleansCheckpointThatRacesImmediatelyAfterManifestCommit() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let seedStore = retainForTestLifetime(
            DocumentRecoveryStore(baseURL: rootURL)
        )
        let document = makeDocument()
        let sessionID = try seedStore.createSession(
            title: "Postcommit Private Taint.sss",
            sourceDocumentURL: nil
        )
        try seedStore.saveCheckpoint(
            sessionID: sessionID,
            title: "Postcommit Private Taint.sss",
            sourceDocumentURL: nil,
            label: "Before Private Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let sessionDidCommit = DispatchSemaphore(value: 0)
        let allowPostcommitCheck = DispatchSemaphore(value: 0)
        let racingStore = retainForTestLifetime(
            DocumentRecoveryStore(
                baseURL: rootURL,
                checkpointSessionDidCommit: { _ in
                    sessionDidCommit.signal()
                    _ = allowPostcommitCheck.wait(timeout: .now() + 10)
                }
            )
        )
        let writer = Task.detached(priority: .userInitiated) {
            let image = makeCoordinateImage(width: 32, height: 24)
            let capture = makeCapturedScreenshot(image: image)
            let snapshot = makeEditorSnapshot(
                cropRect: CGRect(x: 0, y: 0, width: 32, height: 24)
            )
            let delayedDocument = makeEditableDocument(
                capture: capture,
                session: makeEditorDocumentSession(
                    initialSnapshot: snapshot,
                    currentSnapshot: snapshot
                )
            )
            try racingStore.saveCheckpoint(
                sessionID: sessionID,
                title: "Postcommit Private Taint.sss",
                sourceDocumentURL: nil,
                label: "Racing Autosave",
                document: delayedDocument,
                previewImage: delayedDocument.capture.image,
                pendingRecovery: true,
                hasUnsavedChanges: true
            )
        }

        XCTAssertEqual(
            sessionDidCommit.wait(timeout: .now() + 10),
            .success,
            "The test writer never reached the postcommit boundary."
        )
        racingStore.registerPrivacyExclusion(for: sessionID)
        allowPostcommitCheck.signal()
        try await writer.value
        try racingStore.excludeSessionFromPresentation(sessionID)

        let checkpointsURL = rootURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("checkpoints", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: checkpointsURL,
                includingPropertiesForKeys: nil
            ).count,
            1,
            "The postcommit race must remove the newly published checkpoint package."
        )
        XCTAssertTrue(racingStore.historyEntries(for: sessionID).isEmpty)
        XCTAssertTrue(racingStore.pendingRecoveryEntries().isEmpty)
        XCTAssertNil(racingStore.latestPendingRecovery())
    }

    func testPrivacyTombstoneFiltersEveryHistorySurfaceWithStaleSearchIndex() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(
            title: "Never Index Private.sss",
            sourceDocumentURL: nil
        )
        for label in ["Visible", "Recycle Me"] {
            try store.saveCheckpoint(
                sessionID: sessionID,
                title: "Never Index Private.sss",
                sourceDocumentURL: nil,
                label: label,
                document: document,
                previewImage: document.capture.image,
                pendingRecovery: true,
                hasUnsavedChanges: true
            )
        }
        let recycledEntry = try XCTUnwrap(
            store.historyEntries(for: sessionID).first {
                $0.label == "Recycle Me"
            }
        )
        try store.deleteHistoryEntry(recycledEntry)
        let searchIndexURL = rootURL.appendingPathComponent("search-index.json")
        let staleSearchIndex = try Data(contentsOf: searchIndexURL)

        try store.excludeSessionFromPresentation(sessionID)
        try staleSearchIndex.write(to: searchIndexURL, options: .atomic)

        let reopenedStore = retainForTestLifetime(
            DocumentRecoveryStore(baseURL: rootURL)
        )
        XCTAssertTrue(reopenedStore.historyEntries(for: sessionID).isEmpty)
        XCTAssertTrue(reopenedStore.pendingRecoveryEntries().isEmpty)
        XCTAssertNil(reopenedStore.latestPendingRecovery())
        XCTAssertTrue(reopenedStore.allHistoryEntries().isEmpty)
        XCTAssertTrue(
            reopenedStore.searchHistoryEntries(
                matching: "Never Index Private"
            ).isEmpty
        )
        XCTAssertTrue(reopenedStore.recycledHistoryEntries().isEmpty)
        XCTAssertTrue(reopenedStore.incompatibleHistoryEntries().isEmpty)

        let state = reopenedStore.presentationState(
            currentSessionID: sessionID,
            captureHistoryLimit: 20,
            recentSnipLimit: 20,
            recycleBinLimit: 20
        )
        XCTAssertTrue(state.historyEntries.isEmpty)
        XCTAssertTrue(state.allCaptureHistoryEntries.isEmpty)
        XCTAssertTrue(state.recentSnipEntries.isEmpty)
        XCTAssertTrue(state.recycleBinEntries.isEmpty)
        XCTAssertNil(state.pendingRecoverySession)
    }

    func testPrivacyExclusionFallsBackToSessionRecordWhenTombstoneWriteFails() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(
            title: "Low Disk Private.sss",
            sourceDocumentURL: nil
        )
        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Low Disk Private.sss",
            sourceDocumentURL: nil,
            label: "Before Private Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let exclusionDirectoryURL = rootURL.appendingPathComponent(
            DocumentRecoveryStore.privacyExclusionsDirectoryName
        )
        try Data("blocks-directory-creation".utf8).write(
            to: exclusionDirectoryURL,
            options: .atomic
        )

        try store.excludeSessionFromPresentation(sessionID)

        let reopenedStore = retainForTestLifetime(
            DocumentRecoveryStore(baseURL: rootURL)
        )
        XCTAssertTrue(reopenedStore.historyEntries(for: sessionID).isEmpty)
        XCTAssertTrue(reopenedStore.allHistoryEntries().isEmpty)
        XCTAssertNil(reopenedStore.latestPendingRecovery())

        try reopenedStore.saveCheckpoint(
            sessionID: sessionID,
            title: "Low Disk Private.sss",
            sourceDocumentURL: nil,
            label: "Must Stay Excluded",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )
        XCTAssertTrue(reopenedStore.historyEntries(for: sessionID).isEmpty)

        try FileManager.default.removeItem(at: exclusionDirectoryURL)
        XCTAssertTrue(reopenedStore.allHistoryEntries().isEmpty)
        let tombstoneURL = rootURL
            .appendingPathComponent(
                DocumentRecoveryStore.privacyExclusionsDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension("excluded")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tombstoneURL.path),
            "A session-record fallback must keep retrying the standalone tombstone after storage recovers."
        )
    }

    func testFailedPrivacyExclusionStaysFailClosedAndRetriesAfterStorageRecovers() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeDocument()
        let sessionID = try store.createSession(
            title: "Retry Private Exclusion.sss",
            sourceDocumentURL: nil
        )
        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Retry Private Exclusion.sss",
            sourceDocumentURL: nil,
            label: "Before Private Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let sessionMetadataURL = rootURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("session.json")
        let originalSessionMetadata = try Data(contentsOf: sessionMetadataURL)
        try FileManager.default.removeItem(at: sessionMetadataURL)
        try FileManager.default.createDirectory(
            at: sessionMetadataURL,
            withIntermediateDirectories: false
        )

        let exclusionDirectoryURL = rootURL.appendingPathComponent(
            DocumentRecoveryStore.privacyExclusionsDirectoryName
        )
        try Data("simulated-no-space".utf8).write(
            to: exclusionDirectoryURL,
            options: .atomic
        )

        XCTAssertThrowsError(
            try store.excludeSessionFromPresentation(sessionID)
        )
        XCTAssertTrue(store.allHistoryEntries().isEmpty)
        XCTAssertTrue(
            store.searchHistoryEntries(matching: "Retry Private").isEmpty
        )
        XCTAssertNil(store.latestPendingRecovery())

        let checkpointsURL = sessionMetadataURL
            .deletingLastPathComponent()
            .appendingPathComponent("checkpoints", isDirectory: true)
        let checkpointCount = try FileManager.default.contentsOfDirectory(
            at: checkpointsURL,
            includingPropertiesForKeys: nil
        ).count
        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Retry Private Exclusion.sss",
            sourceDocumentURL: nil,
            label: "Must Not Commit During Failure",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: checkpointsURL,
                includingPropertiesForKeys: nil
            ).count,
            checkpointCount
        )

        try FileManager.default.removeItem(at: exclusionDirectoryURL)
        try FileManager.default.removeItem(at: sessionMetadataURL)
        try originalSessionMetadata.write(
            to: sessionMetadataURL,
            options: .atomic
        )

        // Any later store interaction retries pending durable exclusions.
        XCTAssertTrue(store.allHistoryEntries().isEmpty)
        let tombstoneURL = rootURL
            .appendingPathComponent(
                DocumentRecoveryStore.privacyExclusionsDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension("excluded")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstoneURL.path))

        let reopenedStore = retainForTestLifetime(
            DocumentRecoveryStore(baseURL: rootURL)
        )
        XCTAssertTrue(reopenedStore.historyEntries(for: sessionID).isEmpty)
        XCTAssertTrue(reopenedStore.pendingRecoveryEntries().isEmpty)
        XCTAssertNil(reopenedStore.latestPendingRecovery())
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

    private func makeCompositionDocument(
        assetImages: [UUID: CGImage],
        initialAssetIDs: [UUID],
        currentAssetIDs: [UUID],
        undoAssetIDs: [[UUID]] = [],
        redoAssetIDs: [[UUID]] = [],
        privateAssetIDs: Set<UUID> = []
    ) throws -> EditableScreenshotDocument {
        let rootImage = makeCoordinateImage(width: 32, height: 24)
        func snapshot(assetIDs: [UUID]) -> EditorSnapshot {
            var snapshot = makeEditorSnapshot(
                cropRect: CGRect(x: 0, y: 0, width: 32, height: 24)
            )
            snapshot.composition = CompositionSnapshot(
                items: assetIDs.map {
                    CompositionItem(assetID: $0, title: $0.uuidString)
                }
            )
            return snapshot
        }

        let session = makeEditorDocumentSession(
            initialSnapshot: snapshot(assetIDs: initialAssetIDs),
            currentSnapshot: snapshot(assetIDs: currentAssetIDs),
            undoStack: undoAssetIDs.map(snapshot),
            redoStack: redoAssetIDs.map(snapshot)
        )
        let assets = try assetImages.map { id, image in
            CompositionStoredAsset(
                descriptor: CompositionAssetDescriptor(
                    id: id,
                    pixelWidth: image.width,
                    pixelHeight: image.height,
                    sourceName: "Recovery \(id.uuidString)",
                    captureKind: CaptureKind.region.rawValue,
                    sourceRect: CGRect(
                        origin: .zero,
                        size: CGSize(width: image.width, height: image.height)
                    ),
                    isPrivate: privateAssetIDs.contains(id)
                ),
                encodedPNG: try ImageExporter.pngData(for: image)
            )
        }
        return EditableScreenshotDocument(
            capture: makeCapturedScreenshot(image: rootImage),
            session: session,
            compositionStoredAssets: assets
        )
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

    private func sessionCompositionAssetsURL(
        from entry: DocumentHistoryEntry
    ) -> URL {
        entry.packageURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                SSSDocumentPackage.recoveryCompositionAssetsDirectoryName,
                isDirectory: true
            )
    }
}
