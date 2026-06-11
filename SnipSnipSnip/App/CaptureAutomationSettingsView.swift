import AppKit
import SwiftUI

struct CaptureAutomationSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab: SettingsTab = .general
    @State private var isShowingResetDefaultsConfirmation = false
    @State private var launchAtLoginErrorMessage: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            SettingsTabContainer(
                title: "General",
                summary: "Capture shortcuts, naming defaults, and editor behavior stay together here."
            ) {
                Section("Startup") {
                    Toggle("Launch SnipSnipSnip at Login", isOn: launchAtLoginBinding)

                    HStack {
                        Label("Status", systemImage: model.launchAtLoginStatus.systemImage)
                        Spacer(minLength: 12)
                        Text(model.launchAtLoginStatus.stateLabel)
                            .foregroundStyle(launchAtLoginStatusColor)
                    }

                    SettingsHelpText(model.launchAtLoginStatus.detail)

                    if model.launchAtLoginStatus.needsSystemSettingsApproval || model.launchAtLoginStatus == .unavailable {
                        Button("Open Login Items in System Settings", action: model.openLaunchAtLoginSettings)
                    }
                }

                Section("Help & Onboarding") {
                    Button("Show Onboarding Again", action: model.requestOnboardingPresentation)
                    Button("Open Support on Discord") {
                        NSWorkspace.shared.open(AppLinks.supportDiscord)
                    }

                    SettingsHelpText("Replay onboarding whenever you want a guided walkthrough. Support requests and feature requests go through Discord.")
                }

                Section("Screenshot Capture") {
                    Toggle("Include Cursor as Editable Overlay", isOn: $model.screenshotIncludesCursor)
                    SettingsHelpText("When enabled, region, window, frontmost-window, fullscreen, and repeat screenshots add the current cursor as a movable, resizable, removable overlay. Scrolling Capture always excludes the cursor while stitching.")

                    Toggle("Enable Precision Region Controls", isOn: regionCaptureBinding(\.advancedControlsEnabled))
                    SettingsHelpText("Keep this off for the fastest drag-to-capture workflow. When enabled, region capture pauses after dragging so you can resize, type dimensions, lock aspect ratio, nudge with arrow keys, then press Return to capture.")

                    Picker("Fullscreen Screenshot", selection: $model.screenshotFullscreenDisplayMode) {
                        ForEach(ScreenshotFullscreenDisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    if model.screenshotFullscreenDisplayMode == .selectedDisplay {
                        Picker("Selected Display", selection: selectedScreenshotDisplayIDBinding) {
                            ForEach(availableDisplayOptions(preferredID: model.selectedScreenshotFullscreenDisplayID)) { option in
                                Text(option.name).tag(Optional(option.id))
                            }
                        }
                    }

                    SettingsHelpText(model.screenshotFullscreenDisplayMode.detail)

                    if FeatureFlags.uiMapEnabled {
                        Toggle("Enable UI Map for Window captures", isOn: uiMapBinding)
                        SettingsHelpText("Save available names, roles, identifiers, and locations of visible interface elements when capturing a window. Region, fullscreen, scrolling, recording, and connected-device captures do not include UI Map metadata.")

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pinned UI Map Overlay Defaults")
                                .font(.subheadline.weight(.semibold))

                            Toggle("Show outline", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsOutline))
                            Toggle("Show label", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsLabel))
                            Toggle("Show identifier", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsIdentifier))
                            Toggle("Show role", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsRole))
                            Toggle("Show coordinates", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsCoordinates))
                            Toggle("Show dimensions", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsDimensions))
                        }

                        SettingsHelpText("Choose which details are shown by default when pinned UI Map elements are rendered on copied, shared, or exported screenshots.")

                        if model.windowUIMapNeedsAccessibilityAccess {
                            HStack(alignment: .firstTextBaseline) {
                                Label("Window UI Map needs Accessibility access before metadata can be captured.", systemImage: "lock.trianglebadge.exclamationmark.fill")
                                    .foregroundStyle(.orange)

                                Spacer()

                                Button("Grant Accessibility") {
                                    model.requestAccessibilityAccess()
                                }
                            }
                        }
                    }
                }

                Section("Screen Ruler") {
                    if model.screenRulerCoordinator.hasActiveRulers {
                        Button("Close All Screen Rulers", action: model.closeAllScreenRulers)
                    }

                    Toggle("Show Mouse Distance", isOn: screenRulerBinding(\.showsMouseDistance))
                    Toggle("Show Half Markers", isOn: screenRulerBinding(\.showsHalfMarkers))

                    Picker("Horizontal Tick Edge", selection: screenRulerBinding(\.horizontalTickEdge)) {
                        ForEach(ScreenRulerHorizontalTickEdge.allCases) { edge in
                            Text(edge.label).tag(edge)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Vertical Tick Edge", selection: screenRulerBinding(\.verticalTickEdge)) {
                        ForEach(ScreenRulerVerticalTickEdge.allCases) { edge in
                            Text(edge.label).tag(edge)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Horizontal 0 Origin", selection: screenRulerBinding(\.horizontalOrigin)) {
                        ForEach(ScreenRulerHorizontalOrigin.allCases) { origin in
                            Text(origin.label).tag(origin)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Vertical 0 Origin", selection: screenRulerBinding(\.verticalOrigin)) {
                        ForEach(ScreenRulerVerticalOrigin.allCases) { origin in
                            Text(origin.label).tag(origin)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Opacity")
                        Spacer(minLength: 12)
                        Text(model.screenRulerPreferences.opacityDescription)
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: screenRulerOpacityBinding, in: 0.35...1, step: 0.01)

                    HStack {
                        Text("Tick Spacing")
                        Spacer(minLength: 12)
                        Text(model.screenRulerPreferences.tickSpacingDescription)
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: screenRulerTickSpacingBinding, in: 4...50, step: 1)

                    Stepper(value: screenRulerMajorTickBinding, in: 2...20, step: 1) {
                        Text("Major Tick Every: \(model.screenRulerPreferences.majorTickEvery)")
                    }

                    SettingsHelpText("Screen rulers are floating, resizable overlays. Click a ruler once to cycle through tick edge and zero-origin combinations, or set the default horizontal and vertical ruler positions here. Visible rulers are included in screenshots when the captured area contains them.")
                }

                Section("Screen Inspector") {
                    Button(model.screenInspectorCoordinator.isVisible ? "Show Screen Inspector" : "Open Screen Inspector", action: model.presentScreenInspector)

                    if model.screenInspectorCoordinator.isVisible {
                        Button("Close Screen Inspector", action: model.closeScreenInspector)
                    }

                    Picker("Zoom Level", selection: screenInspectorBinding(\.zoomLevel)) {
                        ForEach(ScreenInspectorZoomLevel.allCases) { zoomLevel in
                            Text(zoomLevel.label).tag(zoomLevel)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Show Pixel Grid", isOn: screenInspectorBinding(\.showsPixelGrid))
                    Toggle("Show Crosshair", isOn: screenInspectorBinding(\.showsCrosshair))

                    SettingsHelpText("Screen Inspector is a floating live magnifier that samples pixels under the cursor, shows coordinates and color values, and can stay visible while you work in other apps.")
                }

                Section("Naming") {
                    TextField("Filename Template", text: $model.screenshotFilenameTemplate)

                    SettingsHelpText("Filename tokens: {kind}, {source}, {width}, {height}, {format}, and date patterns such as {yyyy-MM-dd-HH-mm-ss}.")
                }

                Section("Export & Sharing") {
                    Picker("Screenshot Format", selection: $model.screenshotDragOutFormat) {
                        ForEach(ImageExportFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("JPEG Quality")
                            Spacer(minLength: 12)
                            Text("\(Int(round(model.screenshotJPEGQuality * 100)))%")
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: screenshotJPEGQualityBinding, in: ImageExportOptions.minimumJPEGQuality...ImageExportOptions.maximumJPEGQuality, step: 0.01)
                    }

                    SettingsHelpText("Drag the file icon from the screenshot editor to share a rendered image. JPEG quality applies to Export JPEG and JPEG drag-out sharing. Transparent presentation shadows automatically use PNG so the styled result stays faithful.")
                }

                Section("Editor") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Crop Outside Dimming")
                            Spacer(minLength: 12)
                            Text(model.editorCropOutsideOverlayDimmingDescription)
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: cropOutsideOverlayAlphaBinding, in: 0...0.9, step: 0.01)

                        SettingsHelpText("Controls how dark the area outside the green crop box appears after the editor refocuses on a crop that is larger than the visible stage.")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show Out-of-Capture Crosshatch", isOn: outOfCapturePatternEnabledBinding)

                        HStack {
                            Text("Pattern Spacing")
                            Spacer(minLength: 12)
                            Text(model.editorOutOfCapturePatternSettings.spacingDescription)
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: outOfCapturePatternSpacingBinding, in: 16...96, step: 1)
                            .disabled(!model.editorOutOfCapturePatternSettings.isEnabled)

                        HStack {
                            Text("Line Opacity")
                            Spacer(minLength: 12)
                            Text(model.editorOutOfCapturePatternSettings.lineOpacityDescription)
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: outOfCapturePatternLineOpacityBinding, in: 0.05...0.9, step: 0.01)
                            .disabled(!model.editorOutOfCapturePatternSettings.isEnabled)

                        HStack {
                            Text("Dot Size")
                            Spacer(minLength: 12)
                            Text(model.editorOutOfCapturePatternSettings.dotDiameterDescription)
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: outOfCapturePatternDotDiameterBinding, in: 2...12, step: 1)
                            .disabled(!model.editorOutOfCapturePatternSettings.isEnabled)

                        HStack {
                            Text("Dot Opacity")
                            Spacer(minLength: 12)
                            Text(model.editorOutOfCapturePatternSettings.dotOpacityDescription)
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: outOfCapturePatternDotOpacityBinding, in: 0.05...1, step: 0.01)
                            .disabled(!model.editorOutOfCapturePatternSettings.isEnabled)

                        SettingsHelpText("The crosshatch marks canvas space outside the original captured image. It is editor-only and is never included when copying, exporting, sharing, or saving rendered output.")
                    }
                }
            }
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            .tag(SettingsTab.general)

            SettingsTabContainer(
                title: "Shortcuts",
                summary: "Global capture hotkeys and built-in keyboard shortcuts are centralized here."
            ) {
                Section("Global Capture Hotkeys") {
                    Toggle("Enable Global Capture Hotkeys", isOn: automationBinding(\.globalHotkeysEnabled))

                    ForEach(GlobalHotKeyAction.allCases, id: \.rawValue) { action in
                        Picker(action.label + " Hotkey", selection: automationHotKeyBinding(for: action)) {
                            ForEach(GlobalHotKeyKey.allCases) { key in
                                Text("Command-Shift-" + key.label).tag(key)
                            }
                        }
                    }

                    SettingsHelpText("Global hotkeys run while SnipSnipSnip is not frontmost, so the active app keeps those shortcuts when SnipSnipSnip is already focused.")
                }

                Section("Editor Shortcuts") {
                    Toggle("Enable Single-Key Tool Shortcuts", isOn: $model.editorSingleKeyToolShortcutsEnabled)
                    SettingsHelpText("Single-key tool shortcuts work only when the screenshot canvas has focus and text entry is not active.")
                }

                Section("Shortcut Reference") {
                    ShortcutCatalogListView(sections: AppShortcut.catalogSections)
                    SettingsHelpText("Default global capture hotkeys can be changed above. Built-in app and editor shortcuts are fixed in this version.")
                }
            }
            .tabItem {
                Label("Shortcuts", systemImage: "keyboard")
            }
            .tag(SettingsTab.shortcuts)

            SettingsTabContainer(
                title: "Recording",
                summary: "Video quality, frame rate, and optional capture sources are grouped here."
            ) {
                Section("Quality") {
                    Picker("Quality", selection: videoPreferenceBinding(\.quality)) {
                        ForEach(VideoRecordingQuality.allCases) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }

                    SettingsHelpText(model.videoRecordingPreferences.quality.detail)

                    Picker("Frame Rate", selection: videoPreferenceBinding(\.frameRate)) {
                        ForEach(VideoRecordingFrameRate.allCases) { frameRate in
                            Text(frameRate.label).tag(frameRate)
                        }
                    }
                }

                Section("Capture Sources") {
                    Picker("Fullscreen Recording", selection: videoPreferenceBinding(\.fullscreenDisplayMode)) {
                        ForEach(VideoRecordingFullscreenDisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    if model.videoRecordingPreferences.fullscreenDisplayMode == .selectedDisplay {
                        Picker("Selected Display", selection: selectedRecordingDisplayIDBinding) {
                            ForEach(availableDisplayOptions(preferredID: model.videoRecordingPreferences.selectedFullscreenDisplayID)) { option in
                                Text(option.name).tag(Optional(option.id))
                            }
                        }
                    }

                    Toggle("Record System Audio", isOn: videoPreferenceBinding(\.recordsSystemAudio))
                    Toggle("Record Microphone", isOn: videoPreferenceBinding(\.recordsMicrophone))
                    Toggle("Show Cursor", isOn: videoPreferenceBinding(\.showsCursor))
                    Toggle("Show Mouse Clicks", isOn: videoPreferenceBinding(\.showsMouseClicks))

                    SettingsHelpText("Microphone and system audio remain optional. macOS asks for the matching privacy permission the first time those sources are used.")
                    SettingsHelpText("Video export targets now live in the video editor Export menu, including MP4 quality or size targets and short GIF/APNG loop export.")
                }
            }
            .tabItem {
                Label("Recording", systemImage: "record.circle")
            }
            .tag(SettingsTab.recording)

            SettingsTabContainer(
                title: "Archive",
                summary: "History storage, size limits, and deleted-item cleanup live in one place."
            ) {
                Section("Archive History") {
                    SettingsHelpText("Archive history is local to this Mac. It stores editable .sss checkpoints, previews, searchable annotation text, and background OCR text unless Private Capture is enabled.")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Location")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(model.archiveLocationDescription)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Button("Choose Location…", action: model.chooseArchiveLocation)

                        Button("Use Default Location", action: model.resetArchiveLocationToDefault)
                            .disabled(model.usesDefaultArchiveLocation)

                        Button("Open in Finder", action: model.openArchiveLocationInFinder)
                    }

                    Stepper(value: Binding(get: {
                        model.archiveMaximumSizeMB
                    }, set: { value in
                        model.updateArchiveMaximumSizeMB(value)
                    }), in: AppModel.minimumArchiveMaximumSizeMB...10_240, step: 100) {
                        Text("Max Archive Size: \(model.archiveMaximumSizeMB) MB")
                    }

                    HStack {
                        Text("Current Size")
                        Spacer(minLength: 12)
                        Text(model.archiveSizeLabel)
                            .foregroundStyle(.secondary)
                    }

                    Button("Clear Archive", role: .destructive, action: model.clearArchive)

                    SettingsHelpText("SnipSnipSnip periodically trims the oldest archived checkpoints until the archive is back under the configured limit.")
                }

                Section("Recycle Bin") {
                    Stepper(value: Binding(get: {
                        model.recycleBinRetentionDays
                    }, set: { value in
                        model.updateRecycleBinRetentionDays(value)
                    }), in: AppModel.minimumRecycleBinRetentionDays...30, step: 1) {
                        Text("Empty Deleted Snips After: \(model.recycleBinRetentionDays) day\(model.recycleBinRetentionDays == 1 ? "" : "s")")
                    }

                    HStack {
                        Text("Deleted Items")
                        Spacer(minLength: 12)
                        Text("\(model.recycleBinEntries.count)")
                            .foregroundStyle(.secondary)
                    }

                    Button("Empty Now", role: .destructive, action: model.emptyRecycleBin)
                        .disabled(model.recycleBinEntries.isEmpty)

                    SettingsHelpText("Deleted snips move to the recycle bin first. The scheduled cleanup permanently removes items after the configured retention period; the default is 2 days.")
                }
            }
            .tabItem {
                Label("Archive", systemImage: "archivebox")
            }
            .tag(SettingsTab.archive)

            SettingsTabContainer(
                title: "Clipboard",
                summary: "Clipboard history, screenshot timeline entries, and ignored apps are configured here."
            ) {
                Section("History") {
                    Toggle("Enable Clipboard History", isOn: Binding(get: {
                        model.clipboardPreferences.isEnabled
                    }, set: { value in
                        model.updateClipboardHistoryEnabled(value)
                    }))

                    Stepper(value: Binding(get: {
                        model.clipboardPreferences.maxItemCount
                    }, set: { value in
                        model.updateClipboardMaxItemCount(value)
                    }), in: 10...1_000, step: 10) {
                        Text("Maximum Items: \(model.clipboardPreferences.maxItemCount)")
                    }

                    Stepper(value: Binding(get: {
                        model.clipboardPreferences.maxStorageMB
                    }, set: { value in
                        model.updateClipboardMaxStorageMB(value)
                    }), in: 25...5_120, step: 25) {
                        Text("Maximum Storage: \(model.clipboardPreferences.maxStorageMB) MB")
                    }

                    HStack {
                        Text("Saved Items")
                        Spacer(minLength: 12)
                        Text("\(model.clipboardHistoryItems.count)")
                            .foregroundStyle(.secondary)
                    }

                    Button("Clear Clipboard History", role: .destructive, action: model.clearClipboardHistory)
                        .disabled(model.clipboardHistoryItems.isEmpty)

                    SettingsHelpText("Clipboard history is local to this Mac. Non-private SnipSnipSnip screenshots are added to this timeline even when Auto Copy is off. Private Capture stays out of clipboard history.")
                }

                Section("Ignored Apps") {
                    SettingsHelpText("SnipSnipSnip skips concealed and transient clipboard types and ignores Apple Passwords plus common password managers by default.")

                    HStack(spacing: 10) {
                        Menu("Ignore Running App") {
                            if model.clipboardRunningAppIgnoreCandidates.isEmpty {
                                Text("No available running apps")
                            } else {
                                ForEach(model.clipboardRunningAppIgnoreCandidates) { app in
                                    Button(app.name) {
                                        model.addIgnoredClipboardApp(app)
                                    }
                                }
                            }
                        }

                        Button("Choose App...", action: model.chooseIgnoredClipboardApp)
                    }

                    if !model.clipboardRecentSourceAppIgnoreCandidates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent Sources")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(model.clipboardRecentSourceAppIgnoreCandidates.prefix(5)) { app in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                        Text(app.match)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 12)

                                    Button("Ignore") {
                                        model.addIgnoredClipboardApp(app)
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ignored")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(model.clipboardPreferences.ignoredApps) { app in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    Text(app.match)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 12)

                                Button("Remove") {
                                    model.removeIgnoredClipboardApp(app)
                                }
                            }
                        }
                    }

                    Button("Restore Default Ignored Apps", action: model.resetIgnoredClipboardApps)
                }
            }
            .tabItem {
                Label("Clipboard", systemImage: "clipboard")
            }
            .tag(SettingsTab.clipboard)

            SettingsTabContainer(
                title: "Privacy",
                summary: "Private capture, permissions, and settings recovery are kept together for faster troubleshooting."
            ) {
                Section("Private Capture") {
                    Toggle("Private Capture", isOn: privateCaptureBinding)
                        .disabled(!model.canChangePrivateCapture)

                    SettingsHelpText("Private Capture keeps the current capture out of archive history, recycle bin retention, and background OCR indexing. You can still explicitly save or export the result. The setting is locked while a capture or recording is active so the in-progress capture uses the privacy choice it started with.")
                }

                Section("Permission Diagnostics") {
                    PermissionStatusRow(requirement: .screenRecording, model: model)
                    if FeatureFlags.scrollingCaptureEnabled {
                        PermissionStatusRow(requirement: .accessibility, model: model)
                    }

                    Button("Export Diagnostics…", action: model.exportSupportDiagnostics)

                    SettingsHelpText(
                        FeatureFlags.scrollingCaptureEnabled
                            ? "Accessibility is only required for Scrolling Capture. Region, Window, Fullscreen, editor OCR, export, and annotation tools do not depend on Accessibility. Diagnostics export sanitized app, permission, display, storage, and status details without screenshots, clipboard contents, OCR text, annotations, or document data."
                            : "Screen Recording is the only privacy permission required for screenshot pixels, live window thumbnails, and screen recording in this build. Diagnostics export sanitized app, permission, display, storage, and status details without screenshots, clipboard contents, OCR text, annotations, or document data."
                    )
                }

                Section("Reset") {
                    Button("Reset All Settings to Defaults", role: .destructive) {
                        isShowingResetDefaultsConfirmation = true
                    }
                    .disabled(!model.canResetPreferencesToDefaults)

                    SettingsHelpText("This restores capture, shortcuts, recording, export and sharing, archive, recycle-bin, naming, and privacy settings to their default values. It does not delete archived captures or recycle-bin items.")
                }
            }
            .tabItem {
                Label("Privacy", systemImage: "hand.raised")
            }
            .tag(SettingsTab.privacy)
        }
        .frame(width: 700, height: 560)
        .task {
            model.refreshLaunchAtLoginStatus()
        }
        .alert("Couldn't Update Launch at Login", isPresented: Binding(get: {
            launchAtLoginErrorMessage != nil
        }, set: { isPresented in
            if !isPresented {
                launchAtLoginErrorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {
                launchAtLoginErrorMessage = nil
            }

            Button("Open Login Items") {
                model.openLaunchAtLoginSettings()
                launchAtLoginErrorMessage = nil
            }
        } message: {
            Text(launchAtLoginErrorMessage ?? "")
        }
        .confirmationDialog("Reset all settings to defaults?", isPresented: $isShowingResetDefaultsConfirmation, titleVisibility: .visible) {
            Button("Reset All Settings", role: .destructive) {
                model.resetPreferencesToDefaults()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This keeps your current documents and archive contents, but it restores settings values to their shipped defaults.")
        }
    }

    private func automationBinding<Value>(_ keyPath: WritableKeyPath<CaptureAutomationPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.automationPreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = model.automationPreferences
                preferences[keyPath: keyPath] = newValue
                model.automationPreferences = preferences
            }
        )
    }

    private func automationHotKeyBinding(for action: GlobalHotKeyAction) -> Binding<GlobalHotKeyKey> {
        Binding(
            get: { model.automationPreferences.key(for: action) },
            set: { newKey in
                var preferences = model.automationPreferences
                preferences.setKey(newKey, for: action)
                model.automationPreferences = preferences
            }
        )
    }

    private func regionCaptureBinding<Value>(_ keyPath: WritableKeyPath<RegionCapturePreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.regionCapturePreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = model.regionCapturePreferences
                preferences[keyPath: keyPath] = newValue
                model.regionCapturePreferences = preferences
            }
        )
    }

    private var privateCaptureBinding: Binding<Bool> {
        Binding(
            get: { model.privateCaptureEnabled },
            set: { newValue in
                model.updatePrivateCaptureEnabled(newValue)
            }
        )
    }

    private var uiMapBinding: Binding<Bool> {
        Binding(
            get: { model.uiMapEnabled },
            set: { newValue in
                model.updateUIMapEnabled(newValue)
            }
        )
    }

    private func uiMapPinnedOverlayDefaultsBinding(_ keyPath: WritableKeyPath<UIMapOverlayOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.uiMapPinnedOverlayDefaults[keyPath: keyPath] },
            set: { newValue in
                var options = model.uiMapPinnedOverlayDefaults
                options[keyPath: keyPath] = newValue
                model.uiMapPinnedOverlayDefaults = options
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLoginStatus.prefersEnabledToggle },
            set: { newValue in
                let result = model.updateLaunchAtLoginEnabled(newValue)

                if case let .failed(message) = result {
                    launchAtLoginErrorMessage = message
                }
            }
        )
    }

    private var launchAtLoginStatusColor: Color {
        switch model.launchAtLoginStatus {
        case .disabled:
            return .secondary
        case .enabled:
            return .green
        case .requiresApproval:
            return .orange
        case .unavailable:
            return .red
        }
    }

    private func videoPreferenceBinding<Value>(_ keyPath: WritableKeyPath<VideoRecordingPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.videoRecordingPreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = model.videoRecordingPreferences
                preferences[keyPath: keyPath] = newValue
                model.videoRecordingPreferences = preferences
            }
        )
    }

    private func screenRulerBinding<Value>(_ keyPath: WritableKeyPath<ScreenRulerPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.screenRulerPreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = model.screenRulerPreferences
                preferences[keyPath: keyPath] = newValue
                model.screenRulerPreferences = preferences
            }
        )
    }

    private func screenInspectorBinding<Value>(_ keyPath: WritableKeyPath<ScreenInspectorPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.screenInspectorPreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = model.screenInspectorPreferences
                preferences[keyPath: keyPath] = newValue
                model.screenInspectorPreferences = preferences
            }
        )
    }

    private var screenRulerOpacityBinding: Binding<Double> {
        Binding(
            get: { model.screenRulerPreferences.opacity },
            set: { newValue in
                var preferences = model.screenRulerPreferences
                preferences.opacity = newValue
                model.screenRulerPreferences = preferences
            }
        )
    }

    private var screenRulerTickSpacingBinding: Binding<Double> {
        Binding(
            get: { Double(model.screenRulerPreferences.tickSpacing) },
            set: { newValue in
                var preferences = model.screenRulerPreferences
                preferences.tickSpacing = CGFloat(newValue)
                model.screenRulerPreferences = preferences
            }
        )
    }

    private var screenRulerMajorTickBinding: Binding<Int> {
        Binding(
            get: { model.screenRulerPreferences.majorTickEvery },
            set: { newValue in
                var preferences = model.screenRulerPreferences
                preferences.majorTickEvery = newValue
                model.screenRulerPreferences = preferences
            }
        )
    }

    private var cropOutsideOverlayAlphaBinding: Binding<Double> {
        Binding(
            get: { Double(model.editorCropOutsideOverlayAlpha) },
            set: { newValue in
                model.updateEditorCropOutsideOverlayAlpha(CGFloat(newValue))
            }
        )
    }

    private var outOfCapturePatternEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.editorOutOfCapturePatternSettings.isEnabled },
            set: { newValue in
                var settings = model.editorOutOfCapturePatternSettings
                settings.isEnabled = newValue
                model.updateEditorOutOfCapturePatternSettings(settings)
            }
        )
    }

    private var outOfCapturePatternSpacingBinding: Binding<Double> {
        Binding(
            get: { Double(model.editorOutOfCapturePatternSettings.spacing) },
            set: { newValue in
                var settings = model.editorOutOfCapturePatternSettings
                settings.spacing = CGFloat(newValue)
                model.updateEditorOutOfCapturePatternSettings(settings)
            }
        )
    }

    private var outOfCapturePatternLineOpacityBinding: Binding<Double> {
        Binding(
            get: { Double(model.editorOutOfCapturePatternSettings.lineOpacity) },
            set: { newValue in
                var settings = model.editorOutOfCapturePatternSettings
                settings.lineOpacity = CGFloat(newValue)
                model.updateEditorOutOfCapturePatternSettings(settings)
            }
        )
    }

    private var outOfCapturePatternDotOpacityBinding: Binding<Double> {
        Binding(
            get: { Double(model.editorOutOfCapturePatternSettings.dotOpacity) },
            set: { newValue in
                var settings = model.editorOutOfCapturePatternSettings
                settings.dotOpacity = CGFloat(newValue)
                model.updateEditorOutOfCapturePatternSettings(settings)
            }
        )
    }

    private var outOfCapturePatternDotDiameterBinding: Binding<Double> {
        Binding(
            get: { Double(model.editorOutOfCapturePatternSettings.dotDiameter) },
            set: { newValue in
                var settings = model.editorOutOfCapturePatternSettings
                settings.dotDiameter = CGFloat(newValue)
                model.updateEditorOutOfCapturePatternSettings(settings)
            }
        )
    }

    private var screenshotJPEGQualityBinding: Binding<Double> {
        Binding(
            get: { Double(model.screenshotJPEGQuality) },
            set: { model.screenshotJPEGQuality = CGFloat($0) }
        )
    }

    private var selectedScreenshotDisplayIDBinding: Binding<UInt32?> {
        Binding(
            get: {
                let selectedID = model.selectedScreenshotFullscreenDisplayID
                let options = availableDisplayOptions(preferredID: selectedID)
                if let selectedID,
                   options.contains(where: { $0.id == selectedID }) {
                    return selectedID
                }

                return options.first?.id
            },
            set: { newValue in
                model.selectedScreenshotFullscreenDisplayID = newValue
            }
        )
    }

    private var selectedRecordingDisplayIDBinding: Binding<UInt32?> {
        Binding(
            get: {
                let selectedID = model.videoRecordingPreferences.selectedFullscreenDisplayID
                let options = availableDisplayOptions(preferredID: selectedID)
                if let selectedID,
                   options.contains(where: { $0.id == selectedID }) {
                    return selectedID
                }

                return options.first?.id
            },
            set: { newValue in
                var preferences = model.videoRecordingPreferences
                preferences.selectedFullscreenDisplayID = newValue
                model.videoRecordingPreferences = preferences
            }
        )
    }

    private func availableDisplayOptions(preferredID: UInt32?) -> [DisplayOption] {
        let screens = NSScreen.screens
        let options = screens.enumerated().compactMap { entry -> DisplayOption? in
            let (index, screen) = entry
            guard let displayID = screen.gscDisplayID else {
                return nil
            }

            return DisplayOption(id: displayID, name: screen.gscDisplayName + " (Display \(index + 1))")
        }

        if let preferredID,
           !options.contains(where: { $0.id == preferredID }) {
            return [DisplayOption(id: preferredID, name: "Previously Selected Display")] + options
        }

        return options
    }
}

