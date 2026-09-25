import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class DocumentWindowPresenterTests: XCTestCase {
    func testEveryDocumentMinimumFitsSmallAvailableContentAreas() {
        for available in [CGSize(width: 1280, height: 650), CGSize(width: 1024, height: 530)] {
            for kind: DocumentWindowContentKind in [.screenshot, .guide, .video] {
                let fitted = MainWindowLayout.fittedContentSize(
                    preferred: MainWindowLayout.minimumContentSize(for: kind), available: available
                )
                XCTAssertLessThanOrEqual(fitted.width, available.width)
                XCTAssertLessThanOrEqual(fitted.height, available.height)
            }
        }
    }

    func testOversizedWindowFitsSmallOffsetDisplay() {
        let visible = CGRect(x: -1024, y: 23, width: 1024, height: 577)
        let fitted = DocumentWindowPlacementPolicy.resizedFrame(
            currentFrame: CGRect(x: 200, y: 200, width: 1280, height: 800),
            targetSize: CGSize(width: 1280, height: 800), visibleFrame: visible
        )
        XCTAssertEqual(fitted, visible)
    }

    func testGuideSheetLeavesRoomForItsParentAttachmentOnSmallDisplay() {
        let size = SheetLayout.contentSize(
            preferred: CGSize(width: 760, height: 730),
            visibleFrame: CGRect(x: -1024, y: 23, width: 1024, height: 577),
            parentContentFrame: CGRect(x: -1000, y: 23, width: 990, height: 530)
        )
        XCTAssertEqual(size, CGSize(width: 760, height: 498))
        XCTAssertEqual(SheetLayout.contentSize(
            preferred: CGSize(width: 760, height: 730),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), parentContentFrame: nil
        ), CGSize(width: 760, height: 730))
    }

    func testMainWindowLayoutUses1240PointPreferredMinimumWidth() {
        XCTAssertEqual(MainWindowLayout.minimumContentSize, CGSize(width: 1_240, height: 600))
        XCTAssertEqual(
            MainWindowLayout.minimumContentSize(for: .screenshot),
            MainWindowLayout.minimumContentSize
        )
        XCTAssertEqual(
            MainWindowLayout.minimumContentSize(for: .video),
            MainWindowLayout.minimumContentSize
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
