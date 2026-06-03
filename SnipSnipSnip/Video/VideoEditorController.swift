import AVFoundation
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

nonisolated struct VideoDragOutExport {
    let document: EditableVideoDocument
    let request: VideoExportRequest
    let suggestedFilename: String

    init(
        recording: CapturedVideoRecording,
        session: VideoEditorSession,
        request: VideoExportRequest
    ) {
        self.document = EditableVideoDocument(recording: recording, session: session)
        self.request = request
        self.suggestedFilename = "\(recording.defaultFilename).\(request.format.fileExtension)"
    }
}

@MainActor
final class VideoEditorController: ObservableObject {
    nonisolated private final class PlayerTimeObserverCleanup: @unchecked Sendable {
        private let lock = NSLock()
        private let player: AVPlayer
        private var token: Any?

        init(player: AVPlayer) {
            self.player = player
        }

        func setToken(_ token: Any) {
            lock.lock()
            defer { lock.unlock() }
            self.token = token
        }

        func invalidate() {
            let token: Any?

            lock.lock()
            token = self.token
            self.token = nil
            lock.unlock()

            guard let token else {
                return
            }

            DispatchQueue.main.async { [player] in
                player.removeTimeObserver(token)
            }
        }

        deinit {
            invalidate()
        }
    }

    let recording: CapturedVideoRecording
    let player: AVPlayer

    @Published private(set) var posterImage: CGImage?
    @Published private(set) var session: VideoEditorSession
    @Published private(set) var currentTimeSeconds: TimeInterval
    @Published private(set) var isPlaying = false
    @Published private(set) var timelineThumbnails: [CGImage] = []
    @Published var errorMessage: String?
    @Published private(set) var exportProgress: VideoExportProgress?
    @Published private(set) var persistenceRevision = 0
    private var posterRefreshTask: Task<Void, Never>?
    private var timelineThumbnailTask: Task<Void, Never>?
    private let timeObserverCleanup: PlayerTimeObserverCleanup
    private var activeExportOperationID: UUID?
    private var exportTask: Task<Void, Never>?
    private var activeExportCancellation: (() -> Void)?

    init(recording: CapturedVideoRecording, session: VideoEditorSession? = nil, posterImage: CGImage? = nil) {
        let normalizedSession = (session ?? .fullDuration(recording.duration)).normalized(for: recording.duration)
        let player = AVPlayer(url: recording.sourceURL)

        self.recording = recording
        self.player = player
        self.session = normalizedSession
        self.currentTimeSeconds = normalizedSession.trimStartSeconds
        self.posterImage = posterImage
        self.timeObserverCleanup = PlayerTimeObserverCleanup(player: player)

        configurePlayerObserver()
        seek(to: self.session.trimStartSeconds)
        refreshTimelineThumbnails()

        if posterImage == nil {
            refreshPoster()
        }
    }

    deinit {
        posterRefreshTask?.cancel()
        timelineThumbnailTask?.cancel()
        exportTask?.cancel()
        timeObserverCleanup.invalidate()
    }

    var documentSession: VideoEditorSession {
        session
    }

    var trimmedDuration: TimeInterval {
        max(session.trimEndSeconds - session.trimStartSeconds, 0)
    }

    var trimStartLabel: String {
        Self.timeLabel(for: session.trimStartSeconds)
    }

    var trimEndLabel: String {
        Self.timeLabel(for: session.trimEndSeconds)
    }

    var durationLabel: String {
        Self.timeLabel(for: recording.duration)
    }

    var trimmedDurationLabel: String {
        Self.timeLabel(for: trimmedDuration)
    }

    var currentTimeLabel: String {
        Self.timeLabel(for: currentTimeSeconds)
    }

    var isExporting: Bool {
        exportProgress != nil
    }

    func updateTrimStart(_ value: TimeInterval) {
        let end = max(session.trimEndSeconds, 0)
        let bounded = min(max(value, 0), max(end - 0.1, 0))
        var nextSession = session
        nextSession.trimStartSeconds = bounded
        nextSession.posterTimeSeconds = min(max(nextSession.posterTimeSeconds, bounded), nextSession.trimEndSeconds)
        applySession(nextSession, refreshPosterWhenPosterTimeChanges: true)

        previewTrimBoundary(at: bounded)
    }

    func updateTrimEnd(_ value: TimeInterval) {
        let bounded = min(max(value, session.trimStartSeconds + 0.1), max(recording.duration, session.trimStartSeconds))
        var nextSession = session
        nextSession.trimEndSeconds = bounded
        nextSession.posterTimeSeconds = min(max(nextSession.posterTimeSeconds, nextSession.trimStartSeconds), bounded)
        applySession(nextSession, refreshPosterWhenPosterTimeChanges: true)

        previewTrimBoundary(at: bounded)
    }

    func setPosterToTrimStart() {
        var nextSession = session
        nextSession.posterTimeSeconds = nextSession.trimStartSeconds
        if nextSession.posterTimeSeconds == session.posterTimeSeconds {
            refreshPoster()
        } else {
            applySession(nextSession, refreshPosterWhenPosterTimeChanges: true)
        }
    }

