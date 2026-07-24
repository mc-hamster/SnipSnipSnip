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

nonisolated enum GuideFinalizationPhase: String, Equatable, Sendable {
    case stoppingMedia
    case preparingDocument
    case renderingPreview
    case savingRecovery
    case complete
}

nonisolated struct GuideFinalizationProgress: Equatable, Sendable {
    let phase: GuideFinalizationPhase
    let detail: String
    let fraction: Double?
}

nonisolated enum GuideCaptureInterruptionError: LocalizedError, Equatable {
    case screenRecordingPermissionChanged
    case accessibilityPermissionChanged

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionChanged:
            "Screen Recording access changed while Guide was running. Restore it in System Settings, then Resume; completed steps are preserved."
        case .accessibilityPermissionChanged:
            "Accessibility access changed while Guide was running. Restore it in System Settings, then Resume; completed steps are preserved."
        }
    }
}

@MainActor
final class GuideCaptureCoordinator: ObservableObject {
    @Published private(set) var state: GuideCaptureState = .idle
    @Published private(set) var project: GuideProject?
    @Published private(set) var stepImages: [UUID: CGImage] = [:]
    @Published private(set) var stepThumbnails: [UUID: CGImage] = [:]
    @Published private(set) var startedAt: Date?
    @Published private(set) var finalizationProgress: GuideFinalizationProgress?
    @Published private(set) var audioLevels = ScreenRecordingAudioLevels()
    @Published private(set) var isUpdatingAudioOptions = false
    @Published private(set) var captureIssue: String?
    @Published private(set) var recoveryIssue: String?
    @Published private(set) var isDiscarding = false
    private var startedUptime: TimeInterval?

    private let systemServices: AppSystemServices
    private let eventMonitor: GuideEventMonitor
    private let frameComposer = GuideFrameComposer()
    private let classifier = GuideEventClassifier()
    private let captionGenerator: GuideCaptionGenerator
    private let textEntryObserver: GuideTextEntryObserver
    private var mediaSession: GuideMediaCaptureSession?
    private var logoImage: CGImage?
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
    private var pendingRecoveryDocument: EditableGuideDocument?
    private var recoveryRevision = 0
    private var pendingRecoveryWriteIsUrgent = false
    private var isRecoveryWriteInFlight = false
    private var lastRecoveryWriteAt = Date.distantPast
    private var guardrailTask: Task<Void, Never>?
    private var sourceTrackingTask: Task<Void, Never>?
    private var retargetTask: Task<Void, Never>?
    private var activeRetargetID: UUID?
    private var isRetargeting = false
    private var queuedCaptures: [QueuedCapture] = []
    private var missingSourceChecks = 0
    private var requiresMediaSessionReplacement = false
    private var retainedSegments: [(GuideTimelineSegment, URL)] = []
    private var cursorSamples: [GuideCursorSample] = []
    private var lastCursorSampleTime: TimeInterval = -.infinity
    private var guideShortcutKeyCode: UInt16?

    private struct QueuedCapture {
        let event: GuideObservedEvent
        let classified: GuideClassifiedEvent
        let timestamp: CMTime
        let captionResult: GuideCaptionResult
    }

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
        logoImage: CGImage?,
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
        project.theme.logoAsset = logoImage == nil ? nil : "brand/logo.png"
        project.timeline.sourceVideoEnabled = preferences.sourceVideoEnabled
        self.project = project
        self.logoImage = logoImage
        stepImages = [:]
        stepThumbnails = [:]
        cursorSamples = []
        retainedSegments = []
        requiresMediaSessionReplacement = false
        isRetargeting = false
        queuedCaptures = []
        missingSourceChecks = 0
        pendingRecoveryDocument = nil
        recoveryRevision = 0
        pendingRecoveryWriteIsUrgent = false
        isRecoveryWriteInFlight = false
        lastRecoveryWriteAt = .distantPast
        captureIssue = nil
        recoveryIssue = nil
        pendingGestureTask?.cancel()
        pendingGestureTask = nil
        pendingGesture = nil
        lastGestureTime = -.infinity
        audioLevels = ScreenRecordingAudioLevels()
        finalizationProgress = nil
        pendingTextEntryTask?.cancel()
        pendingTextEntryTask = nil
        pendingTextEntry = nil
        stopTextEntryObservation()

