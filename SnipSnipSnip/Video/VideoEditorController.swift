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
    @Published var errorMessage: String? {
        didSet {
            if let errorMessage, errorMessage != oldValue {
                AppAccessibility.announce("Video editor error: \(errorMessage)", priority: .high)
            }
        }
    }
    @Published private(set) var statusMessage: String?
    @Published private(set) var exportProgress: VideoExportProgress?
    @Published private(set) var persistenceRevision = 0
    @Published private(set) var isPreparingPreview = false
    @Published private(set) var previewError: String?
    @Published var inspectorSection: VideoInspectorSection = .trim
    @Published var isPolishing = false
    @Published var selectedZoomID: UUID?
    weak var undoManager: UndoManager?
    private var continuousEditStart: VideoEditorSession?
    private var continuousEditName: String?
    private var previewTask: Task<Void, Never>?
    private var preparedPipeline: VideoRenderPipeline?
    private var posterRefreshTask: Task<Void, Never>?
    private var timelineThumbnailTask: Task<Void, Never>?
    private let timeObserverCleanup: PlayerTimeObserverCleanup
    private var activeExportOperationID: UUID?
    private var exportTask: Task<Void, Never>?
    private var activeExportCancellation: (() -> Void)?

    init(recording: CapturedVideoRecording, session: VideoEditorSession? = nil, posterImage: CGImage? = nil) {
        var initial = session ?? .fullDuration(recording.duration)
        if session == nil { initial.effects = .initial(for: recording) }
        let normalizedSession = initial.normalized(for: recording.duration)
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
        refreshPreview()

    }

    deinit {
        posterRefreshTask?.cancel()
        timelineThumbnailTask?.cancel()
        exportTask?.cancel()
        previewTask?.cancel()
        timeObserverCleanup.invalidate()
    }

    var documentSession: VideoEditorSession {
        session
    }

    var previewPixelSize: CGSize {
        preparedPipeline?.renderer.outputSize ?? recording.bounds.size
    }

    var previewRenderer: VideoFrameRenderer? { preparedPipeline?.renderer }

    var trimmedDuration: TimeInterval {
        VideoEditTimeline(session: session, duration: recording.duration).duration
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

    var exportSummaryLabel: String {
        let source = session.effects.audioVolume > 0 && (recording.preferences.recordsSystemAudio || recording.preferences.recordsMicrophone) ? "Audio on" : "Silent"
        return "\(trimmedDurationLabel) clip • \(recording.preferences.frameRate.label) source • \(source)"
    }

    var currentTimeLabel: String {
        Self.timeLabel(for: currentTimeSeconds)
    }

    var isExporting: Bool {
        exportProgress != nil
    }

    func updateTrimStart(_ value: TimeInterval) {
        perform(.trimStart(value))
        previewTrimBoundary(at: session.trimStartSeconds)
    }

    func updateTrimEnd(_ value: TimeInterval) {
        perform(.trimEnd(value))
        previewTrimBoundary(at: session.trimEndSeconds)
    }

    func setPosterToTrimStart() {
        if session.posterTimeSeconds == session.trimStartSeconds {
            refreshPoster()
        } else {
            perform(.poster(session.trimStartSeconds))
        }
    }

    func playTrimmedPreview() {
        guard !isPreparingPreview, previewError == nil else { return }
        if currentTimeSeconds < session.trimStartSeconds || currentTimeSeconds >= session.trimEndSeconds {
            seek(to: session.trimStartSeconds)
        }

        if let cut = session.removedRanges.first(where: { $0.start <= currentTimeSeconds && currentTimeSeconds < $0.end }) {
            seek(to: cut.end)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func returnToStart() {
        let firstKeptTime = VideoEditTimeline(session: session, duration: recording.duration).ranges.first?.start
            ?? session.trimStartSeconds
        scrub(to: firstKeptTime)
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            playTrimmedPreview()
        }
    }

    func scrub(to seconds: TimeInterval) {
        pause()
        let bounded = min(max(seconds, 0), recording.duration)
        seek(to: bounded)
    }

    func exportVideo(using request: VideoExportRequest) {
        guard !isExporting else {
            errorMessage = VideoStorageError.exportAlreadyInProgress.errorDescription
            return
        }

        let capability = VideoExportSupport.capability(for: request.format, target: request.target)
        guard capability.isSupported else {
            errorMessage = capability.unsupportedReason
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

    func dismissStatus() {
        statusMessage = nil
    }

    private func exportVideoAsync(using request: VideoExportRequest) async {
        let panel = NSSavePanel()
        let format = request.format
        panel.allowedContentTypes = [format.contentType]
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
            statusMessage = "Exported \(request.menuLabel) to \(url.lastPathComponent)."
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

        let resolvedRequest: VideoExportRequest
        if VideoExportSupport.capability(for: request.format, target: request.target).isSupported {
            resolvedRequest = request
        } else {
            resolvedRequest = VideoExportRequest(format: .mp4, target: .quality(.balanced), updatesDefaults: false)
            statusMessage = "Drag-out sharing fell back to MP4 because \(request.format.label) export is unavailable."
        }

        let dragOutExport = VideoDragOutExport(
            recording: recording,
            session: session,
            request: resolvedRequest
        )

        return PromisedFilePayload(
            suggestedFilename: dragOutExport.suggestedFilename,
            contentType: dragOutExport.request.format.contentType,
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
        let oldEffects = session.effects
        let normalizedSession = proposedSession.normalized(for: recording.duration)

        guard normalizedSession != session else {
            return
        }

        session = normalizedSession
        persistenceRevision += 1

        if normalizedSession.effects != oldEffects {
            posterImage = nil
            refreshPreview()
        }

        if refreshPosterWhenPosterTimeChanges, normalizedSession.posterTimeSeconds != oldPosterTime {
            posterImage = nil
            refreshPoster()
        }
    }

    private func refreshPoster() {
        guard !isPreparingPreview, let renderer = preparedPipeline?.renderer else { return }
        let sourceURL = recording.sourceURL
        let posterTimeSeconds = session.posterTimeSeconds
        posterRefreshTask?.cancel()
        posterRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                let source = try await VideoExporter.posterFrame(for: sourceURL, at: posterTimeSeconds)
                let image = renderer.cgImage(source, at: posterTimeSeconds)
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
                guard !self.isPreparingPreview else { return }
                self.currentTimeSeconds = seconds

                if self.isPlaying && seconds >= self.session.trimEndSeconds {
                    self.pause()
                    self.seek(to: self.session.trimEndSeconds)
                } else if self.isPlaying, let cut = self.session.removedRanges.first(where: { $0.start <= seconds && seconds < $0.end }) {
                    self.seek(to: min(cut.end, self.session.trimEndSeconds))
                }
            }
        }
        timeObserverCleanup.setToken(token)
    }

    private static func timeLabel(for seconds: TimeInterval) -> String {
        let bounded = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%02d:%02d", bounded / 60, bounded % 60)
    }

    func perform(_ command: VideoEditCommand) {
        let next = command.applying(to: session, recording: recording)
        guard next != session else { return }
        if continuousEditStart == nil { registerUndo(session: session, name: command.name) }
        applySession(next, refreshPosterWhenPosterTimeChanges: true)
    }

    func beginContinuousEdit(_ name: String) {
        guard continuousEditStart == nil else { return }
        continuousEditStart = session
        continuousEditName = name
    }

    func endContinuousEdit() {
        if let previous = continuousEditStart, previous != session {
            registerUndo(session: previous, name: continuousEditName ?? "Edit Video")
        }
        continuousEditStart = nil
        continuousEditName = nil
    }

    private func registerUndo(session previous: VideoEditorSession, name: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerUndo(session: target.session, name: name)
            target.applySession(previous, refreshPosterWhenPosterTimeChanges: true)
        }
        undoManager?.setActionName(name)
    }

    func polishVideo() {
        var effects = session.effects
        effects.presentation = ScreenshotPresentationPreset.lifted.settings
        effects.smoothsCursor = true
        effects.cursorScale = 1.5
        if let interactions = recording.interactions {
            effects.zooms = VideoSmartZooms.suggest(track: interactions, duration: recording.duration)
        }
        perform(.effects(effects, name: "Polish Video"))
    }

    func addZoom() {
        var effects = session.effects
        let start = min(max(currentTimeSeconds, session.trimStartSeconds), max(session.trimEndSeconds - 1, session.trimStartSeconds))
        let zoom = VideoZoom(start: start, end: min(start + 3, session.trimEndSeconds),
                             followsCursor: recording.interactions?.samples.isEmpty == false,
                             center: recording.interactions?.cursor(at: start, smooth: true) ?? .center)
        effects.zooms.append(zoom)
        perform(.effects(effects, name: "Add Zoom"))
        selectedZoomID = zoom.id
        inspectorSection = .zooms
    }

    func refreshPreview() {
        let document = EditableVideoDocument(recording: recording, session: session)
        previewTask?.cancel()
        posterRefreshTask?.cancel()
        isPreparingPreview = true
        previewError = nil
        pause()
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(90))
                let pipeline = try await VideoRenderPipeline.make(document: document, appliesCuts: false,
                                                                   sourceAsset: self?.player.currentItem?.asset as? AVURLAsset)
                guard !Task.isCancelled, let self else { return }
                let time = self.currentTimeSeconds
                self.preparedPipeline = pipeline
                if let item = self.player.currentItem, item.asset === pipeline.asset {
                    item.videoComposition = pipeline.videoComposition
                    item.audioMix = pipeline.audioMix
                } else {
                    self.player.replaceCurrentItem(with: pipeline.playerItem())
                }
                self.seek(to: time)
                self.isPreparingPreview = false
                self.refreshPoster()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isPreparingPreview = false
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.previewError = "\(reason) Your recording and edits are still available in this session."
            }
        }
    }
}