    func playTrimmedPreview() {
        if currentTimeSeconds < session.trimStartSeconds || currentTimeSeconds >= session.trimEndSeconds {
            seek(to: session.trimStartSeconds)
        }

        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            playTrimmedPreview()
        }
    }

    func scrub(to seconds: TimeInterval) {
        let bounded = min(max(seconds, 0), recording.duration)
        seek(to: bounded)
    }

    func exportVideo(using request: VideoExportRequest) {
        guard !isExporting else {
            errorMessage = VideoStorageError.exportAlreadyInProgress.errorDescription
            return
        }

        exportTask?.cancel()
        exportTask = Task {
            await exportVideoAsync(using: request)
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        activeExportCancellation?()
    }

    func dismissError() {
        errorMessage = nil
    }

    private func exportVideoAsync(using request: VideoExportRequest) async {
        let panel = NSSavePanel()
        let format = request.format
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(recording.defaultFilename).\(format.fileExtension)"
        panel.title = request.menuLabel
        panel.message = request.target.detail

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try await exportVideo(
                EditableVideoDocument(recording: recording, session: session),
                using: request,
                to: url
            )
        } catch is CancellationError {
            // Cancellation is user-initiated and should quietly dismiss progress.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        exportTask = nil
    }

    func promisedVideoPayload(using request: VideoExportRequest) -> PromisedFilePayload? {
        guard !isExporting else {
            errorMessage = VideoStorageError.exportAlreadyInProgress.errorDescription
            return nil
        }

        let dragOutExport = VideoDragOutExport(
            recording: recording,
            session: session,
            request: request
        )

        return PromisedFilePayload(
            suggestedFilename: dragOutExport.suggestedFilename,
            contentType: .mpeg4Movie,
            writer: { [weak self] destinationURL in
                guard let self else {
                    throw CancellationError()
                }

                try await self.exportVideo(
                    dragOutExport.document,
                    using: dragOutExport.request,
                    to: destinationURL
                )
            },
            completion: { [weak self] result in
                guard case .failure(let error) = result,
                      !(error is CancellationError) else {
                    return
                }

                Task { @MainActor [weak self] in
                    self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        )
    }

    private func exportVideo(
        _ document: EditableVideoDocument,
        using request: VideoExportRequest,
        to url: URL
    ) async throws {
        guard !isExporting else {
            throw VideoStorageError.exportAlreadyInProgress
        }

        try VideoStorageGuardrails.cleanupOwnedTemporaryMedia(excluding: [document.recording.sourceURL])
        try VideoStorageGuardrails.ensureCanExport(
            sourceURL: document.recording.sourceURL,
            request: request,
            destinationURL: url
        )

        let exportOperationID = UUID()
        activeExportOperationID = exportOperationID
        exportProgress = VideoExportProgress(
            title: "Preparing Export",
            detail: request.menuLabel,
            fractionCompleted: nil
        )

        let operation = Task {
            try await VideoExporter.export(
                document,
                using: request,
                progressHandler: { [weak self] progress in
                    guard let self, self.activeExportOperationID == exportOperationID else {
                        return
                    }

                    self.exportProgress = progress
                },
                to: url
            )
        }
        activeExportCancellation = {
            operation.cancel()
        }

        defer {
            activeExportOperationID = nil
            activeExportCancellation = nil
            exportProgress = nil
        }

        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private func seek(to seconds: TimeInterval) {
        let bounded = min(max(seconds, 0), recording.duration)
        currentTimeSeconds = bounded
        player.seek(to: CMTime(seconds: bounded, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func previewTrimBoundary(at seconds: TimeInterval) {
        pause()
        seek(to: seconds)
    }

    private func applySession(_ proposedSession: VideoEditorSession, refreshPosterWhenPosterTimeChanges: Bool = false) {
        let oldPosterTime = session.posterTimeSeconds
        let normalizedSession = proposedSession.normalized(for: recording.duration)

        guard normalizedSession != session else {
            return
        }

        session = normalizedSession
        persistenceRevision += 1

        if refreshPosterWhenPosterTimeChanges, normalizedSession.posterTimeSeconds != oldPosterTime {
            refreshPoster()
        }
    }

    private func refreshPoster() {
        let sourceURL = recording.sourceURL
        let posterTimeSeconds = session.posterTimeSeconds
        posterRefreshTask?.cancel()
        posterRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                let image = try await VideoExporter.posterFrame(for: sourceURL, at: posterTimeSeconds)
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    self?.posterImage = image
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func refreshTimelineThumbnails() {
        let sourceURL = recording.sourceURL
        let duration = recording.duration
        let thumbnailCount = max(min(Int(duration.rounded(.up)), 12), 8)
        timelineThumbnailTask?.cancel()
        timelineThumbnailTask = Task { [weak self] in
            do {
                let images = try await VideoExporter.timelineFrames(for: sourceURL, duration: duration, count: thumbnailCount)
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    self?.timelineThumbnails = images
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
            }
        }
    }

    private func configurePlayerObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                let seconds = max(time.seconds, 0)
                self.currentTimeSeconds = seconds

                if self.isPlaying && seconds >= self.session.trimEndSeconds {
                    self.pause()
                    self.seek(to: self.session.trimEndSeconds)
                }
            }
        }
        timeObserverCleanup.setToken(token)
    }

    private static func timeLabel(for seconds: TimeInterval) -> String {
        let bounded = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%02d:%02d", bounded / 60, bounded % 60)
    }
}
