import XCTest
@testable import SnipSnipSnip

@MainActor
final class ArchiveFolderAccessTests: XCTestCase {
    private struct Failure: Error {}

    func testFailedBookmarkSavePreservesThePreviousLocation() throws {
        let name = "ArchiveFolderAccessTests.save.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let oldURL = URL(fileURLWithPath: "/tmp/previous-history")
        defaults.set(oldURL.path, forKey: AppModelPreferenceKey.archiveLocationPath)
        defaults.set(Data("old-bookmark".utf8), forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
        let client = ArchiveBookmarkClient(create: { _ in throw Failure() },
            resolve: { _ in ArchiveBookmarkResolution(url: oldURL, isStale: false) },
            startAccess: { _ in true }, stopAccess: { _ in })
        let store = ArchivePreferenceStore(storage: defaults, bookmarks: client, requiresSecurityScope: true)
        XCTAssertThrowsError(try store.saveLocationURL(URL(fileURLWithPath: "/tmp/new-history")))
        XCTAssertEqual(defaults.string(forKey: AppModelPreferenceKey.archiveLocationPath), oldURL.path)
        XCTAssertEqual(defaults.data(forKey: AppModelPreferenceKey.archiveLocationBookmarkData), Data("old-bookmark".utf8))
    }

    func testBrokenBookmarkDoesNotFallBackToItsPlainPath() {
        let name = "ArchiveFolderAccessTests.resolve.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/tmp/history", forKey: AppModelPreferenceKey.archiveLocationPath)
        defaults.set(Data("broken".utf8), forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
        let client = ArchiveBookmarkClient(create: { _ in Data() }, resolve: { _ in throw Failure() },
            startAccess: { _ in XCTFail("A failed bookmark must not acquire access through a plain path"); return false },
            stopAccess: { _ in })
        let store = ArchivePreferenceStore(storage: defaults, bookmarks: client, requiresSecurityScope: true)
        let location = PreparedArchiveLocation(preferences: store)
        XCTAssertNil(location.usableURL)
        XCTAssertEqual(location.requestedURL?.path, "/tmp/history")
        XCTAssertEqual(location.error, .bookmarkUnavailable)
        XCTAssertNil(store.loadLocationURL())
    }

    func testStaleBookmarkIsRenewedUsingItsResolvedLocation() {
        let name = "ArchiveFolderAccessTests.stale.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/tmp/old-history", forKey: AppModelPreferenceKey.archiveLocationPath)
        defaults.set(Data("stale".utf8), forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
        let movedURL = URL(fileURLWithPath: "/tmp/moved-history")
        let client = ArchiveBookmarkClient(create: { url in
            XCTAssertEqual(url, movedURL)
            return Data("renewed".utf8)
        }, resolve: { _ in ArchiveBookmarkResolution(url: movedURL, isStale: true) },
            startAccess: { _ in true }, stopAccess: { _ in })
        let store = ArchivePreferenceStore(storage: defaults, bookmarks: client, requiresSecurityScope: true)
        XCTAssertEqual(store.loadLocationURL(), movedURL)
        XCTAssertEqual(defaults.data(forKey: AppModelPreferenceKey.archiveLocationBookmarkData), Data("renewed".utf8))
        XCTAssertEqual(defaults.string(forKey: AppModelPreferenceKey.archiveLocationPath), movedURL.path)
    }

    func testFailedScopeUsesVisibleSafeFallbackAndPreservesSavedChoice() {
        let name = "ArchiveFolderAccessTests.start.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let requested = URL(fileURLWithPath: "/tmp/unavailable-history")
        defaults.set(requested.path, forKey: AppModelPreferenceKey.archiveLocationPath)
        defaults.set(Data("bookmark".utf8), forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
        let client = ArchiveBookmarkClient(create: { _ in Data() },
            resolve: { _ in ArchiveBookmarkResolution(url: requested, isStale: false) },
            startAccess: { _ in false }, stopAccess: { _ in XCTFail("A failed acquisition must not be released") })
        let preferences = ArchivePreferenceStore(storage: defaults, bookmarks: client, requiresSecurityScope: true)
        let environment = AppEnvironment(defaults: defaults, permissions: TestCapturePermissionService(),
            preferenceStores: AppPreferenceStores(storage: defaults, archive: preferences))
        let fallback = DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        let model = AppModel(defaults: defaults, environment: environment, recoveryStore: fallback,
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        XCTAssertNil(model.archive.configuredArchiveLocationURL)
        XCTAssertEqual(model.archive.requestedArchiveLocationURL, requested)
        XCTAssertEqual(model.archive.folderAccessError, .accessUnavailable)
        XCTAssertEqual(model.archive.directoryURL, fallback.archiveURL)
        XCTAssertNotNil(model.lifecycle.errorMessage)
        XCTAssertEqual(defaults.string(forKey: AppModelPreferenceKey.archiveLocationPath), requested.path)
    }

    func testChoosingAFolderWithFailedPersistenceDoesNotRebindOrReleaseCurrentStorage() {
        let name = "ArchiveFolderAccessTests.choose.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let old = URL(fileURLWithPath: "/tmp/old-history")
        let selected = URL(fileURLWithPath: "/tmp/selected-history")
        defaults.set(old.path, forKey: AppModelPreferenceKey.archiveLocationPath)
        defaults.set(Data("old".utf8), forKey: AppModelPreferenceKey.archiveLocationBookmarkData)
        let client = ArchiveBookmarkClient(create: { _ in throw Failure() },
            resolve: { _ in ArchiveBookmarkResolution(url: old, isStale: false) },
            startAccess: { _ in true }, stopAccess: { _ in })
        let prefs = ArchivePreferenceStore(storage: defaults, bookmarks: client, requiresSecurityScope: true)
        let location = PreparedArchiveLocation(preferences: prefs)
        let recovery = DocumentRecoveryStore(baseURL: old, folderAccess: location.access)
        let lifecycle = TestWorkflowLifecyclePresenter()
        let model = ArchiveWorkflowModel(dependencies: ArchiveWorkflowDependencies(
            systemServices: AppSystemServices.live(permissions: TestCapturePermissionService()), lifecycle: lifecycle,
            locationPresenter: ArchiveTestLocationPresenter(selection: selected)),
            recoveryStore: recovery, configuredArchiveLocationURL: old, preferenceStore: prefs, preparedLocation: location)
        model.shouldStartMaintenance = false
        model.chooseArchiveLocation()
        XCTAssertTrue(model.recoveryStore === recovery)
        XCTAssertEqual(model.directoryURL, old)
        XCTAssertEqual(model.folderAccess?.url, old)
        XCTAssertEqual(defaults.data(forKey: AppModelPreferenceKey.archiveLocationBookmarkData), Data("old".utf8))
        XCTAssertFalse(lifecycle.presentedErrors.isEmpty)
    }

    func testRecoveryStoreKeepsScopeAliveForItsEntireLifetime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveFolderAccessTests.lease.\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = ArchiveScopeLedger()
        let client = ArchiveBookmarkClient(create: { _ in Data() },
            resolve: { _ in ArchiveBookmarkResolution(url: root, isStale: false) },
            startAccess: { _ in ledger.start(); return true }, stopAccess: { _ in ledger.stop() })
        var lease: ArchiveFolderAccess? = ArchiveFolderAccess(url: root, client: client, requiresSecurityScope: true)
        weak var weakLease = lease
        var store: DocumentRecoveryStore? = DocumentRecoveryStore(baseURL: root, folderAccess: lease)
        lease = nil
        XCTAssertNotNil(weakLease)
        _ = try store?.createSession(title: "Test", sourceDocumentURL: nil)
        XCTAssertEqual(ledger.stops, 0)
        store = nil
        XCTAssertNil(weakLease)
        XCTAssertEqual(ledger.stops, 1)
    }

    func testPermanentlyGrantedFolderDoesNotNeedASecurityScopeToken() throws {
        let name = "ArchiveFolderAccessTests.permanent.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let folder = URL(fileURLWithPath: "/tmp/permanent-history", isDirectory: true)
        let client = ArchiveBookmarkClient(create: { _ in throw Failure() },
            resolve: { _ in throw Failure() }, startAccess: { _ in false }, stopAccess: { _ in XCTFail("No acquired scope") },
            hasPermanentAccess: { $0.path == folder.path })
        let store = ArchivePreferenceStore(storage: defaults, bookmarks: client, requiresSecurityScope: true)
        try store.saveLocationURL(folder)
        let prepared = PreparedArchiveLocation(preferences: store)
        XCTAssertEqual(prepared.usableURL, folder)
        XCTAssertNil(prepared.error)
        XCTAssertFalse(try XCTUnwrap(prepared.access).didStartAccess)
    }

    func testLegacyPlainPathIsRejectedOnlyWhenASecurityCapabilityIsRequired() {
        let name = "ArchiveFolderAccessTests.legacy.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/tmp/history", forKey: AppModelPreferenceKey.archiveLocationPath)
        XCTAssertNil(ArchivePreferenceStore(storage: defaults, requiresSecurityScope: true).loadLocationURL())
        XCTAssertEqual(ArchivePreferenceStore(storage: defaults, requiresSecurityScope: false).loadLocationURL()?.path, "/tmp/history")
    }


}

private final class ArchiveScopeLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var stopCount = 0
    var stops: Int { lock.withLock { stopCount } }
    func start() {}
    func stop() { lock.withLock { stopCount += 1 } }
}

@MainActor
private struct ArchiveTestLocationPresenter: ArchiveLocationPresenting {
    let selection: URL
    func selectArchiveLocation(initialDirectory: URL) -> URL? { selection }
}
