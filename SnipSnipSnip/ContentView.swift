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
    let capabilities: AppCapabilitySnapshot
    let workflowCoordinator: AppWorkflowCoordinator
    let dismissWelcomeCard: () -> Void
    let presentWindowQuickCaptureMenu: () -> Void
    let performAutomationRequest: (AutomationRequest) async -> Void
    @Environment(\.openURL) private var openURL

    private let windowRefreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isRecordingVideo: Bool {
        video.activeVideoRecording != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let videoController = documents.videoEditorController {
                VideoEditorToolbarView(
                    controller: videoController,
                    documentFilename: documents.currentDocumentFilename,
                    hasUnsavedChanges: documents.hasUnsavedChanges,
                    exportPreferences: video.exportPreferences,
                    onBack: documents.closeEditor,
                    onExportRequest: video.exportVideo(using:),
                    dragOutPayloadProvider: video.promisedVideoPayload
                )
                Divider()
            } else if documents.editorController != nil {
                EditorToolbarView(
                    controller: documents.editorController,
                    onBack: documents.closeEditor,
                    onFloatReference: documents.floatCurrentEditorReference,
                    onExportPNG: { documents.exportAnnotatedImage(as: .png) },
                    onExportJPEG: { documents.exportAnnotatedImage(as: .jpeg) },
                    onExportPDF: { documents.exportAnnotatedImage(as: .pdf) },
                    onCopyStyled: documents.copyCurrentEditorImageToClipboard,
                    onCopyPlain: documents.copyCurrentPlainEditorImageToClipboard,
                    onShare: documents.shareAnnotatedImage,
                    dragOutPayloadProvider: documents.promisedAnnotatedImagePayload
                )
                Divider()
            }

            Group {
                if let editorController = documents.editorController {
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
        .sheet(isPresented: capturePresetNamingSheetBinding) {
            CapturePresetNamingSheetView(capture: capture)
                .frame(width: 420)
        }
        .alert("Presentation Mode is Experimental", isPresented: $lifecycle.isShowingPresentationExperimentalNotice) {
            Button("Join Discord") {
                openURL(AppLinks.presentationFeedbackDiscord)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Presentation mode is still experimental. Join our Discord to share feedback about the feature.")
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
    }

    private var header: some View {
        GlassEffectContainer(spacing: 18) {
            VStack(spacing: 0) {
                headerPanel
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.thinMaterial)
    }

    private var headerPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    headerIntro
                    Spacer(minLength: 8)
                    headerUtilities
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 10) {
                        headerIntro
                        Spacer(minLength: 8)
                    }

                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        headerUtilities
                    }
                }
            }

            headerPrimaryActions

            if !headerCaptureReady {
                headerPermissionCallout
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .sssGlassSurface(cornerRadius: 18, tint: .white.opacity(0.06), shadowOpacity: 0.12)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
        }
    }

    private var headerIntro: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(AppBranding.displayName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)

                headerStatusSummary
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(AppBranding.displayName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)

                headerStatusSummary
            }
        }
    }

    private var headerStatusSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                headerStatusChip(
                    title: permissionStatusTitle,
                    systemImage: permissionStatusSystemImage,
                    tint: permissionStatusTint
                )

                if capabilities.isEnabled(.uiMap), shouldShowHeaderUIMapStatus {
                    headerUIMapStatusChip
                }

                if capture.isWorking || isRecordingVideo {
                    headerWorkingChip
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                headerStatusChip(
                    title: permissionStatusTitle,
                    systemImage: permissionStatusSystemImage,
                    tint: permissionStatusTint
                )

                if capabilities.isEnabled(.uiMap), shouldShowHeaderUIMapStatus {
                    headerUIMapStatusChip
                }

                if capture.isWorking || isRecordingVideo {
                    headerWorkingChip
                }
            }
        }
    }

    private var appTitle: some View {
        Text(AppBranding.displayName)
            .font(.headline.weight(.bold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
            .accessibilityAddTraits(.isHeader)
    }

    private var headerPrimaryActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                headerPrimaryActionButtons
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
                    recordButton
                }
            }
        }
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

    private var headerPrimaryActionButtons: some View {
        Group {
            captureButton(title: "Region", systemImage: "selection.pin.in.out", action: capture.captureRegion)
            captureButton(title: "Full", systemImage: "macwindow", action: capture.captureCurrentDisplay)
            captureButton(title: "Window", systemImage: "rectangle.on.rectangle", action: captureWindowFromHeader)
            if capabilities.isEnabled(.scrollingCapture) {
                captureButton(title: "Scroll", systemImage: "arrow.down.to.line", action: capture.captureScrollingArea)
            }
            captureButton(title: "Repeat", systemImage: "arrow.clockwise", action: capture.repeatLastCapture)
                .disabled(!capture.canRepeatLastCapture)
            capturePresetsMenu
            recordButton
        }
    }

    private var capturePresetsMenu: some View {
        Menu {
            CapturePresetMenuContent(capture: capture, video: video, lifecycle: lifecycle)
        } label: {
            Label("Presets", systemImage: "star")
        }
        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
        .help("Run saved screenshot capture presets or save the last capture as a preset.")
    }

    private var headerUtilities: some View {
        HStack(spacing: 12) {
            headerAutoCopyToggle
        }
    }

    private var capturePresetNamingSheetBinding: Binding<Bool> {
        Binding(
            get: { capture.isShowingCapturePresetNamingSheet },
            set: { capture.isShowingCapturePresetNamingSheet = $0 }
        )
    }

    private var headerAutoCopyToggle: some View {
        Toggle("Auto Copy", isOn: $clipboard.autoCopyEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.subheadline.weight(.semibold))
            .fixedSize()
        .help("Automatically copy the current rendered snip to the clipboard after each capture and after editor changes.")
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
                        .buttonStyle(SSSChromeButtonStyle())
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
        .sssGlassSurface(cornerRadius: 12, tint: .orange, shadowOpacity: 0.03)
    }

    private var headerWorkingChip: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text(lifecycle.workingMessage)
                .font(.caption.weight(.medium))
                .foregroundStyle(isRecordingVideo ? .red : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(isRecordingVideo ? .red : nil), in: .capsule)
    }

    private var headerUIMapStatusChip: some View {
        Group {
            if documents.editorController?.isProcessingUIMap == true {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)

                    Text(uiMapStatusTitle)
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular.tint(uiMapStatusTint), in: .capsule)
            } else {
                headerStatusChip(
                    title: uiMapStatusTitle,
                    systemImage: "rectangle.3.group",
                    tint: uiMapStatusTint
                )
            }
        }
        .help(uiMapStatusHelp)
    }

    private func headerStatusChip(title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular.tint(tint), in: .capsule)
    }

    private var emptyState: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    windowCaptureCard

                    captureHistoryCard

                    recycleBinCard
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
    }

    private var welcomeCard: some View {
        CaptureModeCard(
            title: "Quick Start",
            systemImage: "sparkles",
            detail: quickStartDetail
        ) {
            VStack(alignment: .leading, spacing: 16) {
                quickStartStep(
                    systemImage: permissions.permissionStatus.hasScreenRecording ? "checkmark.shield" : "hand.raised.fill",
                    title: "Set Up Capture Permissions",
                    detail: permissions.permissionStatus.hasScreenRecording
                        ? allowedPermissionsDetail
                        : permissionCalloutSummary
                )

                quickStartStep(
                    systemImage: "keyboard",
                    title: "Capture From Anywhere",
                    detail: "Use the app shortcuts while \(AppBranding.displayName) is active, use global hotkeys in the background, or trigger capture from the menu bar extra."
                )

                quickStartStep(
                    systemImage: "bolt.badge.clock",
                    title: "Edit Immediately",
                    detail: "Each capture opens in the layered editor so you can annotate, redact, save, export, or search older captures from the inspector."
                )

                HStack(spacing: 10) {
                    if !permissions.permissionStatus.hasScreenRecording {
                        Button("Set Up", action: permissions.requestScreenRecordingAccess)
                            .buttonStyle(SSSChromeButtonStyle())
                            .disabled(permissions.activePermissionRequest != nil)
                            .help("Set up macOS Screen Recording permission for \(AppBranding.displayName).")
                    }

                    Button("Dismiss", action: dismissWelcomeCard)
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                        .help("Hide this quick-start card.")

                    Spacer(minLength: 8)

                    Text(clipboard.autoCopyEnabled ? "Auto Copy is enabled by default." : "Auto Copy is currently off.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(quickStartShortcutEntries) { entry in
                        shortcutRow(key: entry.keys, action: entry.action)
                    }
                }
            }
        }
    }

    private var quickStartShortcutEntries: [ShortcutCatalogEntry] {
        let appOpen = AppShortcut.catalogSections
            .first { $0.title == "App" }?
            .entries
            .first { $0.action == "Open SnipSnipSnip" }
        let captures = AppShortcut.catalogSections
            .first { $0.title == "Default Global Capture" }
            .map { Array($0.entries.prefix(5)) } ?? []

        return [appOpen].compactMap { $0 } + captures
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
                        .buttonStyle(SSSChromeButtonStyle())
                        .help("Hide this window and choose a window directly from an on-screen overlay.")

                    Button("Capture Frontmost", action: capture.captureFrontmostWindow)
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                        .help("Capture the frontmost shareable window immediately.")

                    Button("Refresh", action: capture.refreshAvailableWindowsOrRequestAccess)
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
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
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
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
                            .buttonStyle(SSSChromeButtonStyle())
                            .help("Open the most recent autosaved session in the editor.")

                        Button("Dismiss", action: documents.dismissPendingRecovery)
                            .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
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
                                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                                .help("Open this capture in the editor.")

                                Button(role: .destructive) {
                                    documents.deleteCaptureHistorySession(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
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
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
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
                        .buttonStyle(SSSChromeButtonStyle())
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

    private func quickStartStep(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .glassEffect(.regular.tint(.accentColor), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }


    private func shortcutRow(key: String, action: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))

            Text(AppBranding.branded(action))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func captureButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            headerActionLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(SSSChromeButtonStyle())
        .controlSize(.small)
        .disabled(capture.isWorking || isRecordingVideo)
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
        .buttonStyle(SSSChromeButtonStyle(tint: .red))
        .controlSize(.small)
        .tint(.red)
        .disabled(capture.isWorking || isRecordingVideo)
        .help("Start a screen video recording.")
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
        case "Full", "Fullscreen":
            return "Capture the full desktop across connected displays."
        case "Window":
            if capabilities.isEnabled(.uiMap), capture.uiMapEnabled {
                return "Open quick window capture choices. UI Map enabled for Window captures."
            }

            return "Open quick window capture choices."
        case "Scroll":
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

    private var shouldShowHeaderUIMapStatus: Bool {
        guard let controller = documents.editorController else {
            return false
        }

        if controller.isProcessingUIMap {
            return true
        }

        return controller.capture.kind == .window && controller.uiMapSnapshot != nil
    }

    private var uiMapStatusTitle: String {
        if documents.editorController?.isProcessingUIMap == true {
            return "UI Map Processing"
        }

        return "UI Map Captured"
    }

    private var uiMapStatusTint: Color {
        documents.editorController?.isProcessingUIMap == true ? .orange : .blue
    }

    private var uiMapStatusHelp: String {
        if documents.editorController?.isProcessingUIMap == true {
            return "Window UI Map metadata is being captured in the background."
        }

        return "This Window capture contains UI Map metadata."
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
                .buttonStyle(SSSChromeButtonStyle())
                .controlSize(.small)
                .help("Restart \(AppBranding.displayName) without the normal quit confirmation so macOS applies Screen Recording access.")

                Button("Check Again") {
                    permissions.checkPermissionSetupGuideStatus()
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .controlSize(.small)
            } else {
                Button("Set Up") {
                    permissions.requestPermission(requirement)
                }
                .buttonStyle(SSSChromeButtonStyle())
                .controlSize(.small)
                .disabled(permissions.activePermissionRequest != nil)
                .help("Set up macOS \(requirement.title) permission for \(AppBranding.displayName).")

                Button("Help") {
                    permissions.presentPermissionSetupGuide(for: requirement)
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
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

        documents.openExternalFile(at: firstURL)
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

    private var quickStartDetail: String {
        if capabilities.isEnabled(.scrollingCapture) && capabilities.isEnabled(.uiMap) {
            return "\(AppBranding.displayName) lives in the menu bar. Screen Recording enables capture pixels. Accessibility is only needed for Scrolling Capture and Window UI Map."
        }

        if capabilities.isEnabled(.uiMap) {
            return "\(AppBranding.displayName) lives in the menu bar. Screen Recording enables capture pixels. Accessibility is only needed for Window UI Map."
        }

        if capabilities.isEnabled(.scrollingCapture) {
            return "\(AppBranding.displayName) lives in the menu bar. Screen Recording enables capture pixels. Accessibility is only needed for Scrolling Capture."
        }

        return "\(AppBranding.displayName) lives in the menu bar. Screen Recording enables capture pixels, live window thumbnails, and recording."
    }

    private var allowedPermissionsDetail: String {
        if capabilities.isEnabled(.scrollingCapture) && capabilities.isEnabled(.uiMap) {
            return "Screen Recording is enabled. Accessibility can be allowed later for Scrolling Capture and Window UI Map."
        }

        if capabilities.isEnabled(.uiMap) {
            return "Screen Recording is enabled. Accessibility can be allowed later for Window UI Map."
        }

        if capabilities.isEnabled(.scrollingCapture) {
            return "Screen Recording is enabled. Accessibility can be allowed later for Scrolling Capture."
        }

        return "Screen Recording is enabled for this Mac session."
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.16)), in: .rect(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .sssGlassSurface(cornerRadius: 22, tint: .white.opacity(0.04), shadowOpacity: 0.055)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
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
                    .glassEffect(.regular.tint(.orange), in: .rect(cornerRadius: 12))

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
                    .glassEffect(.regular, in: .rect(cornerRadius: 8))
            }

            HStack(spacing: 10) {
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(SSSChromeButtonStyle())

                Button("Reveal App", action: onRevealApp)
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))

                Button("Copy Path", action: onCopyPath)
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))

                Spacer(minLength: 12)

                Button("Check Again", action: onCheckAgain)
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))

                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
            }
        }
        .padding(12)
        .sssGlassSurface(cornerRadius: 10, tint: .orange, shadowOpacity: 0.03)
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

                Text("Name this preset so you can run the same screenshot capture again from the Presets menu.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Preset name", text: $capture.capturePresetNameDraft)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(save)

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
}
