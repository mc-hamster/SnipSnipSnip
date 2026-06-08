import AppKit
import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class CaptureModelsTests: XCTestCase {
    func testRegionCapturePreferencesDefaultToCombinedOverlayAndAutoCapture() {
        let preferences = RegionCapturePreferences()

        XCTAssertEqual(preferences.overlayMode, .crosshairAndMagnifyingGlass)
        XCTAssertFalse(preferences.showsActionControls)
        XCTAssertTrue(preferences.autoCapturesOnMouseUp)
    }

    func testRegionCaptureOverlayModeFlagsMatchVisibleOverlays() {
        XCTAssertTrue(RegionCaptureOverlayMode.crosshair.showsCrosshair)
        XCTAssertFalse(RegionCaptureOverlayMode.crosshair.showsMagnifyingGlass)

        XCTAssertFalse(RegionCaptureOverlayMode.magnifyingGlass.showsCrosshair)
        XCTAssertTrue(RegionCaptureOverlayMode.magnifyingGlass.showsMagnifyingGlass)

        XCTAssertTrue(RegionCaptureOverlayMode.crosshairAndMagnifyingGlass.showsCrosshair)
        XCTAssertTrue(RegionCaptureOverlayMode.crosshairAndMagnifyingGlass.showsMagnifyingGlass)
    }

    func testDisplaySnapshotSeparatesCaptureFrameFromOverlayFrame() {
        let captureFrame = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let overlayFrame = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

        let snapshot = DisplaySnapshot(
            displayID: 7,
            name: "External",
            frame: captureFrame,
            overlayFrame: overlayFrame,
            scale: 2
        )

        XCTAssertEqual(snapshot.frame, captureFrame)
        XCTAssertEqual(snapshot.overlayFrame, overlayFrame)
    }

    func testDisplaySnapshotDefaultsOverlayFrameToCaptureFrame() {
        let captureFrame = CGRect(x: -100, y: 20, width: 120, height: 100)

        let snapshot = DisplaySnapshot(displayID: 1, name: "Display", frame: captureFrame, scale: 1)

        XCTAssertEqual(snapshot.overlayFrame, captureFrame)
    }

    func testScreenshotFilenameTemplateResolvesTokensAndSanitizesOutput() {
        let capture = makeCapturedScreenshot(
            image: makeCoordinateImage(width: 320, height: 240),
            kind: .window,
            sourceName: "Safari: Inbox/Work",
            capturedAt: Date(timeIntervalSince1970: 1_717_171_717)
        )
        let template = ScreenshotFilenameTemplate(pattern: "Shot-{kind}-{source}-{yyyy-MM-dd-HH-mm}-{width}x{height}.{format}")

        XCTAssertEqual(
            template.resolvedFilename(for: capture, formatExtension: "png"),
            "Shot-window-Safari- Inbox-Work-2024-05-31-09-08-320x240.png"
        )
    }

    func testDefaultScreenshotFilenameTemplateIncludesKindAndTimestamp() {
        let capture = makeCapturedScreenshot(
            image: makeCoordinateImage(width: 64, height: 48),
            kind: .region,
            capturedAt: Date(timeIntervalSince1970: 1_717_171_717)
        )

        XCTAssertEqual(
            ScreenshotFilenameTemplate.default.resolvedFilename(for: capture, formatExtension: nil),
            "SnipSnipSnip-Display-2024-05-31-09-08-37"
        )
    }

    func testCapturedScreenshotTracksSourceRectAndCoordinateContract() {
        let capture = makeCapturedScreenshot(
            image: makeCoordinateImage(width: 64, height: 48),
            kind: .scrolling,
            sourceName: "Scrolling Capture",
            sourceRect: CGRect(x: 120, y: 240, width: 64, height: 180)
        )

        XCTAssertEqual(capture.sourceRect, CGRect(x: 120, y: 240, width: 64, height: 180))
        XCTAssertEqual(capture.coordinateContract, .current)
    }

    func testCapturedScreenshotPreservesSourceWindowIdentityWhenAttachingMetadata() {
        let identity = CaptureSourceWindowIdentity(
            windowID: 42,
            ownerName: "System Settings",
            ownerPID: 1234,
            bundleIdentifier: "com.apple.systempreferences",
            title: "Privacy & Security",
            frame: CGRect(x: 40, y: 120, width: 600, height: 540)
        )
        let capture = makeCapturedScreenshot(
            kind: .window,
            sourceWindowIdentity: identity
        )

        let uiMap = UIMapSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceRect: CGRect(x: 40, y: 120, width: 600, height: 540),
            elements: [
                UIMapElement(
                    name: "Privacy & Security",
                    role: "AXWindow",
                    documentRect: CGRect(x: 0, y: 0, width: 600, height: 540)
                )
            ]
        )

        XCTAssertEqual(capture.attachingUIMap(uiMap).sourceWindowIdentity, identity)
        XCTAssertEqual(capture.attachingCursorOverlay(nil).sourceWindowIdentity, identity)
    }

    func testCursorCaptureGeometryMapsScreenHotspotIntoDocumentPixels() {
        let rect = CursorCaptureGeometry.overlayRect(
            cursorCaptureGlobalLocation: CGPoint(x: 150, y: 260),
            cursorHotSpot: CGPoint(x: 2, y: 3),
            cursorSize: CGSize(width: 16, height: 18),
            captureSourceRect: CGRect(x: 100, y: 200, width: 200, height: 100),
            capturePixelSize: CGSize(width: 400, height: 200)
        )

        XCTAssertEqual(rect, CGRect(x: 96, y: 114, width: 32, height: 36))
    }

    func testCursorCaptureGeometryExcludesCursorOutsideCaptureRect() {
        XCTAssertNil(CursorCaptureGeometry.overlayRect(
            cursorCaptureGlobalLocation: CGPoint(x: 99, y: 260),
            cursorHotSpot: .zero,
            cursorSize: CGSize(width: 16, height: 18),
            captureSourceRect: CGRect(x: 100, y: 200, width: 200, height: 100),
            capturePixelSize: CGSize(width: 400, height: 200)
        ))
    }

    func testCursorCaptureGeometryConvertsAppKitPointToQuartzGlobalPoint() {
        XCTAssertEqual(
            CursorCaptureGeometry.captureGlobalPoint(
                fromAppKitGlobalPoint: CGPoint(x: -900, y: 700),
                captureFrame: CGRect(x: -1330, y: -922, width: 1031, height: 922),
                appKitFrame: CGRect(x: -1330, y: 0, width: 1031, height: 922)
            ),
            CGPoint(x: -900, y: -700)
        )
    }

    func testScrollingCaptureResultSeparatesViewportSourceRectFromOutputDocumentRect() {
        let image = makeCoordinateImage(width: 64, height: 220)
        let result = ScrollingCaptureResult(
            image: image,
            sourceViewportRect: CGRect(x: 20, y: 30, width: 64, height: 80),
            sourceName: "Scrolling Capture - Safari",
            capturedAt: Date(timeIntervalSince1970: 1_818_000_000),
            warnings: []
        )

        XCTAssertEqual(result.sourceViewportRect, CGRect(x: 20, y: 30, width: 64, height: 80))
        XCTAssertEqual(result.outputPixelSize, CGSize(width: 64, height: 220))
        XCTAssertEqual(result.outputDocumentRect, CGRect(x: 0, y: 0, width: 64, height: 220))
        XCTAssertEqual(result.capturedScreenshot.sourceRect, result.sourceViewportRect)
    }

    func testBestWindowMatchPrefersSameProcessAndTitle() {
        let previous = makeCaptureWindow(id: 10, ownerPID: 42, ownerName: "Notes", title: "Sprint Plan", focusRank: 5)
        let candidates = [
            makeCaptureWindow(id: 11, ownerPID: 7, ownerName: "Safari", title: "Inbox", focusRank: 0),
            makeCaptureWindow(id: 12, ownerPID: 42, ownerName: "Notes", title: "Sprint Plan", focusRank: 3),
            makeCaptureWindow(id: 13, ownerPID: 42, ownerName: "Notes", title: "Archive", focusRank: 1)
        ]

        let resolved = gscBestWindowMatch(for: previous, in: candidates, frontmostOwnerPID: 7)

        XCTAssertEqual(resolved?.id, 12)
    }

    func testBestWindowMatchFallsBackToFrontmostOwner() {
        let previous = makeCaptureWindow(id: 20, ownerPID: 99, ownerName: "Preview", title: "Mockup", focusRank: 10)
        let candidates = [
            makeCaptureWindow(id: 21, ownerPID: 55, ownerName: "Xcode", title: "Project", focusRank: 4),
            makeCaptureWindow(id: 22, ownerPID: 77, ownerName: "Mail", title: "Inbox", focusRank: 2),
            makeCaptureWindow(id: 23, ownerPID: 77, ownerName: "Mail", title: "Compose", focusRank: 0)
        ]

        let resolved = gscBestWindowMatch(for: previous, in: candidates, frontmostOwnerPID: 77)

        XCTAssertEqual(resolved?.id, 23)
    }

    func testTopmostWindowPrefersLowestFocusRankAmongOverlappingMatches() {
        let point = CGPoint(x: 160, y: 160)
        let windows = [
            makeCaptureWindow(id: 31, focusRank: 8, frame: CGRect(x: 40, y: 40, width: 240, height: 220)),
            makeCaptureWindow(id: 32, focusRank: 2, frame: CGRect(x: 90, y: 90, width: 180, height: 180)),
            makeCaptureWindow(id: 33, focusRank: 5, frame: CGRect(x: 120, y: 120, width: 90, height: 90))
        ]

        let resolved = gscTopmostWindow(at: point, in: windows)

        XCTAssertEqual(resolved?.id, 32)
    }

    func testTopmostWindowBreaksEqualFocusRankUsingSmallestMatch() {
        let point = CGPoint(x: 160, y: 160)
        let windows = [
            makeCaptureWindow(id: 41, focusRank: 3, frame: CGRect(x: 40, y: 40, width: 260, height: 260)),
            makeCaptureWindow(id: 42, focusRank: 3, frame: CGRect(x: 110, y: 110, width: 90, height: 90))
        ]

        let resolved = gscTopmostWindow(at: point, in: windows)

        XCTAssertEqual(resolved?.id, 42)
    }

    func testWindowBoundsByIDParsesCGWindowBoundsDictionary() {
        let desktopFrame = CGRect(x: 0, y: -900, width: 3360, height: 1980)
        let cgWindowBounds = CGRect(x: 1920, y: 120, width: 640, height: 400)

        XCTAssertEqual(
            gscAppKitScreenRect(fromCGWindowBounds: cgWindowBounds, desktopFrame: desktopFrame),
            CGRect(x: 1920, y: 560, width: 640, height: 400)
        )

        let windowInfo: [[String: Any]] = [
            [
                kCGWindowNumber as String: NSNumber(value: 17),
                kCGWindowBounds as String: [
                    "X": 1920,
                    "Y": 120,
                    "Width": 640,
                    "Height": 400
                ]
            ]
        ]

        let boundsByID = gscWindowBoundsByID(from: windowInfo)

        let expectedBounds = gscAppKitScreenRect(fromCGWindowBounds: cgWindowBounds, desktopFrame: NSScreen.screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        })

        XCTAssertEqual(boundsByID[17], expectedBounds)
    }

    func testWindowBoundsByIDCanUseCaptureDesktopFrameForMixedHeightDisplays() {
        let captureDesktopFrame = CGRect(x: -3780, y: -1178, width: 5292, height: 2160)
        let cgWindowBounds = CGRect(x: -3143, y: -282, width: 1519, height: 1128)
        let windowInfo: [[String: Any]] = [
            [
                kCGWindowNumber as String: NSNumber(value: 52),
                kCGWindowBounds as String: [
                    "X": -3143,
                    "Y": -282,
                    "Width": 1519,
                    "Height": 1128
                ]
            ]
        ]

        XCTAssertEqual(
            gscAppKitScreenRect(fromCGWindowBounds: cgWindowBounds, desktopFrame: captureDesktopFrame),
            CGRect(x: -3143, y: 136, width: 1519, height: 1128)
        )
        XCTAssertEqual(
            gscWindowBoundsByID(from: windowInfo, desktopFrame: captureDesktopFrame)[52],
            CGRect(x: -3143, y: 136, width: 1519, height: 1128)
        )
    }

    func testTopmostWindowCanPreferVisibleScreenSpaceBounds() {
        let point = CGPoint(x: 2010, y: 210)
        let windows = [
            makeCaptureWindow(id: 51, focusRank: 5, frame: CGRect(x: 10, y: 10, width: 400, height: 300)),
            makeCaptureWindow(id: 52, focusRank: 1, frame: CGRect(x: 20, y: 20, width: 300, height: 200))
        ]
        let visibleBoundsByID: [CGWindowID: CGRect] = [
            51: CGRect(x: 1980, y: 180, width: 500, height: 320),
            52: CGRect(x: 2000, y: 200, width: 120, height: 90)
        ]

        let resolved = gscTopmostWindow(at: point, in: windows, visibleBoundsByID: visibleBoundsByID)

        XCTAssertEqual(resolved?.id, 52)
    }

    func testPreferredHighlightRectUsesSharedInteriorWhenBoundsMostlyOverlap() {
        let primary = CGRect(x: 10, y: 20, width: 240, height: 180)
        let alternate = CGRect(x: 10, y: 30, width: 240, height: 170)

        XCTAssertEqual(
            gscPreferredHighlightRect(primary: primary, alternate: alternate),
            CGRect(x: 10, y: 30, width: 240, height: 170)
        )
    }

    func testPreferredHighlightRectKeepsPrimaryWhenBoundsDoNotMostlyOverlap() {
        let primary = CGRect(x: 10, y: 20, width: 240, height: 180)
        let alternate = CGRect(x: 10, y: 120, width: 240, height: 180)

        XCTAssertEqual(
            gscPreferredHighlightRect(primary: primary, alternate: alternate),
            primary
        )
    }
}
