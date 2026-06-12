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

    func testDisplayedImageSizeAppliesZoomScale() {
        let size = FloatingReferenceWindowSizing.displayedImageSize(
            forPixelSize: CGSize(width: 640, height: 480),
            displayScale: 1.5
        )

        XCTAssertEqual(size.width, 960, accuracy: 0.0001)
        XCTAssertEqual(size.height, 720, accuracy: 0.0001)
    }

    func testContentSizeForDisplayedImageAddsViewportAndToolbarSpace() {
        let size = FloatingReferenceWindowSizing.contentSize(
            forDisplayedImageSize: CGSize(width: 640, height: 480)
        )

        XCTAssertEqual(size.width, 680, accuracy: 0.0001)
        XCTAssertEqual(size.height, 558, accuracy: 0.0001)
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

    func testResizedFrameKeepsCurrentCenterWhenItFits() {
        let frame = FloatingReferenceWindowSizing.resizedFrame(
            currentFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            requestedFrameSize: CGSize(width: 600, height: 420),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 900)
        )

        XCTAssertEqual(frame, CGRect(x: 0, y: 40, width: 600, height: 420))
    }

    func testResizedFrameClampsToVisibleFrame() {
        let visibleFrame = CGRect(x: 80, y: 120, width: 900, height: 700)

        let frame = FloatingReferenceWindowSizing.resizedFrame(
            currentFrame: CGRect(x: 700, y: 620, width: 260, height: 180),
            requestedFrameSize: CGSize(width: 1_400, height: 1_000),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, visibleFrame)
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
