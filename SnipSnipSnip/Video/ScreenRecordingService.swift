import AppKit
import AVFoundation
import AVFAudio
import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

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
    func startFullscreenRecording(preferences: VideoRecordingPreferences) async throws -> ScreenRecordingSession {
        guard CapturePermissionStatus.current().hasScreenRecording else {
            throw ScreenRecordingError.permissionDenied
        }

        try await requestMicrophoneAccessIfNeeded(preferences)

        let content = try await fetchShareableContent()

        let fullscreenTarget = try resolveFullscreenTarget(
            content: content,
            mode: preferences.fullscreenDisplayMode,
            selectedDisplayID: preferences.selectedFullscreenDisplayID
        )
        let filter = fullscreenTarget.filter
        let sourceRect = fullscreenTarget.bounds.gscIntegralStandardized
        let configuration = streamConfiguration(
            for: filter,
            sourceRect: fullscreenTarget.sourceRect,
            fallbackBounds: sourceRect,
            preferences: preferences
        )

        return try await startRecording(
            kind: .fullscreen,
            sourceName: fullscreenTarget.sourceName,
            bounds: sourceRect,
            filter: filter,
            configuration: configuration,
            preferences: preferences
        )
    }

    func startRegionRecording(in region: CGRect, preferences: VideoRecordingPreferences) async throws -> ScreenRecordingSession {
        guard CapturePermissionStatus.current().hasScreenRecording else {
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

        let filter = displayRecordingFilter(for: display, content: content)
        filter.includeMenuBar = true
        let displaySnapshot = DisplaySnapshot(
            displayID: display.displayID,
            name: displayName(for: display.displayID),
            frame: display.frame,
            scale: 1
        )
        let sourceRect = regionRecordingSourceRect(for: normalizedRegion, in: displaySnapshot)

        let configuration = streamConfiguration(
            for: filter,
            sourceRect: sourceRect,
            fallbackBounds: normalizedRegion,
            preferences: preferences
        )

        return try await startRecording(
            kind: .region,
            sourceName: "Region",
            bounds: normalizedRegion,
            filter: filter,
            configuration: configuration,
            preferences: preferences
        )
    }

    nonisolated func regionRecordingSourceRect(for region: CGRect, in display: DisplaySnapshot) -> CGRect {
        display.captureDisplayTransform.captureLocalRect(fromCaptureGlobalRect: region.gscIntegralStandardized)
    }

    func startWindowRecording(_ window: CaptureWindowSummary, preferences: VideoRecordingPreferences) async throws -> ScreenRecordingSession {
        guard CapturePermissionStatus.current().hasScreenRecording else {
            throw ScreenRecordingError.permissionDenied
        }

        try await requestMicrophoneAccessIfNeeded(preferences)

        let content = try await fetchShareableContent()

        guard let sourceWindow = content.windows.first(where: { $0.windowID == window.id }) else {
            throw ScreenRecordingError.noWindowsAvailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: sourceWindow)
        let configuration = streamConfiguration(
            for: filter,
            sourceRect: nil,
            fallbackBounds: sourceWindow.frame,
            preferences: preferences
        )
        configuration.ignoreShadowsSingleWindow = false

        return try await startRecording(
            kind: .window,
            sourceName: window.displayTitle,
            bounds: sourceWindow.frame.gscIntegralStandardized,
            filter: filter,
            configuration: configuration,
            preferences: preferences
        )
    }

    func resolveWindowTarget(_ window: CaptureWindowSummary) async throws -> CaptureWindowSummary {
        let captureService = ScreenCaptureService()
        return try await captureService.resolveWindowTarget(window)
    }

    private func startRecording(
        kind: VideoRecordingKind,
        sourceName: String,
        bounds: CGRect,
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        preferences: VideoRecordingPreferences
    ) async throws -> ScreenRecordingSession {
        let outputURL = TemporaryVideoMediaManager.recordingOutputURL()

        try VideoStorageGuardrails.ensureCanStartRecording(
            width: configuration.width,
            height: configuration.height,
            preferences: preferences
        )

        let session = ScreenRecordingSession(
            filter: filter,
            configuration: configuration,
            outputURL: outputURL,
            kind: kind,
            sourceName: sourceName,
            bounds: bounds,
            preferences: preferences
        )
        try session.startRecordingSegment()
        try await session.stream.startCapture()
        session.markCaptureStarted()
        return session
    }

    private func streamConfiguration(
        for filter: SCContentFilter,
        sourceRect: CGRect?,
        fallbackBounds: CGRect,
        preferences: VideoRecordingPreferences
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let pointPixelScale = max(CGFloat(filter.pointPixelScale), 1)
        let outputScale = preferences.quality.outputScale(for: pointPixelScale)
        let contentBounds = sourceRect ?? filter.contentRect.gscIntegralStandardized
        let resolvedBounds = contentBounds.width > 0 && contentBounds.height > 0
            ? contentBounds
            : fallbackBounds.gscIntegralStandardized

        if let sourceRect {
            configuration.sourceRect = sourceRect.gscIntegralStandardized
        }

        configuration.width = max(Int((resolvedBounds.width * outputScale).rounded(.up)), 1)
        configuration.height = max(Int((resolvedBounds.height * outputScale).rounded(.up)), 1)
        configuration.minimumFrameInterval = preferences.frameRate.frameInterval
        configuration.queueDepth = 5
        configuration.captureResolution = preferences.quality.captureResolution
        configuration.showsCursor = preferences.showsCursor
        configuration.showMouseClicks = preferences.showsMouseClicks
        configuration.capturesAudio = preferences.recordsSystemAudio
        configuration.captureMicrophone = preferences.recordsMicrophone
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureDynamicRange = .SDR
        return configuration
    }

    private func fetchShareableContent() async throws -> SCShareableContent {
        let result: ShareableContentResult = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let content else {
                    continuation.resume(throwing: ScreenRecordingError.noDisplays)
                    return
                }

                continuation.resume(returning: ShareableContentResult(content: content))
            }
        }
        return result.content
    }

    private func requestMicrophoneAccessIfNeeded(_ preferences: VideoRecordingPreferences) async throws {
        guard preferences.recordsMicrophone else {
            return
        }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw ScreenRecordingError.microphonePermissionDenied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }

            if !granted {
                throw ScreenRecordingError.microphonePermissionDenied
            }
        @unknown default:
            throw ScreenRecordingError.microphonePermissionDenied
        }
    }

    private func currentDisplay(in displays: [SCDisplay]) -> SCDisplay? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        let displayID = screen?.gscDisplayID

        return displays.first { display in
            display.displayID == displayID
        }
    }

    private func currentApplication(in content: SCShareableContent) -> SCRunningApplication? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return content.applications.first { $0.processID == currentPID }
    }

    private func displayRecordingFilter(for display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let excludedApplications = content.applications.filter { $0.processID == currentPID }

        if excludedApplications.isEmpty {
            let excludedWindows = content.windows.filter { $0.owningApplication?.processID == currentPID }
            return SCContentFilter(display: display, excludingWindows: excludedWindows)
        }

        return SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
    }

    private func resolveFullscreenTarget(
        content: SCShareableContent,
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
            let filter = displayRecordingFilter(for: display, content: content)
            filter.includeMenuBar = true
            return FullscreenRecordingTarget(
                filter: filter,
                bounds: display.frame.gscIntegralStandardized,
                sourceRect: nil,
                sourceName: displayName(for: display.displayID)
            )
        case .selectedDisplay:
            let display = content.displays.first(where: { $0.displayID == selectedDisplayID })
                ?? content.displays.first

            guard let display else {
                throw ScreenRecordingError.selectedDisplayUnavailable
            }

            let filter = displayRecordingFilter(for: display, content: content)
            filter.includeMenuBar = true
            return FullscreenRecordingTarget(
                filter: filter,
                bounds: display.frame.gscIntegralStandardized,
                sourceRect: nil,
                sourceName: displayName(for: display.displayID)
            )
        case .allDisplays:
            guard let anchorDisplay = currentDisplay(in: content.displays) ?? content.displays.first else {
                throw ScreenRecordingError.currentDisplayUnavailable
            }

            let filter = displayRecordingFilter(for: anchorDisplay, content: content)
            filter.includeMenuBar = true

            let unionBounds = content.displays
                .map(\.frame)
                .reduce(CGRect.null) { partial, frame in
                    partial.union(frame)
                }
                .gscIntegralStandardized

            return FullscreenRecordingTarget(
                filter: filter,
                bounds: unionBounds,
                sourceRect: unionBounds,
                sourceName: content.displays.count == 1 ? displayName(for: anchorDisplay.displayID) : "All Displays"
            )
        }
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        NSScreen.screens.first(where: { $0.gscDisplayID == displayID })?.gscDisplayName ?? "Display"
    }
}

