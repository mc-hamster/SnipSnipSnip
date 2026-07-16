import AppKit
import Combine
import CoreGraphics
import CoreMedia
import Foundation

nonisolated enum GuideCaptureState: String, Codable, Sendable {
    case idle
    case starting
    case recording
    case paused
    case finishing
}

@MainActor
final class GuideCaptureCoordinator: ObservableObject {
    @Published private(set) var state: GuideCaptureState = .idle
    @Published private(set) var project: GuideProject?
    @Published private(set) var stepImages: [UUID: CGImage] = [:]
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishingStartedAt: Date?
    @Published private(set) var finishingEstimatedDuration: TimeInterval = 0
    @Published private(set) var finishingProgress: Double = 0
    @Published private(set) var finishingStatus = ""
    @Published private(set) var audioLevels = ScreenRecordingAudioLevels()
    @Published private(set) var isUpdatingAudioOptions = false
    private var startedUptime: TimeInterval?

    private let systemServices: AppSystemServices
    private let eventMonitor: GuideEventMonitor
    private let frameComposer = GuideFrameComposer()
    private let classifier = GuideEventClassifier()
    private let captionGenerator: GuideCaptionGenerator
    private let textEntryObserver: GuideTextEntryObserver
    private var mediaSession: GuideMediaCaptureSession?
    private var preferences = GuideCapturePreferences()
    private var pendingScrollTask: Task<Void, Never>?
    private var pendingScroll: (event: GuideObservedEvent, timestamp: CMTime, direction: String, distance: Double)?
    private var pendingGestureTask: Task<Void, Never>?
    private var pendingGesture: (event: GuideObservedEvent, direction: String)?
    private var lastGestureTime: TimeInterval = -.infinity
    private var pendingTextEntryTask: Task<Void, Never>?
    private var pendingTextEntry: (event: GuideObservedEvent, caption: GuideCaptionResult)?
    private let recoveryStore: GuideRecoveryStore
    private var recoveryTask: Task<Void, Never>?
    private var cursorSamples: [GuideCursorSample] = []
    private var lastCursorSampleTime: TimeInterval = -.infinity
    private var guideShortcutKeyCode: UInt16?

    init(
        systemServices: AppSystemServices,
        eventMonitor: GuideEventMonitor = GuideEventMonitor(),
        recoveryStore: GuideRecoveryStore = GuideRecoveryStore()
    ) {
        self.systemServices = systemServices
        self.eventMonitor = eventMonitor
        let captionGenerator = GuideCaptionGenerator(accessibility: systemServices.accessibility)
        self.captionGenerator = captionGenerator
        self.textEntryObserver = GuideTextEntryObserver(captionGenerator: captionGenerator)
        self.recoveryStore = recoveryStore
    }

    func start(
        source: GuideCaptureSource,
        preferences: GuideCapturePreferences,
        exportSettings: GuideExportSettings,
        theme: GuideTheme,
        privateCapture: Bool,
        guideShortcutKeyCode: UInt16
    ) async throws {
        guard state == .idle else { return }
        guard systemServices.accessibility.isProcessTrusted() else {
            throw GuideEventMonitorError.accessibilityRequired
        }
        state = .starting
        self.preferences = preferences
        self.guideShortcutKeyCode = guideShortcutKeyCode
        var project = GuideProject(source: source, isPrivate: privateCapture)
        project.exportSettings = exportSettings
        project.theme = theme
        project.timeline.sourceVideoEnabled = preferences.sourceVideoEnabled
        self.project = project
        stepImages = [:]
        cursorSamples = []
        pendingGestureTask?.cancel()
        pendingGestureTask = nil
        pendingGesture = nil
        lastGestureTime = -.infinity
        audioLevels = ScreenRecordingAudioLevels()
        resetFinishingStatus()
        pendingTextEntryTask?.cancel()
        pendingTextEntryTask = nil
        pendingTextEntry = nil
        stopTextEntryObservation()

        do {
            let media = try await GuideMediaCaptureSession.make(source: source, preferences: preferences, systemServices: systemServices)
            media.audioLevelHandler = { [weak self] levels in
                self?.audioLevels = levels
            }
            mediaSession = media
            try await media.start()
            try eventMonitor.start { [weak self] event, timestamp in
                self?.receive(event, timestamp: timestamp)
            }
            startedAt = Date()
            startedUptime = ProcessInfo.processInfo.systemUptime
            state = .recording
            startTextEntryObservation()
        } catch {
            eventMonitor.stop()
            mediaSession = nil
            self.project = nil
            audioLevels = ScreenRecordingAudioLevels()
            state = .idle
            throw error
        }
    }

