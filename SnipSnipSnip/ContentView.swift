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
                    switch model.windowPickerMode {
                    case .videoRecording:
                        model.recordWindow(window)
                    case .capturePresetReplacement(let presetID):
                        model.isShowingWindowPicker = false
                        model.replaceWindowTargetAndCapturePreset(id: presetID, with: window)
                    case .screenshot:
                        model.captureWindow(window)
                    }
                    model.windowPickerMode = .screenshot
                },
                onPickOnScreen: {
                    switch model.windowPickerMode {
                    case .videoRecording:
                        model.pickWindowOnScreenForVideoRecording()
                    case .capturePresetReplacement(let presetID):
                        model.pickWindowOnScreenForPresetReplacement(id: presetID)
                    case .screenshot:
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
        .sheet(isPresented: $model.isShowingCapturePresetNamingSheet) {
            CapturePresetNamingSheetView(model: model)
                .frame(width: 420)
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

                if FeatureFlags.uiMapEnabled, shouldShowHeaderUIMapStatus {
                    headerUIMapStatusChip
                }

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

                if FeatureFlags.uiMapEnabled, shouldShowHeaderUIMapStatus {
                    headerUIMapStatusChip
                }

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
            capturePresetsMenu
            recordButton
        }
    }

    private var capturePresetsMenu: some View {
        Menu {
            CapturePresetMenuContent(model: model)
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

                if headerMissingRequirements.count > 1 {
                    Button("Grant Next", action: requestNextHeaderPermission)
                        .buttonStyle(SSSChromeButtonStyle())
                        .controlSize(.small)
                        .help("Open the next missing macOS privacy permission for SnipSnipSnip.")
                }
            }

            ForEach(headerMissingRequirements) { requirement in
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

    private var headerUIMapStatusChip: some View {
        Group {
            if model.editorController?.isProcessingUIMap == true {
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
                    systemImage: model.permissionStatus.hasScreenRecording ? "checkmark.shield" : "hand.raised.fill",
                    title: "Grant Capture Permissions",
                    detail: model.permissionStatus.hasScreenRecording
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
                    if !model.permissionStatus.hasScreenRecording {
                        Button("Grant Screen Recording", action: model.requestScreenRecordingAccess)
                            .buttonStyle(SSSChromeButtonStyle())
                            .help("Ask macOS to grant Screen Recording permission for SnipSnipSnip.")
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

    private var captureHistoryCard: some View {
        CaptureModeCard(
            title: "Search Capture History",
            systemImage: "text.magnifyingglass",
            detail: "Search labels, document names, annotations, and recognized text across captures, including recent unsaved snips."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Search captures", text: $model.captureSearchQuery)
                    .textFieldStyle(.roundedBorder)

                Text(captureHistoryResultsLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if model.allCaptureHistoryEntries.isEmpty {
                    Text("Capture history search appears here after you have autosaves, recent snips, or saved checkpoints to search.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if visibleCaptureHistoryEntries.isEmpty {
                    Text("No captures matched the current search.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(visibleCaptureHistoryEntries.prefix(8))) { entry in
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
                                    model.restoreHistoryEntry(entry)
                                }
                                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                                .help("Open this capture in the editor.")

                                Button(role: .destructive) {
                                    model.deleteCaptureHistorySession(entry)
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
        latestEntriesBySession(from: model.filteredCaptureHistoryEntries)
    }

    private var captureHistoryResultsLabel: String {
        let query = model.captureSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = visibleCaptureHistoryEntries.count

        guard !query.isEmpty else {
            return "Recent captures, autosaves, and shelved snips from every session."
        }

        return count == 1 ? "1 capture for \"\(query)\"" : "\(count) captures for \"\(query)\""
    }

    private func checkpointCountLabel(for entry: DocumentHistoryEntry) -> String {
        let count = model.allCaptureHistoryEntries.filter { $0.sessionID == entry.sessionID }.count
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
                .disabled(model.isConnectedDeviceSessionActive)
            Button("Record Window", action: model.presentVideoWindowPicker)
                .disabled(model.isConnectedDeviceSessionActive)
            Button("Record Fullscreen", action: model.recordCurrentDisplay)
                .disabled(model.isConnectedDeviceSessionActive)
            if FeatureFlags.connectedDeviceCaptureEnabled {
                Menu("Record Connected Device") {
                    ConnectedDeviceCaptureMenuContent(model: model, mode: .recording)
                }
            }
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
            if FeatureFlags.uiMapEnabled, model.uiMapEnabled {
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

        if !model.permissionStatus.hasScreenRecording {
            return "Access Needed"
        }

        return FeatureFlags.scrollingCaptureEnabled ? "Scroll Access Needed" : "Access Needed"
    }

    private var permissionStatusSystemImage: String {
        headerCaptureReady ? "checkmark.circle.fill" : "lock.trianglebadge.exclamationmark.fill"
    }

    private var permissionStatusTint: Color {
        headerCaptureReady ? .green : .orange
    }

    private var headerCaptureReady: Bool {
        model.permissionStatus.hasScreenRecording
    }

    private var shouldShowHeaderUIMapStatus: Bool {
        guard let controller = model.editorController else {
            return false
        }

        if controller.isProcessingUIMap {
            return true
        }

        return controller.capture.kind == .window && controller.uiMapSnapshot != nil
    }

    private var uiMapStatusTitle: String {
        if model.editorController?.isProcessingUIMap == true {
            return "UI Map Processing"
        }

        return "UI Map Captured"
    }

    private var uiMapStatusTint: Color {
        model.editorController?.isProcessingUIMap == true ? .orange : .blue
    }

    private var uiMapStatusHelp: String {
        if model.editorController?.isProcessingUIMap == true {
            return "Window UI Map metadata is being captured in the background."
        }

        return "This Window capture contains UI Map metadata."
    }

    private var headerMissingRequirements: [CapturePermissionRequirement] {
        model.permissionStatus.hasScreenRecording ? [] : [.screenRecording]
    }

    private var permissionCalloutSummary: String {
        let missingRequirements = headerMissingRequirements

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

    private func requestNextHeaderPermission() {
        guard let requirement = headerMissingRequirements.first else {
            return
        }

        model.requestPermission(requirement)
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

    private func missingPermissionDescription(for requirement: CapturePermissionRequirement) -> String {
        return requirement.requiredFor
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
        if FeatureFlags.scrollingCaptureEnabled && FeatureFlags.uiMapEnabled {
            return "SnipSnipSnip lives in the menu bar. Grant Screen Recording for capture pixels. Accessibility is only needed for Scrolling Capture and Window UI Map."
        }

        if FeatureFlags.uiMapEnabled {
            return "SnipSnipSnip lives in the menu bar. Grant Screen Recording for capture pixels. Accessibility is only needed for Window UI Map."
        }

        if FeatureFlags.scrollingCaptureEnabled {
            return "SnipSnipSnip lives in the menu bar. Grant Screen Recording for capture pixels. Accessibility is only needed for Scrolling Capture."
        }

        return "SnipSnipSnip lives in the menu bar. Grant Screen Recording for capture pixels, live window thumbnails, and recording."
    }

    private var grantedPermissionsDetail: String {
        if FeatureFlags.scrollingCaptureEnabled && FeatureFlags.uiMapEnabled {
            return "Screen Recording is enabled. Accessibility can be granted later for Scrolling Capture and Window UI Map."
        }

        if FeatureFlags.uiMapEnabled {
            return "Screen Recording is enabled. Accessibility can be granted later for Window UI Map."
        }

        if FeatureFlags.scrollingCaptureEnabled {
            return "Screen Recording is enabled. Accessibility can be granted later for Scrolling Capture."
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

private struct CapturePresetNamingSheetView: View {
    @ObservedObject var model: AppModel
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

            TextField("Preset name", text: $model.capturePresetNameDraft)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(save)

            HStack(spacing: 10) {
                Spacer()

                Button("Cancel") {
                    model.cancelSavingCapturePreset()
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
        model.commitCapturePresetName()
        dismiss()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(model: AppModel())
    }
}
