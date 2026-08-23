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

    func testSnipLibraryModelStartsWithAUsableSelectionAndChangesScopes() {
        let recent = makeEntry(index: 1)
        let history = makeEntry(index: 2)
        let recycled = makeEntry(index: 3, deletedAt: Date())
        let model = SnipLibraryWindowModel(
            request: makeLibraryRequest(
                recent: [recent],
                history: [history],
                recycled: [recycled]
            ),
            initialScope: .recent
        )
        install([recent], in: model)

        XCTAssertEqual(model.selectedEntry?.id, recent.id)
        XCTAssertEqual(model.primaryActionTitle, "Open")

        model.changeScope(.recycleBin)
        install([recycled], in: model)

        XCTAssertEqual(model.selectedEntry?.id, recycled.id)
        XCTAssertEqual(model.primaryActionTitle, "Restore")
    }

    func testSnipLibrarySearchKeepsSelectionWhenPossibleAndChoosesFirstMatch() {
        let first = makeEntry(index: 1, searchableText: "alpha")
        let second = makeEntry(index: 2, searchableText: "beta")
        let model = SnipLibraryWindowModel(
            request: makeLibraryRequest(history: [first, second]),
            initialScope: .history
        )
        install([first, second], in: model)

        model.select(second.id)
        model.searchQuery = "beta"
        model.searchDidChange()
        install([second], in: model, preferredSelection: second.id)
        XCTAssertEqual(model.selectedEntry?.id, second.id)

        model.searchQuery = "alpha"
        model.searchDidChange()
        install([first], in: model, preferredSelection: first.id)
        XCTAssertEqual(model.selectedEntry?.id, first.id)
    }

    func testSnipLibrarySearchWithNoMatchClearsSelection() {
        let entry = makeEntry(index: 1, searchableText: "alpha")
        let model = SnipLibraryWindowModel(
            request: makeLibraryRequest(history: [entry]),
            initialScope: .history
        )
        install([entry], in: model)

        model.searchQuery = "not present"
        model.searchDidChange()
        install([], in: model)

        XCTAssertTrue(model.visibleEntries.isEmpty)
        XCTAssertNil(model.selectedEntryID)
        XCTAssertNil(model.selectedEntry)
    }

    func testSnipLibraryRefreshSelectsNextAvailableEntryAfterDeletion() {
        let first = makeEntry(index: 1)
        let second = makeEntry(index: 2)
        let model = SnipLibraryWindowModel(
            request: makeLibraryRequest(history: [first, second]),
            initialScope: .history
        )
        install([first, second], in: model)

        model.prepareForEntryReload(preferredSelection: first.id)
        install([second], in: model, preferredSelection: first.id)

        XCTAssertEqual(model.selectedEntry?.id, second.id)
    }

    func testSnipLibraryAppendsPagesWithoutLosingSelection() {
        let entries = [makeEntry(index: 1), makeEntry(index: 2), makeEntry(index: 3)]
        let model = SnipLibraryWindowModel(
            request: makeLibraryRequest(history: entries),
            initialScope: .history
        )
        model.install(
            page: DocumentHistoryPage(
                entries: Array(entries.prefix(2)),
                totalCount: 3,
                offset: 0
            ),
            appending: false,
            preferredSelection: entries[1].id
        )

        XCTAssertTrue(model.hasMoreEntries)
        XCTAssertEqual(model.selectedEntryID, entries[1].id)

        model.install(
            page: DocumentHistoryPage(
                entries: [entries[2]],
                totalCount: 3,
                offset: 2
            ),
            appending: true,
            preferredSelection: entries[1].id
        )

        XCTAssertEqual(model.entries.map(\.id), entries.map(\.id))
        XCTAssertEqual(model.selectedEntryID, entries[1].id)
        XCTAssertFalse(model.hasMoreEntries)
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

    private func makeLibraryRequest(
        recent: [DocumentHistoryEntry] = [],
        history: [DocumentHistoryEntry] = [],
        recycled: [DocumentHistoryEntry] = []
    ) -> SnipLibraryRequest {
        SnipLibraryRequest(
            outOfCapturePatternSettings: .default,
            loadPage: { scope, query, offset, limit in
                let source = switch scope {
                case .recent: recent
                case .history: history
                case .recycleBin: recycled
                }
                let matches = source.filter { $0.matchesSearchQuery(query) }
                let start = min(max(offset, 0), matches.count)
                let end = min(start + max(limit, 1), matches.count)
                return DocumentHistoryPage(
                    entries: Array(matches[start..<end]),
                    totalCount: matches.count,
                    offset: start
                )
            },
            onOpenRecent: { _ in },
            onOpenHistory: { _ in },
            onRestoreRecycled: { _ in },
            onFloat: { _ in },
            onDelete: { _ in },
            onPermanentlyDelete: { _ in },
            onEmptyRecycleBin: {}
        )
    }

    private func install(
        _ entries: [DocumentHistoryEntry],
        in model: SnipLibraryWindowModel,
        preferredSelection: UUID? = nil
    ) {
        model.install(
            page: DocumentHistoryPage(
                entries: entries,
                totalCount: entries.count,
                offset: 0
            ),
            appending: false,
            preferredSelection: preferredSelection
        )
    }

    private func makeEntry(
        index: Int,
        searchableText: String = "",
        deletedAt: Date? = nil
    ) -> DocumentHistoryEntry {
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
            searchableText: searchableText,
            packageSizeBytes: nil,
            deletedAt: deletedAt
        )
    }
}
