import AVFoundation
import CoreMedia
import Foundation
import os

enum ScreenRecordingError: LocalizedError {
    case permissionDenied
    case microphonePermissionDenied
    case noDisplays
    case noWindowsAvailable
    case currentDisplayUnavailable
    case selectedDisplayUnavailable
    case invalidRegion
    case regionSpansMultipleDisplays
    case recordingAlreadyStopped
    case insufficientStorage
    case unsupportedRecordingFormat
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording access is required before video recording can begin."
        case .microphonePermissionDenied:
            return "Microphone access is required before recording narration."
        case .noDisplays:
            return "No active displays were found for recording."
        case .noWindowsAvailable:
            return "No shareable windows are currently available for recording."
        case .currentDisplayUnavailable:
            return "The current display could not be resolved for recording."
        case .selectedDisplayUnavailable:
            return "The selected display could not be resolved for recording."
        case .invalidRegion:
            return "The selected region was too small to record."
        case .regionSpansMultipleDisplays:
            return "Region video recording must stay within one display."
        case .recordingAlreadyStopped:
            return "The recording has already stopped."
        case .insufficientStorage:
            return "There is not enough free disk space to start a new recording."
        case .unsupportedRecordingFormat:
            return "This Mac does not support the requested recording format."
        case .recordingFailed(let message):
            return message
        }
    }
}

struct ScreenRecordingService {
    let permissions: any CapturePermissionServicing
    let platform: any ScreenRecordingPlatform
    let capturePlatform: any ScreenCapturePlatform
    let workspace: any WorkspaceServicing
    let screens: any ScreenTopologyProviding
    let files: any FileSystemServicing
    let mouse: any MouseLocationProviding
    let clock: any ClockProviding

    init(
        permissions: any CapturePermissionServicing,
        platform: any ScreenRecordingPlatform,
        capturePlatform: any ScreenCapturePlatform,
        workspace: any WorkspaceServicing,
        screens: any ScreenTopologyProviding,
        files: any FileSystemServicing,
        mouse: any MouseLocationProviding,
        clock: any ClockProviding
    ) {
        self.permissions = permissions
        self.platform = platform
        self.capturePlatform = capturePlatform
        self.workspace = workspace
        self.screens = screens
        self.files = files
        self.mouse = mouse
        self.clock = clock
    }

    func startFullscreenRecording(preferences: VideoRecordingPreferences) async throws -> ScreenRecordingSession {
        guard permissions.currentStatus().hasScreenRecording else {
            throw ScreenRecordingError.permissionDenied
        }

        try await requestMicrophoneAccessIfNeeded(preferences)

        let content = try await fetchShareableContent()

        let fullscreenTarget = try resolveFullscreenTarget(
            content: content,
            mode: preferences.fullscreenDisplayMode,
            selectedDisplayID: preferences.selectedFullscreenDisplayID
        )
        let sourceRect = fullscreenTarget.bounds.gscIntegralStandardized
        let configuration = streamConfiguration(
            for: fullscreenTarget.target,
            fallbackBounds: sourceRect,
            preferences: preferences
        )

        return try await startRecording(
            kind: .fullscreen,
            sourceName: fullscreenTarget.sourceName,
            bounds: sourceRect,
            target: fullscreenTarget.target,
            configuration: configuration,
            preferences: preferences
        )
    }

    func startRegionRecording(in region: CGRect, preferences: VideoRecordingPreferences) async throws -> ScreenRecordingSession {
        guard permissions.currentStatus().hasScreenRecording else {
            throw ScreenRecordingError.permissionDenied
        }

        let normalizedRegion = region.gscIntegralStandardized

        guard normalizedRegion.width > 2, normalizedRegion.height > 2 else {
            throw ScreenRecordingError.invalidRegion
        }

        try await requestMicrophoneAccessIfNeeded(preferences)

        let content = try await fetchShareableContent()
        let containingDisplays = content.displays.filter { $0.frame.contains(normalizedRegion) }

        guard containingDisplays.count == 1, let display = containingDisplays.first else {
            if content.displays.contains(where: { $0.frame.intersects(normalizedRegion) }) {
                throw ScreenRecordingError.regionSpansMultipleDisplays
            }

            throw ScreenRecordingError.currentDisplayUnavailable
        }

        let sourceRect = regionRecordingSourceRect(for: normalizedRegion, in: display)
        let target = ScreenRecordingTarget(
            source: .display(
                display.displayID,
                excludingProcessID: ProcessInfo.processInfo.processIdentifier,
                includeMenuBar: true
            ),
            contentBounds: display.frame.gscIntegralStandardized,
            pointPixelScale: display.scale,
            sourceRect: sourceRect
        )

        let configuration = streamConfiguration(
            for: target,
            fallbackBounds: normalizedRegion,
            preferences: preferences
        )

        return try await startRecording(
            kind: .region,
            sourceName: "Region",
            bounds: normalizedRegion,
            target: target,
            configuration: configuration,
            preferences: preferences
        )
    }

