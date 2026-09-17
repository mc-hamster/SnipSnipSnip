import AppKit
import CoreImage
import XCTest
@testable import SnipSnipSnip

@MainActor
final class VideoZoomTargetTests: XCTestCase {
    func testFullTargetShowsDestinationEvenAtStartOfTransition() {
        let zoom = VideoZoom(start: 1, end: 4, scale: 2, followsCursor: false, center: .init(x: 0.25, y: 0.75))
        let start = VideoZoomGeometry.resolve(zoom, at: 1, interactions: nil)
        XCTAssertEqual(start.sourceRect, CGRect(x: 0, y: 0, width: 1, height: 1))
        let target = VideoZoomGeometry.resolve(zoom, at: 1, interactions: nil, atFullMagnification: true)
        XCTAssertEqual(target.sourceRect, CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(target, VideoZoomGeometry.resolve(zoom, at: 2.5, interactions: nil))
        XCTAssertEqual(target.focusSource, .fixed)
    }

    func testTargetRespectsAllEdgesAndFullFrameMagnification() {
        for x in [0.0, 0.5, 1.0] {
            for y in [0.0, 0.5, 1.0] {
                for scale in [1.0, 2.0, 4.0] {
                    let zoom = VideoZoom(start: 0, end: 2, scale: scale, followsCursor: false, center: .init(x: x, y: y))
                    let target = VideoZoomGeometry.resolve(zoom, at: 1, interactions: nil)
                    XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(target.sourceRect))
                    XCTAssertEqual(target.sourceRect.width, 1 / scale)
                    XCTAssertEqual(target.sourceRect.height, 1 / scale)
                }
            }
        }
    }

