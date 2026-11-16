import AppKit
import Combine
import SwiftUI

@MainActor
final class QuickControlsCoordinator: NSObject, NSWindowDelegate {
    private let model: QuickControlsModel
    private var palettePanel: NSPanel?
    private var customizationPanel: NSPanel?
    private var preferencesObserver: AnyCancellable?
    private var menuTrackingObserver: AnyCancellable?
    private var hasActivated = false
    private var isRestoringFrame = false
    private var pendingDockSnap: DispatchWorkItem?
    private var paletteDisplayID: CGDirectDisplayID?
    private var appliedDockState: QuickControlsDockState?
    private var hoverReveal: QuickControlsIconReveal?
    private var suppressesHoverUntilExit = false
    private var hoverCollapseTimer: Timer?
    private var trackingMenus = Set<ObjectIdentifier>()

    init(model: QuickControlsModel) {
        self.model = model
        super.init()

        model.showCustomizationHandler = { [weak self] in
            self?.showCustomization()
        }
        model.presentationContextProvider = { [weak self] in
            .quickControls(
                displayID: self?.palettePanel?.screen?.gscDisplayID
                    ?? self?.paletteDisplayID
            )
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

        let notifications = NotificationCenter.default
        menuTrackingObserver = notifications.publisher(for: NSMenu.didBeginTrackingNotification)
            .merge(with: notifications.publisher(for: NSMenu.didEndTrackingNotification))
            .sink { [weak self] notification in
                self?.menuTrackingChanged(notification)
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

    private func showPalette() {
        let panel = palettePanel ?? makePalettePanel()
        if palettePanel == nil {
            palettePanel = panel
            restoreFrame(of: panel)
        }
        panel.orderFrontRegardless()
    }

    private func hidePalette() {
        cancelDockSnap()
        palettePanel?.orderOut(nil)
        endHoverReveal(suppressUntilExit: false)
        suppressesHoverUntilExit = false
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
            cancelDockSnap()
            updateHoverReveal(nil)
            cancelHoverCollapse()
            suppressesHoverUntilExit = false
            model.setVisible(false)
        }
    }

    private func apply(_ preferences: QuickControlsPreferences) {
        guard hasActivated else {
            return
        }

        let visibility = QuickControlsPaletteVisibilityDecision.resolve(
            isRequestedVisible: preferences.isVisible,
            isPanelVisible: palettePanel?.isVisible == true
        )
        guard visibility != .hide else {
            hidePalette()
            return
        }

        if let palettePanel {
            let mode = preferences.resolvedDockState
            let modeChanged = appliedDockState != mode
            let baseFrame = restingFrame(of: palettePanel)
            appliedDockState = mode
            if modeChanged {
                suppressesHoverUntilExit = mode == .iconOnly
                updateHoverReveal(nil)
                cancelHoverCollapse()
            }
            resizeAndAnchorPalette(palettePanel, preferences: preferences, from: baseFrame)
            if modeChanged {
                suppressesHoverUntilExit = mode == .iconOnly && pointerIsOver(palettePanel)
                model.recordPanelFrame(palettePanel.frame, dockEdge: preferences.resolvedDockEdge)
            }
        }
        if visibility == .show {
            showPalette()
        }
    }

    private func makePalettePanel() -> NSPanel {
        let preferredSize = model.preferences.resolvedPanelSize
        appliedDockState = model.preferences.resolvedDockState
        let panel = QuickControlsPalettePanel(
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
        panel.becomesKeyOnlyIfNeeded = true
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
        let hostingView = QuickControlsPaletteHostingView(rootView: paletteContent)
        hostingView.sizingOptions = []
        hostingView.pointerPresenceChanged = { [weak self] in self?.pointerPresenceChanged() }
        panel.contentView = hostingView
        return panel
    }

    private var paletteContent: QuickControlsView {
        QuickControlsView(quickControls: model, hoverReveal: hoverReveal) { [weak self] in
            self?.endHoverReveal(suppressUntilExit: true)
        }
    }

    private func updateHoverReveal(_ reveal: QuickControlsIconReveal?) {
        guard hoverReveal != reveal else { return }
        hoverReveal = reveal
        (palettePanel?.contentView as? QuickControlsPaletteHostingView)?.rootView = paletteContent
    }

    private func restingFrame(of panel: NSWindow) -> CGRect {
        hoverReveal?.iconFrame(in: panel.frame, edge: model.preferences.resolvedDockEdge) ?? panel.frame
    }

    private func pointerIsOver(_ panel: NSWindow) -> Bool {
        panel.frame.contains(NSEvent.mouseLocation)
    }

    private func pointerPresenceChanged() {
        guard !isRestoringFrame, let panel = palettePanel, panel.isVisible,
              appliedDockState == .iconOnly, model.preferences.resolvedDockState == .iconOnly else { return }

        if pointerIsOver(panel) {
            cancelHoverCollapse()
            guard hoverReveal == nil, !suppressesHoverUntilExit, trackingMenus.isEmpty,
                  NSEvent.pressedMouseButtons == 0 else { return }
            guard let screen = screen(withDisplayID: paletteDisplayID) ?? panel.screen else { return }
            revealFull(on: panel, from: panel.frame, screen: screen, preferences: model.preferences)
        } else {
            suppressesHoverUntilExit = false
            scheduleHoverCollapse()
        }
    }

    private func menuTrackingChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        if notification.name == NSMenu.didBeginTrackingNotification {
            trackingMenus.insert(ObjectIdentifier(menu))
            cancelHoverCollapse()
        } else {
            trackingMenus.remove(ObjectIdentifier(menu))
            if trackingMenus.isEmpty {
                pointerPresenceChanged()
            }
        }
    }

    private func scheduleHoverCollapse() {
        cancelHoverCollapse()
        guard hoverReveal != nil, trackingMenus.isEmpty else { return }
        // The default run-loop mode also defers collapse during native menu and mouse tracking.
        hoverCollapseTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.palettePanel, !self.pointerIsOver(panel) else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 || self.pendingDockSnap != nil {
                    self.scheduleHoverCollapse()
                } else {
                    self.endHoverReveal(suppressUntilExit: false)
                }
            }
        }
    }