    nonisolated func regionRecordingSourceRect(for region: CGRect, in display: DisplaySnapshot) -> CGRect {
        display.captureDisplayTransform.captureLocalRect(fromCaptureGlobalRect: region.gscIntegralStandardized)
    }

    func startWindowRecording(_ window: CaptureWindowSummary, preferences: VideoRecordingPreferences) async throws -> ScreenRecordingSession {
        guard permissions.currentStatus().hasScreenRecording else {
            throw ScreenRecordingError.permissionDenied
        }

        try await requestMicrophoneAccessIfNeeded(preferences)

        let content = try await fetchShareableContent()

        guard let sourceWindow = content.windows.first(where: { $0.id == window.id }) else {
            throw ScreenRecordingError.noWindowsAvailable
        }

        let target = ScreenRecordingTarget(
            source: .window(sourceWindow.id),
            contentBounds: sourceWindow.frame.gscIntegralStandardized,
            pointPixelScale: displayScale(forCaptureFrame: sourceWindow.frame, displays: content.displays),
            sourceRect: nil
        )
        let configuration = streamConfiguration(
            for: target,
            fallbackBounds: sourceWindow.frame,
            preferences: preferences
        )

        return try await startRecording(
            kind: .window,
            sourceName: window.displayTitle,
            bounds: sourceWindow.frame.gscIntegralStandardized,
            target: target,
            configuration: configuration,
            preferences: preferences
        )
    }

    func resolveWindowTarget(_ window: CaptureWindowSummary) async throws -> CaptureWindowSummary {
        let captureService = ScreenCaptureService(
            permissions: permissions,
            platform: capturePlatform,
            workspace: workspace,
            screens: screens,
            mouse: mouse,
            windowFocus: NullApplicationWindowFocusService(),
            clock: clock
        )
        return try await captureService.resolveWindowTarget(window)
    }

    private func startRecording(
        kind: VideoRecordingKind,
        sourceName: String,
        bounds: CGRect,
        target: ScreenRecordingTarget,
        configuration: ScreenRecordingConfiguration,
        preferences: VideoRecordingPreferences
    ) async throws -> ScreenRecordingSession {
        let outputURL = TemporaryVideoMediaManager.recordingOutputURL(files: files)

        try VideoStorageGuardrails.ensureCanStartRecording(
            width: configuration.width,
            height: configuration.height,
            preferences: preferences
        )

        let platformSession = try await platform.makeSession(target: target, configuration: configuration)
        let session = ScreenRecordingSession(
            platformSession: platformSession,
            configuration: configuration,
            outputURL: outputURL,
            kind: kind,
            sourceName: sourceName,
            bounds: bounds,
            preferences: preferences,
            platform: platform,
            files: files,
            clock: clock
        )
        try session.startRecordingSegment()
        try await platformSession.startCapture()
        session.markCaptureStarted()
        return session
    }

    private func streamConfiguration(
        for target: ScreenRecordingTarget,
        fallbackBounds: CGRect,
        preferences: VideoRecordingPreferences
    ) -> ScreenRecordingConfiguration {
        let pointPixelScale = max(target.pointPixelScale, 1)
        let outputScale = preferences.quality.outputScale(for: pointPixelScale)
        let contentBounds = target.sourceRect ?? target.contentBounds.gscIntegralStandardized
        let resolvedBounds = contentBounds.width > 0 && contentBounds.height > 0
            ? contentBounds
            : fallbackBounds.gscIntegralStandardized

        return ScreenRecordingConfiguration(
            width: max(Int((resolvedBounds.width * outputScale).rounded(.up)), 1),
            height: max(Int((resolvedBounds.height * outputScale).rounded(.up)), 1),
            minimumFrameInterval: preferences.frameRate.frameInterval,
            captureResolution: preferences.quality.captureResolution,
            showsCursor: preferences.showsCursor,
            showsMouseClicks: preferences.showsMouseClicks,
            capturesAudio: preferences.recordsSystemAudio,
            capturesMicrophone: preferences.recordsMicrophone
        )
    }

