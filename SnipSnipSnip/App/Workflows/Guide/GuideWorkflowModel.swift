import AppKit
import Combine
import Foundation
import ImageIO

@MainActor
struct GuideWorkflowDependencies {
    let capabilities: AppCapabilitySnapshot
    let systemServices: AppSystemServices
    let appWindowPresenter: any AppWindowPresenting
    let permissions: any PermissionGatekeeping
    let lifecycle: any WorkflowLifecyclePresenting
    let capture: any GuideCaptureWorkflowPort
    let video: any GuideVideoWorkflowPort
}

enum GuideWorkflowOutput {
    case guideCompleted(EditableGuideDocument, exportImmediately: Bool)
    case presentError(String)
    case requestMainWindowPresentation
}

private enum GuideTargetSelectionResult {
    case source(GuideCaptureSource)
    case chooseFromList(GuideTargetPickerKind)
    case cancelled
}

nonisolated struct GuideExitContext: Equatable, Sendable {
    let isPrivate: Bool
    let hasSteps: Bool
}

nonisolated enum GuideExitAction: Equatable, Sendable {
    case finalizeForRecovery
    case openAndStay
    case discard
}

nonisolated enum GuideExitResult: Equatable, Sendable {
    case readyToExit
    case stayedOpen
}

@MainActor
final class GuideWorkflowModel: ObservableObject {
    static let onboardingVersion = 1

    let dependencies: GuideWorkflowDependencies
    let captureCoordinator: GuideCaptureCoordinator
    weak var outputSink: (any WorkflowOutputSink)?
    private let preferenceStore: GuidePreferenceStore
    private let recoveryStore: GuideRecoveryStore
    private var guideAudioOptionsTask: Task<Void, Never>?
    private var activeFinishTask: Task<EditableGuideDocument, Error>?
    private var captureStateObservation: AnyCancellable?
    private var captureDiscardObservation: AnyCancellable?

    @Published var isShowingQuickStart = false
    @Published var capturePreferences: GuideCapturePreferences { didSet { preferenceStore.saveCapturePreferences(capturePreferences) } }
    @Published var exportSettings: GuideExportSettings { didSet { preferenceStore.saveExportSettings(exportSettings) } }
    @Published var theme: GuideTheme { didSet { preferenceStore.saveTheme(theme) } }
    @Published private(set) var defaultLogoImage: CGImage?
    @Published private(set) var savedThemes: [GuideTheme]
    @Published var selectedWindowID: CGWindowID?
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedSourceKind = "window"
    @Published var targetPickerKind: GuideTargetPickerKind?
    @Published private(set) var targetWindows: [CaptureWindowSummary] = []
    @Published var storageEstimateMinutes = 30
    @Published var isShowingFirstUseSetup: Bool
    @Published var hasRecoverableGuide = false

