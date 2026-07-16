import AppKit
import Combine

@MainActor
final class MenuBarStatusController: NSObject, NSMenuDelegate {
    static let shared = MenuBarStatusController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let windowCaptureMenu = NSMenu(title: "Window Capture")
    private let capturePresetsMenu = NSMenu(title: "Presets")
    private let videoRecordingMenu = NSMenu(title: "Video Recording")
    private let guideMenu = NSMenu(title: "Guide")
    private let screenRulerMenu = NSMenu(title: "Screen Ruler")
    private let timerMenu = NSMenu(title: "Timer")
    private let regionCaptureSettingsMenu = NSMenu(title: "Region Capture Settings")
    private var cancellables: Set<AnyCancellable> = []
    private weak var lifecycle: AppLifecycleModel?
    private weak var capture: CaptureWorkflowModel?
    private weak var clipboard: ClipboardWorkflowModel?
    private weak var video: VideoWorkflowModel?
    private weak var guide: GuideWorkflowModel?
    private weak var tools: ToolWorkflowModel?
    private weak var floatingReferences: FloatingReferenceCoordinator?
    private weak var workflowCoordinator: AppWorkflowCoordinator?
    private var capabilities: AppCapabilitySnapshot?
    private var consumeOnboardingWindowPresentationFlag: (() -> Bool)?
    private var consumeMainWindowPresentationFlag: (() -> Bool)?
    private var openMainWindowAction: (() -> Void)?
    private var openOnboardingWindowAction: (() -> Void)?
    private var openCapturePresetsSettingsAction: (() -> Void)?