    private func fetchShareableContent() async throws -> ScreenContentSnapshot {
        let content = try await platform.shareableContent()
        let displays = content.displays.map { display in
            let screen = screens.screen(withDisplayID: display.displayID)
            return DisplaySnapshot(
                displayID: display.displayID,
                name: screen?.name ?? display.name,
                frame: display.frame,
                overlayFrame: screen?.frame ?? display.overlayFrame,
                scale: screen?.backingScaleFactor ?? display.scale
            )
        }
        return ScreenContentSnapshot(displays: displays, windows: content.windows, applications: content.applications)
    }

    private func requestMicrophoneAccessIfNeeded(_ preferences: VideoRecordingPreferences) async throws {
        guard preferences.recordsMicrophone else {
            return
        }

        try await platform.requestMicrophoneAccess()
    }

    private func currentDisplay(in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        let mouseLocation = mouse.appKitGlobalLocation
        let screen = screens.screen(containing: mouseLocation) ?? screens.mainScreen
        let displayID = screen?.displayID

        return displays.first { display in
            display.displayID == displayID
        }
    }

    private func resolveFullscreenTarget(
        content: ScreenContentSnapshot,
        mode: VideoRecordingFullscreenDisplayMode,
        selectedDisplayID: UInt32?
    ) throws -> FullscreenRecordingTarget {
        guard !content.displays.isEmpty else {
            throw ScreenRecordingError.noDisplays
        }

        switch mode {
        case .currentDisplay:
            guard let display = currentDisplay(in: content.displays) ?? content.displays.first else {
                throw ScreenRecordingError.currentDisplayUnavailable
            }
            return FullscreenRecordingTarget(
                target: displayRecordingTarget(for: display, sourceRect: nil),
                bounds: display.frame.gscIntegralStandardized,
                sourceName: display.name
            )
        case .selectedDisplay:
            let display = content.displays.first(where: { $0.displayID == selectedDisplayID })
                ?? content.displays.first

            guard let display else {
                throw ScreenRecordingError.selectedDisplayUnavailable
            }

            return FullscreenRecordingTarget(
                target: displayRecordingTarget(for: display, sourceRect: nil),
                bounds: display.frame.gscIntegralStandardized,
                sourceName: display.name
            )
        case .allDisplays:
            guard let anchorDisplay = currentDisplay(in: content.displays) ?? content.displays.first else {
                throw ScreenRecordingError.currentDisplayUnavailable
            }

            let unionBounds = content.displays
                .map(\.frame)
                .reduce(CGRect.null) { partial, frame in
                    partial.union(frame)
                }
                .gscIntegralStandardized

            return FullscreenRecordingTarget(
                target: displayRecordingTarget(for: anchorDisplay, sourceRect: unionBounds),
                bounds: unionBounds,
                sourceName: content.displays.count == 1 ? anchorDisplay.name : "All Displays"
            )
        }
    }

    private func displayRecordingTarget(for display: DisplaySnapshot, sourceRect: CGRect?) -> ScreenRecordingTarget {
        ScreenRecordingTarget(
            source: .display(
                display.displayID,
                excludingProcessID: ProcessInfo.processInfo.processIdentifier,
                includeMenuBar: true
            ),
            contentBounds: display.frame.gscIntegralStandardized,
            pointPixelScale: display.scale,
            sourceRect: sourceRect?.gscIntegralStandardized
        )
    }

    private func displayScale(forCaptureFrame frame: CGRect, displays: [DisplaySnapshot]) -> CGFloat {
        let scales = displays.compactMap { display -> CGFloat? in
            display.frame.intersects(frame) ? display.scale : nil
        }

        return max(scales.max() ?? 2, 1)
    }
}

private struct FullscreenRecordingTarget {
    let target: ScreenRecordingTarget
    let bounds: CGRect
    let sourceName: String
}

@MainActor
final class RecordingOutputCompletionTracker {
    private var outputURLByToken: [ScreenRecordingSegmentToken: URL] = [:]
    private var continuationsByToken: [ScreenRecordingSegmentToken: [CheckedContinuation<Void, Error>]] = [:]
    private var resultsByToken: [ScreenRecordingSegmentToken: Result<Void, Error>] = [:]

