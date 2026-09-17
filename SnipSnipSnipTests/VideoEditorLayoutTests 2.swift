import AppKit
import AVKit
import SwiftUI
import XCTest
@testable import SnipSnipSnip

@MainActor
final class VideoEditorLayoutTests: XCTestCase {
    func testPlaybackRemainsVisibleForPortraitLandscapeAndSquareVideo() async throws {
        for size in [CGSize(width: 720, height: 1280), CGSize(width: 1280, height: 720), CGSize(width: 720, height: 720)] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let recording = try await VideoTestMedia.make(in: directory, duration: 0.5, width: Int(size.width), height: Int(size.height))
            let controller = VideoEditorController(recording: recording)
            await waitUntil { !controller.isPreparingPreview }
            XCTAssertNil(controller.previewError)

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for section: VideoInspectorSection? in [nil, .trim, .polish] {
                    controller.inspectorSection = section ?? .trim
                    let view = NSHostingView(rootView: VideoEditorWorkspace(
                        controller: controller, inspectorVisible: .constant(section != nil)))
                    view.appearance = NSAppearance(named: appearance)
                    let window = host(view, size: MainWindowLayout.minimumContentSize(for: .video))
                    defer { window.close() }
                    try await Task.sleep(for: .milliseconds(150))
                    view.layoutSubtreeIfNeeded()
                    try assertPlaybackVisible(in: view, window: window, trimming: section == .trim)
                    try attach(view, name: "Video \(Int(size.width))x\(Int(size.height)) - \(section?.rawValue ?? "Review") - \(appearance.rawValue)")

                    // Leave room for expanded permission diagnostics or other transient chrome.
                    window.setContentSize(CGSize(width: 1240, height: 420))
                    try await Task.sleep(for: .milliseconds(80))
                    view.layoutSubtreeIfNeeded()
                    try assertPlaybackVisible(in: view, window: window, trimming: section == .trim)
                }
            }
        }
    }

    func testVideoMainWindowStartsWithPlaybackNotCaptureDiscovery() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "VideoMainWindowLayout-\(UUID().uuidString)"
        let defaults = makeDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let environment = AppEnvironment(defaults: defaults, permissions: TestCapturePermissionService())
        let model = AppModel(defaults: defaults, environment: environment, shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        let recording = try await VideoTestMedia.make(in: directory, width: 720, height: 1280)
        let controller = VideoEditorController(recording: recording)
        model.documents.videoEditorController = controller
        let content = ContentView(
            lifecycle: model.lifecycle, capture: model.capture, permissions: model.permissions,
            documents: model.documents, clipboard: model.clipboard, video: model.video,
            guide: model.guide, tools: model.tools, quickControls: model.quickControls,
            creation: model.creation, capabilities: model.capabilities,
            workflowCoordinator: model.workflowCoordinator, presentWindowQuickCaptureMenu: {},
            performAutomationRequest: { _ in })
        let view = FirstMouseHostingView(rootView: content)
        let window = host(view, size: MainWindowLayout.minimumContentSize(for: .video))
        defer { window.close(); model.documents.videoEditorController = nil }
        await waitUntil { !controller.isPreparingPreview }
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(find("capture.header", in: view), "Video shares the compact workflow header")
        XCTAssertNotNil(find("video.sessionBar", in: view))
        XCTAssertNotNil(find("video.commandBar", in: view))
        XCTAssertNil(find("creation.comparison", in: view), "Generic capture discovery must not appear above Video")
        XCTAssertNil(find("video.inspector.section", in: view), "A new video starts watch-first")
        for identifier in ["video.discard", "video.export", "video.inspector.toggle", "video.polish.show"] {
            let frame = try XCTUnwrap(find(identifier, in: view)).accessibilityFrame()
            XCTAssertTrue(window.convertToScreen(view.convert(view.bounds, to: nil)).contains(frame), "\(identifier) must not hide in title-bar overflow")
        }
        try assertPlaybackVisible(in: view, window: window, trimming: false)
        try attach(view, name: "Video Main Window - First Open - Portrait - 1240x600")

        let original = controller.documentSession
        controller.isPolishing = true
        controller.inspectorSection = .polish
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(find("video.backToContent", in: view))
        XCTAssertNotNil(find("video.tool.Polish", in: view))
        XCTAssertNotNil(find("video.polish.automatic", in: view))
        try assertPlaybackVisible(in: view, window: window, trimming: false)
        try attach(view, name: "Video Main Window - Polish - Portrait - 1240x600")
        controller.isPolishing = false
        controller.inspectorSection = .trim
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.documentSession, original, "Workflow navigation must not alter Video effects or trim")
        XCTAssertEqual(controller.persistenceRevision, 0)
        try assertPlaybackVisible(in: view, window: window, trimming: true)
    }

    func testPlayPauseScrubAndBackToStartDoNotEditTheRecording() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = try await VideoTestMedia.make(in: directory)
        let session = VideoEditorSession(trimStartSeconds: 0.2, trimEndSeconds: 1.8, posterTimeSeconds: 0.2,
                                         removedRanges: [.init(start: 0.2, end: 0.6)])
        let controller = VideoEditorController(recording: recording, session: session)
        await waitUntil { !controller.isPreparingPreview }
        XCTAssertNil(controller.previewError)
        XCTAssertFalse(controller.isPlaying, "Opening a video must not autoplay")
        let original = controller.documentSession
        controller.togglePlayback()
        XCTAssertTrue(controller.isPlaying)
        await waitUntil { controller.currentTimeSeconds > 0.7 }
        XCTAssertGreaterThan(controller.currentTimeSeconds, 0.7, "Play must advance the video, not just change its label")
        controller.togglePlayback()
        XCTAssertFalse(controller.isPlaying)
        controller.scrub(to: 1.2)
        XCTAssertEqual(controller.currentTimeSeconds, 1.2, accuracy: 0.001)
        XCTAssertFalse(controller.isPlaying)
        controller.returnToStart()
        XCTAssertEqual(controller.currentTimeSeconds, 0.6, accuracy: 0.001)
        XCTAssertEqual(controller.documentSession, original)
        XCTAssertEqual(controller.persistenceRevision, 0)
    }

    func testZoomTargetIsVisibleWithoutCursorAndNeverCoversPlayback() async throws {
        for size in [CGSize(width: 320, height: 560), CGSize(width: 560, height: 320)] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let recording = try await VideoTestMedia.make(in: directory, width: Int(size.width), height: Int(size.height))
            var session = VideoEditorSession.fullDuration(2)
            session.effects.showsCursor = false
            session.effects.zooms = [.init(start: 0.2, end: 1.8, scale: 2, followsCursor: false)]
            let controller = VideoEditorController(recording: recording, session: session)
            await waitUntil { !controller.isPreparingPreview }
            XCTAssertNil(controller.previewError)
            controller.selectZoom(session.effects.zooms[0].id)

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let view = NSHostingView(rootView: VideoEditorWorkspace(controller: controller, inspectorVisible: .constant(true)))
                view.appearance = NSAppearance(named: appearance)
                let window = host(view, size: CGSize(width: 1240, height: 420))
                defer { window.close() }
                await waitUntil(timeoutNanoseconds: 5_000_000_000) { self.find("video.zoom.target", in: view) != nil }
                view.layoutSubtreeIfNeeded()
                let target = try XCTUnwrap(find("video.zoom.target", in: view)).accessibilityFrame()
                let stage = try XCTUnwrap(find("video.preview", in: view)).accessibilityFrame()
                let controls = try XCTUnwrap(find("video.playback.controls", in: view)).accessibilityFrame()
                XCTAssertTrue(stage.insetBy(dx: -1, dy: -1).contains(target))
                XCTAssertGreaterThan(target.height, 60)
                XCTAssertFalse(target.intersects(controls))
                try assertPlaybackVisible(in: view, window: window, trimming: false)
                try attach(view, name: "Zoom Target - No Cursor - \(Int(size.width))x\(Int(size.height)) - \(appearance.rawValue)")
                controller.previewZoom(session.effects.zooms[0].id)
                await waitUntil { self.find("video.zoom.targetEditor", in: view) == nil }
                XCTAssertTrue(controller.isPlaying)
                XCTAssertNil(find("video.zoom.targetEditor", in: view), "Editing guides must disappear during playback")
                controller.pause()
                controller.selectZoom(session.effects.zooms[0].id)
                XCTAssertEqual(controller.session, session)
                XCTAssertEqual(controller.persistenceRevision, 0)
            }
        }
    }

    private func host<Content: View>(_ view: NSHostingView<Content>, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 40, y: 100), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = CGRect(origin: .zero, size: size)
        window.contentView = view
        window.orderFront(nil)
        return window
    }

    private func assertPlaybackVisible(in view: NSView, window: NSWindow, trimming: Bool) throws {
        let visible = window.convertToScreen(view.convert(view.bounds, to: nil)).insetBy(dx: -1, dy: -1)
        for identifier in ["video.playback.toggle", "video.playback.start", "video.playback.time",
                           trimming ? "video.trim.playhead" : "video.playback.seek"] {
            let element = try XCTUnwrap(find(identifier, in: view), "Missing \(identifier)")
            let frame = element.accessibilityFrame()
            XCTAssertGreaterThan(frame.width, 0, identifier)
            XCTAssertGreaterThan(frame.height, 0, identifier)
            XCTAssertTrue(visible.contains(frame), "\(identifier) outside window: \(frame), visible: \(visible)")
        }
        let player = try XCTUnwrap(descendant(AVPlayerView.self, in: view))
        let playerFrame = window.convertToScreen(player.convert(player.bounds, to: nil))
        XCTAssertTrue(visible.contains(playerFrame), "Player must fit, not crop outside the window")
        XCTAssertGreaterThan(playerFrame.height, 60)
        let controls = try XCTUnwrap(find("video.playback.controls", in: view)).accessibilityFrame()
        XCTAssertFalse(playerFrame.intersects(controls), "Media must never cover playback controls")
    }

    private func find(_ identifier: String, in object: Any, depth: Int = 0) -> (any NSAccessibilityProtocol)? {
        guard depth < 50, let element = object as? any NSAccessibilityProtocol else { return nil }
        if element.accessibilityIdentifier() == identifier { return element }
        for child in element.accessibilityChildren() ?? [] {
            if let match = find(identifier, in: child, depth: depth + 1) { return match }
        }
        return nil
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private func attach(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VideoEditorLayoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
