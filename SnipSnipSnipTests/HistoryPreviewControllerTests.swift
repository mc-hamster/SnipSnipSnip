import CoreGraphics
import XCTest
@testable import SnipSnipSnip

@MainActor
final class HistoryPreviewControllerTests: XCTestCase {
    func testWindowModelSelectsRequestedEntryAndNavigatesNeighbors() {
        let entries = [makeEntry(index: 0), makeEntry(index: 1), makeEntry(index: 2)]
        let model = HistoryPreviewWindowModel(
            request: makeRequest(entries: entries, selectedEntryID: entries[1].id)
        )

        XCTAssertEqual(model.selectedEntry?.id, entries[1].id)
        XCTAssertEqual(model.positionLabel, "2 of 3")
        XCTAssertTrue(model.canSelectPrevious)
        XCTAssertTrue(model.canSelectNext)

        XCTAssertEqual(model.select(offset: 1)?.id, entries[2].id)
        XCTAssertFalse(model.canSelectNext)
        XCTAssertNil(model.select(offset: 1))
    }

    func testWindowModelDeduplicatesEntriesWithoutChangingOrder() {
        let first = makeEntry(index: 0)
        let second = makeEntry(index: 1)
        let model = HistoryPreviewWindowModel(
            request: makeRequest(
                entries: [first, second, first],
                selectedEntryID: first.id
            )
        )

        XCTAssertEqual(model.entries.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.positionLabel, "1 of 2")
    }

    func testWindowModelCarriesOptionalContextualPrimaryAction() {
        let entry = makeEntry(index: 0)
        let action = HistoryPreviewPrimaryAction(
            title: "Restore",
            systemImage: "arrow.uturn.backward.circle",
            help: "Restore this screenshot.",
            perform: { _ in }
        )
        let request = HistoryPreviewRequest(
            contextTitle: "Recent Snips",
            entries: [entry],
            selectedEntryID: entry.id,
            primaryAction: action,
            onFloat: { _ in }
        )
        let model = HistoryPreviewWindowModel(request: request)

        XCTAssertEqual(model.primaryActionTitle, "Restore")
        XCTAssertEqual(model.primaryActionSystemImage, "arrow.uturn.backward.circle")
        XCTAssertEqual(model.primaryActionHelp, "Restore this screenshot.")

        let actionlessModel = HistoryPreviewWindowModel(
            request: HistoryPreviewRequest(
                contextTitle: "History",
                entries: [entry],
                selectedEntryID: entry.id,
                primaryAction: nil,
                onFloat: { _ in }
            )
        )
        XCTAssertNil(actionlessModel.primaryActionTitle)
    }

    func testManualZoomContinuityPreservesSimilarAspectRatios() {
        XCTAssertTrue(
            HistoryPreviewZoomContinuityPolicy.shouldPreserveManualZoom(
                from: CGSize(width: 1600, height: 900),
                to: CGSize(width: 1440, height: 900)
            )
        )
        XCTAssertFalse(
            HistoryPreviewZoomContinuityPolicy.shouldPreserveManualZoom(
                from: CGSize(width: 1600, height: 900),
                to: CGSize(width: 600, height: 1400)
            )
        )
    }

    func testInitialFramePrefersSpaceBesideParentAndStaysVisible() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1800, height: 1000)
        let parentFrame = CGRect(x: 100, y: 100, width: 800, height: 700)

        let frame = HistoryPreviewWindowSizing.initialFrame(
            parentFrame: parentFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, CGRect(x: 912, y: 296, width: 640, height: 460))
        XCTAssertTrue(visibleFrame.contains(frame))
    }

    private func makeRequest(
        entries: [DocumentHistoryEntry],
        selectedEntryID: UUID
    ) -> HistoryPreviewRequest {
        HistoryPreviewRequest(
            contextTitle: "Change History",
            entries: entries,
            selectedEntryID: selectedEntryID,
            primaryAction: nil,
            onFloat: { _ in }
        )
    }

    private func makeEntry(index: Int) -> DocumentHistoryEntry {
        DocumentHistoryEntry(
            id: UUID(),
            sessionID: UUID(),
            title: "Private title \(index)",
            label: "Checkpoint \(index)",
            changeSummary: nil,
            savedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            packageURL: URL(fileURLWithPath: "/tmp/history-preview-\(index).sss"),
            previewAssetURL: nil,
            sourceDocumentURL: nil,
            hasUnsavedChanges: index.isMultiple(of: 2),
            searchableText: "",
            packageSizeBytes: nil,
            deletedAt: nil
        )
    }
}
