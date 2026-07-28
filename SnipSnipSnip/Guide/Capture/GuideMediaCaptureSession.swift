import CoreMedia
import Foundation

nonisolated struct GuideResolvedCaptureSource: Equatable, Sendable {
    let source: GuideCaptureSource
    let windowID: CGWindowID?
    let captureFrame: CGRect
    let displayID: CGDirectDisplayID
    let pointPixelScale: CGFloat
    let target: ScreenRecordingTarget
}

nonisolated enum GuideSourceResolutionError: LocalizedError, Equatable {
    case regionSpansDisplays
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .regionSpansDisplays:
            "Guide regions must stay on one display. Select the region again without crossing a display boundary."
        case .sourceUnavailable:
            "The window or app Guide was following is no longer available. Completed steps are preserved."
        }
    }
}

@MainActor
final class GuideMediaCaptureSession: ScreenRecordingPlatformEventSink, ScreenRecordingPlatformFrameSink, @unchecked Sendable {
    private(set) var resolvedSource: GuideResolvedCaptureSource
    var source: GuideCaptureSource { resolvedSource.source }
    var capturedDisplayFrame: CGRect { resolvedSource.captureFrame }
    var captureDisplayID: CGDirectDisplayID { resolvedSource.displayID }
    var pointPixelScale: CGFloat { resolvedSource.pointPixelScale }
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
    var interruptionHandler: ((Error) -> Void)?
    private(set) var interruptionError: Error?
    var isInterrupted: Bool { interruptionError != nil }

    init(
        source: GuideCaptureSource,
        capturedDisplayFrame: CGRect,
        captureDisplayID: CGDirectDisplayID,
        pointPixelScale: CGFloat = 1,
        platformSession: any ScreenRecordingPlatformSession,
        screenRecordingPlatform: any ScreenRecordingPlatform = LiveScreenRecordingPlatform(),
        configuration: ScreenRecordingConfiguration? = nil,
        files: any FileSystemServicing,
        sourceVideoEnabled: Bool
    ) {
        let scale = max(pointPixelScale, 1)
        self.resolvedSource = GuideResolvedCaptureSource(
            source: source,
            windowID: source.windowID,
            captureFrame: capturedDisplayFrame,
            displayID: captureDisplayID,
            pointPixelScale: scale,
            target: ScreenRecordingTarget(
                source: .display(captureDisplayID, excludingProcessID: nil, includeMenuBar: true),
                contentBounds: capturedDisplayFrame,
                pointPixelScale: scale,
                sourceRect: capturedDisplayFrame
            )
        )
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
        try await requestMicrophoneAccessIfNeeded(
            preferences: preferences,
            platform: systemServices.screenRecordingPlatform
        )
        let content = try await systemServices.screenRecordingPlatform.shareableContent()
        let resolved = try resolve(
            source: source,
            content: content,
            screens: systemServices.screens,
            preferredWindowID: source.windowID,
            previousFrame: source.initialFrame,
            includeMenuBar: preferences.menuBarIncludedForDisplays
        )
        let configuration = configuration(
            for: resolved,
            preferences: preferences,
            capturesSystemAudio: preferences.capturesSystemAudio,
            capturesMicrophone: preferences.capturesMicrophone
        )
        try GuideStorageGuardrails.ensureCanStartCapture(
            pixelWidth: configuration.width,
            pixelHeight: configuration.height,
            framesPerSecond: preferences.framesPerSecond,
            sourceVideoEnabled: preferences.sourceVideoEnabled,
            temporaryDirectory: systemServices.files.temporaryDirectory
        )
        let platformSession = try await systemServices.screenRecordingPlatform.makeSession(
            target: resolved.target,
            configuration: configuration
        )
        let session = GuideMediaCaptureSession(
            source: resolved.source,
            capturedDisplayFrame: resolved.captureFrame,
            captureDisplayID: resolved.displayID,
            pointPixelScale: resolved.pointPixelScale,
            platformSession: platformSession,
            screenRecordingPlatform: systemServices.screenRecordingPlatform,
            configuration: configuration,
            files: systemServices.files,
            sourceVideoEnabled: preferences.sourceVideoEnabled
        )
        session.resolvedSource = resolved
        return session
    }

