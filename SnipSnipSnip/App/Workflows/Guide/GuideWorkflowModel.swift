import AppKit
import Combine
import Foundation

@MainActor
struct GuideWorkflowDependencies {
    let capabilities: AppCapabilitySnapshot
    let systemServices: AppSystemServices
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

@MainActor
final class GuideWorkflowModel: ObservableObject {
    static let onboardingVersion = 1

    let dependencies: GuideWorkflowDependencies
    let captureCoordinator: GuideCaptureCoordinator
    weak var outputSink: (any WorkflowOutputSink)?
    private let preferenceStore: GuidePreferenceStore
    private let recoveryStore: GuideRecoveryStore
    private var guideAudioOptionsTask: Task<Void, Never>?

    @Published var isShowingQuickStart = false
    @Published var capturePreferences: GuideCapturePreferences { didSet { preferenceStore.saveCapturePreferences(capturePreferences) } }
    @Published var exportSettings: GuideExportSettings { didSet { preferenceStore.saveExportSettings(exportSettings) } }
    @Published var theme: GuideTheme { didSet { preferenceStore.saveTheme(theme) } }
    @Published private(set) var savedThemes: [GuideTheme]
    @Published var selectedWindowID: CGWindowID?
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedSourceKind = "window"
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
        self.savedThemes = preferenceStore.loadSavedThemes()
        self.captureCoordinator = GuideCaptureCoordinator(systemServices: dependencies.systemServices, recoveryStore: recoveryStore)
        self.isShowingFirstUseSetup = preferenceStore.loadOnboardingVersion() < Self.onboardingVersion
        self.hasRecoverableGuide = recoveryStore.newestRecoveryURL() != nil
    }

    var isActive: Bool { captureCoordinator.state != .idle }
    var isFinishing: Bool { captureCoordinator.state == .finishing }
    var availableWindows: [CaptureWindowSummary] { dependencies.capture.availableWindows }
    var stepCount: Int { captureCoordinator.project?.steps.count ?? 0 }

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

    func startSelectedSource() {
        switch selectedSourceKind {
        case "window":
            guard let window = selectedWindow else { return }
            start(source: .window(id: window.id, ownerPID: window.ownerPID, name: window.displayTitle, frame: window.frame))
        case "app":
            guard let window = selectedWindow else { return }
            start(source: .app(processID: window.ownerPID, bundleIdentifier: nil, name: window.ownerName, initialFrame: window.frame))
        case "region": selectAndStartRegion()
        default: startSelectedDisplay()
        }
    }

    func start(source: GuideCaptureSource) {
        guard !isActive,
              dependencies.permissions.preflight([.screenRecording, .accessibility], featureName: "Guide").isGranted else { return }
        isShowingQuickStart = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await startImmediately(source: source, privateCapture: dependencies.capture.privateCaptureEnabled)
            } catch {
                outputSink?.handle(GuideWorkflowOutput.presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    func togglePauseResume() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if captureCoordinator.state == .paused { try captureCoordinator.resume() }
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

    func finalizeForApplicationExit() async {
        guard isActive else { return }
        if stepCount == 0 { await captureCoordinator.discard() }
        else { _ = try? await captureCoordinator.stop() }
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

    private var selectedWindow: CaptureWindowSummary? {
        if let selectedWindowID, let match = availableWindows.first(where: { $0.id == selectedWindowID }) { return match }
        return availableWindows.first
    }

    private func startSelectedDisplay() {
        if let selectedDisplayID,
           dependencies.systemServices.screens.screen(withDisplayID: selectedDisplayID) != nil {
            start(source: .displays(.selected([selectedDisplayID])))
            return
        }
        let point = dependencies.systemServices.mouse.appKitGlobalLocation
        guard let screen = dependencies.systemServices.screens.screen(containing: point) ?? dependencies.systemServices.screens.mainScreen else { return }
        start(source: .displays(.selected([screen.displayID])))
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

    private func selectAndStartRegion() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let selection = try await dependencies.capture.videoWindowSelectionSnapshot(fallbackWindows: availableWindows)
                let session = RegionSelectionSession(
                    snapshot: selection.snapshot,
                    windows: selection.windows,
                    preferences: dependencies.capture.regionCapturePreferences,
                    livePreviewCapturePlatform: dependencies.systemServices.screenCapturePlatform
                )
                guard let result = await session.begin() else { return }
                switch result {
                case .region(let rect, _): start(source: .region(rect))
                case .window(let window): start(source: .window(id: window.id, ownerPID: window.ownerPID, name: window.displayTitle, frame: window.frame))
                }
            } catch { outputSink?.handle(GuideWorkflowOutput.presentError(error.localizedDescription)) }
        }
    }

    private func startImmediately(source: GuideCaptureSource, privateCapture: Bool) async throws {
        isShowingQuickStart = false
        try await captureCoordinator.start(
            source: source,
            preferences: capturePreferences,
            exportSettings: exportSettings,
            theme: theme,
            privateCapture: privateCapture,
            guideShortcutKeyCode: dependencies.capture.guideHotKeyCode
        )
        preferenceStore.saveLastSource(source)
        dependencies.lifecycle.updateWorkingMessage("Guide • 0 steps")
    }

    @discardableResult
    private func finishGuideCapture(exportImmediately: Bool = false) async throws -> EditableGuideDocument {
        guard let document = try await captureCoordinator.stop() else {
            throw AutomationExecutionError(code: .noActiveGuide, message: "There is no active Guide.")
        }
        guard !document.project.steps.isEmpty else {
            throw AutomationExecutionError(code: .guideHasNoSteps, message: "The Guide has no captured steps.")
        }
        outputSink?.handle(GuideWorkflowOutput.guideCompleted(document, exportImmediately: exportImmediately))
        outputSink?.handle(GuideWorkflowOutput.requestMainWindowPresentation)
        return document
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
                try captureCoordinator.resume()
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
