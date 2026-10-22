import AppKit
import CoreGraphics
import XCTest
@testable import SnipSnipSnip

@MainActor
final class ScrollingCaptureServiceTests: XCTestCase {
    func testDuplicateAfterRetryStopsTheCaptureLoop() async throws {
        let driver = ScrollingTestDriver(reportedPosition: 0)
        driver.hasMoreContent = false
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let mismatch = makeSolidImage(width: 48, height: 80, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))

        let result = try await captureFrames([first, mismatch, first], driver: driver)

        assertScrollingRows(in: result.image, expectedHeight: 80)
        XCTAssertEqual(driver.scrollDistances, [60, 36])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testStalledCaptureWithKnownRemainingContentOffersPartial() async throws {
        let driver = ScrollingTestDriver(reportedPosition: 0.5)
        driver.hasMoreContent = true
        let frame = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })

        do {
            _ = try await captureFrames([frame, frame], driver: driver)
            XCTFail("A stall before the scrollbar maximum must not claim completion")
        } catch let interruption as ScrollingCaptureInterruptedError {
            assertScrollingRows(in: interruption.partialResult.image, expectedHeight: 80)
            XCTAssertEqual(driver.scrollDistances, [60])
        }
    }

    func testAccessibilityEndDetectionUsesScrollbarMaximumRatherThanNoMovement() throws {
        for value in [2.0, 5.0] {
            var platform = TestGuideAccessibility()
            let target = platform.applicationElement(processID: ProcessInfo.processInfo.processIdentifier)
            let bar = platform.systemWideElement()
            platform.hitTest = { _ in (.success, target) }
            platform.attributeProvider = { name, _ in
                switch name {
                case "AXRole": return "AXScrollArea"
                case "AXVerticalScrollBar": return bar
                case "AXValue": return NSNumber(value: value)
                case "AXMaxValue": return NSNumber(value: 5)
                default: return nil
                }
            }
            let driver = try AccessibilityScrollDriver(
                viewportRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                permissions: TestCapturePermissionService(), accessibility: platform
            )

            XCTAssertEqual(driver.hasMoreContent, value < 5)
            XCTAssertEqual(driver.isAtEnd(previousPosition: value), value == 5)
        }
    }
    func testProgressPanelFallbackDoesNotCoverTheScrollEventPoint() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let display = DisplaySnapshot(displayID: 1, name: "Test", frame: bounds, scale: 1)
        let target = CGPoint(x: 650, y: 100)
        let size = CGSize(width: 420, height: 220)
        let origin = ScrollingCaptureProgressOverlay.frameOrigin(
            avoiding: bounds, on: display, visibleFrame: bounds, panelSize: size, scrollTargetPoint: target
        )
        let panel = CGRect(origin: origin, size: size)

        XCTAssertTrue(bounds.contains(panel))
        XCTAssertFalse(panel.contains(display.captureDisplayTransform.overlayGlobalPoint(fromCaptureGlobalPoint: target)))
        XCTAssertFalse(ScrollingCaptureProgressOverlay.requiresKeyboardControls(panelFrame: panel, scrollTargetPoint: target, on: display))
    }

    func testProgressPanelDropsMarginsWhenOnlyThePanelFitsOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 430, height: 240)
        let display = DisplaySnapshot(displayID: 1, name: "Test", frame: bounds, scale: 1)
        let size = CGSize(width: 420, height: 220)

        let origin = ScrollingCaptureProgressOverlay.frameOrigin(
            avoiding: bounds, on: display, visibleFrame: bounds, panelSize: size
        )

        XCTAssertTrue(bounds.contains(CGRect(origin: origin, size: size)))
        XCTAssertTrue(ScrollingCaptureProgressOverlay.requiresKeyboardControls(
            panelFrame: CGRect(origin: origin, size: size),
            scrollTargetPoint: CGPoint(x: bounds.midX, y: bounds.midY), on: display
        ))
    }
    func testProgressPreviewPreservesTopAndBottomInFlippedView() throws {
        let image = makeRGBAImage(width: 8, height: 12) { _, y in
            y < 6 ? PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
                : PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
        }
        let context = try XCTUnwrap(SRGBBitmapContext.make(width: 8, height: 12))
        context.translateBy(x: 0, y: 12)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        ScrollingCapturePreviewRenderer.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 12))

        let preview = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(samplePixel(in: preview, topLeftX: 4, topLeftY: 2).red, 255)
        XCTAssertEqual(samplePixel(in: preview, topLeftX: 4, topLeftY: 10).blue, 255)
    }

    func testAlreadyCancelledCaptureDoesNotResolveOrMoveATarget() async throws {
        let cancellation = ScrollingCaptureCancellation()
        cancellation.cancel()
        let permissions = TestCapturePermissionService()
        let service = ScrollingCaptureService(captureService: ScreenCaptureService(), permissions: permissions, driverFactory: { _ in
            XCTFail("A cancelled attempt must not touch the target app")
            throw ScrollingCaptureError.noScrollableTarget
        })

        do {
            _ = try await service.capture(
                request: ScrollingCaptureRequest(viewportRect: CGRect(x: 0, y: 0, width: 48, height: 80)),
                cancellation: cancellation
            )
            XCTFail("Expected cancellation")
        } catch ScrollingCaptureError.cancelled {
        }
    }

    func testExactHeightLimitStopsWithoutAnExtraScroll() async throws {
        let driver = ScrollingTestDriver(reportedPosition: nil)
        let frames = [0, 50].map { offset in
            makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + offset })
        }

        let result = try await captureFrames(frames, driver: driver, maxOutputHeight: 130)

        assertScrollingRows(in: result.image, expectedHeight: 130)
        XCTAssertEqual(driver.scrollDistances, [60])
        XCTAssertEqual(result.warnings.count, 1)
    }
    func testAccessibilityHitTestingUsesUnflippedCaptureCoordinates() throws {
        for y in [40, 1100, -800] {
            let viewport = CGRect(x: 100, y: y, width: 300, height: 200)
            var platform = TestGuideAccessibility()
            let target = platform.applicationElement(processID: ProcessInfo.processInfo.processIdentifier)
            let hits = ScrollingHitRecorder()
            platform.hitTest = { point in
                hits.record(point)
                return (.success, target)
            }
            platform.attributeProvider = { name, _ in name == "AXRole" ? "AXScrollArea" : nil }

            _ = try AccessibilityScrollDriver(viewportRect: viewport, permissions: TestCapturePermissionService(), accessibility: platform)

            XCTAssertEqual(hits.points, [CGPoint(x: viewport.midX, y: viewport.midY)])
        }
    }
    func testWheelDeltaKeepsSmallStepsAndRejectsInvalidDistances() {
        XCTAssertEqual(AccessibilityScrollDriver.wheelDelta(for: 7), -7)
        XCTAssertEqual(AccessibilityScrollDriver.wheelDelta(for: -3), 3)
        XCTAssertEqual(AccessibilityScrollDriver.wheelDelta(for: 0.1), -1)
        XCTAssertNil(AccessibilityScrollDriver.wheelDelta(for: 0))
        XCTAssertNil(AccessibilityScrollDriver.wheelDelta(for: .nan))
        XCTAssertNil(AccessibilityScrollDriver.wheelDelta(for: .infinity))
        XCTAssertEqual(AccessibilityScrollDriver.wheelDelta(for: .greatestFiniteMagnitude), -Int32.max)
    }

    func testPositionAdvanceRequiresFiniteForwardProgress() {
        XCTAssertTrue(ScrollingCaptureService.positionAdvanced(from: 0.2, to: 0.200001))
        XCTAssertFalse(ScrollingCaptureService.positionAdvanced(from: 0.2, to: 0.2))
        XCTAssertFalse(ScrollingCaptureService.positionAdvanced(from: 0.2, to: 0.1))
        XCTAssertFalse(ScrollingCaptureService.positionAdvanced(from: nil, to: 1))
        XCTAssertFalse(ScrollingCaptureService.positionAdvanced(from: 0, to: .nan))
    }

    func testDelayedScrollRenderingIsRecapturedBeforeDeclaringEnd() async throws {
        let driver = ScrollingTestDriver(reportedPosition: nil)
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let last = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + 60 })

        let result = try await captureFrames([first, first, last, last], driver: driver)

        assertScrollingRows(in: result.image, expectedHeight: 140)
        XCTAssertEqual(driver.scrollDistances, [60, 60])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testRepeatedPixelsWithAdvancingScrollbarOfferPartialInsteadOfClaimingEnd() async throws {
        let driver = ScrollingTestDriver(reportedPosition: 0)
        driver.advancesPosition = true
        let frame = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })

        do {
            _ = try await captureFrames([frame, frame], driver: driver)
            XCTFail("An advancing page with repeated pixels has an ambiguous seam")
        } catch let interruption as ScrollingCaptureInterruptedError {
            assertScrollingRows(in: interruption.partialResult.image, expectedHeight: 80)
            XCTAssertTrue(interruption.reason.contains("repeated content"))
        }
    }

    func testReadOnlyScrollbarDoesNotTriggerAnotherForwardStepDuringRetry() async throws {
        let driver = ScrollingTestDriver(reportedPosition: 0)
        driver.advancesPosition = true
        driver.restorationSucceeds = false
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let mismatch = makeSolidImage(width: 48, height: 80, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        let last = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + 50 })

        let result = try await captureFrames([first, mismatch, last, last], driver: driver)

        assertScrollingRows(in: result.image, expectedHeight: 130)
        XCTAssertEqual(driver.scrollDistances, [60, 60])
        XCTAssertEqual(driver.restoredPositions, [0])
        XCTAssertTrue(result.warnings.isEmpty)
    }
    func testCursorParkingLocationPrefersPointOutsideViewport() {
        let point = ScrollingCaptureService.cursorParkingLocation(
            avoiding: CGRect(x: 100, y: 100, width: 400, height: 300),
            on: CGRect(x: 0, y: 0, width: 1200, height: 900)
        )

        XCTAssertEqual(point, CGPoint(x: 524, y: 424))
    }

    func testCursorParkingLocationReturnsNilWhenViewportFillsVisibleFrame() {
        let point = ScrollingCaptureService.cursorParkingLocation(
            avoiding: CGRect(x: 0, y: 0, width: 1200, height: 900),
            on: CGRect(x: 0, y: 0, width: 1200, height: 900)
        )

        XCTAssertNil(point)
    }

    func testCursorParkingMapsCaptureAndOverlayCoordinatesOnOffsetDisplays() throws {
        for (captureY, overlayY) in [(0, 0), (900, -900), (-900, 900)] {
            let captureFrame = CGRect(x: 0, y: captureY, width: 1440, height: 900)
            let overlayFrame = CGRect(x: 0, y: overlayY, width: 1440, height: 900)
            let viewport = CGRect(x: 100, y: captureY + 100, width: 400, height: 300)
            let point = try XCTUnwrap(ScrollingCaptureService.cursorParkingLocation(
                avoiding: viewport, on: overlayFrame,
                displayTransform: CaptureDisplayTransform(captureFrame: captureFrame, overlayFrame: overlayFrame)
            ))

            XCTAssertTrue(captureFrame.contains(point))
            XCTAssertFalse(viewport.contains(point))
        }
    }

    func testProgressPanelUsesCaptureDisplayInsteadOfAppKitFrameIntersection() {
        let display = DisplaySnapshot(
            displayID: 2, name: "Below", frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
            overlayFrame: CGRect(x: 0, y: -900, width: 1440, height: 900), scale: 1
        )
        let viewport = CGRect(x: 100, y: 1000, width: 400, height: 300)
        let panelSize = CGSize(width: 420, height: 220)
        let origin = ScrollingCaptureProgressOverlay.frameOrigin(
            avoiding: viewport, on: display, visibleFrame: display.overlayFrame, panelSize: panelSize
        )
        let panel = CGRect(origin: origin, size: panelSize)

        XCTAssertTrue(display.overlayFrame.contains(panel))
        XCTAssertFalse(panel.intersects(display.captureDisplayTransform.overlayGlobalRect(fromCaptureGlobalRect: viewport)))
    }

    func testCaptureDeniesBeforeResolvingDriverWhenAccessibilityPermissionMissing() async {
        let deniedPermissions = TestCapturePermissionService(
            status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false)
        )
        let service = ScrollingCaptureService(
            captureService: ScreenCaptureService(permissions: deniedPermissions),
            permissions: deniedPermissions,
            driverFactory: { _ in
                XCTFail("Accessibility preflight should fail before creating a scroll driver.")
                throw ScrollingCaptureError.noScrollableTarget
            }
        )

        do {
            _ = try await service.capture(
                request: ScrollingCaptureRequest(viewportRect: CGRect(x: 0, y: 0, width: 120, height: 120)),
                cancellation: ScrollingCaptureCancellation()
            )
            XCTFail("Expected scrolling capture to fail without Accessibility permission.")
        } catch ScrollingCaptureError.accessibilityPermissionDenied {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testChangedFramesAreStitchedWhenReportedScrollPositionStalls() async throws {
        let driver = ScrollingTestDriver(reportedPosition: 0)
        let frames = [0, 60, 65, 65].map { offset in
            makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + offset })
        }

        let result = try await captureFrames(frames, driver: driver)

        assertScrollingRows(in: result.image, expectedHeight: 145)
        XCTAssertEqual(driver.scrollDistances, [60, 60, 60])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testLowConfidenceRetryRestoresLastAcceptedPositionBeforeSmallerScroll() async throws {
        let driver = ScrollingTestDriver(reportedPosition: 0)
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let mismatch = makeSolidImage(width: 48, height: 80, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        let retry = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + 36 })
        let last = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + 96 })

        let result = try await captureFrames([first, mismatch, retry, last, last], driver: driver)

        assertScrollingRows(in: result.image, expectedHeight: 176)
        XCTAssertEqual(driver.restoredPositions, [0])
        XCTAssertEqual(driver.scrollDistances, [60, 36, 60, 60])
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testRetryWithoutScrollPositionRecapturesWithoutMovingAboveAcceptedContent() async throws {
        let driver = ScrollingTestDriver(reportedPosition: nil)
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let mismatch = makeSolidImage(width: 48, height: 80, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        let last = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + 50 })

        let result = try await captureFrames([first, mismatch, last, last], driver: driver)

        assertScrollingRows(in: result.image, expectedHeight: 130)
        XCTAssertTrue(driver.restoredPositions.isEmpty)
        XCTAssertEqual(driver.scrollDistances, [60, 60])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testHeightLimitAppliesToFirstFrameWithoutScrolling() async throws {
        let driver = ScrollingTestDriver(reportedPosition: 0)
        let frame = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })

        let result = try await captureFrames([frame], driver: driver, maxOutputHeight: 40)

        assertScrollingRows(in: result.image, expectedHeight: 40)
        XCTAssertTrue(driver.scrollDistances.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("maximum output height"))
    }

    func testSegmentLimitWarnsThatCaptureStoppedEarly() async throws {
        let driver = ScrollingTestDriver(reportedPosition: nil)
        let frames = [0, 60].map { offset in
            makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + offset })
        }

        let result = try await captureFrames(frames, driver: driver, maxSegmentCount: 2)

        assertScrollingRows(in: result.image, expectedHeight: 140)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("maximum number of segments"))
    }

    func testTaskCancellationDuringScrollWaitDoesNotOfferPartialResult() async throws {
        let frame = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let scheduler = ScrollingTestScheduler { delay in
            if delay == 220_000_000 { throw CancellationError() }
        }

        do {
            _ = try await captureFrames([frame], driver: ScrollingTestDriver(reportedPosition: nil), scheduler: scheduler)
            XCTFail("Expected cancellation")
        } catch ScrollingCaptureError.cancelled {
        }
    }

    func testCancellationDuringDuplicateCaptureDoesNotReturnSuccess() async throws {
        let cancellation = ScrollingCaptureCancellation()
        let frame = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })

        do {
            _ = try await captureFrames(
                [frame, frame], driver: ScrollingTestDriver(reportedPosition: nil), cancellation: cancellation,
                onCapture: { if $0 == 1 { cancellation.cancel() } }
            )
            XCTFail("Expected cancellation")
        } catch ScrollingCaptureError.cancelled {
        }
    }

    func testCancellationDuringRetryCaptureDoesNotReturnSuccess() async throws {
        let cancellation = ScrollingCaptureCancellation()
        let frame = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let mismatch = makeSolidImage(width: 48, height: 80, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))

        do {
            _ = try await captureFrames(
                [frame, mismatch, frame], driver: ScrollingTestDriver(reportedPosition: 0), cancellation: cancellation,
                onCapture: { if $0 == 2 { cancellation.cancel() } }
            )
            XCTFail("Expected cancellation")
        } catch ScrollingCaptureError.cancelled {
        }
    }

    func testDoneDuringRetryKeepsOnlyAcceptedContent() async throws {
        let cancellation = ScrollingCaptureCancellation()
        let first = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 })
        let mismatch = makeSolidImage(width: 48, height: 80, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        let retry = makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + 36 })

        let result = try await captureFrames(
            [first, mismatch, retry], driver: ScrollingTestDriver(reportedPosition: 0), cancellation: cancellation,
            onCapture: { if $0 == 2 { cancellation.finish() } }
        )

        assertScrollingRows(in: result.image, expectedHeight: 80)
    }

    func testCancellationFromFinalProgressDoesNotReturnSuccess() async throws {
        let cancellation = ScrollingCaptureCancellation()
        let frames = [0, 60].map { offset in
            makeScrollingFrame(width: 48, height: 80, rowMapper: { $0 + offset })
        }

        do {
            _ = try await captureFrames(
                frames, driver: ScrollingTestDriver(reportedPosition: nil), maxSegmentCount: 2,
                cancellation: cancellation, progressHandler: { if $0.segmentCount == 2 { cancellation.cancel() } }
            )
            XCTFail("Expected cancellation")
        } catch ScrollingCaptureError.cancelled {
        }
    }

    private func captureFrames(
        _ images: [CGImage], driver: ScrollingTestDriver,
        maxSegmentCount: Int = 10, maxOutputHeight: Int = 60_000,
        cancellation: ScrollingCaptureCancellation = ScrollingCaptureCancellation(),
        scheduler: any Scheduling = ScrollingTestScheduler(),
        onCapture: @escaping @Sendable (Int) throws -> Void = { _ in },
        progressHandler: (@MainActor (ScrollingCaptureProgress) -> Void)? = nil
    ) async throws -> ScrollingCaptureResult {
        // The final frame remains visible for the no-movement confirmation.
        let frames = ScrollingTestFrames(images + Array(images.suffix(1)), onCapture: onCapture)
        let permissions = TestCapturePermissionService()
        let platform = TestScreenCapturePlatform(
            content: ScreenContentSnapshot(
                displays: [DisplaySnapshot(displayID: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 48, height: 80), scale: 1)],
                windows: [], applications: []
            ),
            imageProvider: { _ in try frames.next() }
        )
        let captureService = ScreenCaptureService(
            permissions: permissions, platform: platform, workspace: TestWorkspaceService(),
            screens: TestScreenTopologyService(), mouse: TestMouseLocationService(),
            windowFocus: TestApplicationWindowFocusService(), clock: TestClock()
        )
        let service = ScrollingCaptureService(
            captureService: captureService, permissions: permissions,
            scheduler: scheduler, clock: TestClock(), driverFactory: { _ in driver }
        )
        // Exercise the production loop without moving the system cursor or
        // resolving a real app, display, Accessibility target, or capture device.
        return try await service.captureLoop(
            request: ScrollingCaptureRequest(
                viewportRect: CGRect(x: 0, y: 0, width: 48, height: 80),
                maxSegmentCount: maxSegmentCount, maxOutputHeight: maxOutputHeight
            ),
            sourceName: driver.sourceName, driver: driver,
            cancellation: cancellation, progressHandler: progressHandler
        )
    }
}

