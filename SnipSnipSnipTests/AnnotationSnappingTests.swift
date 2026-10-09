import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class AnnotationSnappingTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)

    func testAttachmentAndReleaseDistancesStayConsistentAcrossMagnifications() {
        let candidates = SnapCandidateSet(bounds: bounds, others: [CGRect(x: 100, y: 350, width: 0, height: 0)])

        for scale: CGFloat in [0.25, 1, 4] {
            var session = AnnotationSnapSession()
            let attached = session.snapPoint(CGPoint(x: 100 + 5 / scale, y: 50), candidates: candidates, displayScale: scale)
            XCTAssertEqual(attached.point.x, 100, accuracy: 0.001)

            let retained = session.snapPoint(CGPoint(x: 100 + 9 / scale, y: 50), candidates: candidates, displayScale: scale)
            XCTAssertEqual(retained.point.x, 100, accuracy: 0.001)

            let released = session.snapPoint(CGPoint(x: 100 + 11 / scale, y: 50), candidates: candidates, displayScale: scale)
            XCTAssertEqual(released.point.x, 100 + 11 / scale, accuracy: 0.001)

            session.reset()
            let outsideAttachment = session.snapPoint(CGPoint(x: 100 + 7 / scale, y: 50), candidates: candidates, displayScale: scale)
            XCTAssertEqual(outsideAttachment.point.x, 100 + 7 / scale, accuracy: 0.001)
        }
    }

    func testAcquiredGuideDoesNotSwitchToCloserCompetingGuideUntilReleased() {
        let candidates = SnapCandidateSet(bounds: bounds, others: [
            CGRect(x: 100, y: 350, width: 0, height: 0),
            CGRect(x: 108, y: 350, width: 0, height: 0)
        ])
        var session = AnnotationSnapSession()
        _ = session.snapPoint(CGPoint(x: 96, y: 50), candidates: candidates, displayScale: 1)

        let retained = session.snapPoint(CGPoint(x: 106, y: 50), candidates: candidates, displayScale: 1)
        XCTAssertEqual(retained.point.x, 100)
        XCTAssertEqual(retained.guides, [SnapGuide(orientation: .vertical, position: 100)])

        let switched = session.snapPoint(CGPoint(x: 111, y: 50), candidates: candidates, displayScale: 1)
        XCTAssertEqual(switched.point.x, 108)
    }

    func testEachAxisReleasesIndependently() {
        let candidates = SnapCandidateSet(bounds: bounds, others: [
            CGRect(x: 100, y: 300, width: 0, height: 0),
            CGRect(x: 108, y: 350, width: 0, height: 0)
        ])
        var session = AnnotationSnapSession()
        _ = session.snapPoint(CGPoint(x: 95, y: 295), candidates: candidates, displayScale: 1)

        let resolution = session.snapPoint(CGPoint(x: 112, y: 306), candidates: candidates, displayScale: 1)
        XCTAssertEqual(resolution.point, CGPoint(x: 108, y: 300))
    }

    func testMoveRetainsTheAcquiredEdgeUntilItsReleaseDistance() {
        let candidates = SnapCandidateSet(bounds: bounds, others: [CGRect(x: 100, y: 350, width: 0, height: 0)])
        var session = AnnotationSnapSession()
        _ = session.snapRect(CGRect(x: 80, y: 50, width: 20, height: 20), candidates: candidates, within: bounds, displayScale: 1, bypassed: false)

        let retained = session.snapRect(CGRect(x: 86, y: 50, width: 20, height: 20), candidates: candidates, within: bounds, displayScale: 1, bypassed: false)
        XCTAssertEqual(retained.rect.maxX, 100)

        let releasedEdge = session.snapRect(CGRect(x: 96, y: 50, width: 20, height: 20), candidates: candidates, within: bounds, displayScale: 1, bypassed: false)
        XCTAssertEqual(releasedEdge.rect.minX, 100)
    }

    func testMoveBypassClearsGuidesAndResumesUsingCurrentPointer() {
        let candidates = SnapCandidateSet(bounds: bounds, others: [
            CGRect(x: 100, y: 350, width: 0, height: 0),
            CGRect(x: 108, y: 350, width: 0, height: 0)
        ])
        var session = AnnotationSnapSession()
        _ = session.snapRect(CGRect(x: 96, y: 50, width: 20, height: 20), candidates: candidates, within: bounds, displayScale: 1, bypassed: false)

        let bypassed = session.snapRect(CGRect(x: 106, y: 50, width: 20, height: 20), candidates: candidates, within: bounds, displayScale: 1, bypassed: true)
        XCTAssertEqual(bypassed.rect.minX, 106)
        XCTAssertTrue(bypassed.guides.isEmpty)

        let resumed = session.snapRect(CGRect(x: 106, y: 50, width: 20, height: 20), candidates: candidates, within: bounds, displayScale: 1, bypassed: false)
        XCTAssertEqual(resumed.rect.minX, 108)
    }

    func testResizeRetainsGuideAndBypassKeepsAnchoredEdges() {
        let original = CGRect(x: 20, y: 50, width: 70, height: 20)
        let candidates = SnapCandidateSet(bounds: bounds, others: [CGRect(x: 100, y: 350, width: 0, height: 0)])
        var session = AnnotationSnapSession()
        _ = session.snapSignedScaleBounds(gscSignedScaleBounds(for: original, handle: .right, point: CGPoint(x: 95, y: 60)), handle: .right, candidates: candidates, displayScale: 1, bypassed: false)

        let rawBounds = gscSignedScaleBounds(for: original, handle: .right, point: CGPoint(x: 109, y: 60))
        let retained = session.snapSignedScaleBounds(rawBounds, handle: .right, candidates: candidates, displayScale: 1, bypassed: false)
        XCTAssertEqual(retained.bounds.maxXTarget, 100)
        XCTAssertEqual(retained.bounds.minXTarget, 20)
        XCTAssertEqual(retained.bounds.minYTarget, 50)
        XCTAssertEqual(retained.bounds.maxYTarget, 70)

        let bypassed = session.snapSignedScaleBounds(rawBounds, handle: .right, candidates: candidates, displayScale: 1, bypassed: true)
        XCTAssertEqual(bypassed.bounds, rawBounds)
        XCTAssertTrue(bypassed.guides.isEmpty)

        let resumed = session.snapSignedScaleBounds(gscSignedScaleBounds(for: original, handle: .right, point: CGPoint(x: 104, y: 60)), handle: .right, candidates: candidates, displayScale: 1, bypassed: false)
        XCTAssertEqual(resumed.bounds.maxXTarget, 100)
    }

    @MainActor
    func testRectangleDrawingUsesCanvasScaleAndKeepsAnchorStable() {
        let snapshot = makeEditorSnapshot(cropRect: bounds)
        var interaction = AnnotationCanvasInteractionState()
        interaction.beginRectDrawing(tool: .rectangle, anchor: CGPoint(x: 70, y: 70))
        interaction.update(at: CGPoint(x: 202, y: 150), snapshot: snapshot, imageBounds: bounds, cropAspectRatio: nil, displayScale: 4, styleProvider: AnnotationStyle.default(for:))
        XCTAssertEqual(interaction.draftAnnotations.first?.boundingRect.maxX, 202)

        interaction.update(at: CGPoint(x: 201, y: 150), snapshot: snapshot, imageBounds: bounds, cropAspectRatio: nil, displayScale: 4, styleProvider: AnnotationStyle.default(for:))
        XCTAssertEqual(interaction.draftAnnotations.first?.boundingRect.minX, 70)
        XCTAssertEqual(interaction.draftAnnotations.first?.boundingRect.maxX, 200)
    }
    @MainActor
    func testEndpointEditsKeepOppositeEndpointAndAnnotationProperties() {
        let start = CGPoint(x: 70, y: 90)
        let end = CGPoint(x: 170, y: 90)
        let target = CGPoint(x: 30, y: 200)
        let annotations = [
            Annotation.makeLine(from: start, to: end),
            Annotation.makeArrow(from: start, to: end),
            Annotation.makeNumberedArrow(from: start, to: end, number: 3)
        ]
        for annotation in annotations {
            for endpoint in AnnotationEndpoint.allCases {
                var interaction = AnnotationCanvasInteractionState()
                let snapshot = makeEditorSnapshot(cropRect: bounds, annotations: [annotation], selectedAnnotationIDs: [annotation.id])
                interaction.beginEndpointEdit(annotation: annotation, endpoint: endpoint)
                interaction.update(at: target, snapshot: snapshot, imageBounds: bounds, cropAspectRatio: nil, bypassesSnapping: true, styleProvider: AnnotationStyle.default(for:))
                guard case let .update(updated) = interaction.finish(snapshot: snapshot), let result = updated.first else {
                    return XCTFail("Endpoint drag must commit an annotation update")
                }
                XCTAssertEqual(endpoint.position(in: result), target)
                let opposite: AnnotationEndpoint = endpoint == .start ? .end : .start
                XCTAssertEqual(opposite.position(in: result), opposite.position(in: annotation))
                XCTAssertEqual(result.id, annotation.id)
                XCTAssertEqual(result.style, annotation.style)
                XCTAssertEqual(endpoint.replacingPosition(in: result, with: endpoint.position(in: annotation)!), annotation)
            }
        }
    }

    func testEndpointHandlesOnlyApplyToSingleLinesAndArrows() {
        let line = Annotation.makeLine(from: CGPoint(x: 20, y: 40), to: CGPoint(x: 20, y: 100))
        XCTAssertEqual(AnnotationEndpoint.editableAnnotation(in: [line]), line)
        XCTAssertNil(AnnotationEndpoint.editableAnnotation(in: []))
        XCTAssertNil(AnnotationEndpoint.editableAnnotation(in: [line, Annotation.makeArrow(from: .zero, to: CGPoint(x: 100, y: 100))]))
        XCTAssertNil(AnnotationEndpoint.editableAnnotation(in: [Annotation.makeRectangle(in: bounds)]))
    }

    @MainActor
    func testEndpointDragSnapsBypassesAndCanCrossTheFixedEndpoint() {
        let line = Annotation.makeLine(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 100))
        let other = Annotation.makeRectangle(in: CGRect(x: 50, y: 250, width: 40, height: 30))
        let snapshot = makeEditorSnapshot(cropRect: bounds, annotations: [line, other])
        var interaction = AnnotationCanvasInteractionState()
        interaction.beginEndpointEdit(annotation: line, endpoint: .end)
        interaction.update(at: CGPoint(x: 54, y: 170), snapshot: snapshot, imageBounds: bounds, cropAspectRatio: nil, styleProvider: AnnotationStyle.default(for:))
        XCTAssertEqual(AnnotationEndpoint.end.position(in: interaction.draftAnnotations[0]), CGPoint(x: 50, y: 170))
        XCTAssertEqual(AnnotationEndpoint.start.position(in: interaction.draftAnnotations[0]), CGPoint(x: 100, y: 100))
        XCTAssertFalse(interaction.snapGuides.isEmpty)
        interaction.update(at: CGPoint(x: 54, y: 170), snapshot: snapshot, imageBounds: bounds, cropAspectRatio: nil, bypassesSnapping: true, styleProvider: AnnotationStyle.default(for:))
        XCTAssertEqual(AnnotationEndpoint.end.position(in: interaction.draftAnnotations[0]), CGPoint(x: 54, y: 170))
        XCTAssertTrue(interaction.snapGuides.isEmpty)
        interaction.reset()
        XCTAssertTrue(interaction.draftAnnotations.isEmpty)
        guard case .none = interaction.finish(snapshot: snapshot) else { return XCTFail("Cancelled drag must not commit") }
    }

    func testRotatedEndpointEditsUseVisibleGeometryAndKeepFixedEnd() {
        for rotation: CGFloat in [90, 180, 270, 35] {
            for original in [Annotation.makeLine(from: CGPoint(x: 50, y: 80), to: CGPoint(x: 180, y: 110)), Annotation.makeNumberedArrow(from: CGPoint(x: 50, y: 80), to: CGPoint(x: 180, y: 110), number: 4)] {
                var annotation = original
                annotation.rotationDegrees = rotation
                for endpoint in AnnotationEndpoint.allCases {
                    let opposite: AnnotationEndpoint = endpoint == .start ? .end : .start
                    let fixed = opposite.position(in: annotation)!
                    let target = CGPoint(x: 240, y: 190)
                    let result = endpoint.replacingPosition(in: annotation, with: target)
                    let moved = endpoint.position(in: result)!
                    let unchanged = opposite.position(in: result)!
                    XCTAssertEqual(moved.x, target.x, accuracy: 0.001)
                    XCTAssertEqual(moved.y, target.y, accuracy: 0.001)
                    XCTAssertEqual(unchanged.x, fixed.x, accuracy: 0.001)
                    XCTAssertEqual(unchanged.y, fixed.y, accuracy: 0.001)
                    XCTAssertEqual(result.rotationDegrees, 0)
                }
            }
        }
    }

}