    nonisolated static func requestMicrophoneAccessIfNeeded(
        preferences: GuideCapturePreferences,
        platform: any ScreenRecordingPlatform
    ) async throws {
        guard preferences.sourceVideoEnabled, preferences.capturesMicrophone else { return }
        try await platform.requestMicrophoneAccess()
    }

    nonisolated private static func configuration(
        for resolved: GuideResolvedCaptureSource,
        preferences: GuideCapturePreferences,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool
    ) -> ScreenRecordingConfiguration {
        ScreenRecordingConfiguration(
            width: Int((resolved.captureFrame.width * resolved.pointPixelScale).rounded(.up)),
            height: Int((resolved.captureFrame.height * resolved.pointPixelScale).rounded(.up)),
            minimumFrameInterval: CMTime(value: 1, timescale: CMTimeScale(max(preferences.framesPerSecond, 1))),
            queueDepth: 8,
            captureResolution: .best,
            showsCursor: false,
            showsMouseClicks: false,
            capturesAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone,
            excludesCurrentProcessAudio: false,
            hidesDesktopWindows: preferences.hidesDesktopIcons
        )
    }

    nonisolated static func resolve(
        source: GuideCaptureSource,
        content: ScreenContentSnapshot,
        screens: any ScreenTopologyProviding,
        preferredWindowID: CGWindowID?,
        previousFrame: CGRect?,
        includeMenuBar: Bool
    ) throws -> GuideResolvedCaptureSource {
        let resolvedSource: GuideCaptureSource
        let windowID: CGWindowID?
        let captureFrame: CGRect
        let display: DisplaySnapshot
        let targetSource: ScreenRecordingTargetSource
        let sourceRect: CGRect?

        switch source {
        case .window(let id, let pid, let name, _):
            guard let window = content.windows.first(where: { $0.id == id && $0.isOnScreen }) else {
                throw GuideSourceResolutionError.sourceUnavailable
            }
            resolvedSource = .window(id: id, ownerPID: pid, name: name, frame: window.frame.gscIntegralStandardized)
            windowID = id
            captureFrame = window.frame.gscIntegralStandardized
            guard let match = displayContainingMost(of: captureFrame, displays: content.displays) else {
                throw ScreenRecordingError.selectedDisplayUnavailable
            }
            display = match
            targetSource = .window(id)
            sourceRect = nil
        case .app(let pid, let bundleIdentifier, let name, let initialFrame):
            let candidates = content.windows.filter { $0.ownerPID == pid && $0.isOnScreen && $0.layer == 0 }
            guard let window = preferredWindow(in: candidates, preferredWindowID: preferredWindowID, previousFrame: previousFrame ?? initialFrame) else {
                throw GuideSourceResolutionError.sourceUnavailable
            }
            resolvedSource = .app(processID: pid, bundleIdentifier: bundleIdentifier, name: name, initialFrame: window.frame.gscIntegralStandardized)
            windowID = window.id
            guard let match = displayContainingMost(of: window.frame, displays: content.displays) else {
                throw ScreenRecordingError.selectedDisplayUnavailable
            }
            display = match
            captureFrame = GuideSourceMediaGeometry.captureFrame(for: resolvedSource, within: display.frame)
            targetSource = .display(display.displayID, excludingProcessID: nil, includeMenuBar: includeMenuBar)
            sourceRect = captureLocalRect(captureFrame, display: display, screens: screens)
        case .region(let rect):
            let containing = content.displays.filter { $0.frame.insetBy(dx: -1, dy: -1).contains(rect) }
            guard let match = containing.first else { throw GuideSourceResolutionError.regionSpansDisplays }
            resolvedSource = source
            windowID = nil
            display = match
            captureFrame = rect.gscIntegralStandardized
            targetSource = .display(display.displayID, excludingProcessID: nil, includeMenuBar: includeMenuBar)
            sourceRect = captureLocalRect(captureFrame, display: display, screens: screens)
        case .displays(.selected(let identifiers)):
            guard let id = identifiers.first,
                  let match = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenRecordingError.selectedDisplayUnavailable
            }
            resolvedSource = source
            windowID = nil
            display = match
            captureFrame = match.frame.gscIntegralStandardized
            targetSource = .display(match.displayID, excludingProcessID: nil, includeMenuBar: includeMenuBar)
            sourceRect = captureLocalRect(captureFrame, display: match, screens: screens)
        case .displays(.current), .displays(.all):
            let fallbackID = screens.mainScreen?.displayID
            guard let match = content.displays.first(where: { $0.displayID == fallbackID }) ?? content.displays.first else {
                throw ScreenRecordingError.selectedDisplayUnavailable
            }
            resolvedSource = source
            windowID = nil
            display = match
            captureFrame = match.frame.gscIntegralStandardized
            targetSource = .display(match.displayID, excludingProcessID: nil, includeMenuBar: includeMenuBar)
            sourceRect = captureLocalRect(captureFrame, display: match, screens: screens)
        }