private struct ScrollingTestScheduler: Scheduling {
    var onSleep: @Sendable (UInt64) throws -> Void = { _ in }
    func sleep(nanoseconds: UInt64) async throws { try onSleep(nanoseconds) }
}

private final class ScrollingHitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CGPoint] = []
    var points: [CGPoint] { lock.withLock { recorded } }
    func record(_ point: CGPoint) { lock.withLock { recorded.append(point) } }
}

private final class ScrollingTestFrames: @unchecked Sendable {
    private let lock = NSLock()
    private let images: [CGImage]
    private var index = 0
    private let onCapture: @Sendable (Int) throws -> Void

    init(_ images: [CGImage], onCapture: @escaping @Sendable (Int) throws -> Void) {
        self.images = images
        self.onCapture = onCapture
    }

    func next() throws -> CGImage {
        try lock.withLock {
            guard index < images.count else { throw ScrollingCaptureError.firstFrameUnavailable }
            try onCapture(index)
            defer { index += 1 }
            return images[index]
        }
    }
}

final class ScreenCaptureServiceTests: XCTestCase {
    func testListWindowsDeniesBeforeFetchingSystemContentWhenScreenRecordingPermissionMissing() async {
        let service = ScreenCaptureService(
            permissions: TestCapturePermissionService(
                status: CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: true)
            )
        )