    func track(token: ScreenRecordingSegmentToken, outputURL: URL) {
        outputURLByToken[token] = outputURL
    }

    func wait(for token: ScreenRecordingSegmentToken) async throws {
        if let result = resultsByToken[token] {
            try result.get()
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let result = resultsByToken[token] {
                continuation.resume(with: result)
                return
            }

            continuationsByToken[token, default: []].append(continuation)
        }
    }

    func finish(token: ScreenRecordingSegmentToken, result: Result<Void, Error>) -> URL? {
        guard resultsByToken[token] == nil else {
            return nil
        }

        resultsByToken[token] = result
        let continuations = continuationsByToken.removeValue(forKey: token) ?? []
        continuations.forEach { $0.resume(with: result) }

        guard case .success = result else {
            return nil
        }

        return outputURLByToken[token]
    }

    func finishAll(with result: Result<Void, Error>) {
        let pendingTokens = Set(outputURLByToken.keys).union(continuationsByToken.keys)

        for token in pendingTokens {
            _ = finish(token: token, result: result)
        }
    }

    var trackedOutputURLs: [URL] {
        Array(outputURLByToken.values)
    }
}

@MainActor
final class ScreenRecordingSession: ScreenRecordingPlatformEventSink {
    private static let logger = Logger(subsystem: "com.oontz.SnipSnipSnip", category: "ScreenRecording")

    let outputURL: URL
    private(set) var isPaused = false

    private let kind: VideoRecordingKind
    private let sourceName: String
    private let bounds: CGRect
    private var preferences: VideoRecordingPreferences
    private var configuration: ScreenRecordingConfiguration
    private let platformSession: any ScreenRecordingPlatformSession
    private let platform: any ScreenRecordingPlatform
    private let files: any FileSystemServicing
    private let clock: any ClockProviding
    private let recordingWidth: Int
    private let recordingHeight: Int
    private let startedAt: Date
    private var activeSegmentToken: ScreenRecordingSegmentToken?
    private var segmentOutputURLs: [URL] = []
    private let completionTracker = RecordingOutputCompletionTracker()
    private var didStop = false
    private var isCaptureRunning = false
    private var audioLevels = ScreenRecordingAudioLevels()
    var audioLevelHandler: ((ScreenRecordingAudioLevels) -> Void)?

    init(
        platformSession: any ScreenRecordingPlatformSession,
        configuration: ScreenRecordingConfiguration,
        outputURL: URL,
        kind: VideoRecordingKind,
        sourceName: String,
        bounds: CGRect,
        preferences: VideoRecordingPreferences,
        platform: any ScreenRecordingPlatform,
        files: any FileSystemServicing,
        clock: any ClockProviding
    ) {
        self.outputURL = outputURL
        self.kind = kind
        self.sourceName = sourceName
        self.bounds = bounds
        self.preferences = preferences
        self.configuration = configuration
        self.platformSession = platformSession
        self.platform = platform
        self.files = files
        self.clock = clock
        self.recordingWidth = configuration.width
        self.recordingHeight = configuration.height
        self.startedAt = clock.now()
        platformSession.setEventSink(self)
    }

    func startRecordingSegment() throws {
        let segmentOutputURL = TemporaryVideoMediaManager.recordingOutputURL(files: files)
        let token = try platformSession.startRecordingSegment(to: segmentOutputURL)
        activeSegmentToken = token
        completionTracker.track(token: token, outputURL: segmentOutputURL)
        isPaused = false
    }

    func pause() async throws {
        guard !didStop else {
            throw ScreenRecordingError.recordingAlreadyStopped
        }

        guard !isPaused, let activeSegmentToken else {
            return
        }

        if isCaptureRunning {
            try await platformSession.stopCapture()
            isCaptureRunning = false
        }

        try await waitForRecordingOutputToFinish(activeSegmentToken)
        try? platformSession.removeRecordingSegment(activeSegmentToken)
        self.activeSegmentToken = nil
        isPaused = true
        resetAudioLevels()
    }

    func resume() async throws {
        guard !didStop else {
            throw ScreenRecordingError.recordingAlreadyStopped
        }

        guard isPaused else {
            return
        }

        try startRecordingSegment()
        try await platformSession.startCapture()
        isCaptureRunning = true
    }

