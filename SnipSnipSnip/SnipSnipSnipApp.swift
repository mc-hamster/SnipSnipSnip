import AppKit
import AppIntents
import SwiftUI

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
                .keyboardShortcut("1", modifiers: AppShortcut.modifiers)
                .disabled(isCaptureOrRecordingActive)

            Button("Window Capture", action: capture.presentWindowPicker)
                .keyboardShortcut("2", modifiers: AppShortcut.modifiers)
                .disabled(isCaptureOrRecordingActive)

            Button("Full Screen Capture", action: capture.captureCurrentDisplay)
                .keyboardShortcut("3", modifiers: AppShortcut.modifiers)
                .disabled(isCaptureOrRecordingActive)

            Button("Frontmost Window Capture", action: capture.captureFrontmostWindow)
                .keyboardShortcut("4", modifiers: AppShortcut.modifiers)
                .disabled(isCaptureOrRecordingActive)

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

            Button(guide.isActive ? "Stop Guide" : "Guide", action: guide.presentQuickStart)
                .keyboardShortcut("g", modifiers: AppShortcut.modifiers)
                .disabled((isCaptureOrRecordingActive && !guide.isActive) || capture.isConnectedDeviceSessionActive)

            if guide.isActive {
                Button(guide.captureCoordinator.state == .paused ? "Resume Guide" : "Pause Guide", action: guide.togglePauseResume)
                Button("Add Manual Step", action: guide.addManualStep)
                Button("Undo Last Guide Step", action: guide.undoLastStep)
                    .disabled(guide.stepCount == 0)
            }

            Divider()

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
                .keyboardShortcut("r", modifiers: AppShortcut.modifiers)
                .disabled(isCaptureOrRecordingActive || !capture.canRepeatLastCapture)

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
                Button("Open Screen Inspector", action: tools.presentScreenInspector)
                    .keyboardShortcut("i", modifiers: AppShortcut.modifiers)

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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
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
                    Button("Export PNG…") {
                        documents.exportAnnotatedImage(as: .png)
                    }

                    Button("Export JPEG…") {
                        documents.exportAnnotatedImage(as: .jpeg)
                    }
                    .disabled(documents.editorController?.requiresPNGForFaithfulExport ?? false)

                    Button("Export PDF…") {
                        documents.exportAnnotatedImage(as: .pdf)
                    }
                    .disabled(documents.editorController?.requiresPNGForFaithfulExport ?? false)
                }
            }
            .disabled(documents.editorController == nil && documents.videoEditorController == nil && documents.guideEditorController == nil)

            Button("Share…", action: documents.shareAnnotatedImage)
                .disabled(documents.editorController == nil)
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
}

private struct PasteboardCommands: Commands {
    @ObservedObject var documents: DocumentWorkflowModel

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Cut", action: cut)
                .keyboardShortcut("x", modifiers: .command)

            Button("Copy", action: copy)
                .keyboardShortcut("c", modifiers: .command)

            Button("Paste", action: paste)
                .keyboardShortcut("v", modifiers: .command)

            Divider()

            Button("Select All", action: selectAll)
                .keyboardShortcut("a", modifiers: .command)

            Button("Unselect", action: unselect)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(documents.editorController?.hasSelection != true)
        }
    }

    private func cut() {
        _ = sendAction(#selector(NSText.cut(_:)))
    }

    private func copy() {
        if sendAction(#selector(NSText.copy(_:))) {
            return
        }

        documents.copyCurrentAnnotatedImageToClipboard()
    }

    private func paste() {
        if sendAction(#selector(NSText.paste(_:))) {
            return
        }

        _ = documents.editorController?.addImageOverlayFromPasteboard()
    }

    private func selectAll() {
        _ = sendAction(#selector(NSText.selectAll(_:)))
    }

    private func unselect() {
        documents.editorController?.clearSelection()
    }

    @discardableResult
    private func sendAction(_ selector: Selector) -> Bool {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

private struct EditorCommands: Commands {
    @ObservedObject var documents: DocumentWorkflowModel
    let capabilities: AppCapabilitySnapshot
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
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
                .disabled(documents.editorController?.selectedCount == 0)
        }
    }

    private func deleteSelection() {
        documents.editorController?.deleteSelected()
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
}

private struct ReferenceCommands: Commands {
    @ObservedObject var documents: DocumentWorkflowModel
    @ObservedObject var floatingReferences: FloatingReferenceCoordinator

    var body: some Commands {
        CommandMenu("Reference") {
            Button("Float Current Screenshot", action: documents.floatCurrentEditorReference)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(documents.editorController == nil)

            Divider()

            Button("Close All Floating References") {
                floatingReferences.closeAll()
            }
            .disabled(!floatingReferences.hasActiveReferences)
        }
    }
}

@main
struct SnipSnipSnipApp: App {
    @NSApplicationDelegateAdaptor(AppOpenBridge.self) private var appOpenBridge
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        AppTerminationController.shared.configure(
            lifecycle: model.lifecycle,
            guide: model.guide,
            documents: model.documents
        )
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
        AutomationAppleScriptBridge.configure(
            automation: model.automation,
            automationService: model.automationService
        )
        AutomationIntentDependencies.configure(automationService: model.automationService)
        SnipSnipSnipAutomationShortcuts.updateAppShortcutParameters()
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
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
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
                guide: model.guide
            )
            PasteboardCommands(documents: model.documents)
            EditorCommands(documents: model.documents, capabilities: model.capabilities)
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
                capture: model.capture,
                permissions: model.permissions,
                clipboard: model.clipboard,
                guide: model.guide,
                capabilities: model.capabilities,
                skipOnboarding: {
                    model.lifecycle.skipOnboarding(
                        requestMainWindowPresentation: model.workflowCoordinator.requestMainWindowPresentation
                    )
                },
                completeOnboarding: {
                    model.lifecycle.completeOnboarding(
                        requestMainWindowPresentation: model.workflowCoordinator.requestMainWindowPresentation
                    )
                }
            )
        }
        .defaultSize(width: 980, height: 700)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Window("\(AppBranding.displayName) Help", id: AppSceneID.helpWindow) {
            HelpGuideView(capabilities: model.capabilities)
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
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