        do {
            let media = try await GuideMediaCaptureSession.make(source: source, preferences: preferences, systemServices: systemServices)
            media.audioLevelHandler = { [weak self] levels in
                self?.audioLevels = levels
            }
            media.interruptionHandler = { [weak self] error in
                self?.handleMediaInterruption(error)
            }
            mediaSession = media
            self.project?.timeline.sourceCoordinateRect = media.capturedDisplayFrame
            try await media.start()
            try eventMonitor.start { [weak self] event, timestamp in
                self?.receive(event, timestamp: timestamp)
            }
            startedAt = Date()
            startedUptime = ProcessInfo.processInfo.systemUptime
            state = .recording
            startTextEntryObservation()
            startGuardrailMonitor()
            startSourceTracking()
        } catch {
            stopGuardrailMonitor()
            stopSourceTracking()
            eventMonitor.stop()
            mediaSession = nil
            self.project = nil
            self.logoImage = nil
            audioLevels = ScreenRecordingAudioLevels()
            state = .idle
            throw error
        }
    }

    func pause() async throws {
        guard state == .recording else { return }
        stopTextEntryObservation()
        flushPendingInteractions(allowRetargeting: false)
        state = .paused
        eventMonitor.stop()
        try await mediaSession?.pause()
        audioLevels = ScreenRecordingAudioLevels()
        synchronizeFinalizedSegments()
        scheduleRecoveryWrite()
    }

    func resume() async throws {
        guard state == .paused else { return }
        let status = systemServices.permissions.currentStatus()
        guard status.hasScreenRecording else {
            throw GuideCaptureInterruptionError.screenRecordingPermissionChanged
        }
        guard status.hasAccessibility, systemServices.accessibility.isProcessTrusted() else {
            throw GuideCaptureInterruptionError.accessibilityPermissionChanged
        }
        try GuideStorageGuardrails.ensureCanContinueCapture(
            temporaryDirectory: systemServices.files.temporaryDirectory
        )
        if (requiresMediaSessionReplacement || mediaSession?.isInterrupted == true),
           let source = project?.source {
            if let mediaSession {
                mediaSession.interruptionHandler = nil
                do {
                    retainedSegments.append(contentsOf: try await mediaSession.stop())
                } catch {
                    retainedSegments.append(contentsOf: mediaSession.completedSegments)
                }
                self.mediaSession = nil
            }
            let replacement = try await GuideMediaCaptureSession.make(
                source: source,
                preferences: preferences,
                systemServices: systemServices
            )
            replacement.audioLevelHandler = { [weak self] levels in self?.audioLevels = levels }
            replacement.interruptionHandler = { [weak self] error in self?.handleMediaInterruption(error) }
            mediaSession = replacement
            if project?.timeline.sourceCoordinateRect == nil {
                project?.timeline.sourceCoordinateRect = replacement.capturedDisplayFrame
            }
            try await replacement.start()
            requiresMediaSessionReplacement = false
        } else {
            try mediaSession?.resume()
        }
        try eventMonitor.start { [weak self] event, timestamp in self?.receive(event, timestamp: timestamp) }
        captureIssue = nil
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
        stepThumbnails[removed.id] = nil
        project.normalizeStepSequence()
        project.modifiedAt = Date()
        self.project = project
        scheduleRecoveryWrite(urgent: true)
    }

    func deleteStep(id: UUID) {
        guard var project, let index = project.steps.firstIndex(where: { $0.id == id }) else { return }
        project.steps.remove(at: index)
        stepImages[id] = nil
        stepThumbnails[id] = nil
        project.normalizeStepSequence()
        project.modifiedAt = Date()
        self.project = project
        scheduleRecoveryWrite(urgent: true)
    }

    func stop() async throws -> EditableGuideDocument? {
        guard state == .recording || state == .paused else { return nil }
        // Give an interaction-triggered app-window switch its bounded frame wait
        // before closing capture. If it cannot complete, omit the queued action
        // rather than pairing it with a frame from the previous window.
        if retargetTask != nil {
            let deadline = ContinuousClock.now + .milliseconds(500)
            while retargetTask != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        state = .finishing
        stopGuardrailMonitor()
        finalizationProgress = GuideFinalizationProgress(
            phase: .stoppingMedia,
            detail: "Stopping capture and closing source media…",
            fraction: nil
        )
        eventMonitor.stop()
        stopTextEntryObservation()
        flushPendingInteractions(allowRetargeting: false)
        stopSourceTracking()
        let segments: [(GuideTimelineSegment, URL)]
        do {
            segments = retainedSegments + (try await mediaSession?.stop() ?? [])
        } catch {
            // Keep the HUD actionable after a finalization failure. From paused, the user can
            // retry Stop, resume into a fresh segment, or discard instead of being stranded in
            // an indefinitely disabled Finishing state.
            state = .paused
            finalizationProgress = nil
            throw error
        }
        mediaSession = nil
        retainedSegments = []
        guard var project else {
            finalizationProgress = nil
            state = .idle
            return nil
        }
        finalizationProgress = GuideFinalizationProgress(
            phase: .preparingDocument,
            detail: "Preparing the editable Guide…",
            fraction: nil
        )
        project.timeline.segments = segments.map(\.0)
        project.timeline.cursorSamples = cursorSamples
        let mediaURLs = Dictionary(uniqueKeysWithValues: segments.map { ($0.0.id, $0.1) })
        finalizationProgress = GuideFinalizationProgress(
            phase: .renderingPreview,
            detail: "Rendering the Guide preview…",
            fraction: nil
        )
        let previewProject = project
        let previewImages = stepImages
        let previewLogo = logoImage
        let preview = await Task.detached(priority: .utility) {
            GuideRenderer.renderPreview(project: previewProject, images: previewImages, logo: previewLogo)
        }.value
        let document = EditableGuideDocument(project: project, stepImages: stepImages, previewImage: preview, logoImage: logoImage, mediaSegmentURLs: mediaURLs)
        if !project.isPrivate {
            finalizationProgress = GuideFinalizationProgress(
                phase: .savingRecovery,
                detail: "Saving the recovery checkpoint…",
                fraction: nil
            )
            if let recoveryTask {
                await recoveryTask.value
            }
            recoveryTask = nil
            pendingRecoveryDocument = nil
            do {
                try await Task.detached(priority: .utility) { [recoveryStore] in
                    try recoveryStore.save(document)
                }.value
                recoveryIssue = nil
            } catch {
                recoveryIssue = "The Guide opened, but its final recovery checkpoint could not be saved: \(error.localizedDescription)"
            }
        }
        self.project = nil
        logoImage = nil
        stepImages = [:]
        stepThumbnails = [:]
        audioLevels = ScreenRecordingAudioLevels()
        startedAt = nil
        startedUptime = nil
        finalizationProgress = GuideFinalizationProgress(
            phase: .complete,
            detail: "Guide ready.",
            fraction: 1
        )
        state = .idle
        return document
    }

    func discard() async {
        guard !isDiscarding else { return }
        isDiscarding = true

        let projectID = project?.id
        eventMonitor.stop()
        stopGuardrailMonitor()
        stopSourceTracking()
        pendingScrollTask?.cancel()
        pendingGestureTask?.cancel()
        pendingGestureTask = nil
        pendingGesture = nil
        pendingTextEntryTask?.cancel()
        pendingTextEntryTask = nil
        pendingTextEntry = nil
        stopTextEntryObservation()
        let outstandingRecoveryTask = recoveryTask
        let discardedMediaSession = mediaSession
        outstandingRecoveryTask?.cancel()
        recoveryTask = nil
        pendingRecoveryDocument = nil
        mediaSession = nil
        retainedSegments = []
        project = nil
        logoImage = nil
        stepImages = [:]
        stepThumbnails = [:]
        audioLevels = ScreenRecordingAudioLevels()
        startedAt = nil
        startedUptime = nil
        finalizationProgress = nil
        state = .idle

        if let outstandingRecoveryTask {
            await outstandingRecoveryTask.value
        }
        await discardedMediaSession?.discard()
        if let projectID { recoveryStore.remove(projectID: projectID) }
        isDiscarding = false
    }

    private func startGuardrailMonitor() {
        stopGuardrailMonitor()
        guardrailTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, state == .recording else { continue }
                let permissionStatus = systemServices.permissions.currentStatus()
                if !permissionStatus.hasScreenRecording {
                    await pauseForIssue(
                        GuideCaptureInterruptionError.screenRecordingPermissionChanged.localizedDescription,
                        replaceMediaSession: true
                    )
                    continue
                }
                if !permissionStatus.hasAccessibility || !systemServices.accessibility.isProcessTrusted() {
                    await pauseForIssue(GuideCaptureInterruptionError.accessibilityPermissionChanged.localizedDescription)
                    continue
                }
                if await displayConfigurationChanged() {
                    await pauseForIssue(
                        "The captured display changed scale, rotation, or bounds. Guide paused so the next segment can use the new display geometry; choose Resume to continue.",
                        replaceMediaSession: true
                    )
                    continue
                }
                do {
                    try GuideStorageGuardrails.ensureCanContinueCapture(
                        temporaryDirectory: systemServices.files.temporaryDirectory
                    )
                } catch {
                    await pauseForIssue((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }

    private func stopGuardrailMonitor() {
        guardrailTask?.cancel()
        guardrailTask = nil
    }

    private func startSourceTracking() {
        stopSourceTracking()
        guard sourceNeedsTracking else { return }
        sourceTrackingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, state == .recording, !isRetargeting else { continue }
                let preferredWindowID: CGWindowID?
                if case .app(let processID, _, _, _) = project?.source {
                    preferredWindowID = captionGenerator.focusedWindowID(forProcessID: processID)
                        ?? mediaSession?.resolvedSource.windowID
                } else {
                    preferredWindowID = mediaSession?.resolvedSource.windowID
                }
                beginRetarget(preferredWindowID: preferredWindowID, pausesOnFailure: false)
            }
        }
    }

    private func stopSourceTracking() {
        sourceTrackingTask?.cancel()
        sourceTrackingTask = nil
        retargetTask?.cancel()
        retargetTask = nil
        activeRetargetID = nil
        isRetargeting = false
        queuedCaptures.removeAll()
        missingSourceChecks = 0
    }

    private var sourceNeedsTracking: Bool {
        guard let source = project?.source else { return false }
        switch source {
        case .window, .app: return true
        case .region, .displays: return false
        }
    }

    private func pauseForIssue(_ message: String, replaceMediaSession: Bool = false) async {
        guard state == .recording else { return }
        requiresMediaSessionReplacement = requiresMediaSessionReplacement || replaceMediaSession
        do {
            try await pause()
        } catch {
            eventMonitor.stop()
            stopTextEntryObservation()
            state = .paused
            synchronizeFinalizedSegments()
            scheduleRecoveryWrite()
        }
        captureIssue = message
    }

    private func displayConfigurationChanged() async -> Bool {
        guard let mediaSession, let source = project?.source,
              let content = try? await systemServices.screenRecordingPlatform.shareableContent(),
              let display = content.displays.first(where: { $0.displayID == mediaSession.captureDisplayID }) else {
            return false
        }
        switch source {
        case .window, .app:
            return false
        case .region, .displays:
            break
        }
        let currentFrame = GuideSourceMediaGeometry.captureFrame(for: source, within: display.frame)
        let currentScale = max(
            systemServices.screens.screen(withDisplayID: display.displayID)?.backingScaleFactor ?? display.scale,
            1
        )
        return !approximatelyEqual(currentFrame, mediaSession.capturedDisplayFrame, tolerance: 1)
            || abs(currentScale - mediaSession.pointPixelScale) > 0.01
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func handleMediaInterruption(_ error: Error) {
        guard state == .recording || state == .starting else { return }
        eventMonitor.stop()
        stopTextEntryObservation()
        flushPendingInteractions(allowRetargeting: false)
        stopSourceTracking()
        requiresMediaSessionReplacement = true
        state = .paused
        audioLevels = ScreenRecordingAudioLevels()
        synchronizeFinalizedSegments()
        scheduleRecoveryWrite()

        let permissions = systemServices.permissions.currentStatus()
        if !permissions.hasScreenRecording {
            captureIssue = GuideCaptureInterruptionError.screenRecordingPermissionChanged.localizedDescription
        } else {
            captureIssue = "Screen capture stopped unexpectedly: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription). Completed steps are preserved; Resume retries the capture."
        }
    }

    private func receive(_ event: GuideObservedEvent, timestamp: CMTime) {
        guard state == .recording else {
            return
        }
        if case .cursorMoved = event.payload {
            guard accepts(event) else { return }
            let cursorSampleRate = min(max(preferences.framesPerSecond, 1), 30)
            if event.timestamp - lastCursorSampleTime >= 1.0 / Double(cursorSampleRate) {
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

    private func flushPendingInteractions(allowRetargeting: Bool) {
        pendingScrollTask?.cancel()
        pendingGestureTask?.cancel()
        pendingTextEntryTask?.cancel()
        pendingScrollTask = nil
        pendingGestureTask = nil
        pendingTextEntryTask = nil

        let scroll = pendingScroll
        let gesture = pendingGesture
        let text = pendingTextEntry
        pendingScroll = nil
        pendingGesture = nil
        pendingTextEntry = nil

        var actions: [(TimeInterval, () -> Void)] = []
        if let scroll {
            actions.append((scroll.event.timestamp, { [weak self] in
                self?.captureStep(
                    for: scroll.event,
                    classified: .scroll(direction: scroll.direction, distance: scroll.distance),
                    timestamp: scroll.timestamp,
                    allowRetargeting: allowRetargeting
                )
            }))
        }
        if let gesture {
            actions.append((gesture.event.timestamp, { [weak self] in
                self?.captureStep(
                    for: gesture.event,
                    classified: .gesture(direction: gesture.direction),
                    timestamp: CMClockGetTime(CMClockGetHostTimeClock()),
                    allowRetargeting: allowRetargeting
                )
            }))
        }
        if let text {
            actions.append((text.event.timestamp, { [weak self] in
                self?.captureStep(
                    for: text.event,
                    classified: .textEntry,
                    timestamp: CMClockGetTime(CMClockGetHostTimeClock()),
                    captionResult: text.caption,
                    allowRetargeting: allowRetargeting
                )
            }))
        }
        actions.sorted { $0.0 < $1.0 }.forEach { $0.1() }
    }

    private func captureStep(
        for event: GuideObservedEvent,
        classified: GuideClassifiedEvent,
        timestamp: CMTime,
        captionResult suppliedCaptionResult: GuideCaptionResult? = nil,
        allowRetargeting: Bool = true
    ) {
        let captionResult = suppliedCaptionResult ?? captionGenerator.immediateCaption(for: classified, at: event.location)
        if allowRetargeting,
           case .app = project?.source,
           let targetWindowID = captionResult.metadata?.windowID,
           targetWindowID != mediaSession?.resolvedSource.windowID {
            enqueueCapture(event: event, classified: classified, timestamp: timestamp, captionResult: captionResult)
            beginRetarget(preferredWindowID: targetWindowID)
            return
        }
        if allowRetargeting, isRetargeting {
            enqueueCapture(event: event, classified: classified, timestamp: timestamp, captionResult: captionResult)
            return
        }
        captureStepNow(
            for: event,
            classified: classified,
            timestamp: timestamp,
            captionResult: captionResult
        )
    }

    private func captureStepNow(
        for event: GuideObservedEvent,
        classified: GuideClassifiedEvent,
        timestamp: CMTime,
        captionResult: GuideCaptionResult
    ) {
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
                source: mediaSession.source,
                capturedDisplayFrame: mediaSession.capturedDisplayFrame,
                transientFrame: captionResult.metadata?.frame
              ) else {
            return
        }
        let point = sourcePixelPoint(event.location, sourceRect: composition.sourceRect, image: composition.image)
        let imageSize = CGSize(width: composition.image.width, height: composition.image.height)
        let targetRect = captionResult.metadata?.frame.map {
            sourcePixelRect($0, sourceRect: composition.sourceRect, image: composition.image)
        }
        // Marker chrome is drawn at a stable presentation size even when a
        // Retina capture is scaled down for a Guide card. Convert that visual
        // size back into source pixels before choosing a collision-free tail.
        let presentationScale = max(min((1_440 - 144) / imageSize.width, 1), 0.001)
        let tail = GuideMarkerGeometry.automaticTail(
            for: point,
            avoiding: targetRect,
            in: imageSize,
            preferredLength: CGFloat(project.theme.markerLength) / presentationScale,
            badgeRadius: GuideMarkerGeometry.badgeRadius / presentationScale,
            targetClearance: GuideMarkerGeometry.targetOuterRadius / presentationScale
        )
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
        stepThumbnails[step.id] = GuideImageMemory.thumbnail(of: composition.image)
        optimizeStepImageInBackground(stepID: step.id, image: composition.image)
        scheduleRecoveryWrite()
        refineCaptionIfNeeded(stepID: step.id, image: composition.image)
    }

    private func enqueueCapture(
        event: GuideObservedEvent,
        classified: GuideClassifiedEvent,
        timestamp: CMTime,
        captionResult: GuideCaptionResult
    ) {
        queuedCaptures.append(QueuedCapture(
            event: event,
            classified: classified,
            timestamp: timestamp,
            captionResult: captionResult
        ))
        let newest = queuedCaptures.last?.event.timestamp ?? event.timestamp
        let exceedsTimeWindow = queuedCaptures.first.map { newest - $0.event.timestamp > 2 } ?? false
        if queuedCaptures.count > 32 || exceedsTimeWindow {
            queuedCaptures.removeAll()
            Task { @MainActor [weak self] in
                await self?.pauseForIssue(
                    "Guide paused because the captured app changed windows faster than capture could follow for two seconds. Completed steps are preserved."
                )
            }
        }
    }

    private func beginRetarget(preferredWindowID: CGWindowID?, pausesOnFailure: Bool = true) {
        guard retargetTask == nil, !isRetargeting else { return }
        let retargetID = UUID()
        activeRetargetID = retargetID
        isRetargeting = true
        retargetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshResolvedSource(
                preferredWindowID: preferredWindowID,
                pausesOnFailure: pausesOnFailure,
                retargetID: retargetID
            )
            guard activeRetargetID == retargetID else { return }
            retargetTask = nil
            activeRetargetID = nil
            isRetargeting = false
        }
    }

    private func refreshResolvedSource(
        preferredWindowID: CGWindowID?,
        pausesOnFailure: Bool,
        retargetID: UUID
    ) async {
        guard state == .recording,
              activeRetargetID == retargetID,
              let project,
              let mediaSession else { return }
        do {
            let content = try await systemServices.screenRecordingPlatform.shareableContent()
            let interactionWindowID = queuedCaptures.last?.captionResult.metadata?.windowID
            let resolved = try GuideMediaCaptureSession.resolve(
                source: project.source,
                content: content,
                screens: systemServices.screens,
                preferredWindowID: interactionWindowID ?? preferredWindowID,
                previousFrame: mediaSession.resolvedSource.captureFrame,
                includeMenuBar: preferences.menuBarIncludedForDisplays
            )
            guard state == .recording,
                  activeRetargetID == retargetID,
                  self.mediaSession === mediaSession else { return }
            missingSourceChecks = 0
            if resolvedNeedsRetarget(resolved, current: mediaSession.resolvedSource) {
                flushPendingInteractions(allowRetargeting: false)
                try await mediaSession.retarget(to: resolved, preferences: preferences)
                guard state == .recording,
                      activeRetargetID == retargetID,
                      self.mediaSession === mediaSession else { return }
                synchronizeFinalizedSegments()
                scheduleRecoveryWrite()
            }
            if case .app = project.source,
               let newestInteractionWindowID = queuedCaptures.last?.captionResult.metadata?.windowID,
               newestInteractionWindowID != mediaSession.resolvedSource.windowID {
                await refreshResolvedSource(
                    preferredWindowID: newestInteractionWindowID,
                    pausesOnFailure: true,
                    retargetID: retargetID
                )
                return
            }
            await replayQueuedCaptures()
        } catch is CancellationError {
            return
        } catch {
            guard state == .recording, activeRetargetID == retargetID else { return }
            if error is GuideSourceResolutionError {
                missingSourceChecks += 1
            } else {
                missingSourceChecks = 2
            }
            if pausesOnFailure || missingSourceChecks >= 2 {
                queuedCaptures.removeAll()
                await pauseForIssue(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    replaceMediaSession: true
                )
            }
        }
    }

    private func resolvedNeedsRetarget(
        _ candidate: GuideResolvedCaptureSource,
        current: GuideResolvedCaptureSource
    ) -> Bool {
        candidate.windowID != current.windowID
            || candidate.displayID != current.displayID
            || abs(candidate.pointPixelScale - current.pointPixelScale) > 0.01
            || !approximatelyEqual(candidate.captureFrame, current.captureFrame, tolerance: 2)
            || candidate.target.source != current.target.source
    }

    private func replayQueuedCaptures() async {
        guard state == .recording, !queuedCaptures.isEmpty, let mediaSession else { return }
        let deadline = ContinuousClock.now + .milliseconds(500)
        while mediaSession.newestFrame(before: .positiveInfinity) == nil,
              ContinuousClock.now < deadline,
              !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard mediaSession.newestFrame(before: .positiveInfinity) != nil else {
            queuedCaptures.removeAll()
            await pauseForIssue(
                "Guide paused because the updated capture source did not produce a frame. Completed steps are preserved.",
                replaceMediaSession: true
            )
            return
        }
        let captures = queuedCaptures.sorted { $0.event.timestamp < $1.event.timestamp }
        queuedCaptures.removeAll()
        for capture in captures {
            captureStepNow(
                for: capture.event,
                classified: capture.classified,
                timestamp: .positiveInfinity,
                captionResult: capture.captionResult
            )
        }
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

    private func optimizeStepImageInBackground(stepID: UUID, image: CGImage) {
        Task { @MainActor [weak self] in
            let compressed = await Task.detached(priority: .utility) {
                GuideImageMemory.compressedCopy(of: image)
            }.value
            guard let self, project?.steps.contains(where: { $0.id == stepID }) == true,
                  let compressed else { return }
            stepImages[stepID] = compressed
        }
    }

    private func synchronizeFinalizedSegments() {
        guard var project, let mediaSession else { return }
        project.timeline.segments = (retainedSegments + mediaSession.completedSegments).map(\.0)
        self.project = project
    }

    private func scheduleRecoveryWrite(urgent: Bool = false) {
        guard let project, !project.isPrivate, !project.steps.isEmpty else { return }
        let completedSegments = retainedSegments + (mediaSession?.completedSegments ?? [])
        let mediaURLs = Dictionary(uniqueKeysWithValues: completedSegments.map { ($0.0.id, $0.1) })
        let document = EditableGuideDocument(
            project: project,
            stepImages: stepImages,
            // Recovery does not need a contact-sheet preview while capture is
            // active. Omitting it avoids re-rendering every prior step.
            previewImage: nil,
            logoImage: logoImage,
            mediaSegmentURLs: mediaURLs
        )
        pendingRecoveryDocument = document
        recoveryRevision += 1
        pendingRecoveryWriteIsUrgent = pendingRecoveryWriteIsUrgent || urgent
        if urgent, recoveryTask != nil, !isRecoveryWriteInFlight {
            recoveryTask?.cancel()
            recoveryTask = nil
        }
        guard recoveryTask == nil else { return }
        recoveryTask = Task { @MainActor [weak self, recoveryStore] in
            while !Task.isCancelled {
                guard let self else { return }
                let writeIsUrgent = pendingRecoveryWriteIsUrgent
                pendingRecoveryWriteIsUrgent = false
                let elapsed = Date().timeIntervalSince(lastRecoveryWriteAt)
                let delay = writeIsUrgent ? 0 : max(0.2, 2.0 - elapsed)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let checkpoint = pendingRecoveryDocument else {
                    recoveryTask = nil
                    return
                }
                let checkpointRevision = recoveryRevision
                pendingRecoveryDocument = nil
                isRecoveryWriteInFlight = true
                do {
                    try await Task.detached(priority: .utility) {
                        try recoveryStore.save(checkpoint)
                    }.value
                    isRecoveryWriteInFlight = false
                    guard !Task.isCancelled else { return }
                    lastRecoveryWriteAt = Date()
                    if checkpointRevision == recoveryRevision {
                        recoveryIssue = nil
                    }
                } catch is CancellationError {
                    isRecoveryWriteInFlight = false
                    return
                } catch {
                    isRecoveryWriteInFlight = false
                    guard !Task.isCancelled else { return }
                    recoveryIssue = "Guide recovery is waiting for storage: \(error.localizedDescription)"
                }
                if pendingRecoveryDocument == nil {
                    recoveryTask = nil
                    return
                }
            }
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
        CGPoint(
            x: min(max((point.x - sourceRect.minX) / sourceRect.width * CGFloat(image.width), 0), CGFloat(image.width)),
            y: min(max((point.y - sourceRect.minY) / sourceRect.height * CGFloat(image.height), 0), CGFloat(image.height))
        )
    }

    private func sourcePixelRect(_ rect: CGRect, sourceRect: CGRect, image: CGImage) -> CGRect {
        let origin = sourcePixelPoint(rect.origin, sourceRect: sourceRect, image: image)
        return CGRect(
            origin: origin,
            size: CGSize(
                width: rect.width / sourceRect.width * CGFloat(image.width),
                height: rect.height / sourceRect.height * CGFloat(image.height)
            )
        ).standardized.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}
