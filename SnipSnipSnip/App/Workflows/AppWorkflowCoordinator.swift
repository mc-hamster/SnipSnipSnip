import Foundation

@MainActor
protocol WorkflowOutputSink: AnyObject {
    func handle(_ output: LifecycleWorkflowOutput)
    func handle(_ output: PermissionWorkflowOutput)
    func handle(_ output: CaptureWorkflowOutput)
    func handle(_ output: DocumentWorkflowOutput)
    func handle(_ output: ClipboardWorkflowOutput)
    func handle(_ output: VideoWorkflowOutput)
    func handle(_ output: ArchiveWorkflowOutput)
    func handle(_ output: ToolWorkflowOutput)
}

@MainActor
final class AppWorkflowCoordinator: WorkflowOutputSink {
    private weak var lifecycle: (any CoordinatorLifecyclePort)?
    private weak var permissions: (any CoordinatorPermissionPort)?
    private weak var capture: (any CoordinatorCapturePort)?
    private weak var documents: (any CoordinatorDocumentPort)?
    private weak var clipboard: (any CoordinatorClipboardPort)?
    private weak var video: (any CoordinatorVideoPort)?
    private weak var archive: (any CoordinatorArchivePort)?
    private weak var tools: (any CoordinatorToolPort)?
    private weak var automation: (any CoordinatorAutomationPort)?

    init(
        lifecycle: any CoordinatorLifecyclePort,
        permissions: any CoordinatorPermissionPort,
        capture: any CoordinatorCapturePort,
        documents: any CoordinatorDocumentPort,
        clipboard: any CoordinatorClipboardPort,
        video: any CoordinatorVideoPort,
        archive: any CoordinatorArchivePort,
        tools: any CoordinatorToolPort,
        automation: any CoordinatorAutomationPort
    ) {
        self.lifecycle = lifecycle
        self.permissions = permissions
        self.capture = capture
        self.documents = documents
        self.clipboard = clipboard
        self.video = video
        self.archive = archive
        self.tools = tools
        self.automation = automation
    }

    func handle(_ output: LifecycleWorkflowOutput) {
        switch output {
        case .presentError(let message):
            lifecycle?.presentError(message)
        case .requestMainWindowPresentation:
            lifecycle?.requestMainWindowPresentation()
        case .requestOnboardingPresentation:
            lifecycle?.requestOnboardingPresentation()
        }
    }

    func handle(_ output: PermissionWorkflowOutput) {
        switch output {
        case .presentError(let message):
            lifecycle?.presentError(message)
        case .permissionsChanged(let status):
            capture?.notifyPermissionsChanged()
            if status.hasScreenRecording {
                capture?.refreshAvailableWindows(
                    includeThumbnails: true,
                    allowsCancellingPendingThumbnailRefresh: true
                )
            }
        case .requirementsMayNowBeSatisfied(let status):
            capture?.retryPendingPermissionCommandIfSatisfied(status)
        case .requestMainWindowPresentation:
            lifecycle?.requestMainWindowPresentation()
        }
    }

    func handle(_ output: CaptureWorkflowOutput) {
        switch output {
        case .captureCompleted(let result):
            guard let documents else {
                lifecycle?.presentError("Document workflow is not available.")
                lifecycle?.requestMainWindowPresentation()
                return
            }

            let controller = documents.installCapturedScreenshot(result)
            capture?.recordCompletedCapture(request: result.request, runOptions: result.runOptions)
            let workflowOutcome = result.workflowPreset?.outcome ?? .openInEditor
            let willBeCopied = workflowOutcome == .copyToClipboard || clipboard?.autoCopyEnabled == true

            if !result.isPrivateCapture {
                clipboard?.scheduleClipboardSnipRecording(
                    from: controller,
                    searchableText: result.capture.sourceName,
                    sessionID: documents.currentRecoverySessionID,
                    willBeCopied: willBeCopied
                )
            }

            if workflowOutcome == .copyToClipboard {
                documents.copyCurrentEditorImageToClipboard()
            } else if workflowOutcome == .exportToFolder,
                      let destination = result.workflowPreset?.exportDestination {
                Task { @MainActor [weak lifecycle] in
                    do {
                        let url = try await documents.exportWorkflowCapture(from: controller, to: destination)
                        controller.showNotice("Saved workflow capture to \(url.lastPathComponent).")
                    } catch {
                        lifecycle?.presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    }
                }
            } else if clipboard?.autoCopyEnabled == true {
                documents.scheduleAutoCopy(for: controller)
            }

            if result.shouldProcessUIMap {
                capture?.scheduleUIMapCapture(for: controller, capture: result.uiMapSourceCapture)
            } else if result.shouldAttemptUIMapCapture,
                      result.runOptions.windowUIMapEnabled,
                      result.capture.uiMap == nil {
                capture?.noticeSkippedUIMapCapture(reason: result.uiMapSkipReason)
            }

            if workflowOutcome == .openInEditor {
                lifecycle?.requestMainWindowPresentation()
            }
        case .presentError(let message):
            lifecycle?.presentError(message)
        case .requestMainWindowPresentation:
            lifecycle?.requestMainWindowPresentation()
        case .connectedDeviceSessionChanged(let isActive):
            capture?.setConnectedDeviceSessionActive(isActive)
        }
    }