private enum SettingsTab: Hashable {
    case general
    case shortcuts
    case recording
    case archive
    case clipboard
    case privacy
}

private struct DisplayOption: Identifiable {
    let id: UInt32
    let name: String
}

private struct ShortcutCatalogListView: View {
    let sections: [ShortcutCatalogSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(section.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.keys)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .frame(minWidth: 148, alignment: .leading)

                            Text(entry.action)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct SettingsTabContainer<Content: View>: View {
    let title: String
    let summary: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))

                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Form {
                content
            }
            .formStyle(.grouped)
        }
    }
}

private struct SettingsHelpText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

private struct PermissionStatusRow: View {
    let requirement: CapturePermissionRequirement
    @ObservedObject var model: AppModel

    private var hasAccess: Bool {
        model.permissionStatus.hasAccess(to: requirement)
    }

    var body: some View {
        HStack {
            Label(requirement.title, systemImage: requirement.systemImage)
            Spacer()
            Text(hasAccess ? "Granted" : "Missing")
                .foregroundStyle(hasAccess ? .green : .orange)
            Button(hasAccess ? "Open Settings" : "Grant") {
                if hasAccess {
                    model.openPermissionSettings(requirement)
                } else {
                    model.requestPermission(requirement)
                }
            }

            if !hasAccess {
                Button("Help") {
                    model.presentPermissionSetupGuide(for: requirement)
                }
            }
        }
    }
}
