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

nonisolated struct GuideConflictingActionPrompt {
    let action: String
    let isPrivate: Bool

    var detail: String {
        isPrivate
            ? "The Private Guide will open so you can save or export it before \(action). Private Guides are not written to recovery."
            : "Guide must stop before \(action). Completed steps and source media will be finalized and kept for recovery."
    }

    var confirmationTitle: String { isPrivate ? "Stop & Open Guide" : "Stop & Continue" }
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
    private let finalizationCoordinator = GuideFinalizationCoordinator()
    private var captureStateObservation: AnyCancellable?
    private var captureDiscardObservation: AnyCancellable?
    private var captureSetupGeneration = UUID()
    private var privateSetupGeneration: UUID?

    @Published var isShowingQuickStart = false
    @Published private(set) var captureSetupDraft: GuideCaptureSetupDraft?
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

    var isActive: Bool { captureCoordinator.state != .idle || captureCoordinator.isDiscarding || finalizationCoordinator.isFinishing }
    var isFinishing: Bool { captureCoordinator.state == .finishing || finalizationCoordinator.isFinishing }
    var isDiscarding: Bool { captureCoordinator.isDiscarding }
    var availableWindows: [CaptureWindowSummary] { dependencies.capture.availableWindows }
    var stepCount: Int { captureCoordinator.project?.steps.count ?? 0 }
    var captureSetupIsPrivate: Bool {
        dependencies.capture.privateCaptureEnabled || privateSetupGeneration == captureSetupGeneration
    }
    var exitContext: GuideExitContext? {
        guard isActive else { return nil }
        return captureCoordinator.project.map { GuideExitContext(isPrivate: $0.isPrivate, hasSteps: !$0.steps.isEmpty) }
            ?? finalizationCoordinator.exitContext
    }

    func presentQuickStart() {
        guard dependencies.capabilities.isEnabled(.guideCapture) else { return }
        if isActive { stopGuide(); return }
        guard !dependencies.capture.isWorking,
              !dependencies.video.blocksNewCapture,
              !dependencies.capture.isConnectedDeviceSessionActive else {
            outputSink?.handle(GuideWorkflowOutput.presentError("Finish the active capture or recording before starting Guide."))
            return
        }
        // Starting another Guide must not silently reuse a previous display. The
        // setup sheet is where people can switch between Window, App, Region, and
        // Display; remembering the previous choice should set a sensible default,
        // not hide those choices.
        targetPickerKind = nil
        if !isShowingQuickStart {
            resetCaptureSetupPrivacy()
            restoreLastSourceSelection()
            captureSetupDraft = GuideCaptureSetupDraft(
                preferences: capturePreferences, sourceKind: selectedSourceKind
            )
        }
        isShowingQuickStart = true
    }

    func resumeSetupAfterPermissionRestart(_ draft: GuideCaptureSetupDraft) {
        guard dependencies.capabilities.isEnabled(.guideCapture) else { return }
        resetCaptureSetupPrivacy()
        captureSetupDraft = draft
        selectedSourceKind = draft.sourceKind
        isShowingQuickStart = true
    }

    func cancelQuickStart() {
        dependencies.permissions.cancelDeferredOperation(ifFeature: "Guide")
        resetCaptureSetupPrivacy()
        captureSetupDraft = nil
        targetPickerKind = nil
        isShowingQuickStart = false
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

    func beginSelectedSourceSelection(setup: GuideCaptureSetupDraft? = nil) {
        guard dependencies.capabilities.isEnabled(.guideCapture) else { return }
        let draft = setup ?? captureSetupDraft ?? GuideCaptureSetupDraft(
            preferences: capturePreferences, sourceKind: selectedSourceKind
        )
        let setupGeneration = captureSetupGeneration
        captureSetupDraft = draft
        guard dependencies.permissions.preflight(
            [.screenRecording, .accessibility],
            featureName: "Guide"
        ).isGranted else {
            dependencies.permissions.deferOperation(requiring: [.screenRecording, .accessibility], featureName: "Guide") { [weak self] in
                guard let self, self.captureSetupGeneration == setupGeneration else { return }
                self.beginSelectedSourceSelection(setup: draft)
            }
            if !captureSetupIsPrivate {
                dependencies.permissions.rememberPermissionRestartAction(.guide(draft))
            }
            return
        }

        dependencies.permissions.cancelDeferredOperation(ifFeature: nil)
        targetPickerKind = nil
        isShowingQuickStart = false
        let sourceKind = draft.sourceKind
        Task { @MainActor [weak self] in
            await self?.selectTargetOnScreen(sourceKind: sourceKind, generation: setupGeneration)
        }
    }

    func selectTarget(_ window: CaptureWindowSummary, as kind: GuideTargetPickerKind) {
        guard dependencies.capabilities.isEnabled(.guideCapture) else { return }
        targetPickerKind = nil
        start(source: kind.source(for: window))
    }

    func pickTargetOnScreen(as kind: GuideTargetPickerKind) {
        guard dependencies.capabilities.isEnabled(.guideCapture) else { return }
        guard dependencies.permissions.preflight(
            [.screenRecording, .accessibility],
            featureName: "Guide"
        ).isGranted else {
            returnToQuickStart()
            return
        }

        targetPickerKind = nil
        let setupGeneration = captureSetupGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 180_000_000)
            await selectTargetOnScreen(sourceKind: kind.rawValue, generation: setupGeneration)
        }
    }

    func cancelTargetSelection() {
        returnToQuickStart()
    }

    func start(source: GuideCaptureSource) {
        guard dependencies.capabilities.isEnabled(.guideCapture) else { return }
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
        let setupGeneration = captureSetupGeneration
        let isPrivate = captureSetupIsPrivate
        let setup = captureSetupDraft
        Task { @MainActor [weak self] in
            guard let self, captureSetupGeneration == setupGeneration else { return }
            do {
                try await startImmediately(
                    source: source,
                    privateCapture: isPrivate || dependencies.capture.privateCaptureEnabled,
                    setup: setup
                )
            } catch {
                guard captureSetupGeneration == setupGeneration, !(error is CancellationError) else { return }
                returnToQuickStart()
                dependencies.permissions.refreshPermissions()
                if !VideoWorkflowModel.isMicrophonePermissionError(error) {
                    outputSink?.handle(GuideWorkflowOutput.presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                }
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
            } catch {
                guard !(error is CancellationError) else { return }
                outputSink?.handle(GuideWorkflowOutput.presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
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
                guard !(error is CancellationError) else { return }
                outputSink?.handle(GuideWorkflowOutput.presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    func discardGuide() {
        guard !captureCoordinator.isDiscarding else { return }
        cancelQuickStart()
        guideAudioOptionsTask?.cancel()
        guideAudioOptionsTask = nil
        let projectID = captureCoordinator.project?.id
        let finalization = finalizationCoordinator.discardCurrentResult()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let finalization { _ = await discardFinalizedCapture(finalization, projectID: projectID) }
            else { await captureCoordinator.discard() }
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
            if let finalization = finalizationCoordinator.discardCurrentResult() {
                return await discardFinalizedCapture(finalization, projectID: captureCoordinator.project?.id)
            }
            await captureCoordinator.discard()
            return .readyToExit
        }
        if stepCount == 0, !finalizationCoordinator.isFinishing {
            await captureCoordinator.discard()
            return .readyToExit
        }
        do {
            let receipt = try await finalizeGuideCapture()
            defer { finalizationCoordinator.complete(receipt) }
            if receipt.wasDiscarded { return .readyToExit }
            let document = receipt.document
            if document.project.isPrivate || action == .openAndStay {
                presentFinalizedGuide(receipt)
                if document.project.isPrivate {
                    outputSink?.handle(GuideWorkflowOutput.presentError(
                        "Private Guides are not written to recovery. The Guide is open so you can save or export it."
                    ))
                }
                return .stayedOpen
            }
            if let issue = captureCoordinator.recoveryIssue {
                presentFinalizedGuide(receipt)
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
        let prompt = GuideConflictingActionPrompt(action: action, isPrivate: captureCoordinator.project?.isPrivate == true)
        alert.informativeText = prompt.detail
        alert.addButton(withTitle: prompt.confirmationTitle)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        // Reuse the exit retention policy: private work and failed checkpoints
        // must remain open instead of discarding the finalized document.
        return await prepareForApplicationExit(.finalizeForRecovery) == .readyToExit
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

    private func selectTargetOnScreen(sourceKind: String, generation: UUID) async {
        guard captureSetupGeneration == generation else { return }
        let hiddenWindow = dependencies.appWindowPresenter.hideAppWindowIfNeeded()
        var restoredWindow = false
        defer {
            if !restoredWindow { dependencies.appWindowPresenter.restoreAppWindowIfNeeded(hiddenWindow) }
        }
        try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
        guard captureSetupGeneration == generation else { return }

        let result: GuideTargetSelectionResult
        do {
            result = try await targetSelectionResult(for: sourceKind, generation: generation)
        } catch {
            guard captureSetupGeneration == generation else { return }
            returnToQuickStart()
            outputSink?.handle(GuideWorkflowOutput.presentError(error.localizedDescription))
            return
        }

        dependencies.appWindowPresenter.restoreAppWindowIfNeeded(hiddenWindow)
        restoredWindow = true
        await Task.yield()
        guard captureSetupGeneration == generation else { return }

        switch result {
        case .source(let source):
            start(source: source)
        case .chooseFromList(let kind):
            targetPickerKind = kind
        case .cancelled:
            returnToQuickStart()
        }
    }

    private func targetSelectionResult(for sourceKind: String, generation: UUID) async throws -> GuideTargetSelectionResult {
        let selection = try await dependencies.capture.videoWindowSelectionSnapshot()
        guard captureSetupGeneration == generation else { return .cancelled }
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
                return .source(GuideTargetPickerKind.window.source(for: window))
            }

        case "window", "app":
            let kind = GuideTargetPickerKind(rawValue: sourceKind) ?? .window
            let session = WindowSelectionSession(
                snapshot: selection.snapshot,
                windows: targetWindows,
                prompt: windowSelectionPrompt(for: kind)
            )
            switch await session.beginOutcome() {
            case .window(let window):
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
            return .source(.displays(.selected([displayID])))
        }
    }

    private func windowSelectionPrompt(for kind: GuideTargetPickerKind) -> WindowSelectionPrompt {
        switch kind {
        case .window:
            WindowSelectionPrompt(
                instructionText: "Hover a window, then click to start the Guide. Esc returns to setup.",
                listButtonTitle: "Choose from List…",
                windowLabel: \.displayTitle,
                targetActionHelp: String(localized: "Press to start the Guide with this window.")
            )
        case .app:
            WindowSelectionPrompt(
                instructionText: "Hover any window from an app, then click to follow that app. Esc returns to setup.",
                listButtonTitle: "Choose from List…",
                windowLabel: \.ownerName,
                targetActionHelp: String(localized: "Press to follow this app in the Guide.")
            )
        }
    }

    private func mergedTargetWindows(_ windows: [CaptureWindowSummary]) -> [CaptureWindowSummary] {
        var cachedWindows = Dictionary(availableWindows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

    private func resetCaptureSetupPrivacy() {
        captureSetupGeneration = UUID()
        privateSetupGeneration = nil
    }

    private func startImmediately(
        source: GuideCaptureSource,
        privateCapture: Bool,
        setup: GuideCaptureSetupDraft? = nil
    ) async throws {
        guard dependencies.capabilities.isEnabled(.guideCapture) else {
            throw AutomationExecutionError(
                code: .proFeatureRequired,
                message: "Guide capture is available in SnipSnipSnip Pro."
            )
        }
        isShowingQuickStart = false
        try await captureCoordinator.start(
            source: source,
            preferences: setup?.preferences ?? capturePreferences,
            exportSettings: exportSettings,
            theme: theme,
            logoImage: defaultLogoImage,
            privateCapture: privateCapture,
            guideShortcutKeyCode: dependencies.capture.guideHotKeyCode
        )
        if let setup {
            capturePreferences = setup.preferences
            completeFirstUseSetup()
            captureSetupDraft = nil
            resetCaptureSetupPrivacy()
            switch source {
            case .window(let id, _, _, _):
                selectedSourceKind = "window"
                selectedWindowID = id
            case .app(let processID, _, _, _):
                selectedSourceKind = "app"
                selectedWindowID = availableWindows.first(where: { $0.ownerPID == processID })?.id
            case .region:
                selectedSourceKind = "region"
            case .displays(let selection):
                selectedSourceKind = "display"
                if case .selected(let identifiers) = selection { selectedDisplayID = identifiers.first }
            }
        }
        preferenceStore.saveLastSource(source)
        dependencies.lifecycle.updateWorkingMessage(
            "\(WorkflowVocabulary.Status.guideCapturing) • 0 steps"
        )
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
        let receipt = try await finalizeGuideCapture()
        defer { finalizationCoordinator.complete(receipt) }
        guard !receipt.wasDiscarded else { throw CancellationError() }
        let document = receipt.document
        guard !document.project.steps.isEmpty else {
            throw AutomationExecutionError(code: .guideHasNoSteps, message: "The Guide has no captured steps.")
        }
        presentFinalizedGuide(receipt, exportImmediately: exportImmediately)
        if let recoveryIssue = captureCoordinator.recoveryIssue {
            outputSink?.handle(GuideWorkflowOutput.presentError(recoveryIssue))
        }
        return document
    }

    private func finalizeGuideCapture() async throws -> GuideFinalizationReceipt {
        try await finalizationCoordinator.finish(context: exitContext) { [captureCoordinator] in
            try await captureCoordinator.stop()
        }
    }

    private func presentFinalizedGuide(_ receipt: GuideFinalizationReceipt, exportImmediately: Bool = false) {
        guard finalizationCoordinator.shouldPresent(receipt) else { return }
        outputSink?.handle(GuideWorkflowOutput.guideCompleted(receipt.document, exportImmediately: exportImmediately))
        outputSink?.handle(GuideWorkflowOutput.requestMainWindowPresentation)
    }

    private func discardFinalizedCapture(_ task: Task<GuideFinalizationReceipt, Error>, projectID: UUID?) async -> GuideExitResult {
        var discardedProjectID = projectID
        if let receipt = try? await task.value {
            defer { finalizationCoordinator.complete(receipt) }
            discardedProjectID = receipt.document.project.id
            recoveryStore.remove(projectID: receipt.document.project.id)
            for url in receipt.document.mediaSegmentURLs.values { try? dependencies.systemServices.files.removeItem(at: url) }
        }
        if let currentProjectID = captureCoordinator.project?.id {
            guard currentProjectID == discardedProjectID else { return .stayedOpen }
            await captureCoordinator.discard()
        }
        return .readyToExit
    }
}

@MainActor
extension GuideWorkflowModel: GuideAutomationPort {
    func guideAutomation(_ command: GuideAutomationCommand, request: AutomationRequest) async -> AutomationResultEnvelope {
        guard dependencies.capabilities.isEnabled(.guideCapture) else {
            return .failure(
                requestID: request.id,
                code: .proFeatureRequired,
                message: "Guide capture and Guide automation are available in SnipSnipSnip Pro."
            )
        }
        do {
            switch command {
            case .start(let target):
                guard !isActive else {
                    return .failure(requestID: request.id, code: .guideAlreadyActive, message: "A Guide is already active.")
                }
                guard !dependencies.capture.isWorking, !dependencies.video.blocksNewCapture, !dependencies.capture.isConnectedDeviceSessionActive else {
                    return .failure(requestID: request.id, code: .busy, message: "Finish the active capture or recording before starting Guide.")
                }
                cancelQuickStart()
                if request.interactionPolicy == .never {
                    if case .region = target {
                        return .failure(requestID: request.id, code: .invalidRequest, message: "Guide Region capture requires an interactive automation policy.")
                    }
                    dependencies.permissions.refreshPermissions()
                    guard dependencies.permissions.permissionStatus.hasScreenRecording,
                          dependencies.permissions.permissionStatus.hasAccessibility else {
                        return .failure(requestID: request.id, code: .permissionDenied, message: "Guide requires Screen Recording and Accessibility access. Set up access in the app before running unattended automation.")
                    }
                    if capturePreferences.sourceVideoEnabled && capturePreferences.capturesMicrophone,
                       dependencies.permissions.mediaPermissionStatus(for: .microphone) != .allowed {
                        return .failure(requestID: request.id, code: .permissionDenied, message: "Guide narration requires Microphone access. Set up access in the app before running unattended automation.")
                    }
                }
                guard dependencies.permissions.preflight([.screenRecording, .accessibility], featureName: "Guide").isGranted else {
                    return .failure(requestID: request.id, code: .permissionDenied, message: "Guide requires Screen Recording and Accessibility access.")
                }
                let source: GuideCaptureSource
                switch target {
                case .window:
                    guard let window = try await dependencies.capture.availableGuideTargetWindows().first else { return .failure(requestID: request.id, code: .targetUnavailable, message: "No capturable window is available.") }
                    source = .window(id: window.id, ownerPID: window.ownerPID, name: window.displayTitle, frame: window.frame)
                case .app:
                    guard let window = try await dependencies.capture.availableGuideTargetWindows().first else { return .failure(requestID: request.id, code: .targetUnavailable, message: "No capturable app is available.") }
                    source = .app(processID: window.ownerPID, bundleIdentifier: nil, name: window.ownerName, initialFrame: window.frame)
                case .display:
                    source = .displays(.current)
                case .region:
                    if request.privacy.privateCapture { privateSetupGeneration = captureSetupGeneration }
                    selectedSourceKind = "region"
                    captureSetupDraft = GuideCaptureSetupDraft(
                        preferences: capturePreferences, sourceKind: "region"
                    )
                    isShowingQuickStart = true
                    return .success(
                        requestID: request.id,
                        payload: .guide(AutomationGuideSummary(state: "selectionRequired", stepCount: 0, source: "region", sourceVideoEnabled: capturePreferences.sourceVideoEnabled)),
                        outputs: [.init(kind: .acceptedInteractiveWorkflow)]
                    )
                }
                try await startImmediately(source: source, privateCapture: request.privacy.privateCapture || dependencies.capture.privateCaptureEnabled)
            case .pause:
                guard captureCoordinator.state == .recording else { return .failure(requestID: request.id, code: .noActiveGuide, message: "There is no active Guide to pause.") }
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
                payload: .guide(AutomationGuideSummary(state: captureCoordinator.state.rawValue, stepCount: stepCount, source: captureCoordinator.project?.source.automationTarget.rawValue, sourceVideoEnabled: capturePreferences.sourceVideoEnabled)),
                outputs: [.init(kind: .none)]
            )
        } catch let error as AutomationExecutionError {
            return .failure(requestID: request.id, code: error.code, message: error.message)
        } catch {
            return .failure(requestID: request.id, code: .guideFinalizationFailed, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

extension GuideCaptureSource {
    nonisolated var automationTarget: GuideAutomationTarget {
        switch self {
        case .window: .window
        case .app: .app
        case .region: .region
        case .displays: .display
        }
    }
}