    func handle(_ output: DocumentWorkflowOutput) {
        switch output {
        case .presentError(let message):
            lifecycle?.presentError(message)
        case .requestMainWindowPresentation:
            lifecycle?.requestMainWindowPresentation()
        case .documentChanged:
            clipboard?.notifyDocumentChanged()
        }
    }

    func handle(_ output: ClipboardWorkflowOutput) {
        switch output {
        case .presentError(let message):
            lifecycle?.presentError(message)
        case .autoCopyChanged(let enabled):
            if enabled {
                documents?.copyCurrentEditorImageToClipboard()
            } else {
                documents?.cancelPendingAutoCopy()
            }
        }
    }

    func handle(_ output: VideoWorkflowOutput) {
        switch output {
        case .recordingCompleted(let recording):
            documents?.installCapturedRecording(recording)
        case .presentError(let message):
            lifecycle?.presentError(message)
        case .requestMainWindowPresentation:
            lifecycle?.requestMainWindowPresentation()
        }
    }

    func handle(_ output: ArchiveWorkflowOutput) {
        switch output {
        case .presentError(let message):
            lifecycle?.presentError(message)
        case .archiveChanged:
            documents?.refreshHistoryEntries()
        }
    }

    func handle(_ output: ToolWorkflowOutput) {
        switch output {
        case .screenInspectorSnip(let sample):
            capture?.completeScreenInspectorSnip(sample)
        }
    }

    func handleApplicationDidBecomeActive() {
        permissions?.refreshPermissions()
        lifecycle?.refreshLaunchAtLoginStatus()
        permissions?.checkPermissionSetupGuideStatus()

        if capture?.autoRefreshWindowsEnabled == false {
            refreshAvailableWindowsOnApplicationForegroundIfNeeded()
        }

        if let permissionStatus = permissions?.permissionStatus {
            capture?.retryPendingPermissionCommandIfSatisfied(permissionStatus)
        }
    }

    func activateStartupServices(
        capabilities: AppCapabilitySnapshot,
        configuredArchiveLocationURL: URL?,
        shouldCheckCompatibilityOnLaunch: Bool,
        shouldStartArchiveMaintenance: Bool,
        isRunningUnitTests: Bool
    ) {
        archive?.activateArchiveDirectoryAccess(configuredArchiveLocationURL)
        documents?.cleanupStalePackageTemporaryDirectories()

        if shouldCheckCompatibilityOnLaunch {
            documents?.handleIncompatibleRecoveryEntriesOnLaunch()
        }

        if shouldStartArchiveMaintenance {
            archive?.startArchiveMaintenance()
        }

        if capabilities.isEnabled(.connectedDeviceCapture), !isRunningUnitTests {
            capture?.refreshConnectedDevices()
        }

        clipboard?.startMonitoring()
    }

    func prepareForMainWindowPresentation() {
        capture?.promoteToRegularApp()
    }

    func requestMainWindowPresentation() {
        prepareForMainWindowPresentation()
        lifecycle?.requestMainWindowPresentation()
    }

    func mainWindowDidAppear() {
        capture?.promoteToRegularApp()
        documents?.syncMainWindowDocumentState()
        documents?.resizeMainWindowForEditorContentIfNeeded(animated: true)
    }

    func mainWindowDidDisappear() {
        Task { @MainActor [weak self] in
            self?.capture?.demoteToAccessoryIfPossible()
        }
    }

    private func refreshAvailableWindowsOnApplicationForegroundIfNeeded() {
        guard let capture,
              !capture.isInteractiveCaptureActive,
              documents?.editorController == nil,
              documents?.videoEditorController == nil,
              !capture.isWorking,
              !capture.isShowingWindowPicker,
              permissions?.permissionStatus.hasScreenRecording == true else {
            return
        }

        capture.refreshAvailableWindows(
            includeThumbnails: true,
            allowsCancellingPendingThumbnailRefresh: false
        )
    }

