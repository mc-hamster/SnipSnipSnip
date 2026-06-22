import AppKit
import Foundation

nonisolated protocol ConnectedDevicePreviewPlatformSession: Sendable {
    nonisolated func setRuntimeIssueHandler(_ handler: (@Sendable (ConnectedDeviceCaptureError) -> Void)?)
    func start() async throws
    nonisolated func stop()
    nonisolated func captureLatestScreenshot() throws -> CapturedScreenshot
    func startRecording() async throws
    func stopRecording() async throws -> CapturedVideoRecording
    @MainActor func makePreviewView() -> NSView
    @MainActor func updatePreviewView(_ view: NSView)
    @MainActor func dismantlePreviewView(_ view: NSView)
}

nonisolated final class ConnectedDevicePreviewSession: @unchecked Sendable {
    private let platformSession: any ConnectedDevicePreviewPlatformSession

    init(platformSession: any ConnectedDevicePreviewPlatformSession) {
        self.platformSession = platformSession
    }

    deinit {
        stop()
    }

    func setRuntimeIssueHandler(_ handler: (@Sendable (ConnectedDeviceCaptureError) -> Void)?) {
        platformSession.setRuntimeIssueHandler(handler)
    }

    func start() async throws {
        try await platformSession.start()
    }

    func stop() {
        platformSession.stop()
    }

    func captureLatestScreenshot() throws -> CapturedScreenshot {
        try platformSession.captureLatestScreenshot()
    }

    func startRecording() async throws {
        try await platformSession.startRecording()
    }

    func stopRecording() async throws -> CapturedVideoRecording {
        try await platformSession.stopRecording()
    }

    @MainActor
    func makePreviewView() -> NSView {
        platformSession.makePreviewView()
    }

    @MainActor
    func updatePreviewView(_ view: NSView) {
        platformSession.updatePreviewView(view)
    }

    @MainActor
    func dismantlePreviewView(_ view: NSView) {
        platformSession.dismantlePreviewView(view)
    }
}