    func testCursorAndMissingCursorResolveToExplicitFocusSources() {
        let zoom = VideoZoom(start: 0, end: 2, scale: 4, center: .init(x: 0.75, y: 0.25))
        let track = VideoInteractionTrack(samples: [
            .init(time: 0.95, position: .init(x: 0.2, y: 0.8)),
            .init(time: 1, position: .init(x: 0.2, y: 0.8)),
            .init(time: 1.05, position: .center, visible: false)
        ])
        let following = VideoZoomGeometry.resolve(zoom, at: 1, interactions: track)
        XCTAssertEqual(following.focusSource, .cursor)
        XCTAssertEqual(following.center.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(following.center.y, 0.8, accuracy: 0.0001)
        for interactions: VideoInteractionTrack? in [nil, .init(), track] {
            let fallback = VideoZoomGeometry.resolve(zoom, at: 1.1, interactions: interactions)
            XCTAssertEqual(fallback.focusSource, .fallback)
            XCTAssertEqual(fallback.center, zoom.center)
        }
    }

    func testTargetAndPointerShareLetterboxedTopLeftCoordinates() throws {
        let content = CGRect(x: 120, y: 80, width: 480, height: 720)
        let zoom = VideoZoom(start: 0, end: 2, scale: 2, followsCursor: false, center: .init(x: 0.25, y: 0.75))
        let target = VideoZoomGeometry.resolve(zoom, at: 1, interactions: nil).rect(in: content)
        XCTAssertEqual(target, CGRect(x: 120, y: 440, width: 240, height: 360))
        XCTAssertEqual(VideoZoomGeometry.point(at: CGPoint(x: target.midX, y: target.midY), in: content), zoom.center)
        XCTAssertEqual(VideoZoomGeometry.point(at: .zero, in: content), VideoPoint(x: 0, y: 0))
        XCTAssertNil(VideoZoomGeometry.point(at: .zero, in: .zero))
        XCTAssertNil(VideoZoomGeometry.point(at: CGPoint(x: CGFloat.nan, y: 0), in: content))
    }

    func testUnzoomedTargetImageLeavesNormalRendererAndPresentationUnchanged() throws {
        let size = CGSize(width: 200, height: 100)
        let source = makeCoordinateImage(width: Int(size.width), height: Int(size.height))
        let recording = CapturedVideoRecording(sourceURL: URL(fileURLWithPath: "/unused-zoom-target-fixture.mp4"), kind: .region,
                                               sourceName: "Fixture", bounds: CGRect(origin: .zero, size: size),
                                               recordedAt: Date(), duration: 2, preferences: .init())
        for polished in [false, true] {
            var session = VideoEditorSession.fullDuration(2)
            session.effects.showsCursor = false
            session.effects.motionBlur = 0.8
            if polished { session.effects.presentation = ScreenshotPresentationPreset.lifted.settings }
            session.effects.zooms = [.init(start: 0, end: 2, scale: 2, followsCursor: false, center: .init(x: 0.25, y: 0.75))]
            func renderer(_ session: VideoEditorSession) throws -> VideoFrameRenderer {
                try VideoFrameRenderer(document: .init(recording: recording, session: session), contentSize: size,
                                       cursorImage: VideoRenderAssets.cursor(), clickImage: VideoRenderAssets.click(),
                                       shortcutImages: [:], timeline: nil)
            }
            let zoomedRenderer = try renderer(session)
            let before = try XCTUnwrap(zoomedRenderer.cgImage(source, at: 0.2))
            let fullFrame = try XCTUnwrap(zoomedRenderer.cgImage(source, at: 0.2, applyingZooms: false))
            session.effects.zooms = []
            let plainRenderer = try renderer(session)
            let expected = try XCTUnwrap(plainRenderer.cgImage(source, at: 0.2))
            let after = try XCTUnwrap(zoomedRenderer.cgImage(source, at: 0.2))
            XCTAssertEqual(normalizedRGBAPixels(fullFrame), normalizedRGBAPixels(expected))
            XCTAssertEqual(normalizedRGBAPixels(before), normalizedRGBAPixels(after))
            XCTAssertNotEqual(normalizedRGBAPixels(fullFrame), normalizedRGBAPixels(after))
            XCTAssertEqual(zoomedRenderer.sourceRectInOutput, plainRenderer.sourceRectInOutput)
            XCTAssertTrue(CGRect(origin: .zero, size: zoomedRenderer.outputSize).contains(zoomedRenderer.sourceRectInOutput))
        }
    }

    func testSelectingTargetIsNavigationAndDraggingIsOneUndoableFixedFocusEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoZoomTargetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = try await VideoTestMedia.make(in: directory)
        var session = VideoEditorSession.fullDuration(2)
        let zoom = VideoZoom(start: 0.2, end: 1.8)
        session.effects.zooms = [zoom]
        let controller = VideoEditorController(recording: recording, session: session)
        await waitUntil { !controller.isPreparingPreview }
        XCTAssertNil(controller.previewError)
        controller.selectZoom(zoom.id)
        XCTAssertEqual(controller.currentTimeSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(controller.selectedZoomID, zoom.id)
        XCTAssertEqual(controller.inspectorSection, .zooms)
        XCTAssertEqual(controller.session, session)
        XCTAssertEqual(controller.persistenceRevision, 0)

        let manager = UndoManager()
        manager.groupsByEvent = false
        controller.undoManager = manager
        manager.beginUndoGrouping()
        controller.beginContinuousEdit("Move Zoom Target")
        controller.moveZoomTarget(zoom.id, to: .init(x: 0.2, y: 0.3))
        controller.moveZoomTarget(zoom.id, to: .init(x: 0.3, y: 0.7))
        controller.endContinuousEdit()
        manager.endUndoGrouping()
        XCTAssertEqual(controller.selectedZoom?.center, .init(x: 0.3, y: 0.7))
        XCTAssertEqual(controller.selectedZoom?.followsCursor, false)
        manager.undo()
        XCTAssertEqual(controller.session, session)
        XCTAssertFalse(manager.canUndo)
        manager.redo()
        XCTAssertEqual(controller.selectedZoom?.center, .init(x: 0.3, y: 0.7))
        let moved = controller.session
        controller.moveZoomTarget(zoom.id, to: .init(x: .nan, y: 0))
        controller.moveZoomTarget(UUID(), to: .center)
        XCTAssertEqual(controller.session, moved)

        controller.selectedZoomID = UUID()
        XCTAssertEqual(controller.selectedZoom?.id, zoom.id, "Stale selection must fall back to an existing zoom")
        await waitUntil { !controller.isPreparingPreview }
        controller.previewZoom(zoom.id)
        XCTAssertTrue(controller.isPlaying)
        controller.pause()
        XCTAssertEqual(controller.session, moved)
    }
}
