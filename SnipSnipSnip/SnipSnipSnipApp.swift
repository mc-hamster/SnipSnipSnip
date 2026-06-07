import AppKit
import SwiftUI

private struct CaptureCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = MenuBarStatusController.shared.setWindowActions(
            openMainWindow: showMainWindow,
            openOnboardingWindow: showOnboardingWindow
        )

        CommandMenu("Capture") {
            Button("Region Capture", action: model.captureRegion)
                .keyboardShortcut("1", modifiers: AppShortcut.modifiers)
                .disabled(model.isWorking || model.isRecordingVideo)

            Button("Window Capture", action: model.presentWindowPicker)
                .keyboardShortcut("2", modifiers: AppShortcut.modifiers)
                .disabled(model.isWorking || model.isRecordingVideo)

            Button("Full Screen Capture", action: model.captureCurrentDisplay)
                .keyboardShortcut("3", modifiers: AppShortcut.modifiers)
                .disabled(model.isWorking || model.isRecordingVideo)

            Button("Frontmost Window Capture", action: model.captureFrontmostWindow)
                .keyboardShortcut("4", modifiers: AppShortcut.modifiers)
                .disabled(model.isWorking || model.isRecordingVideo)

            if FeatureFlags.scrollingCaptureEnabled {
                Button("Scrolling Capture", action: model.captureScrollingArea)
                    .disabled(model.isWorking || model.isRecordingVideo)
            }

            if FeatureFlags.connectedDeviceCaptureEnabled {
                Menu("Connected Device") {
                    ConnectedDeviceCaptureMenuContent(model: model, mode: .screenshot)
                }
                .disabled(model.isWorking || model.isRecordingVideo || model.isConnectedDeviceSessionActive)
            }

            Divider()

            Menu("Video Recording") {
                Button("Record Region", action: model.recordRegion)
                    .disabled(model.isWorking || model.isRecordingVideo)

                Button("Record Window", action: model.presentVideoWindowPicker)
                    .disabled(model.isWorking || model.isRecordingVideo)

                Button("Record Full Screen", action: model.recordCurrentDisplay)
                    .disabled(model.isWorking || model.isRecordingVideo)

                if FeatureFlags.connectedDeviceCaptureEnabled {
                    Menu("Record Connected Device") {
                        ConnectedDeviceCaptureMenuContent(model: model, mode: .recording)
                    }
                    .disabled(model.isWorking || model.isRecordingVideo || model.isConnectedDeviceSessionActive)
                }

                if model.isRecordingVideo {
                    Divider()

                    Button("Stop Recording", action: model.stopVideoRecording)
                }
            }

            Divider()

            Button("Repeat Last Capture", action: model.repeatLastCapture)
                .keyboardShortcut("r", modifiers: AppShortcut.modifiers)
                .disabled(model.isWorking || model.isRecordingVideo || !model.canRepeatLastCapture)

            Divider()

            Button("Open \(AppBranding.displayName)", action: showMainWindow)
                .keyboardShortcut(AppShortcut.openWindowKey, modifiers: AppShortcut.modifiers)

            Menu("Screen Ruler") {
                Button("New Horizontal Ruler") {
                    model.presentScreenRuler(.horizontal)
                }

                Button("New Vertical Ruler") {
                    model.presentScreenRuler(.vertical)
                }

                if model.screenRulerCoordinator.hasActiveRulers {
                    Divider()

                    Button("Close All Screen Rulers", action: model.closeAllScreenRulers)
                }
            }

            Menu("Screen Inspector") {
                Button("Open Screen Inspector", action: model.presentScreenInspector)
                    .keyboardShortcut("i", modifiers: AppShortcut.modifiers)

                if model.screenInspectorCoordinator.isVisible {
                    Button("Close Screen Inspector", action: model.closeScreenInspector)
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
                CaptureTimerMenuContent(model: model)
            }

            Menu("Screenshot Capture Settings") {
                ScreenshotCaptureSettingsMenuContent(model: model)
            }

            Menu("Region Capture Settings") {
                RegionCaptureSettingsMenuContent(model: model)
            }
        }
    }

    private func showMainWindow() {
        model.prepareForMainWindowPresentation()
        openWindow(id: AppSceneID.mainWindow)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.identifier?.rawValue == AppSceneID.mainWindow })?.makeKeyAndOrderFront(nil)
    }

    private func showOnboardingWindow() {
        openWindow(id: AppSceneID.onboardingWindow)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.identifier?.rawValue == AppSceneID.onboardingWindow })?.makeKeyAndOrderFront(nil)
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

    private var screenInspectorZoomBinding: Binding<ScreenInspectorZoomLevel> {
        screenInspectorBinding(\.zoomLevel)
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

private struct HelpCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("\(AppBranding.displayName) Help", action: showHelpWindow)
                .keyboardShortcut("/", modifiers: [.command, .shift])

            Button("Show Onboarding", action: model.requestOnboardingPresentation)

            Divider()

            Button("Website", action: openWebsite)
            Button("Privacy Policy", action: openPrivacyPolicy)
            Button("Support (Discord)", action: openSupport)
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
        NSWorkspace.shared.open(AppLinks.supportDiscord)
    }
}

