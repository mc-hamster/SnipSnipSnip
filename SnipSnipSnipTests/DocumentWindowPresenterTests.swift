import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class DocumentWindowPresenterTests: XCTestCase {
    func testMainWindowLayoutUses1240PointPreferredMinimumWidth() {
        XCTAssertEqual(MainWindowLayout.minimumContentSize, CGSize(width: 1_240, height: 600))
        XCTAssertEqual(
            MainWindowLayout.minimumContentSize(for: .screenshot),
            MainWindowLayout.minimumContentSize
        )
        XCTAssertGreaterThanOrEqual(
            MainWindowLayout.minimumContentSize(for: .video).width,
            MainWindowLayout.minimumContentSize.width
        )
        XCTAssertGreaterThanOrEqual(
            MainWindowLayout.minimumContentSize(for: .guide).width,
            MainWindowLayout.minimumContentSize.width
        )
    }

    func testResizedFrameKeepsUserPlacedTopLeftCorner() {
        let frame = DocumentWindowPlacementPolicy.resizedFrame(
            currentFrame: CGRect(x: 90, y: 160, width: 900, height: 600),
            targetSize: CGSize(width: 1_000, height: 700),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(frame, CGRect(x: 90, y: 60, width: 1_000, height: 700))
    }

    func testResizedFrameDoesNotMoveWhenSizeIsUnchanged() {
        let currentFrame = CGRect(x: 420, y: 180, width: 900, height: 600)

        let frame = DocumentWindowPlacementPolicy.resizedFrame(
            currentFrame: currentFrame,
            targetSize: currentFrame.size,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(frame, currentFrame)
    }

    func testResizedFrameClampsOnlyAsNeededToRemainVisible() {
        let frame = DocumentWindowPlacementPolicy.resizedFrame(
            currentFrame: CGRect(x: 980, y: 250, width: 400, height: 500),
            targetSize: CGSize(width: 900, height: 700),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(frame, CGRect(x: 540, y: 50, width: 900, height: 700))
    }

    func testResizedFrameSupportsOffsetDisplayCoordinates() {
        let frame = DocumentWindowPlacementPolicy.resizedFrame(
            currentFrame: CGRect(x: -1_800, y: 280, width: 900, height: 600),
            targetSize: CGSize(width: 1_100, height: 700),
            visibleFrame: CGRect(x: -1_920, y: 23, width: 1_920, height: 1_057)
        )

        XCTAssertEqual(frame, CGRect(x: -1_800, y: 180, width: 1_100, height: 700))
    }
}