        do {
            _ = try await service.listWindows(includeThumbnails: false)
            XCTFail("Expected window listing to fail without Screen Recording permission.")
        } catch ScreenCaptureError.permissionDenied {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRepairTransparentArtifactRowsReplacesIsolatedTransparentRow() {
        let service = ScreenCaptureService()
        let image = makeImageWithTransparentRows(width: 16, height: 8, transparentRows: [3])

        let repaired = service.repairTransparentArtifactRows(in: image)

        XCTAssertEqual(
            samplePixel(in: repaired, topLeftX: 6, topLeftY: 3),
            samplePixel(in: repaired, topLeftX: 6, topLeftY: 2)
        )
    }

    func testRepairTransparentArtifactRowsLeavesOpaqueImageUnchanged() {
        let service = ScreenCaptureService()
        let image = makeCoordinateImage(
            width: 16,
            height: 8,
            pattern: .weighted(xMultiplier: 9, yMultiplier: 13, includeBlueSum: true)
        )

        let repaired = service.repairTransparentArtifactRows(in: image)

        XCTAssertEqual(samplePixel(in: repaired, topLeftX: 4, topLeftY: 5), samplePixel(in: image, topLeftX: 4, topLeftY: 5))
    }

    func testDirectDisplayCaptureRequestUsesDisplayLocalCrop() {
        let service = ScreenCaptureService()
        let displays = [
            DisplaySnapshot(
                displayID: 7,
                name: "Display",
                frame: CGRect(x: 100, y: 200, width: 1440, height: 900),
                scale: 2
            )
        ]

        let request = service.directDisplayCaptureRequest(
            for: CGRect(x: 140, y: 260, width: 320, height: 180),
            displays: displays
        )

        XCTAssertEqual(
            request,
            DirectDisplayCaptureRequest(
                displayID: 7,
                sourceRect: DisplayLocalRect(CGRect(x: 40, y: 60, width: 320, height: 180)),
                outputSize: CGSize(width: 640, height: 360)
            )
        )
    }

    func testDirectDisplayCaptureRequestReturnsNilWhenRegionSpansDisplays() {
        let service = ScreenCaptureService()
        let displays = [
            DisplaySnapshot(
                displayID: 1,
                name: "Left",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                scale: 2
            ),
            DisplaySnapshot(
                displayID: 2,
                name: "Right",
                frame: CGRect(x: 800, y: 0, width: 800, height: 600),
                scale: 2
            )
        ]

        let request = service.directDisplayCaptureRequest(
            for: CGRect(x: 760, y: 100, width: 120, height: 200),
            displays: displays
        )

        XCTAssertNil(request)
    }

    func testRegionCapturePlanAllowsStillScreenshotAcrossDisplays() {
        let displays = [
            DisplaySnapshot(displayID: 1, name: "Left", frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1),
            DisplaySnapshot(displayID: 2, name: "Right", frame: CGRect(x: 800, y: 0, width: 800, height: 600), scale: 2)
        ]
        let region = CGRect(x: 760, y: 100, width: 120, height: 200)

        XCTAssertEqual(
            ScreenCaptureService().regionCapturePlan(for: region, displays: displays, requiresSingleDisplay: false),
            .screenRect(rect: region, scale: 2)
        )
        XCTAssertEqual(
            ScreenCaptureService().regionCapturePlan(for: region, displays: displays, requiresSingleDisplay: true),
            .rejectedSingleDisplay
        )
    }

    func testDirectDisplayCaptureRequestUsesTopLeftOffsetOnDisplayBelowPrimary() {
        let service = ScreenCaptureService()
        // Secondary monitor below primary (negative y), region slightly bleeds into primary (y > 0).
        let displays = [
            DisplaySnapshot(
                displayID: 1,
                name: "Primary",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                scale: 2
            ),
            DisplaySnapshot(
                displayID: 2,
                name: "Secondary",
                frame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
                scale: 2
            )
        ]

        let request = service.directDisplayCaptureRequest(
            for: CGRect(x: -1716, y: -447, width: 1198, height: 400),
            displays: displays
        )

        XCTAssertEqual(request?.displayID, 2)
        XCTAssertEqual(request?.sourceRect, DisplayLocalRect(CGRect(x: 204, y: 633, width: 1198, height: 400)))
    }
}

private func makeImageWithTransparentRows(width: Int, height: Int, transparentRows: Set<Int>) -> CGImage {
    makeRGBAImage(
        width: width,
        height: height,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        pixelAt: { x, y in
            let alpha: UInt8 = transparentRows.contains(y) ? 0 : 255
            return PixelSample(
                red: alpha == 0 ? 0 : UInt8((x * 17) % 255),
                green: alpha == 0 ? 0 : UInt8((y * 29) % 255),
                blue: alpha == 0 ? 0 : UInt8((x + y * 3) % 255),
                alpha: alpha
            )
        }
    )
}
