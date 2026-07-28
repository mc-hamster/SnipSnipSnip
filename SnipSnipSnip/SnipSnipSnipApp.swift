import AppKit
import AppIntents
import SwiftUI

/// Routes active-window output availability through SwiftUI's command focus
/// graph. App-scoped `Commands` aren't descendants of `ContentView`, so
/// observing the workflow alone doesn't reliably invalidate live menu items.
struct DocumentOutputCommandAvailabilityKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var documentOutputCommandIsAvailable: Bool? {
        get { self[DocumentOutputCommandAvailabilityKey.self] }
        set { self[DocumentOutputCommandAvailabilityKey.self] = newValue }
    }
}

private struct CaptureCommands: Commands {
    @ObservedObject var lifecycle: AppLifecycleModel
    @ObservedObject var capture: CaptureWorkflowModel
    @ObservedObject var video: VideoWorkflowModel
    @ObservedObject var guide: GuideWorkflowModel
    @ObservedObject var tools: ToolWorkflowModel
    let capabilities: AppCapabilitySnapshot
    let workflowCoordinator: AppWorkflowCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        let _ = MenuBarStatusController.shared.setWindowActions(
            openMainWindow: showMainWindow,
            openOnboardingWindow: showOnboardingWindow,
            openCapturePresetsSettings: showCapturePresetsSettings
        )

