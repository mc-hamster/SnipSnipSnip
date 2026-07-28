import AppKit
import Foundation
import SwiftUI

struct AppWindowVisibilityToken: Hashable {
    fileprivate let id = UUID()
}

@MainActor
protocol AppWindowPresenting: AnyObject {
    func hideAppWindowIfNeeded() -> AppWindowVisibilityToken?
    func restoreAppWindowIfNeeded(_ token: AppWindowVisibilityToken?)
    func promoteToRegularApp()
    func demoteToAccessoryIfPossible()
    func activateApp()
}

@MainActor
func presentAppScene(id: String, using openWindow: OpenWindowAction) {
    openWindow(id: id)
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first {
        $0.identifier?.rawValue == id
    }?.makeKeyAndOrderFront(nil)
}

@MainActor
final class LiveAppWindowPresenter: AppWindowPresenting {
    private let requestMainWindowPresentation: @MainActor () -> Void
    private let windowProvider: @MainActor () -> [NSWindow]
    private let keyWindowProvider: @MainActor () -> NSWindow?
    private let mainWindowProvider: @MainActor () -> NSWindow?
    private var hiddenWindows: [AppWindowVisibilityToken: WeakWindow] = [:]

    init(
        requestMainWindowPresentation: @escaping @MainActor () -> Void,
        windowProvider: @escaping @MainActor () -> [NSWindow] = { NSApp.windows },
        keyWindowProvider: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
        mainWindowProvider: @escaping @MainActor () -> NSWindow? = { NSApp.mainWindow }
    ) {
        self.requestMainWindowPresentation = requestMainWindowPresentation
        self.windowProvider = windowProvider
        self.keyWindowProvider = keyWindowProvider
        self.mainWindowProvider = mainWindowProvider
    }

    func hideAppWindowIfNeeded() -> AppWindowVisibilityToken? {
        let windows = windowProvider()
        let window = windows.first(where: {
            $0.identifier?.rawValue == AppSceneID.mainWindow && $0.isVisible && !$0.isMiniaturized
        }) ?? nonRulerWindow(keyWindowProvider()) ?? nonRulerWindow(mainWindowProvider()) ?? windows.first(where: {
            $0.isVisible && !$0.isMiniaturized && !ScreenRulerWindowID.isScreenRulerWindow($0)
        })

        guard let window, window.isVisible, !window.isMiniaturized else {
            return nil
        }

        window.orderOut(nil)
        let token = AppWindowVisibilityToken()
        hiddenWindows[token] = WeakWindow(window)
        return token
    }

    func restoreAppWindowIfNeeded(_ token: AppWindowVisibilityToken?) {
        guard let token else {
            return
        }

        guard let window = hiddenWindows.removeValue(forKey: token)?.window else {
            requestMainWindowPresentation()
            return
        }

        promoteToRegularApp()
        NSApp.activate(ignoringOtherApps: true)

        if windowProvider().contains(where: { $0 === window }) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        requestMainWindowPresentation()
    }

    func promoteToRegularApp() {
        guard NSApp.activationPolicy() != .regular else {
            return
        }

        NSApp.setActivationPolicy(.regular)
    }

    func demoteToAccessoryIfPossible() {
        let hasOpenMainWindow = windowProvider().contains { window in
            window.identifier?.rawValue == AppSceneID.mainWindow && (window.isVisible || window.isMiniaturized)
        }

        guard !hasOpenMainWindow, NSApp.activationPolicy() != .accessory else {
            return
        }

        NSApp.setActivationPolicy(.accessory)
    }

    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func nonRulerWindow(_ window: NSWindow?) -> NSWindow? {
        guard let window, !ScreenRulerWindowID.isScreenRulerWindow(window) else {
            return nil
        }

        return window
    }
}

private final class WeakWindow {
    weak var window: NSWindow?

    init(_ window: NSWindow) {
        self.window = window
    }
}