    override init() {
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self

        windowCaptureMenu.autoenablesItems = false
        windowCaptureMenu.delegate = self

        capturePresetsMenu.autoenablesItems = false
        capturePresetsMenu.delegate = self

        videoRecordingMenu.autoenablesItems = false
        videoRecordingMenu.delegate = self
        guideMenu.autoenablesItems = false
        guideMenu.delegate = self

        screenRulerMenu.autoenablesItems = false
        screenRulerMenu.delegate = self

        timerMenu.autoenablesItems = false
        timerMenu.delegate = self

        regionCaptureSettingsMenu.autoenablesItems = false
        regionCaptureSettingsMenu.delegate = self

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: AppBranding.displayName)
            button.imagePosition = .imageOnly
            button.toolTip = AppBranding.displayName
        }

        statusItem.menu = menu
    }

    func configure(
        lifecycle: AppLifecycleModel,
        capture: CaptureWorkflowModel,
        clipboard: ClipboardWorkflowModel,
        video: VideoWorkflowModel,
        guide: GuideWorkflowModel,
        tools: ToolWorkflowModel,
        floatingReferences: FloatingReferenceCoordinator,
        capabilities: AppCapabilitySnapshot,
        workflowCoordinator: AppWorkflowCoordinator,
        consumeOnboardingWindowPresentationFlag: @escaping () -> Bool,
        consumeMainWindowPresentationFlag: @escaping () -> Bool
    ) {
        guard self.lifecycle !== lifecycle || self.capture !== capture else {
            return
        }

        self.lifecycle = lifecycle
        self.capture = capture
        self.clipboard = clipboard
        self.video = video
        self.guide = guide
        self.tools = tools
        self.floatingReferences = floatingReferences
        self.capabilities = capabilities
        self.workflowCoordinator = workflowCoordinator
        self.consumeOnboardingWindowPresentationFlag = consumeOnboardingWindowPresentationFlag
        self.consumeMainWindowPresentationFlag = consumeMainWindowPresentationFlag
        cancellables.removeAll()

        lifecycle.$mainWindowPresentationRequest
            .dropFirst()
            .sink { [weak self] _ in
                self?.performOpenMainWindow()
            }
            .store(in: &cancellables)

        lifecycle.$onboardingPresentationRequest
            .dropFirst()
            .sink { [weak self] _ in
                self?.performOpenOnboardingWindow()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .sssOpenMainWindowRequest)
            .sink { [weak self] _ in
                self?.performOpenMainWindow()
            }
            .store(in: &cancellables)

        guide.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebuildMainMenu() } }
            .store(in: &cancellables)

        rebuildMainMenu()
        capture.refreshAvailableWindows(includeThumbnails: true)
    }

    func setWindowActions(
        openMainWindow: @escaping () -> Void,
        openOnboardingWindow: @escaping () -> Void,
        openCapturePresetsSettings: @escaping () -> Void
    ) {
        openMainWindowAction = openMainWindow
        openOnboardingWindowAction = openOnboardingWindow
        openCapturePresetsSettingsAction = openCapturePresetsSettings
        performInitialWindowPresentationIfNeeded()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu {
        case self.menu:
            rebuildMainMenu()
            capture?.refreshAvailableWindows(includeThumbnails: true)
        case windowCaptureMenu:
            rebuildWindowCaptureMenu()
        case capturePresetsMenu:
            rebuildCapturePresetsMenu()
        case videoRecordingMenu:
            rebuildVideoRecordingMenu()
        case guideMenu:
            rebuildGuideMenu()
        case screenRulerMenu:
            rebuildScreenRulerMenu()
        case timerMenu:
            rebuildTimerMenu()
        case regionCaptureSettingsMenu:
            rebuildRegionCaptureSettingsMenu()
        default:
            break
        }
    }

    @objc private func captureRegion() {
        performMenuAction { [weak self] in self?.capture?.captureRegion() }
    }

    @objc private func captureCurrentDisplay() {
        performMenuAction { [weak self] in self?.capture?.captureCurrentDisplay() }
    }

    @objc private func captureFrontmostWindow() {
        performMenuAction { [weak self] in self?.capture?.captureFrontmostWindow() }
    }

    @objc private func captureScrollingArea() {
        performMenuAction { [weak self] in self?.capture?.captureScrollingArea() }
    }

    @objc private func repeatLastCapture() {
        performMenuAction { [weak self] in self?.capture?.repeatLastCapture() }
    }

    @objc private func capturePreset(_ sender: NSMenuItem) {
        guard let presetID = sender.representedObject as? CapturePreset.ID else {
            return
        }

        performMenuAction { [weak self] in self?.capture?.capturePreset(id: presetID) }
    }

    @objc private func saveLastCaptureAsPreset() {
        performMenuAction { [weak self] in self?.capture?.beginSavingLastCaptureAsPreset() }
    }

    @objc private func manageCapturePresets() {
        openCapturePresetsSettingsAction?()
    }

    @objc private func recordRegion() {
        performMenuAction { [weak self] in self?.video?.recordRegion() }
    }

    @objc private func presentVideoWindowPicker() {
        performMenuAction { [weak self] in self?.video?.presentVideoWindowPicker() }
    }

    @objc private func recordCurrentDisplay() {
        performMenuAction { [weak self] in self?.video?.recordCurrentDisplay() }
    }

    @objc private func stopVideoRecording() {
        performMenuAction { [weak self] in self?.video?.stopVideoRecording() }
    }

    @objc private func presentGuide() { performMenuAction { [weak self] in self?.guide?.presentQuickStart() } }
    @objc private func toggleGuidePause() { performMenuAction { [weak self] in self?.guide?.togglePauseResume() } }
    @objc private func addGuideStep() { performMenuAction { [weak self] in self?.guide?.addManualStep() } }
    @objc private func undoGuideStep() { performMenuAction { [weak self] in self?.guide?.undoLastStep() } }
    @objc private func stopGuide() { performMenuAction { [weak self] in self?.guide?.stopGuide() } }

    @objc private func openMainWindow() {
        performMenuAction { [weak self] in
            self?.workflowCoordinator?.prepareForMainWindowPresentation()
            self?.performOpenMainWindow()
        }
    }

    @objc private func openClipboardHistory() {
        clipboard?.showClipboardManager()
    }

    @objc private func addHorizontalScreenRuler() {
        tools?.presentScreenRuler(.horizontal)
        rebuildMainMenu()
    }

    @objc private func addVerticalScreenRuler() {
        tools?.presentScreenRuler(.vertical)
        rebuildMainMenu()
    }

    @objc private func openScreenInspector() {
        tools?.presentScreenInspector()
        rebuildMainMenu()
    }

    @objc private func toggleAutoCopy() {
        guard let clipboard else {
            return
        }

        clipboard.autoCopyEnabled.toggle()
        rebuildMainMenu()
    }

    @objc private func toggleGlobalHotkeys() {
        guard let capture else {
            return
        }

        var preferences = capture.automationPreferences
        preferences.globalHotkeysEnabled.toggle()
        capture.automationPreferences = preferences
        rebuildMainMenu()
    }

    @objc private func toggleScreenshotCursor() {
        guard let capture else {
            return
        }

        capture.screenshotIncludesCursor.toggle()
        rebuildMainMenu()
    }

    @objc private func toggleUIMap() {
        guard let capture else {
            return
        }

        capture.updateUIMapEnabled(!capture.uiMapEnabled)
        rebuildMainMenu()
    }

    @objc private func setTimerOff() {
        capture?.captureDelay = .immediate
    }

    @objc private func setTimerThreeSeconds() {
        capture?.captureDelay = .threeSeconds
    }

    @objc private func setTimerFiveSeconds() {
        capture?.captureDelay = .fiveSeconds
    }

    @objc private func setTimerTenSeconds() {
        capture?.captureDelay = .tenSeconds
    }

    @objc private func setRegionOverlayCrosshair() {
        updateRegionCapturePreferences { $0.overlayMode = .crosshair }
    }

    @objc private func setRegionOverlayMagnifier() {
        updateRegionCapturePreferences { $0.overlayMode = .magnifyingGlass }
    }

    @objc private func setRegionOverlayCrosshairAndMagnifier() {
        updateRegionCapturePreferences { $0.overlayMode = .crosshairAndMagnifyingGlass }
    }

    @objc private func toggleAlwaysCaptureOnMouseUp() {
        updateRegionCapturePreferences {
            $0.showsActionControls.toggle()
        }
    }

    @objc private func pickWindowOnScreen() {
        performMenuAction { [weak self] in self?.capture?.pickWindowOnScreen() }
    }

    @objc private func captureWindow(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? CaptureWindowSummary else {
            return
        }

        performMenuAction { [weak self] in self?.capture?.captureWindow(window) }
    }

    @objc private func presentWindowPicker() {
        performMenuAction { [weak self] in self?.capture?.presentWindowPicker() }
    }

    @objc private func closeAllFloatingReferences() {
        floatingReferences?.closeAll()
        rebuildMainMenu()
    }

    @objc private func closeAllScreenRulers() {
        tools?.closeAllScreenRulers()
        rebuildMainMenu()
    }

    @objc private func toggleScreenInspector() {
        tools?.toggleScreenInspector()
        rebuildMainMenu()
    }

    @objc private func quitApplication() {
        AppTerminationController.shared.requestQuit()
    }

    private func rebuildMainMenu() {
        guard let lifecycle, let capture, let clipboard, let floatingReferences, let capabilities else {
            return
        }

        menu.removeAllItems()
        updateStatusItemForGuide()

        menu.addItem(actionItem(
            title: "Open \(AppBranding.displayName)",
            systemImage: "menubar.rectangle",
            action: #selector(openMainWindow),
            keyEquivalent: "o",
            keyModifiers: captureShortcutModifiers,
            enabled: true
        ))

        menu.addItem(.separator())

        menu.addItem(captureItem(
            title: "Region Capture",
            systemImage: "selection.pin.in.out",
            action: #selector(captureRegion),
            keyEquivalent: "1",
            enabled: !isCaptureActionDisabled
        ))

        let windowCaptureItem = NSMenuItem(title: "Window Capture", action: nil, keyEquivalent: "2")
        windowCaptureItem.keyEquivalentModifierMask = captureShortcutModifiers
        windowCaptureItem.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        windowCaptureItem.submenu = windowCaptureMenu
        windowCaptureItem.isEnabled = !isCaptureActionDisabled
        menu.addItem(windowCaptureItem)

        menu.addItem(captureItem(
            title: "Full Screen Capture",
            systemImage: "macwindow",
            action: #selector(captureCurrentDisplay),
            keyEquivalent: "3",
            enabled: !isCaptureActionDisabled
        ))

        menu.addItem(captureItem(
            title: "Frontmost Window Capture",
            systemImage: "macwindow.on.rectangle",
            action: #selector(captureFrontmostWindow),
            keyEquivalent: "4",
            enabled: !isCaptureActionDisabled
        ))

        if capabilities.isEnabled(.scrollingCapture) {
            menu.addItem(actionItem(
                title: "Scrolling Capture",
                systemImage: "arrow.down.to.line",
                action: #selector(captureScrollingArea),
                enabled: !isCaptureActionDisabled
            ))
        }

        menu.addItem(actionItem(
            title: "Repeat Last Capture",
            systemImage: "arrow.clockwise",
            action: #selector(repeatLastCapture),
            keyEquivalent: "r",
            keyModifiers: captureShortcutModifiers,
            enabled: !isCaptureActionDisabled && capture.canRepeatLastCapture
        ))

        menu.addItem(.separator())

        let presetsItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presetsItem.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        presetsItem.submenu = capturePresetsMenu
        presetsItem.isEnabled = true
        menu.addItem(presetsItem)

        menu.addItem(.separator())

        let videoRecordingItem = NSMenuItem(title: "Video Recording", action: nil, keyEquivalent: "")
        videoRecordingItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        videoRecordingItem.submenu = videoRecordingMenu
        menu.addItem(videoRecordingItem)

        let guideItem = NSMenuItem(title: guide?.isActive == true ? "Guide · \(guide?.stepCount ?? 0) steps" : "Guide", action: nil, keyEquivalent: "g")
        guideItem.keyEquivalentModifierMask = captureShortcutModifiers
        guideItem.image = NSImage(systemSymbolName: "list.number", accessibilityDescription: nil)
        guideItem.submenu = guideMenu
        guideItem.isEnabled = guide?.isActive == true || !isCaptureActionDisabled
        menu.addItem(guideItem)

        menu.addItem(.separator())

        menu.addItem(actionItem(
            title: "Clipboard History",
            systemImage: "clipboard",
            action: #selector(openClipboardHistory),
            keyEquivalent: "v",
            keyModifiers: [.command, .shift],
            enabled: true
        ))

        let screenRulerItem = NSMenuItem(title: "Screen Ruler", action: nil, keyEquivalent: "")
        screenRulerItem.image = NSImage(systemSymbolName: "ruler", accessibilityDescription: nil)
        screenRulerItem.submenu = screenRulerMenu
        menu.addItem(screenRulerItem)

        menu.addItem(actionItem(
            title: "Screen Inspector",
            systemImage: "scope",
            action: #selector(toggleScreenInspector),
            keyEquivalent: "i",
            keyModifiers: captureShortcutModifiers,
            enabled: true
        ))

        menu.addItem(.separator())

        if floatingReferences.hasActiveReferences {
            menu.addItem(actionItem(
                title: "Close All Floating References",
                systemImage: "xmark.rectangle",
                action: #selector(closeAllFloatingReferences),
                enabled: true
            ))

            menu.addItem(.separator())
        }

        let timerItem = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        timerItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        menu.addItem(toggleItem(
            title: "Include Cursor in Screenshots",
            action: #selector(toggleScreenshotCursor),
            isOn: capture.screenshotIncludesCursor,
            enabled: true,
            toolTip: "Add the cursor as an editable overlay in screenshots. Scrolling Capture always excludes it."
        ))

        if capabilities.isEnabled(.uiMap) {
            menu.addItem(toggleItem(
                title: "Include UI Map for Window Captures",
                action: #selector(toggleUIMap),
                isOn: capture.uiMapEnabled,
                enabled: true,
                toolTip: capture.windowUIMapNeedsAccessibilityAccess
                    ? "Allow Accessibility access before Window UI Map metadata can be captured."
                    : "Save available names, roles, identifiers, and locations of visible interface elements when capturing a window."
            ))
        }

        let regionSettingsItem = NSMenuItem(title: "Region Capture Settings", action: nil, keyEquivalent: "")
        regionSettingsItem.submenu = regionCaptureSettingsMenu
        menu.addItem(regionSettingsItem)

        menu.addItem(toggleItem(
            title: "Auto Copy",
            action: #selector(toggleAutoCopy),
            isOn: clipboard.autoCopyEnabled,
            enabled: true,
            toolTip: "Automatically copy the current rendered snip to the clipboard after each capture and after editor changes."
        ))

        menu.addItem(.separator())

        menu.addItem(toggleItem(
            title: "Global Hotkeys",
            action: #selector(toggleGlobalHotkeys),
            isOn: capture.automationPreferences.globalHotkeysEnabled,
            enabled: true,
            toolTip: "Register capture hotkeys while \(AppBranding.displayName) is not frontmost."
        ))

        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit \(AppBranding.displayName)", systemImage: nil, action: #selector(quitApplication), enabled: true))

        if isCaptureActionDisabled {
            menu.addItem(.separator())

            let workingItem = NSMenuItem(title: lifecycle.workingMessage, action: nil, keyEquivalent: "")
            workingItem.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
            workingItem.isEnabled = false
            menu.addItem(workingItem)
        }

        rebuildVideoRecordingMenu()
        rebuildScreenRulerMenu()
        rebuildTimerMenu()
        rebuildRegionCaptureSettingsMenu()
        rebuildWindowCaptureMenu()
    }

    private func rebuildWindowCaptureMenu() {
        guard let capture, let capabilities else {
            return
        }

        WindowCaptureMenuBuilder.populate(
            windowCaptureMenu,
            context: WindowCaptureMenuContext(
                windows: capture.availableWindows,
                isActionEnabled: !isCaptureActionDisabled,
                isUIMapEnabled: capabilities.isEnabled(.uiMap) && capture.uiMapEnabled
            ),
            target: self,
            pickOnScreenAction: #selector(pickWindowOnScreen),
            captureWindowAction: #selector(captureWindow(_:)),
            presentWindowPickerAction: #selector(presentWindowPicker),
            thumbnailSize: NSSize(width: 128, height: 80)
        )
    }

    private func rebuildVideoRecordingMenu() {
        videoRecordingMenu.removeAllItems()
        let isDisabled = isCaptureActionDisabled

        videoRecordingMenu.addItem(actionItem(
            title: "Record Region",
            systemImage: "record.circle",
            action: #selector(recordRegion),
            enabled: !isDisabled
        ))

        videoRecordingMenu.addItem(actionItem(
            title: "Record Window",
            systemImage: "rectangle.on.rectangle",
            action: #selector(presentVideoWindowPicker),
            enabled: !isDisabled
        ))

        videoRecordingMenu.addItem(actionItem(
            title: "Record Full Screen",
            systemImage: "display",
            action: #selector(recordCurrentDisplay),
            enabled: !isDisabled
        ))

        if isRecordingVideo {
            videoRecordingMenu.addItem(.separator())
            videoRecordingMenu.addItem(actionItem(
                title: "Stop Recording",
                systemImage: "stop.fill",
                action: #selector(stopVideoRecording),
                enabled: true
            ))
        }
    }

    private func rebuildGuideMenu() {
        guideMenu.removeAllItems()
        guard let guide else { return }
        if guide.isActive {
            guideMenu.addItem(actionItem(title: guide.captureCoordinator.state == .paused ? "Resume" : "Pause", systemImage: guide.captureCoordinator.state == .paused ? "play.fill" : "pause.fill", action: #selector(toggleGuidePause), enabled: true))
            guideMenu.addItem(actionItem(title: "Manual Step", systemImage: "plus.square", action: #selector(addGuideStep), enabled: guide.captureCoordinator.state == .recording))
            guideMenu.addItem(actionItem(title: "Undo Last", systemImage: "arrow.uturn.backward", action: #selector(undoGuideStep), enabled: guide.stepCount > 0))
            guideMenu.addItem(.separator())
            guideMenu.addItem(actionItem(title: "Stop Guide", systemImage: "stop.fill", action: #selector(stopGuide), enabled: guide.stepCount > 0))
        } else {
            guideMenu.addItem(actionItem(title: "Start Guide…", systemImage: "list.number", action: #selector(presentGuide), enabled: !isCaptureActionDisabled))
        }
    }

    private func updateStatusItemForGuide() {
        guard let button = statusItem.button else { return }
        if guide?.isActive == true {
            statusItem.length = NSStatusItem.variableLength
            button.image = NSImage(systemSymbolName: "list.number", accessibilityDescription: "Guide active")
            button.title = " \(guide?.stepCount ?? 0)"
            button.toolTip = "Guide active · \(guide?.stepCount ?? 0) steps"
        } else {
            statusItem.length = NSStatusItem.squareLength
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: AppBranding.displayName)
            button.title = ""
            button.toolTip = AppBranding.displayName
        }
    }

    private func rebuildScreenRulerMenu() {
        guard let tools else {
            return
        }

        screenRulerMenu.removeAllItems()
        screenRulerMenu.addItem(actionItem(
            title: "New Horizontal Ruler",
            systemImage: ScreenRulerKind.horizontal.systemImage,
            action: #selector(addHorizontalScreenRuler),
            enabled: true
        ))
        let verticalRulerItem = actionItem(
            title: "New Vertical Ruler",
            systemImage: nil,
            action: #selector(addVerticalScreenRuler),
            enabled: true
        )
        verticalRulerItem.image = verticalRulerMenuImage()
        screenRulerMenu.addItem(verticalRulerItem)

        if tools.screenRulerCoordinator.hasActiveRulers {
            screenRulerMenu.addItem(.separator())
            screenRulerMenu.addItem(actionItem(
                title: "Close All Screen Rulers",
                systemImage: "xmark.rectangle",
                action: #selector(closeAllScreenRulers),
                enabled: true
            ))
        }
    }

    private func rebuildCapturePresetsMenu() {
        guard let capture else {
            return
        }

        capturePresetsMenu.removeAllItems()

        let isEnabled = !isCaptureActionDisabled
        if capture.capturePresets.isEmpty {
            let emptyItem = NSMenuItem(title: "No Presets", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            capturePresetsMenu.addItem(emptyItem)
        } else {
            for preset in capture.capturePresets {
                let item = actionItem(
                    title: capturePresetMenuTitle(preset.name),
                    systemImage: nil,
                    action: #selector(capturePreset(_:)),
                    enabled: isEnabled
                )
                item.image = capturePresetMenuImage(for: preset)
                item.representedObject = preset.id
                capturePresetsMenu.addItem(item)
            }
        }

        capturePresetsMenu.addItem(.separator())
        capturePresetsMenu.addItem(actionItem(
            title: "Save Last Capture as Preset...",
            systemImage: "plus",
            action: #selector(saveLastCaptureAsPreset),
            enabled: isEnabled && capture.canSaveLastCaptureAsPreset
        ))

        capturePresetsMenu.addItem(actionItem(
            title: "Manage Presets...",
            systemImage: "slider.horizontal.3",
            action: #selector(manageCapturePresets),
            enabled: true
        ))
    }

    private func capturePresetMenuTitle(_ name: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.count > 30 else {
            return trimmedName.isEmpty ? "Capture Preset" : trimmedName
        }

        return String(trimmedName.prefix(27)) + "..."
    }

    private func rebuildTimerMenu() {
        guard let capture else {
            return
        }

        timerMenu.removeAllItems()
        timerMenu.addItem(timerItem(title: CaptureDelay.immediate.label, action: #selector(setTimerOff), isSelected: capture.captureDelay == .immediate))
        timerMenu.addItem(timerItem(title: CaptureDelay.threeSeconds.label, action: #selector(setTimerThreeSeconds), isSelected: capture.captureDelay == .threeSeconds))
        timerMenu.addItem(timerItem(title: CaptureDelay.fiveSeconds.label, action: #selector(setTimerFiveSeconds), isSelected: capture.captureDelay == .fiveSeconds))
        timerMenu.addItem(timerItem(title: CaptureDelay.tenSeconds.label, action: #selector(setTimerTenSeconds), isSelected: capture.captureDelay == .tenSeconds))
    }

    private func rebuildRegionCaptureSettingsMenu() {
        guard let capture else {
            return
        }

        regionCaptureSettingsMenu.removeAllItems()

        let overlayMode = capture.regionCapturePreferences.overlayMode
        regionCaptureSettingsMenu.addItem(timerItem(title: RegionCaptureOverlayMode.crosshair.label, action: #selector(setRegionOverlayCrosshair), isSelected: overlayMode == .crosshair))
        regionCaptureSettingsMenu.addItem(timerItem(title: RegionCaptureOverlayMode.magnifyingGlass.label, action: #selector(setRegionOverlayMagnifier), isSelected: overlayMode == .magnifyingGlass))
        regionCaptureSettingsMenu.addItem(timerItem(title: RegionCaptureOverlayMode.crosshairAndMagnifyingGlass.label, action: #selector(setRegionOverlayCrosshairAndMagnifier), isSelected: overlayMode == .crosshairAndMagnifyingGlass))

        regionCaptureSettingsMenu.addItem(.separator())
        regionCaptureSettingsMenu.addItem(toggleItem(
            title: "Always Capture on Mouse Up",
            action: #selector(toggleAlwaysCaptureOnMouseUp),
            isOn: !capture.regionCapturePreferences.showsActionControls,
            enabled: true,
            toolTip: "Capture the selected region immediately when you release the mouse instead of showing Capture and Cancel buttons."
        ))
    }

    private func captureItem(
        title: String,
        systemImage: String,
        action: Selector,
        keyEquivalent: String,
        enabled: Bool
    ) -> NSMenuItem {
        actionItem(
            title: title,
            systemImage: systemImage,
            action: action,
            keyEquivalent: keyEquivalent,
            keyModifiers: captureShortcutModifiers,
            enabled: enabled
        )
    }

    private func actionItem(
        title: String,
        systemImage: String?,
        action: Selector,
        keyEquivalent: String = "",
        keyModifiers: NSEvent.ModifierFlags = [],
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = keyModifiers
        item.isEnabled = enabled

        if let systemImage {
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }

        return item
    }

    private func verticalRulerMenuImage() -> NSImage? {
        guard let baseImage = NSImage(systemSymbolName: ScreenRulerKind.horizontal.systemImage, accessibilityDescription: nil) else {
            return nil
        }

        let image = NSImage(size: NSSize(width: baseImage.size.height, height: baseImage.size.width))
        image.lockFocus()
        defer { image.unlockFocus() }

        let transform = NSAffineTransform()
        transform.translateX(by: image.size.width / 2, yBy: image.size.height / 2)
        transform.rotate(byDegrees: 90)
        transform.translateX(by: -baseImage.size.width / 2, yBy: -baseImage.size.height / 2)
        transform.concat()

        baseImage.draw(at: .zero, from: NSRect(origin: .zero, size: baseImage.size), operation: .sourceOver, fraction: 1)
        image.isTemplate = true
        return image
    }

    private func toggleItem(
        title: String,
        action: Selector,
        isOn: Bool,
        enabled: Bool,
        toolTip: String?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        item.isEnabled = enabled
        item.toolTip = toolTip
        return item
    }

    private func timerItem(title: String, action: Selector, isSelected: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isSelected ? .on : .off
        return item
    }

    private func updateRegionCapturePreferences(_ update: (inout RegionCapturePreferences) -> Void) {
        guard let capture else {
            return
        }

        var preferences = capture.regionCapturePreferences
        update(&preferences)
        capture.regionCapturePreferences = preferences
    }

    private func performOpenMainWindow() {
        openMainWindowAction?()
    }

    private func performOpenOnboardingWindow() {
        openOnboardingWindowAction?()
    }

    private func performInitialWindowPresentationIfNeeded() {
        guard openMainWindowAction != nil, openOnboardingWindowAction != nil else {
            return
        }

        if consumeOnboardingWindowPresentationFlag?() == true {
            performOpenOnboardingWindow()
            return
        }

        if consumeMainWindowPresentationFlag?() == true {
            performOpenMainWindow()
        }
    }

    private func performMenuAction(_ action: @MainActor @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }

    private var isCaptureActionDisabled: Bool {
        capture?.isWorking == true || isRecordingVideo || guide?.isActive == true
    }

    private var isRecordingVideo: Bool {
        video?.activeVideoRecording != nil
    }

    private var captureShortcutModifiers: NSEvent.ModifierFlags {
        [.command, .shift]
    }

}
