import AppKit
import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import XCTest
@testable import SnipSnipSnip

@MainActor
final class VideoEditingTests: XCTestCase {
    func testShortcutRecordingHasItsOwnBuildGate() {
        XCTAssertTrue(BuildTargetFeatureMatrix.isEnabled(.videoShortcutCapture, for: .dev))
        XCTAssertTrue(BuildTargetFeatureMatrix.isEnabled(.videoShortcutCapture, for: .selfRelease))
        XCTAssertFalse(BuildTargetFeatureMatrix.isEnabled(.videoShortcutCapture, for: .release))
        XCTAssertFalse(BuildTargetFeatureMatrix.isEnabled(.videoShortcutCapture, for: .internalTesting))
        XCTAssertFalse(BuildTargetFeatureMatrix.isEnabled(.videoShortcutCapture, for: .externalTesting))
        XCTAssertFalse(BuildTargetCapabilityProvider().snapshot(for: .release).isEnabled(.videoShortcutCapture))
    }
    func testOverlappingCutsProduceOneContinuousTimeMap() {
        let session = VideoEditorSession(trimStartSeconds: 1, trimEndSeconds: 9, posterTimeSeconds: 1,
                                         removedRanges: [.init(start: 3, end: 5), .init(start: 4, end: 6)])
        let timing = VideoEditTimeline(session: session, duration: 10)
        XCTAssertEqual(timing.duration, 5)
        XCTAssertEqual(timing.ranges.map(\.start), [1, 6])
        XCTAssertEqual(timing.ranges.map(\.end), [3, 9])
        XCTAssertEqual(timing.sourceTime(for: 1.5), 2.5)
        XCTAssertEqual(timing.sourceTime(for: 2), 6)
        XCTAssertEqual(timing.sourceTime(for: 99), 9)
    }

    func testZoomEasingAndCursorInterpolationRespectBoundaries() {
        let zoom = VideoZoom(start: 1, end: 4)
        XCTAssertEqual(zoom.amount(at: 0), 0)
        XCTAssertEqual(zoom.amount(at: 1), 0)
        XCTAssertEqual(zoom.amount(at: 2), 1)
        XCTAssertEqual(zoom.amount(at: 4), 0)
        let track = VideoInteractionTrack(samples: [
            .init(time: 0, position: .init(x: 0, y: 0)),
            .init(time: 0.1, position: .init(x: 1, y: 1)),
            .init(time: 0.2, position: .center, visible: false),
            .init(time: 1, position: .center)
        ])
        XCTAssertEqual(track.cursor(at: 0.05, smooth: false), .center)
        XCTAssertNil(track.cursor(at: -0.1, smooth: false))
        XCTAssertNil(track.cursor(at: 0.2, smooth: false))
        XCTAssertNil(track.cursor(at: 0.8, smooth: true))
        XCTAssertNil(track.cursor(at: 1.4, smooth: false))
    }

    func testSmartZoomsGroupNearbyClicksWithoutTouchingCaptureData() {
        let track = VideoInteractionTrack(clicks: [
            .init(time: 1, position: .center), .init(time: 2, position: .center), .init(time: 8, position: .center)
        ])
        let zooms = VideoSmartZooms.suggest(track: track, duration: 9)
        XCTAssertEqual(zooms.count, 2)
        XCTAssertEqual(zooms[0].start, 0.3, accuracy: 0.001)
        XCTAssertEqual(zooms[0].end, 4)
        XCTAssertEqual(zooms[1].end, 9)
        XCTAssertEqual(track.clicks.count, 3)
    }

