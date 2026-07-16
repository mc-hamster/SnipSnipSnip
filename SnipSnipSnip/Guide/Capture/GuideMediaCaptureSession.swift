import CoreMedia
import Foundation

@MainActor
final class GuideMediaCaptureSession: ScreenRecordingPlatformEventSink, ScreenRecordingPlatformFrameSink, @unchecked Sendable {
    let source: GuideCaptureSource
    let capturedDisplayFrame: CGRect
    let captureDisplayID: CGDirectDisplayID
    let frameBuffer = GuideFrameBuffer()
    private let platformSession: any ScreenRecordingPlatformSession
    private let screenRecordingPlatform: any ScreenRecordingPlatform
    private let files: any FileSystemServicing
    private let sourceVideoEnabled: Bool
    private var configuration: ScreenRecordingConfiguration
    private var activeToken: ScreenRecordingSegmentToken?
    private var activeURL: URL?
    private var segmentStart: Date?
    private var finishedSegments: [(GuideTimelineSegment, URL)] = []
    var completedSegments: [(GuideTimelineSegment, URL)] { finishedSegments }
    private var segmentContinuations: [ScreenRecordingSegmentToken: CheckedContinuation<Void, Error>] = [:]
    private var segmentFinalizationTimeouts: [ScreenRecordingSegmentToken: Task<Void, Never>] = [:]
    private var audioLevels = ScreenRecordingAudioLevels()
    var audioLevelHandler: ((ScreenRecordingAudioLevels) -> Void)?

    init(
        source: GuideCaptureSource,
        capturedDisplayFrame: CGRect,
        captureDisplayID: CGDirectDisplayID,
        platformSession: any ScreenRecordingPlatformSession,
        screenRecordingPlatform: any ScreenRecordingPlatform = LiveScreenRecordingPlatform(),
        configuration: ScreenRecordingConfiguration? = nil,
        files: any FileSystemServicing,
        sourceVideoEnabled: Bool
    ) {
        self.source = source
        self.capturedDisplayFrame = capturedDisplayFrame
        self.captureDisplayID = captureDisplayID
        self.platformSession = platformSession
        self.screenRecordingPlatform = screenRecordingPlatform
        self.configuration = configuration ?? ScreenRecordingConfiguration(
            width: Int(max(capturedDisplayFrame.width, 1)),
            height: Int(max(capturedDisplayFrame.height, 1)),
            minimumFrameInterval: CMTime(value: 1, timescale: 30),
            captureResolution: .best,
            showsCursor: false,
            showsMouseClicks: false,
            capturesAudio: false,
            capturesMicrophone: false
        )
        self.files = files
        self.sourceVideoEnabled = sourceVideoEnabled
        platformSession.setEventSink(self)
        platformSession.setFrameSink(self)
    }

    static func make(
        source: GuideCaptureSource,
        preferences: GuideCapturePreferences,
        systemServices: AppSystemServices
    ) async throws -> GuideMediaCaptureSession {
        let screen = try captureScreen(for: source, screens: systemServices.screens, mouse: systemServices.mouse)
        let displayFrame = CGDisplayBounds(screen.displayID)
        // Capture only the Guide's actual content from the outset. The previous
        // implementation recorded the entire display and then performed a second,
        // full-duration AVFoundation export just to crop the source media when Stop
        // was pressed. On a long Guide that made finalization proportional to the
        // recording length and needlessly CPU-bound.
        let captureFrame = GuideSourceMediaGeometry.captureFrame(for: source, within: displayFrame)
        let sourceRect = CaptureDisplayTransform(
            captureFrame: displayFrame,
            overlayFrame: screen.frame
        )
        .captureLocalRect(fromCaptureGlobalRect: captureFrame)
        let scale = max(screen.backingScaleFactor, 1)
        let target = recordingTarget(
            screen: screen,
            displayFrame: displayFrame,
            scale: scale,
            sourceRect: sourceRect,
            includeMenuBar: preferences.menuBarIncludedForDisplays
        )
        let configuration = ScreenRecordingConfiguration(
            width: Int(captureFrame.width * scale),
            height: Int(captureFrame.height * scale),
            minimumFrameInterval: CMTime(value: 1, timescale: CMTimeScale(max(preferences.framesPerSecond, 1))),
            queueDepth: 8,
            captureResolution: .best,
            showsCursor: false,
            showsMouseClicks: false,
            capturesAudio: preferences.capturesSystemAudio,
            capturesMicrophone: preferences.capturesMicrophone,
            excludesCurrentProcessAudio: false,
            hidesDesktopWindows: preferences.hidesDesktopIcons
        )
        let platformSession = try await systemServices.screenRecordingPlatform.makeSession(target: target, configuration: configuration)
        return GuideMediaCaptureSession(
            source: source,
            capturedDisplayFrame: captureFrame,
            captureDisplayID: screen.displayID,
            platformSession: platformSession,
            screenRecordingPlatform: systemServices.screenRecordingPlatform,
            configuration: configuration,
            files: systemServices.files,
            sourceVideoEnabled: preferences.sourceVideoEnabled
        )
    }

