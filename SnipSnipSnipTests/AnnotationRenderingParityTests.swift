import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class AnnotationRenderingParityTests: XCTestCase {
    func testBothRotationSignsMatchHitGeometryInPreviewAndCroppedExport() throws {
        let base = makeSolidImage(width: 160, height: 160, color: white)
        let rect = CGRect(x: 45, y: 72, width: 70, height: 16)
        let fill = AnnotationStyle(strokeColor: .clear, fillColor: .redactionFill,
            lineWidth: 0, fontSize: 0, effectRadius: 0)
        var stroke = fill
        stroke.strokeColor = .redactionFill
        stroke.lineWidth = 16
        let blackImage = makeSolidImage(width: 70, height: 16, color: black)
        let annotations = [
            Annotation.makeRectangle(in: rect, style: fill),
            Annotation.makeEllipse(in: rect, style: fill),
            Annotation.makeHighlight(in: rect, style: fill),
            Annotation.makeLine(from: CGPoint(x: 45, y: 80), to: CGPoint(x: 115, y: 80), style: stroke),
            Annotation.makeHighlighter(points: [CGPoint(x: 45, y: 80), CGPoint(x: 115, y: 80)], style: stroke),
            Annotation.makeSolidRedaction(in: rect, style: fill),
            Annotation.makeImageOverlay(image: blackImage, in: rect),
        ]
        let crop = CGRect(x: 20, y: 30, width: 120, height: 120)
        for angle: CGFloat in [-35, 35] {
            let inside = gscPoint(CGPoint(x: 103, y: 80), rotatedByDegrees: angle, around: rect.center)
            let opposite = gscPoint(CGPoint(x: 103, y: 80), rotatedByDegrees: -angle, around: rect.center)
            for original in annotations {
                let annotation = original.updatingRotationDegrees(angle)
                let snapshot = makeEditorSnapshot(cropRect: crop, annotations: [annotation])
                let preview = try preview(base: base, snapshot: snapshot)
                let exported = try XCTUnwrap(EditorRenderer.render(baseImage: base, snapshot: snapshot))
                XCTAssertTrue(annotation.contains(inside), "\(annotation.editorTool), \(angle)")
                XCTAssertLessThan(pixel(preview, at: inside).red, 150, "Preview \(annotation.editorTool), \(angle)")
                XCTAssertLessThan(pixel(exported, at: inside, crop: crop).red, 150, "Export \(annotation.editorTool), \(angle)")
                XCTAssertGreaterThan(pixel(preview, at: opposite).red, 240, "Preview outside \(annotation.editorTool), \(angle)")
                XCTAssertGreaterThan(pixel(exported, at: opposite, crop: crop).red, 240, "Export outside \(annotation.editorTool), \(angle)")
            }
        }
    }

    func testRotatedSpotlightHoleMatchesPreviewForRectangleAndEllipse() throws {
        let base = makeSolidImage(width: 160, height: 160, color: white)
        let rect = CGRect(x: 40, y: 70, width: 80, height: 20)
        var style = AnnotationStyle.default(for: .spotlight)
        style.strokeColor = .clear
        style.fillColor = .redactionFill
        style.lineWidth = 0
        style.effectRadius = 80
        for angle: CGFloat in [-35, 35] {
            for ellipse in [false, true] {
                let annotation = Annotation(id: UUID(), groupID: nil,
                    kind: .spotlight(SpotlightShape(rect: rect, isEllipse: ellipse)), style: style,
                    rotationDegrees: angle)
                let inside = gscPoint(CGPoint(x: 105, y: 80), rotatedByDegrees: angle, around: rect.center)
                let outside = gscPoint(CGPoint(x: 105, y: 80), rotatedByDegrees: -angle, around: rect.center)
                let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 160), annotations: [annotation])
                let preview = try preview(base: base, snapshot: snapshot)
                let exported = try XCTUnwrap(EditorRenderer.render(baseImage: base, snapshot: snapshot))
                XCTAssertGreaterThan(pixel(preview, at: inside).red, 240)
                XCTAssertGreaterThan(pixel(exported, at: inside).red, 240)
                XCTAssertLessThan(pixel(preview, at: outside).red, 100)
                XCTAssertLessThan(pixel(exported, at: outside).red, 100)
            }
        }
    }

    func testRotatedBlurAndPixelateKeepUnderlyingSourceAligned() throws {
        let base = makeCoordinateImage(width: 160, height: 160)
        for angle: CGFloat in [-35, 35] {
            for mode in [RedactionMode.blur, .pixelate] {
                var style = AnnotationStyle.default(for: mode.editorTool)
                style.effectRadius = mode == .blur ? 0 : 1
                style.lineWidth = 0
                style.strokeColor = .clear
                let annotation = Annotation.makeRedaction(in: CGRect(x: 50, y: 65, width: 60, height: 30), mode: mode, style: style)
                    .updatingRotationDegrees(angle)
                let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 20, y: 20, width: 120, height: 120), annotations: [annotation])
                let exported = try XCTUnwrap(EditorRenderer.render(baseImage: base, snapshot: snapshot))
                let preview = try preview(base: base, snapshot: snapshot)
                for point in [CGPoint(x: 87, y: 83), CGPoint(x: 74, y: 76)] {
                    let expected = pixel(base, at: point)
                    for actual in [pixel(exported, at: point, crop: snapshot.cropRect), pixel(preview, at: point)] {
                        XCTAssertEqual(Double(actual.red), Double(expected.red), accuracy: 2, "\(mode), \(angle)")
                        XCTAssertEqual(Double(actual.green), Double(expected.green), accuracy: 2, "\(mode), \(angle)")
                    }
                }
            }
        }
    }

    func testProcessedRedactionPreviewIncludesLowerAnnotationLayers() throws {
        let base = makeSolidImage(width: 160, height: 160, color: white)
        let overlay = Annotation.makeImageOverlay(image: makeSolidImage(width: 100, height: 100, color: black),
            in: CGRect(x: 30, y: 30, width: 100, height: 100))
        for mode in [RedactionMode.blur, .pixelate] {
            var style = AnnotationStyle.default(for: mode.editorTool)
            style.effectRadius = 8
            style.lineWidth = 0
            let redaction = Annotation.makeRedaction(in: CGRect(x: 60, y: 60, width: 40, height: 40), mode: mode, style: style)
            let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 160), annotations: [overlay, redaction])
            let preview = try preview(base: base, snapshot: snapshot)
            let exported = try XCTUnwrap(EditorRenderer.render(baseImage: base, snapshot: snapshot))
            XCTAssertLessThan(pixel(exported, at: CGPoint(x: 80, y: 80)).red, 10)
            XCTAssertLessThan(pixel(preview, at: CGPoint(x: 80, y: 80)).red, 10)
        }
    }

    func testImageOverlayPreservesTopAndBottomPixelsInCroppedExport() throws {
        let base = makeSolidImage(width: 160, height: 160, color: white)
        let overlay = makeRGBAImage(width: 40, height: 40) { _, y in
            y < 20 ? PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
                : PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
        }
        let annotation = Annotation.makeImageOverlay(image: overlay, in: CGRect(x: 55, y: 45, width: 40, height: 40))
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 20, y: 20, width: 120, height: 120), annotations: [annotation])
        let preview = try preview(base: base, snapshot: snapshot)
        let exported = try XCTUnwrap(EditorRenderer.render(baseImage: base, snapshot: snapshot))
        for (point, expected) in [(CGPoint(x: 75, y: 50), PixelSample(red: 255, green: 0, blue: 0, alpha: 255)),
                                  (CGPoint(x: 75, y: 80), PixelSample(red: 0, green: 0, blue: 255, alpha: 255))] {
            XCTAssertEqual(pixel(preview, at: point), expected)
            XCTAssertEqual(pixel(exported, at: point, crop: snapshot.cropRect), expected)
        }
    }

    func testArrowLabelAboveAndBelowMatchModelGeometryInPreview() throws {
        let base = makeSolidImage(width: 160, height: 160, color: white)
        for placement in [ArrowLabelPlacement.parallelAbove, .parallelBelow] {
            let annotation = Annotation.makeArrow(from: CGPoint(x: 30, y: 80), to: CGPoint(x: 130, y: 80))
                .updatingArrow(label: "Label", labelBoxColor: .redactionFill, labelPlacement: placement)
            guard case .arrow(let shape) = annotation.kind else { return XCTFail("Expected arrow") }
            let label = AnnotationGeometry.arrowLabelGeometry(for: shape).rect
            let point = CGPoint(x: label.minX + 10, y: label.minY + 10)
            let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 160), annotations: [annotation])
            let preview = try preview(base: base, snapshot: snapshot)
            XCTAssertLessThan(pixel(preview, at: point).red, 100)
        }
    }

    func testCurvedArrowBodyUsesTheSameQuadraticAsItsModelAndLabels() throws {
        let base = makeSolidImage(width: 160, height: 160, color: white)
        var style = AnnotationStyle.default(for: .arrow)
        style.strokeColor = .redactionFill
        style.lineWidth = 4
        for curvature: CGFloat in [-40, 40] {
            let annotation = Annotation.makeArrow(from: CGPoint(x: 20, y: 80), to: CGPoint(x: 140, y: 80), style: style)
                .updatingArrow(curvature: curvature)
            guard case .arrow(let shape) = annotation.kind else { return XCTFail("Expected arrow") }
            let midpoint = AnnotationGeometry.arrowPoint(on: shape, at: 0.5)
            let pathBounds = EditorRenderGeometry.arrowBodyPath(for: shape).boundingBoxOfPath
            XCTAssertEqual(curvature > 0 ? pathBounds.maxY : pathBounds.minY, midpoint.y, accuracy: 0.01)
            let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 160, height: 160), annotations: [annotation])
            let preview = try preview(base: base, snapshot: snapshot)
            let exported = try XCTUnwrap(EditorRenderer.render(baseImage: base, snapshot: snapshot))
            XCTAssertLessThan(pixel(preview, at: midpoint).red, 100)
            XCTAssertLessThan(pixel(exported, at: midpoint).red, 100)
            XCTAssertGreaterThan(pixel(exported, at: CGPoint(x: midpoint.x, y: 160 - midpoint.y)).red, 240)
        }
    }

    func testArrowLabelGeometryScalesWithPreviewMagnification() {
        for placement in ArrowLabelPlacement.allCases {
            let original = ArrowShape(start: CGPoint(x: 20, y: 40), end: CGPoint(x: 140, y: 80),
                curvature: 20, label: "Label", labelPlacement: placement, labelFontSize: 14)
            let expected = AnnotationGeometry.arrowLabelGeometry(for: original)
            for scale: CGFloat in [0.25, 0.5, 2, 3] {
                var scaled = original
                scaled.start = CGPoint(x: original.start.x * scale, y: original.start.y * scale)
                scaled.end = CGPoint(x: original.end.x * scale, y: original.end.y * scale)
                scaled.curvature *= scale
                scaled.labelFontSize *= scale
                let actual = EditorRenderGeometry.arrowLabelGeometry(for: scaled, yAxisPointsDown: true, scale: scale)
                assertRectsEqual(actual.rect, expected.rect.applying(CGAffineTransform(scaleX: scale, y: scale)), accuracy: 0.001)
                XCTAssertEqual(actual.rotationDegrees, expected.rotationDegrees, accuracy: 0.001)
            }
        }
    }

    func testCurvedArrowHitTestingFollowsVisibleCurveThroughRotation() {
        for curvature: CGFloat in [-60, 60] {
            let original = Annotation.makeArrow(from: CGPoint(x: 20, y: 80), to: CGPoint(x: 140, y: 80))
                .updatingArrow(curvature: curvature)
            guard case .arrow(let shape) = original.kind else { return XCTFail("Expected arrow") }
            let midpoint = AnnotationGeometry.arrowPoint(on: shape, at: 0.5)
            let center = original.kind.unrotatedBoundingRect(style: original.style).center
            for angle: CGFloat in [-35, 0, 35] {
                let annotation = original.updatingRotationDegrees(angle)
                XCTAssertTrue(annotation.contains(gscPoint(midpoint, rotatedByDegrees: angle, around: center)))
                XCTAssertFalse(annotation.contains(gscPoint(CGPoint(x: 80, y: 80), rotatedByDegrees: angle, around: center)),
                    "The empty chord beneath a curved arrow must not be its selectable body")
            }
        }
    }

    func testRotatedProcessedRedactionClippedByCropDoesNotStretchSourcePixels() throws {
        let base = makeCoordinateImage(width: 160, height: 160)
        let crop = CGRect(x: 40, y: 30, width: 80, height: 100)
        for angle: CGFloat in [-35, 35] {
            for mode in [RedactionMode.blur, .pixelate] {
                var style = AnnotationStyle.default(for: mode.editorTool)
                style.effectRadius = mode == .blur ? 0 : 1
                style.lineWidth = 0
                style.strokeColor = .clear
                let annotation = Annotation.makeRedaction(in: CGRect(x: 20, y: 40, width: 70, height: 30), mode: mode, style: style)
                    .updatingRotationDegrees(angle)
                let result = try XCTUnwrap(EditorRenderer.render(baseImage: base,
                    snapshot: makeEditorSnapshot(cropRect: crop, annotations: [annotation])))
                for point in [CGPoint(x: 50, y: 55), CGPoint(x: 60, y: 55)] {
                    let expected = pixel(base, at: point)
                    let actual = pixel(result, at: point, crop: crop)
                    XCTAssertEqual(Double(actual.red), Double(expected.red), accuracy: 2)
                    XCTAssertEqual(Double(actual.green), Double(expected.green), accuracy: 2)
                }
            }
        }
    }

    func testProcessedRedactionTracksChangingLowerLayerPixelsAcrossRenders() throws {
        let base = makeSolidImage(width: 100, height: 100, color: white)
        for index in 0..<20 {
            try autoreleasepool {
                let expected = index.isMultiple(of: 2) ? black : white
                let overlay = Annotation.makeImageOverlay(image: makeSolidImage(width: 100, height: 100, color: expected),
                    in: CGRect(x: 0, y: 0, width: 100, height: 100))
                var style = AnnotationStyle.default(for: .blur)
                style.effectRadius = 0
                style.lineWidth = 0
                let redaction = Annotation.makeBlur(in: CGRect(x: 20, y: 20, width: 60, height: 60), style: style)
                let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                    annotations: [overlay, redaction])
                let result = try XCTUnwrap(EditorRenderer.render(baseImage: base, snapshot: snapshot))
                XCTAssertEqual(pixel(result, at: CGPoint(x: 50, y: 50)), expected)
            }
        }
    }

    private let white = PixelSample(red: 255, green: 255, blue: 255, alpha: 255)
    private let black = PixelSample(red: 0, green: 0, blue: 0, alpha: 255)

    private func pixel(_ image: CGImage, at point: CGPoint, crop: CGRect = .zero) -> PixelSample {
        samplePixel(in: image, topLeftX: Int((point.x - crop.minX).rounded()), topLeftY: Int((point.y - crop.minY).rounded()))
    }

    private func preview(base: CGImage, snapshot: EditorSnapshot) throws -> CGImage {
        let context = try XCTUnwrap(SRGBBitmapContext.make(width: base.width, height: base.height))
        // Native annotation views are genuinely Y-down, unlike export's
        // unflipped Quartz context. Reproduce that transform explicitly.
        context.translateBy(x: 0, y: CGFloat(base.height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        EditorRenderer.draw(baseImage: base, snapshot: snapshot,
            canvasRect: CGRect(x: 0, y: 0, width: base.width, height: base.height), draftAnnotations: [])
        return try XCTUnwrap(context.makeImage())
    }
}