    init(
        dependencies: GuideWorkflowDependencies,
        preferenceStore: GuidePreferenceStore,
        recoveryStore: GuideRecoveryStore = GuideRecoveryStore()
    ) {
        self.dependencies = dependencies
        self.preferenceStore = preferenceStore
        self.recoveryStore = recoveryStore
        self.capturePreferences = preferenceStore.loadCapturePreferences()
        self.exportSettings = preferenceStore.loadExportSettings()
        self.theme = preferenceStore.loadTheme()
        self.defaultLogoImage = Self.decodeLogo(preferenceStore.loadBrandLogoData())
        self.savedThemes = preferenceStore.loadSavedThemes()
        self.captureCoordinator = GuideCaptureCoordinator(systemServices: dependencies.systemServices, recoveryStore: recoveryStore)
        self.isShowingFirstUseSetup = preferenceStore.loadOnboardingVersion() < Self.onboardingVersion
        self.hasRecoverableGuide = recoveryStore.newestRecoveryURL() != nil
        self.captureStateObservation = captureCoordinator.$state
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
        self.captureDiscardObservation = captureCoordinator.$isDiscarding
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var isActive: Bool { captureCoordinator.state != .idle || captureCoordinator.isDiscarding }
    var isFinishing: Bool { captureCoordinator.state == .finishing }
    var isDiscarding: Bool { captureCoordinator.isDiscarding }
    var availableWindows: [CaptureWindowSummary] { dependencies.capture.availableWindows }
    var stepCount: Int { captureCoordinator.project?.steps.count ?? 0 }
    var exitContext: GuideExitContext? {
        guard isActive, let project = captureCoordinator.project else { return nil }
        return GuideExitContext(isPrivate: project.isPrivate, hasSteps: !project.steps.isEmpty)
    }

    func presentQuickStart() {
        guard dependencies.capabilities.isEnabled(.guide) else { return }
        if isActive { stopGuide(); return }
        guard !dependencies.capture.isWorking,
              !dependencies.video.isRecording,
              !dependencies.capture.isConnectedDeviceSessionActive else {
            outputSink?.handle(GuideWorkflowOutput.presentError("Finish the active capture or recording before starting Guide."))
            return
        }
        // Starting another Guide must not silently reuse a previous display. The
        // setup sheet is where people can switch between Window, App, Region, and
        // Display; remembering the previous choice should set a sensible default,
        // not hide those choices.
        targetPickerKind = nil
        if !isShowingQuickStart { restoreLastSourceSelection() }
        isShowingQuickStart = true
    }

    func completeFirstUseSetup() {
        preferenceStore.saveOnboardingVersion(Self.onboardingVersion)
        isShowingFirstUseSetup = false
    }

    func saveTheme(_ value: GuideTheme) {
        var theme = value
        let trimmedName = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        theme.name = trimmedName.isEmpty ? "My Guide Theme" : trimmedName
        if let index = savedThemes.firstIndex(where: { $0.id == theme.id }) { savedThemes[index] = theme }
        else { savedThemes.append(theme) }
        preferenceStore.saveSavedThemes(savedThemes)
    }

    func applySavedTheme(_ id: UUID) {
        guard let saved = savedThemes.first(where: { $0.id == id }) else { return }
        theme = saved
    }

    func deleteSavedTheme(_ id: UUID) {
        savedThemes.removeAll { $0.id == id }
        preferenceStore.saveSavedThemes(savedThemes)
    }

    func setDefaultLogo(_ image: CGImage?) {
        let normalized = image.flatMap { GuideImageMemory.thumbnail(of: $0, maximumPixelDimension: 1_024) }
        defaultLogoImage = normalized
        preferenceStore.saveBrandLogoData(normalized.flatMap { try? ImageExporter.pngData(for: $0) })
        var updatedTheme = theme
        updatedTheme.logoAsset = normalized == nil ? nil : "brand/logo.png"
        theme = updatedTheme
    }

    func setDefaultBranding(theme: GuideTheme, logo: CGImage?) {
        self.theme = theme
        setDefaultLogo(logo)
    }

    func beginSelectedSourceSelection() {
        guard dependencies.permissions.preflight(
            [.screenRecording, .accessibility],
            featureName: "Guide"
        ).isGranted else {
            return
        }

        targetPickerKind = nil
        isShowingQuickStart = false
        let sourceKind = selectedSourceKind
        Task { @MainActor [weak self] in
            await self?.selectTargetOnScreen(sourceKind: sourceKind)
        }
    }

    func selectTarget(_ window: CaptureWindowSummary, as kind: GuideTargetPickerKind) {
        targetPickerKind = nil
        selectedSourceKind = kind.rawValue
        selectedWindowID = window.id
        start(source: kind.source(for: window))
    }

    func pickTargetOnScreen(as kind: GuideTargetPickerKind) {
        guard dependencies.permissions.preflight(
            [.screenRecording, .accessibility],
            featureName: "Guide"
        ).isGranted else {
            returnToQuickStart()
            return
        }

        targetPickerKind = nil
        selectedSourceKind = kind.rawValue
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 180_000_000)
            await selectTargetOnScreen(sourceKind: kind.rawValue)
        }
    }

    func cancelTargetSelection() {
        returnToQuickStart()
    }

    func start(source: GuideCaptureSource) {
        guard !isActive else { return }
        guard dependencies.permissions.preflight(
            [.screenRecording, .accessibility],
            featureName: "Guide"
        ).isGranted else {
            returnToQuickStart()
            return
        }
        isShowingQuickStart = false
        targetPickerKind = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await startImmediately(source: source, privateCapture: dependencies.capture.privateCaptureEnabled)
            } catch {
                returnToQuickStart()
                outputSink?.handle(GuideWorkflowOutput.presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    func togglePauseResume() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if captureCoordinator.state == .paused { try await captureCoordinator.resume() }
                else { try await captureCoordinator.pause() }
            } catch { outputSink?.handle(GuideWorkflowOutput.presentError(error.localizedDescription)) }
        }
    }

    func addManualStep() { captureCoordinator.addManualStep() }
    func undoLastStep() { captureCoordinator.undoLastStep() }
    func deleteStep(id: UUID) { captureCoordinator.deleteStep(id: id) }

    func setGuideCapturesSystemAudio(_ enabled: Bool) {
        setGuideAudioOptions(capturesSystemAudio: enabled, capturesMicrophone: capturePreferences.capturesMicrophone)
    }

    func setGuideCapturesMicrophone(_ enabled: Bool) {
        setGuideAudioOptions(capturesSystemAudio: capturePreferences.capturesSystemAudio, capturesMicrophone: enabled)
    }

    func stopGuide() {
        stopGuide(exportImmediately: false)
    }

    func stopGuide(exportImmediately: Bool) {
        guard !isFinishing else { return }
        guard stepCount > 0 else {
            // Stop must always end the active workflow. There is no editable
            // document to open for an empty Guide, so discard its live capture.
            discardGuide()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await finishGuideCapture(exportImmediately: exportImmediately)
            } catch { outputSink?.handle(GuideWorkflowOutput.presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)) }
        }
    }

    func exportAndStartNewGuide() {
        guard let source = captureCoordinator.project?.source, stepCount > 0 else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await finishGuideCapture(exportImmediately: true)
                try await startImmediately(source: source, privateCapture: dependencies.capture.privateCaptureEnabled)
            } catch {
                outputSink?.handle(GuideWorkflowOutput.presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    func discardGuide() {
        guard !captureCoordinator.isDiscarding else { return }
        guideAudioOptionsTask?.cancel()
        guideAudioOptionsTask = nil
        Task { @MainActor [weak self] in
            await self?.captureCoordinator.discard()
        }
    }

    private func setGuideAudioOptions(capturesSystemAudio: Bool, capturesMicrophone: Bool) {
        guard captureCoordinator.state == .recording else { return }
        let previousPreferences = capturePreferences
        capturePreferences.capturesSystemAudio = capturesSystemAudio
        capturePreferences.capturesMicrophone = capturesMicrophone
        guideAudioOptionsTask?.cancel()
        guideAudioOptionsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await captureCoordinator.updateAudioOptions(
                    capturesSystemAudio: capturesSystemAudio,
                    capturesMicrophone: capturesMicrophone
                )
            } catch {
                guard !Task.isCancelled else { return }
                capturePreferences = previousPreferences
                outputSink?.handle(GuideWorkflowOutput.presentError(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ))
            }
        }
    }

    func prepareForApplicationExit(_ action: GuideExitAction) async -> GuideExitResult {
        guard isActive else { return .readyToExit }
        if action == .discard {
            await captureCoordinator.discard()
            return .readyToExit
        }
        if stepCount == 0 {
            await captureCoordinator.discard()
            return .readyToExit
        }
        do {
            let wasAlreadyFinishing = activeFinishTask != nil
            let document: EditableGuideDocument
            if let activeFinishTask {
                document = try await activeFinishTask.value
            } else {
                guard let stoppedDocument = try await captureCoordinator.stop() else { return .readyToExit }
                document = stoppedDocument
            }
            if document.project.isPrivate || action == .openAndStay {
                if !wasAlreadyFinishing {
                    outputSink?.handle(GuideWorkflowOutput.guideCompleted(document, exportImmediately: false))
                    outputSink?.handle(GuideWorkflowOutput.requestMainWindowPresentation)
                }
                if document.project.isPrivate {
                    outputSink?.handle(GuideWorkflowOutput.presentError(
                        "Private Guides are not written to recovery. The Guide is open so you can save or export it."
                    ))
                }
                return .stayedOpen
            }
            if let issue = captureCoordinator.recoveryIssue {
                if !wasAlreadyFinishing {
                    outputSink?.handle(GuideWorkflowOutput.guideCompleted(document, exportImmediately: false))
                    outputSink?.handle(GuideWorkflowOutput.requestMainWindowPresentation)
                }
                outputSink?.handle(GuideWorkflowOutput.presentError(issue))
                return .stayedOpen
            }
            return .readyToExit
        } catch {
            outputSink?.handle(GuideWorkflowOutput.presentError(
                "Guide could not be finalized, so the app stayed open: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            ))
            return .stayedOpen
        }
    }

    func prepareForConflictingAction(named action: String) async -> Bool {
        guard isActive else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop the active Guide?"
        alert.informativeText = "Guide must stop before \(action). Completed steps and source media will be finalized and kept for recovery."
        alert.addButton(withTitle: "Stop & Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if stepCount == 0 { await captureCoordinator.discard() }
        else {
            do {
                _ = try await captureCoordinator.stop()
            } catch {
                outputSink?.handle(GuideWorkflowOutput.presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                return false
            }
        }
        return true
    }

    func recoverLatestGuide() {
        do {
            guard let document = try recoveryStore.loadNewest() else { return }
            isShowingQuickStart = false
            outputSink?.handle(GuideWorkflowOutput.guideCompleted(document, exportImmediately: false))
            outputSink?.handle(GuideWorkflowOutput.requestMainWindowPresentation)
        } catch {
            outputSink?.handle(GuideWorkflowOutput.presentError("The recovered Guide could not be opened: \(error.localizedDescription)"))
        }
    }

    private func restoreLastSourceSelection() {
        guard let source = preferenceStore.loadLastSource() else { return }
        switch source {
        case .window(let id, _, _, _):
            selectedSourceKind = "window"
            selectedWindowID = id
        case .app(let processID, _, _, _):
            selectedSourceKind = "app"
            selectedWindowID = availableWindows.first(where: { $0.ownerPID == processID })?.id
        case .region:
            selectedSourceKind = "region"
        case .displays(.selected(let identifiers)):
            selectedSourceKind = "display"
            selectedDisplayID = identifiers.first
        case .displays(.current), .displays(.all):
            selectedSourceKind = "display"
        }
    }

    private func selectTargetOnScreen(sourceKind: String) async {
        let hiddenWindow = dependencies.appWindowPresenter.hideAppWindowIfNeeded()
        try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)

        let result: GuideTargetSelectionResult
        do {
            result = try await targetSelectionResult(for: sourceKind)
        } catch {
            dependencies.appWindowPresenter.restoreAppWindowIfNeeded(hiddenWindow)
            returnToQuickStart()
            outputSink?.handle(GuideWorkflowOutput.presentError(error.localizedDescription))
            return
        }

        dependencies.appWindowPresenter.restoreAppWindowIfNeeded(hiddenWindow)
        await Task.yield()

        switch result {
        case .source(let source):
            start(source: source)
        case .chooseFromList(let kind):
            targetPickerKind = kind
        case .cancelled:
            returnToQuickStart()
        }
    }

    private func targetSelectionResult(for sourceKind: String) async throws -> GuideTargetSelectionResult {
        let selection = try await dependencies.capture.videoWindowSelectionSnapshot(fallbackWindows: [])
        targetWindows = mergedTargetWindows(selection.windows)

        switch sourceKind {
        case "region":
            let session = RegionSelectionSession(
                snapshot: selection.snapshot,
                windows: targetWindows,
                preferences: dependencies.capture.regionCapturePreferences,
                constraint: .singleDisplay,
                livePreviewCapturePlatform: dependencies.systemServices.screenCapturePlatform
            )
            guard let result = await session.begin() else {
                return .cancelled
            }
            switch result {
            case .region(let rect, _):
                return .source(.region(rect))
            case .window(let window):
                selectedSourceKind = GuideTargetPickerKind.window.rawValue
                selectedWindowID = window.id
                return .source(GuideTargetPickerKind.window.source(for: window))
            }

        case "window", "app":
            let kind = GuideTargetPickerKind(rawValue: sourceKind) ?? .window
            let session = WindowSelectionSession(
                snapshot: selection.snapshot,
                windows: targetWindows,
                capabilities: dependencies.capabilities,
                accessibility: dependencies.systemServices.accessibility,
                screens: dependencies.systemServices.screens,
                prompt: windowSelectionPrompt(for: kind)
            )
            switch await session.beginOutcome() {
            case .window(let window):
                selectedWindowID = window.id
                return .source(kind.source(for: window))
            case .chooseFromList:
                return .chooseFromList(kind)
            case .cancelled:
                return .cancelled
            }

        default:
            let displays = selection.snapshot.displays
            guard !displays.isEmpty else {
                throw ScreenCaptureError.noDisplays
            }

            let displayID: CGDirectDisplayID?
            if displays.count == 1 {
                displayID = displays[0].displayID
            } else {
                displayID = await DisplaySelectionSession(displays: displays).begin()
            }

            guard let displayID else {
                return .cancelled
            }
            selectedDisplayID = displayID
            return .source(.displays(.selected([displayID])))
        }
    }

    private func windowSelectionPrompt(for kind: GuideTargetPickerKind) -> WindowSelectionPrompt {
        switch kind {
        case .window:
            WindowSelectionPrompt(
                instructionText: "Hover a window, then click to start the Guide. Esc returns to setup.",
                listButtonTitle: "Choose from List…",
                windowLabel: \.displayTitle
            )
        case .app:
            WindowSelectionPrompt(
                instructionText: "Hover any window from an app, then click to follow that app. Esc returns to setup.",
                listButtonTitle: "Choose from List…",
                windowLabel: \.ownerName
            )
        }
    }

    private func mergedTargetWindows(_ windows: [CaptureWindowSummary]) -> [CaptureWindowSummary] {
        var cachedWindows = Dictionary(uniqueKeysWithValues: availableWindows.map { ($0.id, $0) })
        targetWindows.forEach { cachedWindows[$0.id] = $0 }
        return windows.map { window in
            CaptureWindowSummary(
                id: window.id,
                ownerName: window.ownerName,
                ownerPID: window.ownerPID,
                title: window.title,
                frame: window.frame,
                layer: window.layer,
                focusRank: window.focusRank,
                thumbnail: window.thumbnail ?? cachedWindows[window.id]?.thumbnail
            )
        }
    }

    private func returnToQuickStart() {
        targetPickerKind = nil
        isShowingQuickStart = true
    }

    private func startImmediately(source: GuideCaptureSource, privateCapture: Bool) async throws {
        isShowingQuickStart = false
        try await captureCoordinator.start(
            source: source,
            preferences: capturePreferences,
            exportSettings: exportSettings,
            theme: theme,
            logoImage: defaultLogoImage,
            privateCapture: privateCapture,
            guideShortcutKeyCode: dependencies.capture.guideHotKeyCode
        )
        preferenceStore.saveLastSource(source)
        dependencies.lifecycle.updateWorkingMessage("Guide • 0 steps")
    }

    private static func decodeLogo(_ data: Data?) -> CGImage? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary)
    }

    @discardableResult
    private func finishGuideCapture(exportImmediately: Bool = false) async throws -> EditableGuideDocument {
        if let activeFinishTask {
            return try await activeFinishTask.value
        }
        let task = Task { @MainActor [weak self] () throws -> EditableGuideDocument in
            guard let self,
                  let document = try await captureCoordinator.stop() else {
                throw AutomationExecutionError(code: .noActiveGuide, message: "There is no active Guide.")
            }
            guard !document.project.steps.isEmpty else {
                throw AutomationExecutionError(code: .guideHasNoSteps, message: "The Guide has no captured steps.")
            }
            outputSink?.handle(GuideWorkflowOutput.guideCompleted(document, exportImmediately: exportImmediately))
            outputSink?.handle(GuideWorkflowOutput.requestMainWindowPresentation)
            if let recoveryIssue = captureCoordinator.recoveryIssue {
                outputSink?.handle(GuideWorkflowOutput.presentError(recoveryIssue))
            }
            return document
        }
        activeFinishTask = task
        defer { activeFinishTask = nil }
        return try await task.value
    }
}

