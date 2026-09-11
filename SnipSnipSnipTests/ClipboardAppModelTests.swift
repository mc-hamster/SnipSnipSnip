import Combine
import CryptoKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class ClipboardAppModelTests: XCTestCase {
    private func makeClipboardStore(named name: String) -> ClipboardHistoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        return ClipboardHistoryStore(baseURL: url, keyProvider: ClipboardAppModelTestKeyProvider())
    }

    private func makeRecoveryStore(named name: String) -> DocumentRecoveryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        return DocumentRecoveryStore(baseURL: url)
    }

    private func removeClipboardStore(named name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }

    func testHistoryMutationsNotifyClipboardWindowModel() throws {
        let name = "ClipboardAppModelTests.historyObservation"
        let defaults = makeDefaults(named: name)
        let store = makeClipboardStore(named: name + ".store")
        defer {
            defaults.removePersistentDomain(forName: name)
            removeClipboardStore(named: name + ".store")
            removeClipboardStore(named: name + ".recovery")
        }
        let model = retainForTestLifetime(AppModel(
            defaults: defaults,
            recoveryStore: makeRecoveryStore(named: name + ".recovery"),
            clipboardHistoryStore: store,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ))
        var changes = 0
        let observation = model.clipboard.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        store.recordText("Clipboard notification test", sourceApp: nil, preferences: .default)
        XCTAssertGreaterThan(changes, 0)
        let item = try XCTUnwrap(model.clipboard.items.first)
        var previousCount = changes
        model.clipboard.togglePinnedClipboardItem(item)
        XCTAssertGreaterThan(changes, previousCount)
        XCTAssertTrue(model.clipboard.items[0].isPinned)

        previousCount = changes
        model.clipboard.addClipboardCollection("Review", for: item)
        XCTAssertGreaterThan(changes, previousCount)
        XCTAssertEqual(model.clipboard.items[0].collectionNames, ["Review"])

        previousCount = changes
        model.clipboard.deleteClipboardItem(item)
        XCTAssertGreaterThan(changes, previousCount)
        XCTAssertTrue(model.clipboard.items.isEmpty)
    }

    func testOpenClipboardSnipUsesStoredSessionOutsideCachedHistory() throws {
        let name = "ClipboardAppModelTests.openStoredSnip"
        let defaults = makeDefaults(named: name)
        let store = makeClipboardStore(named: name + ".store")
        let recovery = makeRecoveryStore(named: name + ".recovery")
        defer {
            defaults.removePersistentDomain(forName: name)
            removeClipboardStore(named: name + ".store")
            removeClipboardStore(named: name + ".recovery")
        }
        let model = retainForTestLifetime(AppModel(
            defaults: defaults, recoveryStore: recovery, clipboardHistoryStore: store,
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false
        ))
        let document = makeEditableDocument()
        let sessionID = try recovery.createSession(title: "Stored clipboard snip", sourceDocumentURL: nil)
        for label in ["Original", "Latest"] {
            try recovery.saveCheckpoint(
                sessionID: sessionID, title: "Stored clipboard snip", sourceDocumentURL: nil,
                label: label, document: document, previewImage: document.capture.image,
                pendingRecovery: false, hasUnsavedChanges: false
            )
        }
        store.recordSnip(
            pngData: try ImageExporter.pngData(for: document.capture.image), title: "Stored clipboard snip",
            searchableText: "", sessionID: sessionID, preferences: .default
        )
        let item = try XCTUnwrap(store.items.first)
        XCTAssertTrue(model.documents.allCaptureHistoryEntries.isEmpty)
        XCTAssertTrue(model.documents.recentSnipEntries.isEmpty)
        XCTAssertEqual(model.documents.latestHistoryEntry(for: sessionID)?.label, "Latest")

        model.clipboard.openClipboardSnip(item)
        XCTAssertNotNil(model.documents.editorController)
        XCTAssertEqual(model.documents.currentRecoverySessionID, sessionID)

        try recovery.deleteSession(sessionID)
        model.clipboard.openClipboardSnip(item)
        XCTAssertTrue(model.clipboard.actionMessage?.contains("no longer available") == true)
        XCTAssertEqual(store.items.first?.id, item.id)
    }

    func testClipboardHistoryIsOptInByDefault() {
        let defaults = makeDefaults(named: "ClipboardAppModelTests.optInDefault")
        defer { defaults.removePersistentDomain(forName: "ClipboardAppModelTests.optInDefault") }

        let preferences = ClipboardWorkflowModel.loadClipboardPreferences(from: defaults)

        XCTAssertFalse(preferences.isEnabled)
        XCTAssertTrue(preferences.recordsUncopiedSnips)
    }

    func testCompletedCaptureRecordsSnipWhenAutoCopyIsDisabled() async throws {
        let suiteName = "ClipboardAppModelTests.autoCopyDisabled"
        let storeName = "ClipboardAppModelTests.autoCopyDisabled.store"
        let defaults = makeDefaults(named: suiteName)
        defaults.set(false, forKey: AppModelPreferenceKey.autoCopyEnabled)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            removeClipboardStore(named: storeName)
        }

        let store = makeClipboardStore(named: storeName)
        let model = retainForTestLifetime(AppModel(
            defaults: defaults,
            recoveryStore: makeRecoveryStore(named: "ClipboardAppModelTests.autoCopyDisabled.recovery"),
            clipboardHistoryStore: store,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ))
        model.clipboard.updateClipboardHistoryEnabled(true)
        model.clipboard.updateRecordsUncopiedSnips(true)

        try model.capture.completeCapture(
            makeCapturedScreenshot(sourceName: "Timeline Source"),
            request: .region(CGRect(x: 0, y: 0, width: 64, height: 48)),
            isPrivateCapture: false
        )

        await waitUntil {
            model.clipboard.clipboardHistoryItems.count == 1
        }

        XCTAssertEqual(model.clipboard.clipboardHistoryItems.count, 1)
        guard case let .snip(_, _, title) = try XCTUnwrap(model.clipboard.clipboardHistoryItems.first).kind else {
            XCTFail("Expected a snip clipboard item")
            return
        }
        XCTAssertTrue(title.hasSuffix(".sss"))
        XCTAssertTrue(try XCTUnwrap(model.clipboard.clipboardHistoryItems.first).searchableText.contains("Timeline Source"))
    }

    func testPrivateCaptureDoesNotRecordClipboardSnip() async throws {
        let suiteName = "ClipboardAppModelTests.privateCapture"
        let storeName = "ClipboardAppModelTests.privateCapture.store"
        let defaults = makeDefaults(named: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            removeClipboardStore(named: storeName)
        }

        let store = makeClipboardStore(named: storeName)
        let model = retainForTestLifetime(AppModel(
            defaults: defaults,
            recoveryStore: makeRecoveryStore(named: "ClipboardAppModelTests.privateCapture.recovery"),
            clipboardHistoryStore: store,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ))
        model.clipboard.updateClipboardHistoryEnabled(true)
        model.clipboard.updateRecordsUncopiedSnips(true)

        try model.capture.completeCapture(
            makeCapturedScreenshot(),
            request: .fullscreen,
            isPrivateCapture: true
        )

        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(model.clipboard.clipboardHistoryItems.isEmpty)
    }

    func testUncopiedScreenshotTimelineCanBeDisabled() async throws {
        let suiteName = "ClipboardAppModelTests.uncopiedSnipsDisabled"
        let storeName = "ClipboardAppModelTests.uncopiedSnipsDisabled.store"
        let defaults = makeDefaults(named: suiteName)
        defaults.set(false, forKey: AppModelPreferenceKey.autoCopyEnabled)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            removeClipboardStore(named: storeName)
        }
        let model = retainForTestLifetime(AppModel(
            defaults: defaults,
            recoveryStore: makeRecoveryStore(named: "ClipboardAppModelTests.uncopiedSnipsDisabled.recovery"),
            clipboardHistoryStore: makeClipboardStore(named: storeName),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ))
        model.clipboard.pauseClipboardMonitoring(for: 60)
        model.clipboard.updateClipboardHistoryEnabled(true)
        model.clipboard.updateRecordsUncopiedSnips(false)

        try model.capture.completeCapture(
            makeCapturedScreenshot(sourceName: "Not copied"),
            request: .fullscreen,
            isPrivateCapture: false
        )
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(model.clipboard.clipboardHistoryItems.isEmpty)
    }

    func testClipboardSettingsPersistAndSanitize() {
        let suiteName = "ClipboardAppModelTests.persist"
        let storeName = "ClipboardAppModelTests.persist.store"
        let defaults = makeDefaults(named: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            removeClipboardStore(named: storeName)
        }

        let model = retainForTestLifetime(AppModel(
            defaults: defaults,
            recoveryStore: makeRecoveryStore(named: "ClipboardAppModelTests.persist.recovery"),
            clipboardHistoryStore: makeClipboardStore(named: storeName),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ))

        model.clipboard.updateClipboardHistoryEnabled(true)
        model.clipboard.updateClipboardMaxItemCount(2)
        model.clipboard.updateClipboardMaxStorageMB(1)
        model.clipboard.updateClipboardRetentionDays(30)
        model.clipboard.updateClipboardMaxItemSizeMB(10)
        model.clipboard.updateRecordsUncopiedSnips(false)
        model.clipboard.addIgnoredClipboardApp(match: "com.example.SecretApp")

        let reloaded = ClipboardWorkflowModel.loadClipboardPreferences(from: defaults)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertEqual(reloaded.maxItemCount, 10)
        XCTAssertEqual(reloaded.maxStorageMB, 25)
        XCTAssertEqual(reloaded.retentionDays, 30)
        XCTAssertEqual(reloaded.maxItemSizeMB, 10)
        XCTAssertFalse(reloaded.recordsUncopiedSnips)
        XCTAssertTrue(reloaded.ignoredApps.contains(where: { $0.match == "com.example.SecretApp" }))
        XCTAssertTrue(reloaded.ignoredApps.contains(where: { $0.match == "com.mseven.mSecure" }))
    }

    func testClipboardPreferenceSanitizationIsIdempotentForDuplicateDisplayNames() {
        let sanitized = ClipboardPreferences.default.sanitized()

        XCTAssertEqual(sanitized.sanitized(), sanitized)
        XCTAssertEqual(
            sanitized.ignoredApps.filter { $0.name == "mSecure" }.map(\.id),
            ["com.mseven.msecure", "msecure"]
        )
    }

    func testResetDefaultsRestoresUncopiedScreenshotRecording() {
        let suiteName = "ClipboardAppModelTests.resetUncopiedScreenshotDefault"
        let storeName = "ClipboardAppModelTests.resetUncopiedScreenshotDefault.store"
        let defaults = makeDefaults(named: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            removeClipboardStore(named: storeName)
        }

        let model = retainForTestLifetime(AppModel(
            defaults: defaults,
            recoveryStore: makeRecoveryStore(named: "ClipboardAppModelTests.resetUncopiedScreenshotDefault.recovery"),
            clipboardHistoryStore: makeClipboardStore(named: storeName),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        ))
        model.clipboard.updateRecordsUncopiedSnips(false)

        model.resetPreferencesToDefaults()

        XCTAssertTrue(model.clipboard.preferences.recordsUncopiedSnips)
    }
}

nonisolated private struct ClipboardAppModelTestKeyProvider: ClipboardEncryptionKeyProviding {
    func encryptionKey() throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 0x6b, count: 32))
    }
}