private struct FullscreenRecordingTarget {
    let filter: SCContentFilter
    let bounds: CGRect
    let sourceRect: CGRect?
    let sourceName: String
}

nonisolated private struct ShareableContentResult: @unchecked Sendable {
    let content: SCShareableContent
}

@MainActor
final class RecordingOutputCompletionTracker {
    private var outputURLByOutputID: [ObjectIdentifier: URL] = [:]
    private var continuationsByOutputID: [ObjectIdentifier: [CheckedContinuation<Void, Error>]] = [:]
    private var resultsByOutputID: [ObjectIdentifier: Result<Void, Error>] = [:]

    func track(outputID: ObjectIdentifier, outputURL: URL) {
        outputURLByOutputID[outputID] = outputURL
    }

    func wait(for outputID: ObjectIdentifier) async throws {
        if let result = resultsByOutputID[outputID] {
            try result.get()
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let result = resultsByOutputID[outputID] {
                continuation.resume(with: result)
                return
            }

            continuationsByOutputID[outputID, default: []].append(continuation)
        }
    }

    func finish(outputID: ObjectIdentifier, result: Result<Void, Error>) -> URL? {
        guard resultsByOutputID[outputID] == nil else {
            return nil
        }

        resultsByOutputID[outputID] = result
        let continuations = continuationsByOutputID.removeValue(forKey: outputID) ?? []
        continuations.forEach { $0.resume(with: result) }

        guard case .success = result else {
            return nil
        }

        return outputURLByOutputID[outputID]
    }