        CommandMenu("Capture") {
            Button("Region Capture", action: capture.captureRegion)
                .keyboardShortcut(hotKey(for: .region), modifiers: AppShortcut.modifiers)
                .disabled(isCaptureOrRecordingActive || isNativeFilePanelActive)

            Button("Window Capture", action: capture.presentWindowPicker)
                .keyboardShortcut(hotKey(for: .window), modifiers: AppShortcut.modifiers)
                .disabled(isCaptureOrRecordingActive || isNativeFilePanelActive)

            Button("Full Screen Capture", action: capture.captureCurrentDisplay)
                .keyboardShortcut(hotKey(for: .fullscreen), modifiers: AppShortcut.modifiers)
                .disabled(isCaptureOrRecordingActive || isNativeFilePanelActive)

            Button("Frontmost Window Capture", action: capture.captureFrontmostWindow)
                .keyboardShortcut(hotKey(for: .frontmostWindow), modifiers: AppShortcut.modifiers)
                .disabled(isCaptureOrRecordingActive || isNativeFilePanelActive)

            if capabilities.isEnabled(.scrollingCapture) {
                Button("Scrolling Capture", action: capture.captureScrollingArea)
                    .disabled(isCaptureOrRecordingActive)
            }

            if capabilities.isEnabled(.connectedDeviceCapture) {
                Menu("Connected Device") {
                    ConnectedDeviceCaptureMenuContent(capture: capture, mode: .screenshot)
                }
                .disabled(isCaptureOrRecordingActive || capture.isConnectedDeviceSessionActive)
            }

            Divider()

            if capabilities.isEnabled(.guideCapture) {
                Button(guide.isActive ? "Stop Guide" : "Guide", action: guide.presentQuickStart)
                    .keyboardShortcut(hotKey(for: .guide), modifiers: AppShortcut.modifiers)
                    .disabled((isCaptureOrRecordingActive && !guide.isActive) || capture.isConnectedDeviceSessionActive || isNativeFilePanelActive)

                if guide.isActive {
                    Button(guide.captureCoordinator.state == .paused ? "Resume Guide" : "Pause Guide", action: guide.togglePauseResume)
                    Button("Add Manual Step", action: guide.addManualStep)
                    Button("Undo Last Guide Step", action: guide.undoLastStep)
                        .disabled(guide.stepCount == 0)
                }

                Divider()
            }

            Menu("Video Recording") {
                Button("Record Region", action: video.recordRegion)
                    .disabled(isCaptureOrRecordingActive)

                Button("Record Window", action: video.presentVideoWindowPicker)
                    .disabled(isCaptureOrRecordingActive)

                Button("Record Full Screen", action: video.recordCurrentDisplay)
                    .disabled(isCaptureOrRecordingActive)

                if capabilities.isEnabled(.connectedDeviceCapture) {
                    Menu("Record Connected Device") {
                        ConnectedDeviceCaptureMenuContent(capture: capture, mode: .recording)
                    }
                    .disabled(isCaptureOrRecordingActive || capture.isConnectedDeviceSessionActive)
                }

                if isRecordingVideo {
                    Divider()

                    Button("Stop Recording", action: video.stopVideoRecording)
                }
            }

            Divider()

            Button("Repeat Last Capture", action: capture.repeatLastCapture)
                .keyboardShortcut(hotKey(for: .repeatLastCapture), modifiers: AppShortcut.modifiers)
                .disabled(isCaptureOrRecordingActive || !capture.canRepeatLastCapture || isNativeFilePanelActive)

            Divider()

            Menu("Presets") {
                CapturePresetMenuContent(capture: capture, video: video, lifecycle: lifecycle)
            }

            Divider()

            Button("Open \(AppBranding.displayName)", action: showMainWindow)
                .keyboardShortcut(AppShortcut.openWindowKey, modifiers: AppShortcut.modifiers)

            Menu("Screen Ruler") {
                Button("New Horizontal Ruler") {
                    tools.presentScreenRuler(.horizontal)
                }

                Button("New Vertical Ruler") {
                    tools.presentScreenRuler(.vertical)
                }

                if tools.screenRulerCoordinator.hasActiveRulers {
                    Divider()

                    Button("Close All Screen Rulers", action: tools.closeAllScreenRulers)
                }
            }

            Menu("Screen Inspector") {
                Button("Open Screen Inspector") {
                    tools.presentScreenInspector()
                }
                    .keyboardShortcut(hotKey(for: .screenInspector), modifiers: AppShortcut.modifiers)
                    .disabled(isNativeFilePanelActive)

                if tools.screenInspectorCoordinator.isVisible {
                    Button("Close Screen Inspector", action: tools.closeScreenInspector)
                }

                Divider()

                Picker("Zoom", selection: screenInspectorZoomBinding) {
                    ForEach(ScreenInspectorZoomLevel.allCases) { zoomLevel in
                        Text(zoomLevel.label).tag(zoomLevel)
                    }
                }

                Toggle("Show Pixel Grid", isOn: screenInspectorBinding(\.showsPixelGrid))
                Toggle("Show Crosshair", isOn: screenInspectorBinding(\.showsCrosshair))
            }

            Menu("Timer") {
                CaptureTimerMenuContent(capture: capture)
            }

            Menu("Screenshot Capture Settings") {
                ScreenshotCaptureSettingsMenuContent(capture: capture)
            }

            Menu("Region Capture Settings") {
                RegionCaptureSettingsMenuContent(capture: capture)
            }
        }
    }

    private func showMainWindow() {
        workflowCoordinator.prepareForMainWindowPresentation()
        openWindow(id: AppSceneID.mainWindow)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.identifier?.rawValue == AppSceneID.mainWindow })?.makeKeyAndOrderFront(nil)
    }

    private func showOnboardingWindow() {
        openWindow(id: AppSceneID.onboardingWindow)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.identifier?.rawValue == AppSceneID.onboardingWindow })?.makeKeyAndOrderFront(nil)
    }

    private func showCapturePresetsSettings() {
        lifecycle.selectedSettingsTab = .presets
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
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

    private var screenInspectorZoomBinding: Binding<ScreenInspectorZoomLevel> {
        screenInspectorBinding(\.zoomLevel)
    }

    private var isCaptureOrRecordingActive: Bool {
        capture.isWorking || isRecordingVideo || guide.isActive
    }

    private var isRecordingVideo: Bool {
        video.activeVideoRecording != nil
    }

    private func hotKey(for action: GlobalHotKeyAction) -> KeyEquivalent {
        capture.automationPreferences.key(for: action).keyEquivalent
    }

    private var isNativeFilePanelActive: Bool {
        NativePanelShortcutPolicy.suspendsCaptureKeyEquivalents(for: NSApp.keyWindow)
    }
}