    private func cancelHoverCollapse() {
        hoverCollapseTimer?.invalidate()
        hoverCollapseTimer = nil
    }

    private func endHoverReveal(suppressUntilExit: Bool) {
        cancelHoverCollapse()
        guard hoverReveal != nil, let panel = palettePanel else { return }
        let frame = restingFrame(of: panel)
        suppressesHoverUntilExit = suppressUntilExit && frame.contains(NSEvent.mouseLocation)
        updateHoverReveal(nil)
        setPaletteFrame(frame, on: panel)
    }

    private func restoreFrame(of panel: NSPanel) {
        isRestoringFrame = true
        defer { isRestoringFrame = false }

        if var stored = model.preferences.panelFrame?.cgRect,
           let screen = screenContainingMeaningfulArea(of: stored) {
            paletteDisplayID = screen.gscDisplayID
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
        paletteDisplayID = screen.gscDisplayID
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

    private func resizeAndAnchorPalette(
        _ panel: NSPanel,
        preferences: QuickControlsPreferences,
        from baseFrame: CGRect
    ) {
        var frame = baseFrame
        let screen = screen(withDisplayID: paletteDisplayID)
            ?? panel.screen
            ?? screenContainingMeaningfulArea(of: frame)
            ?? NSScreen.main
        paletteDisplayID = screen?.gscDisplayID
        let size = fittedSize(for: preferences, on: screen)
        frame.origin.y += frame.height - size.height
        frame.size = size
        let edge = preferences.resolvedDockEdge
        frame = anchoredFrame(frame, edge: edge, on: screen)
        if hoverReveal != nil, let screen {
            revealFull(on: panel, from: frame, screen: screen, preferences: preferences)
        } else {
            updateHoverReveal(nil)
            setPaletteFrame(frame, on: panel)
        }
    }

    private func revealFull(
        on panel: NSWindow,
        from iconFrame: CGRect,
        screen: NSScreen,
        preferences: QuickControlsPreferences
    ) {
        let size = fittedSize(for: preferences, presentation: .full, on: screen)
        let visibleFrame = screen.visibleFrame
        let reveal = QuickControlsIconReveal(iconFrame: iconFrame, visibleFrame: visibleFrame, fullHeight: size.height)
        let frame = reveal.fullFrame(from: iconFrame, size: size, edge: preferences.resolvedDockEdge,
                                     visibleFrame: visibleFrame)
        setPaletteFrame(frame, on: panel)
        updateHoverReveal(reveal)
    }

    private func setPaletteFrame(_ frame: CGRect, on panel: NSWindow, animate: Bool = false) {
        guard frame != panel.frame else { return }
        isRestoringFrame = true
        defer { isRestoringFrame = false }
        panel.minSize = frame.size
        panel.maxSize = frame.size
        panel.setFrame(frame, display: true, animate: animate)
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
        presentation: QuickControlsDockState? = nil,
        on screen: NSScreen?
    ) -> CGSize {
        let naturalSize = preferences.panelSize(for: presentation ?? preferences.resolvedDockState)
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
        cancelDockSnap()
        let workItem = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            self.snapDock(window)
        }
        pendingDockSnap = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func cancelDockSnap() {
        pendingDockSnap?.cancel()
        pendingDockSnap = nil
    }

    private func snapDock(_ panel: NSWindow) {
        pendingDockSnap = nil
        guard !isRestoringFrame else { return }
        // A pause in pointer movement is not the end of a window drag.
        // Wait for release before snapping or publishing a new saved frame.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            scheduleDockSnap(from: Notification(name: NSWindow.didMoveNotification, object: panel))
            return
        }
        guard let screen = panel.screen ?? screenContainingMeaningfulArea(of: panel.frame) ?? NSScreen.main else {
            return
        }
        let visibleFrame = screen.visibleFrame
        paletteDisplayID = screen.gscDisplayID
        let distanceToLeft = abs(panel.frame.minX - visibleFrame.minX)
        let distanceToRight = abs(visibleFrame.maxX - panel.frame.maxX)
        let edge: QuickControlsDockEdge = distanceToLeft <= distanceToRight ? .left : .right
        var candidate = restingFrame(of: panel)
        cancelHoverCollapse()
        candidate.size = fittedSize(for: model.preferences, on: screen)
        let frame = anchoredFrame(candidate, edge: edge, on: screen)
        if hoverReveal != nil {
            var preferences = model.preferences
            preferences.dockEdge = edge
            revealFull(on: panel, from: frame, screen: screen, preferences: preferences)
            if !pointerIsOver(panel) {
                scheduleHoverCollapse()
            }
        } else {
            setPaletteFrame(frame, on: panel, animate: true)
        }
        model.recordPanelFrame(frame, dockEdge: edge)
    }

    private func screen(
        withDisplayID displayID: CGDirectDisplayID?
    ) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { $0.gscDisplayID == displayID }
    }

}

private final class QuickControlsPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class QuickControlsPaletteHostingView: NSHostingView<QuickControlsView> {
    var pointerPresenceChanged: (() -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerPresenceChanged?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointerPresenceChanged?()
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
