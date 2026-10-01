import AppKit
import AVKit
import SwiftUI
import XCTest
@testable import SnipSnipSnip

@MainActor
final class VideoEditorLayoutTests: XCTestCase {
    func testCompletionNoticePreservesPlayerAndPlaybackControlFrames() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = try await VideoTestMedia.make(in: directory, duration: 0.5)
        let controller = VideoEditorController(recording: recording)
        await waitUntil { !controller.isPreparingPreview }
        let view = NSHostingView(rootView: VideoEditorWorkspace(
            controller: controller, inspectorVisible: .constant(false)))
        let window = host(view, size: CGSize(width: 1240, height: 600))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let player = try XCTUnwrap(descendant(AVPlayerView.self, in: view))
        let playerFrame = player.convert(player.bounds, to: view)
        let controlsFrame = try XCTUnwrap(find("video.playback.controls", in: view)).accessibilityFrame()

        let url = directory.appendingPathComponent("Exported.mp4")
        controller.showStatus(EditorNotice(message: "Exported MP4 to Exported.mp4.",
                                           action: .reveal(url), dismissalDelaySeconds: nil))
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(player.convert(player.bounds, to: view), playerFrame)
        XCTAssertEqual(try XCTUnwrap(find("video.playback.controls", in: view)).accessibilityFrame(), controlsFrame)
        XCTAssertEqual(controller.statusNotice?.action, .reveal(url))
        XCTAssertNotNil(find("video.notice", in: view))
        controller.dismissStatus()
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(player.convert(player.bounds, to: view), playerFrame)
        XCTAssertNil(controller.statusNotice)
    }

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
        try assertPlaybackVisible(in: view, window: window, trimming: false)
        try attach(view, name: "Video Main Window - Polish - Portrait - 1240x600")
        controller.isPolishing = false
        controller.inspectorSection = .trim
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.documentSession, original, "Workflow navigation must not alter Video effects or trim")
        XCTAssertEqual(controller.persistenceRevision, 0)
        // This ContentView has no SwiftUI Scene lifecycle, so its SceneStorage
        // inspector binding remains at the watch-first default. Inspector
        // transitions are covered below with a mounted, mutable State binding.
        try assertPlaybackVisible(in: view, window: window, trimming: false)
    }

    func testSectionNavigationOpensInspectorWithoutEditingVideoOrHidingPlayback() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = try await VideoTestMedia.make(in: directory, width: 320, height: 560)
        let controller = VideoEditorController(recording: recording)
        await waitUntil { !controller.isPreparingPreview }
        XCTAssertNil(controller.previewError)
        let original = controller.documentSession
        var didAppear = false
        let view = NSHostingView(rootView: VideoInspectorLifecycleFixture(
            controller: controller, onAppear: { didAppear = true }))
        let window = host(view, size: CGSize(width: 1240, height: 600))
        defer { window.close() }
        // AX nodes are available before onAppear installs the section observer.
        // Wait for the actual mounted lifecycle before testing navigation.
        await waitUntil { didAppear }
        XCTAssertTrue(didAppear, "The Video editor must finish mounting before section navigation")
        await waitUntil { self.find("video.playback.seek", in: view) != nil }
        XCTAssertNil(find("video.inspector.section", in: view))

        controller.isPolishing = true
        controller.inspectorSection = .polish
        await waitUntil {
            guard let polish = self.find("video.polish.automatic", in: window) else { return false }
            let frame = polish.accessibilityFrame()
            return frame.width > 0 && frame.height > 0
                && window.convertToScreen(window.contentLayoutRect).contains(frame)
        }
        view.layoutSubtreeIfNeeded()
        let polish = try XCTUnwrap(find("video.polish.automatic", in: window))
        let visible = window.convertToScreen(window.contentLayoutRect)
        let polishFrame = polish.accessibilityFrame()
        XCTAssertGreaterThan(polishFrame.width, 0)
        XCTAssertGreaterThan(polishFrame.height, 0)
        XCTAssertTrue(visible.contains(polishFrame), "Polish must fit inside native window content: \(polishFrame), visible: \(visible)")
        try assertPlaybackVisible(in: view, window: window, trimming: false)
        try attach(view, name: "Video Inspector - Polish - Portrait")

        controller.isPolishing = false
        controller.inspectorSection = .trim
        await waitUntil { self.find("video.trim.playhead", in: view) != nil }
        view.layoutSubtreeIfNeeded()
        try assertPlaybackVisible(in: view, window: window, trimming: true)
        XCTAssertEqual(controller.documentSession, original, "Inspector navigation must not alter Video effects or trim")
        XCTAssertEqual(controller.persistenceRevision, 0)
        try attach(view, name: "Video Inspector - Trim - Portrait")
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
        HostedViewTestSupport.host(view, size: size)
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
        HostedViewTestSupport.find(identifier, in: object, depth: depth)
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private func attach(_ view: NSView, name: String) throws {
        add(try HostedViewTestSupport.attachment(of: view, name: name))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VideoEditorLayoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct VideoInspectorLifecycleFixture: View {
    @ObservedObject var controller: VideoEditorController
    let onAppear: () -> Void
    @State private var inspectorVisible = false

    var body: some View {
        VideoEditorView(controller: controller, inspectorVisible: $inspectorVisible)
            .onAppear(perform: onAppear)
    }
}