    func pause() async throws {
        guard state == .recording else { return }
        stopTextEntryObservation()
        flushPendingTextEntry()
        flushPendingGesture()
        state = .paused
        eventMonitor.stop()
        pendingScrollTask?.cancel()
        pendingScrollTask = nil
        pendingScroll = nil
        try await mediaSession?.pause()
        audioLevels = ScreenRecordingAudioLevels()
        synchronizeFinalizedSegments()
        scheduleRecoveryWrite()
    }

    func resume() throws {
        guard state == .paused else { return }
        try mediaSession?.resume()
        try eventMonitor.start { [weak self] event, timestamp in self?.receive(event, timestamp: timestamp) }
        state = .recording
        startTextEntryObservation()
    }

    /// Applies the Guide HUD's live audio choices to the active source-media capture.
    /// Audio options are intentionally only mutable while recording: changing a
    /// ScreenCaptureKit configuration closes the current media segment, and a paused
    /// Guide should not unexpectedly start a new one.
    func updateAudioOptions(capturesSystemAudio: Bool, capturesMicrophone: Bool) async throws {
        guard state == .recording else { return }
        isUpdatingAudioOptions = true
        defer { isUpdatingAudioOptions = false }
        try await mediaSession?.updateAudioOptions(
            capturesSystemAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone
        )
        preferences.capturesSystemAudio = capturesSystemAudio
        preferences.capturesMicrophone = capturesMicrophone
        audioLevels = ScreenRecordingAudioLevels(
            system: capturesSystemAudio ? audioLevels.system : 0,
            microphone: capturesMicrophone ? audioLevels.microphone : 0
        )
    }

    func addManualStep() {
        guard state == .recording else { return }
        flushPendingTextEntry()
        let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
        let appKitPoint = systemServices.mouse.appKitGlobalLocation
        let location = CursorCaptureGeometry.captureGlobalPoint(fromAppKitGlobalPoint: appKitPoint) ?? appKitPoint
        let event = GuideObservedEvent(timestamp: ProcessInfo.processInfo.systemUptime, location: location, payload: .manual)
        flushPendingGesture()
        captureStep(for: event, classified: .manual, timestamp: timestamp)
    }

    func undoLastStep() {
        guard var project, let removed = project.steps.popLast() else { return }
        stepImages[removed.id] = nil
        project.normalizeStepSequence()
        self.project = project
    }

    func deleteStep(id: UUID) {
        guard var project, let index = project.steps.firstIndex(where: { $0.id == id }) else { return }
        project.steps.remove(at: index)
        stepImages[id] = nil
        project.normalizeStepSequence()
        self.project = project
    }

    func stop() async throws -> EditableGuideDocument? {
        guard state == .recording || state == .paused else { return nil }
        state = .finishing
        finishingStartedAt = Date()
        finishingEstimatedDuration = estimatedFinishingDuration()
        finishingProgress = 0.08
        finishingStatus = "Stopping capture…"
        eventMonitor.stop()
        stopTextEntryObservation()
        pendingScrollTask?.cancel()
        pendingGestureTask?.cancel()
        flushPendingTextEntry()
        if let pendingScroll { captureStep(for: pendingScroll.event, classified: .scroll(direction: pendingScroll.direction, distance: pendingScroll.distance), timestamp: pendingScroll.timestamp) }
        self.pendingScroll = nil
        flushPendingGesture()
        let segments: [(GuideTimelineSegment, URL)]
        do {
            segments = try await mediaSession?.stop() ?? []
        } catch {
            // Keep the HUD actionable after a finalization failure. From paused, the user can
            // retry Stop, resume into a fresh segment, or discard instead of being stranded in
            // an indefinitely disabled Finishing state.
            state = .paused
            resetFinishingStatus()
            throw error
        }
        mediaSession = nil
        guard var project else {
            resetFinishingStatus()
            state = .idle
            return nil
        }
        finishingProgress = 0.68
        finishingStatus = "Preparing Guide…"
        project.timeline.segments = segments.map(\.0)
        project.timeline.cursorSamples = cursorSamples
        let mediaURLs = Dictionary(uniqueKeysWithValues: segments.map { ($0.0.id, $0.1) })
        finishingProgress = 0.78
        finishingStatus = "Rendering Guide preview…"
        let preview = GuideRenderer.renderPreview(project: project, images: stepImages)
        let document = EditableGuideDocument(project: project, stepImages: stepImages, previewImage: preview, logoImage: nil, mediaSegmentURLs: mediaURLs)
        if !project.isPrivate {
            finishingProgress = 0.9
            finishingStatus = "Starting local recovery save…"
            // A recovery package can include a long source-media file. Start its
            // disk copy in the background rather than holding the Guide HUD open
            // until that copy completes; the editable document already owns the
            // finalized media URLs and is ready to open immediately.
            recoveryTask?.cancel()
            recoveryTask = Task.detached(priority: .utility) { [recoveryStore] in
                try? recoveryStore.save(document)
            }
        }
        self.project = nil
        stepImages = [:]
        audioLevels = ScreenRecordingAudioLevels()
        startedAt = nil
        startedUptime = nil
        resetFinishingStatus()
        state = .idle
        return document
    }

