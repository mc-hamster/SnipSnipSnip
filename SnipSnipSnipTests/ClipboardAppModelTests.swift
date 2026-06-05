import XCTest
@testable import SnipSnipSnip

@MainActor
final class ClipboardAppModelTests: XCTestCase {
    private func makeDefaults(named suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeClipboardStore(named name: String) -> ClipboardHistoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        return ClipboardHistoryStore(baseURL: url)
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

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        while !condition() && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
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

        try model.completeCapture(
            makeCapturedScreenshot(sourceName: "Timeline Source"),
            request: .region(CGRect(x: 0, y: 0, width: 64, height: 48)),
            isPrivateCapture: false
        )

        await waitUntil {
            model.clipboardHistoryItems.count == 1
        }

        XCTAssertEqual(model.clipboardHistoryItems.count, 1)
        guard case let .snip(_, _, title) = try XCTUnwrap(model.clipboardHistoryItems.first).kind else {
            XCTFail("Expected a snip clipboard item")
            return
        }
        XCTAssertTrue(title.hasSuffix(".sss"))
        XCTAssertTrue(try XCTUnwrap(model.clipboardHistoryItems.first).searchableText.contains("Timeline Source"))
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

        try model.completeCapture(
            makeCapturedScreenshot(),
            request: .fullscreen,
            isPrivateCapture: true
        )

        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(model.clipboardHistoryItems.isEmpty)
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

        model.updateClipboardHistoryEnabled(false)
        model.updateClipboardMaxItemCount(2)
        model.updateClipboardMaxStorageMB(1)
        model.addIgnoredClipboardApp(match: "com.example.SecretApp")

        let reloaded = AppModel.loadClipboardPreferences(from: defaults)
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertEqual(reloaded.maxItemCount, 10)
        XCTAssertEqual(reloaded.maxStorageMB, 25)
        XCTAssertTrue(reloaded.ignoredApps.contains(where: { $0.match == "com.example.SecretApp" }))
        XCTAssertTrue(reloaded.ignoredApps.contains(where: { $0.match == "com.mseven.mSecure" }))
    }
}
