import AppKit
import Combine

@MainActor
final class MenuBarStatusController: NSObject, NSMenuDelegate {
    static let shared = MenuBarStatusController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let windowCaptureMenu = NSMenu(title: "Window Capture")
    private let videoRecordingMenu = NSMenu(title: "Video Recording")
    private let screenRulerMenu = NSMenu(title: "Screen Ruler")
    private let timerMenu = NSMenu(title: "Timer")
    private let regionCaptureSettingsMenu = NSMenu(title: "Region Capture Settings")
    private var cancellables: Set<AnyCancellable> = []
    private weak var model: AppModel?
    private var openMainWindowAction: (() -> Void)?
    private var openOnboardingWindowAction: (() -> Void)?

    override init() {
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self

        windowCaptureMenu.autoenablesItems = false
        windowCaptureMenu.delegate = self

        videoRecordingMenu.autoenablesItems = false
        videoRecordingMenu.delegate = self

        screenRulerMenu.autoenablesItems = false
        screenRulerMenu.delegate = self

        timerMenu.autoenablesItems = false
        timerMenu.delegate = self

        regionCaptureSettingsMenu.autoenablesItems = false
        regionCaptureSettingsMenu.delegate = self

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "SnipSnipSnip")
            button.imagePosition = .imageOnly
            button.toolTip = "SnipSnipSnip"
        }

        statusItem.menu = menu
    }

    func configure(with model: AppModel) {
        guard self.model !== model else {
            return
        }

        self.model = model
        cancellables.removeAll()

        model.$mainWindowPresentationRequest
            .dropFirst()
            .sink { [weak self] _ in
                self?.performOpenMainWindow()
            }
            .store(in: &cancellables)

        model.$onboardingPresentationRequest
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

        rebuildMainMenu()
        model.refreshAvailableWindows(includeThumbnails: true)
    }

    func setWindowActions(
        openMainWindow: @escaping () -> Void,
        openOnboardingWindow: @escaping () -> Void
    ) {
        openMainWindowAction = openMainWindow
        openOnboardingWindowAction = openOnboardingWindow
        performInitialWindowPresentationIfNeeded()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu {
        case self.menu:
            rebuildMainMenu()
            model?.refreshAvailableWindows(includeThumbnails: true)
        case windowCaptureMenu:
            rebuildWindowCaptureMenu()
        case videoRecordingMenu:
            rebuildVideoRecordingMenu()
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
        performMenuAction { $0.captureRegion() }
    }

    @objc private func captureCurrentDisplay() {
        performMenuAction { $0.captureCurrentDisplay() }
    }

    @objc private func captureFrontmostWindow() {
        performMenuAction { $0.captureFrontmostWindow() }
    }

    @objc private func captureScrollingArea() {
        performMenuAction { $0.captureScrollingArea() }
    }

    @objc private func repeatLastCapture() {
        performMenuAction { $0.repeatLastCapture() }
    }

    @objc private func recordRegion() {
        performMenuAction { $0.recordRegion() }
    }

    @objc private func presentVideoWindowPicker() {
        performMenuAction { $0.presentVideoWindowPicker() }
    }

    @objc private func recordCurrentDisplay() {
        performMenuAction { $0.recordCurrentDisplay() }
    }

    @objc private func stopVideoRecording() {
        performMenuAction { $0.stopVideoRecording() }
    }

    @objc private func openMainWindow() {
        performMenuAction { [weak self] model in
            model.prepareForMainWindowPresentation()
            self?.performOpenMainWindow()
        }
    }

    @objc private func openClipboardHistory() {
        model?.showClipboardManager()
    }

    @objc private func addHorizontalScreenRuler() {
        model?.presentScreenRuler(.horizontal)
        rebuildMainMenu()
    }

    @objc private func addVerticalScreenRuler() {
        model?.presentScreenRuler(.vertical)
        rebuildMainMenu()
    }

    @objc private func openScreenInspector() {
        model?.presentScreenInspector()
        rebuildMainMenu()
    }

    @objc private func toggleAutoCopy() {
        guard let model else {
            return
        }

        model.autoCopyEnabled.toggle()
        rebuildMainMenu()
    }

    @objc private func toggleGlobalHotkeys() {
        guard let model else {
            return
        }

        var preferences = model.automationPreferences
        preferences.globalHotkeysEnabled.toggle()
        model.automationPreferences = preferences
        rebuildMainMenu()
    }

    @objc private func toggleScreenshotCursor() {
        guard let model else {
            return
        }

        model.screenshotIncludesCursor.toggle()
        rebuildMainMenu()
    }

    @objc private func toggleUIMap() {
        guard let model else {
            return
        }

        model.updateUIMapEnabled(!model.uiMapEnabled)
        rebuildMainMenu()
    }

    @objc private func setTimerOff() {
        model?.captureDelay = .immediate
    }

    @objc private func setTimerThreeSeconds() {
        model?.captureDelay = .threeSeconds
    }

    @objc private func setTimerFiveSeconds() {
        model?.captureDelay = .fiveSeconds
    }

    @objc private func setTimerTenSeconds() {
        model?.captureDelay = .tenSeconds
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
        performMenuAction { $0.pickWindowOnScreen() }
    }

    @objc private func captureWindow(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? CaptureWindowSummary else {
            return
        }

        performMenuAction { $0.captureWindow(window) }
    }

    @objc private func presentWindowPicker() {
        performMenuAction { $0.presentWindowPicker() }
    }

    @objc private func closeAllFloatingReferences() {
        model?.floatingReferenceCoordinator.closeAll()
        rebuildMainMenu()
    }

    @objc private func closeAllScreenRulers() {
        model?.closeAllScreenRulers()
        rebuildMainMenu()
    }

    @objc private func toggleScreenInspector() {
        model?.toggleScreenInspector()
        rebuildMainMenu()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private func rebuildMainMenu() {
        guard let model else {
            return
        }

        menu.removeAllItems()

        menu.addItem(captureItem(
            title: "Region Capture",
            systemImage: "selection.pin.in.out",
            action: #selector(captureRegion),
            keyEquivalent: "1",
            enabled: !isCaptureActionDisabled(for: model)
        ))

        let windowCaptureItem = NSMenuItem(title: "Window Capture", action: nil, keyEquivalent: "2")
        windowCaptureItem.keyEquivalentModifierMask = captureShortcutModifiers
        windowCaptureItem.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        windowCaptureItem.submenu = windowCaptureMenu
        windowCaptureItem.isEnabled = !isCaptureActionDisabled(for: model)
        menu.addItem(windowCaptureItem)

        menu.addItem(captureItem(
            title: "Full Screen Capture",
            systemImage: "macwindow",
            action: #selector(captureCurrentDisplay),
            keyEquivalent: "3",
            enabled: !isCaptureActionDisabled(for: model)
        ))

        menu.addItem(captureItem(
            title: "Frontmost Window Capture",
            systemImage: "macwindow.on.rectangle",
            action: #selector(captureFrontmostWindow),
            keyEquivalent: "4",
            enabled: !isCaptureActionDisabled(for: model)
        ))

        if FeatureFlags.scrollingCaptureEnabled {
            menu.addItem(actionItem(
                title: "Scrolling Capture",
                systemImage: "arrow.down.to.line",
                action: #selector(captureScrollingArea),
                enabled: !isCaptureActionDisabled(for: model)
            ))
        }

        menu.addItem(actionItem(
            title: "Repeat Last Capture",
            systemImage: "arrow.clockwise",
            action: #selector(repeatLastCapture),
            keyEquivalent: "r",
            keyModifiers: captureShortcutModifiers,
            enabled: !isCaptureActionDisabled(for: model) && model.canRepeatLastCapture
        ))

        menu.addItem(.separator())

        let videoRecordingItem = NSMenuItem(title: "Video Recording", action: nil, keyEquivalent: "")
        videoRecordingItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        videoRecordingItem.submenu = videoRecordingMenu
        menu.addItem(videoRecordingItem)

        menu.addItem(.separator())

        menu.addItem(actionItem(
            title: "Open SnipSnipSnip",
            systemImage: "menubar.rectangle",
            action: #selector(openMainWindow),
            keyEquivalent: "o",
            keyModifiers: captureShortcutModifiers,
            enabled: true
        ))

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

        if model.floatingReferenceCoordinator.hasActiveReferences {
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
            isOn: model.screenshotIncludesCursor,
            enabled: true,
            toolTip: "Add the cursor as an editable overlay in screenshots. Scrolling Capture always excludes it."
        ))

        if FeatureFlags.uiMapEnabled {
            menu.addItem(toggleItem(
                title: "Include UI Map",
                action: #selector(toggleUIMap),
                isOn: model.uiMapEnabled,
                enabled: true,
                toolTip: model.uiMapNeedsAccessibilityAccess
                    ? "Grant Accessibility access before UI Map metadata can be captured."
                    : "Save names, roles, and locations of visible interface elements with new screenshots."
            ))
        }

        let regionSettingsItem = NSMenuItem(title: "Region Capture Settings", action: nil, keyEquivalent: "")
        regionSettingsItem.submenu = regionCaptureSettingsMenu
        menu.addItem(regionSettingsItem)

        menu.addItem(toggleItem(
            title: "Auto Copy",
            action: #selector(toggleAutoCopy),
            isOn: model.autoCopyEnabled,
            enabled: true,
            toolTip: "Automatically copy the current rendered snip to the clipboard after each capture and after editor changes."
        ))

        menu.addItem(.separator())

        menu.addItem(toggleItem(
            title: "Global Hotkeys",
            action: #selector(toggleGlobalHotkeys),
            isOn: model.automationPreferences.globalHotkeysEnabled,
            enabled: true,
            toolTip: "Register capture hotkeys while SnipSnipSnip is not frontmost."
        ))

        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit SnipSnipSnip", systemImage: nil, action: #selector(quitApplication), enabled: true))

        if model.isWorking || model.isRecordingVideo {
            menu.addItem(.separator())

            let workingItem = NSMenuItem(title: model.workingMessage, action: nil, keyEquivalent: "")
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
        guard let model else {
            return
        }

        WindowCaptureMenuBuilder.populate(
            windowCaptureMenu,
            for: model,
            target: self,
            pickOnScreenAction: #selector(pickWindowOnScreen),
            captureWindowAction: #selector(captureWindow(_:)),
            presentWindowPickerAction: #selector(presentWindowPicker),
            thumbnailSize: NSSize(width: 128, height: 80)
        )
    }

    private func rebuildVideoRecordingMenu() {
        guard let model else {
            return
        }

        videoRecordingMenu.removeAllItems()
        let isDisabled = isCaptureActionDisabled(for: model)

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

        if model.isRecordingVideo {
            videoRecordingMenu.addItem(.separator())
            videoRecordingMenu.addItem(actionItem(
                title: "Stop Recording",
                systemImage: "stop.fill",
                action: #selector(stopVideoRecording),
                enabled: true
            ))
        }
    }

    private func rebuildScreenRulerMenu() {
        guard let model else {
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

        if model.screenRulerCoordinator.hasActiveRulers {
            screenRulerMenu.addItem(.separator())
            screenRulerMenu.addItem(actionItem(
                title: "Close All Screen Rulers",
                systemImage: "xmark.rectangle",
                action: #selector(closeAllScreenRulers),
                enabled: true
            ))
        }
    }

    private func rebuildTimerMenu() {
        guard let model else {
            return
        }

        timerMenu.removeAllItems()
        timerMenu.addItem(timerItem(title: CaptureDelay.immediate.label, action: #selector(setTimerOff), isSelected: model.captureDelay == .immediate))
        timerMenu.addItem(timerItem(title: CaptureDelay.threeSeconds.label, action: #selector(setTimerThreeSeconds), isSelected: model.captureDelay == .threeSeconds))
        timerMenu.addItem(timerItem(title: CaptureDelay.fiveSeconds.label, action: #selector(setTimerFiveSeconds), isSelected: model.captureDelay == .fiveSeconds))
        timerMenu.addItem(timerItem(title: CaptureDelay.tenSeconds.label, action: #selector(setTimerTenSeconds), isSelected: model.captureDelay == .tenSeconds))
    }

    private func rebuildRegionCaptureSettingsMenu() {
        guard let model else {
            return
        }

        regionCaptureSettingsMenu.removeAllItems()

        let overlayMode = model.regionCapturePreferences.overlayMode
        regionCaptureSettingsMenu.addItem(timerItem(title: RegionCaptureOverlayMode.crosshair.label, action: #selector(setRegionOverlayCrosshair), isSelected: overlayMode == .crosshair))
        regionCaptureSettingsMenu.addItem(timerItem(title: RegionCaptureOverlayMode.magnifyingGlass.label, action: #selector(setRegionOverlayMagnifier), isSelected: overlayMode == .magnifyingGlass))
        regionCaptureSettingsMenu.addItem(timerItem(title: RegionCaptureOverlayMode.crosshairAndMagnifyingGlass.label, action: #selector(setRegionOverlayCrosshairAndMagnifier), isSelected: overlayMode == .crosshairAndMagnifyingGlass))

        regionCaptureSettingsMenu.addItem(.separator())
        regionCaptureSettingsMenu.addItem(toggleItem(
            title: "Always Capture on Mouse Up",
            action: #selector(toggleAlwaysCaptureOnMouseUp),
            isOn: !model.regionCapturePreferences.showsActionControls,
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
        guard let model else {
            return
        }

        var preferences = model.regionCapturePreferences
        update(&preferences)
        model.regionCapturePreferences = preferences
    }

    private func performOpenMainWindow() {
        openMainWindowAction?()
    }

    private func performOpenOnboardingWindow() {
        openOnboardingWindowAction?()
    }

    private func performInitialWindowPresentationIfNeeded() {
        guard let model, openMainWindowAction != nil, openOnboardingWindowAction != nil else {
            return
        }

        if model.consumeOnboardingWindowPresentationFlag() {
            performOpenOnboardingWindow()
            return
        }

        if model.consumeMainWindowPresentationFlag() {
            performOpenMainWindow()
        }
    }

    private func performMenuAction(_ action: @escaping (AppModel) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let model = self?.model else {
                return
            }

            action(model)
        }
    }

    private func isCaptureActionDisabled(for model: AppModel) -> Bool {
        model.isWorking || model.isRecordingVideo
    }

    private var captureShortcutModifiers: NSEvent.ModifierFlags {
        [.command, .shift]
    }

}
