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

    func testClipboardDenialStopsBackgroundReadsAndUpdatesMonitoringStatus() async throws {
        let name = "ClipboardAppModelTests.permission.\(UUID())"
        let defaults = makeDefaults(named: name)
        let store = makeClipboardStore(named: name + ".store")
        let pasteboard = TestPasteboardService()
        pasteboard.programmaticAccessPolicy = .denied
        let model = retainForTestLifetime(AppModel(
            defaults: defaults, environment: makePasteboardTestEnvironment(defaults: defaults, pasteboard: pasteboard),
            recoveryStore: makeRecoveryStore(named: name + ".recovery"), clipboardHistoryStore: store,
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false
        ))
        defer {
            model.clipboard.monitor.stop()
            defaults.removePersistentDomain(forName: name)
            removeClipboardStore(named: name + ".store")
            removeClipboardStore(named: name + ".recovery")
        }
        pasteboard.setString("Blocked clipboard value", forType: .string)
        let reads = pasteboard.contentReadCount
        model.clipboard.updateClipboardHistoryEnabled(true)
        XCTAssertEqual(model.clipboard.monitoringStatus, "Monitoring Blocked")
        XCTAssertTrue(model.clipboard.needsClipboardAccess)
        XCTAssertEqual(pasteboard.contentReadCount, reads)
        XCTAssertTrue(store.items.isEmpty)
        pasteboard.programmaticAccessPolicy = .ask
        model.clipboard.monitor.update(preferences: model.clipboard.preferences)
        XCTAssertEqual(model.clipboard.monitoringStatus, "Monitoring Needs Access")
        XCTAssertEqual(pasteboard.contentReadCount, reads)
        pasteboard.programmaticAccessPolicy = .allowed
        model.clipboard.monitor.update(preferences: model.clipboard.preferences)
        XCTAssertEqual(model.clipboard.monitoringStatus, "Monitoring")
        XCTAssertEqual(pasteboard.contentReadCount, reads, "Do not import content copied while access was blocked")
        pasteboard.setString("New allowed copy", forType: .string)
        model.clipboard.monitor.update(preferences: model.clipboard.preferences)
        for _ in 0..<100 where store.items.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.items.isEmpty)
        XCTAssertGreaterThan(pasteboard.contentReadCount, reads)
    }

    func testConcealedAndTransientCopiesDoNotReadClipboardSourceOrContent() {
        for typeName in ClipboardPasteboardReader.concealedAndTransientTypeNames.sorted() {
            let name = "ClipboardAppModelTests.excludedType.\(UUID())"
            let store = makeClipboardStore(named: name)
            let pasteboard = TestPasteboardService()
            pasteboard.programmaticAccessPolicy = .systemDefault
            let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, workspace: TestWorkspaceService())
            defer { monitor.stop(); removeClipboardStore(named: name) }
            pasteboard.setString("Excluded clipboard content", forType: .string)
            pasteboard.setString("com.apple.Notes", forType: .init(ClipboardPasteboardReader.sourceTypeName))
            pasteboard.addType(typeName)
            var preferences = ClipboardPreferences.default
            preferences.isEnabled = true

            monitor.start(preferences: preferences)

            XCTAssertEqual(pasteboard.contentReadCount, 0, "\(typeName) must be excluded before source or payload reads can prompt")
            XCTAssertTrue(store.items.isEmpty)
        }
    }

    func testIgnoredFrontmostAppCopyDoesNotReadClipboardContent() {
        let name = "ClipboardAppModelTests.ignoredFrontmostApp.\(UUID())"
        let store = makeClipboardStore(named: name)
        let pasteboard = TestPasteboardService()
        pasteboard.programmaticAccessPolicy = .systemDefault
        let workspace = TestWorkspaceService(frontmostApplication: WorkspaceRunningApplicationSnapshot(
            processIdentifier: 101, activationPolicy: .regular,
            bundleIdentifier: "com.bitwarden.desktop", localizedName: "Bitwarden", bundleURL: nil
        ))
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, workspace: workspace)
        defer { monitor.stop(); removeClipboardStore(named: name) }
        pasteboard.setString("Ignored clipboard content", forType: .string)
        var preferences = ClipboardPreferences.default
        preferences.isEnabled = true

        monitor.start(preferences: preferences)

        XCTAssertEqual(pasteboard.contentReadCount, 0, "Ignored sources must be excluded before payload reads can prompt")
        XCTAssertTrue(store.items.isEmpty)
    }

    func testIgnoredExplicitSourceCopyReadsOnlySourceMetadata() {
        let name = "ClipboardAppModelTests.ignoredExplicitSource.\(UUID())"
        let store = makeClipboardStore(named: name)
        let pasteboard = TestPasteboardService()
        let workspace = TestWorkspaceService(frontmostApplication: WorkspaceRunningApplicationSnapshot(
            processIdentifier: 101, activationPolicy: .regular,
            bundleIdentifier: "com.apple.Notes", localizedName: "Notes", bundleURL: nil
        ))
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, workspace: workspace)
        defer { monitor.stop(); removeClipboardStore(named: name) }
        pasteboard.setString("Ignored clipboard content", forType: .string)
        pasteboard.setString("com.bitwarden.desktop", forType: .init(ClipboardPasteboardReader.sourceTypeName))
        var preferences = ClipboardPreferences.default
        preferences.isEnabled = true

        monitor.start(preferences: preferences)

        XCTAssertEqual(pasteboard.contentReadCount, 1, "Only the source metadata is needed to exclude an explicit ignored source")
        XCTAssertTrue(store.items.isEmpty)
    }

    func testPermissionDeniedDuringClipboardReadStopsFurtherReadsImmediately() {
        let name = "ClipboardSecondPass.deniedDuringRead.\(UUID())"
        let store = makeClipboardStore(named: name)
        let pasteboard = TestPasteboardService()
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, workspace: TestWorkspaceService())
        defer { monitor.stop(); removeClipboardStore(named: name) }
        pasteboard.setString("Must not be captured after denial", forType: .string)
        pasteboard.onContentRead = { [weak pasteboard] in pasteboard?.programmaticAccessPolicy = .denied }
        var preferences = ClipboardPreferences.default
        preferences.isEnabled = true
        monitor.start(preferences: preferences)
        XCTAssertEqual(pasteboard.contentReadCount, 1, "A denial during the first read must stop subsequent protected reads")
        XCTAssertEqual(monitor.accessPolicy, .denied)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRevokingClipboardAccessDiscardsInFlightIngestion() async {
        for refreshBeforeCompletion in [true, false] {
            let name = "ClipboardSecondPass.deniedDuringIngestion.\(UUID())"
            let store = makeClipboardStore(named: name)
            let pasteboard = TestPasteboardService()
            let barrier = DeferredBoolVerifier()
            let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, workspace: TestWorkspaceService(), snapshotResolver: { captured in
                _ = await barrier.value()
                return .text(captured.text ?? "")
            })
            defer { monitor.stop(); removeClipboardStore(named: name) }
            pasteboard.setString("Pending clipboard content", forType: .string)
            var preferences = ClipboardPreferences.default
            preferences.isEnabled = true
            monitor.start(preferences: preferences)
            await barrier.waitForRequest()
            pasteboard.programmaticAccessPolicy = .denied
            if refreshBeforeCompletion { monitor.refreshAccessPolicy() }
            await barrier.resume(returning: true)
            for _ in 0..<100 { await Task.yield() }
            XCTAssertTrue(store.items.isEmpty, "Revocation must invalidate pending ingestion even before the next timer tick")
            XCTAssertEqual(monitor.accessPolicy, .denied)
        }
    }

    func testBackgroundReaderStopsMidBatchWithoutBlockingExplicitPaste() throws {
        let pasteboard = TestPasteboardService()
        pasteboard.setString("Explicit paste remains available", forType: .string)
        pasteboard.onContentRead = { [weak pasteboard] in pasteboard?.programmaticAccessPolicy = .denied }
        let captured = ClipboardPasteboardReader.capturePasteboardContent(pasteboard,
            sourceApp: nil, preferences: .default, background: true)
        XCTAssertEqual(pasteboard.contentReadCount, 1)
        XCTAssertNil(captured?.text)
        pasteboard.onContentRead = nil
        let explicit = ClipboardPasteboardReader.capturePasteboardContent(pasteboard, sourceApp: nil, preferences: .default)
        XCTAssertEqual(try XCTUnwrap(explicit).text, "Explicit paste remains available")
    }

    func testConsentDefaultDoesNotPerformABackgroundRead() {
        let name = "ClipboardAudit.default.\(UUID())"
        let store = makeClipboardStore(named: name)
        let pasteboard = TestPasteboardService()
        pasteboard.programmaticAccessPolicy = .systemDefault
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, workspace: TestWorkspaceService())
        defer { monitor.stop(); removeClipboardStore(named: name) }
        pasteboard.setString("No unsolicited consent request", forType: .string)
        var preferences = ClipboardPreferences.default
        preferences.isEnabled = true
        monitor.start(preferences: preferences)
        XCTAssertEqual(pasteboard.contentReadCount, 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testForegroundApprovalRetainsTheItemWhileAskBlocksFutureCopies() async {
        let name = "ClipboardAudit.once.\(UUID())"
        let store = makeClipboardStore(named: name)
        let pasteboard = TestPasteboardService()
        pasteboard.programmaticAccessPolicy = .systemDefault
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, workspace: TestWorkspaceService())
        defer { monitor.stop(); removeClipboardStore(named: name) }
        pasteboard.setString("Approved once", forType: .string)
        pasteboard.onContentRead = { [weak pasteboard] in pasteboard?.programmaticAccessPolicy = .ask }
        var preferences = ClipboardPreferences.default
        preferences.isEnabled = true
        monitor.start(preferences: preferences)
        let didRead = await monitor.readClipboardOnce(preferences: preferences)
        XCTAssertTrue(didRead)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(pasteboard.contentReadCount, 1)
        XCTAssertEqual(monitor.accessPolicy, .ask)
        pasteboard.setString("Next copy must wait", forType: .string)
        monitor.update(preferences: preferences)
        XCTAssertEqual(pasteboard.contentReadCount, 1)
        XCTAssertEqual(store.items.count, 1)
    }

    func testOnlyAnExplicitAllowPolicyPermitsBackgroundReads() {
        XCTAssertFalse(ClipboardAccessPolicy(.default).allowsBackgroundRead)
        XCTAssertFalse(ClipboardAccessPolicy(.ask).allowsBackgroundRead)
        XCTAssertFalse(ClipboardAccessPolicy(.alwaysDeny).allowsBackgroundRead)
        XCTAssertTrue(ClipboardAccessPolicy(.alwaysAllow).allowsBackgroundRead)
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

    func testCompletedCaptureRecordsSnipWithoutCopying() async throws {
        let suiteName = "ClipboardAppModelTests.uncopiedCapture"
        let storeName = "ClipboardAppModelTests.uncopiedCapture.store"
        let defaults = makeDefaults(named: suiteName)
        defaults.set(true, forKey: "appModel.autoCopyEnabled")
        let pasteboard = TestPasteboardService()
        pasteboard.setString("Existing clipboard", forType: .string)
        let before = pasteboard.changeCount
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            removeClipboardStore(named: storeName)
        }

        let store = makeClipboardStore(named: storeName)
        let model = retainForTestLifetime(AppModel(
            defaults: defaults,
            environment: makePasteboardTestEnvironment(defaults: defaults, pasteboard: pasteboard),
            recoveryStore: makeRecoveryStore(named: "ClipboardAppModelTests.uncopiedCapture.recovery"),
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
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing clipboard")
        guard case let .snip(_, _, title) = try XCTUnwrap(model.clipboard.clipboardHistoryItems.first).kind else {
            XCTFail("Expected a snip clipboard item")
            return
        }
        XCTAssertTrue(title.hasSuffix(".sss"))
        XCTAssertTrue(try XCTUnwrap(model.clipboard.clipboardHistoryItems.first).searchableText.contains("Timeline Source"))
    }

    func testCopyPresetRecordsSnipWhenUncopiedScreenshotHistoryIsDisabled() async throws {
        let name = "ClipboardAppModelTests.copyPreset.\(UUID())"
        let defaults = makeDefaults(named: name)
        let pasteboard = TestPasteboardService()
        let store = makeClipboardStore(named: name + ".store")
        defer {
            defaults.removePersistentDomain(forName: name)
            removeClipboardStore(named: name + ".store")
            removeClipboardStore(named: name + ".recovery")
        }
        let model = retainForTestLifetime(AppModel(
            defaults: defaults,
            environment: makePasteboardTestEnvironment(defaults: defaults, pasteboard: pasteboard),
            recoveryStore: makeRecoveryStore(named: name + ".recovery"),
            clipboardHistoryStore: store,
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false
        ))
        model.clipboard.updateClipboardHistoryEnabled(true)
        model.clipboard.updateRecordsUncopiedSnips(false)
        let preset = CapturePreset(name: "Copy preset", target: .fullscreen,
                                   options: CaptureRunOptions(), outcome: .copyToClipboard)
        model.capture.capturePresets = [preset]
        var context = CaptureCompletionContext.standalone
        context.workflowPreset = preset
        context.workflowPresetRunID = UUID()
        try model.capture.completeCapture(makeCapturedScreenshot(), request: .fullscreen,
                                        isPrivateCapture: false, shouldAttemptUIMapCapture: false,
                                        completionContext: context)
        await waitUntil { store.items.count == 1 && pasteboard.data(forType: .png) != nil }
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNotNil(pasteboard.data(forType: .png))
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
