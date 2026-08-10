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
    case recordingStartTimedOut
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
        case .recordingStartTimedOut:
            return "The recording output did not start in time. Try recording again."
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
            preferences: preferences,
            presentationFrame: fullscreenTarget.presentationFrame
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
            sourceName: WorkflowVocabulary.Source.region,
            bounds: normalizedRegion,
            target: target,
            configuration: configuration,
            preferences: preferences,
            presentationFrame: presentationFrame(for: display)
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
            pointPixelScale: gscDisplayScale(
                forCaptureFrame: sourceWindow.frame,
                displays: content.displays,
                fallbackScale: 2
            ),
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
            preferences: preferences,
            presentationFrame: presentationFrame(forWindowFrame: sourceWindow.frame, displays: content.displays)
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
        preferences: VideoRecordingPreferences,
        presentationFrame: CGRect
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
            presentationFrame: presentationFrame,
            platform: platform,
            files: files,
            clock: clock
        )
        try await session.start()
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
        return content.resolvingDisplayMetadata(using: screens)
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

    private func presentationFrame(for display: DisplaySnapshot) -> CGRect {
        screens.screen(withDisplayID: display.displayID)?.visibleFrame ?? display.overlayFrame
    }

    private func presentationFrame(forWindowFrame frame: CGRect, displays: [DisplaySnapshot]) -> CGRect {
        let display = displays.max { left, right in
            let leftIntersection = left.frame.intersection(frame).gscFiniteOr(.zero)
            let rightIntersection = right.frame.intersection(frame).gscFiniteOr(.zero)
            let leftArea = max(leftIntersection.width, 0) * max(leftIntersection.height, 0)
            let rightArea = max(rightIntersection.width, 0) * max(rightIntersection.height, 0)
            if leftArea == rightArea { return left.displayID > right.displayID }
            return leftArea < rightArea
        } ?? currentDisplay(in: displays)
        return display.map(presentationFrame(for:))
            ?? screens.mainScreen?.visibleFrame
            ?? .zero
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
                sourceName: display.name,
                presentationFrame: presentationFrame(for: display)
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
                sourceName: display.name,
                presentationFrame: presentationFrame(for: display)
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
                sourceName: content.displays.count == 1 ? anchorDisplay.name : "All Displays",
                presentationFrame: presentationFrame(for: anchorDisplay)
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
}

private struct FullscreenRecordingTarget {
    let target: ScreenRecordingTarget
    let bounds: CGRect
    let sourceName: String
    let presentationFrame: CGRect
}

@MainActor
final class RecordingOutputCompletionTracker {
    private var outputURLByToken: [ScreenRecordingSegmentToken: URL] = [:]
    private var continuationsByToken: [ScreenRecordingSegmentToken: [CheckedContinuation<Void, Error>]] = [:]
    private var resultsByToken: [ScreenRecordingSegmentToken: Result<Void, Error>] = [:]
    private var timeoutTasksByToken: [ScreenRecordingSegmentToken: Task<Void, Never>] = [:]

    func track(token: ScreenRecordingSegmentToken, outputURL: URL) {
        outputURLByToken[token] = outputURL
    }

    func wait(
        for token: ScreenRecordingSegmentToken,
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) async throws {
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
            if timeoutTasksByToken[token] == nil {
                timeoutTasksByToken[token] = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    guard !Task.isCancelled else { return }
                    _ = self?.finish(
                        token: token,
                        result: .failure(ScreenRecordingError.recordingFailed(
                            "The recording output did not finish in time."
                        ))
                    )
                }
            }
        }
    }

    func finish(token: ScreenRecordingSegmentToken, result: Result<Void, Error>) -> URL? {
        guard resultsByToken[token] == nil else {
            return nil
        }

        resultsByToken[token] = result
        timeoutTasksByToken.removeValue(forKey: token)?.cancel()
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
final class RecordingOutputStartTracker {
    private var resultsByToken: [ScreenRecordingSegmentToken: Result<Void, Error>] = [:]
    private var continuationsByToken: [ScreenRecordingSegmentToken: CheckedContinuation<Void, Error>] = [:]
    private var timeoutTasksByToken: [ScreenRecordingSegmentToken: Task<Void, Never>] = [:]

    func wait(for token: ScreenRecordingSegmentToken, timeoutNanoseconds: UInt64) async throws {
        if let result = resultsByToken[token] {
            try result.get()
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            continuationsByToken[token] = continuation
            timeoutTasksByToken[token] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                self?.finish(token: token, result: .failure(ScreenRecordingError.recordingStartTimedOut))
            }
        }
    }

    func finish(token: ScreenRecordingSegmentToken, result: Result<Void, Error>) {
        guard resultsByToken[token] == nil else { return }
        resultsByToken[token] = result
        timeoutTasksByToken.removeValue(forKey: token)?.cancel()
        continuationsByToken.removeValue(forKey: token)?.resume(with: result)
    }
}