private struct AppInfoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppBranding.displayName)", action: showAboutPanel)
        }
    }

    private func showAboutPanel() {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        NSApp.applicationIconImage = icon
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationIcon: icon
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AppLifecycleCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("Quit \(AppBranding.displayName)", action: AppTerminationController.shared.requestQuit)
                .keyboardShortcut("q", modifiers: [.command])
        }
    }
}

private struct HelpCommands: Commands {
    @ObservedObject var lifecycle: AppLifecycleModel
    let capabilities: AppCapabilitySnapshot
    let requestOnboardingPresentation: () -> Void
    let checkForProUpdates: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("\(AppBranding.displayName) Help", action: showHelpWindow)
                .keyboardShortcut("/", modifiers: [.command, .shift])

            Button("Show Onboarding", action: requestOnboardingPresentation)

            if capabilities.isEnabled(.proUpdateCheck) {
                Button(
                    lifecycle.isCheckingProUpdates ? "Checking for Pro Updates..." : "Check for Pro Updates...",
                    action: checkForProUpdates
                )
                .disabled(lifecycle.isCheckingProUpdates)
            }

            Divider()

            Button("Website", action: openWebsite)
            Button("Privacy Policy", action: openPrivacyPolicy)
            Button("Support", action: openSupport)
        }
    }

    private func showHelpWindow() {
        openWindow(id: AppSceneID.helpWindow)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.identifier?.rawValue == AppSceneID.helpWindow })?.makeKeyAndOrderFront(nil)
    }

    private func openWebsite() {
        NSWorkspace.shared.open(AppLinks.website)
    }

    private func openPrivacyPolicy() {
        NSWorkspace.shared.open(AppLinks.privacyPolicy)
    }

    private func openSupport() {
        NSWorkspace.shared.open(AppLinks.support)
    }
}

private struct DocumentCommands: Commands {
    @ObservedObject var capture: CaptureWorkflowModel
    @ObservedObject var documents: DocumentWorkflowModel
    @ObservedObject var video: VideoWorkflowModel
    @ObservedObject var guide: GuideWorkflowModel
    @ObservedObject var creation: CreationWorkflowModel
    @FocusedValue(\.documentOutputCommandIsAvailable)
    private var focusedDocumentOutputIsAvailable

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Create…") {
                creation.presentQuickStart()
            }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!canOpenDocument)

            Divider()

            Button("Open…", action: documents.openDocumentPanel)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!canOpenDocument)

            Button("Import Image…", action: documents.importImagePanel)
                .disabled(!canOpenDocument)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save", action: documents.saveDocument)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSaveDocument)

            Button("Save As…", action: documents.saveDocumentAs)
                .keyboardShortcut("S", modifiers: [.command, .shift])
                .disabled(!canSaveDocument)
        }

        CommandGroup(after: .importExport) {
            if canExportCurrentContent {
                Menu("Export") {
                    if documents.guideEditorController != nil {
                        Button("Export Guide…", action: documents.exportCurrentGuide)
                    } else if documents.videoEditorController != nil {
                        Button("Export \(video.exportPreferences.menuLabel)…") {
                            video.exportVideo(using: video.defaultExportRequest)
                        }

                        Divider()

                        Menu("MP4 Quality") {
                            ForEach(VideoExportQualityPreset.allCases) { preset in
                                Button(preset.label) {
                                    video.exportVideo(using: VideoExportRequest(format: .mp4, target: .quality(preset)))
                                }
                            }
                        }

                        Menu("MP4 Size Limit") {
                            ForEach(VideoExportSizeLimit.allCases) { sizeLimit in
                                Button(sizeLimit.label) {
                                    video.exportVideo(using: VideoExportRequest(format: .mp4, target: .sizeLimit(sizeLimit)))
                                }
                            }
                        }

                        Menu("Animated Loops") {
                            ForEach(VideoExportQualityPreset.allCases) { preset in
                                Button("GIF • \(preset.label)") {
                                    video.exportVideo(using: VideoExportRequest(format: .gif, target: .quality(preset)))
                                }

                                Button("APNG • \(preset.label)") {
                                    video.exportVideo(using: VideoExportRequest(format: .apng, target: .quality(preset)))
                                }
                            }
                        }

                    } else {
                        Button("PNG…") {
                            documents.exportCurrentWorkspaceImage(as: .png)
                        }
                        Button("JPEG…") {
                            documents.exportCurrentWorkspaceImage(as: .jpeg)
                        }
                        .disabled(documents.currentWorkspaceOutputRequiresPNG)
                        Button("PDF…") {
                            documents.exportCurrentWorkspaceImage(as: .pdf)
                        }
                        .disabled(documents.currentWorkspaceOutputRequiresPNG)
                    }
                }
            } else {
                // A disabled placeholder makes the top-level native menu item
                // accurately communicate that the scoped editing canvas is not
                // an export preview. Disabling a SwiftUI submenu only disables
                // its children and leaves the parent exposed as actionable.
                Button("Export") {}
                    .disabled(true)
            }

            Button("Share", action: documents.shareCurrentWorkspaceImage)
                .disabled(!documentOutputIsAvailable)
        }
    }

    private var canOpenDocument: Bool {
        !capture.isWorking && video.activeVideoRecording == nil && !guide.isActive && !capture.isConnectedDeviceSessionActive
    }

    private var canSaveDocument: Bool {
        (documents.editorController != nil || documents.videoEditorController != nil || documents.guideEditorController != nil)
            && !capture.isWorking
            && video.activeVideoRecording == nil
            && !guide.isActive
    }

    private var canExportCurrentContent: Bool {
        if documents.editorController != nil {
            return documentOutputIsAvailable
        }
        return documents.videoEditorController != nil
            || documents.guideEditorController != nil
    }

    private var documentOutputIsAvailable: Bool {
        focusedDocumentOutputIsAvailable
            ?? documents.isEditorDocumentOutputAvailable
    }
}