@MainActor
extension GuideWorkflowModel: GuideAutomationPort {
    func guideAutomation(_ command: GuideAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope {
        do {
            switch command {
            case .start(let target):
                guard !isActive else {
                    return .failure(requestID: request.id, code: .guideAlreadyActive, message: "A Guide is already active.")
                }
                guard !dependencies.capture.isWorking, !dependencies.video.isRecording, !dependencies.capture.isConnectedDeviceSessionActive else {
                    return .failure(requestID: request.id, code: .busy, message: "Finish the active capture or recording before starting Guide.")
                }
                guard dependencies.permissions.preflight([.screenRecording, .accessibility], featureName: "Guide").isGranted else {
                    return .failure(requestID: request.id, code: .permissionDenied, message: "Guide requires Screen Recording and Accessibility access.")
                }
                let source: GuideCaptureSource
                switch target {
                case .window:
                    guard let window = availableWindows.first else { return .failure(requestID: request.id, code: .targetUnavailable, message: "No capturable window is available.") }
                    source = .window(id: window.id, ownerPID: window.ownerPID, name: window.displayTitle, frame: window.frame)
                case .app:
                    guard let window = availableWindows.first else { return .failure(requestID: request.id, code: .targetUnavailable, message: "No capturable app is available.") }
                    source = .app(processID: window.ownerPID, bundleIdentifier: nil, name: window.ownerName, initialFrame: window.frame)
                case .display:
                    source = .displays(.current)
                case .region:
                    selectedSourceKind = "region"
                    isShowingQuickStart = true
                    return .success(
                        requestID: request.id,
                        payload: .guide(AutomationGuideSummary(state: "selectionRequired", stepCount: 0, source: "region", sourceVideoEnabled: capturePreferences.sourceVideoEnabled)),
                        outputs: [.init(kind: .acceptedInteractiveWorkflow)]
                    )
                }
                try await startImmediately(source: source, privateCapture: request.privacy.privateCapture || dependencies.capture.privateCaptureEnabled)
            case .pause:
                guard captureCoordinator.state == .recording else { return .failure(requestID: request.id, code: .noActiveGuide, message: "There is no recording Guide to pause.") }
                try await captureCoordinator.pause()
            case .resume:
                guard captureCoordinator.state == .paused else { return .failure(requestID: request.id, code: .noActiveGuide, message: "There is no paused Guide to resume.") }
                try await captureCoordinator.resume()
            case .addStep:
                guard captureCoordinator.state == .recording else { return .failure(requestID: request.id, code: .noActiveGuide, message: "There is no active Guide.") }
                captureCoordinator.addManualStep()
            case .stop:
                _ = try await finishGuideCapture()
            case .export:
                return .failure(requestID: request.id, code: .internalError, message: "Guide export routing is unavailable.")
            }
            return .success(
                requestID: request.id,
                payload: .guide(AutomationGuideSummary(state: captureCoordinator.state.rawValue, stepCount: stepCount, source: selectedSourceKind, sourceVideoEnabled: capturePreferences.sourceVideoEnabled)),
                outputs: [.init(kind: .none)]
            )
        } catch let error as AutomationExecutionError {
            return .failure(requestID: request.id, code: error.code, message: error.message)
        } catch {
            return .failure(requestID: request.id, code: .guideFinalizationFailed, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