    func canRepeatLastCapture() -> Bool {
        capture?.canRepeatLastCapture ?? false
    }

    func handleGlobalHotKeyAction(_ action: GlobalHotKeyAction) {
        let isCapturing = capture?.isWorking == true
        let isRecording = video?.isRecording == true

        guard !isCapturing, !isRecording else {
            lifecycle?.presentBusyHotKeyFeedback(
                message: isRecording ? "Recording in progress" : "Capture already in progress"
            )
            return
        }

        switch action {
        case .region:
            capture?.captureRegion()
        case .window:
            capture?.presentWindowPicker()
        case .fullscreen:
            capture?.captureCurrentDisplay()
        case .frontmostWindow:
            capture?.captureFrontmostWindow()
        case .repeatLastCapture:
            capture?.repeatLastCapture()
        case .screenInspector:
            tools?.toggleScreenInspector()
        }
    }

    func handleGlobalPresetHotKey(_ presetID: UUID) {
        guard capture?.isWorking != true, video?.isRecording != true else {
            lifecycle?.presentBusyHotKeyFeedback(message: video?.isRecording == true ? "Recording in progress" : "Capture already in progress")
            return
        }
        capture?.capturePreset(id: presetID)
    }

    var canResetPreferencesToDefaults: Bool {
        guard let capture else {
            return false
        }

        return !capture.isWorking
            && !capture.isShowingWindowPicker
            && video?.isRecording != true
            && !capture.isConnectedDeviceSessionActive
    }

    func resetPreferencesToDefaults() {
        guard canResetPreferencesToDefaults else {
            return
        }

        clipboard?.resetClipboardPreferencesToDefaults()
        capture?.resetCapturePreferencesToDefaults()
        documents?.resetDocumentPreferencesToDefaults()
        tools?.resetToolPreferencesToDefaults()
        video?.resetVideoPreferencesToDefaults()
        archive?.resetArchivePreferencesToDefaults()
    }

    func capturePreset(_ preset: CapturePreset) {
        capture?.capturePreset(preset)
    }

    func beginRegionCapture() {
        capture?.beginRegionCapture()
    }

    func presentWindowPicker() {
        capture?.presentWindowPicker()
    }

    func repeatLastCapture() {
        capture?.repeatLastCapture()
    }

    func openDocument(_ url: URL) {
        documents?.openDocument(at: url)
    }

    func saveDocument(_ controller: EditorController, to url: URL) async -> Bool {
        await documents?.saveDocument(controller, to: url) ?? false
    }

    func floatCurrentEditorReference() {
        documents?.floatCurrentEditorReference()
    }

    func automationResultAfterCurrentEditorOutput(
        _ request: AutomationRequest,
        _ kind: String,
        _ sourceName: String?
    ) async -> AutomationResultEnvelope {
        guard let automation else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }

        return await automation.resultAfterCurrentEditorOutput(
            request: request,
            kind: kind,
            sourceName: sourceName
        )
    }
}

struct CaptureWorkflowResult {
    let capture: CapturedScreenshot
    let uiMapSourceCapture: CapturedScreenshot
    let request: LastCaptureRequest
    let runOptions: CaptureRunOptions
    let isPrivateCapture: Bool
    let checkpointLabel: String
    let shouldAttemptUIMapCapture: Bool
    let shouldProcessUIMap: Bool
    let uiMapSkipReason: String?
    let workflowPreset: CapturePreset?
}

enum LifecycleWorkflowOutput {
    case presentError(String)
    case requestMainWindowPresentation
    case requestOnboardingPresentation
}

enum PermissionWorkflowOutput {
    case permissionsChanged(CapturePermissionStatus)
    case requirementsMayNowBeSatisfied(CapturePermissionStatus)
    case requestMainWindowPresentation
    case presentError(String)
}

enum CaptureWorkflowOutput {
    case captureCompleted(CaptureWorkflowResult)
    case connectedDeviceSessionChanged(Bool)
    case presentError(String)
    case requestMainWindowPresentation
}

enum DocumentWorkflowOutput {
    case documentChanged
    case presentError(String)
    case requestMainWindowPresentation
}

enum ClipboardWorkflowOutput {
    case autoCopyChanged(Bool)
    case presentError(String)
}

enum VideoWorkflowOutput {
    case recordingCompleted(CapturedVideoRecording)
    case presentError(String)
    case requestMainWindowPresentation
}

enum ArchiveWorkflowOutput {
    case archiveChanged
    case presentError(String)
}

enum ToolWorkflowOutput {
    case screenInspectorSnip(ScreenInspectorSample)
}
