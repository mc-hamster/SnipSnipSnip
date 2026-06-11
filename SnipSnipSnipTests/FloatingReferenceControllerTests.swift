import CoreGraphics
import XCTest
@testable import SnipSnipSnip

@MainActor
final class FloatingReferenceControllerTests: XCTestCase {
    func testInitialWindowSizePreservesAspectRatioWithinBounds() {
        let size = FloatingReferenceWindowSizing.initialWindowSize(
            for: CGSize(width: 4_000, height: 2_000)
        )

        XCTAssertEqual(size.width, 720, accuracy: 0.0001)
        XCTAssertEqual(size.height, 360, accuracy: 0.0001)
    }

    func testInitialWindowSizeFallsBackForInvalidImages() {
        let size = FloatingReferenceWindowSizing.initialWindowSize(for: .zero)

        XCTAssertEqual(size.width, 520, accuracy: 0.0001)
        XCTAssertEqual(size.height, 340, accuracy: 0.0001)
    }

    func testInitialFrameCascadesFromTopRightInsideVisibleFrame() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 1_000, height: 800)

        let firstFrame = FloatingReferenceWindowPlacementPolicy.initialFrame(
            forWindowSize: CGSize(width: 400, height: 300),
            visibleFrame: visibleFrame,
            referenceIndex: 0
        )
        let secondFrame = FloatingReferenceWindowPlacementPolicy.initialFrame(
            forWindowSize: CGSize(width: 400, height: 300),
            visibleFrame: visibleFrame,
            referenceIndex: 1
        )

        XCTAssertEqual(firstFrame, CGRect(x: 672, y: 672, width: 400, height: 300))
        XCTAssertEqual(secondFrame, CGRect(x: 646, y: 646, width: 400, height: 300))
        XCTAssertTrue(visibleFrame.contains(firstFrame))
        XCTAssertTrue(visibleFrame.contains(secondFrame))
    }

    func testInitialFrameClampsLargeWindowsToVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 360, height: 260)

        let frame = FloatingReferenceWindowPlacementPolicy.initialFrame(
            forWindowSize: CGSize(width: 720, height: 520),
            visibleFrame: visibleFrame,
            referenceIndex: 0
        )

        XCTAssertEqual(frame, CGRect(x: 28, y: 28, width: 304, height: 204))
        XCTAssertTrue(visibleFrame.contains(frame))
    }

    func testRetentionPolicyClosesOldestReferenceBeforeAddingPastLimit() {
        let ids = makeIDs(count: FloatingReferenceRetentionPolicy.maximumActiveReferences)

        let referencesToClose = FloatingReferenceRetentionPolicy.referencesToCloseBeforeAddingReference(
            currentOrder: ids
        )

        XCTAssertEqual(referencesToClose, [ids[0]])
    }

    func testRetentionPolicyKeepsNewestReferencesForSmallerCustomLimits() {
        let ids = makeIDs(count: 5)

        let referencesToClose = FloatingReferenceRetentionPolicy.referencesToCloseBeforeAddingReference(
            currentOrder: ids,
            maximumActiveReferences: 3
        )

        XCTAssertEqual(referencesToClose, Array(ids.prefix(3)))
    }

    func testCloseNotifierPublishesOnlyOnce() {
        let id = UUID()
        var closedIDs: [UUID] = []
        let notifier = FloatingReferenceCloseNotifier(id: id) { closedIDs.append($0) }

        notifier.notifyIfNeeded()
        notifier.notifyIfNeeded()

        XCTAssertEqual(closedIDs, [id])
        XCTAssertTrue(notifier.didNotifyClose)
    }

    private func makeIDs(count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }
}
