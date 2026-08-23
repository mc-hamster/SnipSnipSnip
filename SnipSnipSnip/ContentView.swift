import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var lifecycle: AppLifecycleModel
    @ObservedObject var capture: CaptureWorkflowModel
    @ObservedObject var permissions: PermissionWorkflowModel
    @ObservedObject var documents: DocumentWorkflowModel
    @ObservedObject var clipboard: ClipboardWorkflowModel
    @ObservedObject var video: VideoWorkflowModel
    @ObservedObject var guide: GuideWorkflowModel
    @ObservedObject var tools: ToolWorkflowModel
    @ObservedObject var creation: CreationWorkflowModel
    let capabilities: AppCapabilitySnapshot
    let workflowCoordinator: AppWorkflowCoordinator
    let presentWindowQuickCaptureMenu: () -> Void
    let performAutomationRequest: (AutomationRequest) async -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    @State private var isPermissionDiagnosticExpanded = false
    @State private var hoveredCaptureDiscovery: CaptureDiscoveryItem?
    @State private var selectedCaptureDiscovery: CaptureDiscoveryItem = .overview
    @FocusState private var focusedCaptureDiscovery: CaptureDiscoveryItem?
    @SceneStorage("editor.inspector.isPresented")
    private var isEditorInspectorPresented = true
    @State private var compositionImportDetails:
        CompositionImportRecoveryState?

    private let windowRefreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isRecordingVideo: Bool {
        video.recordingLifecycle.blocksNewCapture
    }

    var body: some View {
        VStack(spacing: 0) {
            captureHeader
            Divider()

            if let editorController = documents.editorController {
                EditorCommandBar(
                    controller: editorController,
                    isInspectorPresented: $isEditorInspectorPresented,
                    onBack: documents.closeEditor,
                    onFloatReference: { documents.floatCurrentEditorReference(appearance: $0) },
                    onExportPNG: { documents.exportAnnotatedImage(as: .png, appearance: $0) },
                    onExportJPEG: { documents.exportAnnotatedImage(as: .jpeg, appearance: $0) },
                    onExportPDF: { documents.exportAnnotatedImage(as: .pdf, appearance: $0) },
                    onExportComposition: { documents.exportComposition(as: $0, appearance: $1) },
                    onCopy: { appearance in
                        if appearance == .styled {
                            documents.copyCurrentStyledEditorImageToClipboard()
                        } else {
                            documents.copyCurrentPlainEditorImageToClipboard()
                        }
                    },
                    onShare: { documents.shareAnnotatedImage(appearance: $0) },
                    onShowLayers: showLayersWindow,
                    onShowUIMap: showUIMapWindow,
                    dragOutPayloadProvider: { documents.promisedAnnotatedImagePayload(appearance: $0) },
                    compositionAddActions: compositionAddActions(for: editorController)
                )
                Divider()
            }

            Group {
                if let guideController = documents.guideEditorController {
                    GuideEditorView(
                        controller: guideController,
                        capabilities: capabilities,
                        recentSnips: documents.recentSnipEntries,
                        onAddRecentSnip: { documents.addRecentSnip($0, to: guideController) },
                        savedThemes: guide.savedThemes,
                        onSaveTheme: guide.saveTheme,
                        onSetDefaultBranding: guide.setDefaultBranding
                    )
                        .id(ObjectIdentifier(guideController))
                } else if let editorController = documents.editorController {
                    EditorView(
                        controller: editorController,
                        isInspectorPresented: $isEditorInspectorPresented,
                        historyEntries: documents.historyEntries,
                        recycleBinEntries: documents.recycleBinEntries,
                        historyActions: EditorHistoryActions(
                            onPresentSnipLibrary: { scope in
                                documents.presentSnipLibrary(initialScope: scope)
                            },
                            onPresentHistoryPreview: documents.presentHistoryPreview,
                            onCloseHistoryPreview: documents.closeHistoryPreview,
                            onRestoreHistoryEntry: documents.restoreHistoryEntry,
                            onRestoreRecentSnipEntry: documents.restoreRecentSnipEntry,
                            onFloatHistoryEntry: documents.floatHistoryReference,
                            onDeleteHistoryEntry: documents.deleteHistoryEntry,
                            onDeleteAllHistoryEntries: documents.deleteAllHistoryEntries,
                            onDeleteRecentSnipEntry: documents.deleteRecentSnipEntry,
                            onDeleteAllRecentSnipEntries: documents.deleteAllRecentSnipEntries,
                            onRestoreRecycledHistoryEntry: documents.restoreRecycledHistoryEntry,
                            onPermanentlyDeleteRecycledHistoryEntry: documents.requestPermanentlyDeleteRecycledHistoryEntry,
                            onEmptyRecycleBin: documents.requestEmptyRecycleBin
                        ),
                        compositionActions: compositionInspectorActions(for: editorController),
                        compositionExportProgress:
                            documents.compositionExportProgressState,
                        onCancelCompositionExport:
                            documents.cancelCompositionExport,
                        onUndoLibrarySwitch:
                            documents.undoLastLibrarySwitch
                    )
                    .id(ObjectIdentifier(editorController))
                } else if let videoController = documents.videoEditorController {
                    VideoEditorView(controller: videoController)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            appToolbarContent
        }
        .background {
            MainWindowMinimumSizeBridge(
                preferredContentSize: preferredMainWindowMinimumContentSize
            )
            .frame(width: 0, height: 0)
        }
        .toolbar(removing: .title)
        .confirmationDialog("Save changes before continuing?", isPresented: $documents.isShowingUnsavedChangesPrompt, titleVisibility: .visible) {
            Button("Save", action: documents.confirmSaveBeforeContinuing)
            Button("Discard Changes", role: .destructive, action: documents.discardChangesAndContinue)
            Button("Cancel", role: .cancel, action: documents.cancelPendingEditorAction)
        } message: {
            Text("The current \(AppBranding.displayName) document has unsaved changes.")
        }
        .sheet(isPresented: $capture.isShowingWindowPicker) {
            CaptureWindowPickerView(
                windows: capture.availableWindows,
                onSelect: { window in
                    switch capture.windowPickerMode {
                    case .videoRecording:
                        video.recordWindow(window)
                    case .capturePresetReplacement(let presetID):
                        capture.isShowingWindowPicker = false
                        capture.replaceWindowTargetAndCapturePreset(id: presetID, with: window)
                    case .screenshot:
                        capture.captureWindow(window)
                    }
                    capture.windowPickerMode = .screenshot
                },
                onPickOnScreen: {
                    switch capture.windowPickerMode {
                    case .videoRecording:
                        video.pickWindowOnScreenForVideoRecording()
                    case .capturePresetReplacement(let presetID):
                        capture.pickWindowOnScreenForPresetReplacement(id: presetID)
                    case .screenshot:
                        capture.pickWindowOnScreen()
                    }
                    capture.windowPickerMode = .screenshot
                },
                onCancel: {
                    if case .videoRecording = capture.windowPickerMode {
                        video.cancelPendingVideoRecording()
                    }
                    capture.cancelScreenshotWindowPicker()
                }
            )
        }
        .sheet(isPresented: $guide.isShowingQuickStart) {
            GuideQuickStartView(guide: guide, permissions: permissions)
        }
        .sheet(isPresented: creationQuickStartBinding) {
            CreationQuickStartView(creation: creation)
        }
        .sheet(isPresented: existingCreationSourceBinding) {
            if let plan = creation.pendingExistingSourcePlan {
                CreationExistingSourcePickerView(
                    sourceTitle: pendingExistingSourceTitle(plan),
                    recentEntries: pendingExistingSourceRecentEntries(plan),
                    historyEntries: pendingExistingSourceHistoryEntries(plan),
                    outOfCapturePatternSettings: documents.editorOutOfCapturePatternSettings,
                    loadPreview: { entry in
                        try? await HistoryPreviewImageLoader.loadImage(
                            from: entry.packageURL,
                            files: documents.systemServices.files
                        )
                    },
                    onChoose: { entry, flattened in
                        let didCreate = documents.createDocument(
                            from: entry,
                            flattened: flattened,
                            completionRole:
                                plan.captureCompletionRole ?? .standalone,
                            forcePrivate:
                                plan.captureOptions.privateCapture
                        )
                        if didCreate {
                            creation.completeExistingSourceSelection()
                        }
                    },
                    onCancel: creation.cancelExistingSourceSelection
                )
            }
        }
        .sheet(isPresented: connectedDeviceCreationBinding) {
            CreationConnectedDevicePickerView(
                devices: capture.connectedDevices,
                isLoading: capture.isLoadingConnectedDevices,
                emptyStateMessage:
                    capture.connectedDeviceEmptyStateMessage,
                onRefresh: capture.refreshConnectedDevices,
                onChoose: creation.selectConnectedDevice,
                onCancel: creation.cancelConnectedDeviceSelection
            )
        }
        .sheet(item: $guide.targetPickerKind) { kind in
            GuideTargetPickerView(
                kind: kind,
                windows: guide.targetWindows,
                onSelect: { guide.selectTarget($0, as: kind) },
                onPickOnScreen: { guide.pickTargetOnScreen(as: kind) },
                onCancel: guide.cancelTargetSelection
            )
        }
        .sheet(isPresented: capturePresetNamingSheetBinding) {
            CapturePresetNamingSheetView(capture: capture)
                .frame(width: 420)
        }
        .sheet(item: $capture.captureRecovery) { recovery in
            CaptureRecoverySheetView(
                recovery: recovery,
                performAction: { action in
                    if action == .openTroubleshooting {
                        openWindow(id: AppSceneID.helpWindow)
                        capture.dismissCaptureRecovery()
                    } else {
                        capture.performCaptureRecovery(action)
                    }
                },
                dismiss: capture.dismissCaptureRecovery
            )
            .frame(width: 460)
        }
        .sheet(item: $compositionImportDetails) { recovery in
            CompositionImportFailureDetailsView(
                recovery: recovery,
                retryFailed: {
                    compositionImportDetails = nil
                    documents.retryFailedCompositionImports()
                }
            )
        }
        .alert("Capture Error", isPresented: Binding(get: {
            lifecycle.errorMessage != nil
        }, set: { value in
            if !value {
                lifecycle.dismissError()
            }
        })) {
            Button("OK", role: .cancel) {
                lifecycle.dismissError()
            }
        } message: {
            Text(lifecycle.errorMessage ?? "")
        }
        .task {
            permissions.refreshPermissions()
            capture.refreshAvailableWindows()
            handlePendingDocumentOpenRequests()
            handlePendingPasteboardImageImportRequests()
            handlePendingAutomationRequests()
        }
        .onAppear {
            workflowCoordinator.mainWindowDidAppear()
            if guide.isActive { GuideCaptureHUDController.shared.show(guide: guide) }
        }
        .onDisappear {
            workflowCoordinator.mainWindowDidDisappear()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sssPendingDocumentURLsDidChange)) { _ in
            handlePendingDocumentOpenRequests()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sssPendingPasteboardImageImportsDidChange)) { _ in
            handlePendingPasteboardImageImportRequests()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sssPendingAutomationRequestsDidChange)) { _ in
            handlePendingAutomationRequests()
        }
        .onReceive(windowRefreshTimer) { _ in
            guard NSApp.isActive else {
                return
            }

            guard !capture.isInteractiveCaptureActive else {
                return
            }

            guard !guide.isActive, !guide.isShowingQuickStart else { return }

            permissions.refreshPermissions()

            guard capture.autoRefreshWindowsEnabled,
                  documents.editorController == nil,
                  !capture.isWorking,
                  !capture.isShowingWindowPicker,
                  permissions.permissionStatus.hasScreenRecording else {
                return
            }

            capture.refreshAvailableWindows(
                includeThumbnails: true,
                allowsCancellingPendingThumbnailRefresh: false
            )
        }
        .onChange(of: guide.captureCoordinator.state) { _, state in
            if state == .idle { GuideCaptureHUDController.shared.hide() }
            else { GuideCaptureHUDController.shared.show(guide: guide) }
        }
    }

    private func compositionAddActions(
        for controller: EditorController,
        completionRole: CaptureCompletionRole = .standalone
    ) -> CompositionAddActions {
        let intent = CaptureIntent.append(
            documentGenerationID: controller.documentGenerationID,
            afterItemID: controller.snapshot.composition?.selectedItemIDs.last
        )
        let historyActions: (DocumentHistoryEntry) -> CompositionAddSourceAction = { entry in
            CompositionAddSourceAction(
                id: entry.id.uuidString,
                title: entry.libraryMenuTitle,
                action: {
                    documents.addHistoryEntryToCurrentComposition(
                        entry,
                        completionRole: completionRole
                    )
                },
                flattenedAction: {
                    documents.addHistoryEntryToCurrentComposition(
                        entry,
                        flattened: true,
                        completionRole: completionRole
                    )
                }
            )
        }

        return CompositionAddActions(
            addRegion: {
                capture.captureRegion(
                    intent: intent,
                    completionRole: completionRole
                )
            },
            addWindow: {
                capture.presentWindowPicker(
                    intent: intent,
                    completionRole: completionRole
                )
            },
            addFrontmostWindow: {
                capture.captureFrontmostWindow(
                    intent: intent,
                    completionRole: completionRole
                )
            },
            addFullScreen: {
                capture.captureCurrentDisplay(
                    intent: intent,
                    completionRole: completionRole
                )
            },
            addRepeat: {
                capture.repeatLastCapture(
                    intent: intent,
                    completionRole: completionRole
                )
            },
            canRepeat: capture.canRepeatLastCapture,
            captureDelay: capture.captureDelay,
            addTimedRegion: { delay in
                capture.captureDelay = delay
                capture.captureRegion(
                    intent: intent,
                    completionRole: completionRole
                )
            },
            addScrolling: capabilities.isEnabled(.scrollingCapture)
                ? {
                    capture.captureScrollingArea(
                        intent: intent,
                        completionRole: completionRole
                    )
                }
                : nil,
            addScreenInspector: capabilities.isEnabled(.screenInspector)
                ? {
                    let context =
                        capture.prepareScreenInspectorCaptureIntent(
                        intent,
                        completionRole: completionRole
                    )
                    tools.presentScreenInspector {
                        guard let sessionID =
                            context.persistentSurfaceSessionID else {
                            return
                        }
                        capture.resetPersistentCaptureSurfaceSession(
                            sessionID
                        )
                    }
                }
                : nil,
            connectedDevices: capture.connectedDevices.map { device in
                CompositionAddSourceAction(
                    id: device.id,
                    title: device.displayName,
                    action: {
                        capture.captureConnectedDevice(
                            device,
                            intent: intent,
                            completionRole: completionRole
                        )
                    },
                    flattenedAction: {
                        capture.captureConnectedDevice(
                            device,
                            intent: intent,
                            completionRole: completionRole
                        )
                    }
                )
            },
            importImages: {
                documents.addImagesToCurrentCompositionPanel(
                    completionRole: completionRole
                )
            },
            pasteImage: {
                documents.pasteImageIntoCurrentComposition(
                    completionRole: completionRole
                )
            },
            recentSnips: documents.recentSnipEntries.map(historyActions),
            captureHistory: documents.allCaptureHistoryEntries.map(historyActions),
            archive: documents.compositionArchiveEntries.map(historyActions),
            actionsForCompletionRole: { role in
                compositionAddActions(
                    for: controller,
                    completionRole: role
                )
            }
        )
    }

    private var creationQuickStartBinding: Binding<Bool> {
        Binding(
            get: { creation.isShowingQuickStart },
            set: { isPresented in
                if !isPresented {
                    creation.cancelQuickStart()
                }
            }
        )
    }

    private var existingCreationSourceBinding: Binding<Bool> {
        Binding(
            get: { creation.pendingExistingSourcePlan != nil },
            set: { isPresented in
                if !isPresented {
                    creation.cancelExistingSourceSelection()
                }
            }
        )
    }

    private var connectedDeviceCreationBinding: Binding<Bool> {
        Binding(
            get: { creation.pendingConnectedDevicePlan != nil },
            set: { isPresented in
                if !isPresented {
                    creation.cancelConnectedDeviceSelection()
                }
            }
        )
    }

    private func pendingExistingSourceTitle(
        _ plan: CreationPlan
    ) -> String {
        guard case .existing(let source) = plan.source else {
            return "Choose an Image"
        }
        switch source {
        case .recentSnips:
            return "Choose a Recent Snip"
        case .captureHistory:
            return "Choose from \(WorkflowVocabulary.Library.snipLibrary)"
        case .archive:
            return "Choose from \(WorkflowVocabulary.Library.snipLibrary)"
        case .files:
            return "Choose a File"
        case .clipboard:
            return "Choose from Clipboard"
        }
    }

    private func pendingExistingSourceRecentEntries(
        _ plan: CreationPlan
    ) -> [DocumentHistoryEntry] {
        guard case .existing(let source) = plan.source else {
            return []
        }
        switch source {
        case .recentSnips, .captureHistory, .archive:
            return documents.recentSnipEntries
        case .files, .clipboard:
            return []
        }
    }

    private func pendingExistingSourceHistoryEntries(
        _ plan: CreationPlan
    ) -> [DocumentHistoryEntry] {
        guard case .existing(let source) = plan.source else {
            return []
        }
        switch source {
        case .recentSnips:
            return []
        case .captureHistory, .archive:
            return documents.snipLibraryEntries
        case .files, .clipboard:
            return []
        }
    }

    private func compositionInspectorActions(for controller: EditorController) -> CompositionInspectorActions {
        let importRecovery = documents.pendingCompositionImportRecovery.map {
            recovery in
            CompositionImportRecoveryActions(
                summary: recovery.summary,
                retryFailed: documents.retryFailedCompositionImports,
                showDetails: {
                    compositionImportDetails = recovery
                },
                dismiss: documents.dismissCompositionImportRecovery
            )
        }

        return CompositionInspectorActions(
            addCapture: compositionAddActions(for: controller),
            importRecovery: importRecovery,
            editComposition: controller.enterCompositionEditing,
            editItem: controller.enterCompositionItemEditing,
            replaceItem: { itemID in
                capture.captureRegion(
                    intent: .replace(
                        documentGenerationID: controller.documentGenerationID,
                        itemID: itemID
                    )
                )
            },
            recaptureItem: { itemID in
                capture.repeatLastCapture(
                    intent: .replace(
                        documentGenerationID: controller.documentGenerationID,
                        itemID: itemID
                    )
                )
            },
            locateItem: documents.locateCompositionItemSource,
            dropFiles: { urls, destination in
                documents.handleCompositionFileDrop(
                    urls,
                    destination: destination
                )
            },
            openSelectedAsScreenshot:
                documents.openCompositionItemAsNewScreenshot
        )
    }

    @ToolbarContentBuilder
    private var appToolbarContent: some ToolbarContent {
        if let guideController = documents.guideEditorController {
            GuideEditorToolbarContent(
                controller: guideController,
                onBack: documents.closeEditor,
                onExport: { documents.exportCurrentGuide(showProgressWindow: $0) },
                exportIsActive: documents.guideExportIsActive,
                exportProgress: documents.guideExportProgress,
                exportStatus: documents.guideExportStatus,
                onCancelExport: documents.cancelGuideExport,
                onShowExportProgress: documents.showGuideExportProgress,
                hasExportedFiles: !documents.lastGuideExportURLs.isEmpty,
                onRevealExports: documents.revealGuideExports,
                onCopyExports: documents.copyGuideExports,
                onShareExports: documents.shareGuideExports,
                dragOutPayloadProvider: documents.promisedGuidePayload
            )
        } else if let videoController = documents.videoEditorController {
            VideoEditorToolbarContent(
                controller: videoController,
                documentFilename: documents.currentDocumentFilename,
                hasUnsavedChanges: documents.hasUnsavedChanges,
                exportPreferences: video.exportPreferences,
                onBack: documents.closeEditor,
                onExportRequest: video.exportVideo(using:),
                dragOutPayloadProvider: video.promisedVideoPayload
            )
        }
    }

    private var captureHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    captureHeaderIdentity
                    Spacer(minLength: 12)
                    if documents.editorController != nil {
                        contextualCreateButton
                    } else {
                        captureHeaderOptions
                    }
                    autoCopyToggle
                }

                VStack(alignment: .leading, spacing: 8) {
                    captureHeaderIdentity
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        if documents.editorController != nil {
                            contextualCreateButton
                        } else {
                            captureHeaderOptions
                        }
                        autoCopyToggle
                    }
                }
            }

            captureHeaderActions

            if !headerCaptureReady {
                if hasOpenDocument {
                    compactPermissionStrip
                    if isPermissionDiagnosticExpanded {
                        headerPermissionCallout
                    }
                } else {
                    headerPermissionCallout
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.header")
        .task(id: hoveredCaptureDiscovery) {
            guard let hoveredCaptureDiscovery else {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else {
                return
            }
            selectedCaptureDiscovery = hoveredCaptureDiscovery
        }
        .onChange(of: focusedCaptureDiscovery) { _, focusedItem in
            if let focusedItem {
                selectedCaptureDiscovery = focusedItem
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification
            )
        ) { _ in
            hoveredCaptureDiscovery = nil
        }
        .onChange(of: permissions.activePermissionRequest) { _, request in
            if request != nil, hasOpenDocument {
                isPermissionDiagnosticExpanded = true
            }
        }
        .onChange(of: permissions.permissionStatus) { oldStatus, newStatus in
            guard oldStatus != newStatus else {
                return
            }
            AppAccessibility.announce(
                newStatus.hasScreenRecording
                    ? "Screenshot capture is available."
                    : "Screenshot capture is unavailable. Screen Recording access is required.",
                priority: .high
            )
        }
    }

    private var hasOpenDocument: Bool {
        documents.editorController != nil
            || documents.videoEditorController != nil
            || documents.guideEditorController != nil
    }

    private var preferredMainWindowMinimumContentSize: CGSize {
        if documents.guideEditorController != nil {
            MainWindowLayout.minimumContentSize(for: .guide)
        } else if documents.videoEditorController != nil {
            MainWindowLayout.minimumContentSize(for: .video)
        } else {
            MainWindowLayout.minimumContentSize
        }
    }

    private var compactPermissionStrip: some View {
        Button {
            isPermissionDiagnosticExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .foregroundStyle(.orange)
                Text("Screenshot capture unavailable")
                    .font(.caption.weight(.medium))
                Spacer(minLength: 8)
                Text(isPermissionDiagnosticExpanded ? "Hide Setup" : "Set Up")
                    .font(.caption.weight(.semibold))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Screenshot capture unavailable")
        .accessibilityHint(isPermissionDiagnosticExpanded ? "Collapse permission diagnostics." : "Expand permission setup and diagnostics.")
        .accessibilityIdentifier("capture.permission.compactStrip")
    }

    private var captureHeaderIdentity: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                captureHeaderTitle
                captureStatusBadge

                if capture.isWorking || isRecordingVideo {
                    headerWorkingIndicator
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                captureHeaderTitle
                HStack(spacing: 8) {
                    captureStatusBadge
                    if capture.isWorking || isRecordingVideo {
                        headerWorkingIndicator
                    }
                }
            }
        }
    }

    private var captureHeaderTitle: some View {
        Text(AppBranding.displayName)
            .font(.title3.bold())
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }

    private var captureStatusBadge: some View {
        Label(permissionStatusTitle, systemImage: permissionStatusSystemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(permissionStatusTint.opacity(0.16), in: .capsule)
            .overlay {
                Capsule()
                    .strokeBorder(permissionStatusTint.opacity(0.55), lineWidth: 1)
            }
            .help(headerCaptureReady ? "Capture permissions are ready." : permissionCalloutSummary)
    }

    private var autoCopyToggle: some View {
        Toggle("Auto Copy", isOn: $clipboard.autoCopyEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.subheadline.weight(.semibold))
            .fixedSize()
            .help("Automatically copy the current rendered snip after captures and editor changes.")
    }

    private var captureHeaderOptions: some View {
        HStack(spacing: 6) {
            discoveryTarget(.timer) {
                Menu {
                    CaptureTimerMenuContent(capture: capture)
                } label: {
                    headerActionLabel(
                        title: capture.captureDelay.shortLabel,
                        systemImage: "timer"
                    )
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .help("Choose how long to wait before capture begins.")
            }

            discoveryTarget(.cursor) {
                Button {
                    capture.screenshotIncludesCursor.toggle()
                } label: {
                    headerActionLabel(
                        title: capture.screenshotIncludesCursor
                            ? "Cursor On"
                            : "Cursor Off",
                        systemImage: "cursorarrow"
                    )
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .help("Add the cursor as an editable screenshot overlay where supported.")
                .accessibilityValue(capture.screenshotIncludesCursor ? "On" : "Off")
            }

            discoveryTarget(.privateCapture) {
                Button {
                    capture.updatePrivateCaptureEnabled(
                        !capture.privateCaptureEnabled
                    )
                } label: {
                    headerActionLabel(
                        title: capture.privateCaptureEnabled
                            ? "Private On"
                            : "Private Off",
                        systemImage: "shield"
                    )
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(capture.isWorking || isRecordingVideo || guide.isActive)
                .help("Keep new captures out of history, recovery, Clipboard History, and OCR indexing.")
                .accessibilityValue(capture.privateCaptureEnabled ? "On" : "Off")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture Options")
    }

    private var captureHeaderActions: some View {
        Group {
            if let controller = documents.editorController {
                editorSessionBar(controller)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    captureDiscoveryActionGroups
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()
                        .accessibilityHidden(true)

                    CaptureDiscoveryPreview(
                        item: selectedCaptureDiscovery
                    )
                    .frame(width: 430)
                    .frame(minHeight: 286)
                }
            }
        }
    }

    private var captureDiscoveryActionGroups: some View {
        VStack(alignment: .leading, spacing: 12) {
            quickCaptureActionGroup
            createSomethingActionGroup
            recordActionGroup
            screenToolsActionGroup
        }
    }

    private var quickCaptureActionGroup: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Quick Capture")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            captureActionRow {
                regionCaptureButton
                captureButton(
                    title: WorkflowVocabulary.Source.window,
                    systemImage: "rectangle.on.rectangle",
                    discoveryItem: .captureWindow,
                    action: captureWindowFromHeader
                )
                captureButton(
                    title: WorkflowVocabulary.Source.screen,
                    systemImage: "macwindow",
                    discoveryItem: .captureScreen,
                    action: capture.captureCurrentDisplay
                )
                if capabilities.isEnabled(.scrollingCapture) {
                    captureButton(
                        title: "Scroll",
                        systemImage: "scroll",
                        discoveryItem: .captureScrolling,
                        action: capture.captureScrollingArea
                    )
                }
                repeatLastCaptureButton
                capturePresetsMenu
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Capture")
        .accessibilityHint("Capture a Screenshot immediately from a live source, repeat, or preset.")
    }

    private var createSomethingActionGroup: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Create")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            captureActionRow {
                creationActionButton(
                    title: "Comparison",
                    systemImage: "square.split.2x1",
                    discoveryItem: .comparison,
                    goal: .comparison,
                    help: "Set up a Before and After Comparison."
                )
                creationActionButton(
                    title: "Steps",
                    systemImage: "list.number",
                    discoveryItem: .steps,
                    goal: .instructions(.addCaptures),
                    help: "Build numbered Steps from captures you add."
                )
                creationActionButton(
                    title: "Combined Image",
                    systemImage: "rectangle.3.group",
                    discoveryItem: .combinedImage,
                    goal: .combineImages,
                    help: "Arrange several captures or images as one result."
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Create")
    }

    private var recordActionGroup: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Record")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            captureActionRow {
                recordingActionButton(
                    title: WorkflowVocabulary.Source.region,
                    systemImage: "selection.pin.in.out",
                    discoveryItem: .recordRegion,
                    action: video.recordRegion,
                    help: "Record a selected region of the screen."
                )
                recordingActionButton(
                    title: WorkflowVocabulary.Source.window,
                    systemImage: "rectangle.on.rectangle",
                    discoveryItem: .recordWindow,
                    action: video.presentVideoWindowPicker,
                    help: "Choose a window to record."
                )
                recordingActionButton(
                    title: WorkflowVocabulary.Source.screen,
                    systemImage: "macwindow",
                    discoveryItem: .recordScreen,
                    action: video.recordCurrentDisplay,
                    help: "Record the configured display."
                )
                if capabilities.isEnabled(.guideCapture) {
                    guideButton
                }
                if capabilities.isEnabled(.connectedDeviceCapture) {
                    connectedDeviceRecordingActions
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Record")
        .onAppear {
            if capabilities.isEnabled(.connectedDeviceCapture) {
                capture.refreshConnectedDevices()
            }
        }
    }

    private var screenToolsActionGroup: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Screen Tools")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            captureActionRow {
                discoveryTarget(.screenRuler) {
                    Menu {
                        Button("New Horizontal Ruler") {
                            tools.presentScreenRuler(.horizontal)
                        }
                        Button("New Vertical Ruler") {
                            tools.presentScreenRuler(.vertical)
                        }
                        if tools.screenRulerCoordinator.hasActiveRulers {
                            Divider()
                            Button(
                                "Close All Screen Rulers",
                                action: tools.closeAllScreenRulers
                            )
                        }
                    } label: {
                        headerActionLabel(
                            title: "Screen Ruler",
                            systemImage: "ruler",
                            showsChevron: true
                        )
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .help("Add a horizontal or vertical ruler above other apps.")
                }

                discoveryTarget(.screenInspector) {
                    Button {
                        tools.toggleScreenInspector()
                    } label: {
                        headerActionLabel(
                            title: tools.screenInspectorCoordinator.isVisible
                                ? "Close Inspector"
                                : "Screen Inspector",
                            systemImage: "scope"
                        )
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .help("Inspect live pixels, colors, coordinates, and spacing.")
                    .accessibilityLabel(
                        tools.screenInspectorCoordinator.isVisible
                            ? "Close Screen Inspector"
                            : "Open Screen Inspector"
                    )
                }

                discoveryTarget(.clipboardHistory) {
                    Button(action: clipboard.showClipboardManager) {
                        headerActionLabel(
                            title: "Clipboard History",
                            systemImage: "clipboard"
                        )
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .help("Find copied text, links, files, images, and recent screenshots.")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screen Tools and Clipboard History")
    }

    private func captureActionRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content()
            }
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var regionCaptureButton: some View {
        discoveryTarget(.captureRegion) {
            Button(action: capture.captureRegion) {
                headerActionLabel(
                    title: WorkflowVocabulary.Source.region,
                    systemImage: "selection.pin.in.out"
                )
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(capture.isWorking || isRecordingVideo || guide.isActive)
            .help("Drag to capture a selected region of the screen.")
        }
    }

    private var repeatLastCaptureButton: some View {
        discoveryTarget(.repeatLast) {
            Button {
                capture.repeatLastCapture()
            } label: {
                headerActionLabel(
                    title: "Repeat Last",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(
                capture.isWorking
                    || isRecordingVideo
                    || guide.isActive
                    || !capture.canRepeatLastCapture
            )
            .help("Repeat Last Capture")
            .accessibilityLabel("Repeat Last Capture")
        }
    }

    private var capturePresetsMenu: some View {
        discoveryTarget(.presets) {
            Menu {
                CapturePresetMenuContent(
                    capture: capture,
                    video: video,
                    lifecycle: lifecycle
                )
            } label: {
                headerActionLabel(
                    title: "Presets",
                    systemImage: "slider.horizontal.3",
                    showsChevron: true
                )
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(capture.isWorking || isRecordingVideo || guide.isActive)
            .help("Run or manage a capture preset.")
            .accessibilityLabel("Capture Presets")
        }
    }

    private func creationActionButton(
        title: String,
        systemImage: String,
        discoveryItem: CaptureDiscoveryItem,
        goal: CreationGoal,
        help: String
    ) -> some View {
        discoveryTarget(discoveryItem) {
            Button {
                creation.presentQuickStart(
                    prefilledDraft: CreationDraft(goal: goal)
                )
            } label: {
                headerActionLabel(
                    title: title,
                    systemImage: systemImage
                )
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(capture.isWorking || isRecordingVideo || guide.isActive)
            .help(help)
            .accessibilityIdentifier("creation.\(creationActionIdentifier(for: goal))")
        }
    }

    private var contextualCreateButton: some View {
        Button {
            creation.presentQuickStart()
        } label: {
            Label("Create…", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(capture.isWorking || isRecordingVideo || guide.isActive)
        .help("Start a new Screenshot, Comparison, Steps, or Combined Image.")
        .accessibilityIdentifier("creation.present")
    }

    private func editorSessionBar(
        _ controller: EditorController
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                editorSessionIdentity(controller)
                editorSessionActions(controller)
            }

            VStack(alignment: .leading, spacing: 8) {
                editorSessionIdentity(controller)
                HStack(spacing: 8) {
                    editorSessionActions(controller)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(editorSessionTitle(controller))
        .accessibilityHint("Current workflow")
        .accessibilityIdentifier("capture.sessionBar")
    }

    private func editorSessionIdentity(
        _ controller: EditorController
    ) -> some View {
        Label(
            editorSessionTitle(controller),
            systemImage: controller.documentPurpose.systemImage
        )
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 4)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func editorSessionActions(
        _ controller: EditorController
    ) -> some View {
        if controller.workflowStage == .polishing {
            sessionPrimaryButton(
                "Back to Content",
                systemImage: "arrow.left"
            ) {
                controller.leavePolish()
                if controller.documentPurpose == .screenshot {
                    controller.setWorkspaceMode(.edit)
                } else {
                    controller.presentationInspectorTab = .layout
                    controller.setWorkspaceMode(.presentation)
                }
            }
        } else {
            switch controller.documentPurpose {
            case .screenshot:
                sessionAdditionMenu(
                    "Add…",
                    systemImage: "plus.rectangle.on.rectangle",
                    controller: controller
                )
                sessionPolishButton(controller)

            case .comparison:
                if controller.workflowStage == .awaitingComparisonAfter {
                    sessionAdditionMenu(
                        compositionAddActions(for: controller).canRepeat
                            ? String(
                                localized: "Repeat Last Capture for After"
                            )
                            : String(localized: "Capture After"),
                        systemImage: "camera.viewfinder",
                        controller: controller,
                        primarySource:
                            compositionAddActions(for: controller).canRepeat
                                ? .repeatLast
                                : .region
                    )
                } else {
                    sessionPrimaryButton(
                        "Review Changes",
                        systemImage: "rectangle.split.2x1"
                    ) {
                        openFocusedContent(controller)
                    }
                    sessionSecondaryButton(
                        "Recapture",
                        systemImage: "arrow.clockwise"
                    ) {
                        recaptureComparisonAfter(controller)
                    }
                    sessionPolishButton(controller)
                }

            case .steps:
                sessionAdditionMenu(
                    "Add Step",
                    systemImage: "plus.rectangle.on.rectangle",
                    controller: controller
                )
                sessionSecondaryButton(
                    "Order & Caption",
                    systemImage: "list.number"
                ) {
                    openFocusedContent(controller)
                }
                sessionPolishButton(controller)

            case .collection:
                sessionAdditionMenu(
                    "Add Image",
                    systemImage: "plus.rectangle.on.rectangle",
                    controller: controller
                )
                sessionSecondaryButton(
                    "Arrange",
                    systemImage: "rectangle.3.group"
                ) {
                    openFocusedContent(controller)
                }
                sessionPolishButton(controller)
            }
        }
    }

    private func sessionPrimaryButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(capture.isWorking)
        .accessibilityIdentifier("capture.session.primary")
    }

    private func sessionSecondaryButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(capture.isWorking)
    }

    private func sessionPolishButton(
        _ controller: EditorController
    ) -> some View {
        Button {
            enterPolish(controller)
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text("Polish")
                    if controller.hasStyledOutputConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                }
            } icon: {
                Image(systemName: "sparkles")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(capture.isWorking)
        .help(controller.polishConfigurationLabel)
        .accessibilityLabel("Polish")
        .accessibilityValue(controller.polishConfigurationLabel)
        .accessibilityIdentifier("capture.session.polish")
    }

    private func sessionAdditionMenu(
        _ title: String,
        systemImage: String,
        controller: EditorController,
        primarySource: ContextualCompositionAdditionSource = .region
    ) -> some View {
        let actions = compositionAddActions(for: controller)
        return Menu {
            sessionAdditionMenuContent(actions)
        } label: {
            Label(title, systemImage: systemImage)
        } primaryAction: {
            requestContextualAddition(primarySource)
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(capture.isWorking)
        .help(
            primarySource == .repeatLast
                ? "Repeat the Before capture to create After and continue the Comparison. Open the menu for another capture or image source."
                : "\(title) using Region. Open the menu for another capture or image source."
        )
        .accessibilityLabel(title)
        .accessibilityHint(
            primarySource == .repeatLast
                ? "Repeats the Before capture to create After and continue the Comparison. Open the menu for another source."
                : "Uses Region. Open the menu for another capture or image source."
        )
        .accessibilityIdentifier("capture.session.primary")
    }

    @ViewBuilder
    private func sessionAdditionMenuContent(
        _ actions: CompositionAddActions
    ) -> some View {
        Button(WorkflowVocabulary.Source.region, systemImage: "viewfinder") {
            requestContextualAddition(.region)
        }
        Button(WorkflowVocabulary.Source.window, systemImage: "macwindow") {
            requestContextualAddition(.window)
        }
        Button(
            "Frontmost \(WorkflowVocabulary.Source.window)",
            systemImage: "macwindow.on.rectangle"
        ) {
            requestContextualAddition(.frontmostWindow)
        }
        Button(
            WorkflowVocabulary.Source.screen,
            systemImage: "rectangle.inset.filled"
        ) {
            requestContextualAddition(.fullScreen)
        }
        Button("Repeat", systemImage: "arrow.clockwise") {
            requestContextualAddition(.repeatLast)
        }
        .disabled(!actions.canRepeat)

        Menu("Timer", systemImage: "timer") {
            ForEach(CaptureDelay.allCases) { delay in
                Button {
                    requestContextualAddition(.timedRegion(delay))
                } label: {
                    if actions.captureDelay == delay {
                        Label(delay.label, systemImage: "checkmark")
                    } else {
                        Text(delay.label)
                    }
                }
            }
        }

        if actions.addScrolling != nil {
            Button(
                "Scroll",
                systemImage: "arrow.up.and.down.text.horizontal"
            ) {
                requestContextualAddition(.scrolling)
            }
        }

        if !actions.connectedDevices.isEmpty {
            Menu(
                WorkflowVocabulary.Source.connectedDevice,
                systemImage: "iphone.gen3"
            ) {
                ForEach(actions.connectedDevices) { source in
                    Button(source.title) {
                        requestContextualAddition(
                            .connectedDevice(source.id)
                        )
                    }
                }
            }
        }

        if actions.addScreenInspector != nil {
            Button("Screen Inspector", systemImage: "scope") {
                requestContextualAddition(.screenInspector)
            }
        }

        Divider()

        Button(
            "Import Images…",
            systemImage: "photo.on.rectangle.angled"
        ) {
            requestContextualAddition(.importImages)
        }
        Button("Paste Image", systemImage: "doc.on.clipboard") {
            requestContextualAddition(.pasteImage)
        }
        if !actions.recentSnips.isEmpty || !actions.captureHistory.isEmpty {
            Menu(
                WorkflowVocabulary.Library.snipLibrary,
                systemImage: "books.vertical"
            ) {
                sessionHistorySourceMenu(
                    WorkflowVocabulary.Library.recentSnips,
                    systemImage: "clock",
                    sources: actions.recentSnips,
                    source: { .recentSnip($0, flattened: $1) }
                )
                sessionHistorySourceMenu(
                    WorkflowVocabulary.Library.snipHistory,
                    systemImage: "clock.arrow.circlepath",
                    sources: actions.captureHistory,
                    source: { .captureHistory($0, flattened: $1) }
                )
            }
        }
    }

    @ViewBuilder
    private func sessionHistorySourceMenu(
        _ title: String,
        systemImage: String,
        sources: [CompositionAddSourceAction],
        source: @escaping (
            UUID,
            Bool
        ) -> ContextualCompositionAdditionSource
    ) -> some View {
        if !sources.isEmpty {
            Menu(title, systemImage: systemImage) {
                ForEach(sources.prefix(20)) { entry in
                    if let entryID = UUID(uuidString: entry.id) {
                        Menu(entry.title) {
                            Button("Add Editable Items") {
                                requestContextualAddition(
                                    source(entryID, false)
                                )
                            }
                            Button("Add as Flattened Item") {
                                requestContextualAddition(
                                    source(entryID, true)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func editorSessionTitle(
        _ controller: EditorController
    ) -> String {
        controller.documentPurpose.sessionTitle(
            stage: controller.workflowStage,
            includedItemCount: controller.includedCompositionItemCount
        )
    }

    private func requestContextualAddition(
        _ source: ContextualCompositionAdditionSource = .region
    ) {
        NotificationCenter.default.post(
            name: .sssRequestContextualCaptureAddition,
            object: source
        )
    }

    private func openFocusedContent(
        _ controller: EditorController
    ) {
        controller.presentationInspectorTab = .layout
        switch controller.documentPurpose {
        case .screenshot:
            controller.setWorkflowStage(.editing)
            controller.setWorkspaceMode(.edit)
        case .comparison:
            controller.setWorkflowStage(
                controller.includedCompositionItemCount >= 2
                    ? .reviewingComparison
                    : .awaitingComparisonAfter
            )
            controller.setWorkspaceMode(.presentation)
        case .steps:
            controller.setWorkflowStage(.collecting)
            controller.setWorkspaceMode(.presentation)
        case .collection:
            controller.setWorkflowStage(.arranging)
            controller.setWorkspaceMode(.presentation)
        }
    }

    private func enterPolish(
        _ controller: EditorController
    ) {
        controller.enterPolish()
        if controller.presentationInspectorTab == .layout {
            controller.presentationInspectorTab = .style
        }
        controller.setWorkspaceMode(.presentation)
    }

    private func recaptureComparisonAfter(
        _ controller: EditorController
    ) {
        guard let itemID =
            controller.composition?.comparison.secondaryItemID
        else {
            requestContextualAddition()
            return
        }
        capture.captureRegion(
            intent: .replace(
                documentGenerationID: controller.documentGenerationID,
                itemID: itemID
            ),
            completionRole: .replacement
        )
    }

    private func showLayersWindow() {
        presentAppScene(id: AppSceneID.layersWindow, using: openWindow)
    }

    private func showUIMapWindow() {
        presentAppScene(id: AppSceneID.uiMapWindow, using: openWindow)
    }

    private var headerWorkingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(lifecycle.workingMessage)
                .font(.caption.weight(.medium))
                .foregroundStyle(isRecordingVideo ? .red : .secondary)
                .lineLimit(1)
        }
    }

    private var capturePresetNamingSheetBinding: Binding<Bool> {
        Binding(
            get: { capture.isShowingCapturePresetNamingSheet },
            set: { capture.isShowingCapturePresetNamingSheet = $0 }
        )
    }

    private var headerPermissionCallout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)

                Text(permissionCalloutSummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if headerMissingRequirements.count > 1 {
                    Button("Set Up Next", action: requestNextHeaderPermission)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(permissions.activePermissionRequest != nil)
                        .help("Set up the next missing macOS privacy permission for \(AppBranding.displayName).")
                }
            }

            ForEach(headerMissingRequirements) { requirement in
                missingPermissionRow(requirement)
            }

            if let guide = permissions.permissionSetupGuide {
                PermissionSetupGuideView(
                    guide: guide,
                    onOpenSettings: permissions.openPermissionSettingsFromGuide,
                    onRevealApp: permissions.revealAppForPermissionSetup,
                    onCopyPath: permissions.copyAppPathForPermissionSetup,
                    onCheckAgain: permissions.checkPermissionSetupGuideStatus,
                    onDone: permissions.dismissPermissionSetupGuide
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        }
    }

    private var emptyState: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if documents.hasRecoverableVideo {
                        videoRecoveryCard
                    }

                    windowCaptureCard

                    captureHistoryCard

                    recycleBinCard
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
    }

    private var videoRecoveryCard: some View {
        CaptureModeCard(
            title: "Recover Last Session",
            systemImage: "arrow.counterclockwise.circle",
            detail: "A Video with unsaved work was preserved when the app last closed."
        ) {
            HStack(spacing: 10) {
                Button("Recover Video", action: documents.recoverLastVideoSession)
                    .buttonStyle(.borderedProminent)
                Button("Discard Recovery", role: .destructive, action: documents.discardRecoverableVideo)
                Spacer()
            }
            .disabled(documents.isRecoveringVideo)
        }
    }

    private var windowCaptureCard: some View {
        CaptureModeCard(
            title: "Capture \(WorkflowVocabulary.Source.window)",
            systemImage: "rectangle.on.rectangle",
            detail: "Click a live window thumbnail to capture it directly, or use on-screen picking for crowded desktops."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button("Pick On Screen", action: capture.pickWindowOnScreen)
                        .buttonStyle(.glass)
                        .help("Hide this window and choose a window directly from an on-screen overlay.")

                    Button("Capture Frontmost", action: capture.captureFrontmostWindow)
                        .buttonStyle(.glass)
                        .help("Capture the frontmost shareable window immediately.")

                    Button("Refresh", action: capture.refreshAvailableWindowsOrRequestAccess)
                        .buttonStyle(.glass)
                        .help(
                            permissions.permissionStatus.hasScreenRecording
                            ? "Reload the list of available windows."
                            : "Set up macOS Screen Recording permission before window thumbnails can be shown."
                        )

                    Spacer(minLength: 8)

                    Toggle("Auto Refresh", isOn: $capture.autoRefreshWindowsEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .fixedSize()
                        .help("Refresh the available window list automatically while this view is visible. When off, \(AppBranding.displayName) still refreshes once when the app returns to the foreground.")
                }

                if !permissions.permissionStatus.hasScreenRecording {
                    Text("Screen Recording access is required before window thumbnails can be shown.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("Set Up", action: permissions.requestScreenRecordingAccess)
                        .buttonStyle(.glass)
                        .disabled(permissions.activePermissionRequest != nil)
                        .help("Set up macOS Screen Recording permission for \(AppBranding.displayName).")
                } else if capture.isLoadingWindowChoices && capture.availableWindows.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading available windows…")
                            .foregroundStyle(.secondary)
                    }
                } else if capture.availableWindows.isEmpty {
            Text("No shareable windows are currently available. Open an app window, then refresh.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(capture.availableWindows) { window in
                                CaptureWindowTileView(window: window) {
                                    capture.captureWindow(window)
                                }
                                .id("\(window.id)-\(capture.windowThumbnailRefreshGeneration)")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var captureHistoryCard: some View {
        CaptureModeCard(
            title: WorkflowVocabulary.Library.snipLibrary,
            systemImage: "text.magnifyingglass",
            detail: "Find Recent Snips and search Snip History. Annotation and recognized screenshot text can match a search without being shown in the results list."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("Search Snip History", text: captureHistorySearchBinding)
                        .textFieldStyle(.roundedBorder)

                    Button("View All") {
                        documents.presentSnipLibrary(
                            initialScope: .history,
                            searchQuery: documents.captureSearchQuery
                        )
                    }
                    .buttonStyle(.glass)
                    .help("Browse all Recent Snips, Snip History, and Recycle Bin screenshots without replacing the Capture workspace.")
                }

                Text(captureHistoryResultsLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if documents.allCaptureHistoryEntries.isEmpty {
                    Text(
                        "\(WorkflowVocabulary.Library.snipHistory) appears here after you have autosaves, recent snips, or saved checkpoints to search."
                    )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if visibleCaptureHistoryEntries.isEmpty {
                    Text("No Snip History items matched the current search.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Swift.Array(visibleCaptureHistoryEntries.prefix(3))) { (entry: DocumentHistoryEntry) in
                        HStack(alignment: .top, spacing: 14) {
                            Button {
                                presentCaptureHistoryPreview(
                                    entry,
                                    entries: visibleCaptureHistoryEntries
                                )
                            } label: {
                                DocumentPreviewThumbnailView(
                                    packageURL: entry.packageURL,
                                    thumbnailSize: CGSize(width: 112, height: 74),
                                    cornerRadius: 12
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Preview this screenshot without opening it.")
                            .accessibilityLabel("Preview Screenshot")

                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.libraryDisplayTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)

                                Text(entry.savedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(checkpointCountLabel(for: entry))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)

                            }

                            Spacer(minLength: 8)

                            VStack(spacing: 8) {
                                Button("Open") {
                                    documents.restoreHistoryEntry(entry)
                                }
                                .buttonStyle(.glass)
                                .help("Open this Snip History item in the editor.")

                                Button(role: .destructive) {
                                    documents.deleteCaptureHistorySession(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .buttonStyle(.glass)
                                .help("Delete this Snip History item and all of its checkpoints.")
                            }
                        }
                    }

                    if visibleCaptureHistoryEntries.count > 3 {
                        Button("View All Screenshots") {
                            documents.presentSnipLibrary(
                                initialScope: .history,
                                searchQuery: documents.captureSearchQuery
                            )
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
        }
    }

    private var visibleCaptureHistoryEntries: [DocumentHistoryEntry] {
        latestEntriesBySession(from: documents.filteredCaptureHistoryEntries)
    }

    private var captureHistoryResultsLabel: String {
        let query = documents.captureSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = visibleCaptureHistoryEntries.count

        guard !query.isEmpty else {
            return "Recent Snips, autosaves, and shelved snips from every session."
        }

        if count >= DocumentWorkflowConstants.captureHistorySearchLimit {
            return "\(count)+ Snip History items for \"\(query)\""
        }

        return count == 1
            ? "1 Snip History item for \"\(query)\""
            : "\(count) Snip History items for \"\(query)\""
    }

    private var captureHistorySearchBinding: Binding<String> {
        Binding(
            get: { documents.captureSearchQuery },
            set: { newValue in
                documents.captureSearchQuery = newValue
                documents.scheduleIndexedCaptureHistorySearch()
            }
        )
    }

    private func checkpointCountLabel(for entry: DocumentHistoryEntry) -> String {
        let count = documents.allCaptureHistoryEntries.filter { $0.sessionID == entry.sessionID }.count
        return count == 1 ? "1 checkpoint" : "\(count) checkpoints"
    }

    private func latestEntriesBySession(from entries: [DocumentHistoryEntry]) -> [DocumentHistoryEntry] {
        var seenSessionIDs: Set<UUID> = []

        return entries.filter { entry in
            seenSessionIDs.insert(entry.sessionID).inserted
        }
    }

    private var recycleBinCard: some View {
        CaptureModeCard(
            title: "Recycle Bin",
            systemImage: "trash",
            detail: "Deleted snips stay recoverable here until the Recycle Bin is emptied or retention expires."
        ) {
            HStack(spacing: 12) {
                Text(recycleBinSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Button("View Recycle Bin") {
                    documents.presentSnipLibrary(initialScope: .recycleBin)
                }
                .buttonStyle(.glass)
                .disabled(documents.recycleBinEntries.isEmpty)
                .help("Inspect deleted screenshots before restoring or permanently deleting them.")
            }
        }
    }

    private var recycleBinSummary: String {
        let count = documents.recycleBinEntries.count
        guard count > 0 else {
            return "No deleted screenshots."
        }
        let countLabel = count >= DocumentWorkflowConstants.recycleBinLimit
            ? "\(count)+"
            : "\(count)"
        return "\(countLabel) deleted screenshot\(count == 1 ? "" : "s") available to restore."
    }

    private func presentCaptureHistoryPreview(
        _ entry: DocumentHistoryEntry,
        entries: [DocumentHistoryEntry]
    ) {
        documents.presentHistoryPreview(
            HistoryPreviewRequest(
                contextTitle: WorkflowVocabulary.Library.snipHistory,
                entries: entries,
                selectedEntryID: entry.id,
                primaryAction: HistoryPreviewPrimaryAction(
                    title: "Open",
                    systemImage: "arrow.up.forward.app",
                    help: "Open this screenshot in the editor.",
                    perform: documents.restoreHistoryEntry
                ),
                onFloat: documents.floatHistoryReference
            )
        )
    }

    private func captureButton(
        title: String,
        systemImage: String,
        discoveryItem: CaptureDiscoveryItem,
        action: @escaping () -> Void
    ) -> some View {
        discoveryTarget(discoveryItem) {
            Button(action: action) {
                headerActionLabel(title: title, systemImage: systemImage)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(capture.isWorking || isRecordingVideo || guide.isActive)
            .help(captureButtonHelpText(for: title))
        }
    }

    private func captureWindowFromHeader() {
        presentWindowQuickCaptureMenu()
    }

    private func recordingActionButton(
        title: String,
        systemImage: String,
        discoveryItem: CaptureDiscoveryItem,
        action: @escaping () -> Void,
        help: String,
        allowsActiveDeviceSession: Bool = false
    ) -> some View {
        discoveryTarget(discoveryItem) {
            Button(action: action) {
                headerActionLabel(title: title, systemImage: systemImage)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(
                capture.isWorking
                    || isRecordingVideo
                    || guide.isActive
                    || (
                        capture.isConnectedDeviceSessionActive
                            && !allowsActiveDeviceSession
                    )
            )
            .help(help)
        }
    }

    @ViewBuilder
    private var connectedDeviceRecordingActions: some View {
        if capture.isConnectedDeviceSessionActive {
            recordingActionButton(
                title: "Device Active",
                systemImage: "iphone",
                discoveryItem: .connectedDevice,
                action: capture.presentConnectedDeviceSessionActiveMessage,
                help: "Close the current connected-device preview before starting another.",
                allowsActiveDeviceSession: true
            )
        } else if capture.isLoadingConnectedDevices {
            ProgressView()
                .controlSize(.small)
                .help("Looking for connected devices.")
                .accessibilityLabel("Looking for Connected Devices")
        } else if capture.connectedDevices.isEmpty {
            recordingActionButton(
                title: "Connected Device",
                systemImage: "iphone",
                discoveryItem: .connectedDevice,
                action: capture.presentConnectedDeviceEmptyState,
                help: capture.connectedDeviceEmptyStateMessage
            )
        } else {
            ForEach(capture.connectedDevices) { device in
                recordingActionButton(
                    title: device.displayName,
                    systemImage: "iphone",
                    discoveryItem: .connectedDevice,
                    action: { capture.recordConnectedDevice(device) },
                    help: "Open a live preview of \(device.displayName) and record it."
                )
            }
        }
    }

    private var guideButton: some View {
        discoveryTarget(.guide) {
            Button(action: guide.presentQuickStart) {
                headerActionLabel(
                    title: guideButtonTitle,
                    systemImage: guide.isActive ? "stop.circle.fill" : "list.number",
                    accent: .accentColor
                )
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(capture.isWorking || isRecordingVideo || guide.isFinishing || guide.isDiscarding)
            .help("Capture clicks, scrolling, and shortcuts as an editable step-by-step guide.")
        }
    }

    private var guideButtonTitle: String {
        if guide.isDiscarding { return "Discarding Guide…" }
        if guide.isFinishing { return "Finishing Guide…" }
        return guide.isActive
            ? "Stop Guide"
            : WorkflowVocabulary.Instructions.recordGuide
    }

    private func creationActionIdentifier(
        for goal: CreationGoal
    ) -> String {
        switch goal {
        case .screenshot:
            return "screenshot"
        case .comparison:
            return "comparison"
        case .instructions(.addCaptures):
            return "steps"
        case .instructions(.recordAsIWork):
            return "guide"
        case .combineImages:
            return "combinedImage"
        }
    }

    private func headerActionLabel(title: String, systemImage: String, accent: Color = .accentColor, showsChevron: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func discoveryTarget<Content: View>(
        _ item: CaptureDiscoveryItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .focused($focusedCaptureDiscovery, equals: item)
            .onHover { isInside in
                if isInside {
                    hoveredCaptureDiscovery = item
                } else if hoveredCaptureDiscovery == item {
                    hoveredCaptureDiscovery = nil
                }
            }
    }

    private func captureButtonHelpText(for title: String) -> String {
        switch title {
        case WorkflowVocabulary.Source.region:
            return "Drag to capture a selected region of the screen."
        case WorkflowVocabulary.Source.screen:
            return capture.screenshotFullscreenDisplayMode.detail
        case WorkflowVocabulary.Source.window:
            if capabilities.isEnabled(.uiMap), capture.uiMapEnabled {
                return "Open quick window capture choices. UI Map enabled for Window captures."
            }

            return "Open quick window capture choices."
        case "Scroll", "Scrolling":
            return "Capture a scrolling page, document, or list from a selected viewport."
        case "Repeat":
            return "Repeat the most recent capture mode with its last target when possible."
        default:
            return title
        }
    }

    private var permissionStatusTitle: String {
        if headerCaptureReady {
            return "Ready"
        }

        if !permissions.permissionStatus.hasScreenRecording {
            return "Access Needed"
        }

        return capabilities.isEnabled(.scrollingCapture) ? "Scroll Access Needed" : "Access Needed"
    }

    private var permissionStatusSystemImage: String {
        headerCaptureReady ? "checkmark.circle.fill" : "lock.trianglebadge.exclamationmark.fill"
    }

    private var permissionStatusTint: Color {
        headerCaptureReady ? .green : .orange
    }

    private var headerCaptureReady: Bool {
        permissions.permissionStatus.hasScreenRecording
    }

    private var headerMissingRequirements: [CapturePermissionRequirement] {
        permissions.permissionStatus.hasScreenRecording ? [] : [.screenRecording]
    }

    private var permissionCalloutSummary: String {
        let missingRequirements = headerMissingRequirements

        if permissions.screenRecordingSetupNeedsAttention,
           missingRequirements == [.screenRecording] {
            return "Restart \(AppBranding.displayName) to finish applying Screen Recording access."
        }

        if missingRequirements == [.screenRecording] {
            return "Screen Recording is required for captures, recordings, and live window thumbnails."
        }

        if capabilities.isEnabled(.scrollingCapture), missingRequirements == [.accessibility] {
            return "Accessibility is required for Scrolling Capture so \(AppBranding.displayName) can scroll the selected app while capturing."
        }

        if capabilities.isEnabled(.scrollingCapture) {
            return "Screen Recording is required for captures. Accessibility is also required for Scrolling Capture."
        }

        return "Screen Recording is required for captures, recordings, and live window thumbnails."
    }

    private func requestNextHeaderPermission() {
        guard let requirement = headerMissingRequirements.first else {
            return
        }

        permissions.requestPermission(requirement)
    }

    private func missingPermissionRow(_ requirement: CapturePermissionRequirement) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: requirement.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.title)
                    .font(.caption.weight(.semibold))

                Text(missingPermissionDescription(for: requirement))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if requirement == .screenRecording,
               permissions.screenRecordingSetupNeedsAttention {
                Button("Restart") {
                    AppTerminationController.shared.requestRestartWithoutConfirmation()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Restart \(AppBranding.displayName) without the normal quit confirmation so macOS applies Screen Recording access.")

                Button("Check Again") {
                    permissions.checkPermissionSetupGuideStatus()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            } else {
                Button("Set Up") {
                    permissions.requestPermission(requirement)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(permissions.activePermissionRequest != nil)
                .help("Set up macOS \(requirement.title) permission for \(AppBranding.displayName).")

                Button("Help") {
                    permissions.presentPermissionSetupGuide(for: requirement)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Show manual setup steps below if macOS does not list \(AppBranding.displayName).")
            }
        }
    }

    private func missingPermissionDescription(for requirement: CapturePermissionRequirement) -> String {
        return requirement.requiredFor
    }

    private func handlePendingDocumentOpenRequests() {
        let urls = PendingDocumentOpenRequests.drain()

        guard let firstURL = urls.first else {
            return
        }

        if urls.count > 1 {
            lifecycle.errorMessage = "\(AppBranding.displayName) can only open or import one file at a time. Opened \(firstURL.lastPathComponent)."
        }

        Task { @MainActor in
            guard await guide.prepareForConflictingAction(named: "opening another document") else { return }
            documents.openExternalFile(at: firstURL)
        }
    }

    private func handlePendingPasteboardImageImportRequests() {
        let requests = PendingPasteboardImageImportRequests.drain()

        guard let firstRequest = requests.first else {
            return
        }

        if requests.count > 1 {
            lifecycle.errorMessage = "\(AppBranding.displayName) can only import one shared image at a time."
        }

        documents.importImageFromPasteboard(
            named: firstRequest.pasteboardName,
            sourceName: firstRequest.sourceName
        )
    }

    private func handlePendingAutomationRequests() {
        let requests = PendingAutomationRequests.drain()
        guard !requests.isEmpty else {
            return
        }

        Task { @MainActor in
            for request in requests {
                await performAutomationRequest(request)
            }
        }
    }

}

private struct CompositionImportFailureDetailsView: View {
    let recovery: CompositionImportRecoveryState
    let retryFailed: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Import Details")
                        .font(.title3.weight(.semibold))
                    Text(recovery.summary)
                        .foregroundStyle(.secondary)
                }
            }

            List(recovery.failures) { failure in
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.url.lastPathComponent)
                        .font(.body.weight(.semibold))
                    Text(failure.reason)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(failure.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    String(
                        localized: "\(failure.url.lastPathComponent). \(failure.reason). Folder: \(failure.url.deletingLastPathComponent().path)"
                    )
                )
            }
            .accessibilityLabel("Failed Imports")

            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Retry Failed") {
                    retryFailed()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Close these details and retry every failed file at its original composition destination.")
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 340, idealHeight: 420)
    }
}

private struct CaptureModeCard<Content: View>: View {
    let title: String
    let systemImage: String
    let detail: String
    @ViewBuilder let content: Content

    init(title: String, systemImage: String, detail: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        InsetGroupBox(spacing: 16) {
            content
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label {
                    Text(title)
                        .font(.headline)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(Color.accentColor)
                }

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionSetupGuideView: View {
    let guide: PermissionSetupGuide
    let onOpenSettings: () -> Void
    let onRevealApp: () -> Void
    let onCopyPath: () -> Void
    let onCheckAgain: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: guide.requirement.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 44, height: 44)
                    .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Allow \(guide.requirement.title)")
                        .font(.title2.weight(.semibold))

                    Text(permissionIntro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                setupStep(firstSetupStep)
                setupStep("If \(guide.appName) is listed, turn it on.")
                setupStep("If it is still not listed, click the + button and choose the app shown below. Development builds may live inside Xcode DerivedData, so adding the exact running app matters.")
                setupStep(finalSetupStep)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Current app")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(guide.appPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 10) {
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.glass)

                Button("Reveal App", action: onRevealApp)
                    .buttonStyle(.glass)

                Button("Copy Path", action: onCopyPath)
                    .buttonStyle(.glass)

                Spacer(minLength: 12)

                Button("Check Again", action: onCheckAgain)
                    .buttonStyle(.glass)

                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        }
    }

    private var permissionIntro: String {
        switch guide.requirement {
        case .screenRecording:
            return "macOS needs this before \(AppBranding.displayName) can read screen pixels for captures, recordings, and live window thumbnails."
        case .accessibility:
            return "macOS needs this for Accessibility workflows such as Scrolling Capture and Window UI Map."
        }
    }

    private var firstSetupStep: String {
        switch guide.requirement {
        case .screenRecording:
            return "Use the macOS prompt's Open System Settings button, or click Open Settings here to go to Privacy & Security > Screen Recording."
        case .accessibility:
            return "Use the macOS prompt's Open System Settings button, or click Open Settings here to go to Privacy & Security > Accessibility."
        }
    }

    private var finalSetupStep: String {
        switch guide.requirement {
        case .screenRecording:
            return "Return here and click Check Again. If macOS still cannot give this running copy access, restart \(AppBranding.displayName) when prompted."
        case .accessibility:
            return "Return here and click Check Again."
        }
    }

    private func setupStep(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 2)

            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CapturePresetNamingSheetView: View {
    @ObservedObject var capture: CaptureWorkflowModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Save Capture Preset")
                    .font(.headline)

                Text("Save a repeatable capture workflow. You can open it for review, copy it, or export it directly to a folder.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                CapturePresetBadge(
                    symbolName: capture.pendingCapturePresetDraft?.symbolName,
                    tint: pendingTintBinding.wrappedValue,
                    size: 36
                )

                TextField("Preset name", text: $capture.capturePresetNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(save)
            }

            HStack {
                Menu("Icon: \(capture.pendingCapturePresetDraft?.symbolName ?? "Default")") {
                    Button("Default") { capture.updatePendingCapturePresetAppearance(symbolName: nil, tint: pendingTintBinding.wrappedValue) }
                    ForEach(presetSymbols, id: \.self) { symbol in
                        Button { capture.updatePendingCapturePresetAppearance(symbolName: symbol, tint: pendingTintBinding.wrappedValue) } label: {
                            Label {
                                Text(symbol)
                            } icon: {
                                CapturePresetBadge(symbolName: symbol, tint: pendingTintBinding.wrappedValue, size: 18)
                            }
                        }
                    }
                }
                Picker("Color", selection: pendingTintBinding) {
                    ForEach(CapturePresetTint.allCases) { tint in
                        CapturePresetTintLabel(
                            tint: tint,
                            symbolName: capture.pendingCapturePresetDraft?.symbolName
                        )
                        .tag(tint)
                    }
                }
                Menu("Shortcut: \(capture.pendingCapturePresetDraft?.hotKey.map { "⌘⇧\($0.label)" } ?? "None")") {
                    Button("No Shortcut") { capture.updatePendingCapturePresetHotKey(nil) }
                    ForEach(GlobalHotKeyKey.allCases) { key in
                        Button("⌘⇧\(key.label)") { capture.updatePendingCapturePresetHotKey(key) }
                    }
                }
            }

            Picker("When capture finishes", selection: pendingOutcomeBinding) {
                ForEach(CapturePresetOutcome.allCases) { outcome in
                    Text(outcome.label).tag(outcome)
                }
            }

            Text(pendingOutcomeBinding.wrappedValue.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if pendingOutcomeBinding.wrappedValue == .exportToFolder {
                HStack {
                    Text(pendingDestinationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Menu("Choose Folder") {
                        ForEach(ImageExportFormat.allCases) { format in
                            Button("\(format.label)…") {
                                capture.choosePendingCapturePresetExportDestination(format: format)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer()

                Button("Cancel") {
                    capture.cancelSavingCapturePreset()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .onAppear {
            isNameFocused = true
        }
    }

    private func save() {
        capture.commitCapturePresetName()
        dismiss()
    }

    private var pendingOutcomeBinding: Binding<CapturePresetOutcome> {
        Binding(
            get: { capture.pendingCapturePresetDraft?.outcome ?? .openInEditor },
            set: { capture.updatePendingCapturePresetOutcome($0) }
        )
    }

    private var pendingDestinationLabel: String {
        guard let destination = capture.pendingCapturePresetDraft?.exportDestination else {
            return "Choose a folder before saving this workflow."
        }

        return "\(destination.format.label) → \(destination.folderURL.lastPathComponent)"
    }

    private var pendingTintBinding: Binding<CapturePresetTint> {
        Binding(
            get: { capture.pendingCapturePresetDraft?.tint ?? .blue },
            set: { capture.updatePendingCapturePresetAppearance(symbolName: capture.pendingCapturePresetDraft?.symbolName, tint: $0) }
        )
    }

    private let presetSymbols = ["camera.viewfinder", "macwindow", "doc.text", "ladybug", "star"]
}

private struct CaptureRecoverySheetView: View {
    let recovery: CaptureRecovery
    let performAction: (CaptureRecoveryAction) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(recovery.title, systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)

            Text(recovery.message)
                .fixedSize(horizontal: false, vertical: true)

            Text("Your capture settings are still in place. Choose the quickest way to continue.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Not Now", action: dismiss)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                ForEach(recovery.actions, id: \.self) { action in
                    actionButton(for: action)
                }
            }
        }
        .padding(22)
    }

    @ViewBuilder
    private func actionButton(for action: CaptureRecoveryAction) -> some View {
        if action == recovery.actions.first {
            Button(label(for: action)) {
                performAction(action)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(label(for: action)) {
                performAction(action)
            }
            .buttonStyle(.bordered)
        }
    }

    private func label(for action: CaptureRecoveryAction) -> String {
        switch action {
        case .retryLastCapture: "Try Again"
        case .setUpScreenRecording: "Set Up Screen Recording"
        case .setUpAccessibility: "Set Up Accessibility"
        case .refreshWindows: "Refresh Windows"
        case .pickAnotherWindow: "Pick Another Window"
        case .captureFrontmostWindow: "Capture Frontmost"
        case .useCurrentDisplay: "Use Current Display"
        case .chooseDisplay: "Choose Display"
        case .captureVisibleArea: "Capture Visible Area"
        case .chooseAnotherArea: "Choose Another Area"
        case .keepPartialResult: "Keep Partial Result"
        case .openTroubleshooting: "Open Troubleshooting"
        }
    }
}