    nonisolated static func recordingTarget(
        screen: ScreenDisplaySnapshot,
        displayFrame: CGRect,
        scale: CGFloat,
        sourceRect: CGRect,
        includeMenuBar: Bool
    ) -> ScreenRecordingTarget {
        ScreenRecordingTarget(
            source: .display(
                screen.displayID,
                // The Guide HUD and its preview panels use NSWindow.sharingType
                // .none, so they remain private without hiding every other
                // SnipSnipSnip window the person may be demonstrating.
                excludingProcessID: nil,
                includeMenuBar: includeMenuBar
            ),
            contentBounds: displayFrame,
            pointPixelScale: scale,
            sourceRect: sourceRect
        )
    }

    func start() async throws {
        try await platformSession.startCapture()
        if sourceVideoEnabled { try startSegment() }
    }

    func pause() async throws {
        try await finishActiveSegment()
        frameBuffer.flush()
    }

    func resume() throws {
        frameBuffer.flush()
        if sourceVideoEnabled { try startSegment() }
    }

    func updateAudioOptions(capturesSystemAudio: Bool, capturesMicrophone: Bool) async throws {
        if capturesMicrophone && !configuration.capturesMicrophone {
            try await screenRecordingPlatform.requestMicrophoneAccess()
        }
        guard capturesSystemAudio != configuration.capturesAudio || capturesMicrophone != configuration.capturesMicrophone else { return }
        if sourceVideoEnabled { try await finishActiveSegment() }
        configuration.capturesAudio = capturesSystemAudio
        configuration.capturesMicrophone = capturesMicrophone
        try await platformSession.updateConfiguration(configuration)
        audioLevels = ScreenRecordingAudioLevels(
            system: capturesSystemAudio ? audioLevels.system : 0,
            microphone: capturesMicrophone ? audioLevels.microphone : 0
        )
        audioLevelHandler?(audioLevels)
        if sourceVideoEnabled { try startSegment() }
    }

    func stop() async throws -> [(GuideTimelineSegment, URL)] {
        try await finishActiveSegment()
        try await platformSession.stopCapture()
        platformSession.setFrameSink(nil)
        platformSession.setEventSink(nil)
        audioLevels = ScreenRecordingAudioLevels()
        audioLevelHandler?(audioLevels)
        return finishedSegments
    }

    /// Abandons media that will immediately be deleted instead of waiting for the recording
    /// encoder's finalization callback. Discard must remain responsive even before the encoder
    /// has produced its first frame.
    func discard() async {
        if let token = activeToken {
            try? platformSession.removeRecordingSegment(token)
        }
        let unfinishedURL = activeURL
        activeToken = nil
        activeURL = nil
        segmentStart = nil
        try? await platformSession.stopCapture()
        platformSession.setFrameSink(nil)
        platformSession.setEventSink(nil)
        audioLevels = ScreenRecordingAudioLevels()
        audioLevelHandler?(audioLevels)
        if let unfinishedURL { try? files.removeItem(at: unfinishedURL) }
        finishedSegments.forEach { try? files.removeItem(at: $0.1) }
        finishedSegments.removeAll()
        for continuation in segmentContinuations.values {
            continuation.resume(throwing: CancellationError())
        }
        segmentContinuations.removeAll()
        segmentFinalizationTimeouts.values.forEach { $0.cancel() }
        segmentFinalizationTimeouts.removeAll()
    }

    func newestFrame(before timestamp: CMTime) -> GuideBufferedFrame? {
        frameBuffer.newestFrame(before: timestamp)
    }

    nonisolated func recordingPlatformDidOutputFrame(_ frame: GuideBufferedFrame) {
        frameBuffer.append(frame)
    }

