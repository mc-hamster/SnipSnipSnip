import CoreGraphics
import ImageIO
import XCTest
@testable import SnipSnipSnip

final class EditorRendererTests: XCTestCase {
    func testDisplayBaseImageReturnsCroppedBasePixels() {
        let image = makeCoordinateImage(width: 60, height: 40)
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 10, y: 8, width: 24, height: 16))

        guard
            let displayed = EditorRenderer.displayBaseImage(baseImage: image, snapshot: snapshot),
            let rendered = EditorRenderer.render(baseImage: image, snapshot: snapshot)
        else {
            return XCTFail("Expected a cropped display base image")
        }

        XCTAssertEqual(displayed.width, 24)
        XCTAssertEqual(displayed.height, 16)
        assertPixel(
            samplePixel(in: displayed, topLeftX: 5, topLeftY: 4),
            isCloseTo: samplePixel(in: rendered, topLeftX: 5, topLeftY: 4),
            tolerance: 0
        )
    }

    func testRenderIncludesPinnedUIMapOverlay() {
        let image = makeSolidImage(width: 80, height: 60, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        let element = UIMapElement(
            name: "Details",
            role: "AXButton",
            roleDescription: "Button",
            documentRect: CGRect(x: 20, y: 15, width: 30, height: 20),
            owningApplication: "Fixture"
        )

        guard let rendered = EditorRenderer.render(
            baseImage: image,
            snapshot: makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 80, height: 60)),
            pinnedUIMapElements: [element],
            uiMapOverlayOptions: UIMapOverlayOptions(showsOutline: true, showsLabel: false)
        ) else {
            return XCTFail("Expected a rendered image")
        }

        let overlayPixel = samplePixel(in: rendered, topLeftX: 25, topLeftY: 20)
        XCTAssertGreaterThan(Int(overlayPixel.blue), Int(overlayPixel.red))
        XCTAssertLessThan(Int(overlayPixel.red), 255)
    }

    func testRenderCropUsesTopLeftDocumentCoordinatesWithoutVerticalMirroring() {
        let image = makeCoordinateImage(
            width: 120,
            height: 80,
            pattern: .weighted(xMultiplier: 1, yMultiplier: 13, includeBlueSum: false)
        )
        let cropRect = CGRect(x: 16, y: 48, width: 28, height: 14)

        guard let rendered = EditorRenderer.render(
            baseImage: image,
            snapshot: makeEditorSnapshot(cropRect: cropRect)
        ) else {
            return XCTFail("Expected a rendered cropped image")
        }

        let localPoint = CGPoint(x: 7, y: 4)
        let renderedPixel = samplePixel(in: rendered, topLeftX: Int(localPoint.x), topLeftY: Int(localPoint.y))
        let expectedPixel = samplePixel(
            in: image,
            topLeftX: Int(cropRect.minX + localPoint.x),
            topLeftY: Int(cropRect.minY + localPoint.y)
        )
        let mirroredPixel = samplePixel(
            in: image,
            topLeftX: Int(cropRect.minX + localPoint.x),
            topLeftY: image.height - 1 - Int(cropRect.minY + localPoint.y)
        )

        XCTAssertEqual(rendered.width, Int(cropRect.width))
        XCTAssertEqual(rendered.height, Int(cropRect.height))
        XCTAssertLessThan(colorDistance(renderedPixel, expectedPixel), colorDistance(renderedPixel, mirroredPixel))
    }

    func testScaledForDisplayScalesStrokeAndFontButKeepsEffectRadius() {
        let style = AnnotationStyle(
            strokeColor: .arrowStroke,
            fillColor: .textBackground,
            lineWidth: 5,
            fontSize: 24,
            effectRadius: 18
        )

        let scaled = style.scaledForDisplay(by: 2.5)

        XCTAssertEqual(scaled.strokeColor, style.strokeColor)
        XCTAssertEqual(scaled.fillColor, style.fillColor)
        XCTAssertEqual(scaled.lineWidth, 12.5, accuracy: 0.001)
        XCTAssertEqual(scaled.fontSize, 60, accuracy: 0.001)
        XCTAssertEqual(scaled.effectRadius, 18, accuracy: 0.001)
    }

    func testArrowHeadLengthGrowsWithLineWidth() {
        let thinHead = EditorRenderer.arrowHeadLength(bodyLength: 120, lineWidth: 4, scale: 1)
        let thickHead = EditorRenderer.arrowHeadLength(bodyLength: 120, lineWidth: 10, scale: 1)

        XCTAssertGreaterThan(thickHead, thinHead)
    }

    func testArrowHeadLengthGrowsWithArrowBodyLength() {
        let shortHead = EditorRenderer.arrowHeadLength(bodyLength: 40, lineWidth: 5, scale: 1)
        let longHead = EditorRenderer.arrowHeadLength(bodyLength: 160, lineWidth: 5, scale: 1)

        XCTAssertGreaterThan(longHead, shortHead)
    }

    func testCurvedArrowHeadGeometryScalesWithZoomedPreview() {
        let base = EditorRenderer.arrowHeadPoints(
            tip: CGPoint(x: 120, y: 60),
            tail: CGPoint(x: 20, y: 20),
            curvature: 36,
            lineWidth: 5,
            scale: 1
        )
        let zoomed = EditorRenderer.arrowHeadPoints(
            tip: CGPoint(x: 240, y: 120),
            tail: CGPoint(x: 40, y: 40),
            curvature: 72,
            lineWidth: 10,
            scale: 2
        )

        XCTAssertEqual(zoomed.left.x, base.left.x * 2, accuracy: 0.001)
        XCTAssertEqual(zoomed.left.y, base.left.y * 2, accuracy: 0.001)
        XCTAssertEqual(zoomed.right.x, base.right.x * 2, accuracy: 0.001)
        XCTAssertEqual(zoomed.right.y, base.right.y * 2, accuracy: 0.001)
    }

    func testSolidRedactionFillsRenderedRegion() {
        let image = makeCoordinateImage(width: 60, height: 40)
        let annotation = Annotation.makeSolidRedaction(in: CGRect(x: 10, y: 8, width: 24, height: 16))

        guard let rendered = EditorRenderer.render(
            baseImage: image,
            snapshot: makeEditorSnapshot(cropRect: CGRect(origin: .zero, size: CGSize(width: 60, height: 40)), annotations: [annotation])
        ) else {
            return XCTFail("Expected a rendered image")
        }

        assertPixel(
            samplePixel(in: rendered, topLeftX: 20, topLeftY: 16),
            isCloseTo: pixelSample(for: .redactionFill),
            tolerance: 4
        )
    }

    func testSpotlightDimsOutsideRegionAndPreservesInsideRegion() {
        let image = makeCoordinateImage(width: 80, height: 60)
        var style = AnnotationStyle.default(for: .spotlight)
        style.fillColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
        style.strokeColor = .clear
        style.lineWidth = 0
        style.effectRadius = 70
        let annotation = Annotation.makeSpotlight(in: CGRect(x: 20, y: 15, width: 30, height: 20), style: style)

        guard let rendered = EditorRenderer.render(
            baseImage: image,
            snapshot: makeEditorSnapshot(cropRect: CGRect(origin: .zero, size: CGSize(width: 80, height: 60)), annotations: [annotation])
        ) else {
            return XCTFail("Expected a rendered image")
        }

        let inside = samplePixel(in: rendered, topLeftX: 35, topLeftY: 25)
        let outside = samplePixel(in: rendered, topLeftX: 6, topLeftY: 6)
        XCTAssertEqual(inside, samplePixel(in: image, topLeftX: 35, topLeftY: 25))
        XCTAssertLessThan(outside.red, samplePixel(in: image, topLeftX: 6, topLeftY: 6).red)
        XCTAssertLessThan(outside.green, samplePixel(in: image, topLeftX: 6, topLeftY: 6).green)
    }

    func testRotatedSpotlightStillDimsCanvasCorners() {
        let image = makeCoordinateImage(width: 80, height: 60)
        var style = AnnotationStyle.default(for: .spotlight)
        style.fillColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
        style.strokeColor = .clear
        style.lineWidth = 0
        style.effectRadius = 70
        let annotation = Annotation
            .makeSpotlight(in: CGRect(x: 20, y: 15, width: 30, height: 20), style: style)
            .updatingRotationDegrees(30)

        guard let rendered = EditorRenderer.render(
            baseImage: image,
            snapshot: makeEditorSnapshot(
                cropRect: CGRect(origin: .zero, size: CGSize(width: 80, height: 60)),
                annotations: [annotation]
            )
        ) else {
            return XCTFail("Expected a rendered image")
        }

        let inside = samplePixel(in: rendered, topLeftX: 35, topLeftY: 25)
        XCTAssertEqual(inside, samplePixel(in: image, topLeftX: 35, topLeftY: 25))

        for point in [(3, 3), (76, 3), (3, 56), (76, 56)] {
            let dimmed = samplePixel(in: rendered, topLeftX: point.0, topLeftY: point.1)
            let base = samplePixel(in: image, topLeftX: point.0, topLeftY: point.1)
            XCTAssertLessThan(dimmed.red, base.red, "Expected rotated spotlight to keep (\(point.0), \(point.1)) dimmed")
            XCTAssertLessThan(dimmed.green, base.green, "Expected rotated spotlight to keep (\(point.0), \(point.1)) dimmed")
        }
    }

    func testImageOverlayRendersIntoExportedImage() {
        let image = makeCoordinateImage(width: 80, height: 60)
        let overlay = makeSolidImage(width: 12, height: 12, color: PixelSample(red: 240, green: 20, blue: 10, alpha: 255))
        let annotation = Annotation.makeImageOverlay(image: overlay, in: CGRect(x: 20, y: 16, width: 12, height: 12))

        guard let rendered = EditorRenderer.render(
            baseImage: image,
            snapshot: makeEditorSnapshot(cropRect: CGRect(origin: .zero, size: CGSize(width: 80, height: 60)), annotations: [annotation])
        ) else {
            return XCTFail("Expected a rendered image")
        }

        assertPixel(
            samplePixel(in: rendered, topLeftX: 24, topLeftY: 20),
            isCloseTo: PixelSample(red: 240, green: 20, blue: 10, alpha: 255),
            tolerance: 1
        )
    }

    func testMeasurementRenderingChangesOutputPixels() {
        let image = makeCoordinateImage(width: 80, height: 60)
        let annotation = Annotation.makeMeasurement(
            from: CGPoint(x: 10, y: 12),
            to: CGPoint(x: 60, y: 12),
            style: AnnotationStyle(strokeColor: .measureStroke, fillColor: .textBackground, lineWidth: 4, fontSize: 14, effectRadius: 0)
        )

        guard
            let base = EditorRenderer.render(baseImage: image, snapshot: makeEditorSnapshot(cropRect: CGRect(origin: .zero, size: CGSize(width: 80, height: 60)))),
            let rendered = EditorRenderer.render(baseImage: image, snapshot: makeEditorSnapshot(cropRect: CGRect(origin: .zero, size: CGSize(width: 80, height: 60)), annotations: [annotation]))
        else {
            return XCTFail("Expected rendered images")
        }

        XCTAssertTrue(imagesDiffer(rendered, base, within: CGRect(x: 8, y: 8, width: 56, height: 16)))
    }

    func testHighlighterRenderingTintsUnderlyingPixelsAlongStroke() {
        let image = makeSolidImage(width: 80, height: 60, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        let style = AnnotationStyle.default(for: .highlighter)
        let annotation = Annotation.makeHighlighter(
            points: [CGPoint(x: 12, y: 24), CGPoint(x: 40, y: 24), CGPoint(x: 68, y: 24)],
            style: style
        )

        guard let rendered = EditorRenderer.render(
            baseImage: image,
            snapshot: makeEditorSnapshot(
                cropRect: CGRect(origin: .zero, size: CGSize(width: 80, height: 60)),
                annotations: [annotation]
            )
        ) else {
            return XCTFail("Expected rendered highlighter image")
        }

        let highlightedPixel = samplePixel(in: rendered, topLeftX: 40, topLeftY: 24)
        let untouchedPixel = samplePixel(in: rendered, topLeftX: 40, topLeftY: 6)

        XCTAssertLessThan(highlightedPixel.blue, untouchedPixel.blue)
        XCTAssertLessThan(highlightedPixel.green, untouchedPixel.green)
        XCTAssertEqual(untouchedPixel, PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
    }

    func testArrowLabelTopRendersAboveHorizontalArrow() {
        let image = makeSolidImage(width: 220, height: 120, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        let annotation = Annotation.makeArrow(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 190, y: 60))
            .updatingArrow(
                label: "Ship",
                labelBoxColor: .highlightFill,
                labelPlacement: .parallelAbove
            )

        guard let rendered = EditorRenderer.render(
            baseImage: image,
            snapshot: makeEditorSnapshot(
                cropRect: CGRect(origin: .zero, size: CGSize(width: 220, height: 120)),
                annotations: [annotation]
            )
        ) else {
            return XCTFail("Expected rendered arrow image")
        }

        let above = samplePixel(in: rendered, topLeftX: 110, topLeftY: 38)
        let below = samplePixel(in: rendered, topLeftX: 110, topLeftY: 82)

        XCTAssertNotEqual(above, PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        XCTAssertEqual(below, PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
    }

    func testExportEncodersStripImageMetadataDictionaries() throws {
        let image = makeCoordinateImage(width: 16, height: 12)

        for data in [try ImageExporter.pngData(for: image), try ImageExporter.jpegData(for: image)] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])

            XCTAssertNil(userMetadataDictionary(properties[kCGImagePropertyExifDictionary]))
            XCTAssertNil(nonEmptyMetadataDictionary(properties[kCGImagePropertyGPSDictionary]))
            XCTAssertNil(userMetadataDictionary(properties[kCGImagePropertyTIFFDictionary]))
            XCTAssertNil(nonEmptyMetadataDictionary(properties[kCGImagePropertyIPTCDictionary]))
        }

        let pdfData = try ImageExporter.pdfData(for: image)
        XCTAssertFalse(String(data: pdfData, encoding: .isoLatin1)?.contains("/GPS") ?? true)
        XCTAssertFalse(String(data: pdfData, encoding: .isoLatin1)?.contains("/Exif") ?? true)
    }

    func testTransparentPresentationShadowProducesAlphaOutputAndLargerCanvas() {
        let image = makeSolidImage(width: 80, height: 60, color: PixelSample(red: 240, green: 240, blue: 240, alpha: 255))
        let presentation = ScreenshotPresentationPreset.transparentShadow.settings
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(origin: .zero, size: CGSize(width: 80, height: 60)),
            presentation: presentation
        )

        guard let rendered = ScreenshotPresentationRenderer.render(baseImage: image, snapshot: snapshot) else {
            return XCTFail("Expected a presented render")
        }

        XCTAssertGreaterThan(rendered.width, image.width)
        XCTAssertGreaterThan(rendered.height, image.height)
        XCTAssertEqual(samplePixel(in: rendered, topLeftX: 0, topLeftY: 0).alpha, 0)

        let contentMinX = Int(presentation.totalInsets.left)
        let contentMaxX = contentMinX + image.width - 1
        let contentMinY = Int(presentation.totalInsets.top)
        let contentMaxY = contentMinY + image.height - 1

        var foundShadow = false
        for y in stride(from: 0, to: rendered.height, by: 6) {
            for x in stride(from: 0, to: rendered.width, by: 6) {
                let isOutsideContent = x < contentMinX || x > contentMaxX || y < contentMinY || y > contentMaxY
                guard isOutsideContent else {
                    continue
                }

                let sample = samplePixel(in: rendered, topLeftX: x, topLeftY: y)
                if sample.alpha > 0 {
                    foundShadow = true
                    break
                }
            }

            if foundShadow {
                break
            }
        }

        XCTAssertTrue(foundShadow, "Expected transparent presentation to include shadow pixels outside the screenshot bounds")
    }

    func testPresentationRenderedImageWritesToPNGFile() async throws {
        let image = makeSolidImage(width: 80, height: 60, color: PixelSample(red: 240, green: 240, blue: 240, alpha: 255))
        let presentation = ScreenshotPresentationPreset.transparentShadow.settings
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(origin: .zero, size: CGSize(width: 80, height: 60)),
            presentation: presentation
        )

        let rendered = try XCTUnwrap(
            ScreenshotPresentationRenderer.render(baseImage: image, snapshot: snapshot),
            "Expected a presented render"
        )

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try await ImageExporter.write(rendered, format: .png, to: outputURL)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        XCTAssertEqual(decoded.width, rendered.width)
        XCTAssertEqual(decoded.height, rendered.height)
        XCTAssertEqual(samplePixel(in: decoded, topLeftX: 0, topLeftY: 0).alpha, 0)
    }

    func testPresentationShadowStylesIncreaseVisibleDepth() {
        let image = makeSolidImage(width: 80, height: 60, color: PixelSample(red: 244, green: 244, blue: 244, alpha: 255))

        let shadowFootprints = [ScreenshotShadowStyle.soft, .medium, .strong].map { style in
            let presentation = ScreenshotPresentation(
                isEnabled: true,
                background: .transparent,
                padding: 24,
                cornerRadius: 12,
                shadow: style
            )

            guard let rendered = ScreenshotPresentationRenderer.render(contentImage: image, presentation: presentation) else {
                XCTFail("Expected a presented image for \(style.rawValue)")
                return 0
            }

            return outsideShadowPixelCount(in: rendered, contentSize: CGSize(width: image.width, height: image.height), presentation: presentation)
        }

        XCTAssertGreaterThan(shadowFootprints[1], shadowFootprints[0])
        XCTAssertGreaterThan(shadowFootprints[2], shadowFootprints[1])
    }

    func testPresentationShadowInsetsFollowDirection() {
        let bottomRight = ScreenshotPresentation(
            isEnabled: true,
            background: .transparent,
            padding: 20,
            cornerRadius: 12,
            shadow: .strong,
            shadowBlurRadius: 32,
            shadowOffsetX: 28,
            shadowOffsetY: 30,
            shadowOpacity: 0.5
        )
        let topLeft = ScreenshotPresentation(
            isEnabled: true,
            background: .transparent,
            padding: 20,
            cornerRadius: 12,
            shadow: .strong,
            shadowBlurRadius: 32,
            shadowOffsetX: -28,
            shadowOffsetY: -30,
            shadowOpacity: 0.5
        )

        XCTAssertGreaterThan(bottomRight.shadowInsets.right, bottomRight.shadowInsets.left)
        XCTAssertGreaterThan(bottomRight.shadowInsets.bottom, bottomRight.shadowInsets.top)
        XCTAssertGreaterThan(topLeft.shadowInsets.left, topLeft.shadowInsets.right)
        XCTAssertGreaterThan(topLeft.shadowInsets.top, topLeft.shadowInsets.bottom)
    }

    func testDropShadowCastsNeutralSilhouetteToBottomRight() {
        let image = makeSolidImage(width: 80, height: 60, color: PixelSample(red: 244, green: 244, blue: 244, alpha: 255))
        let presentation = ScreenshotPresentation(
            isEnabled: true,
            background: .transparent,
            padding: 0,
            cornerRadius: 0,
            shadow: .drop
        )

        guard let rendered = ScreenshotPresentationRenderer.render(contentImage: image, presentation: presentation) else {
            return XCTFail("Expected a presented image")
        }

        let contentMinX = Int(presentation.totalInsets.left)
        let contentMaxX = contentMinX + image.width - 1
        let contentMinY = Int(presentation.totalInsets.top)
        let contentMaxY = contentMinY + image.height - 1
        let leftAlpha = alphaTotal(in: rendered, xRange: 0..<contentMinX, yRange: 0..<rendered.height)
        let rightAlpha = alphaTotal(in: rendered, xRange: (contentMaxX + 1)..<rendered.width, yRange: 0..<rendered.height)
        let topAlpha = alphaTotal(in: rendered, xRange: 0..<rendered.width, yRange: 0..<contentMinY)
        let bottomAlpha = alphaTotal(in: rendered, xRange: 0..<rendered.width, yRange: (contentMaxY + 1)..<rendered.height)
        let shadowSample = samplePixel(in: rendered, topLeftX: min(contentMaxX + 8, rendered.width - 1), topLeftY: min(contentMaxY + 8, rendered.height - 1))

        XCTAssertGreaterThan(rightAlpha, leftAlpha)
        XCTAssertGreaterThan(bottomAlpha, topAlpha)
        XCTAssertEqual(shadowSample.red, shadowSample.green)
        XCTAssertEqual(shadowSample.green, shadowSample.blue)
        XCTAssertGreaterThan(shadowSample.alpha, 0)
    }

    func testLiftedPresentationBackgroundIsNotFlatFill() {
        let image = makeSolidImage(width: 24, height: 16, color: PixelSample(red: 36, green: 41, blue: 49, alpha: 255))
        let presentation = ScreenshotPresentationPreset.lifted.settings

        guard let rendered = ScreenshotPresentationRenderer.render(contentImage: image, presentation: presentation) else {
            return XCTFail("Expected a presented image")
        }

        let topBackground = samplePixel(in: rendered, topLeftX: 6, topLeftY: 6)
        let bottomBackground = samplePixel(in: rendered, topLeftX: 6, topLeftY: rendered.height - 7)

        XCTAssertEqual(topBackground.alpha, 255)
        XCTAssertEqual(bottomBackground.alpha, 255)
        XCTAssertGreaterThan(colorDistance(topBackground, bottomBackground), 12)
    }

    func testBlurRedactionSamplesCompositedContentBelowIt() {
        let image = makeCoordinateImage(width: 60, height: 40)
        let overlay = Annotation.makeRectangle(
            in: CGRect(x: 8, y: 8, width: 14, height: 14),
            style: AnnotationStyle(
                strokeColor: .clear,
                fillColor: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
                lineWidth: 0,
                fontSize: 0,
                effectRadius: 0
            )
        )
        var blurStyle = AnnotationStyle.default(for: .blur)
        blurStyle.effectRadius = 8
        let blur = Annotation.makeBlur(in: CGRect(x: 14, y: 14, width: 14, height: 14), style: blurStyle)

        guard
            let baseBlurred = EditorRenderer.render(baseImage: image, snapshot: makeEditorSnapshot(cropRect: CGRect(origin: .zero, size: CGSize(width: 60, height: 40)), annotations: [blur])),
            let overlayBlurred = EditorRenderer.render(baseImage: image, snapshot: makeEditorSnapshot(cropRect: CGRect(origin: .zero, size: CGSize(width: 60, height: 40)), annotations: [overlay, blur]))
        else {
            return XCTFail("Expected rendered images")
        }

        XCTAssertTrue(
            pixelsDiffer(
                overlayBlurred,
                baseBlurred,
                samplePoints: [(18, 18), (20, 18), (18, 20), (20, 20), (22, 22)]
            )
        )
    }

    func testPixelateRedactionSamplesCompositedContentBelowIt() {
        let image = makeCoordinateImage(width: 60, height: 40)
        let overlay = Annotation.makeRectangle(
            in: CGRect(x: 8, y: 8, width: 14, height: 14),
            style: AnnotationStyle(
                strokeColor: .clear,
                fillColor: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1),
                lineWidth: 0,
                fontSize: 0,
                effectRadius: 0
            )
        )
        var pixelateStyle = AnnotationStyle.default(for: .pixelate)
        pixelateStyle.effectRadius = 6
        let pixelate = Annotation.makePixelate(in: CGRect(x: 14, y: 14, width: 14, height: 14), style: pixelateStyle)

        guard
            let basePixelated = EditorRenderer.render(baseImage: image, snapshot: makeEditorSnapshot(cropRect: CGRect(origin: .zero, size: CGSize(width: 60, height: 40)), annotations: [pixelate])),
            let overlayPixelated = EditorRenderer.render(baseImage: image, snapshot: makeEditorSnapshot(cropRect: CGRect(origin: .zero, size: CGSize(width: 60, height: 40)), annotations: [overlay, pixelate]))
        else {
            return XCTFail("Expected rendered images")
        }

        XCTAssertTrue(imagesDiffer(overlayPixelated, basePixelated, within: CGRect(x: 14, y: 14, width: 14, height: 14)))
    }

    func testBlurRedactionWithZeroRadiusSamplesFromExpectedRowNotMirroredRow() {
        let image = makeCoordinateImage(
            width: 120,
            height: 80,
            pattern: .weighted(xMultiplier: 1, yMultiplier: 13, includeBlueSum: false)
        )
        let rect = CGRect(x: 16, y: 10, width: 32, height: 18)
        var style = AnnotationStyle.default(for: .blur)
        style.effectRadius = 0
        style.lineWidth = 0
        let annotation = Annotation.makeBlur(in: rect, style: style)

        guard let rendered = EditorRenderer.render(
            baseImage: image,
            snapshot: makeEditorSnapshot(
                cropRect: CGRect(origin: .zero, size: CGSize(width: 120, height: 80)),
                annotations: [annotation]
            )
        ) else {
            return XCTFail("Expected a rendered image")
        }

        let sampleX = Int(rect.midX)
        let sampleY = Int(rect.midY)
        let renderedPixel = samplePixel(in: rendered, topLeftX: sampleX, topLeftY: sampleY)
        let expectedPixel = samplePixel(in: image, topLeftX: sampleX, topLeftY: sampleY)
        let mirroredPixel = samplePixel(in: image, topLeftX: sampleX, topLeftY: image.height - 1 - sampleY)

        XCTAssertLessThan(
            colorDistance(renderedPixel, expectedPixel),
            colorDistance(renderedPixel, mirroredPixel)
        )
    }

    func testBlurRedactionProcessingWithZeroRadiusSamplesFromExpectedRowNotMirroredRow() {
        let image = makeCoordinateImage(
            width: 200,
            height: 200,
            pattern: .weighted(xMultiplier: 1, yMultiplier: 13, includeBlueSum: false)
        )
        let rect = CGRect(x: 48, y: 136, width: 32, height: 18)

        guard let rendered = EditorRenderer.debugMakeBlurredRedactionImage(in: rect, sourceImage: image, radius: 0) else {
            return XCTFail("Expected a rendered image")
        }

        let renderedPixel = samplePixel(in: rendered, topLeftX: Int(rect.width / 2), topLeftY: Int(rect.height / 2))
        let expectedPixel = samplePixel(in: image, topLeftX: Int(rect.midX), topLeftY: Int(rect.midY))
        let mirroredPixel = samplePixel(in: image, topLeftX: Int(rect.midX), topLeftY: image.height - 1 - Int(rect.midY))

        XCTAssertLessThan(
            colorDistance(renderedPixel, expectedPixel),
            colorDistance(renderedPixel, mirroredPixel)
        )
    }

    func testRenderPerformanceDenseAnnotationScene() {
        let canvasSize = CGSize(width: 2560, height: 1440)
        let cropRect = CGRect(origin: .zero, size: canvasSize)
        let baseImage = makeCoordinateImage(
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            pattern: .weighted(xMultiplier: 9, yMultiplier: 17, includeBlueSum: true)
        )
        let snapshot = makeEditorSnapshot(
            cropRect: cropRect,
            annotations: makeDensePerformanceAnnotations(in: cropRect, count: 240)
        )
        let options = XCTMeasureOptions.default
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            let rendered = EditorRenderer.render(baseImage: baseImage, snapshot: snapshot)
            XCTAssertNotNil(rendered)
        }
    }

    func testRenderPerformanceCommonAnnotationScene() {
        let canvasSize = CGSize(width: 1920, height: 1080)
        let cropRect = CGRect(origin: .zero, size: canvasSize)
        let baseImage = makeCoordinateImage(
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            pattern: .weighted(xMultiplier: 5, yMultiplier: 11, includeBlueSum: true)
        )
        let snapshot = makeEditorSnapshot(
            cropRect: cropRect,
            annotations: makeCommonPerformanceAnnotations(in: cropRect, count: 56)
        )
        let options = XCTMeasureOptions.default
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            let rendered = EditorRenderer.render(baseImage: baseImage, snapshot: snapshot)
            XCTAssertNotNil(rendered)
        }
    }


    private func assertPixel(_ actual: PixelSample, isCloseTo expected: PixelSample, tolerance: Int) {
        XCTAssertLessThanOrEqual(abs(Int(actual.red) - Int(expected.red)), tolerance)
        XCTAssertLessThanOrEqual(abs(Int(actual.green) - Int(expected.green)), tolerance)
        XCTAssertLessThanOrEqual(abs(Int(actual.blue) - Int(expected.blue)), tolerance)
        XCTAssertEqual(actual.alpha, expected.alpha)
    }

    private func pixelsDiffer(_ lhs: CGImage, _ rhs: CGImage, samplePoints: [(Int, Int)]) -> Bool {
        samplePoints.contains { point in
            samplePixel(in: lhs, topLeftX: point.0, topLeftY: point.1) != samplePixel(in: rhs, topLeftX: point.0, topLeftY: point.1)
        }
    }

    private func imagesDiffer(_ lhs: CGImage, _ rhs: CGImage, within rect: CGRect) -> Bool {
        let bounds = rect.gscIntegralStandardized.intersection(
            CGRect(x: 0, y: 0, width: min(lhs.width, rhs.width), height: min(lhs.height, rhs.height))
        )

        guard bounds.width > 0, bounds.height > 0 else {
            return false
        }

        for y in Int(bounds.minY)..<Int(bounds.maxY) {
            for x in Int(bounds.minX)..<Int(bounds.maxX) {
                if samplePixel(in: lhs, topLeftX: x, topLeftY: y) != samplePixel(in: rhs, topLeftX: x, topLeftY: y) {
                    return true
                }
            }
        }

        return false
    }

    private func colorDistance(_ lhs: PixelSample, _ rhs: PixelSample) -> Int {
        abs(Int(lhs.red) - Int(rhs.red))
            + abs(Int(lhs.green) - Int(rhs.green))
            + abs(Int(lhs.blue) - Int(rhs.blue))
    }

    private func outsideShadowPixelCount(
        in image: CGImage,
        contentSize: CGSize,
        presentation: ScreenshotPresentation
    ) -> Int {
        let contentMinX = Int(presentation.totalInsets.left)
        let contentMaxX = contentMinX + Int(contentSize.width) - 1
        let contentMinY = Int(presentation.totalInsets.top)
        let contentMaxY = contentMinY + Int(contentSize.height) - 1
        var shadowPixels = 0

        for y in 0..<image.height {
            for x in 0..<image.width {
                let isOutsideContent = x < contentMinX || x > contentMaxX || y < contentMinY || y > contentMaxY
                guard isOutsideContent else {
                    continue
                }

                if samplePixel(in: image, topLeftX: x, topLeftY: y).alpha > 0 {
                    shadowPixels += 1
                }
            }
        }

        return shadowPixels
    }

    private func alphaTotal(in image: CGImage, xRange: Range<Int>, yRange: Range<Int>) -> Int {
        yRange.reduce(into: 0) { total, y in
            for x in xRange {
                total += Int(samplePixel(in: image, topLeftX: x, topLeftY: y).alpha)
            }
        }
    }

    private func nonEmptyMetadataDictionary(_ value: Any?) -> [AnyHashable: Any]? {
        guard let dictionary = value as? [AnyHashable: Any], !dictionary.isEmpty else {
            return nil
        }

        return dictionary
    }

    private func userMetadataDictionary(_ value: Any?) -> [AnyHashable: Any]? {
        guard let dictionary = value as? [AnyHashable: Any] else {
            return nil
        }

        let userMetadataKeys: Set<String> = [
            kCGImagePropertyExifDateTimeDigitized as String,
            kCGImagePropertyExifDateTimeOriginal as String,
            kCGImagePropertyExifLensMake as String,
            kCGImagePropertyExifLensModel as String,
            kCGImagePropertyExifUserComment as String,
            kCGImagePropertyTIFFArtist as String,
            kCGImagePropertyTIFFCopyright as String,
            kCGImagePropertyTIFFDateTime as String,
            kCGImagePropertyTIFFHostComputer as String,
            kCGImagePropertyTIFFImageDescription as String,
            kCGImagePropertyTIFFMake as String,
            kCGImagePropertyTIFFModel as String,
            kCGImagePropertyTIFFSoftware as String
        ]
        let filtered = dictionary.filter { key, _ in
            userMetadataKeys.contains(String(describing: key))
        }

        return filtered.isEmpty ? nil : filtered
    }

    private func makeDensePerformanceAnnotations(in cropRect: CGRect, count: Int) -> [Annotation] {
        guard count > 0 else {
            return []
        }

        return (0..<count).map { index in
            let x = CGFloat((index * 37) % max(Int(cropRect.width) - 220, 1))
            let y = CGFloat((index * 53) % max(Int(cropRect.height) - 220, 1))
            let rect = CGRect(x: x, y: y, width: 180, height: 120)

            switch index % 8 {
            case 0:
                return Annotation.makeRectangle(in: rect)
            case 1:
                return Annotation.makeEllipse(in: rect)
            case 2:
                return Annotation.makeLine(
                    from: CGPoint(x: rect.minX, y: rect.minY),
                    to: CGPoint(x: rect.maxX, y: rect.maxY)
                )
            case 3:
                return Annotation.makeArrow(
                    from: CGPoint(x: rect.minX, y: rect.midY),
                    to: CGPoint(x: rect.maxX, y: rect.midY)
                )
            case 4:
                return Annotation.makeHighlight(in: rect)
            case 5:
                return Annotation.makeText(at: CGPoint(x: rect.minX + 6, y: rect.minY + 6)).updatingText("Perf \(index)")
            case 6:
                return Annotation.makeCallout(at: CGPoint(x: rect.midX, y: rect.midY), number: (index % 9) + 1)
            default:
                return Annotation.makeBlur(in: rect)
            }
        }
    }

    private func makeCommonPerformanceAnnotations(in cropRect: CGRect, count: Int) -> [Annotation] {
        guard count > 0 else {
            return []
        }

        return (0..<count).map { index in
            let x = CGFloat((index * 61) % max(Int(cropRect.width) - 200, 1))
            let y = CGFloat((index * 43) % max(Int(cropRect.height) - 140, 1))
            let rect = CGRect(x: x, y: y, width: 180, height: 100)

            switch index % 10 {
            case 0:
                return Annotation.makeRectangle(in: rect)
            case 1:
                return Annotation.makeArrow(
                    from: CGPoint(x: rect.minX + 4, y: rect.midY),
                    to: CGPoint(x: rect.maxX - 4, y: rect.midY)
                )
            case 2:
                return Annotation.makeText(at: CGPoint(x: rect.minX + 8, y: rect.minY + 8)).updatingText("Note \(index)")
            case 3:
                return Annotation.makeCallout(at: CGPoint(x: rect.midX, y: rect.midY), number: (index % 9) + 1)
                    .updatingText("Step \(index)")
            case 4:
                return Annotation.makeHighlight(in: rect)
            case 5:
                return Annotation.makeSolidRedaction(in: rect)
            case 6:
                return Annotation.makeSpotlight(in: rect)
            case 7:
                return Annotation.makeBlur(in: rect)
            case 8:
                return Annotation.makeImageOverlay(
                    image: makeSolidImage(
                        width: 32,
                        height: 32,
                        color: PixelSample(red: 220, green: 180, blue: 80, alpha: 255)
                    ),
                    in: CGRect(x: rect.minX + 20, y: rect.minY + 20, width: 32, height: 32)
                )
            default:
                return Annotation.makeMeasurement(
                    from: CGPoint(x: rect.minX + 4, y: rect.maxY - 4),
                    to: CGPoint(x: rect.maxX - 4, y: rect.minY + 4)
                )
            }
        }
    }

}