@MainActor
final class ScreenRecordingSession: ScreenRecordingPlatformEventSink {
    private static let logger = Logger(subsystem: "com.oontz.SnipSnipSnip", category: "ScreenRecording")

    let outputURL: URL
    let presentationFrame: CGRect
    private(set) var isPaused = false
    private(set) var recoveredFromSegmentFailure = false

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
    private var candidateSegmentOutputURLs: [URL] = []
    private let completionTracker = RecordingOutputCompletionTracker()
    private let startTracker = RecordingOutputStartTracker()
    private var didStop = false
    private var isStopping = false
    private var isCaptureRunning = false
    private var stopTask: Task<CapturedVideoRecording, Error>?
    private var finalizedRecording: CapturedVideoRecording?
    private var didReportTerminalFailure = false
    private var pendingTerminalFailure: Error?
    private var audioLevels = ScreenRecordingAudioLevels()
    var audioLevelHandler: ((ScreenRecordingAudioLevels) -> Void)?
    var terminalFailureHandler: ((Error) -> Void)? {
        didSet {
            guard let terminalFailureHandler,
                  let pendingTerminalFailure,
                  !didReportTerminalFailure else { return }
            self.pendingTerminalFailure = nil
            didReportTerminalFailure = true
            terminalFailureHandler(pendingTerminalFailure)
        }
    }

    init(
        platformSession: any ScreenRecordingPlatformSession,
        configuration: ScreenRecordingConfiguration,
        outputURL: URL,
        kind: VideoRecordingKind,
        sourceName: String,
        bounds: CGRect,
        preferences: VideoRecordingPreferences,
        presentationFrame: CGRect = .zero,
        platform: any ScreenRecordingPlatform,
        files: any FileSystemServicing,
        clock: any ClockProviding
    ) {
        self.outputURL = outputURL
        self.kind = kind
        self.sourceName = sourceName
        self.bounds = bounds
        self.preferences = preferences
        self.presentationFrame = presentationFrame
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
        candidateSegmentOutputURLs.append(segmentOutputURL)
        isPaused = false
    }

    func start() async throws {
        try startRecordingSegment()
        guard let activeSegmentToken else {
            throw ScreenRecordingError.recordingFailed("The recording output could not be prepared.")
        }

        do {
            try await platformSession.startCapture()
            isCaptureRunning = true
            try await startTracker.wait(for: activeSegmentToken, timeoutNanoseconds: 10_000_000_000)
        } catch {
            if isCaptureRunning { try? await platformSession.stopCapture() }
            isCaptureRunning = false
            try? platformSession.removeRecordingSegment(activeSegmentToken)
            self.activeSegmentToken = nil
            throw error
        }
    }

