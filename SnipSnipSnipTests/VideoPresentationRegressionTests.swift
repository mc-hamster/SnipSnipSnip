import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class VideoPresentationRegressionTests: XCTestCase {
    func testVideoShadowPickerAppliesPresetParametersAndRemainsUndoable() throws {
        let recording = fixtureRecording()
        var session = VideoEditorSession.fullDuration(recording.duration)
        session.effects.presentation = ScreenshotPresentationPreset.lifted.settings
        let controller = VideoEditorController(recording: recording, session: session)
        let manager = UndoManager()
        manager.groupsByEvent = false
        controller.undoManager = manager

        for shadow in [ScreenshotShadowStyle.off, .drop, .strong] {
            let previous = controller.session
            manager.beginUndoGrouping()
            controller.updatePresentationShadow(shadow)
            manager.endUndoGrouping()
            let actual = controller.session.effects.presentation
            XCTAssertEqual(actual.shadow, shadow)
            XCTAssertEqual(actual.shadowBlurRadius, shadow.blurRadius)
            XCTAssertEqual(actual.shadowOffsetX, shadow.offsetX)
            XCTAssertEqual(actual.shadowOffsetY, shadow.offsetY)
            XCTAssertEqual(actual.shadowOpacity, shadow.opacity)
            manager.undo()
            XCTAssertEqual(controller.session, previous)
            manager.redo()
            XCTAssertEqual(controller.session.effects.presentation, actual)
        }
    }

    func testSoftAndStrongVideoShadowsProduceDifferentRenderedFrames() throws {
        let recording = fixtureRecording()
        var session = VideoEditorSession.fullDuration(recording.duration)
        session.effects.presentation = ScreenshotPresentationPreset.lifted.settings
        let controller = VideoEditorController(recording: recording, session: session)
        let source = makeSolidImage(width: 160, height: 100,
            color: PixelSample(red: 255, green: 0, blue: 0, alpha: 255))
        var sizes: [CGSize] = []
        for shadow in [ScreenshotShadowStyle.drop, .strong] {
            controller.updatePresentationShadow(shadow)
            let renderer = try VideoFrameRenderer(
                document: EditableVideoDocument(recording: recording, session: controller.session),
                contentSize: CGSize(width: source.width, height: source.height),
                cursorImage: VideoRenderAssets.cursor(), clickImage: VideoRenderAssets.click(),
                shortcutImages: [:], timeline: nil)
            let rendered = try XCTUnwrap(renderer.cgImage(source, at: 0))
            let sourceRect = renderer.sourceRectInOutput
            let center = samplePixel(in: rendered, topLeftX: Int(sourceRect.midX), topLeftY: Int(sourceRect.midY))
            XCTAssertGreaterThan(center.red, 240)
            XCTAssertLessThan(center.blue, 10)
            sizes.append(renderer.outputSize)
        }
        XCTAssertGreaterThan(sizes[1].width, sizes[0].width)
        XCTAssertGreaterThan(sizes[1].height, sizes[0].height)
    }

    func testCursorResumesAtFirstVisibleSampleAfterPauseOrHiddenInterval() {
        for previousIsVisible in [false, true] {
            let position = VideoPoint(x: 0.2, y: 0.7)
            let track = VideoInteractionTrack(samples: [
                VideoCursorSample(time: 0, position: .center, visible: previousIsVisible),
                VideoCursorSample(time: 1, position: position),
            ])
            for smooth in [false, true] {
                XCTAssertNil(track.cursor(at: 0.9, smooth: smooth))
                XCTAssertEqual(track.cursor(at: 1, smooth: smooth), position)
                XCTAssertEqual(track.cursor(at: 1.1, smooth: smooth), position)
                XCTAssertNil(track.cursor(at: 1.3, smooth: smooth))
            }
        }
    }

    func testPreviewSkipsWholeOverlappingAndAdjacentCutsUsingExportTimeline() throws {
        let recording = fixtureRecording()
        var session = VideoEditorSession(trimStartSeconds: 0.2, trimEndSeconds: 1.9, posterTimeSeconds: 0.2)
        session.removedRanges = [
            VideoTimeRange(start: 0.8, end: 1.4),
            VideoTimeRange(start: 0.4, end: 1),
            VideoTimeRange(start: 1.4, end: 1.6),
        ]
        let controller = VideoEditorController(recording: recording, session: session)
        let exportTimeline = VideoEditTimeline(session: session, duration: recording.duration)
        XCTAssertEqual(controller.nextKeptPreviewTime(atOrAfter: 0), 0.2)
        XCTAssertEqual(controller.nextKeptPreviewTime(atOrAfter: 0.3), 0.3)
        for time in [0.4, 0.6, 0.9, 1.2, 1.4, 1.5, 1.6] {
            XCTAssertEqual(controller.nextKeptPreviewTime(atOrAfter: time), 1.6)
        }
        XCTAssertEqual(controller.nextKeptPreviewTime(atOrAfter: 0.4),
            exportTimeline.sourceTime(for: 0.2))
        XCTAssertNil(controller.nextKeptPreviewTime(atOrAfter: 1.9))
        XCTAssertNil(controller.nextKeptPreviewTime(atOrAfter: .nan))
    }

    private func fixtureRecording() -> CapturedVideoRecording {
        CapturedVideoRecording(sourceURL: URL(fileURLWithPath: "/unused-video-presentation-fixture.mp4"),
            kind: .region, sourceName: "Video Presentation Fixture",
            bounds: CGRect(x: 0, y: 0, width: 160, height: 100), recordedAt: Date(),
            duration: 2, preferences: VideoRecordingPreferences())
    }
}
