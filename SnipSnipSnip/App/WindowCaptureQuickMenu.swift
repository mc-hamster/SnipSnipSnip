import AppKit

@MainActor
enum WindowCaptureMenuBuilder {
    static let suggestedWindowLimit = 5

    static func makeMenu(
        for model: AppModel,
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
            for: model,
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
        for model: AppModel,
        target: AnyObject,
        pickOnScreenAction: Selector,
        captureWindowAction: Selector,
        presentWindowPickerAction: Selector,
        thumbnailSize: NSSize
    ) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let isEnabled = !(model.isWorking || model.isRecordingVideo)

        menu.addItem(actionItem(
            title: "Pick On Screen",
            systemImage: "cursorarrow.click.2",
            action: pickOnScreenAction,
            target: target,
            enabled: isEnabled
        ))

        let windows = Array(model.availableWindows.prefix(suggestedWindowLimit))
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
                item.toolTip = window.displayTitle
                item.image = resizedThumbnailImage(for: window, size: thumbnailSize)
                item.isEnabled = isEnabled
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: "More Windows…",
            systemImage: "list.bullet.rectangle",
            action: presentWindowPickerAction,
            target: target,
            enabled: isEnabled
        ))
    }

    private static func actionItem(
        title: String,
        systemImage: String,
        action: Selector,
        target: AnyObject,
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        item.isEnabled = enabled
        return item
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

    private weak var model: AppModel?
    private var activeMenu: NSMenu?
    private var isPresenting = false

    func present(for model: AppModel) {
        guard !isPresenting else {
            return
        }

        isPresenting = true
        self.model = model
        model.refreshAvailableWindows(
            includeThumbnails: false,
            allowsCancellingPendingThumbnailRefresh: false
        )

        let menu = WindowCaptureMenuBuilder.makeMenu(
            for: model,
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
        model?.pickWindowOnScreen()
    }

    @objc private func captureWindow(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? CaptureWindowSummary else {
            return
        }

        model?.captureWindow(window)
    }

    @objc private func presentWindowPicker() {
        model?.presentWindowPicker()
    }

    private var popupOrigin: NSPoint {
        let location = NSEvent.mouseLocation
        return NSPoint(x: location.x + 14, y: location.y + 8)
    }
}