    func updateAudioOptions(recordsSystemAudio: Bool, recordsMicrophone: Bool) async throws {
        guard !didStop else {
            throw ScreenRecordingError.recordingAlreadyStopped
        }

        if recordsMicrophone {
            try await platform.requestMicrophoneAccess()
        }

        guard recordsSystemAudio != preferences.recordsSystemAudio
                || recordsMicrophone != preferences.recordsMicrophone else {
            return
        }

        let wasCapturing = isCaptureRunning
        if wasCapturing, let activeSegmentToken {
            try await platformSession.stopCapture()
            isCaptureRunning = false
            try await waitForRecordingOutputToFinish(activeSegmentToken)
            try? platformSession.removeRecordingSegment(activeSegmentToken)
            self.activeSegmentToken = nil
        }

        configuration.capturesAudio = recordsSystemAudio
        configuration.capturesMicrophone = recordsMicrophone
        try await platformSession.updateConfiguration(configuration)
        preferences.recordsSystemAudio = recordsSystemAudio
        preferences.recordsMicrophone = recordsMicrophone
        if !recordsSystemAudio {
            audioLevels.system = 0
        }
        if !recordsMicrophone {
            audioLevels.microphone = 0
        }
        audioLevelHandler?(audioLevels)

        if wasCapturing {
            try startRecordingSegment()
            try await platformSession.startCapture()
            isCaptureRunning = true
        }
    }

    func stop() async throws -> CapturedVideoRecording {
        guard !didStop else {
            throw ScreenRecordingError.recordingAlreadyStopped
        }

        didStop = true
        let activeSegmentToken = activeSegmentToken

        // Keep the recording output attached until the stream is fully stopping so
        // the capture backend does not keep delivering frames to a removed output.
        if isCaptureRunning {
            try await platformSession.stopCapture()
            isCaptureRunning = false
        }

        if let activeSegmentToken {
            try await waitForRecordingOutputToFinish(activeSegmentToken)
        }

        self.activeSegmentToken = nil
        isPaused = false
        resetAudioLevels()
        let finalizedOutputURL = try await finalizeOutputURL()
        let duration = await recordingDuration(from: finalizedOutputURL)

        return CapturedVideoRecording(
            sourceURL: finalizedOutputURL,
            kind: kind,
            sourceName: sourceName,
            bounds: bounds,
            recordedAt: startedAt,
            duration: duration,
            preferences: preferences
        )
    }

    private func waitForRecordingOutputToFinish(_ token: ScreenRecordingSegmentToken) async throws {
        try await completionTracker.wait(for: token)
    }

    private func finalizeOutputURL() async throws -> URL {
        guard !segmentOutputURLs.isEmpty else {
            Self.logger.error("Finalize recording failed: no segment URLs were captured")
            throw ScreenRecordingError.recordingFailed("The recording finished without any captured segments.")
        }

        Self.logger.notice("Finalize recording with \(self.segmentOutputURLs.count, privacy: .public) segment(s)")

        if segmentOutputURLs.count == 1, let singleSegmentURL = segmentOutputURLs.first {
            try? files.removeItem(at: outputURL)
            if singleSegmentURL.standardizedFileURL != outputURL.standardizedFileURL {
                try files.moveItem(at: singleSegmentURL, to: outputURL)
            }
            return outputURL
        }

        try? files.removeItem(at: outputURL)
        do {
            try await mergeSegments(at: segmentOutputURLs, to: outputURL)
        } catch {
            let nsError = error as NSError
            Self.logger.error(
                "Segment merge failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)"
            )
            throw error
        }

        // Best-effort cleanup of intermediate segments after merge.
        for segmentURL in segmentOutputURLs {
            try? files.removeItem(at: segmentURL)
        }

        return outputURL
    }

    private func recordingDuration(from url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)

        if let duration = try? await asset.load(.duration) {
            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0 {
                return seconds
            }
        }