private struct DocumentCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…", action: model.openDocumentPanel)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.canOpenDocument)

            Button("Import Image…", action: model.importImagePanel)
                .disabled(!model.canOpenDocument)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save", action: model.saveDocument)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSaveDocument)

            Button("Save As…", action: model.saveDocumentAs)
                .keyboardShortcut("S", modifiers: [.command, .shift])
                .disabled(!model.canSaveDocument)
        }

        CommandGroup(after: .importExport) {
            Menu("Export") {
                if model.videoEditorController != nil {
                    Button("Export \(model.videoExportPreferences.menuLabel)…") {
                        model.exportVideo(using: model.defaultVideoExportRequest)
                    }

                    Divider()

                    Menu("MP4 Quality") {
                        ForEach(VideoExportQualityPreset.allCases) { preset in
                            Button(preset.label) {
                                model.exportVideo(using: VideoExportRequest(format: .mp4, target: .quality(preset)))
                            }
                        }
                    }

                    Menu("MP4 Size Limit") {
                        ForEach(VideoExportSizeLimit.allCases) { sizeLimit in
                            Button(sizeLimit.label) {
                                model.exportVideo(using: VideoExportRequest(format: .mp4, target: .sizeLimit(sizeLimit)))
                            }
                        }
                    }

                    Menu("Animated Loops") {
                        ForEach(VideoExportQualityPreset.allCases) { preset in
                            Button("GIF • \(preset.label)") {
                                model.exportVideo(using: VideoExportRequest(format: .gif, target: .quality(preset)))
                            }

                            Button("APNG • \(preset.label)") {
                                model.exportVideo(using: VideoExportRequest(format: .apng, target: .quality(preset)))
                            }
                        }
                    }

                } else {
                    Button("Export PNG…") {
                        model.exportAnnotatedImage(as: .png)
                    }

                    Button("Export JPEG…") {
                        model.exportAnnotatedImage(as: .jpeg)
                    }
                    .disabled(model.editorController?.requiresPNGForFaithfulExport ?? false)

                    Button("Export PDF…") {
                        model.exportAnnotatedImage(as: .pdf)
                    }
                    .disabled(model.editorController?.requiresPNGForFaithfulExport ?? false)
                }
            }
            .disabled(model.editorController == nil && model.videoEditorController == nil)

            Button("Share…", action: model.shareAnnotatedImage)
                .disabled(model.editorController == nil)
        }
    }
}

private struct PasteboardCommands: Commands {
    @ObservedObject var model: AppModel

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
        }
    }

    private func cut() {
        _ = sendAction(#selector(NSText.cut(_:)))
    }

    private func copy() {
        if sendAction(#selector(NSText.copy(_:))) {
            return
        }

        model.copyCurrentAnnotatedImageToClipboard()
    }

    private func paste() {
        if sendAction(#selector(NSText.paste(_:))) {
            return
        }

        _ = model.editorController?.addImageOverlayFromPasteboard()
    }

    private func selectAll() {
        _ = sendAction(#selector(NSText.selectAll(_:)))
    }

    @discardableResult
    private func sendAction(_ selector: Selector) -> Bool {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

private struct EditorCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Menu("Arrange") {
                Button("Show Layers", action: showLayersWindow)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.editorController == nil)

                Divider()

                Button("Bring Forward") {
                    model.editorController?.bringForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model.editorController?.canBringForward != true)

                Button("Send Backward") {
                    model.editorController?.sendBackward()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model.editorController?.canSendBackward != true)

                Divider()

                Button("Bring to Front") {
                    model.editorController?.sendToFront()
                }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(model.editorController == nil)

                Button("Send to Back") {
                    model.editorController?.sendToBack()
                }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(model.editorController == nil)
            }
            .disabled(model.editorController == nil)

            Divider()

            Button("Group") {
                model.editorController?.groupSelected()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(model.editorController?.canGroupSelection != true)

            Button("Ungroup") {
                model.editorController?.ungroupSelected()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(model.editorController?.canUngroupSelection != true)

            Divider()

            Button("Delete", action: deleteSelection)
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.editorController?.selectedCount == 0)
        }
    }

    private func deleteSelection() {
        model.editorController?.deleteSelected()
    }

    private func showLayersWindow() {
        openWindow(id: AppSceneID.layersWindow)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.identifier?.rawValue == AppSceneID.layersWindow })?.makeKeyAndOrderFront(nil)
    }
}

private struct ReferenceCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var floatingReferences: FloatingReferenceCoordinator

    var body: some Commands {
        CommandMenu("Reference") {
            Button("Float Current Screenshot", action: model.floatCurrentEditorReference)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.editorController == nil)

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
        MenuBarStatusController.shared.configure(with: model)
    }

    var body: some Scene {
        Window(AppBranding.displayName, id: AppSceneID.mainWindow) {
            FirstMouseHostingContainer {
                ContentView(model: model)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            AppInfoCommands()
            HelpCommands(model: model)
            DocumentCommands(model: model)
            PasteboardCommands(model: model)
            EditorCommands(model: model)
            ReferenceCommands(model: model, floatingReferences: model.floatingReferenceCoordinator)
            CaptureCommands(model: model)
        }

        Window("Welcome to \(AppBranding.displayName)", id: AppSceneID.onboardingWindow) {
            OnboardingView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 700)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Window("\(AppBranding.displayName) Help", id: AppSceneID.helpWindow) {
            HelpGuideView()
        }
        .defaultSize(width: 920, height: 760)

        Window("Layers", id: AppSceneID.layersWindow) {
            LayersWindowView(model: model)
        }
        .defaultSize(width: 360, height: 520)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            CaptureAutomationSettingsView(model: model)
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