    func testOldSessionsAndPreferencesDecodeWithSafeDefaults() throws {
        let data = Data(#"{"trimStartSeconds":1,"trimEndSeconds":5,"posterTimeSeconds":2}"#.utf8)
        let session = try JSONDecoder().decode(VideoEditorSession.self, from: data)
        XCTAssertTrue(session.removedRanges.isEmpty)
        XCTAssertFalse(session.effects.presentation.isEnabled)
        XCTAssertTrue(session.effects.zooms.isEmpty)
        var preferences = VideoRecordingPreferences()
        preferences.recordsKeyboardShortcuts = nil
        let decoded = try JSONDecoder().decode(VideoRecordingPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertNil(decoded.recordsKeyboardShortcuts)
    }

    func testInvalidNumbersCannotEscapeSessionNormalization() {
        var session = VideoEditorSession(trimStartSeconds: .nan, trimEndSeconds: .infinity, posterTimeSeconds: -.infinity)
        session.effects.cursorScale = .nan
        session.effects.zooms = [VideoZoom(start: .nan, end: .infinity)]
        let normalized = session.normalized(for: 3)
        XCTAssertEqual(normalized.trimStartSeconds, 0)
        XCTAssertEqual(normalized.trimEndSeconds, 3)
        XCTAssertEqual(normalized.posterTimeSeconds, 0)
        XCTAssertTrue(normalized.effects.cursorScale.isFinite)
        XCTAssertTrue(normalized.effects.zooms.isEmpty)
    }

    func testPolishAndContinuousTrimCanBeUndoneAsSingleActions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = try await VideoTestMedia.make(in: directory)
        let controller = VideoEditorController(recording: recording)
        let manager = UndoManager()
        manager.groupsByEvent = false
        controller.undoManager = manager
        let initial = controller.session
        manager.beginUndoGrouping()
        controller.polishVideo()
        manager.endUndoGrouping()
        XCTAssertTrue(controller.session.effects.presentation.isEnabled)
        manager.undo()
        XCTAssertEqual(controller.session, initial)
        manager.redo()
        XCTAssertTrue(controller.session.effects.presentation.isEnabled)
        manager.beginUndoGrouping()
        controller.beginContinuousEdit("Trim Video")
        controller.updateTrimStart(0.2)
        controller.updateTrimStart(0.4)
        controller.endContinuousEdit()
        manager.endUndoGrouping()
        manager.undo()
        XCTAssertEqual(controller.session.trimStartSeconds, 0)
    }

    func testProjectRoundTripKeepsOriginalMediaAndEditableEffects() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var recording = try await VideoTestMedia.make(in: directory)
        recording.interactions = VideoInteractionTrack(samples: [.init(time: 0, position: .center)], clicks: [.init(time: 0.5, position: .center)])
        var session = VideoEditorSession.fullDuration(2)
        session.effects.zooms = [.init(start: 0.2, end: 1.5)]
        session.effects.presentation = ScreenshotPresentationPreset.lifted.settings
        session.removedRanges = [.init(start: 0.7, end: 0.9)]
        let url = directory.appendingPathComponent("Edited.sssvideo")
        let source = try Data(contentsOf: recording.sourceURL)
        try SSSVideoDocumentPackage.save(document: .init(recording: recording, session: session),
                                        posterImage: makeCoordinateImage(width: 16, height: 12), to: url)
        let result = try SSSVideoDocumentPackage.load(from: url)
        XCTAssertEqual(result.session, session)
        XCTAssertEqual(result.recording.interactions, recording.interactions)
        XCTAssertEqual(try Data(contentsOf: result.recording.sourceURL), source)
        let manifestURL = url.appendingPathComponent(SSSVideoDocumentPackage.manifestFilename)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertEqual(manifest["formatVersion"] as? Int, 3)
        // Reproduce the version-2 schema, which did not store separate effects.
        manifest["formatVersion"] = 2
        var oldSession = try XCTUnwrap(manifest["session"] as? [String: Any])
        oldSession.removeValue(forKey: "effects")
        oldSession.removeValue(forKey: "removedRanges")
        manifest["session"] = oldSession
        var oldRecording = try XCTUnwrap(manifest["recording"] as? [String: Any])
        oldRecording.removeValue(forKey: "interactions")
        manifest["recording"] = oldRecording
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let legacy = try SSSVideoDocumentPackage.load(from: url)
        XCTAssertNil(legacy.recording.interactions)
        XCTAssertEqual(legacy.session.trimStartSeconds, session.trimStartSeconds)
        XCTAssertFalse(legacy.session.effects.presentation.isEnabled)
        XCTAssertTrue(legacy.session.effects.zooms.isEmpty)
    }