    func pause() async throws {
        guard !didStop else {
            throw ScreenRecordingError.recordingAlreadyStopped
        }

        guard !isPaused, let activeSegmentToken else {
            return
        }

        if isCaptureRunning {
            do {
                try await platformSession.stopCapture()
                isCaptureRunning = false
            } catch {
                reportTerminalFailureIfNeeded(error)
                throw error
            }
        }

        do {
            try await waitForRecordingOutputToFinish(activeSegmentToken)
        } catch {
            reportTerminalFailureIfNeeded(error)
            throw error
        }
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

        do {
            try startRecordingSegment()
            guard let activeSegmentToken else { return }
            try await platformSession.startCapture()
            isCaptureRunning = true
            try await startTracker.wait(for: activeSegmentToken, timeoutNanoseconds: 10_000_000_000)
        } catch {
            await abandonActiveSegmentAfterFailedRestart()
            isPaused = true
            resetAudioLevels()
            reportTerminalFailureIfNeeded(error)
            throw error
        }
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
            do {
                try await platformSession.stopCapture()
                isCaptureRunning = false
            } catch {
                reportTerminalFailureIfNeeded(error)
                throw error
            }
            do {
                try await waitForRecordingOutputToFinish(activeSegmentToken)
            } catch {
                reportTerminalFailureIfNeeded(error)
                throw error
            }
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
            do {
                try startRecordingSegment()
                guard let activeSegmentToken else { return }
                try await platformSession.startCapture()
                isCaptureRunning = true
                try await startTracker.wait(for: activeSegmentToken, timeoutNanoseconds: 10_000_000_000)
            } catch {
                await abandonActiveSegmentAfterFailedRestart()
                resetAudioLevels()
                reportTerminalFailureIfNeeded(error)
                throw error
            }
        }
    }

    private func abandonActiveSegmentAfterFailedRestart() async {
        if isCaptureRunning {
            try? await platformSession.stopCapture()
            isCaptureRunning = false
        }
        guard let activeSegmentToken else { return }
        try? await waitForRecordingOutputToFinish(activeSegmentToken)
        try? platformSession.removeRecordingSegment(activeSegmentToken)
        self.activeSegmentToken = nil
    }

    func stop() async throws -> CapturedVideoRecording {
        if let finalizedRecording { return finalizedRecording }
        if let stopTask { return try await stopTask.value }
        guard !didStop else { throw ScreenRecordingError.recordingAlreadyStopped }
        let task = Task<CapturedVideoRecording, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await performStop()
        }
        stopTask = task
        do {
            let recording = try await task.value
            finalizedRecording = recording
            stopTask = nil
            return recording
        } catch {
            stopTask = nil
            throw error
        }
    }

    private func performStop() async throws -> CapturedVideoRecording {
        isStopping = true
        defer { isStopping = false }
        let activeSegmentToken = activeSegmentToken

        // Keep the recording output attached until the stream is fully stopping so
        // the capture backend does not keep delivering frames to a removed output.
        if isCaptureRunning {
            try? await platformSession.stopCapture()
            isCaptureRunning = false
        }

        if let activeSegmentToken {
            try? await waitForRecordingOutputToFinish(activeSegmentToken)
            try? platformSession.removeRecordingSegment(activeSegmentToken)
        }

        self.activeSegmentToken = nil
        isPaused = false
        resetAudioLevels()
        let finalizedOutputURL = try await finalizeOutputURL()
        let duration = await recordingDuration(from: finalizedOutputURL)
        didStop = true

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
        try await completionTracker.wait(for: token, timeoutNanoseconds: 10_000_000_000)
    }

    private func finalizeOutputURL() async throws -> URL {
        let usableSegmentURLs = await validatedSegmentURLs(from: candidateSegmentOutputURLs)
        guard !usableSegmentURLs.isEmpty else {
            Self.logger.error("Finalize recording failed: no segment URLs were captured")
            throw ScreenRecordingError.recordingFailed("The recording finished without any captured segments.")
        }

        Self.logger.notice("Finalize recording with \(usableSegmentURLs.count, privacy: .public) usable segment(s)")

        if usableSegmentURLs.count == 1, let singleSegmentURL = usableSegmentURLs.first {
            try? files.removeItem(at: outputURL)
            if singleSegmentURL.standardizedFileURL != outputURL.standardizedFileURL {
                try files.copyItem(at: singleSegmentURL, to: outputURL)
            }
            guard await isUsableVideo(at: outputURL) else {
                try? files.removeItem(at: outputURL)
                throw ScreenRecordingError.recordingFailed("The captured recording could not be validated.")
            }
            cleanupCandidateSegments()
            return outputURL
        }

        try? files.removeItem(at: outputURL)
        do {
            try await mergeSegments(at: usableSegmentURLs, to: outputURL)
        } catch {
            let nsError = error as NSError
            Self.logger.error(
                "Segment merge failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)"
            )
            do {
                return try await salvageLongestSegment(from: usableSegmentURLs)
            } catch {
                throw ScreenRecordingError.recordingFailed(nsError.localizedDescription)
            }
        }

        guard await isUsableVideo(at: outputURL) else {
            try? files.removeItem(at: outputURL)
            return try await salvageLongestSegment(from: usableSegmentURLs)
        }
        cleanupCandidateSegments()
        return outputURL
    }

    private func validatedSegmentURLs(from urls: [URL]) async -> [URL] {
        var usable: [URL] = []
        for url in urls where await isUsableVideo(at: url) {
            usable.append(url)
        }
        return usable
    }

    private func isUsableVideo(at url: URL) async -> Bool {
        guard files.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.seconds.isFinite, duration.seconds > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .video),
              !tracks.isEmpty else { return false }
        return true
    }

    private func cleanupCandidateSegments() {
        for segmentURL in candidateSegmentOutputURLs
        where segmentURL.standardizedFileURL != outputURL.standardizedFileURL {
            try? files.removeItem(at: segmentURL)
        }
    }

    private func salvageLongestSegment(from segmentURLs: [URL]) async throws -> URL {
        var best: (url: URL, duration: Double)?
        for url in segmentURLs {
            let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            if duration > (best?.duration ?? 0) {
                best = (url, duration)
            }
        }
        guard let best else {
            throw ScreenRecordingError.recordingFailed("No usable recording segment could be recovered.")
        }

        try? files.removeItem(at: outputURL)
        if best.url.standardizedFileURL != outputURL.standardizedFileURL {
            try files.copyItem(at: best.url, to: outputURL)
        }
        guard await isUsableVideo(at: outputURL) else {
            try? files.removeItem(at: outputURL)
            throw ScreenRecordingError.recordingFailed("The recording segment could not be recovered.")
        }

        recoveredFromSegmentFailure = true
        Self.logger.notice(
            "Recovered recording from longest valid segment duration=\(best.duration, privacy: .public)s; preserving all candidate segments"
        )
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
        didStartSegment token: ScreenRecordingSegmentToken
    ) {
        startTracker.finish(token: token, result: .success(()))
    }

    func recordingPlatformSession(
        _ session: any ScreenRecordingPlatformSession,
        didFinishSegment token: ScreenRecordingSegmentToken
    ) {
        // ScreenCaptureKit normally delivers start before finish. Treat a finish as
        // implicit confirmation too so callback scheduling cannot cause a false
        // startup timeout after a segment has already completed.
        startTracker.finish(token: token, result: .success(()))
        resumeFinishContinuation(for: token, with: .success(()))
    }

    func recordingPlatformSession(
        _ session: any ScreenRecordingPlatformSession,
        segment token: ScreenRecordingSegmentToken,
        didFailWith error: Error
    ) {
        startTracker.finish(token: token, result: .failure(error))
        resumeFinishContinuation(for: token, with: .failure(error))
        reportTerminalFailureIfNeeded(error)
    }

    func recordingPlatformSession(_ session: any ScreenRecordingPlatformSession, didStopWith error: Error) {
        isCaptureRunning = false
        if !didStop {
            resumeAllFinishContinuations(with: .failure(error))
            if let activeSegmentToken {
                startTracker.finish(token: activeSegmentToken, result: .failure(error))
            }
            reportTerminalFailureIfNeeded(error)
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

    private func reportTerminalFailureIfNeeded(_ error: Error) {
        guard !isStopping, !didStop, !didReportTerminalFailure else { return }
        guard let terminalFailureHandler else {
            if pendingTerminalFailure == nil { pendingTerminalFailure = error }
            return
        }
        didReportTerminalFailure = true
        terminalFailureHandler(error)
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
