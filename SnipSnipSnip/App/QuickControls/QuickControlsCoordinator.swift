import AppKit
import Combine
import SwiftUI

@MainActor
final class QuickControlsCoordinator: NSObject, NSWindowDelegate {
    private let model: QuickControlsModel
    private var palettePanel: NSPanel?
    private var customizationPanel: NSPanel?
    private var preferencesObserver: AnyCancellable?
    private var hasActivated = false
    private var isRestoringFrame = false
    private var pendingDockSnap: DispatchWorkItem?

    init(model: QuickControlsModel) {
        self.model = model
        super.init()

        model.showCustomizationHandler = { [weak self] in
            self?.showCustomization()
        }

        preferencesObserver = model.$preferences
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    self.apply(self.model.preferences)
                }
            }
    }

    func activate() {
        guard !hasActivated else {
            return
        }
        hasActivated = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.apply(self.model.preferences)
        }
    }

    func showPalette() {
        let panel = palettePanel ?? makePalettePanel()
        if palettePanel == nil {
            palettePanel = panel
            restoreFrame(of: panel)
        }
        panel.orderFrontRegardless()
    }

    func hidePalette() {
        palettePanel?.orderOut(nil)
    }

    func showCustomization() {
        let panel: NSPanel
        if let customizationPanel {
            panel = customizationPanel
        } else {
            panel = NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 720),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Customize Quick Controls"
            panel.minSize = NSSize(width: 920, height: 620)
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.moveToActiveSpace]
            panel.delegate = self
            panel.contentView = NSHostingView(
                rootView: QuickControlsCustomizationView(
                    quickControls: model,
                    dismiss: { [weak self] in
                        self?.customizationPanel?.close()
                    }
                )
            )
            panel.center()
            customizationPanel = panel
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidMove(_ notification: Notification) {
        scheduleDockSnap(from: notification)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        if window === customizationPanel {
            customizationPanel = nil
        } else if window === palettePanel {
            palettePanel = nil
            model.setVisible(false)
        }
    }

    private func apply(_ preferences: QuickControlsPreferences) {
        guard hasActivated else {
            return
        }

        if let palettePanel {
            resizeAndAnchorPalette(palettePanel, preferences: preferences)
        }

        switch QuickControlsPaletteVisibilityDecision.resolve(
            isRequestedVisible: preferences.isVisible,
            isPanelVisible: palettePanel?.isVisible == true
        ) {
        case .show:
            showPalette()
        case .preserve:
            break
        case .hide:
            hidePalette()
        }
    }

    private func makePalettePanel() -> NSPanel {
        let preferredSize = model.preferences.resolvedPanelSize
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: preferredSize),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quick Controls"
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        panel.sharingType = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.minSize = preferredSize
        panel.maxSize = preferredSize
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuickControlsView(quickControls: model))
        return panel
    }

    private func restoreFrame(of panel: NSPanel) {
        isRestoringFrame = true
        defer { isRestoringFrame = false }

        if var stored = model.preferences.panelFrame?.cgRect,
           let screen = screenContainingMeaningfulArea(of: stored) {
            stored.size = fittedSize(for: model.preferences, on: screen)
            panel.setFrame(
                anchoredFrame(
                    stored,
                    edge: model.preferences.resolvedDockEdge,
                    on: screen
                ),
                display: false
            )
            return
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        let visibleFrame = screen.visibleFrame
        var frame = panel.frame
        frame.size = fittedSize(for: model.preferences, on: screen)
        frame.origin.y = visibleFrame.maxY - frame.height - QuickControlsDockMetrics.screenEdgeInset
        panel.setFrame(
            anchoredFrame(frame, edge: model.preferences.resolvedDockEdge, on: screen),
            display: false
        )
    }

    private func screenContainingMeaningfulArea(of frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).area < rhs.visibleFrame.intersection(frame).area
        }.flatMap { screen in
            screen.visibleFrame.intersection(frame).area >= 48 * 48 ? screen : nil
        }
    }

    private func resizeAndAnchorPalette(_ panel: NSPanel, preferences: QuickControlsPreferences) {
        isRestoringFrame = true
        defer { isRestoringFrame = false }

        var frame = panel.frame
        let screen = panel.screen ?? screenContainingMeaningfulArea(of: frame) ?? NSScreen.main
        let size = fittedSize(for: preferences, on: screen)
        panel.minSize = size
        panel.maxSize = size
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(
            anchoredFrame(frame, edge: preferences.resolvedDockEdge, on: screen),
            display: true,
            animate: false
        )
    }

    private func anchoredFrame(
        _ candidate: CGRect,
        edge: QuickControlsDockEdge,
        on screen: NSScreen?
    ) -> CGRect {
        guard let visibleFrame = screen?.visibleFrame else {
            return candidate
        }
        var frame = candidate
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.y = min(
            max(frame.minY, visibleFrame.minY),
            visibleFrame.maxY - frame.height
        )
        switch edge {
        case .left:
            frame.origin.x = visibleFrame.minX + QuickControlsDockMetrics.screenEdgeInset
        case .right:
            frame.origin.x = visibleFrame.maxX - frame.width - QuickControlsDockMetrics.screenEdgeInset
        }
        return frame
    }

    private func fittedSize(
        for preferences: QuickControlsPreferences,
        on screen: NSScreen?
    ) -> CGSize {
        let naturalSize = preferences.resolvedPanelSize
        guard let visibleFrame = screen?.visibleFrame else {
            return naturalSize
        }
        return CGSize(
            width: naturalSize.width,
            height: min(
                naturalSize.height,
                max(visibleFrame.height - 24, QuickControlsDockMetrics.compactHeaderHeight + 80)
            )
        )
    }

    private func scheduleDockSnap(from notification: Notification) {
        guard !isRestoringFrame,
              let window = notification.object as? NSWindow,
              window === palettePanel else {
            return
        }
        pendingDockSnap?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            self.snapDock(window)
        }
        pendingDockSnap = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func snapDock(_ panel: NSWindow) {
        guard !isRestoringFrame else { return }
        let screen = panel.screen ?? screenContainingMeaningfulArea(of: panel.frame) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let distanceToLeft = abs(panel.frame.minX - visibleFrame.minX)
        let distanceToRight = abs(visibleFrame.maxX - panel.frame.maxX)
        let edge: QuickControlsDockEdge = distanceToLeft <= distanceToRight ? .left : .right
        var candidate = panel.frame
        candidate.size = fittedSize(for: model.preferences, on: screen)
        let frame = anchoredFrame(candidate, edge: edge, on: screen)
        isRestoringFrame = true
        panel.setFrame(frame, display: true, animate: true)
        isRestoringFrame = false
        model.recordPanelFrame(frame, dockEdge: edge)
    }

}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else {
            return 0
        }
        return width * height
    }
}
