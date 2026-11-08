import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class PasteboardPermissionTests: XCTestCase {
    func testCopyAndCaptureTextDoNotReadClipboardWithoutPriorAccess() throws {
        for policy in [ClipboardAccessPolicy.systemDefault, .ask, .denied] {
            let pasteboard = TestPasteboardService()
            pasteboard.setString("unrelated content", forType: .string)
            pasteboard.programmaticAccessPolicy = policy
            XCTAssertTrue(ClipboardPasteboardTransaction.commit(
                pasteboard: pasteboard, preparedItems: nil,
                fallbackWrite: { pasteboard.setString("copied item", forType: .string) }
            ))
            XCTAssertEqual(pasteboard.contentReadCount, 0)
            try TextCaptureService.writeText("recognized text", isPrivate: false, pasteboard: pasteboard)
            XCTAssertEqual(pasteboard.contentReadCount, 0)
            XCTAssertEqual(pasteboard.string(forType: .string), "recognized text")
        }
    }

    func testFailedCopyWithoutReadAccessReportsFailureAndDoesNotRead() {
        let pasteboard = TestPasteboardService()
        pasteboard.programmaticAccessPolicy = .ask
        pasteboard.failNextSnapshotWrite()
        XCTAssertFalse(ClipboardPasteboardTransaction.commit(
            pasteboard: pasteboard,
            preparedItems: [PasteboardItemSnapshot(representations: [
                PasteboardRepresentationSnapshot(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, data: Data("new".utf8))
            ])], fallbackWrite: { false }
        ))
        XCTAssertEqual(pasteboard.contentReadCount, 0)
    }

    func testSnapshotReaderStopsBetweenRepresentationsAndDiscardsPartialContent() {
        var access = true
        var reads = 0
        let snapshots = PasteboardSnapshotReader.read(
            items: { [0, 1] }, types: { _ in ["text", "html"] },
            data: { _, _ in
                reads += 1
                access = false
                return Data("protected".utf8)
            },
            acceptedTypeIdentifiers: ["text", "html"], allowsRead: { access }
        )
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testSnapshotReaderDoesNotFetchItemsWithoutAccess() {
        var fetchedItems = false
        let snapshots = PasteboardSnapshotReader.read(
            items: { fetchedItems = true; return [0] }, types: { _ in ["text"] },
            data: { _, _ in XCTFail("No content should be read"); return nil },
            acceptedTypeIdentifiers: ["text"], allowsRead: { false }
        )
        XCTAssertFalse(fetchedItems)
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testSnapshotReaderPreservesEmptyPrivacyMarkersWithContent() throws {
        let marker = "org.nspasteboard.ConcealedType"
        let snapshots = PasteboardSnapshotReader.read(
            items: { [0] }, types: { _ in ["text", marker, "missing"] },
            data: { _, type in type == "missing" ? nil : type == marker ? Data() : Data("private".utf8) },
            acceptedTypeIdentifiers: ["text", marker, "missing"], allowsRead: { true }
        )
        let representations = try XCTUnwrap(snapshots.first).representations
        XCTAssertEqual(representations.map(\.typeIdentifier), ["text", marker])
        XCTAssertEqual(representations.last?.data, Data())
    }

    func testRollbackDiscardsContentWhenAccessChangesDuringSnapshot() {
        let pasteboard = TestPasteboardService()
        pasteboard.setString("protected", forType: .string)
        pasteboard.onContentRead = { [weak pasteboard] in pasteboard?.programmaticAccessPolicy = .denied }
        XCTAssertTrue(pasteboard.rollbackItemSnapshots(acceptedTypeIdentifiers: Set(pasteboard.typeNames)).isEmpty)
        XCTAssertEqual(pasteboard.contentReadCount, 1)
    }
}