    func finishAll(with result: Result<Void, Error>) {
        let pendingOutputIDs = Set(outputURLByOutputID.keys).union(continuationsByOutputID.keys)

        for outputID in pendingOutputIDs {
            _ = finish(outputID: outputID, result: result)
        }
    }

    var trackedOutputURLs: [URL] {
        Array(outputURLByOutputID.values)
    }
}

@MainActor
final class ScreenRecordingSession: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput {
    private static let logger = Logger(subsystem: "com.oontz.SnipSnipSnip", category: "ScreenRecording")

    private(set) var stream: SCStream!
    let outputURL: URL
    private(set) var isPaused = false

    private let kind: VideoRecordingKind
    private let sourceName: String
    private let bounds: CGRect
    private let preferences: VideoRecordingPreferences
    private let recordingWidth: Int
    private let recordingHeight: Int
    private let startedAt: Date
    private var activeRecordingOutput: SCRecordingOutput?
    private var segmentOutputURLs: [URL] = []
    private let completionTracker = RecordingOutputCompletionTracker()
    private var didStop = false
    private var isCaptureRunning = false
    private let sampleOutputQueue = DispatchQueue(label: "com.oontz.SnipSnipSnip.ScreenRecordingSampleOutput")
    private var didAttachSampleOutput = false

    init(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        outputURL: URL,
        kind: VideoRecordingKind,
        sourceName: String,
        bounds: CGRect,
        preferences: VideoRecordingPreferences
    ) {
        self.outputURL = outputURL
        self.kind = kind
        self.sourceName = sourceName
        self.bounds = bounds
        self.preferences = preferences
        self.recordingWidth = configuration.width
        self.recordingHeight = configuration.height
        self.startedAt = Date()
        super.init()
        self.stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    func startRecordingSegment() throws {
        try ensureSampleOutputAttached()

        let recordingConfiguration = SCRecordingOutputConfiguration()
        let segmentOutputURL = TemporaryVideoMediaManager.recordingOutputURL()
        recordingConfiguration.outputURL = segmentOutputURL
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264

        guard recordingConfiguration.availableOutputFileTypes.contains(.mp4),
              recordingConfiguration.availableVideoCodecTypes.contains(.h264) else {
            throw ScreenRecordingError.unsupportedRecordingFormat
        }

        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)
        activeRecordingOutput = recordingOutput
        completionTracker.track(outputID: ObjectIdentifier(recordingOutput), outputURL: segmentOutputURL)
        isPaused = false
    }

