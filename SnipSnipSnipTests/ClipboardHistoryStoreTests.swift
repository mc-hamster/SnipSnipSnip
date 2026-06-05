import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class ClipboardHistoryStoreTests: XCTestCase {
    private func makeStore(named name: String) -> ClipboardHistoryStore {
        ClipboardHistoryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true))
    }

    private func removeStore(named name: String) {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true))
    }

    func testDeduplicatesItemsByContentHashAndKeepsNewestTimelinePosition() {
        let storeName = "ClipboardHistoryStoreTests.deduplicates"
        removeStore(named: storeName)
        defer { removeStore(named: storeName) }

        let store = makeStore(named: storeName)
        let preferences = ClipboardPreferences.default

        store.recordText(
            "repeat value",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
            preferences: preferences,
            copiedAt: Date(timeIntervalSince1970: 1)
        )
        store.recordText(
            "other value",
            sourceApp: ClipboardSourceApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
            preferences: preferences,
            copiedAt: Date(timeIntervalSince1970: 2)
        )
        store.recordText(
            "repeat value",
            sourceApp: ClipboardSourceApp(name: "Mail", bundleIdentifier: "com.apple.mail"),
            preferences: preferences,
            copiedAt: Date(timeIntervalSince1970: 3)
        )

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first?.previewText, "repeat value")
        XCTAssertEqual(store.items.first?.sourceApp?.name, "Mail")
    }

    func testPrunesUnpinnedItemsByMaximumItemCount() {
        let storeName = "ClipboardHistoryStoreTests.prunesCount"
        removeStore(named: storeName)
        defer { removeStore(named: storeName) }

        let store = makeStore(named: storeName)
        let preferences = ClipboardPreferences(
            isEnabled: true,
            maxItemCount: 10,
            maxStorageMB: 25,
            ignoredApps: []
        )

        for index in 0..<14 {
            store.recordText("value \(index)", sourceApp: nil, preferences: preferences, copiedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }

        XCTAssertEqual(store.items.count, 10)
        XCTAssertEqual(store.items.first?.previewText, "value 13")
        XCTAssertEqual(store.items.last?.previewText, "value 4")
    }

    func testPrunesUnpinnedItemsByMaximumByteSize() {
        let storeName = "ClipboardHistoryStoreTests.prunesSize"
        removeStore(named: storeName)
        defer { removeStore(named: storeName) }

        let store = makeStore(named: storeName)
        let preferences = ClipboardPreferences(
            isEnabled: true,
            maxItemCount: 100,
            maxStorageMB: 25,
            ignoredApps: []
        )

        let imageData = Data(repeating: 7, count: 14 * 1_024 * 1_024)
        store.recordImageData(imageData, sourceApp: nil, preferences: preferences, copiedAt: Date(timeIntervalSince1970: 1))
        store.recordImageData(Data(repeating: 9, count: 14 * 1_024 * 1_024), sourceApp: nil, preferences: preferences, copiedAt: Date(timeIntervalSince1970: 2))

        var constrainedPreferences = preferences
        constrainedPreferences.maxStorageMB = 25
        store.prune(using: constrainedPreferences)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertLessThanOrEqual(store.items.reduce(Int64(0)) { $0 + $1.byteSize }, constrainedPreferences.maxStorageBytes)
    }

    func testIgnoredAppsAndSensitiveTypesAreFiltered() {
        let preferences = ClipboardPreferences.default
        let sourceApp = ClipboardSourceApp(name: "Bitwarden", bundleIdentifier: "com.bitwarden.desktop")

        XCTAssertTrue(preferences.ignores(sourceApp))
        XCTAssertTrue(ClipboardPasteboardReader.containsSensitiveOrTransientType(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(ClipboardPasteboardReader.containsSensitiveOrTransientType(["org.nspasteboard.TransientType"]))
        XCTAssertFalse(ClipboardPasteboardReader.containsSensitiveOrTransientType(["public.utf8-plain-text"]))
    }

    func testDefaultIgnoredAppsIncludeAdditionalPasswordManagers() {
        let preferences = ClipboardPreferences.default
        let managers = [
            ClipboardSourceApp(name: "mSecure", bundleIdentifier: "com.mseven.mSecure"),
            ClipboardSourceApp(name: "Keeper Password Manager", bundleIdentifier: "com.keepersecurity.passwordmanager"),
            ClipboardSourceApp(name: "RoboForm", bundleIdentifier: "com.siber.roboform"),
            ClipboardSourceApp(name: "Enpass", bundleIdentifier: "in.sinew.Enpass-Desktop"),
            ClipboardSourceApp(name: "KeeWeb", bundleIdentifier: "com.antelle.keeweb"),
            ClipboardSourceApp(name: "MacPass", bundleIdentifier: "com.hicknhacksoftware.MacPass"),
            ClipboardSourceApp(name: "Strongbox", bundleIdentifier: "com.strongboxsafe.Strongbox"),
            ClipboardSourceApp(name: "Secrets", bundleIdentifier: "com.outercorner.Secrets"),
            ClipboardSourceApp(name: "Buttercup", bundleIdentifier: "com.buttercup.desktop"),
            ClipboardSourceApp(name: "SafeInCloud", bundleIdentifier: "com.safe-in-cloud.SafeInCloud")
        ]

        for manager in managers {
            XCTAssertTrue(preferences.ignores(manager), "Expected default clipboard privacy filters to ignore \(manager.displayName).")
        }
    }

    func testSearchMatchesTextSourceAndType() {
        let storeName = "ClipboardHistoryStoreTests.search"
        removeStore(named: storeName)
        defer { removeStore(named: storeName) }

        let store = makeStore(named: storeName)
        store.recordText(
            "https://example.com/snip",
            sourceApp: ClipboardSourceApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
            preferences: .default
        )

        let item = try! XCTUnwrap(store.items.first)
        XCTAssertTrue(item.matchesSearchQuery("example"))
        XCTAssertTrue(item.matchesSearchQuery("Safari"))
        XCTAssertTrue(item.matchesSearchQuery("Link"))
        XCTAssertFalse(item.matchesSearchQuery("missing"))
    }

    func testImageFileURLsAreReadAsImageSnapshotsWithFilenameMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardHistoryStoreTests.imageFileURL", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("image000000.jpg")
        let imageData = try XCTUnwrap(Self.jpegData())
        try imageData.write(to: imageURL)

        let snapshot = try XCTUnwrap(ClipboardPasteboardReader.imageFileSnapshot(for: [imageURL]))
        guard case let .imageData(data, title, searchableText) = snapshot else {
            return XCTFail("Expected image data for copied image file URLs.")
        }

        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(title, "image000000.jpg")
        XCTAssertTrue(searchableText?.contains("image000000.jpg") == true)
    }

    func testWebURLsReadFromPasteboardURLObjectsAreLinksNotFiles() throws {
        let storeName = "ClipboardHistoryStoreTests.webURL"
        removeStore(named: storeName)
        defer { removeStore(named: storeName) }

        let webURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abc123"))
        let snapshot = try XCTUnwrap(ClipboardPasteboardReader.webURLSnapshot(for: [webURL], title: "Demo Video"))
        guard case let .link(urlString, title, _) = snapshot else {
            return XCTFail("Expected link data for web URL pasteboard objects.")
        }

        let store = makeStore(named: storeName)
        store.recordLink(
            urlString,
            title: title,
            sourceApp: ClipboardSourceApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
            preferences: .default
        )

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.kind.filter, .links)
        XCTAssertEqual(item.title, "Demo Video")
        XCTAssertTrue(item.matchesSearchQuery("youtube.com/watch"))
        XCTAssertTrue(item.matchesSearchQuery("Safari"))
    }

    private static func jpegData() -> Data? {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        NSGraphicsContext.restoreGraphicsState()

        return representation.representation(using: .jpeg, properties: [:])
    }
}
