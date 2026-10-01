import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class AnnotationMutationTests: XCTestCase {
    func testMovingAndScalingEveryKindPreservesMetadata() {
        let rect = CGRect(x: 20, y: 30, width: 80, height: 40)
        let start = rect.origin
        let end = CGPoint(x: 100, y: 70)
        let image = makeCoordinateImage(width: 8, height: 8)
        let kinds: [AnnotationKind] = [
            .rectangle(RectangleShape(rect: rect)),
            .ellipse(EllipseShape(rect: rect)),
            .line(LineShape(start: start, end: end)),
            .arrow(decoratedArrow),
            .statusMark(StatusMarkShape(rect: rect)),
            .freehand(FreehandShape(points: [start, end])),
            .highlighter(HighlighterShape(points: [start, end])),
            .highlight(HighlightShape(rect: rect)),
            .text(TextShape(rect: rect, text: "Label", alignment: .right, automaticallySizesToText: false)),
            .callout(CalloutShape(
                rect: rect, number: 7, text: "Details", alignment: .center,
                style: .outlined, leaderPoint: end, automaticallySizesToText: false
            )),
            .measurement(MeasurementShape(start: start, end: end)),
            .spotlight(SpotlightShape(rect: rect, isEllipse: false)),
            .imageOverlay(ImageOverlayShape(
                assetID: UUID(), rect: rect, image: image, opacity: 0.4, role: .capturedCursor
            )),
            .redaction(RedactionShape(rect: rect, mode: .solid))
        ]
        let originalBounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let scaledBounds = CGRect(x: 0, y: 0, width: 512, height: 512)

        for kind in kinds {
            let annotation = makeAnnotation(kind)
            let moved = annotation.translated(by: CGSize(width: 12, height: -8))
            let scaled = moved.scaled(from: originalBounds, to: scaledBounds)
            let restored = scaled.scaled(from: scaledBounds, to: originalBounds)
                .translated(by: CGSize(width: -12, height: 8))

            XCTAssertNotEqual(moved.kind, annotation.kind, "\(kind.editorTool)")
            XCTAssertNotEqual(scaled.kind, moved.kind, "\(kind.editorTool)")
            XCTAssertEqual(restored, annotation, "\(kind.editorTool)")
            XCTAssertEqual(scaled.id, annotation.id)
            XCTAssertEqual(scaled.groupID, annotation.groupID)
            XCTAssertEqual(scaled.style, annotation.style)
            XCTAssertEqual(scaled.rotationDegrees, annotation.rotationDegrees)

            if case .imageOverlay(let shape) = scaled.kind {
                XCTAssertTrue(shape.image === image)
            }
        }
    }

    func testArrowEditsPreserveOtherOptionsAndAcceptEmptyValues() {
        let annotation = makeAnnotation(.arrow(decoratedArrow))
        let updated = annotation.updatingArrow(curvature: 0, headStyle: .single, label: "")
            .updatingArrow(labelBoxColor: .clear, labelFontSize: 18)
            .updatingNumberedArrowNumber(0)
        var expected = decoratedArrow
        expected.curvature = 0
        expected.headStyle = .single
        expected.label = ""
        expected.labelBoxColor = .clear
        expected.labelFontSize = 18
        expected.sequenceNumber = 1
        var expectedAnnotation = annotation
        expectedAnnotation.kind = .arrow(expected)

        XCTAssertEqual(updated, expectedAnnotation)
        XCTAssertEqual(annotation.kind, .arrow(decoratedArrow))
    }

    func testTextEditsPreserveManualSizingAndAnnotationMetadata() {
        let annotation = makeAnnotation(.text(TextShape(
            rect: CGRect(x: 20, y: 30, width: 180, height: 80),
            text: "Original", alignment: .right, automaticallySizesToText: false
        )))
        let updated = annotation.updatingText("Replacement", refittingBounds: false)
            .updatingTextAlignment(.center)
            .disablingAutomaticTextSizing()
        var expected = annotation
        expected.kind = .text(TextShape(
            rect: CGRect(x: 20, y: 30, width: 180, height: 80),
            text: "Replacement", alignment: .center, automaticallySizesToText: false
        ))

        XCTAssertEqual(updated, expected)
    }

    func testCalloutEditsPreserveLeaderAndLayout() {
        let annotation = makeAnnotation(.callout(CalloutShape(
            rect: CGRect(x: 20, y: 30, width: 200, height: 80),
            number: 7, text: "Original", alignment: .right, style: .outlined,
            leaderPoint: CGPoint(x: 12, y: 14), automaticallySizesToText: true
        )))
        let updated = annotation.updatingText("Replacement", refittingBounds: false)
            .updatingTextAlignment(.center)
            .disablingAutomaticTextSizing()
            .updatingCalloutNumber(9)
        var expected = annotation
        expected.kind = .callout(CalloutShape(
            rect: CGRect(x: 20, y: 30, width: 200, height: 80),
            number: 9, text: "Replacement", alignment: .center, style: .outlined,
            leaderPoint: CGPoint(x: 12, y: 14), automaticallySizesToText: false
        ))
        XCTAssertEqual(updated, expected)

        expected.kind = .callout(CalloutShape(
            rect: CGRect(x: 20, y: 30, width: 200, height: 80),
            number: 9, text: "Replacement", alignment: .center, style: .filled,
            leaderPoint: CGPoint(x: 12, y: 14), automaticallySizesToText: false
        ))
        XCTAssertEqual(updated.updatingCalloutStyle(.filled), expected)
    }

    private var decoratedArrow: ArrowShape {
        ArrowShape(
            start: CGPoint(x: 20, y: 30), end: CGPoint(x: 100, y: 70),
            curvature: 24, headStyle: .double, label: "Details", labelBoxColor: RGBAColor(red: 1, green: 1, blue: 1, alpha: 1),
            labelPlacement: .parallelBelow, labelFontSize: 22, labelTextColor: .complementary,
            headShape: .diamond, sequenceNumber: 7, badgeStyle: .outlined
        )
    }

    private func makeAnnotation(_ kind: AnnotationKind) -> Annotation {
        var style = AnnotationStyle.default(for: kind.editorTool)
        style.lineWidth = 7
        return Annotation(id: UUID(), groupID: UUID(), kind: kind, style: style, rotationDegrees: 30)
    }
}