    func discard() async {
        let projectID = project?.id
        eventMonitor.stop()
        pendingScrollTask?.cancel()
        pendingGestureTask?.cancel()
        pendingGestureTask = nil
        pendingGesture = nil
        pendingTextEntryTask?.cancel()
        pendingTextEntryTask = nil
        pendingTextEntry = nil
        stopTextEntryObservation()
        await mediaSession?.discard()
        mediaSession = nil
        project = nil
        stepImages = [:]
        audioLevels = ScreenRecordingAudioLevels()
        startedAt = nil
        startedUptime = nil
        resetFinishingStatus()
        state = .idle
        if let projectID { recoveryStore.remove(projectID: projectID) }
    }

    private func estimatedFinishingDuration() -> TimeInterval {
        // Source media is cropped by ScreenCaptureKit while recording, so finishing
        // no longer scales with recording duration. Recovery persistence continues
        // in the background after the editable document opens.
        let mediaWork = preferences.sourceVideoEnabled ? 2.5 : 1
        return min(max(2, mediaWork + Double(stepImages.count) * 0.03), 7)
    }

    private func resetFinishingStatus() {
        finishingStartedAt = nil
        finishingEstimatedDuration = 0
        finishingProgress = 0
        finishingStatus = ""
    }

    private func receive(_ event: GuideObservedEvent, timestamp: CMTime) {
        guard state == .recording else {
            return
        }
        if case .cursorMoved = event.payload {
            guard accepts(event) else { return }
            if event.timestamp - lastCursorSampleTime >= 1.0 / 60.0 {
                cursorSamples.append(GuideCursorSample(
                    timestampSeconds: max(0, event.timestamp - (startedUptime ?? event.timestamp)),
                    point: event.location
                ))
                lastCursorSampleTime = event.timestamp
            }
            return
        }
        let classified = classifier.classify(event, guideShortcutKeyCode: guideShortcutKeyCode)
        if case .textEntry = classified {
            flushPendingGesture()
            let fromPrintableKeyEvent: Bool
            if case .keyDown = event.payload { fromPrintableKeyEvent = true }
            else { fromPrintableKeyEvent = false }
            guard var caption = captionGenerator.textEntryCaption(
                at: event.location,
                fromPrintableKeyEvent: fromPrintableKeyEvent
            ) else { return }
            if caption.metadata?.processID == nil,
               let frontmostProcessID = systemServices.workspace.frontmostApplicationProcessIdentifier {
                var metadata = caption.metadata ?? GuideTargetMetadata()
                metadata.processID = frontmostProcessID
                caption.metadata = metadata
            }
            let location = caption.metadata?.frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? event.location
            // The key event proves that text changed, but the character itself is
            // not needed after classification and must not survive the callback.
            let textEvent = GuideObservedEvent(timestamp: event.timestamp, location: location, payload: .textChanged)
            guard acceptsTextEntry(metadata: caption.metadata, fallbackEvent: textEvent) else { return }
            queueTextEntry(event: textEvent, caption: caption)
            return
        }
        guard accepts(event) else { return }
        if classified == .click || classified == .doubleClick || classified == .selection {
            establishFocusedTextEntryBaseline()
        }
        switch classified {
        case .ignored: return
        case .scroll(let direction, let distance):
            if pendingGesture != nil || event.timestamp - lastGestureTime <= GuideEventClassifier.gestureQuietInterval {
                return
            }
            flushPendingTextEntry()
            if var existing = pendingScroll {
                existing.event = event
                existing.timestamp = timestamp
                existing.direction = direction
                existing.distance += distance
                pendingScroll = existing
            } else {
                pendingScroll = (event, timestamp, direction, distance)
            }
            pendingScrollTask?.cancel()
            pendingScrollTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, let pending = self.pendingScroll else { return }
                self.pendingScroll = nil
                self.captureStep(for: pending.event, classified: .scroll(direction: pending.direction, distance: pending.distance), timestamp: pending.timestamp)
            }
        case .gesture(let direction):
            flushPendingTextEntry()
            pendingScrollTask?.cancel()
            pendingScrollTask = nil
            pendingScroll = nil
            lastGestureTime = event.timestamp
            queueGesture(event: event, direction: direction)
        case .doubleClick:
            flushPendingTextEntry()
            flushPendingGesture()
            if var project,
               let index = project.steps.indices.last,
               project.steps[index].eventKind == .click,
               Date().timeIntervalSince(project.steps[index].capturedAt) <= NSEvent.doubleClickInterval {
                project.steps[index].eventKind = .doubleClick
                let caption = captionGenerator.immediateCaption(for: classified, at: event.location)
                project.steps[index].caption = caption.deterministicCaption
                project.steps[index].deterministicCaption = caption.deterministicCaption
                self.project = project
            } else {
                captureStep(for: event, classified: classified, timestamp: timestamp)
            }
        default:
            flushPendingTextEntry()
            flushPendingGesture()
            captureStep(for: event, classified: classified, timestamp: timestamp)
        }
    }

    private func queueGesture(event: GuideObservedEvent, direction: String) {
        pendingGesture = (event, direction)
        pendingGestureTask?.cancel()
        pendingGestureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(GuideEventClassifier.gestureQuietInterval))
            guard !Task.isCancelled, let self else { return }
            self.flushPendingGesture()
        }
    }

    private func flushPendingGesture() {
        pendingGestureTask?.cancel()
        pendingGestureTask = nil
        guard let pending = pendingGesture else { return }
        pendingGesture = nil
        // A fullscreen swipe animates between Spaces. Save the current frame
        // after the transition instead of the frame from before the gesture.
        captureStep(
            for: pending.event,
            classified: .gesture(direction: pending.direction),
            timestamp: CMClockGetTime(CMClockGetHostTimeClock())
        )
    }

    private func queueTextEntry(event: GuideObservedEvent, caption: GuideCaptionResult) {
        pendingTextEntry = (event, caption)
        pendingTextEntryTask?.cancel()
        pendingTextEntryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(GuideEventClassifier.textEntryQuietInterval))
            guard !Task.isCancelled, let self else { return }
            self.flushPendingTextEntry()
        }
    }

    private func startTextEntryObservation() {
        textEntryObserver.start { [weak self] observation in
            self?.receiveFocusedTextEntryChange(observation)
        }
    }

    private func stopTextEntryObservation() {
        textEntryObserver.stop()
    }

    private func receiveFocusedTextEntryChange(_ observation: GuideTextEntryObservation) {
        guard state == .recording else { return }
        let location = observation.caption.metadata?.frame.map {
            CGPoint(x: $0.midX, y: $0.midY)
        } ?? CursorCaptureGeometry.captureGlobalPoint(
            fromAppKitGlobalPoint: systemServices.mouse.appKitGlobalLocation
        ) ?? systemServices.mouse.appKitGlobalLocation
        let event = GuideObservedEvent(
            timestamp: ProcessInfo.processInfo.systemUptime,
            location: location,
            payload: .textChanged
        )
        guard acceptsTextEntry(metadata: observation.caption.metadata, fallbackEvent: event) else { return }
        queueTextEntry(event: event, caption: observation.caption)
    }

    private func establishFocusedTextEntryBaseline() {
        textEntryObserver.establishFocusedFieldBaseline()
    }

    private func flushPendingTextEntry() {
        pendingTextEntryTask?.cancel()
        pendingTextEntryTask = nil
        guard let pending = pendingTextEntry else { return }
        pendingTextEntry = nil
        // Text steps should show the completed entry, unlike click steps that
        // intentionally preserve the frame from immediately before the action.
        captureStep(
            for: pending.event,
            classified: .textEntry,
            timestamp: CMClockGetTime(CMClockGetHostTimeClock()),
            captionResult: pending.caption
        )
    }

    private func captureStep(
        for event: GuideObservedEvent,
        classified: GuideClassifiedEvent,
        timestamp: CMTime,
        captionResult suppliedCaptionResult: GuideCaptionResult? = nil
    ) {
        let captionResult = suppliedCaptionResult ?? captionGenerator.immediateCaption(for: classified, at: event.location)
        guard var project else {
            return
        }
        guard let mediaSession else {
            return
        }
        guard let frame = mediaSession.newestFrame(before: timestamp) else {
            return
        }
        guard let composition = try? frameComposer.compose(
                frame: frame,
                source: project.source,
                capturedDisplayFrame: mediaSession.capturedDisplayFrame,
                transientFrame: captionResult.metadata?.frame
              ) else {
            return
        }
        let point = sourcePixelPoint(event.location, sourceRect: composition.sourceRect, image: composition.image)
        let tail = automaticTail(for: point, size: CGSize(width: composition.image.width, height: composition.image.height))
        var redactions: [GuideRedaction] = []
        if preferences.masksSecureFields,
           captionResult.metadata?.isSecure == true,
           let frame = captionResult.metadata?.frame {
            redactions = [GuideRedaction(kind: .solid, rect: sourcePixelRect(frame, sourceRect: composition.sourceRect, image: composition.image))]
        }
        let kind: GuideEventKind
        var shortcut: String?
        var scrollDistance: Double?
        switch classified {
        case .click: kind = .click
        case .doubleClick: kind = .doubleClick
        case .selection: kind = .selection
        case .textEntry: kind = .textEntry
        case .scroll(_, let distance): kind = .scroll; scrollDistance = distance
        case .gesture: kind = .gesture
        case .shortcut(let value): kind = .shortcut; shortcut = value
        case .manual: kind = .manual
        case .ignored: return
        }
        let step = GuideStep(
            sequence: project.steps.count + 1,
            eventKind: kind,
            capturedAt: Date(),
            sourceTimestampSeconds: max(0, event.timestamp - (startedUptime ?? event.timestamp)),
            caption: captionResult.deterministicCaption,
            keyboardShortcut: shortcut,
            scrollDistance: scrollDistance,
            targetMetadata: captionResult.metadata,
            session: GuideStepSession(
                marker: GuideMarker(target: point, tail: tail, length: Double(hypot(tail.x - point.x, tail.y - point.y))),
                redactions: redactions,
                sourceCoordinateRect: composition.sourceRect,
                sourcePixelSize: CGSize(width: composition.image.width, height: composition.image.height),
                showsCursor: preferences.showsCursorInSteps
            )
        )
        project.steps.append(step)
        project.modifiedAt = Date()
        self.project = project
        stepImages[step.id] = composition.image
        scheduleRecoveryWrite()
        refineCaptionIfNeeded(stepID: step.id, image: composition.image)
    }

    private func refineCaptionIfNeeded(stepID: UUID, image: CGImage) {
        guard preferences.automaticCaptions,
              let step = project?.steps.first(where: { $0.id == stepID }),
              step.eventKind != .manual else { return }
        let revision = step.captionRevision
        let deterministic = step.deterministicCaption
        let metadata = step.targetMetadata
        let isPrivate = project?.isPrivate == true
        Task { [weak self] in
            guard let self else { return }
            let ocr = metadata?.label == nil && metadata?.title == nil ? await captionGenerator.recognizeFallbackText(in: image, privateCapture: isPrivate) : nil
            guard preferences.aiCaptionRefinement,
                  let refined = await captionGenerator.refineCaption(deterministic: deterministic, metadata: metadata, recognizedText: ocr, privateCapture: isPrivate),
                  var project = self.project,
                  let index = project.steps.firstIndex(where: { $0.id == stepID }),
                  project.steps[index].captionRevision == revision,
                  !project.steps[index].userEditedCaption else { return }
            project.steps[index].caption = refined
            self.project = project
            self.scheduleRecoveryWrite()
        }
    }

    private func synchronizeFinalizedSegments() {
        guard var project, let mediaSession else { return }
        project.timeline.segments = mediaSession.completedSegments.map(\.0)
        self.project = project
    }

    private func scheduleRecoveryWrite() {
        guard let project, !project.isPrivate, !project.steps.isEmpty else { return }
        let mediaURLs = Dictionary(uniqueKeysWithValues: (mediaSession?.completedSegments ?? []).map { ($0.0.id, $0.1) })
        let document = EditableGuideDocument(
            project: project,
            stepImages: stepImages,
            previewImage: GuideRenderer.renderPreview(project: project, images: stepImages),
            logoImage: nil,
            mediaSegmentURLs: mediaURLs
        )
        recoveryTask?.cancel()
        recoveryTask = Task.detached(priority: .utility) { [recoveryStore] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            try? recoveryStore.save(document)
        }
    }

    private func accepts(_ event: GuideObservedEvent) -> Bool {
        guard let project else { return false }
        let process = targetProcess(at: event.location)
        if process == ProcessInfo.processInfo.processIdentifier { return false }
        switch project.source {
        case .window(_, let pid, _, let frame):
            // Menus, sheets and system pickers can sit outside the primary window. AX ownership
            // is stronger than geometry; geometry remains the safe fallback when AX is silent.
            return process == pid || (process == nil && frame.contains(event.location))
        case .app(let pid, _, _, let frame):
            return process == pid || (process == nil && frame.contains(event.location))
        case .region(let rect): return rect.contains(event.location)
        case .displays(.all): return displayID(containingCapturePoint: event.location) != nil
        case .displays(.current):
            return displayID(containingCapturePoint: event.location) == mediaSession?.captureDisplayID
        case .displays(.selected(let identifiers)):
            guard let displayID = displayID(containingCapturePoint: event.location) else { return false }
            return identifiers.contains(displayID)
        }
    }

    private func acceptsTextEntry(
        metadata: GuideTargetMetadata?,
        fallbackEvent: GuideObservedEvent
    ) -> Bool {
        guard let project else { return false }
        guard metadata?.processID != ProcessInfo.processInfo.processIdentifier else { return false }

        switch project.source {
        case .window(_, let processID, _, _), .app(let processID, _, _, _):
            if let focusedProcessID = metadata?.processID {
                return focusedProcessID == processID
            }
        case .region(let rect):
            if let frame = metadata?.frame {
                return rect.intersects(frame)
            }
        case .displays:
            break
        }
        return accepts(fallbackEvent)
    }

    private func displayID(containingCapturePoint point: CGPoint) -> CGDirectDisplayID? {
        systemServices.screens.screens.first { CGDisplayBounds($0.displayID).contains(point) }?.displayID
    }

    private func targetProcess(at point: CGPoint) -> pid_t? {
        guard systemServices.accessibility.isProcessTrusted() else { return nil }
        let result = systemServices.accessibility.element(at: point, from: systemServices.accessibility.systemWideElement())
        guard let element = result.element else { return nil }
        return systemServices.accessibility.processIdentifier(for: element).processID
    }

    private func sourcePixelPoint(_ point: CGPoint, sourceRect: CGRect, image: CGImage) -> CGPoint {
        CGPoint(x: (point.x - sourceRect.minX) / sourceRect.width * CGFloat(image.width), y: (point.y - sourceRect.minY) / sourceRect.height * CGFloat(image.height))
    }

    private func sourcePixelRect(_ rect: CGRect, sourceRect: CGRect, image: CGImage) -> CGRect {
        let origin = sourcePixelPoint(rect.origin, sourceRect: sourceRect, image: image)
        return CGRect(origin: origin, size: CGSize(width: rect.width / sourceRect.width * CGFloat(image.width), height: rect.height / sourceRect.height * CGFloat(image.height)))
    }

    private func automaticTail(for target: CGPoint, size: CGSize) -> CGPoint {
        let dx: CGFloat = target.x < size.width / 2 ? 80 : -80
        let dy: CGFloat = target.y < size.height / 2 ? 80 : -80
        return CGPoint(x: min(max(target.x + dx, 24), size.width - 24), y: min(max(target.y + dy, 24), size.height - 24))
    }
}
