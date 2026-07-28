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
