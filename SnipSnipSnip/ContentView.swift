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
    let capabilities: AppCapabilitySnapshot
    let workflowCoordinator: AppWorkflowCoordinator
    let dismissWelcomeCard: () -> Void
    let presentWindowQuickCaptureMenu: () -> Void
    let performAutomationRequest: (AutomationRequest) async -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    @State private var isPermissionDiagnosticExpanded = false

    private let windowRefreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isRecordingVideo: Bool {
        video.activeVideoRecording != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            captureHeader
            Divider()

            if let editorController = documents.editorController {
                EditorCommandBar(
                    controller: editorController,
                    onBack: documents.closeEditor,
                    onFloatReference: { documents.floatCurrentEditorReference(appearance: $0) },
                    onExportPNG: { documents.exportAnnotatedImage(as: .png, appearance: $0) },
                    onExportJPEG: { documents.exportAnnotatedImage(as: .jpeg, appearance: $0) },
                    onExportPDF: { documents.exportAnnotatedImage(as: .pdf, appearance: $0) },
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
                    dragOutPayloadProvider: { documents.promisedAnnotatedImagePayload(appearance: $0) }
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
                        historyEntries: documents.historyEntries,
                        recentSnipEntries: documents.recentSnipEntries,
                        captureHistoryEntries: documents.allCaptureHistoryEntries,
                        recycleBinEntries: documents.recycleBinEntries,
                        captureSearchQuery: captureHistorySearchBinding,
                        captureHistorySearchResultsLabel: documents.captureHistorySearchResultsLabel,
                        historyActions: EditorHistoryActions(
                            onRestoreHistoryEntry: documents.restoreHistoryEntry,
                            onRestoreRecentSnipEntry: documents.restoreRecentSnipEntry,
                            onFloatHistoryEntry: documents.floatHistoryReference,
                            onDeleteHistoryEntry: documents.deleteHistoryEntry,
                            onDeleteAllHistoryEntries: documents.deleteAllHistoryEntries,
                            onDeleteRecentSnipEntry: documents.deleteRecentSnipEntry,
                            onDeleteAllRecentSnipEntries: documents.deleteAllRecentSnipEntries,
                            onRestoreRecycledHistoryEntry: documents.restoreRecycledHistoryEntry,
                            onPermanentlyDeleteRecycledHistoryEntry: documents.permanentlyDeleteRecycledHistoryEntry,
                            onEmptyRecycleBin: documents.emptyRecycleBin
                        )
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
                    capture.isShowingWindowPicker = false
                    capture.windowPickerMode = .screenshot
                }
            )
        }
        .sheet(isPresented: $guide.isShowingQuickStart) {
            GuideQuickStartView(guide: guide, permissions: permissions)
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
                    autoCopyToggle
                }

                VStack(alignment: .leading, spacing: 8) {
                    captureHeaderIdentity
                    autoCopyToggle
                        .frame(maxWidth: .infinity, alignment: .trailing)
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

    private var captureHeaderActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                captureHeaderActionButtons
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    captureButton(title: "Region", systemImage: "selection.pin.in.out", action: capture.captureRegion)
                    captureButton(title: "Full", systemImage: "macwindow", action: capture.captureCurrentDisplay)
                    captureButton(title: "Window", systemImage: "rectangle.on.rectangle", action: captureWindowFromHeader)
                }

                HStack(spacing: 8) {
                    if capabilities.isEnabled(.scrollingCapture) {
                        captureButton(title: "Scroll", systemImage: "arrow.down.to.line", action: capture.captureScrollingArea)
                    }
                    captureButton(title: "Repeat", systemImage: "arrow.clockwise", action: capture.repeatLastCapture)
                        .disabled(!capture.canRepeatLastCapture)
                    capturePresetsMenu
                    if capabilities.isEnabled(.guideCapture) {
                        guideButton
                    }
                    recordButton
                }
            }
        }
    }

    @ViewBuilder
    private var captureHeaderActionButtons: some View {
        captureButton(title: "Region", systemImage: "selection.pin.in.out", action: capture.captureRegion)
        captureButton(title: "Full", systemImage: "macwindow", action: capture.captureCurrentDisplay)
        captureButton(title: "Window", systemImage: "rectangle.on.rectangle", action: captureWindowFromHeader)
        if capabilities.isEnabled(.scrollingCapture) {
            captureButton(title: "Scroll", systemImage: "arrow.down.to.line", action: capture.captureScrollingArea)
        }
        captureButton(title: "Repeat", systemImage: "arrow.clockwise", action: capture.repeatLastCapture)
            .disabled(!capture.canRepeatLastCapture)
        capturePresetsMenu
        if capabilities.isEnabled(.guideCapture) {
            guideButton
        }
        recordButton
    }

    private func showLayersWindow() {
        openWindow(id: AppSceneID.layersWindow)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.identifier?.rawValue == AppSceneID.layersWindow })?.makeKeyAndOrderFront(nil)
    }

    private func showUIMapWindow() {
        openWindow(id: AppSceneID.uiMapWindow)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.identifier?.rawValue == AppSceneID.uiMapWindow })?.makeKeyAndOrderFront(nil)
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

    private var capturePresetsMenu: some View {
        Menu {
            CapturePresetMenuContent(capture: capture, video: video, lifecycle: lifecycle)
        } label: {
            Label("Presets", systemImage: "star")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .help("Run saved screenshot capture presets or save the last capture as a preset.")
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
                    if lifecycle.showsWelcomeCard {
                        exploreCard
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

    private var exploreCard: some View {
        CaptureModeCard(
            title: "Explore More",
            systemImage: "sparkles",
            detail: "Your core capture setup is complete. More tools are ready when you need them."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(explorationFeatureNames.joined(separator: "  ·  "))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Open Help Guide") {
                        openWindow(id: AppSceneID.helpWindow)
                        NSApp.activate(ignoringOtherApps: true)
                    }

                    Button("Dismiss", action: dismissWelcomeCard)
                        .help("Hide this exploration card.")
                }
            }
        }
    }

    private var explorationFeatureNames: [String] {
        var names: [String] = []
        if capabilities.isEnabled(.guideCapture) { names.append("Guide") }
        if capabilities.isEnabled(.screenRecording) { names.append("Screen Recording") }
        if capabilities.isEnabled(.presentation) { names.append("Presentation") }
        if capabilities.isEnabled(.recovery) { names.append("Recovery") }
        if capabilities.isEnabled(.uiMap) { names.append("UI Map") }
        if capabilities.isEnabled(.automation) { names.append("Automation") }
        return names
    }

    private var windowCaptureCard: some View {
        CaptureModeCard(
            title: "Window Capture",
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

    private func recoveryCard(_ recoverySession: PendingRecoverySession) -> some View {
        CaptureModeCard(
            title: "Recover Last Session",
            systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            detail: "\(AppBranding.displayName) found an autosaved session from your last run."
        ) {
            HStack(alignment: .top, spacing: 16) {
                DocumentPreviewThumbnailView(
                    packageURL: recoverySession.latestEntry.packageURL,
                    thumbnailSize: CGSize(width: 180, height: 120),
                    cornerRadius: 16
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text(recoverySession.title)
                        .font(.headline)

                    Text("Last autosave: \(recoverySession.latestEntry.savedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if recoverySession.latestEntry.hasUnsavedChanges {
                        Text("This recovery includes unsaved changes.")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.orange)
                    }

                    HStack(spacing: 10) {
                        Button("Restore", action: documents.restorePendingRecovery)
                            .buttonStyle(.glass)
                            .help("Open the most recent autosaved session in the editor.")

                        Button("Dismiss", action: documents.dismissPendingRecovery)
                            .buttonStyle(.glass)
                            .help("Ignore this recovery session and remove the pending recovery prompt.")
                    }
                }
            }
        }
    }

    private var captureHistoryCard: some View {
        CaptureModeCard(
            title: "Search Capture History",
            systemImage: "text.magnifyingglass",
            detail: "Search labels, document names, annotations, and recognized text across captures, including recent unsaved snips."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Search captures", text: captureHistorySearchBinding)
                    .textFieldStyle(.roundedBorder)

                Text(captureHistoryResultsLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if documents.allCaptureHistoryEntries.isEmpty {
                    Text("Capture history search appears here after you have autosaves, recent snips, or saved checkpoints to search.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if visibleCaptureHistoryEntries.isEmpty {
                    Text("No captures matched the current search.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Swift.Array(visibleCaptureHistoryEntries.prefix(8))) { (entry: DocumentHistoryEntry) in
                        HStack(alignment: .top, spacing: 14) {
                            DocumentPreviewThumbnailView(
                                packageURL: entry.packageURL,
                                thumbnailSize: CGSize(width: 112, height: 74),
                                cornerRadius: 12
                            )

                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)

                                Text("\(entry.label) • \(entry.savedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(checkpointCountLabel(for: entry))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)

                                if let previewText = historyPreviewText(for: entry) {
                                    Text(previewText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer(minLength: 8)

                            VStack(spacing: 8) {
                                Button("Open") {
                                    documents.restoreHistoryEntry(entry)
                                }
                                .buttonStyle(.glass)
                                .help("Open this capture in the editor.")

                                Button(role: .destructive) {
                                    documents.deleteCaptureHistorySession(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .buttonStyle(.glass)
                                .help("Delete this capture and all of its checkpoints.")
                            }
                        }
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
            return "Recent captures, autosaves, and shelved snips from every session."
        }

        return count == 1 ? "1 capture for \"\(query)\"" : "\(count) captures for \"\(query)\""
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
            detail: "Deleted snips stay recoverable here until the recycle bin is emptied or retention expires."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(documents.recycleBinEntries.isEmpty ? "No deleted snips." : "\(documents.recycleBinEntries.count) deleted snip\(documents.recycleBinEntries.count == 1 ? "" : "s") available to restore.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    Button("Empty Now", role: .destructive, action: documents.emptyRecycleBin)
                        .buttonStyle(.glass)
                        .disabled(documents.recycleBinEntries.isEmpty)
                        .help("Permanently delete every item currently in the recycle bin.")
                }

                ForEach(Array(documents.recycleBinEntries.prefix(6))) { entry in
                    HStack(alignment: .top, spacing: 14) {
                        DocumentPreviewThumbnailView(
                            packageURL: entry.packageURL,
                            thumbnailSize: CGSize(width: 112, height: 74),
                            cornerRadius: 12
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)

                            Text(recycleBinDeletedLabel(for: entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Button("Restore") {
                            documents.restoreRecycledHistoryEntry(entry)
                        }
                        .buttonStyle(.glass)
                        .help("Restore this deleted snip and open it in the editor.")
                    }
                }
            }
        }
    }

    private func recycleBinDeletedLabel(for entry: DocumentHistoryEntry) -> String {
        guard let deletedAt = entry.deletedAt else {
            return "Deleted recently"
        }

        return "Deleted \(deletedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func historyPreviewText(for entry: DocumentHistoryEntry) -> String? {
        let previewText = entry.searchableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previewText.isEmpty else {
            return nil
        }

        return String(previewText.prefix(120))
    }

    private func captureButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            headerActionLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(capture.isWorking || isRecordingVideo || guide.isActive)
        .help(captureButtonHelpText(for: title))
    }

    private func captureWindowFromHeader() {
        presentWindowQuickCaptureMenu()
    }

    private var recordButton: some View {
        Menu {
            Button("Record Region", action: video.recordRegion)
                .disabled(capture.isConnectedDeviceSessionActive)
            Button("Record Window", action: video.presentVideoWindowPicker)
                .disabled(capture.isConnectedDeviceSessionActive)
            Button("Record Fullscreen", action: video.recordCurrentDisplay)
                .disabled(capture.isConnectedDeviceSessionActive)
            if capabilities.isEnabled(.connectedDeviceCapture) {
                Menu("Record Connected Device") {
                    ConnectedDeviceCaptureMenuContent(capture: capture, mode: .recording)
                }
            }
        } label: {
            headerActionLabel(title: "Record", systemImage: "record.circle", accent: .red, showsChevron: true)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.red)
        .disabled(capture.isWorking || isRecordingVideo || guide.isActive)
        .help("Start a screen video recording.")
    }

    private var guideButton: some View {
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

    private var guideButtonTitle: String {
        if guide.isDiscarding { return "Discarding Guide…" }
        if guide.isFinishing { return "Finishing Guide…" }
        return guide.isActive ? "Stop Guide" : "Guide"
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

    private func captureButtonHelpText(for title: String) -> String {
        switch title {
        case "Region":
            return "Drag to capture a selected region of the screen."
        case "Full", "Fullscreen", "Full Screen":
            return capture.screenshotFullscreenDisplayMode.detail
        case "Window":
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
