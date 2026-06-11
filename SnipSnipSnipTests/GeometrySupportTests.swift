import AppKit
import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class GeometrySupportTests: XCTestCase {
    func testDistanceFromPointToSegmentReturnsZeroOnLine() {
        let distance = gscDistanceFromPoint(
            CGPoint(x: 20, y: 20),
            toSegmentFrom: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 30, y: 30)
        )

        XCTAssertEqual(distance, 0, accuracy: 0.0001)
    }

    func testResizedRectAdjustsBottomRightHandle() {
        let original = CGRect(x: 100, y: 50, width: 40, height: 30)
        let resized = gscResizedRect(original, handle: .bottomRight, point: CGPoint(x: 180, y: 120))

        XCTAssertEqual(resized, CGRect(x: 100, y: 50, width: 80, height: 70))
    }

    func testResizedRectStandardizesDraggedPastOppositeCorner() {
        let original = CGRect(x: 100, y: 100, width: 60, height: 40)
        let resized = gscResizedRect(original, handle: .topLeft, point: CGPoint(x: 180, y: 170))

        XCTAssertEqual(resized, CGRect(x: 160, y: 140, width: 20, height: 30))
    }

    func testSignedScaleBoundsPreserveHorizontalFlipAfterResolution() {
        let original = CGRect(x: 100, y: 100, width: 60, height: 40)
        let signedBounds = gscSignedScaleBounds(for: original, handle: .left, point: CGPoint(x: 180, y: 120))
        let resolvedBounds = signedBounds.resolved(to: signedBounds.rect)
        let mappedMinPoint = gscScaledPoint(CGPoint(x: original.minX, y: original.midY), from: original, to: resolvedBounds)
        let mappedMaxPoint = gscScaledPoint(CGPoint(x: original.maxX, y: original.midY), from: original, to: resolvedBounds)

        XCTAssertEqual(signedBounds.rect, CGRect(x: 160, y: 100, width: 20, height: 40))
        XCTAssertTrue(resolvedBounds.isFlippedHorizontally)
        XCTAssertEqual(mappedMinPoint, CGPoint(x: 180, y: 120))
        XCTAssertEqual(mappedMaxPoint, CGPoint(x: 160, y: 120))
    }

    func testBoundingRectUnionsMultipleRects() {
        let bounds = gscBoundingRect(of: [
            CGRect(x: 10, y: 20, width: 20, height: 20),
            CGRect(x: 40, y: 10, width: 10, height: 50)
        ])

        XCTAssertEqual(bounds, CGRect(x: 10, y: 10, width: 40, height: 50))
    }

    func testSnapRectAlignsNearCanvasEdges() {
        let resolution = gscSnapRect(
            CGRect(x: 4, y: 96, width: 40, height: 20),
            within: CGRect(x: 0, y: 0, width: 200, height: 200),
            against: [],
            threshold: 8
        )

        XCTAssertEqual(resolution.rect.minX, 0)
        XCTAssertEqual(resolution.rect.minY, 100)
        XCTAssertEqual(resolution.guides.count, 2)
    }

    func testSnapRectStaysWithinBoundsWhenGuideWouldPushPastEdge() {
        let resolution = gscSnapRect(
            CGRect(x: 65, y: 20, width: 30, height: 20),
            within: CGRect(x: 0, y: 0, width: 100, height: 100),
            against: [CGRect(x: 110, y: 20, width: 20, height: 20)],
            threshold: 20
        )

        XCTAssertEqual(resolution.rect, CGRect(x: 70, y: 20, width: 30, height: 20))
    }

    func testCapturePreviewTransformScalesCaptureSelectionIntoPreviewPixels() {
        let transform = CapturePreviewTransform(
            displayTransform: CaptureDisplayTransform(
                captureFrame: CGRect(x: 0, y: 0, width: 100, height: 50),
                overlayFrame: CGRect(x: 0, y: 0, width: 100, height: 50)
            ),
            previewPixelSize: CGSize(width: 200, height: 150)
        )

        let mapped = transform.previewTopLeftPixelRect(fromCaptureGlobalRect: CGRect(x: 20, y: 15, width: 30, height: 10))

        XCTAssertEqual(mapped, CGRect(x: 40, y: 45, width: 60, height: 30))
    }

    func testCenteredCropRectKeepsRequestedAreaAroundPoint() {
        let crop = gscCenteredCropRect(
            around: CGPoint(x: 60, y: 40),
            size: 24,
            within: CGRect(x: 0, y: 0, width: 200, height: 120)
        )

        XCTAssertEqual(crop, CGRect(x: 48, y: 28, width: 24, height: 24))
    }

    func testCenteredCropRectClampsAtEdges() {
        let crop = gscCenteredCropRect(
            around: CGPoint(x: 4, y: 6),
            size: 24,
            within: CGRect(x: 0, y: 0, width: 200, height: 120)
        )

        XCTAssertEqual(crop, CGRect(x: 0, y: 0, width: 16, height: 18))
    }

    func testCropInteractionHUDLayoutKeepsLoupeAndDimensionInsideBounds() {
        let layout = gscCropInteractionHUDLayout(
            around: CGPoint(x: 390, y: 290),
            in: CGRect(x: 0, y: 0, width: 400, height: 300),
            dimensionSize: CGSize(width: 72, height: 16)
        )

        XCTAssertGreaterThanOrEqual(layout.loupeRect.minX, 16)
        XCTAssertGreaterThanOrEqual(layout.loupeRect.minY, 16)
        XCTAssertLessThanOrEqual(layout.loupeRect.maxX, 384)
        XCTAssertLessThanOrEqual(layout.loupeRect.maxY, 284)
        XCTAssertGreaterThanOrEqual(layout.dimensionRect.minX, 16)
        XCTAssertGreaterThanOrEqual(layout.dimensionRect.minY, 16)
        XCTAssertLessThanOrEqual(layout.dimensionRect.maxX, 384)
        XCTAssertLessThanOrEqual(layout.dimensionRect.maxY, 284)
    }

    func testCropInteractionHUDLayoutMovesDimensionAboveLoupeWhenBottomSpaceRunsOut() {
        let layout = gscCropInteractionHUDLayout(
            around: CGPoint(x: 120, y: 220),
            in: CGRect(x: 0, y: 0, width: 280, height: 300),
            dimensionSize: CGSize(width: 80, height: 16)
        )

        XCTAssertLessThan(layout.dimensionRect.maxY, layout.loupeRect.minY)
    }

    func testCropPixelDimensionTextMatchesCommittedIntegralCropSize() {
        let text = gscCropPixelDimensionText(for: CGRect(x: 10.2, y: 20.6, width: 119.2, height: 79.1))

        XCTAssertEqual(text, "120 × 80 px")
    }

    func testAutoCropTrimsUniformBorderAroundContent() {
        let image = makeAutoCropFixtureImage(
            width: 100,
            height: 80,
            background: PixelSample(red: 255, green: 255, blue: 255, alpha: 255),
            contentRects: [CGRect(x: 30, y: 20, width: 40, height: 30)]
        )

        let crop = AutoCropAnalyzer.tightenedCropRect(
            baseImage: image,
            currentCrop: CGRect(x: 0, y: 0, width: 100, height: 80)
        )

        XCTAssertEqual(crop, CGRect(x: 30, y: 20, width: 40, height: 30))
    }

    func testAutoCropAppliesConfiguredPadding() {
        let image = makeAutoCropFixtureImage(
            width: 100,
            height: 80,
            background: PixelSample(red: 255, green: 255, blue: 255, alpha: 255),
            contentRects: [CGRect(x: 30, y: 20, width: 40, height: 30)]
        )

        let crop = AutoCropAnalyzer.tightenedCropRect(
            baseImage: image,
            currentCrop: CGRect(x: 0, y: 0, width: 100, height: 80),
            options: AutoCropOptions(padding: AutoCropOptions.paddedCropPadding)
        )

        XCTAssertEqual(crop, CGRect(x: 22, y: 12, width: 56, height: 46))
    }

    func testAutoCropNeverExpandsOutsideCurrentCrop() throws {
        let image = makeAutoCropFixtureImage(
            width: 80,
            height: 70,
            background: PixelSample(red: 255, green: 255, blue: 255, alpha: 255),
            contentRects: [CGRect(x: 20, y: 20, width: 8, height: 8)]
        )
        let currentCrop = CGRect(x: 20, y: 20, width: 40, height: 40)

        let crop = try XCTUnwrap(AutoCropAnalyzer.tightenedCropRect(baseImage: image, currentCrop: currentCrop))

        XCTAssertGreaterThanOrEqual(crop.minX, currentCrop.minX)
        XCTAssertGreaterThanOrEqual(crop.minY, currentCrop.minY)
        XCTAssertLessThanOrEqual(crop.maxX, currentCrop.maxX)
        XCTAssertLessThanOrEqual(crop.maxY, currentCrop.maxY)
    }

    func testAutoCropIncludesRequiredAnnotationBounds() {
        let image = makeAutoCropFixtureImage(
            width: 80,
            height: 70,
            background: PixelSample(red: 255, green: 255, blue: 255, alpha: 255),
            contentRects: [CGRect(x: 30, y: 30, width: 20, height: 20)]
        )

        let crop = AutoCropAnalyzer.tightenedCropRect(
            baseImage: image,
            currentCrop: CGRect(x: 0, y: 0, width: 80, height: 70),
            requiredBounds: CGRect(x: 10, y: 12, width: 12, height: 10)
        )

        XCTAssertEqual(crop, CGRect(x: 10, y: 12, width: 40, height: 38))
    }

    func testAutoCropCanCropAroundAnnotationOnly() {
        let image = makeSolidImage(
            width: 80,
            height: 60,
            color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255)
        )

        let crop = AutoCropAnalyzer.tightenedCropRect(
            baseImage: image,
            currentCrop: CGRect(x: 0, y: 0, width: 80, height: 60),
            requiredBounds: CGRect(x: 30, y: 20, width: 10, height: 8)
        )

        XCTAssertEqual(crop, CGRect(x: 30, y: 20, width: 10, height: 8))
    }

    func testAutoCropReturnsNilWhenUniformImageHasNoRequiredBounds() {
        let image = makeSolidImage(
            width: 80,
            height: 60,
            color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255)
        )

        let crop = AutoCropAnalyzer.tightenedCropRect(
            baseImage: image,
            currentCrop: CGRect(x: 0, y: 0, width: 80, height: 60)
        )

        XCTAssertNil(crop)
    }

    func testAutoCropClampsAtImageEdges() {
        let image = makeAutoCropFixtureImage(
            width: 50,
            height: 40,
            background: PixelSample(red: 255, green: 255, blue: 255, alpha: 255),
            contentRects: [CGRect(x: 0, y: 0, width: 10, height: 10)]
        )

        let crop = AutoCropAnalyzer.tightenedCropRect(
            baseImage: image,
            currentCrop: CGRect(x: 0, y: 0, width: 50, height: 40)
        )

        XCTAssertEqual(crop, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testCroppingPreviewImageMatchesCursorPixelInTopLeftCoordinates() {
        let image = makeCoordinateImage(width: 160, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 50)
        let localPoint = CGPoint(x: 23, y: 17)
        let logicalCropRect = gscCenteredCropRect(around: localPoint, size: 12, within: bounds)
        let imageCropRect = CapturePreviewTransform(
            displayTransform: CaptureDisplayTransform(
                captureFrame: CGRect(origin: .zero, size: bounds.size),
                overlayFrame: CGRect(origin: .zero, size: bounds.size)
            ),
            previewPixelSize: CGSize(width: image.width, height: image.height)
        )
        .previewTopLeftPixelRect(fromOverlayLocalRect: logicalCropRect)

        guard let cropped = image.gscCropped(topLeftPixelRect: imageCropRect) else {
            return XCTFail("Expected preview crop")
        }

        let originalPixel = samplePixel(
            in: image,
            topLeftX: Int(localPoint.x / bounds.width * CGFloat(image.width)),
            topLeftY: Int(localPoint.y / bounds.height * CGFloat(image.height))
        )
        let croppedPixel = samplePixel(
            in: cropped,
            topLeftX: Int((localPoint.x - logicalCropRect.minX) / logicalCropRect.width * CGFloat(cropped.width)),
            topLeftY: Int((localPoint.y - logicalCropRect.minY) / logicalCropRect.height * CGFloat(cropped.height))
        )

        XCTAssertEqual(croppedPixel, originalPixel)
    }

    func testCroppingWithTopLeftPixelRectSamplesTopEdge() {
        let image = makeCoordinateImage(width: 20, height: 10)

        guard let cropped = image.gscCropped(topLeftPixelRect: CGRect(x: 0, y: 0, width: 1, height: 1)) else {
            return XCTFail("Expected crop")
        }

        XCTAssertEqual(samplePixel(in: cropped, topLeftX: 0, topLeftY: 0), PixelSample(red: 0, green: 0, blue: 0, alpha: 255))
    }

    func testRegionImageUsesDisplaySnapshotCoordinatesWithoutVerticalOffset() throws {
        let display = DisplaySnapshot(
            displayID: 1,
            name: "Main",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 1
        )
        let preview = DisplayPreview(snapshot: display, image: makeCoordinateImage(width: 100, height: 100))
        let region = CGRect(x: 10, y: 80, width: 10, height: 10)

        let image = try ScreenCaptureService().buildRegionImage(from: [preview], region: region)

        XCTAssertEqual(image.width, 10)
        XCTAssertEqual(image.height, 10)
        XCTAssertEqual(samplePixel(in: image, topLeftX: 0, topLeftY: 0), PixelSample(red: 10, green: 80, blue: 0, alpha: 255))
    }

    func testRegionImageComposesPixelsAcrossAdjacentDisplays() throws {
        let leftDisplay = DisplaySnapshot(
            displayID: 1,
            name: "Left",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 1
        )
        let rightDisplay = DisplaySnapshot(
            displayID: 2,
            name: "Right",
            frame: CGRect(x: 100, y: 0, width: 100, height: 100),
            scale: 1
        )
        let leftImage = makeCoordinateImage(width: 100, height: 100)
        let rightImage = makeCoordinateImage(
            width: 100,
            height: 100,
            pattern: .weighted(xMultiplier: 3, yMultiplier: 5, includeBlueSum: true)
        )
        let previews = [
            DisplayPreview(snapshot: leftDisplay, image: leftImage),
            DisplayPreview(snapshot: rightDisplay, image: rightImage)
        ]
        let region = CGRect(x: 90, y: 20, width: 20, height: 20)

        let image = try ScreenCaptureService().buildRegionImage(from: previews, region: region)

        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 20)
        XCTAssertEqual(samplePixel(in: image, topLeftX: 0, topLeftY: 0), samplePixel(in: leftImage, topLeftX: 90, topLeftY: 20))
        XCTAssertEqual(samplePixel(in: image, topLeftX: 10, topLeftY: 0), samplePixel(in: rightImage, topLeftX: 0, topLeftY: 20))
        XCTAssertEqual(samplePixel(in: image, topLeftX: 19, topLeftY: 19), samplePixel(in: rightImage, topLeftX: 9, topLeftY: 39))
    }

    func testRegionImageComposesPixelsAcrossOffsetDisplays() throws {
        let leftDisplay = DisplaySnapshot(
            displayID: 1,
            name: "Left",
            frame: CGRect(x: -120, y: 20, width: 120, height: 100),
            scale: 1
        )
        let rightDisplay = DisplaySnapshot(
            displayID: 2,
            name: "Right",
            frame: CGRect(x: 0, y: -40, width: 100, height: 140),
            scale: 1
        )
        let leftImage = makeCoordinateImage(width: 120, height: 100)
        let rightImage = makeCoordinateImage(
            width: 100,
            height: 140,
            pattern: .weighted(xMultiplier: 3, yMultiplier: 5, includeBlueSum: true)
        )
        let previews = [
            DisplayPreview(snapshot: leftDisplay, image: leftImage),
            DisplayPreview(snapshot: rightDisplay, image: rightImage)
        ]
        let region = CGRect(x: -10, y: 30, width: 30, height: 60)

        let image = try ScreenCaptureService().buildRegionImage(from: previews, region: region)

        XCTAssertEqual(image.width, 30)
        XCTAssertEqual(image.height, 60)
        XCTAssertEqual(samplePixel(in: image, topLeftX: 0, topLeftY: 0), samplePixel(in: leftImage, topLeftX: 110, topLeftY: 10))
        XCTAssertEqual(samplePixel(in: image, topLeftX: 10, topLeftY: 0), samplePixel(in: rightImage, topLeftX: 0, topLeftY: 70))
        XCTAssertEqual(samplePixel(in: image, topLeftX: 29, topLeftY: 59), samplePixel(in: rightImage, topLeftX: 19, topLeftY: 129))
    }

    func testCaptureDisplayTransformMapsSelectionInsideOffsetDisplay() {
        let displayFrame = CGRect(x: -120, y: 20, width: 120, height: 100)
        let globalSelection = CGRect(x: -110, y: 80, width: 20, height: 30)
        let transform = CaptureDisplayTransform(captureFrame: displayFrame, overlayFrame: displayFrame)

        let localSelection = transform.captureLocalRect(fromCaptureGlobalRect: globalSelection)

        XCTAssertEqual(localSelection, CGRect(x: 10, y: 60, width: 20, height: 30))
        XCTAssertEqual(transform.captureGlobalPoint(fromCaptureLocalPoint: localSelection.origin), CGPoint(x: -110, y: 80))
    }

    func testMakeFullscreenCaptureUsesDesktopCompositeBoundsAcrossDisplays() {
        let previewImage = makeCoordinateImage(
            width: 200,
            height: 100,
            pattern: .weighted(xMultiplier: 7, yMultiplier: 11, includeBlueSum: true)
        )
        let snapshot = DesktopCompositeSnapshot(
            previewImage: previewImage,
            globalFrame: CGRect(x: -100, y: 0, width: 200, height: 100),
            displays: [
                DisplaySnapshot(displayID: 1, name: "Left", frame: CGRect(x: -100, y: 0, width: 100, height: 100), scale: 1),
                DisplaySnapshot(displayID: 2, name: "Right", frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)
            ],
            displayPreviews: []
        )
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_123)

        let capture = ScreenCaptureService().makeFullscreenCapture(from: snapshot, capturedAt: capturedAt)

        XCTAssertEqual(capture.kind, .fullscreen)
        XCTAssertEqual(capture.sourceName, "All Displays")
        XCTAssertEqual(capture.sourceRect, snapshot.globalFrame)
        XCTAssertEqual(capture.capturedAt, capturedAt)
        XCTAssertEqual(capture.image.width, previewImage.width)
        XCTAssertEqual(capture.image.height, previewImage.height)
        XCTAssertEqual(samplePixel(in: capture.image, topLeftX: 12, topLeftY: 8), samplePixel(in: previewImage, topLeftX: 12, topLeftY: 8))
        XCTAssertEqual(samplePixel(in: capture.image, topLeftX: 160, topLeftY: 44), samplePixel(in: previewImage, topLeftX: 160, topLeftY: 44))
    }

    func testCurrentDisplayPrefersMatchingDisplayID() {
        let displays = [
            DisplaySnapshot(displayID: 1, name: "Left", frame: CGRect(x: -100, y: 0, width: 100, height: 100), overlayFrame: CGRect(x: -100, y: 0, width: 100, height: 100), scale: 1),
            DisplaySnapshot(displayID: 2, name: "Right", frame: CGRect(x: 0, y: 0, width: 100, height: 100), overlayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
        ]

        let display = ScreenCaptureService().currentDisplay(
            from: displays,
            preferredDisplayID: 2,
            preferredPoint: nil
        )

        XCTAssertEqual(display?.displayID, 2)
        XCTAssertEqual(display?.name, "Right")
    }

    func testCurrentDisplayPrefersPointOverDisplayIDWhenTheyDisagree() {
        let displays = [
            DisplaySnapshot(displayID: 1, name: "Left", frame: CGRect(x: -100, y: 0, width: 100, height: 100), overlayFrame: CGRect(x: -100, y: 0, width: 100, height: 100), scale: 1),
            DisplaySnapshot(displayID: 2, name: "Right", frame: CGRect(x: 0, y: 0, width: 100, height: 100), overlayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
        ]

        let display = ScreenCaptureService().currentDisplay(
            from: displays,
            preferredDisplayID: 2,
            preferredPoint: CGPoint(x: -50, y: 50)
        )

        XCTAssertEqual(display?.displayID, 1)
        XCTAssertEqual(display?.name, "Left")
    }

    func testCurrentDisplayFallsBackToPointWhenDisplayIDMissing() {
        let displays = [
            DisplaySnapshot(displayID: 1, name: "Left", frame: CGRect(x: -100, y: 0, width: 100, height: 100), overlayFrame: CGRect(x: -100, y: 0, width: 100, height: 100), scale: 1),
            DisplaySnapshot(displayID: 2, name: "Right", frame: CGRect(x: 0, y: 0, width: 100, height: 100), overlayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
        ]

        let display = ScreenCaptureService().currentDisplay(
            from: displays,
            preferredDisplayID: nil,
            preferredPoint: CGPoint(x: 50, y: 50)
        )

        XCTAssertEqual(display?.displayID, 2)
        XCTAssertEqual(display?.name, "Right")
    }

    func testCompositeCaptureDrawTransformPlacesDisplayWithinUnionFrame() {
        let rect = CompositeCaptureDrawTransform(
            captureUnionFrame: CGRect(x: 0, y: 0, width: 3360, height: 1440),
            outputScale: 2
        ).destinationRect(fromCaptureGlobalRect: CGRect(x: 1440, y: 0, width: 1920, height: 1080))

        XCTAssertEqual(rect, CGRect(x: 2880, y: 0, width: 3840, height: 2160))
    }

    func testSuggestedTextRectPrefersPlacementToTheRight() {
        let rect = gscSuggestedTextRect(
            adjacentTo: CGRect(x: 40, y: 80, width: 100, height: 60),
            within: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertEqual(rect.origin, CGPoint(x: 154, y: 80))
        XCTAssertEqual(rect.size, CGSize(width: 260, height: 80))
    }

    func testCaptureDisplayTransformRoundTripsThroughGlobalSpace() {
        let globalFrame = CGRect(x: 100, y: 50, width: 400, height: 300)
        let globalPoint = CGPoint(x: 180, y: 280)
        let transform = CaptureDisplayTransform(captureFrame: globalFrame, overlayFrame: globalFrame)
        let localPoint = transform.captureLocalPoint(fromCaptureGlobalPoint: globalPoint)

        XCTAssertEqual(localPoint, CGPoint(x: 80, y: 230))
        XCTAssertEqual(transform.captureGlobalPoint(fromCaptureLocalPoint: localPoint), globalPoint)
    }

    func testCaptureDisplayTransformRemapsOverlayPointsAcrossDifferentDisplaySizes() {
        let overlayFrame = CGRect(x: 1920, y: 0, width: 1440, height: 900)
        let captureFrame = CGRect(x: 1920, y: 0, width: 2560, height: 1600)
        let transform = CaptureDisplayTransform(captureFrame: captureFrame, overlayFrame: overlayFrame)

        XCTAssertEqual(
            transform.captureLocalPoint(fromOverlayLocalPoint: CGPoint(x: 720, y: 450)),
            CGPoint(x: 1280, y: 800)
        )
    }

    func testCaptureDisplayTransformRemapsOverlayRectsAcrossDifferentDisplaySizes() {
        let overlayFrame = CGRect(x: 1920, y: 0, width: 1440, height: 900)
        let captureFrame = CGRect(x: 1920, y: 0, width: 2560, height: 1600)
        let transform = CaptureDisplayTransform(captureFrame: captureFrame, overlayFrame: overlayFrame)

        XCTAssertEqual(
            transform.captureLocalRect(fromOverlayLocalRect: CGRect(x: 144, y: 90, width: 720, height: 450)),
            CGRect(x: 256, y: 160, width: 1280, height: 800)
        )
    }

    func testCaptureDisplayTransformMapsCaptureGlobalRectsIntoOverlayGlobalSpace() {
        let overlayFrame = CGRect(x: -3780, y: 0, width: 3780, height: 2160)
        let captureFrame = CGRect(x: -3780, y: 291, width: 3780, height: 2160)
        let transform = CaptureDisplayTransform(captureFrame: captureFrame, overlayFrame: overlayFrame)

        XCTAssertEqual(
            transform.overlayGlobalRect(fromCaptureGlobalRect: CGRect(x: -2894, y: 1323, width: 1519, height: 1128)),
            CGRect(x: -2894, y: 0, width: 1519, height: 1128)
        )
    }

    func testUprightTextRotationKeepsLabelsReadable() {
        XCTAssertEqual(gscUprightTextRotationDegrees(for: 30), 30)
        XCTAssertEqual(gscUprightTextRotationDegrees(for: 135), -45)
        XCTAssertEqual(gscUprightTextRotationDegrees(for: -135), 45)
        XCTAssertEqual(gscUprightTextRotationDegrees(for: 210), 30)
    }

    func testCaptureAccessibilityTransformFlipsDisplayRelativeY() {
        let mapping = CaptureAccessibilityTransform(
            captureFrame: CGRect(x: -1330, y: -836, width: 1031, height: 922),
            accessibilityFrame: CGRect(x: -1330, y: 500, width: 1031, height: 922)
        )

        XCTAssertEqual(
            mapping.accessibilityPoint(fromCapturePoint: CGPoint(x: -986, y: -432)),
            CGPoint(x: -986, y: 1018)
        )
        XCTAssertEqual(
            mapping.accessibilityRect(fromCaptureRect: CGRect(x: -1718, y: -840, width: 1464, height: 815)),
            CGRect(x: -1718, y: 611, width: 1464, height: 815)
        )
    }

    func testCaptureAccessibilityTransformScalesAcrossDifferingDisplaySizes() {
        let mapping = CaptureAccessibilityTransform(
            captureFrame: CGRect(x: 200, y: 100, width: 200, height: 100),
            accessibilityFrame: CGRect(x: 1000, y: 500, width: 100, height: 50)
        )

        XCTAssertEqual(mapping.accessibilityPoint(fromCapturePoint: CGPoint(x: 300, y: 150)), CGPoint(x: 1050, y: 525))
        XCTAssertEqual(
            mapping.accessibilityRect(fromCaptureRect: CGRect(x: 250, y: 120, width: 80, height: 30)),
            CGRect(x: 1025, y: 525, width: 40, height: 15)
        )
    }

    func testCaptureAccessibilityTransformInvertsPointMapping() {
        let mapping = CaptureAccessibilityTransform(
            captureFrame: CGRect(x: 200, y: 100, width: 200, height: 100),
            accessibilityFrame: CGRect(x: 1000, y: 500, width: 100, height: 50)
        )
        let capturePoint = CGPoint(x: 260, y: 130)

        XCTAssertEqual(
            mapping.capturePoint(fromAccessibilityPoint: mapping.accessibilityPoint(fromCapturePoint: capturePoint)),
            capturePoint
        )
    }

    func testCaptureAccessibilityTransformInvertsRectMapping() {
        let mapping = CaptureAccessibilityTransform(
            captureFrame: CGRect(x: -1330, y: -836, width: 1031, height: 922),
            accessibilityFrame: CGRect(x: -1330, y: 500, width: 1031, height: 922)
        )
        let captureRect = CGRect(x: -1200, y: -700, width: 400, height: 300)

        XCTAssertEqual(
            mapping.captureRect(fromAccessibilityRect: mapping.accessibilityRect(fromCaptureRect: captureRect)),
            captureRect
        )
    }

    func testCaptureDisplayTransformUsesTopLeftLocalCoordinates() {
        let captureFrame = CGRect(x: -1330, y: -922, width: 1031, height: 922)
        let localPoint = CGPoint(x: 482, y: 437)
        let transform = CaptureDisplayTransform(captureFrame: captureFrame, overlayFrame: captureFrame)

        let capturePoint = transform.captureGlobalPoint(fromCaptureLocalPoint: localPoint)

        XCTAssertEqual(capturePoint, CGPoint(x: -848, y: -485))
        XCTAssertEqual(transform.captureLocalPoint(fromCaptureGlobalPoint: capturePoint), localPoint)
    }

    func testCaptureLocalRectUsesTopLeftOrigin() {
        let captureFrame = CGRect(x: -1330, y: -922, width: 1031, height: 922)
        let captureRect = CGRect(x: -1302, y: -904, width: 908, height: 838)
        let transform = CaptureDisplayTransform(captureFrame: captureFrame, overlayFrame: captureFrame)

        let localRect = transform.captureLocalRect(fromCaptureGlobalRect: captureRect)

        XCTAssertEqual(localRect, CGRect(x: 28, y: 18, width: 908, height: 838))
    }

    func testDocumentProjectionMapsDocumentRectIntoRenderContext() {
        let projection = DocumentProjection(
            sourceDocumentRect: CGRect(x: 20, y: 15, width: 80, height: 60),
            destinationBounds: CGRect(x: 0, y: 0, width: 80, height: 60)
        )

        XCTAssertEqual(
            projection.destinationRect(fromDocumentRect: CGRect(x: 30, y: 25, width: 10, height: 15)),
            CGRect(x: 10, y: 10, width: 10, height: 15)
        )
        XCTAssertEqual(
            projection.contextRect(fromDocumentRect: CGRect(x: 30, y: 25, width: 10, height: 15)),
            CGRect(x: 10, y: 35, width: 10, height: 15)
        )
    }

    func testFittedTextRectExpandsHeightForWrappedContent() {
        let rect = gscFittedTextRect(
            for: "This is a longer text annotation that should wrap into multiple lines.",
            currentRect: CGRect(x: 20, y: 20, width: 160, height: 48),
            font: NSFont.systemFont(ofSize: 24, weight: .semibold),
            horizontalPadding: 24,
            verticalPadding: 20,
            minSize: CGSize(width: 160, height: 48),
            maxWidth: 220
        )

        XCTAssertGreaterThan(rect.height, 48)
    }

    func testFittedTextRectAddsSlackForExplicitLineBreaks() {
        let font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        let rect = gscFittedTextRect(
            for: "Line 1\nLine 2\nLine 3",
            currentRect: CGRect(x: 20, y: 20, width: 180, height: 60),
            font: font,
            horizontalPadding: 24,
            verticalPadding: 20,
            minSize: CGSize(width: 180, height: 60),
            maxWidth: 520
        )

        XCTAssertGreaterThan(rect.height, 119)
    }
}

private func makeAutoCropFixtureImage(
    width: Int,
    height: Int,
    background: PixelSample,
    contentRects: [CGRect],
    content: PixelSample = PixelSample(red: 0, green: 0, blue: 0, alpha: 255)
) -> CGImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for y in 0..<height {
        for x in 0..<width {
            let point = CGPoint(x: x, y: y)
            let sample = contentRects.contains { $0.contains(point) } ? content : background
            let offset = y * bytesPerRow + x * bytesPerPixel
            pixels[offset] = sample.red
            pixels[offset + 1] = sample.green
            pixels[offset + 2] = sample.blue
            pixels[offset + 3] = sample.alpha
        }
    }

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: CGDataProvider(data: Data(pixels) as CFData)!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}