        return max(clock.now().timeIntervalSince(startedAt), 0)
    }

    private func mergeSegments(at segmentURLs: [URL], to outputURL: URL) async throws {
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ScreenRecordingError.recordingFailed("The recording could not be merged.")
        }

        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        var insertionTime = CMTime.zero
        var preferredTransform: CGAffineTransform?
        var insertedSegmentCount = 0

        for segmentURL in segmentURLs {
            let asset = AVURLAsset(url: segmentURL)
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            Self.logger.notice(
                "Merge segment \(segmentURL.lastPathComponent, privacy: .public) duration=\(duration.seconds, privacy: .public)s videoTracks=\(videoTracks.count, privacy: .public) audioTracks=\(audioTracks.count, privacy: .public)"
            )

            guard duration.seconds > 0 else {
                continue
            }

            let timeRange = CMTimeRange(start: .zero, duration: duration)
            guard let videoTrack = videoTracks.first else {
                continue
            }

            try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: insertionTime)
            if preferredTransform == nil {
                preferredTransform = try? await videoTrack.load(.preferredTransform)
            }

            if let audioTrack = audioTracks.first,
               let compositionAudioTrack {
                try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: insertionTime)
            }

            insertionTime = insertionTime + duration
            insertedSegmentCount += 1
        }

        guard insertedSegmentCount > 0 else {
            Self.logger.error("Merge aborted: no segments with non-zero duration and usable video track")
            throw ScreenRecordingError.recordingFailed("The recording segments could not be merged.")
        }

        if let preferredTransform {
            compositionVideoTrack.preferredTransform = preferredTransform
        }

        Self.logger.notice(
            "Merging \(insertedSegmentCount, privacy: .public) segment(s) totalDuration=\(composition.duration.seconds, privacy: .public)s"
        )

        let presetCandidates = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        var lastError: Error?

        for preset in presetCandidates {
            guard let exportSession = AVAssetExportSession(asset: composition, presetName: preset) else {
                Self.logger.notice("Merge export preset unavailable: \(preset, privacy: .public)")
                continue
            }

            guard exportSession.supportedFileTypes.contains(.mp4) else {
                Self.logger.notice("Merge export preset \(preset, privacy: .public) does not support MP4")
                continue
            }

            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = true

            do {
                Self.logger.notice("Merge export start preset=\(preset, privacy: .public)")
                try await exportSession.export(to: outputURL, as: .mp4)
                Self.logger.notice("Merge export success preset=\(preset, privacy: .public)")
                return
            } catch {
                let nsError = error as NSError
                Self.logger.error(
                    "Merge export failed preset=\(preset, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)"
                )
                lastError = error
                try? files.removeItem(at: outputURL)
            }
        }

        if let lastError {
            throw ScreenRecordingError.recordingFailed((lastError as NSError).localizedDescription)
        }

        throw ScreenRecordingError.recordingFailed("The merged recording could not be exported.")
    }

    func recordingPlatformSession(
        _ session: any ScreenRecordingPlatformSession,
        didFinishSegment token: ScreenRecordingSegmentToken
    ) {
        resumeFinishContinuation(for: token, with: .success(()))
    }

    func recordingPlatformSession(
        _ session: any ScreenRecordingPlatformSession,
        segment token: ScreenRecordingSegmentToken,
        didFailWith error: Error
    ) {
        resumeFinishContinuation(for: token, with: .failure(error))
    }

    func recordingPlatformSession(_ session: any ScreenRecordingPlatformSession, didStopWith error: Error) {
        if !didStop {
            resumeAllFinishContinuations(with: .failure(error))
        }
    }

    func recordingPlatformSession(
        _ session: any ScreenRecordingPlatformSession,
        didUpdateAudioLevel level: Double,
        source: ScreenRecordingAudioSource
    ) {
        guard isCaptureRunning, !isPaused, !didStop else {
            return
        }

        switch source {
        case .system where preferences.recordsSystemAudio:
            audioLevels.system = level
        case .microphone where preferences.recordsMicrophone:
            audioLevels.microphone = level
        default:
            return
        }

        audioLevelHandler?(audioLevels)
    }

    private func resumeFinishContinuation(for token: ScreenRecordingSegmentToken, with result: Result<Void, Error>) {
        if let outputURL = completionTracker.finish(token: token, result: result) {
            segmentOutputURLs.append(outputURL)
        }
    }

    private func resumeAllFinishContinuations(with result: Result<Void, Error>) {
        completionTracker.finishAll(with: result)
    }

    func markCaptureStarted() {
        isCaptureRunning = true
    }

    private func resetAudioLevels() {
        audioLevels = ScreenRecordingAudioLevels()
        audioLevelHandler?(audioLevels)
    }

    func checkStoragePressure() throws {
        try VideoStorageGuardrails.ensureCanContinueRecording(
            width: recordingWidth,
            height: recordingHeight,
            preferences: preferences,
            excluding: protectedTemporaryMediaURLs()
        )
    }

    private func protectedTemporaryMediaURLs() -> [URL] {
        ([outputURL] + segmentOutputURLs + completionTracker.trackedOutputURLs).map(\.standardizedFileURL)
    }

}
