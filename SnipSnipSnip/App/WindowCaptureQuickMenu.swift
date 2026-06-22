import AppKit

@MainActor
struct WindowCaptureMenuContext {
    let windows: [CaptureWindowSummary]
    let isActionEnabled: Bool
    let isUIMapEnabled: Bool
}

@MainActor
enum WindowCaptureMenuBuilder {
    static let suggestedWindowLimit = 5

    static func makeMenu(
        context: WindowCaptureMenuContext,
        target: AnyObject,
        pickOnScreenAction: Selector,
        captureWindowAction: Selector,
        presentWindowPickerAction: Selector,
        thumbnailSize: NSSize
    ) -> NSMenu {
        let menu = NSMenu(title: "Window Capture")
        menu.autoenablesItems = false
        populate(
            menu,
            context: context,
            target: target,
            pickOnScreenAction: pickOnScreenAction,
            captureWindowAction: captureWindowAction,
            presentWindowPickerAction: presentWindowPickerAction,
            thumbnailSize: thumbnailSize
        )
        return menu
    }

    static func populate(
        _ menu: NSMenu,
        context: WindowCaptureMenuContext,
        target: AnyObject,
        pickOnScreenAction: Selector,
        captureWindowAction: Selector,
        presentWindowPickerAction: Selector,
        thumbnailSize: NSSize
    ) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        menu.addItem(actionItem(
            title: "Pick On Screen",
            systemImage: "cursorarrow.click.2",
            action: pickOnScreenAction,
            target: target,
            enabled: context.isActionEnabled,
            toolTip: windowUIMapHelpText(isEnabled: context.isUIMapEnabled)
        ))

        let windows = Array(context.windows.prefix(suggestedWindowLimit))
        if !windows.isEmpty {
            menu.addItem(.separator())

            for window in windows {
                let item = NSMenuItem(
                    title: window.displayTitle,
                    action: captureWindowAction,
                    keyEquivalent: ""
                )
                item.target = target
                item.representedObject = window
                item.toolTip = [
                    window.displayTitle,
                    windowUIMapHelpText(isEnabled: context.isUIMapEnabled)
                ]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                item.image = resizedThumbnailImage(for: window, size: thumbnailSize)
                item.isEnabled = context.isActionEnabled
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: "More Windows…",
            systemImage: "list.bullet.rectangle",
            action: presentWindowPickerAction,
            target: target,
            enabled: context.isActionEnabled,
            toolTip: windowUIMapHelpText(isEnabled: context.isUIMapEnabled)
        ))
    }

    private static func actionItem(
        title: String,
        systemImage: String,
        action: Selector,
        target: AnyObject,
        enabled: Bool,
        toolTip: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        item.isEnabled = enabled
        item.toolTip = toolTip
        return item
    }

    private static func windowUIMapHelpText(isEnabled: Bool) -> String? {
        guard isEnabled else {
            return nil
        }

        return "UI Map enabled for Window captures."
    }

    private static func resizedThumbnailImage(for window: CaptureWindowSummary, size targetSize: NSSize) -> NSImage? {
        guard let thumbnail = window.thumbnail else {
            return NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        }

        let source = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        let image = NSImage(size: targetSize)

        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

@MainActor
final class WindowCaptureQuickMenuPresenter: NSObject {
    static let shared = WindowCaptureQuickMenuPresenter()

    private weak var capture: CaptureWorkflowModel?
    private var activeMenu: NSMenu?
    private var isPresenting = false

    func present(
        capture: CaptureWorkflowModel,
        video: VideoWorkflowModel,
        capabilities: AppCapabilitySnapshot
    ) {
        guard !isPresenting else {
            return
        }

        isPresenting = true
        self.capture = capture
        capture.refreshAvailableWindows(
            includeThumbnails: false,
            allowsCancellingPendingThumbnailRefresh: false
        )
        let context = WindowCaptureMenuContext(
            windows: capture.availableWindows,
            isActionEnabled: !capture.isWorking && video.activeVideoRecording == nil,
            isUIMapEnabled: capabilities.isEnabled(.uiMap) && capture.uiMapEnabled
        )

        let menu = WindowCaptureMenuBuilder.makeMenu(
            context: context,
            target: self,
            pickOnScreenAction: #selector(pickWindowOnScreen),
            captureWindowAction: #selector(captureWindow(_:)),
            presentWindowPickerAction: #selector(presentWindowPicker),
            thumbnailSize: NSSize(width: 64, height: 40)
        )
        activeMenu = menu

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            menu.popUp(positioning: nil, at: self.popupOrigin, in: nil)
            self.activeMenu = nil
            self.isPresenting = false
        }
    }

    @objc private func pickWindowOnScreen() {
        capture?.pickWindowOnScreen()
    }

    @objc private func captureWindow(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? CaptureWindowSummary else {
            return
        }

        capture?.captureWindow(window)
    }

    @objc private func presentWindowPicker() {
        capture?.presentWindowPicker()
    }

    private var popupOrigin: NSPoint {
        let location = NSEvent.mouseLocation
        return NSPoint(x: location.x + 14, y: location.y + 8)
    }
}
