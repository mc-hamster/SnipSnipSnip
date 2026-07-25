import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct CaptureAutomationSettingsView: View {
    @ObservedObject var lifecycle: AppLifecycleModel
    @ObservedObject var capture: CaptureWorkflowModel
    @ObservedObject var permissions: PermissionWorkflowModel
    @ObservedObject var documents: DocumentWorkflowModel
    @ObservedObject var clipboard: ClipboardWorkflowModel
    @ObservedObject var video: VideoWorkflowModel
    @ObservedObject var guide: GuideWorkflowModel
    @ObservedObject var archive: ArchiveWorkflowModel
    @ObservedObject var tools: ToolWorkflowModel
    let capabilities: AppCapabilitySnapshot
    let clock: any ClockProviding
    let requestOnboardingPresentation: () -> Void
    let checkForProUpdates: () -> Void
    let resetPreferencesToDefaults: () -> Void
    @State private var isShowingResetDefaultsConfirmation = false
    @State private var isShowingClearClipboardConfirmation = false
    @State private var isImportingGuideLogo = false
    @State private var launchAtLoginErrorMessage: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        TabView(selection: $lifecycle.selectedSettingsTab) {
            SettingsTabContainer(
                title: "General",
                summary: "Startup, background behavior, Help, updates, and settings recovery."
            ) {
                Section("Startup") {
                    Toggle("Launch \(AppBranding.displayName) at Login", isOn: launchAtLoginBinding)

                    HStack {
                        Label("Status", systemImage: lifecycle.launchAtLoginStatus.systemImage)
                        Spacer(minLength: 12)
                        Text(lifecycle.launchAtLoginStatus.stateLabel)
                            .foregroundStyle(launchAtLoginStatusColor)
                    }

                    SettingsHelpText(lifecycle.launchAtLoginStatus.detail)

                    if lifecycle.launchAtLoginStatus.needsSystemSettingsApproval || lifecycle.launchAtLoginStatus == .unavailable {
                        Button("Open Login Items in System Settings", action: lifecycle.openLaunchAtLoginSettings)
                    }

                    Toggle("Confirm Before Quitting", isOn: $lifecycle.confirmsBeforeQuitting)
                    SettingsHelpText("Command-Q and Quit \(AppBranding.displayName) ask whether to run in the background or quit so the menu bar icon, shortcuts, and clipboard history stay available unless this is turned off.")
                }

                Section("Help & Onboarding") {
                    Button("Show Onboarding Again", action: requestOnboardingPresentation)
                    Button("Open Support Page") {
                        openURL(AppLinks.support)
                    }

                    if capabilities.isEnabled(.proUpdateCheck) {
                        Button(
                            lifecycle.isCheckingProUpdates ? "Checking for Pro Updates..." : "Check for Pro Updates...",
                            action: checkForProUpdates
                        )
                        .disabled(lifecycle.isCheckingProUpdates)
                    }

                    SettingsHelpText(capabilities.isEnabled(.proUpdateCheck)
                        ? "Replay onboarding whenever you want a guided walkthrough. Support requests and feature requests start from the support page. Pro update checks read the latest GitHub release and send you there to download the newest package."
                        : "Replay onboarding whenever you want a guided walkthrough. Support requests and feature requests start from the support page.")
                }

                Section("Reset Settings") {
                    Button("Reset All Settings to Defaults", role: .destructive) {
                        isShowingResetDefaultsConfirmation = true
                    }
                    .disabled(!canResetPreferencesToDefaults)

                    SettingsHelpText("This restores capture, shortcuts, recording, output, Library, naming, and privacy settings to their default values. It does not delete archived captures or Recycle Bin items.")
                }
            }
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            .tag(AppSettingsTab.general)

            SettingsTabContainer(
                title: "Capture",
                summary: "Screenshot behavior and specialized screen tools."
            ) {
                Section("Screenshot Capture") {
                    Toggle("Include Cursor as Editable Overlay", isOn: $capture.screenshotIncludesCursor)
                    SettingsHelpText("When enabled, region, window, frontmost-window, fullscreen, and repeat screenshots add the current cursor as a movable, resizable, removable overlay. Scrolling Capture always excludes the cursor while stitching.")

                    Picker("After Selecting a Region", selection: regionCaptureCommitModeBinding) {
                        ForEach(RegionCaptureCommitMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    SettingsHelpText(capture.regionCapturePreferences.commitMode.detail)

                    Picker("Fullscreen Screenshot", selection: $capture.screenshotFullscreenDisplayMode) {
                        ForEach(ScreenshotFullscreenDisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    if capture.screenshotFullscreenDisplayMode == .selectedDisplay {
                        Picker("Selected Display", selection: selectedScreenshotDisplayIDBinding) {
                            ForEach(availableDisplayOptions(preferredID: capture.selectedScreenshotFullscreenDisplayID)) { option in
                                Text(option.name).tag(Optional(option.id))
                            }
                        }
                    }

                    SettingsHelpText(capture.screenshotFullscreenDisplayMode.detail)

                    if capabilities.isEnabled(.uiMap) {
                        DisclosureGroup("Advanced") {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Enable UI Map for Window captures", isOn: uiMapBinding)
                                SettingsHelpText("Save available names, roles, identifiers, and locations of visible interface elements when capturing a window. Region, fullscreen, scrolling, recording, and connected-device captures do not include UI Map metadata.")

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Pinned UI Map Overlay Defaults")
                                        .font(.subheadline.weight(.semibold))

                                    Toggle("Show outline", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsOutline))
                                    Toggle("Show source", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsSource))
                                    Toggle("Show name", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsLabel))
                                    Toggle("Show accessibility label", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsAccessibilityLabel))
                                    Toggle("Show identifier", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsIdentifier))
                                    Toggle("Show role", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsRole))
                                    Toggle("Show value", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsValue))
                                    Toggle("Show coordinates", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsCoordinates))
                                    Toggle("Show dimensions", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsDimensions))
                                    Toggle("Show owning app", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsOwningApplication))
                                    Toggle("Show bundle identifier", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsBundleIdentifier))
                                    Toggle("Show parent hierarchy", isOn: uiMapPinnedOverlayDefaultsBinding(\.showsParentHierarchy))
                                }

                                SettingsHelpText("Choose which details are shown by default when pinned UI Map elements are rendered on copied, shared, or exported screenshots.")

                                if capture.windowUIMapNeedsAccessibilityAccess {
                                    HStack(alignment: .firstTextBaseline) {
                                        Label("Window UI Map needs Accessibility access before metadata can be captured.", systemImage: "lock.trianglebadge.exclamationmark.fill")
                                            .foregroundStyle(.orange)

                                        Spacer()

                                        Button("Set Up") {
                                            permissions.requestAccessibilityAccess()
                                        }
                                        .disabled(permissions.activePermissionRequest != nil)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Screen Ruler") {
                    if tools.screenRulerCoordinator.hasActiveRulers {
                        Button("Close All Screen Rulers", action: tools.closeAllScreenRulers)
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
                        Text(tools.screenRulerPreferences.opacityDescription)
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: screenRulerOpacityBinding, in: 0.35...1, step: 0.01)

                    HStack {
                        Text("Tick Spacing")
                        Spacer(minLength: 12)
                        Text(tools.screenRulerPreferences.tickSpacingDescription)
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: screenRulerTickSpacingBinding, in: 4...50, step: 1)

                    Stepper(value: screenRulerMajorTickBinding, in: 2...20, step: 1) {
                        Text("Major Tick Every: \(tools.screenRulerPreferences.majorTickEvery)")
                    }

                    SettingsHelpText("Screen rulers are floating, resizable overlays. Click a ruler once to cycle through tick edge and zero-origin combinations, or set the default horizontal and vertical ruler positions here. Visible rulers are included in screenshots when the captured area contains them.")
                }

                Section("Screen Inspector") {
                    Button(tools.screenInspectorCoordinator.isVisible ? "Show Screen Inspector" : "Open Screen Inspector", action: tools.presentScreenInspector)

                    if tools.screenInspectorCoordinator.isVisible {
                        Button("Close Screen Inspector", action: tools.closeScreenInspector)
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
            }
            .tabItem {
                Label("Capture", systemImage: "camera.viewfinder")
            }
            .tag(AppSettingsTab.capture)

            SettingsTabContainer(
                title: "Presets",
                summary: "Saved screenshot setups for repeating common captures quickly."
            ) {
                Section("Capture Presets") {
                    SettingsHelpText("Presets rerun a saved screenshot target with the timer, cursor, display, region, and Window UI Map options captured when the preset was created.")

                    if capture.capturePresets.isEmpty {
                        SettingsHelpText("Capture a screenshot, then choose Presets > Save Last Capture as Preset to add it here.")
                        Button("Open Capture Window") {
                            lifecycle.requestMainWindowPresentation()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(capture.capturePresets) { preset in
                                capturePresetRow(preset)
                            }
                        }
                    }
                }
            }
            .tabItem {
                Label("Presets", systemImage: "star")
            }
            .tag(AppSettingsTab.presets)

            SettingsTabContainer(
                title: "Editor & Output",
                summary: "Editor defaults, canvas aids, Presentation resources, naming, and rendered output."
            ) {
                Section("Naming") {
                    TextField("Filename Template", text: $capture.screenshotFilenameTemplate)

                    SettingsHelpText("Filename tokens: {kind}, {source}, {width}, {height}, {format}, and date patterns such as {yyyy-MM-dd-HH-mm-ss}.")
                }

                Section("Export & Sharing") {
                    Picker("Screenshot Format", selection: $capture.screenshotDragOutFormat) {
                        ForEach(ImageExportFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("JPEG Quality")
                            Spacer(minLength: 12)
                            Text("\(Int(round(capture.screenshotJPEGQuality * 100)))%")
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: screenshotJPEGQualityBinding, in: ImageExportOptions.minimumJPEGQuality...ImageExportOptions.maximumJPEGQuality, step: 0.01)
                    }

                    SettingsHelpText("Drag the file icon from the screenshot editor to share a rendered image. JPEG quality applies to Export JPEG and JPEG drag-out sharing. Transparent presentation shadows automatically use PNG so the styled result stays faithful.")
                }

                Section("Editor") {
                    Picker("Default Tool", selection: $documents.editorStartupToolPreference) {
                        Text(EditorStartupToolPreference.default.label).tag(EditorStartupToolPreference.default)
                        Divider()
                        ForEach(EditorTool.startupDefaultTools) { tool in
                            Text(tool.label).tag(EditorStartupToolPreference.tool(tool))
                        }
                    }

                    SettingsHelpText("Choose Last Used to start each new editor session with the tool you selected most recently, or choose a specific tool to always start there.")

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Crop Outside Dimming")
                            Spacer(minLength: 12)
                            Text(documents.editorCropOutsideOverlayDimmingDescription)
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
                            Text(documents.editorOutOfCapturePatternSettings.spacingDescription)
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: outOfCapturePatternSpacingBinding, in: 16...96, step: 1)
                            .disabled(!documents.editorOutOfCapturePatternSettings.isEnabled)

                        HStack {
                            Text("Line Opacity")
                            Spacer(minLength: 12)
                            Text(documents.editorOutOfCapturePatternSettings.lineOpacityDescription)
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: outOfCapturePatternLineOpacityBinding, in: 0.05...0.9, step: 0.01)
                            .disabled(!documents.editorOutOfCapturePatternSettings.isEnabled)

                        HStack {
                            Text("Dot Size")
                            Spacer(minLength: 12)
                            Text(documents.editorOutOfCapturePatternSettings.dotDiameterDescription)
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: outOfCapturePatternDotDiameterBinding, in: 2...12, step: 1)
                            .disabled(!documents.editorOutOfCapturePatternSettings.isEnabled)

                        HStack {
                            Text("Dot Opacity")
                            Spacer(minLength: 12)
                            Text(documents.editorOutOfCapturePatternSettings.dotOpacityDescription)
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: outOfCapturePatternDotOpacityBinding, in: 0.05...1, step: 0.01)
                            .disabled(!documents.editorOutOfCapturePatternSettings.isEnabled)

                        SettingsHelpText("The crosshatch marks canvas space outside the original captured image. It is editor-only and is never included when copying, exporting, sharing, or saving rendered output.")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Presentation Scenes")
                            .font(.subheadline.weight(.semibold))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scenes Folder")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(documents.presentationScenesRootDescription)
                                .font(.footnote)
                                .textSelection(.enabled)
                        }

                        HStack {
                            Button("Choose Scenes Folder...", action: documents.choosePresentationScenesRoot)
                            Button("Reveal Scenes Folder", action: documents.revealPresentationScenesRoot)
                            Button("Reset to Default Folder", action: documents.resetPresentationScenesRootToDefault)
                                .disabled(documents.usesDefaultPresentationScenesRoot)
                            Button("Reload Scenes", action: documents.reloadPresentationScenes)
                        }

                        SettingsHelpText("Presentation Scenes are SVG files. \(AppBranding.displayName) manages shipped examples in Bundled and reads custom scenes from User inside this folder.")
                    }
                }
            }
            .tabItem {
                Label("Editor & Output", systemImage: "slider.horizontal.3")
            }
            .tag(AppSettingsTab.editorOutput)

            SettingsTabContainer(
                title: "Shortcuts",
                summary: "Global capture hotkeys and built-in keyboard shortcuts are centralized here."
            ) {
                Section("Global Capture Hotkeys") {
                    Toggle("Enable Global Capture Hotkeys", isOn: automationBinding(\.globalHotkeysEnabled))

                    ForEach(availableGlobalHotKeyActions, id: \.rawValue) { action in
                        Picker(action.label + " Hotkey", selection: automationHotKeyBinding(for: action)) {
                            ForEach(GlobalHotKeyKey.allCases) { key in
                                Text("Command-Shift-" + key.label).tag(key)
                            }
                        }

                        if let warning = capture.automationPreferences.key(for: action).knownSystemConflictWarning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }

                    SettingsHelpText("Global hotkeys run while \(AppBranding.displayName) is not frontmost, so the active app keeps those shortcuts when \(AppBranding.displayName) is already focused.")
                }

                Section("Editor Shortcuts") {
                    Toggle("Enable Single-Key Tool Shortcuts", isOn: $documents.editorSingleKeyToolShortcutsEnabled)
                    SettingsHelpText("Single-key tool shortcuts work only when the screenshot canvas has focus and text entry is not active.")
                }

                Section("Shortcut Reference") {
                    ShortcutCatalogListView(
                        sections: AppShortcut.catalogSections(
                            preferences: capture.automationPreferences,
                            includesGuideCapture: capabilities.isEnabled(.guideCapture)
                        )
                    )
                    SettingsHelpText("Default global capture hotkeys can be changed above. Built-in app and editor shortcuts are fixed in this version.")
                }
            }
            .tabItem {
                Label("Shortcuts", systemImage: "keyboard")
            }
            .tag(AppSettingsTab.shortcuts)

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

                    SettingsHelpText(video.recordingPreferences.quality.detail)

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

                    if video.recordingPreferences.fullscreenDisplayMode == .selectedDisplay {
                        Picker("Selected Display", selection: selectedRecordingDisplayIDBinding) {
                            ForEach(availableDisplayOptions(preferredID: video.recordingPreferences.selectedFullscreenDisplayID)) { option in
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
            .tag(AppSettingsTab.recording)

            if capabilities.isEnabled(.guideCapture) {
                SettingsTabContainer(
                    title: "Guide",
                    summary: "Choose how actions become polished, private, editable instructions."
                ) {
                Section("Capture") {
                    Toggle("Keep Full-Motion Source Video", isOn: guideCapturePreferenceBinding(\.sourceVideoEnabled))
                    Picker("Source Frame Rate", selection: guideCapturePreferenceBinding(\.framesPerSecond)) {
                        Text("15 fps").tag(15)
                        Text("30 fps · Balanced").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Toggle("Record System Audio", isOn: guideCapturePreferenceBinding(\.capturesSystemAudio))
                    Toggle("Record Microphone", isOn: guideCapturePreferenceBinding(\.capturesMicrophone))
                    SettingsHelpText("Source video is on by default so Full Motion and Action Highlights remain available. Turn it off when you only need PDF, animated, image, ZIP, or slideshow output.")
                }

                Section("Steps & Privacy") {
                    Toggle("Create Captions Automatically", isOn: guideCapturePreferenceBinding(\.automaticCaptions))
                    Toggle("Refine Captions On Device", isOn: guideCapturePreferenceBinding(\.aiCaptionRefinement))
                    Toggle("Mask Secure Fields", isOn: guideCapturePreferenceBinding(\.masksSecureFields))
                    Toggle("Show Cursor in Still Steps", isOn: guideCapturePreferenceBinding(\.showsCursorInSteps))
                    Toggle("Hide Desktop Icons", isOn: guideCapturePreferenceBinding(\.hidesDesktopIcons))
                    Toggle("Include Menu Bar in Display Guides", isOn: guideCapturePreferenceBinding(\.menuBarIncludedForDisplays))
                    SettingsHelpText("Private Guide follows Private Capture: it skips archive, OCR indexing, diagnostics content, and AI refinement. Screen images and metadata never leave this Mac.")
                }

                Section("Capture HUD") {
                    Picker("Corner", selection: guideCapturePreferenceBinding(\.hudCorner)) {
                        Text("Top Right").tag("topRight")
                        Text("Top Left").tag("topLeft")
                        Text("Bottom Right").tag("bottomRight")
                        Text("Bottom Left").tag("bottomLeft")
                    }
                    Toggle("Show Recent Step Previews", isOn: guideCapturePreferenceBinding(\.hudPreviewsEnabled))
                }

                Section("Default Brand Profile") {
                    TextField("Organization", text: guideThemeBinding(\.organizationName))
                    HStack {
                        Button(guide.defaultLogoImage == nil ? "Choose Logo…" : "Replace Logo…") {
                            isImportingGuideLogo = true
                        }
                        if guide.defaultLogoImage != nil {
                            Button("Remove Logo", role: .destructive) { guide.setDefaultLogo(nil) }
                        }
                    }
                    TextField("Copyright / footer", text: guideThemeBinding(\.footer))
                    Text("Legal statement").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: guideOptionalThemeStringBinding(\.legalStatement))
                        .frame(minHeight: 72)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    SettingsHelpText("This profile is copied into every new Guide and travels with the saved .sssguide document. Existing Guides keep their own branding. Use the Guide editor's Use as Default button to replace this profile from a finished design.")
                }

                Section("Default Design & Export") {
                    TextField("Theme Name", text: guideThemeBinding(\.name))
                    HStack {
                        Button("Save Theme") { guide.saveTheme(guide.theme) }
                        if !guide.savedThemes.isEmpty {
                            Menu("Saved Themes") {
                                ForEach(guide.savedThemes) { theme in
                                    Button(theme.name) { guide.applySavedTheme(theme.id) }
                                }
                                Divider()
                                Menu("Delete Theme") {
                                    ForEach(guide.savedThemes) { theme in
                                        Button(theme.name, role: .destructive) { guide.deleteSavedTheme(theme.id) }
                                    }
                                }
                            }
                        }
                    }
                    Picker("Appearance", selection: guideThemeBinding(\.appearance)) {
                        ForEach(GuideAppearance.allCases) { appearance in
                            Text(appearance.rawValue.capitalized).tag(appearance)
                        }
                    }
                    Stepper("Arrow Width: \(guide.theme.markerLineWidth, specifier: "%.0f") pt", value: guideThemeBinding(\.markerLineWidth), in: 1...12)
                    Stepper("Arrow Length: \(guide.theme.markerLength, specifier: "%.0f") pt", value: guideThemeBinding(\.markerLength), in: 24...240)
                    Toggle("PDF", isOn: guideExportFormatBinding(.pdf))
                    Toggle("GIF", isOn: guideExportFormatBinding(.gif))
                    Toggle("APNG", isOn: guideExportFormatBinding(.apng))
                    Toggle("Full Motion MP4", isOn: guideExportFormatBinding(.fullMotionMP4))
                    Toggle("Action Highlights MP4", isOn: guideExportFormatBinding(.highlightMP4))
                    Toggle("Step Slideshow MP4", isOn: guideExportFormatBinding(.slideshowMP4))
                    Toggle("Step Images", isOn: guideExportFormatBinding(.stepImages))
                    Toggle("ZIP", isOn: guideExportFormatBinding(.zip))
                    Picker("PDF Paper", selection: guideExportSettingsBinding(\.pdfPaper)) {
                        Text("Automatic").tag(GuidePDFPaper.automatic)
                        Text("US Letter").tag(GuidePDFPaper.letter)
                        Text("A4").tag(GuidePDFPaper.a4)
                    }
                    Picker("PDF Orientation", selection: guideExportSettingsBinding(\.pdfOrientation)) {
                        Text("Portrait").tag(GuidePDFOrientation.portrait)
                        Text("Landscape").tag(GuidePDFOrientation.landscape)
                    }
                    Picker("PDF Quality", selection: guideExportSettingsBinding(\.pdfDPI)) {
                        Text("Compact · 144 dpi").tag(144)
                        Text("Standard · 216 dpi").tag(216)
                        Text("Print · 300 dpi").tag(300)
                    }
                    Picker("Step Image Format", selection: guideExportSettingsBinding(\.stepImageFormat)) {
                        Text("PNG").tag(GuideStepImageFormat.png)
                        Text("JPEG").tag(GuideStepImageFormat.jpeg)
                    }
                    TextField("File Name", text: guideExportSettingsBinding(\.filenameTemplate))
                }
                }
                .tabItem {
                    Label("Guide", systemImage: "list.number")
                }
                .tag(AppSettingsTab.guide)
            }

            SettingsTabContainer(
                title: "Library",
                summary: "Snip recovery and Clipboard History share one task-oriented destination."
            ) {
                Picker("Library Page", selection: $lifecycle.selectedLibrarySettingsSection) {
                    ForEach(LibrarySettingsSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.library.section")

                if lifecycle.selectedLibrarySettingsSection == .snips {
                    Section("Archive History") {
                    SettingsHelpText("Archive history is local to this Mac. It stores editable .sss checkpoints, previews, searchable annotation text, and background OCR text unless Private Capture is enabled.")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Location")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(archive.archiveLocationDescription)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Button("Choose Location…", action: archive.chooseArchiveLocation)

                        Button("Use Default Location", action: archive.resetArchiveLocationToDefault)
                            .disabled(archive.usesDefaultArchiveLocation)

                        Button("Open in Finder", action: archive.openArchiveLocationInFinder)
                    }

                    Stepper(value: Binding(get: {
                        archive.maximumSizeMB
                    }, set: { value in
                        archive.updateArchiveMaximumSizeMB(value)
                    }), in: ArchiveWorkflowConstants.minimumMaximumSizeMB...10_240, step: 100) {
                        Text("Max Archive Size: \(archive.maximumSizeMB) MB")
                    }

                    HStack {
                        Text("Current Size")
                        Spacer(minLength: 12)
                        Text(archive.archiveSizeLabel)
                            .foregroundStyle(.secondary)
                    }

                    Button("Clear Archive", role: .destructive) {
                        Task { @MainActor in
                            guard await guide.prepareForConflictingAction(named: "clearing the archive") else { return }
                            archive.clearArchive()
                        }
                    }

                    SettingsHelpText("\(AppBranding.displayName) periodically trims the oldest archived checkpoints until the archive is back under the configured limit.")
                }

                    Section("Recycle Bin") {
                    Stepper(value: Binding(get: {
                        archive.recycleBinRetentionDays
                    }, set: { value in
                        archive.updateRecycleBinRetentionDays(value)
                    }), in: ArchiveWorkflowConstants.minimumRecycleBinRetentionDays...ArchiveWorkflowConstants.maximumRecycleBinRetentionDays, step: 1) {
                        Text("Empty Deleted Snips After: \(archive.recycleBinRetentionDays) day\(archive.recycleBinRetentionDays == 1 ? "" : "s")")
                    }

                    HStack {
                        Text("Deleted Items")
                        Spacer(minLength: 12)
                        Text("\(documents.recycleBinEntries.count)")
                            .foregroundStyle(.secondary)
                    }

                    Button("Empty Now", role: .destructive, action: documents.emptyRecycleBin)
                        .disabled(documents.recycleBinEntries.isEmpty)

                    SettingsHelpText("Deleted snips move to the recycle bin first. The scheduled cleanup permanently removes items after the configured retention period; the default is 30 days. Choose from 1 to 180 days.")
                    }
                } else {
                    Section("Clipboard History") {
                    Toggle("Enable Clipboard History", isOn: Binding(get: {
                        clipboard.preferences.isEnabled
                    }, set: { value in
                        clipboard.updateClipboardHistoryEnabled(value)
                    }))

                    SettingsHelpText("Optional and off by default. Turning this on begins monitoring supported copied content and loads or creates an encrypted local history whose key is protected by Keychain. macOS may ask you to allow Keychain access.")

                    Stepper(value: Binding(get: {
                        clipboard.preferences.maxItemCount
                    }, set: { value in
                        clipboard.updateClipboardMaxItemCount(value)
                    }), in: 10...1_000, step: 10) {
                        Text("Maximum Unpinned Items: \(clipboard.preferences.maxItemCount)")
                    }

                    Stepper(value: Binding(get: {
                        clipboard.preferences.maxStorageMB
                    }, set: { value in
                        clipboard.updateClipboardMaxStorageMB(value)
                    }), in: 25...5_120, step: 25) {
                        Text("History Storage Target: \(clipboard.preferences.maxStorageMB) MB (Pinned Kept)")
                    }

                    Stepper(value: Binding(get: {
                        clipboard.preferences.maxItemSizeMB
                    }, set: { value in
                        clipboard.updateClipboardMaxItemSizeMB(value)
                    }), in: 1...250, step: 5) {
                        Text("Maximum Item Size: \(clipboard.preferences.maxItemSizeMB) MB")
                    }

                    Picker("Delete Unpinned Items", selection: Binding(get: {
                        clipboard.preferences.retentionDays
                    }, set: { value in
                        clipboard.updateClipboardRetentionDays(value)
                    })) {
                        Text("Never").tag(0)
                        Text("After 1 Day").tag(1)
                        Text("After 7 Days").tag(7)
                        Text("After 30 Days").tag(30)
                        Text("After 90 Days").tag(90)
                    }

                    Toggle("Add Screenshots That Were Not Copied", isOn: Binding(get: {
                        clipboard.preferences.recordsUncopiedSnips
                    }, set: { value in
                        clipboard.updateRecordsUncopiedSnips(value)
                    }))
                    .disabled(!clipboard.preferences.isEnabled)

                    HStack {
                        Text("Monitoring")
                        Spacer(minLength: 12)
                        if clipboard.isClipboardMonitoringPaused {
                            Button("Resume", action: clipboard.resumeClipboardMonitoring)
                        } else {
                            Menu("Pause") {
                                Button("5 Minutes") { clipboard.pauseClipboardMonitoring(for: 5 * 60) }
                                Button("1 Hour") { clipboard.pauseClipboardMonitoring(for: 60 * 60) }
                                Button("Until Restart") { clipboard.pauseClipboardMonitoring(for: nil) }
                            }
                            .disabled(!clipboard.preferences.isEnabled)
                        }
                    }

                    HStack {
                        Text("Saved Items")
                        Spacer(minLength: 12)
                        Text("\(clipboard.clipboardHistoryItems.count)")
                            .foregroundStyle(.secondary)
                    }

                    Button("Clear Clipboard History", role: .destructive) {
                        isShowingClearClipboardConfirmation = true
                    }
                        .disabled(clipboard.clipboardHistoryItems.isEmpty)

                    if let recoveryMessage = clipboard.historyStore.recoveryMessage {
                        Label(recoveryMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }

                    SettingsHelpText("When enabled, clipboard history stays encrypted on this Mac with a key protected by Keychain. Turning it off stops monitoring and unloads decrypted history and cached previews while preserving the encrypted history unless you clear it. The history and its key are not loaded on the next launch. Private Capture always stays out of clipboard history.")
                }

                    Section("Ignored Apps") {
                    SettingsHelpText("\(AppBranding.displayName) skips concealed and transient clipboard types and ignores Apple Passwords plus common password managers by default.")

                    HStack(spacing: 10) {
                        Menu("Ignore Running App") {
                            if clipboard.clipboardRunningAppIgnoreCandidates.isEmpty {
                                Text("No available running apps")
                            } else {
                                ForEach(clipboard.clipboardRunningAppIgnoreCandidates) { app in
                                    Button(app.name) {
                                        clipboard.addIgnoredClipboardApp(app)
                                    }
                                }
                            }
                        }

                        Button("Choose App...", action: clipboard.chooseIgnoredClipboardApp)
                    }

                    if !clipboard.clipboardRecentSourceAppIgnoreCandidates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent Sources")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(clipboard.clipboardRecentSourceAppIgnoreCandidates.prefix(5)) { app in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                        Text(app.match)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 12)

                                    Button("Ignore") {
                                        clipboard.addIgnoredClipboardApp(app)
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

                        ForEach(clipboard.preferences.ignoredApps) { app in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    Text(app.match)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 12)

                                Button("Remove") {
                                    clipboard.removeIgnoredClipboardApp(app)
                                }
                            }
                        }
                    }

                    Button("Restore Default Ignored Apps", action: clipboard.resetIgnoredClipboardApps)
                    }
                }
            }
            .tabItem {
                Label("Library", systemImage: "books.vertical")
            }
            .tag(AppSettingsTab.library)

            SettingsTabContainer(
                title: "Privacy",
                summary: "Private Capture, permissions, and diagnostics."
            ) {
                Section("Private Capture") {
                    Toggle("Private Capture", isOn: privateCaptureBinding)
                        .disabled(!capture.canChangePrivateCapture)

                    SettingsHelpText("Private Capture keeps the current capture out of archive history, Recent Snips, the Recycle Bin, Clipboard History, and background OCR indexing. You can still explicitly save or export the result. The setting is locked while a capture or recording is active so the in-progress capture uses the privacy choice it started with.")
                }

                Section("Permission Diagnostics") {
                    PermissionStatusRow(requirement: .screenRecording, permissions: permissions)
                    if shouldShowAccessibilityPermissionDiagnostics {
                        PermissionStatusRow(requirement: .accessibility, permissions: permissions)
                    }

                    Button("Export Diagnostics…") {
                        SupportDiagnosticsExporter.export(
                            snapshot: supportDiagnosticsSnapshot,
                            clock: clock
                        ) { error in
                            lifecycle.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }

                    SettingsHelpText(
                        shouldShowAccessibilityPermissionDiagnostics
                            ? accessibilityPermissionDiagnosticsDetail
                            : "Screen Recording is the only privacy permission required for screenshot pixels, live window thumbnails, and screen recording in this build. Diagnostics export sanitized app, permission, display, storage, and status details without screenshots, clipboard contents, OCR text, annotations, or document data."
                    )
                }

            }
            .tabItem {
                Label("Privacy", systemImage: "hand.raised")
            }
            .tag(AppSettingsTab.privacy)
        }
        .frame(width: 700, height: 560)
        .task {
            lifecycle.refreshLaunchAtLoginStatus()
        }
        .fileImporter(isPresented: $isImportingGuideLogo, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            guide.setDefaultLogo(image)
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
                lifecycle.openLaunchAtLoginSettings()
                launchAtLoginErrorMessage = nil
            }
        } message: {
            Text(launchAtLoginErrorMessage ?? "")
        }
        .confirmationDialog("Reset all settings to defaults?", isPresented: $isShowingResetDefaultsConfirmation, titleVisibility: .visible) {
            Button("Reset All Settings", role: .destructive) {
                resetPreferencesToDefaults()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This keeps your current documents and archive contents, but it restores settings values to their shipped defaults.")
        }
        .confirmationDialog("Clear all clipboard history?", isPresented: $isShowingClearClipboardConfirmation, titleVisibility: .visible) {
            Button("Clear Clipboard History", role: .destructive, action: clipboard.clearClipboardHistory)
        } message: {
            Text("This permanently removes pinned and unpinned clipboard items from this Mac.")
        }
        .onDisappear {
            lifecycle.selectedSettingsTab = .general
        }
    }

    private var supportDiagnosticsSnapshot: SupportDiagnosticsSnapshot {
        SupportDiagnosticsSnapshot.make(
            capabilities: capabilities,
            permissions: capture.dependencies.systemServices.permissions,
            systemServices: capture.dependencies.systemServices,
            lifecycle: lifecycle,
            permissionWorkflow: permissions,
            capture: capture,
            documents: documents,
            clipboard: clipboard,
            video: video,
            guide: guide,
            archive: archive
        )
    }

    private var shouldShowAccessibilityPermissionDiagnostics: Bool {
        capabilities.isEnabled(.scrollingCapture)
            || capabilities.isEnabled(.guideCapture)
            || (capabilities.isEnabled(.uiMap) && capture.uiMapEnabled)
    }

    private var accessibilityPermissionDiagnosticsDetail: String {
        let requirementSummary: String
        if capabilities.isEnabled(.scrollingCapture),
           capabilities.isEnabled(.guideCapture),
           capabilities.isEnabled(.uiMap),
           capture.uiMapEnabled {
            requirementSummary = "Accessibility is only required for Scrolling Capture, Guide capture, and Window UI Map."
        } else if capabilities.isEnabled(.guideCapture),
                  capabilities.isEnabled(.uiMap),
                  capture.uiMapEnabled {
            requirementSummary = "Accessibility is only required for Guide capture and Window UI Map."
        } else if capabilities.isEnabled(.scrollingCapture),
                  capabilities.isEnabled(.guideCapture) {
            requirementSummary = "Accessibility is only required for Scrolling Capture and Guide capture."
        } else if capabilities.isEnabled(.uiMap), capture.uiMapEnabled {
            requirementSummary = "Accessibility is only required for Window UI Map."
        } else if capabilities.isEnabled(.guideCapture) {
            requirementSummary = "Accessibility is only required for Guide capture."
        } else {
            requirementSummary = "Accessibility is only required for Scrolling Capture."
        }

        return "\(requirementSummary) Region, Fullscreen, editor OCR, export, and annotation tools do not depend on Accessibility. Diagnostics export sanitized app, permission, display, storage, and status details without screenshots, clipboard contents, OCR text, annotations, or document data."
    }

    private var canResetPreferencesToDefaults: Bool {
        !capture.isWorking
            && !capture.isShowingWindowPicker
            && video.activeVideoRecording == nil
            && !guide.isActive
            && !capture.isConnectedDeviceSessionActive
    }

    private func automationBinding<Value>(_ keyPath: WritableKeyPath<CaptureAutomationPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { capture.automationPreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = capture.automationPreferences
                preferences[keyPath: keyPath] = newValue
                capture.automationPreferences = preferences
            }
        )
    }

    private func guideCapturePreferenceBinding<Value>(_ keyPath: WritableKeyPath<GuideCapturePreferences, Value>) -> Binding<Value> {
        Binding(
            get: { guide.capturePreferences[keyPath: keyPath] },
            set: { value in
                var preferences = guide.capturePreferences
                preferences[keyPath: keyPath] = value
                guide.capturePreferences = preferences
            }
        )
    }

    private func guideThemeBinding<Value>(_ keyPath: WritableKeyPath<GuideTheme, Value>) -> Binding<Value> {
        Binding(
            get: { guide.theme[keyPath: keyPath] },
            set: { value in
                var theme = guide.theme
                theme[keyPath: keyPath] = value
                guide.theme = theme
            }
        )
    }

    private func guideOptionalThemeStringBinding(_ keyPath: WritableKeyPath<GuideTheme, String?>) -> Binding<String> {
        Binding(
            get: { guide.theme[keyPath: keyPath] ?? "" },
            set: { value in
                var theme = guide.theme
                theme[keyPath: keyPath] = value.isEmpty ? nil : value
                guide.theme = theme
            }
        )
    }

    private func guideExportSettingsBinding<Value>(_ keyPath: WritableKeyPath<GuideExportSettings, Value>) -> Binding<Value> {
        Binding(
            get: { guide.exportSettings[keyPath: keyPath] },
            set: { value in
                var settings = guide.exportSettings
                settings[keyPath: keyPath] = value
                guide.exportSettings = settings
            }
        )
    }

    private func guideExportFormatBinding(_ format: GuideExportFormat) -> Binding<Bool> {
        Binding(
            get: { guide.exportSettings.formats.contains(format) },
            set: { enabled in
                var settings = guide.exportSettings
                if enabled { settings.formats.insert(format) }
                else { settings.formats.remove(format) }
                guide.exportSettings = settings
            }
        )
    }

    private func automationHotKeyBinding(for action: GlobalHotKeyAction) -> Binding<GlobalHotKeyKey> {
        Binding(
            get: { capture.automationPreferences.key(for: action) },
            set: { newKey in
                var preferences = capture.automationPreferences
                preferences.setKey(newKey, for: action)
                capture.automationPreferences = preferences
            }
        )
    }

    private var availableGlobalHotKeyActions: [GlobalHotKeyAction] {
        GlobalHotKeyAction.availableActions(for: capabilities)
    }

    private func capturePresetRow(_ preset: CapturePreset) -> some View {
        let index = capture.capturePresets.firstIndex(where: { $0.id == preset.id }) ?? 0

        return HStack(alignment: .top, spacing: 8) {
            CapturePresetBadge(preset: preset, size: 32)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Preset name", text: capturePresetNameBinding(for: preset.id))
                    .textFieldStyle(.roundedBorder)

                Text("\(preset.targetLabel) • \(preset.outcome.label)\(preset.lastRunAt.map { " • Last run \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Outcome", selection: capturePresetOutcomeBinding(for: preset.id)) {
                    ForEach(CapturePresetOutcome.allCases) { outcome in
                        Text(outcome.label).tag(outcome)
                    }
                }
                .labelsHidden()

                HStack {
                    Menu("Icon: \(preset.symbolName ?? "Default")") {
                        Button("Default") { capture.updateCapturePresetAppearance(id: preset.id, symbolName: nil, tint: preset.tint) }
                        ForEach(["camera.viewfinder", "macwindow", "doc.text", "ladybug", "star"], id: \.self) { symbol in
                            Button { capture.updateCapturePresetAppearance(id: preset.id, symbolName: symbol, tint: preset.tint) } label: {
                                Label {
                                    Text(symbol)
                                } icon: {
                                    CapturePresetBadge(symbolName: symbol, tint: preset.tint, size: 18)
                                }
                            }
                        }
                    }
                    Picker("Color", selection: capturePresetTintBinding(for: preset.id)) {
                        ForEach(CapturePresetTint.allCases) { tint in
                            CapturePresetTintLabel(tint: tint, symbolName: preset.symbolName)
                                .tag(tint)
                        }
                    }
                    Menu("Shortcut: \(preset.hotKey.map { "⌘⇧\($0.label)" } ?? "None")") {
                        Button("No Shortcut") { capture.updateCapturePresetHotKey(id: preset.id, hotKey: nil) }
                        ForEach(GlobalHotKeyKey.allCases) { key in
                            Button("⌘⇧\(key.label)") { capture.updateCapturePresetHotKey(id: preset.id, hotKey: key) }
                        }
                    }
                }
                .labelsHidden()

                if preset.outcome == .exportToFolder {
                    Menu(preset.exportDestination.map { "\($0.format.label) → \($0.folderURL.lastPathComponent)" } ?? "Choose export folder") {
                        ForEach(ImageExportFormat.allCases) { format in
                            Button("Choose \(format.label) Folder…") {
                                capture.chooseCapturePresetExportDestination(id: preset.id, format: format)
                            }
                        }
                    }
                    .font(.caption)
                }
            }

            Spacer(minLength: 8)

            Button {
                capture.capturePreset(preset)
            } label: {
                Image(systemName: "play.fill")
            }
            .help("Run this workflow.")

            Button {
                capture.toggleCapturePresetFavorite(id: preset.id)
            } label: {
                Image(systemName: preset.isFavorite ? "star.fill" : "star")
            }
            .help(preset.isFavorite ? "Remove from favorites." : "Add to favorites.")

            Button {
                capture.moveCapturePreset(id: preset.id, offset: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .help("Move preset up.")
            .disabled(index == 0)

            Button {
                capture.moveCapturePreset(id: preset.id, offset: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .help("Move preset down.")
            .disabled(index >= capture.capturePresets.count - 1)

            Button(role: .destructive) {
                capture.deleteCapturePreset(id: preset.id)
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete preset.")
        }
    }

    private func capturePresetNameBinding(for id: CapturePreset.ID) -> Binding<String> {
        Binding(
            get: {
                capture.capturePresets.first(where: { $0.id == id })?.name ?? ""
            },
            set: { newValue in
                capture.renameCapturePreset(id: id, to: newValue)
            }
        )
    }

    private func capturePresetOutcomeBinding(for id: CapturePreset.ID) -> Binding<CapturePresetOutcome> {
        Binding(
            get: { capture.capturePresets.first(where: { $0.id == id })?.outcome ?? .openInEditor },
            set: { capture.updateCapturePresetOutcome(id: id, outcome: $0) }
        )
    }

    private func capturePresetTintBinding(for id: CapturePreset.ID) -> Binding<CapturePresetTint> {
        Binding(
            get: { capture.capturePresets.first(where: { $0.id == id })?.tint ?? .blue },
            set: { tint in
                let symbol = capture.capturePresets.first(where: { $0.id == id })?.symbolName
                capture.updateCapturePresetAppearance(id: id, symbolName: symbol, tint: tint)
            }
        )
    }

    private func regionCaptureBinding<Value>(_ keyPath: WritableKeyPath<RegionCapturePreferences, Value>) -> Binding<Value> {
        Binding(
            get: { capture.regionCapturePreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = capture.regionCapturePreferences
                preferences[keyPath: keyPath] = newValue
                capture.regionCapturePreferences = preferences
            }
        )
    }

    private var regionCaptureCommitModeBinding: Binding<RegionCaptureCommitMode> {
        Binding(
            get: { capture.regionCapturePreferences.commitMode },
            set: { newValue in
                var preferences = capture.regionCapturePreferences
                preferences.commitMode = newValue
                capture.regionCapturePreferences = preferences
            }
        )
    }

    private var privateCaptureBinding: Binding<Bool> {
        Binding(
            get: { capture.privateCaptureEnabled },
            set: { newValue in
                capture.updatePrivateCaptureEnabled(newValue)
            }
        )
    }

    private var uiMapBinding: Binding<Bool> {
        Binding(
            get: { capture.uiMapEnabled },
            set: { newValue in
                capture.updateUIMapEnabled(newValue)
            }
        )
    }

    private func uiMapPinnedOverlayDefaultsBinding(_ keyPath: WritableKeyPath<UIMapOverlayOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { documents.uiMapPinnedOverlayDefaults[keyPath: keyPath] },
            set: { newValue in
                var options = documents.uiMapPinnedOverlayDefaults
                options[keyPath: keyPath] = newValue
                documents.uiMapPinnedOverlayDefaults = options
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { lifecycle.launchAtLoginStatus.prefersEnabledToggle },
            set: { newValue in
                let result = lifecycle.updateLaunchAtLoginEnabled(newValue)

                if case let .failed(message) = result {
                    launchAtLoginErrorMessage = message
                }
            }
        )
    }

    private var launchAtLoginStatusColor: Color {
        switch lifecycle.launchAtLoginStatus {
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
            get: { video.recordingPreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = video.recordingPreferences
                preferences[keyPath: keyPath] = newValue
                video.recordingPreferences = preferences
            }
        )
    }

    private func screenRulerBinding<Value>(_ keyPath: WritableKeyPath<ScreenRulerPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { tools.screenRulerPreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = tools.screenRulerPreferences
                preferences[keyPath: keyPath] = newValue
                tools.screenRulerPreferences = preferences
            }
        )
    }

    private func screenInspectorBinding<Value>(_ keyPath: WritableKeyPath<ScreenInspectorPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { tools.screenInspectorPreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = tools.screenInspectorPreferences
                preferences[keyPath: keyPath] = newValue
                tools.screenInspectorPreferences = preferences
            }
        )
    }

    private var screenRulerOpacityBinding: Binding<Double> {
        Binding(
            get: { tools.screenRulerPreferences.opacity },
            set: { newValue in
                var preferences = tools.screenRulerPreferences
                preferences.opacity = newValue
                tools.screenRulerPreferences = preferences
            }
        )
    }

    private var screenRulerTickSpacingBinding: Binding<Double> {
        Binding(
            get: { Double(tools.screenRulerPreferences.tickSpacing) },
            set: { newValue in
                var preferences = tools.screenRulerPreferences
                preferences.tickSpacing = CGFloat(newValue)
                tools.screenRulerPreferences = preferences
            }
        )
    }

    private var screenRulerMajorTickBinding: Binding<Int> {
        Binding(
            get: { tools.screenRulerPreferences.majorTickEvery },
            set: { newValue in
                var preferences = tools.screenRulerPreferences
                preferences.majorTickEvery = newValue
                tools.screenRulerPreferences = preferences
            }
        )
    }

    private var cropOutsideOverlayAlphaBinding: Binding<Double> {
        Binding(
            get: { Double(documents.editorCropOutsideOverlayAlpha) },
            set: { newValue in
                documents.updateEditorCropOutsideOverlayAlpha(CGFloat(newValue))
            }
        )
    }

    private var outOfCapturePatternEnabledBinding: Binding<Bool> {
        Binding(
            get: { documents.editorOutOfCapturePatternSettings.isEnabled },
            set: { newValue in
                var settings = documents.editorOutOfCapturePatternSettings
                settings.isEnabled = newValue
                documents.updateEditorOutOfCapturePatternSettings(settings)
            }
        )
    }

    private var outOfCapturePatternSpacingBinding: Binding<Double> {
        Binding(
            get: { Double(documents.editorOutOfCapturePatternSettings.spacing) },
            set: { newValue in
                var settings = documents.editorOutOfCapturePatternSettings
                settings.spacing = CGFloat(newValue)
                documents.updateEditorOutOfCapturePatternSettings(settings)
            }
        )
    }

    private var outOfCapturePatternLineOpacityBinding: Binding<Double> {
        Binding(
            get: { Double(documents.editorOutOfCapturePatternSettings.lineOpacity) },
            set: { newValue in
                var settings = documents.editorOutOfCapturePatternSettings
                settings.lineOpacity = CGFloat(newValue)
                documents.updateEditorOutOfCapturePatternSettings(settings)
            }
        )
    }

    private var outOfCapturePatternDotOpacityBinding: Binding<Double> {
        Binding(
            get: { Double(documents.editorOutOfCapturePatternSettings.dotOpacity) },
            set: { newValue in
                var settings = documents.editorOutOfCapturePatternSettings
                settings.dotOpacity = CGFloat(newValue)
                documents.updateEditorOutOfCapturePatternSettings(settings)
            }
        )
    }

    private var outOfCapturePatternDotDiameterBinding: Binding<Double> {
        Binding(
            get: { Double(documents.editorOutOfCapturePatternSettings.dotDiameter) },
            set: { newValue in
                var settings = documents.editorOutOfCapturePatternSettings
                settings.dotDiameter = CGFloat(newValue)
                documents.updateEditorOutOfCapturePatternSettings(settings)
            }
        )
    }

    private var screenshotJPEGQualityBinding: Binding<Double> {
        Binding(
            get: { Double(capture.screenshotJPEGQuality) },
            set: { capture.screenshotJPEGQuality = CGFloat($0) }
        )
    }

    private var selectedScreenshotDisplayIDBinding: Binding<UInt32?> {
        Binding(
            get: {
                let selectedID = capture.selectedScreenshotFullscreenDisplayID
                let options = availableDisplayOptions(preferredID: selectedID)
                if let selectedID,
                   options.contains(where: { $0.id == selectedID }) {
                    return selectedID
                }

                return options.first?.id
            },
            set: { newValue in
                capture.selectedScreenshotFullscreenDisplayID = newValue
            }
        )
    }

    private var selectedRecordingDisplayIDBinding: Binding<UInt32?> {
        Binding(
            get: {
                let selectedID = video.recordingPreferences.selectedFullscreenDisplayID
                let options = availableDisplayOptions(preferredID: selectedID)
                if let selectedID,
                   options.contains(where: { $0.id == selectedID }) {
                    return selectedID
                }

                return options.first?.id
            },
            set: { newValue in
                var preferences = video.recordingPreferences
                preferences.selectedFullscreenDisplayID = newValue
                video.recordingPreferences = preferences
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

                            Text(AppBranding.branded(entry.action))
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
    @ObservedObject var permissions: PermissionWorkflowModel

    private var hasAccess: Bool {
        permissions.permissionStatus.hasAccess(to: requirement)
    }

    var body: some View {
        HStack {
            Label(requirement.title, systemImage: requirement.systemImage)
            Spacer()
            Text(hasAccess ? "Allowed" : "Missing")
                .foregroundStyle(hasAccess ? .green : .orange)
            Button(hasAccess ? "Manage" : "Set Up") {
                if hasAccess {
                    permissions.openPermissionSettings(requirement)
                } else {
                    permissions.requestPermission(requirement)
                }
            }
            .disabled(!hasAccess && permissions.activePermissionRequest != nil)

            if !hasAccess {
                Button("Help") {
                    permissions.presentPermissionSetupGuide(for: requirement)
                }
            }
        }
    }
}