        guard captureFrame.width > 0, captureFrame.height > 0 else {
            throw ScreenRecordingError.selectedDisplayUnavailable
        }
        let scale = max(screens.screen(withDisplayID: display.displayID)?.backingScaleFactor ?? display.scale, 1)
        let contentBounds: CGRect
        if case .window = targetSource { contentBounds = captureFrame }
        else { contentBounds = display.frame }
        let target = ScreenRecordingTarget(
            source: targetSource,
            contentBounds: contentBounds,
            pointPixelScale: scale,
            sourceRect: sourceRect
        )
        return GuideResolvedCaptureSource(
            source: resolvedSource,
            windowID: windowID,
            captureFrame: captureFrame,
            displayID: display.displayID,
            pointPixelScale: scale,
            target: target
        )
    }

    nonisolated private static func preferredWindow(
        in candidates: [ScreenWindowSnapshot],
        preferredWindowID: CGWindowID?,
        previousFrame: CGRect
    ) -> ScreenWindowSnapshot? {
        if let preferredWindowID, let exact = candidates.first(where: { $0.id == preferredWindowID }) { return exact }
        return candidates.max { left, right in
            let leftOverlap = area(left.frame.intersection(previousFrame))
            let rightOverlap = area(right.frame.intersection(previousFrame))
            if leftOverlap != rightOverlap { return leftOverlap < rightOverlap }
            return area(left.frame) < area(right.frame)
        }
    }

    nonisolated private static func displayContainingMost(of frame: CGRect, displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        displays.filter { $0.frame.intersects(frame) }.max {
            area($0.frame.intersection(frame)) < area($1.frame.intersection(frame))
        }
    }

    nonisolated private static func area(_ rect: CGRect) -> CGFloat {
        max(rect.width, 0) * max(rect.height, 0)
    }

    nonisolated private static func captureLocalRect(
        _ captureFrame: CGRect,
        display: DisplaySnapshot,
        screens: any ScreenTopologyProviding
    ) -> CGRect {
        CaptureDisplayTransform(
            captureFrame: display.frame,
            overlayFrame: screens.screen(withDisplayID: display.displayID)?.frame ?? display.overlayFrame
        ).captureLocalRect(fromCaptureGlobalRect: captureFrame)
    }

    nonisolated static func recordingTarget(
        screen: ScreenDisplaySnapshot,
        displayFrame: CGRect,
        scale: CGFloat,
        sourceRect: CGRect,
        includeMenuBar: Bool
    ) -> ScreenRecordingTarget {
        recordingTarget(
            displayID: screen.displayID,
            displayFrame: displayFrame,
            scale: scale,
            sourceRect: sourceRect,
            includeMenuBar: includeMenuBar
        )
    }

    nonisolated private static func recordingTarget(
        displayID: CGDirectDisplayID,
        displayFrame: CGRect,
        scale: CGFloat,
        sourceRect: CGRect,
        includeMenuBar: Bool
    ) -> ScreenRecordingTarget {
        ScreenRecordingTarget(
            source: .display(
                displayID,
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
        interruptionError = nil
        try await platformSession.startCapture()
        if sourceVideoEnabled { try startSegment() }
    }

    func pause() async throws {
        if let interruptionError { throw interruptionError }
        try await finishActiveSegment()
        frameBuffer.flush()
    }

    func resume() throws {
        if let interruptionError { throw interruptionError }
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

    func retarget(to resolved: GuideResolvedCaptureSource, preferences: GuideCapturePreferences) async throws {
        guard interruptionError == nil, resolved != resolvedSource else { return }
        if sourceVideoEnabled { try await finishActiveSegment() }
        let updated = Self.configuration(
            for: resolved,
            preferences: preferences,
            capturesSystemAudio: configuration.capturesAudio,
            capturesMicrophone: configuration.capturesMicrophone
        )
        try await platformSession.updateTarget(resolved.target, configuration: updated)
        configuration = updated
        resolvedSource = resolved
        frameBuffer.flush()
        if sourceVideoEnabled { try startSegment() }
    }

    func stop() async throws -> [(GuideTimelineSegment, URL)] {
        if interruptionError != nil {
            platformSession.setFrameSink(nil)
            platformSession.setEventSink(nil)
            audioLevels = ScreenRecordingAudioLevels()
            audioLevelHandler?(audioLevels)
            return finishedSegments
        }
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
        interruptionError = error
        segmentFinalizationTimeouts.values.forEach { $0.cancel() }
        segmentFinalizationTimeouts.removeAll()
        for continuation in segmentContinuations.values { continuation.resume(throwing: error) }
        segmentContinuations.removeAll()
        if let token = activeToken {
            try? platformSession.removeRecordingSegment(token)
        }
        let interruptedURL = activeURL
        activeToken = nil
        activeURL = nil
        segmentStart = nil
        if let interruptedURL { try? files.removeItem(at: interruptedURL) }
        audioLevels = ScreenRecordingAudioLevels()
        audioLevelHandler?(audioLevels)
        interruptionHandler?(error)
        // The coordinator flushes completed debounced interactions synchronously
        // from the interruption callback. Keep the newest frame alive until then.
        frameBuffer.flush()
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
        let segment = GuideTimelineSegment(
            asset: "media/segments/\(UUID().uuidString.lowercased()).mp4",
            startedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt),
            sourceCoordinateRect: capturedDisplayFrame
        )
        finishedSegments.append((segment, url))
    }

    private func resolveFinalization(for token: ScreenRecordingSegmentToken, error: Error? = nil) {
        segmentFinalizationTimeouts.removeValue(forKey: token)?.cancel()
        guard let continuation = segmentContinuations.removeValue(forKey: token) else { return }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    nonisolated static func captureDisplay(
        for source: GuideCaptureSource,
        in displays: [DisplaySnapshot],
        fallbackDisplayID: CGDirectDisplayID
    ) -> DisplaySnapshot? {
        switch source {
        case .window(_, _, _, let frame), .app(_, _, _, let frame):
            let point = CGPoint(x: frame.midX, y: frame.midY)
            return displays.first(where: { $0.frame.contains(point) })
                ?? displays.first(where: { $0.displayID == fallbackDisplayID })
        case .region(let rect):
            let point = CGPoint(x: rect.midX, y: rect.midY)
            return displays.first(where: { $0.frame.contains(point) })
                ?? displays.first(where: { $0.displayID == fallbackDisplayID })
        case .displays(.selected(let identifiers)):
            if let selected = identifiers.first,
               let display = displays.first(where: { $0.displayID == selected }) {
                return display
            }
            return displays.first(where: { $0.displayID == fallbackDisplayID })
        case .displays(.current), .displays(.all):
            return displays.first(where: { $0.displayID == fallbackDisplayID })
        }
    }
}

private extension GuideCaptureSource {
    nonisolated var windowID: CGWindowID? {
        if case .window(let id, _, _, _) = self { return id }
        return nil
    }

    nonisolated var initialFrame: CGRect? {
        switch self {
        case .window(_, _, _, let frame), .app(_, _, _, let frame), .region(let frame): frame
        case .displays: nil
        }
    }
}