private struct PasteboardCommands: Commands {
    @ObservedObject var documents: DocumentWorkflowModel
    @FocusedValue(\.documentOutputCommandIsAvailable)
    private var focusedDocumentOutputIsAvailable

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Cut", action: cut)
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!canCut)

            Button("Copy", action: copy)
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!canCopy)

            Button("Paste", action: paste)
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!canPaste)

            Divider()

            Button("Select All", action: selectAll)
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!canSelectAll)

            Button("Unselect", action: unselect)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(documents.editorController?.hasSelection != true)
        }
    }

    private func cut() {
        if hasNativeTextTarget(for: #selector(NSText.cut(_:))),
           sendAction(#selector(NSText.cut(_:))) {
            return
        }
        guard documents.editorController?.isDocumentOutputAvailable == true,
              documents.editorController?.hasSelection == true else {
            return
        }
        documents.copyCurrentPlainEditorImageToClipboard()
        documents.editorController?.deleteSelected()
    }

    private func copy() {
        if hasNativeTextTarget(for: #selector(NSText.copy(_:))),
           sendAction(#selector(NSText.copy(_:))) {
            return
        }

        guard documents.editorController?.isDocumentOutputAvailable == true else {
            return
        }
        documents.copyCurrentAnnotatedImageToClipboard()
    }

    private func paste() {
        if sendAction(#selector(NSText.paste(_:))) {
            return
        }

        guard let controller = documents.editorController else {
            return
        }
        if controller.workspaceMode == .presentation,
           controller.presentationInspectorTab == .layout,
           controller.compositionEditingScope == .layout {
            documents.pasteImageIntoCurrentComposition()
        } else {
            _ = controller.addImageOverlayFromPasteboard()
        }
    }

    private func selectAll() {
        if sendAction(#selector(NSText.selectAll(_:))) {
            return
        }
        documents.editorController?.selectAll()
    }

    private func unselect() {
        documents.editorController?.clearSelection()
    }

    @discardableResult
    private func sendAction(_ selector: Selector) -> Bool {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    private var canCut: Bool {
        hasNativeTextTarget(for: #selector(NSText.cut(_:)))
            || (
                documentOutputIsAvailable
                    && documents.editorController?.hasSelection == true
            )
    }

    private var canCopy: Bool {
        hasNativeTextTarget(for: #selector(NSText.copy(_:)))
            || documentOutputIsAvailable
    }

    private var canPaste: Bool {
        hasNativeTarget(for: #selector(NSText.paste(_:)))
            || (
                documents.editorController != nil
                    && NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
            )
    }

    private var canSelectAll: Bool {
        hasNativeTarget(for: #selector(NSText.selectAll(_:)))
            || documents.editorController?.snapshot.annotations.isEmpty == false
    }

    private func hasNativeTarget(for selector: Selector) -> Bool {
        NSApp.target(forAction: selector, to: nil, from: nil) != nil
    }

    private func hasNativeTextTarget(for selector: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSText else {
            return false
        }
        return hasNativeTarget(for: selector)
    }

    private var documentOutputIsAvailable: Bool {
        focusedDocumentOutputIsAvailable
            ?? documents.isEditorDocumentOutputAvailable
    }
}

private struct EditorCommands: Commands {
    @ObservedObject var documents: DocumentWorkflowModel
    let capabilities: AppCapabilitySnapshot
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.documentOutputCommandIsAvailable)
    private var focusedDocumentOutputIsAvailable

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Add…") {
                NotificationCenter.default.post(
                    name: .sssRequestContextualCaptureAddition,
                    object: nil
                )
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(
                documents.editorController == nil
                    || !documentOutputIsAvailable
            )

            Button("Show/Hide Inspector") {
                NotificationCenter.default.post(name: .sssToggleEditorInspector, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(documents.editorController == nil)
        }

        CommandGroup(after: .pasteboard) {
            Menu("Arrange") {
                Button("Show Layers", action: showLayersWindow)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(documents.editorController == nil)

                if capabilities.isEnabled(.uiMap) {
                    Button("Show UI Map", action: showUIMapWindow)
                        .keyboardShortcut("u", modifiers: [.command, .shift])
                        .disabled(documents.editorController?.uiMapSnapshot == nil)
                }

                Divider()

                Button("Bring Forward") {
                    documents.editorController?.bringForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(documents.editorController?.canBringForward != true)

                Button("Send Backward") {
                    documents.editorController?.sendBackward()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(documents.editorController?.canSendBackward != true)

                Divider()

                Button("Bring to Front") {
                    documents.editorController?.sendToFront()
                }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(documents.editorController == nil)

                Button("Send to Back") {
                    documents.editorController?.sendToBack()
                }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(documents.editorController == nil)
            }
            .disabled(documents.editorController == nil)

            Divider()

            Button("Group") {
                documents.editorController?.groupSelected()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(documents.editorController?.canGroupSelection != true)

            Button("Ungroup") {
                documents.editorController?.ungroupSelected()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(documents.editorController?.canUngroupSelection != true)

            Divider()

            Button("Delete", action: deleteSelection)
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!canDelete)
        }
    }

    private func deleteSelection() {
        if NSApp.sendAction(#selector(NSResponder.deleteBackward(_:)), to: nil, from: nil) {
            return
        }
        documents.editorController?.deleteSelected()
    }

    private var canDelete: Bool {
        NSApp.target(forAction: #selector(NSResponder.deleteBackward(_:)), to: nil, from: nil) != nil
            || (documents.editorController?.selectedCount ?? 0) > 0
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

    private var documentOutputIsAvailable: Bool {
        focusedDocumentOutputIsAvailable
            ?? documents.isEditorDocumentOutputAvailable
    }
}

private struct ReferenceCommands: Commands {
    @ObservedObject var documents: DocumentWorkflowModel
    @ObservedObject var floatingReferences: FloatingReferenceCoordinator
    @FocusedValue(\.documentOutputCommandIsAvailable)
    private var focusedDocumentOutputIsAvailable

    var body: some Commands {
        CommandMenu("Reference") {
            Button(
                "Float Current Screenshot",
                action: documents.floatCurrentWorkspaceReference
            )
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!documentOutputIsAvailable)

            Divider()

            Button("Close All Floating References") {
                floatingReferences.closeAll()
            }
            .disabled(!floatingReferences.hasActiveReferences)
        }
    }

    private var documentOutputIsAvailable: Bool {
        focusedDocumentOutputIsAvailable
            ?? documents.isEditorDocumentOutputAvailable
    }
}

@main
struct SnipSnipSnipApp: App {
    @NSApplicationDelegateAdaptor(AppOpenBridge.self) private var appOpenBridge
    @StateObject private var model: AppModel

    init() {
        SingleInstanceCoordinator.enforceAtLaunch()
#if DEBUG
        let model = CompositionUITestLaunchSupport.makeAppModel()
#else
        let model = AppModel()
#endif
        _model = StateObject(wrappedValue: model)
        AppTerminationController.shared.configure(
            lifecycle: model.lifecycle,
            guide: model.guide,
            documents: model.documents
        )
        if !AppModel.isRunningUnitTests {
            MenuBarStatusController.shared.configure(
                lifecycle: model.lifecycle,
                capture: model.capture,
                clipboard: model.clipboard,
                video: model.video,
                guide: model.guide,
                tools: model.tools,
                floatingReferences: model.documents.floatingReferenceCoordinator,
                capabilities: model.capabilities,
                workflowCoordinator: model.workflowCoordinator,
                consumeOnboardingWindowPresentationFlag: model.lifecycle.consumeOnboardingWindowPresentationFlag,
                consumeMainWindowPresentationFlag: model.lifecycle.consumeMainWindowPresentationFlag
            )
        }
        AutomationAppleScriptBridge.configure(
            automation: model.automation,
            automationService: model.automationService
        )
        AutomationIntentDependencies.configure(automationService: model.automationService)
        SnipSnipSnipAutomationShortcuts.updateAppShortcutParameters()
#if DEBUG
        CompositionUITestLaunchSupport.installInitialDocumentIfNeeded(in: model)
#endif
    }

    var body: some Scene {
        Window(AppBranding.displayName, id: AppSceneID.mainWindow) {
            FirstMouseHostingContainer {
                ContentView(
                    lifecycle: model.lifecycle,
                    capture: model.capture,
                    permissions: model.permissions,
                    documents: model.documents,
                    clipboard: model.clipboard,
                    video: model.video,
                    guide: model.guide,
                    tools: model.tools,
                    creation: model.creation,
                    capabilities: model.capabilities,
                    workflowCoordinator: model.workflowCoordinator,
                    dismissWelcomeCard: model.lifecycle.dismissWelcomeCard,
                    presentWindowQuickCaptureMenu: {
                        WindowCaptureQuickMenuPresenter.shared.present(
                            capture: model.capture,
                            video: model.video,
                            capabilities: model.capabilities
                        )
                    },
                    performAutomationRequest: { request in
                        _ = await model.automationService.perform(request)
                    }
                )
            }
            // Publish command availability from the scene's SwiftUI tree.
            // ContentView is hosted inside an NSViewRepresentable so values
            // published there cannot cross the nested NSHostingView boundary.
            .modifier(
                DocumentOutputCommandAvailabilityModifier(
                    documents: model.documents
                )
            )
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentSize)
#if DEBUG
        .defaultLaunchBehavior(
            CompositionUITestLaunchSupport.isEnabled ? .presented : .suppressed
        )
#else
        .defaultLaunchBehavior(.suppressed)
#endif
        .restorationBehavior(.disabled)
        .commands {
            AppInfoCommands()
            AppLifecycleCommands()
            HelpCommands(
                lifecycle: model.lifecycle,
                capabilities: model.capabilities,
                requestOnboardingPresentation: {
                    model.workflowCoordinator.prepareForMainWindowPresentation()
                    model.lifecycle.requestOnboardingPresentation()
                },
                checkForProUpdates: model.lifecycle.checkForProUpdates
            )
            DocumentCommands(
                capture: model.capture,
                documents: model.documents,
                video: model.video,
                guide: model.guide,
                creation: model.creation
            )
            PasteboardCommands(documents: model.documents)
            EditorCommands(
                documents: model.documents,
                capabilities: model.capabilities
            )
#if DEBUG
            CompositionUITestCommands(
                documents: model.documents,
                capture: model.capture
            )
#endif
            ReferenceCommands(
                documents: model.documents,
                floatingReferences: model.documents.floatingReferenceCoordinator
            )
            CaptureCommands(
                lifecycle: model.lifecycle,
                capture: model.capture,
                video: model.video,
                guide: model.guide,
                tools: model.tools,
                capabilities: model.capabilities,
                workflowCoordinator: model.workflowCoordinator
            )
        }

        Window("Welcome to \(AppBranding.displayName)", id: AppSceneID.onboardingWindow) {
            OnboardingView(
                lifecycle: model.lifecycle,
                permissions: model.permissions,
                clipboard: model.clipboard,
                capabilities: model.capabilities,
                completeOnboarding: {
                    model.lifecycle.completeOnboarding(
                        requestMainWindowPresentation: model.workflowCoordinator.requestMainWindowPresentation
                    )
                }
            )
        }
        .defaultSize(
            width: OnboardingWindowLayout.idealSize.width,
            height: OnboardingWindowLayout.idealSize.height
        )
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        Window("\(AppBranding.displayName) Help", id: AppSceneID.helpWindow) {
            HelpGuideView(capabilities: model.capabilities, capture: model.capture)
        }
        .defaultSize(width: 920, height: 760)

        Window("Layers", id: AppSceneID.layersWindow) {
            LayersWindowView(documents: model.documents)
        }
        .defaultSize(width: 360, height: 520)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Window("UI Map", id: AppSceneID.uiMapWindow) {
            UIMapWindowView(documents: model.documents, capabilities: model.capabilities)
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            CaptureAutomationSettingsView(
                lifecycle: model.lifecycle,
                capture: model.capture,
                permissions: model.permissions,
                documents: model.documents,
                clipboard: model.clipboard,
                video: model.video,
                guide: model.guide,
                archive: model.archive,
                tools: model.tools,
                capabilities: model.capabilities,
                clock: model.environment.systemServices.clock,
                requestOnboardingPresentation: {
                    model.workflowCoordinator.prepareForMainWindowPresentation()
                    model.lifecycle.requestOnboardingPresentation()
                },
                checkForProUpdates: model.lifecycle.checkForProUpdates,
                resetPreferencesToDefaults: model.workflowCoordinator.resetPreferencesToDefaults
            )
        }
    }
}

private struct DocumentOutputCommandAvailabilityModifier: ViewModifier {
    @ObservedObject var documents: DocumentWorkflowModel

    func body(content: Content) -> some View {
        content.focusedSceneValue(
            \.documentOutputCommandIsAvailable,
            documents.isEditorDocumentOutputAvailable
        )
    }
}

private struct FirstMouseHostingContainer<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> FirstMouseHostingView<Content> {
        FirstMouseHostingView(rootView: content)
    }

    func updateNSView(_ nsView: FirstMouseHostingView<Content>, context: Context) {
        nsView.rootView = content
        nsView.refreshWindowChrome()
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    private var windowChromeObservers: [NSObjectProtocol] = []
    private var isWindowChromeRefreshScheduled = false

    override func viewDidMoveToWindow() {
        removeWindowChromeObservers()
        super.viewDidMoveToWindow()
        refreshWindowChrome()
        observeWindowChromeChanges()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func refreshWindowChrome() {
        applyWindowChrome()

        guard !isWindowChromeRefreshScheduled else {
            return
        }
        isWindowChromeRefreshScheduled = true

        // SwiftUI and AppKit may finish installing or updating the toolbar
        // after this callback. Coalesce a next-turn correction so those
        // changes cannot restore the partial titlebar separator.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.isWindowChromeRefreshScheduled = false
            self.applyWindowChrome()
        }
    }

    private func applyWindowChrome() {
        guard let window else {
            return
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        if window.titlebarSeparatorStyle != .none {
            window.titlebarSeparatorStyle = .none
        }
    }

    private func observeWindowChromeChanges() {
        guard let window else {
            return
        }

        let center = NotificationCenter.default
        windowChromeObservers = [
            center.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshWindowChrome()
                }
            },
            center.addObserver(
                forName: NSWindow.didEndSheetNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshWindowChrome()
                }
            },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshWindowChrome()
                }
            },
        ]
    }

    private func removeWindowChromeObservers() {
        windowChromeObservers.forEach(
            NotificationCenter.default.removeObserver
        )
        windowChromeObservers = []
    }

    deinit {
        MainActor.assumeIsolated {
            removeWindowChromeObservers()
        }
    }
}