    private func ensureSampleOutputAttached() throws {
        guard !didAttachSampleOutput else {
            return
        }

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleOutputQueue)
        didAttachSampleOutput = true
    }

    func pause() async throws {
        guard !didStop else {
            throw ScreenRecordingError.recordingAlreadyStopped
        }

        guard !isPaused, let recordingOutput = activeRecordingOutput else {
            return
        }

        if isCaptureRunning {
            try await stream.stopCapture()
            isCaptureRunning = false
        }

        try await waitForRecordingOutputToFinish(recordingOutput)
        try? stream.removeRecordingOutput(recordingOutput)
        activeRecordingOutput = nil
        isPaused = true
    }

    func resume() async throws {
        guard !didStop else {
            throw ScreenRecordingError.recordingAlreadyStopped
        }

        guard isPaused else {
            return
        }

        try startRecordingSegment()
        try await stream.startCapture()
        isCaptureRunning = true
    }

    func stop() async throws -> CapturedVideoRecording {
        guard !didStop else {
            throw ScreenRecordingError.recordingAlreadyStopped
        }

        didStop = true
        let recordingOutput = activeRecordingOutput

        // Keep the recording output attached until the stream is fully stopping so
        // ScreenCaptureKit does not keep delivering frames to a removed output.
        if isCaptureRunning {
            try await stream.stopCapture()
            isCaptureRunning = false
        }

        if let recordingOutput {
            try await waitForRecordingOutputToFinish(recordingOutput)
        }

        activeRecordingOutput = nil
        isPaused = false
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

    private func waitForRecordingOutputToFinish(_ recordingOutput: SCRecordingOutput) async throws {
        let outputID = ObjectIdentifier(recordingOutput)
        try await completionTracker.wait(for: outputID)
    }

    private func finalizeOutputURL() async throws -> URL {
        guard !segmentOutputURLs.isEmpty else {
            Self.logger.error("Finalize recording failed: no segment URLs were captured")
            throw ScreenRecordingError.recordingFailed("The recording finished without any captured segments.")
        }

        Self.logger.notice("Finalize recording with \(self.segmentOutputURLs.count, privacy: .public) segment(s)")

        if segmentOutputURLs.count == 1, let singleSegmentURL = segmentOutputURLs.first {
            try? FileManager.default.removeItem(at: outputURL)
            if singleSegmentURL.standardizedFileURL != outputURL.standardizedFileURL {
                try FileManager.default.moveItem(at: singleSegmentURL, to: outputURL)
            }
            return outputURL
        }

        try? FileManager.default.removeItem(at: outputURL)
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
            try? FileManager.default.removeItem(at: segmentURL)
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

        return max(Date().timeIntervalSince(startedAt), 0)
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
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        if let lastError {
            throw ScreenRecordingError.recordingFailed((lastError as NSError).localizedDescription)
        }

        throw ScreenRecordingError.recordingFailed("The merged recording could not be exported.")
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            self?.resumeFinishContinuation(for: recordingOutput, with: .success(()))
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor [weak self] in
            self?.resumeFinishContinuation(for: recordingOutput, with: .failure(error))
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            if !self.didStop {
                self.resumeAllFinishContinuations(with: .failure(error))
            }
        }
    }

    private func resumeFinishContinuation(for recordingOutput: SCRecordingOutput, with result: Result<Void, Error>) {
        let outputID = ObjectIdentifier(recordingOutput)

        if let outputURL = completionTracker.finish(outputID: outputID, result: result) {
            segmentOutputURLs.append(outputURL)
        }
    }

    private func resumeAllFinishContinuations(with result: Result<Void, Error>) {
        completionTracker.finishAll(with: result)
    }

    func markCaptureStarted() {
        isCaptureRunning = true
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

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // RecordingOutput handles persisted media. Keep this sink attached so the
        // stream has an active output target and does not spam dropped-frame logs.
    }
}