    func testPreviewAndMP4UseSameFrameGeometryAndCuts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = try await VideoTestMedia.make(in: directory)
        var session = VideoEditorSession(trimStartSeconds: 0.2, trimEndSeconds: 1.8, posterTimeSeconds: 0.2)
        session.effects.presentation = ScreenshotPresentationPreset.lifted.settings
        session.effects.presentation.canvas = .preset(.square)
        session.removedRanges = [.init(start: 0.6, end: 1)]
        let document = EditableVideoDocument(recording: recording, session: session)
        let preview = try await VideoRenderPipeline.make(document: document, appliesCuts: false)
        let generator = AVAssetImageGenerator(asset: preview.asset)
        generator.videoComposition = preview.videoComposition
        let previewImage: CGImage = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: CMTime(seconds: 0.3, preferredTimescale: 600)) { image, _, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? VideoExportError.exportFailed) }
            }
        }
        XCTAssertEqual(previewImage.width, previewImage.height)
        let url = directory.appendingPathComponent("result.mp4")
        try await VideoExporter.export(document, as: .mp4, preset: .high, progressHandler: nil, to: url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.2, accuracy: 0.08)
        let exported = try await VideoExporter.posterFrame(for: url, at: 0.1)
        XCTAssertEqual(exported.width, previewImage.width)
        XCTAssertEqual(exported.height, previewImage.height)
        // Check both halves of the source survive framing; a larger render canvas
        // must not silently rescale or crop the source before the filter runs.
        let previewRed = pixel(previewImage, x: previewImage.width / 3, y: previewImage.height / 2)
        let exportRed = pixel(exported, x: exported.width / 3, y: exported.height / 2)
        XCTAssertGreaterThan(previewRed.0, 180)
        XCTAssertLessThan(previewRed.2, 60)
        XCTAssertGreaterThan(exportRed.0, 160)
        XCTAssertLessThan(exportRed.2, 80)
        let blue = pixel(exported, x: exported.width * 2 / 3, y: exported.height / 2)
        XCTAssertGreaterThan(blue.2, 160)
        XCTAssertLessThan(blue.0, 80)
    }

    func testAnimatedExportKeepsPresentation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = try await VideoTestMedia.make(in: directory, duration: 0.5)
        var session = VideoEditorSession.fullDuration(0.5)
        session.effects.presentation = ScreenshotPresentationPreset.lifted.settings
        session.effects.presentation.canvas = .preset(.square)
        let url = directory.appendingPathComponent("result.png")
        try await VideoExporter.export(.init(recording: recording, session: session), as: .apng, to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 1)
        XCTAssertEqual(image.width, image.height)
    }

    func testZoomFocusUsesSourcePixelsAndNeverExposesAnEmptyEdge() throws {
        let source = makeRGBAImage(width: 320, height: 240) { x, _ in
            x < 160 ? PixelSample(red: 255, green: 0, blue: 0, alpha: 255) : PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
        }
        let recording = CapturedVideoRecording(sourceURL: URL(fileURLWithPath: "/unused-render-fixture.mp4"), kind: .region,
                                               sourceName: "Fixture", bounds: CGRect(x: 0, y: 0, width: 320, height: 240),
                                               recordedAt: Date(), duration: 2, preferences: .init())
        for (focus, channel) in [(0.05, 0), (0.95, 2)] {
            var session = VideoEditorSession.fullDuration(2)
            session.effects.zooms = [.init(start: 0, end: 2, scale: 2, followsCursor: false, center: .init(x: focus, y: 0.5))]
            let renderer = try VideoFrameRenderer(document: .init(recording: recording, session: session), contentSize: CGSize(width: 320, height: 240),
                                                  cursorImage: VideoRenderAssets.cursor(), clickImage: VideoRenderAssets.click(),
                                                  shortcutImages: [:], timeline: nil)
            let image = try XCTUnwrap(renderer.cgImage(source, at: 1))
            for x in [1, 160, 318] {
                let value = pixel(image, x: x, y: 120)
                XCTAssertGreaterThan(channel == 0 ? value.0 : value.2, 240)
            }
        }
    }

    func testAudioUsesTheSameCutsAndVolumeAsVideo() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = try await VideoTestMedia.make(in: directory, withAudio: true)
        var session = VideoEditorSession(trimStartSeconds: 0.1, trimEndSeconds: 1.9, posterTimeSeconds: 0.1)
        session.removedRanges = [.init(start: 0.5, end: 1.25)]
        session.effects.audioVolume = 0.25
        let document = EditableVideoDocument(recording: recording, session: session)
        let pipeline = try await VideoRenderPipeline.make(document: document, appliesCuts: true)
        let tracks = try await pipeline.asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first as? AVCompositionTrack)
        let segments = track.segments.filter { !$0.isEmpty }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].timeMapping.source.start.seconds, 0.1, accuracy: 0.001)
        XCTAssertEqual(segments[1].timeMapping.source.start.seconds, 1.25, accuracy: 0.001)
        XCTAssertEqual(segments[1].timeMapping.target.start.seconds, 0.4, accuracy: 0.001)
        let parameter = try XCTUnwrap(pipeline.audioMix?.inputParameters.first)
        var start: Float = 0, end: Float = 0
        var range = CMTimeRange.zero
        XCTAssertTrue(parameter.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 0.25)
        let url = directory.appendingPathComponent("sound-edited.mp4")
        try await VideoExporter.export(document, as: .mp4, to: url)
        let exported = AVURLAsset(url: url)
        let exportedAudio = try await exported.loadTracks(withMediaType: .audio)
        XCTAssertEqual(exportedAudio.count, 1)
        let exportedDuration = try await exported.load(.duration).seconds
        XCTAssertEqual(exportedDuration, 1.05, accuracy: 0.08)
    }

    func testVideoInspectorAndExportSheetLayouts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = try await VideoTestMedia.make(in: directory)
        let controller = VideoEditorController(recording: recording)
        controller.polishVideo()
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for section in VideoInspectorSection.allCases {
                controller.inspectorSection = section
                let view = NSHostingView(rootView: VideoInspectorView(controller: controller))
                view.appearance = NSAppearance(named: appearanceName)
                view.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "Video Inspector - \(section.rawValue) - \(appearanceName.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        let export = NSHostingView(rootView: VideoExportOptionsView(preferences: .init(), onExport: { _ in }))
        export.frame = CGRect(x: 0, y: 0, width: 508, height: 420)
        export.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(export.bitmapImageRepForCachingDisplay(in: export.bounds))
        export.cacheDisplay(in: export.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "Video Export"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSettingsSidebarLayoutAtMinimumSize() async throws {
        let suite = "VideoSettingsLayout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, shouldCheckCompatibilityOnLaunch: false)
        model.lifecycle.selectedSettingsTab = .recording
        let settings = CaptureAutomationSettingsView(
            lifecycle: model.lifecycle, capture: model.capture, permissions: model.permissions,
            documents: model.documents, clipboard: model.clipboard, video: model.video,
            guide: model.guide, archive: model.archive, tools: model.tools,
            quickControls: model.quickControls, capabilities: model.capabilities,
            clock: model.environment.systemServices.clock, requestOnboardingPresentation: {},
            checkForProUpdates: {}, resetPreferencesToDefaults: {})
        let view = NSHostingView(rootView: settings)
        view.appearance = NSAppearance(named: .aqua)
        view.frame = CGRect(x: 0, y: 0, width: 820, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "Settings - Minimum Size"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(AppSettingsTab.recording.searchText.localizedStandardContains("microphone"))
        XCTAssertTrue(AppSettingsTab.editorOutput.searchText.localizedStandardContains("filename"))
        XCTAssertTrue(AppSettingsTab.library.searchText.localizedStandardContains("clipboard"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VideoEditingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        guard let bytes = normalizedRGBAPixels(image) else {
            XCTFail("Unable to read rendered frame")
            return (0, 0, 0)
        }
        let index = (y * image.width + x) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }
}
