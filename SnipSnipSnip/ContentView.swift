import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    private let windowRefreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let videoController = model.videoEditorController {
                VideoEditorToolbarView(
                    controller: videoController,
                    documentFilename: model.currentDocumentFilename,
                    hasUnsavedChanges: model.hasUnsavedChanges,
                    exportPreferences: model.videoExportPreferences,
                    onBack: model.closeEditor,
                    onExportRequest: model.exportVideo(using:),
                    dragOutPayloadProvider: model.promisedVideoPayload
                )
                Divider()
            } else if model.editorController != nil {
                EditorToolbarView(
                    controller: model.editorController,
                    onBack: model.closeEditor,
                    onFloatReference: model.floatCurrentEditorReference,
                    onExportPNG: { model.exportAnnotatedImage(as: .png) },
                    onExportJPEG: { model.exportAnnotatedImage(as: .jpeg) },
                    onExportPDF: { model.exportAnnotatedImage(as: .pdf) },
                    onShare: model.shareAnnotatedImage,
                    dragOutPayloadProvider: model.promisedAnnotatedImagePayload
                )
                Divider()
            }

            Group {
                if let editorController = model.editorController {
                    EditorView(
                        controller: editorController,
                        historyEntries: model.historyEntries,
                        recentSnipEntries: model.recentSnipEntries,
                        captureHistoryEntries: model.allCaptureHistoryEntries,
                        recycleBinEntries: model.recycleBinEntries,
                        captureSearchQuery: $model.captureSearchQuery,
                        captureHistorySearchResultsLabel: model.captureHistorySearchResultsLabel,
                        historyActions: EditorHistoryActions(
                            onRestoreHistoryEntry: model.restoreHistoryEntry,
                            onRestoreRecentSnipEntry: model.restoreRecentSnipEntry,
                            onFloatHistoryEntry: model.floatHistoryReference,
                            onDeleteHistoryEntry: model.deleteHistoryEntry,
                            onDeleteAllHistoryEntries: model.deleteAllHistoryEntries,
                            onDeleteRecentSnipEntry: model.deleteRecentSnipEntry,
                            onDeleteAllRecentSnipEntries: model.deleteAllRecentSnipEntries,
                            onRestoreRecycledHistoryEntry: model.restoreRecycledHistoryEntry,
                            onPermanentlyDeleteRecycledHistoryEntry: model.permanentlyDeleteRecycledHistoryEntry,
                            onEmptyRecycleBin: model.emptyRecycleBin
                        ),
                        dragOutPayloadProvider: model.promisedAnnotatedImagePayload
                    )
                    .id(ObjectIdentifier(editorController))
                } else if let videoController = model.videoEditorController {
                    VideoEditorView(controller: videoController)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Save changes before continuing?", isPresented: $model.isShowingUnsavedChangesPrompt, titleVisibility: .visible) {
            Button("Save", action: model.confirmSaveBeforeContinuing)
            Button("Discard Changes", role: .destructive, action: model.discardChangesAndContinue)
            Button("Cancel", role: .cancel, action: model.cancelPendingEditorAction)
        } message: {
            Text("The current SnipSnipSnip document has unsaved changes.")
        }
        .sheet(isPresented: $model.isShowingWindowPicker) {
            CaptureWindowPickerView(
                windows: model.availableWindows,
                onSelect: { window in
                    if model.windowPickerMode == .videoRecording {
                        model.recordWindow(window)
                    } else {
                        model.captureWindow(window)
                    }
                    model.windowPickerMode = .screenshot
                },
                onPickOnScreen: {
                    if model.windowPickerMode == .videoRecording {
                        model.pickWindowOnScreenForVideoRecording()
                    } else {
                        model.pickWindowOnScreen()
                    }
                    model.windowPickerMode = .screenshot
                },
                onCancel: {
                    model.isShowingWindowPicker = false
                    model.windowPickerMode = .screenshot
                }
            )
        }
        .alert("Capture Error", isPresented: Binding(get: {
            model.errorMessage != nil
        }, set: { value in
            if !value {
                model.dismissError()
            }
        })) {
            Button("OK", role: .cancel) {
                model.dismissError()
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            model.refreshPermissions()
            model.refreshAvailableWindows()
            handlePendingDocumentOpenRequests()
            handlePendingPasteboardImageImportRequests()
        }
        .onAppear {
            model.mainWindowDidAppear()
        }
        .onDisappear {
            model.mainWindowDidDisappear()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sssPendingDocumentURLsDidChange)) { _ in
            handlePendingDocumentOpenRequests()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sssPendingPasteboardImageImportsDidChange)) { _ in
            handlePendingPasteboardImageImportRequests()
        }
        .onReceive(windowRefreshTimer) { _ in
            guard NSApp.isActive else {
                return
            }

            guard !model.isInteractiveCaptureActive else {
                return
            }

            model.refreshPermissions()

            guard model.autoRefreshWindowsEnabled,
                  model.editorController == nil,
                  !model.isWorking,
                  !model.isShowingWindowPicker,
                  model.permissionStatus.hasScreenRecording else {
                return
            }

            model.refreshAvailableWindows(
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

            if !model.permissionStatus.isCaptureReady {
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
                Text("SnipSnipSnip")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)

                headerStatusSummary
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("SnipSnipSnip")
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

                if model.isWorking || model.isRecordingVideo {
                    headerWorkingChip
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                headerStatusChip(
                    title: permissionStatusTitle,
                    systemImage: permissionStatusSystemImage,
                    tint: permissionStatusTint
                )

                if model.isWorking || model.isRecordingVideo {
                    headerWorkingChip
                }
            }
        }
    }

    private var appTitle: some View {
        Text("SnipSnipSnip")
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
                    captureButton(title: "Region", systemImage: "selection.pin.in.out", action: model.captureRegion)
                    captureButton(title: "Full", systemImage: "macwindow", action: model.captureCurrentDisplay)
                    captureButton(title: "Window", systemImage: "rectangle.on.rectangle", action: captureWindowFromHeader)
                }

                HStack(spacing: 8) {
                    if FeatureFlags.scrollingCaptureEnabled {
                        captureButton(title: "Scroll", systemImage: "arrow.down.to.line", action: model.captureScrollingArea)
                    }
                    captureButton(title: "Repeat", systemImage: "arrow.clockwise", action: model.repeatLastCapture)
                        .disabled(!model.canRepeatLastCapture)
                    recordButton
                }
            }
        }
    }

    private var headerWorkingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(model.workingMessage)
                .font(.caption.weight(.medium))
                .foregroundStyle(model.isRecordingVideo ? .red : .secondary)
                .lineLimit(1)
        }
    }

    private var headerPrimaryActionButtons: some View {
        Group {
            captureButton(title: "Region", systemImage: "selection.pin.in.out", action: model.captureRegion)
            captureButton(title: "Full", systemImage: "macwindow", action: model.captureCurrentDisplay)
            captureButton(title: "Window", systemImage: "rectangle.on.rectangle", action: captureWindowFromHeader)
            if FeatureFlags.scrollingCaptureEnabled {
                captureButton(title: "Scroll", systemImage: "arrow.down.to.line", action: model.captureScrollingArea)
            }
            captureButton(title: "Repeat", systemImage: "arrow.clockwise", action: model.repeatLastCapture)
                .disabled(!model.canRepeatLastCapture)
            recordButton
        }
    }

    private var headerUtilities: some View {
        HStack(spacing: 12) {
            headerAutoCopyToggle
        }
    }

    private var headerAutoCopyToggle: some View {
        Toggle("Auto Copy", isOn: $model.autoCopyEnabled)
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

                if model.permissionStatus.missingRequirements.count > 1 {
                    Button("Grant Next", action: model.requestMissingCapturePermissions)
                        .buttonStyle(SSSChromeButtonStyle())
                        .controlSize(.small)
                        .help("Open the next missing macOS privacy permission for SnipSnipSnip.")
                }
            }

            ForEach(model.permissionStatus.missingRequirements) { requirement in
                missingPermissionRow(requirement)
            }

            if let guide = model.permissionSetupGuide {
                PermissionSetupGuideView(
                    guide: guide,
                    onOpenSettings: model.openPermissionSettingsFromGuide,
                    onRevealApp: model.revealAppForPermissionSetup,
                    onCopyPath: model.copyAppPathForPermissionSetup,
                    onCheckAgain: model.checkPermissionSetupGuideStatus,
                    onDone: model.dismissPermissionSetupGuide
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

            Text(model.workingMessage)
                .font(.caption.weight(.medium))
                .foregroundStyle(model.isRecordingVideo ? .red : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(model.isRecordingVideo ? .red : nil), in: .capsule)
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

                    if !model.recentSnipEntries.isEmpty {
                        recentSnipsCard
                    }

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
                    systemImage: model.permissionStatus.isCaptureReady ? "checkmark.shield" : "hand.raised.fill",
                    title: "Grant Capture Permissions",
                    detail: model.permissionStatus.isCaptureReady
                        ? grantedPermissionsDetail
                        : permissionCalloutSummary
                )

                quickStartStep(
                    systemImage: "keyboard",
                    title: "Capture From Anywhere",
                    detail: "Use the app shortcuts while SnipSnipSnip is active, use global hotkeys in the background, or trigger capture from the menu bar extra."
                )

                quickStartStep(
                    systemImage: "bolt.badge.clock",
                    title: "Edit Immediately",
                    detail: "Each capture opens in the layered editor so you can annotate, redact, save, export, or search older captures from the inspector."
                )

                HStack(spacing: 10) {
                    if !model.permissionStatus.isCaptureReady {
                        Button("Grant Missing Access", action: model.requestMissingCapturePermissions)
                            .buttonStyle(SSSChromeButtonStyle())
                            .help("Open the next missing macOS privacy permission for SnipSnipSnip.")
                    }

                    Button("Dismiss", action: model.dismissWelcomeCard)
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                        .help("Hide this quick-start card.")

                    Spacer(minLength: 8)

                    Text(model.autoCopyEnabled ? "Auto Copy is enabled by default." : "Auto Copy is currently off.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    shortcutRow(key: "Command-Shift-O", action: "Open SnipSnipSnip")
                    shortcutRow(key: "Command-Shift-1", action: "Region")
                    shortcutRow(key: "Command-Shift-2", action: "Window")
                    shortcutRow(key: "Command-Shift-3", action: "Full Screen")
                    shortcutRow(key: "Command-Shift-4", action: "Frontmost Window")
                    shortcutRow(key: "Command-Shift-R", action: "Repeat Last Capture")
                }
            }
        }
    }

    private var windowCaptureCard: some View {
        CaptureModeCard(
            title: "Window Capture",
            systemImage: "rectangle.on.rectangle",
            detail: "Click a live window thumbnail to capture it directly, or use on-screen picking for crowded desktops."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button("Pick On Screen", action: model.pickWindowOnScreen)
                        .buttonStyle(SSSChromeButtonStyle())
                        .help("Hide this window and choose a window directly from an on-screen overlay.")

                    Button("Capture Frontmost", action: model.captureFrontmostWindow)
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                        .help("Capture the frontmost shareable window immediately.")

                    Button("Refresh") {
                        model.refreshAvailableWindows()
                    }
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                        .help("Reload the list of available windows.")

                    Spacer(minLength: 8)

                    Toggle("Auto Refresh", isOn: $model.autoRefreshWindowsEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .fixedSize()
                        .help("Refresh the available window list automatically while this view is visible. When off, SnipSnipSnip still refreshes once when the app returns to the foreground.")
                }

                if !model.permissionStatus.hasScreenRecording {
                    Text("Screen Recording access is required before window thumbnails can be shown.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("Grant Screen Recording Access", action: model.requestScreenRecordingAccess)
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                        .help("Open the macOS Screen Recording permission prompt for SnipSnipSnip.")
                } else if model.isLoadingWindowChoices && model.availableWindows.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading available windows…")
                            .foregroundStyle(.secondary)
                    }
                } else if model.availableWindows.isEmpty {
            Text("No shareable windows are currently available. Open an app window, then refresh.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(model.availableWindows) { window in
                                CaptureWindowTileView(window: window) {
                                    model.captureWindow(window)
                                }
                                .id("\(window.id)-\(model.windowThumbnailRefreshGeneration)")
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
            detail: "SnipSnipSnip found an autosaved session from your last run."
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
                        Button("Restore", action: model.restorePendingRecovery)
                            .buttonStyle(SSSChromeButtonStyle())
                            .help("Open the most recent autosaved session in the editor.")

                        Button("Dismiss", action: model.dismissPendingRecovery)
                            .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                            .help("Ignore this recovery session and remove the pending recovery prompt.")
                    }
                }
            }
        }
    }

    private var recentSnipsCard: some View {
        CaptureModeCard(
            title: "Recent Snips",
            systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            detail: "Unsaved snips stay available here when a new capture takes over the editor."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Spacer()

                    Button(role: .destructive, action: model.deleteAllRecentSnipEntries) {
                        Label("Clear Recent Snips", systemImage: "trash")
                    }
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                    .help("Delete every recent snip except the one currently open.")
                }

                ForEach(model.recentSnipEntries) { entry in
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

                            Text(entry.savedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(entry.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        VStack(spacing: 8) {
                            Button("Restore") {
                                model.restoreRecentSnipEntry(entry)
                            }
                            .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                            .help("Open this recent snip in the editor.")

                            Button(role: .destructive) {
                                model.deleteRecentSnipEntry(entry)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                            .help("Delete this recent snip.")
                        }
                    }
                }
            }
        }
    }

    private var captureHistoryCard: some View {
        CaptureModeCard(
            title: "Search Capture History",
            systemImage: "text.magnifyingglass",
            detail: "Search labels, document names, annotations, and recognized text across recent capture checkpoints."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Search captures", text: $model.captureSearchQuery)
                    .textFieldStyle(.roundedBorder)

                Text(model.captureHistorySearchResultsLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if model.allCaptureHistoryEntries.isEmpty {
                    Text("Capture history search appears here after you have autosaves, recent snips, or saved checkpoints to search.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if model.filteredCaptureHistoryEntries.isEmpty {
                    Text("No captures matched the current search.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.filteredCaptureHistoryEntries.prefix(8))) { entry in
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
                                    model.restoreHistoryEntry(entry)
                                }
                                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))

                                Button(role: .destructive) {
                                    model.deleteHistoryEntry(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                            }
                        }
                    }
                }
            }
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
                    Text(model.recycleBinEntries.isEmpty ? "No deleted snips." : "\(model.recycleBinEntries.count) deleted snip\(model.recycleBinEntries.count == 1 ? "" : "s") available to restore.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    Button("Empty Now", role: .destructive, action: model.emptyRecycleBin)
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                        .disabled(model.recycleBinEntries.isEmpty)
                        .help("Permanently delete every item currently in the recycle bin.")
                }

                ForEach(Array(model.recycleBinEntries.prefix(6))) { entry in
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
                            model.restoreRecycledHistoryEntry(entry)
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

            Text(action)
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
        .disabled(model.isWorking || model.isRecordingVideo)
        .help(captureButtonHelpText(for: title))
    }

    private func captureWindowFromHeader() {
        WindowCaptureQuickMenuPresenter.shared.present(for: model)
    }

    private var recordButton: some View {
        Menu {
            Button("Record Region", action: model.recordRegion)
            Button("Record Window", action: model.presentVideoWindowPicker)
            Button("Record Fullscreen", action: model.recordCurrentDisplay)
        } label: {
            headerActionLabel(title: "Record", systemImage: "record.circle", accent: .red, showsChevron: true)
        }
        .buttonStyle(SSSChromeButtonStyle(tint: .red))
        .controlSize(.small)
        .tint(.red)
        .disabled(model.isWorking || model.isRecordingVideo)
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
        if model.permissionStatus.isCaptureReady {
            return "Ready"
        }

        if !model.permissionStatus.hasScreenRecording {
            return "Access Needed"
        }

        return FeatureFlags.scrollingCaptureEnabled ? "Scroll Access Needed" : "Access Needed"
    }

    private var permissionStatusSystemImage: String {
        model.permissionStatus.isCaptureReady ? "checkmark.circle.fill" : "lock.trianglebadge.exclamationmark.fill"
    }

    private var permissionStatusTint: Color {
        model.permissionStatus.isCaptureReady ? .green : .orange
    }

    private var permissionCalloutSummary: String {
        let missingRequirements = model.permissionStatus.missingRequirements

        if missingRequirements == [.screenRecording] {
            return "Screen Recording is required for captures, recordings, and live window thumbnails."
        }

        if FeatureFlags.scrollingCaptureEnabled, missingRequirements == [.accessibility] {
            return "Accessibility is required for Scrolling Capture so SnipSnipSnip can scroll the selected app while capturing."
        }

        if FeatureFlags.scrollingCaptureEnabled {
            return "Screen Recording is required for captures. Accessibility is also required for Scrolling Capture."
        }

        return "Screen Recording is required for captures, recordings, and live window thumbnails."
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

                Text(requirement.requiredFor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Grant") {
                model.requestPermission(requirement)
            }
            .buttonStyle(SSSChromeButtonStyle())
            .controlSize(.small)
            .help("Ask macOS to grant \(requirement.title) permission for SnipSnipSnip.")

            Button("Help") {
                model.presentPermissionSetupGuide(for: requirement)
            }
            .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
            .controlSize(.small)
            .help("Show manual setup steps below if macOS does not list SnipSnipSnip.")
        }
    }

    private func handlePendingDocumentOpenRequests() {
        let urls = PendingDocumentOpenRequests.drain()

        guard let firstURL = urls.first else {
            return
        }

        if urls.count > 1 {
            model.errorMessage = "SnipSnipSnip can only open or import one file at a time. Opened \(firstURL.lastPathComponent)."
        }

        model.openExternalFile(at: firstURL)
    }

    private func handlePendingPasteboardImageImportRequests() {
        let requests = PendingPasteboardImageImportRequests.drain()

        guard let firstRequest = requests.first else {
            return
        }

        if requests.count > 1 {
            model.errorMessage = "SnipSnipSnip can only import one shared image at a time."
        }

        model.importImageFromPasteboard(
            named: firstRequest.pasteboardName,
            sourceName: firstRequest.sourceName
        )
    }

    private var quickStartDetail: String {
        if FeatureFlags.scrollingCaptureEnabled {
            return "SnipSnipSnip lives in the menu bar. Grant Screen Recording for capture pixels and Accessibility for Scrolling Capture."
        }

        return "SnipSnipSnip lives in the menu bar. Grant Screen Recording for capture pixels, live window thumbnails, and recording."
    }

    private var grantedPermissionsDetail: String {
        if FeatureFlags.scrollingCaptureEnabled {
            return "Screen Recording and Accessibility are enabled for this Mac session."
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
                setupStep("Return here and click Check Again.")
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
            return "macOS needs this before SnipSnipSnip can read screen pixels for captures, recordings, and live window thumbnails."
        case .accessibility:
            return "macOS needs this before Scrolling Capture can scroll the selected app while SnipSnipSnip captures and stitches the viewport."
        }
    }

    private var firstSetupStep: String {
        switch guide.requirement {
        case .screenRecording:
            return "Open System Settings to Privacy & Security > Screen Recording."
        case .accessibility:
            return "Click Grant to trigger the macOS Accessibility prompt. Then use the prompt's Open System Settings button, or click Open Settings here to go to Privacy & Security > Accessibility."
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(model: AppModel())
    }
}