    func recordingPlatformSession(_ session: any ScreenRecordingPlatformSession, didFinishSegment token: ScreenRecordingSegmentToken) {
        resolveFinalization(for: token)
    }

    func recordingPlatformSession(_ session: any ScreenRecordingPlatformSession, segment token: ScreenRecordingSegmentToken, didFailWith error: Error) {
        resolveFinalization(for: token, error: error)
    }

    func recordingPlatformSession(_ session: any ScreenRecordingPlatformSession, didStopWith error: Error) {
        segmentFinalizationTimeouts.values.forEach { $0.cancel() }
        segmentFinalizationTimeouts.removeAll()
        for continuation in segmentContinuations.values { continuation.resume(throwing: error) }
        segmentContinuations.removeAll()
    }

    func recordingPlatformSession(
        _ session: any ScreenRecordingPlatformSession,
        didUpdateAudioLevel level: Double,
        source: ScreenRecordingAudioSource
    ) {
        switch source {
        case .system where configuration.capturesAudio:
            audioLevels.system = min(max(level, 0), 1)
        case .microphone where configuration.capturesMicrophone:
            audioLevels.microphone = min(max(level, 0), 1)
        default:
            return
        }
        audioLevelHandler?(audioLevels)
    }

    private func startSegment() throws {
        guard activeToken == nil else { return }
        let url = files.temporaryDirectory.appendingPathComponent("SnipSnipSnip-Guide-Segment-\(UUID().uuidString).mp4")
        try? files.removeItem(at: url)
        activeURL = url
        segmentStart = Date()
        activeToken = try platformSession.startRecordingSegment(to: url)
    }

    private func finishActiveSegment() async throws {
        guard let token = activeToken, let url = activeURL, let startedAt = segmentStart else { return }
        activeToken = nil
        activeURL = nil
        segmentStart = nil
        try await withCheckedThrowingContinuation { continuation in
            segmentContinuations[token] = continuation
            segmentFinalizationTimeouts[token] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                // Removing a recording output normally invokes its delegate. If the callback is
                // lost during stream shutdown, continue with the file ScreenCaptureKit closed
                // instead of leaving Guide permanently stuck in Finishing.
                self?.resolveFinalization(for: token)
            }
            do { try platformSession.removeRecordingSegment(token) }
            catch {
                resolveFinalization(for: token, error: error)
            }
        }
        // `sourceRect` above applies the privacy crop in ScreenCaptureKit. Retain
        // this hardware-produced segment directly; a second export here would
        // re-encode every frame and make a long Guide appear to hang on Stop.
        let segment = GuideTimelineSegment(asset: "media/segments/\(UUID().uuidString.lowercased()).mp4", startedAt: startedAt, duration: Date().timeIntervalSince(startedAt))
        finishedSegments.append((segment, url))
    }

    private func resolveFinalization(for token: ScreenRecordingSegmentToken, error: Error? = nil) {
        segmentFinalizationTimeouts.removeValue(forKey: token)?.cancel()
        guard let continuation = segmentContinuations.removeValue(forKey: token) else { return }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    private static func captureScreen(
        for source: GuideCaptureSource,
        screens: any ScreenTopologyProviding,
        mouse: any MouseLocationProviding
    ) throws -> ScreenDisplaySnapshot {
        let point: CGPoint
        switch source {
        case .window(_, _, _, let frame): point = CGPoint(x: frame.midX, y: frame.midY)
        case .app(_, _, _, let frame): point = CGPoint(x: frame.midX, y: frame.midY)
        case .region(let rect): point = CGPoint(x: rect.midX, y: rect.midY)
        case .displays(.selected(let ids)):
            if let id = ids.first, let screen = screens.screen(withDisplayID: id) { return screen }
            guard let screen = screens.screen(containing: mouse.appKitGlobalLocation) ?? screens.mainScreen ?? screens.screens.first else {
                throw ScreenCapturePlatformError.noDisplays
            }
            return screen
        case .displays(.current), .displays(.all):
            guard let screen = screens.screen(containing: mouse.appKitGlobalLocation) ?? screens.mainScreen ?? screens.screens.first else {
                throw ScreenCapturePlatformError.noDisplays
            }
            return screen
        }
        let captureSpaceScreen = screens.screens.first { CGDisplayBounds($0.displayID).contains(point) }
        guard let screen = captureSpaceScreen ?? screens.mainScreen ?? screens.screens.first else {
            throw ScreenCapturePlatformError.noDisplays
        }
        return screen
    }
}
