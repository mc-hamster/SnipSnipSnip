import AppKit
import CoreGraphics

@MainActor
final class ScrollingSelectionSession: NSObject {
    private let snapshot: DesktopCompositeSnapshot
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private var coordinator: ScrollingSelectionCoordinator?
    private var overlayWindows: [ScrollingSelectionWindow] = []

    init(snapshot: DesktopCompositeSnapshot) {
        self.snapshot = snapshot
    }

    func begin() async -> CGRect? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentOverlay()
        }
    }

    private func presentOverlay() {
        NSApp.activate(ignoringOtherApps: true)

        let coordinator = ScrollingSelectionCoordinator(snapshot: snapshot) { [weak self] selection in
            self?.finish(with: selection)
        }
        self.coordinator = coordinator

        overlayWindows = snapshot.displayPreviews.map { displayPreview in
            let overlay = ScrollingSelectionWindow(displayPreview: displayPreview, coordinator: coordinator)
            overlay.orderFrontRegardless()
            return overlay
        }

        overlayWindows.first?.makeKeyAndOrderFront(nil)
    }

    private func finish(with selection: CGRect?) {
        let continuation = continuation
        self.continuation = nil
        coordinator = nil
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = []
        continuation?.resume(returning: selection)
    }
}

private final class ScrollingSelectionWindow: NSWindow {
    init(displayPreview: DisplayPreview, coordinator: ScrollingSelectionCoordinator) {
        super.init(
            contentRect: displayPreview.snapshot.overlayFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        contentView = ScrollingSelectionView(displayPreview: displayPreview, coordinator: coordinator)
        makeFirstResponder(contentView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class ScrollingSelectionCoordinator {
    private let snapshot: DesktopCompositeSnapshot
    private let onComplete: (CGRect?) -> Void
    private var views: [WeakView] = []
    private var dragAnchor: CGPoint?
    private var actionControlsDisplayID: CGDirectDisplayID?
    private var actionControlsGlobalPoint: CGPoint?

    private struct WeakView {
        weak var view: ScrollingSelectionView?
    }

    private(set) var selectionRect: CGRect?
    private(set) var cursorGlobalPoint: CGPoint?
    private(set) var activeDisplayID: CGDirectDisplayID?

    init(snapshot: DesktopCompositeSnapshot, onComplete: @escaping (CGRect?) -> Void) {
        self.snapshot = snapshot
        self.onComplete = onComplete
    }

    func register(_ view: ScrollingSelectionView) {
        views.append(WeakView(view: view))
    }

    func shouldShowActionControls(on displayID: CGDirectDisplayID) -> Bool {
        actionControlsDisplayID == displayID && selectionRect != nil
    }

    func actionControlsPoint(for display: DisplaySnapshot) -> CGPoint? {
        guard let actionControlsGlobalPoint else {
            return nil
        }

        let localPoint = display.captureDisplayTransform.overlayLocalPoint(fromCaptureGlobalPoint: actionControlsGlobalPoint)
        guard localPoint.gscIsFinite else {
            return nil
        }

        return localPoint
    }

    func mouseMoved(to point: CGPoint) {
        guard point.gscIsFinite else {
            return
        }

        cursorGlobalPoint = point
        activeDisplayID = displayID(containing: point)
        notifyViews()
    }

    func mouseDown(at point: CGPoint, in window: NSWindow?) {
        guard point.gscIsFinite else {
            return
        }

        window?.makeKeyAndOrderFront(nil)
        cursorGlobalPoint = point
        activeDisplayID = displayID(containing: point)
        dragAnchor = point
        actionControlsDisplayID = nil
        actionControlsGlobalPoint = nil
        selectionRect = nil
        notifyViews()
    }

    func mouseDragged(to point: CGPoint) {
        guard point.gscIsFinite else {
            return
        }

        cursorGlobalPoint = point
        activeDisplayID = displayID(containing: point)

        guard let dragAnchor else {
            return
        }

        let candidateRect = CGRect(
            x: min(dragAnchor.x, point.x),
            y: min(dragAnchor.y, point.y),
            width: abs(point.x - dragAnchor.x),
            height: abs(point.y - dragAnchor.y)
        ).gscClamped(to: snapshot.globalFrame)

        guard candidateRect.gscIsFinite else {
            selectionRect = nil
            return
        }

        selectionRect = candidateRect
        notifyViews()
    }

    func mouseUp(at point: CGPoint) {
        guard point.gscIsFinite else {
            return
        }

        cursorGlobalPoint = point
        activeDisplayID = displayID(containing: point)
        dragAnchor = nil

        guard let selectionRect, selectionRect.width > 8, selectionRect.height > 8 else {
            self.selectionRect = nil
            notifyViews()
            return
        }

        let normalized = selectionRect.gscIntegralStandardized
        guard normalized.gscIsFinite else {
            self.selectionRect = nil
            actionControlsDisplayID = nil
            actionControlsGlobalPoint = nil
            notifyViews()
            return
        }

        self.selectionRect = normalized
        let controlsDisplay = displayPreviewForControls(near: point, selectionRect: normalized)
        actionControlsDisplayID = controlsDisplay?.snapshot.displayID
        actionControlsGlobalPoint = clampedActionPoint(point, in: controlsDisplay?.snapshot.frame)
        notifyViews()
    }

    func confirmScrollingCapture() {
        guard let selectionRect, selectionRect.width > 8, selectionRect.height > 8 else {
            NSSound.beep()
            return
        }

        onComplete(selectionRect.gscIntegralStandardized)
    }

    func cancel() {
        onComplete(nil)
    }

    private func notifyViews() {
        views.removeAll { $0.view == nil }
        for weakView in views {
            weakView.view?.needsDisplay = true
            weakView.view?.layoutActionControls()
        }
    }

    private func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
        snapshot.displayPreviews.first(where: { $0.snapshot.frame.contains(point) })?.snapshot.displayID
    }

    private func displayPreviewForControls(near point: CGPoint, selectionRect: CGRect) -> DisplayPreview? {
        if let display = snapshot.displayPreviews.first(where: { $0.snapshot.frame.contains(point) }) {
            return display
        }

        return snapshot.displayPreviews
            .filter { $0.snapshot.frame.intersects(selectionRect) }
            .max {
                $0.snapshot.frame.intersection(selectionRect).area < $1.snapshot.frame.intersection(selectionRect).area
            }
    }

    private func clampedActionPoint(_ point: CGPoint, in displayFrame: CGRect?) -> CGPoint? {
        guard point.gscIsFinite,
              let displayFrame,
              displayFrame.gscIsFinite else {
            return nil
        }

        let clampedPoint = CGPoint(
            x: min(max(point.x, displayFrame.minX + 24), displayFrame.maxX - 220),
            y: min(max(point.y, displayFrame.minY + 64), displayFrame.maxY - 24)
        )

        return clampedPoint.gscIsFinite ? clampedPoint : nil
    }
}

private final class ScrollingSelectionView: NSView {
    private let displayPreview: DisplayPreview
    private let displayTransform: CaptureDisplayTransform
    private let displayImage: NSImage
    private let coordinator: ScrollingSelectionCoordinator
    private var actionPanel: NSView?
    private var captureButton: NSButton?
    private var cancelButton: NSButton?

    init(displayPreview: DisplayPreview, coordinator: ScrollingSelectionCoordinator) {
        self.displayPreview = displayPreview
        self.displayTransform = displayPreview.snapshot.captureDisplayTransform
        self.displayImage = NSImage(cgImage: displayPreview.image, size: displayPreview.snapshot.overlayFrame.size)
        self.coordinator = coordinator
        super.init(frame: CGRect(origin: .zero, size: displayPreview.snapshot.overlayFrame.size))
        wantsLayer = true
        coordinator.register(self)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        displayImage.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.40).setFill()
        bounds.fill()

        if let selectionRect = coordinator.selectionRect {
            drawSelection(selectionRect)
        } else {
            drawInstructions("Drag over the scrollable viewport. Esc cancels.")
        }
    }

    override func mouseDown(with event: NSEvent) {
        coordinator.mouseDown(at: globalPoint(for: event), in: window)
    }

    override func mouseDragged(with event: NSEvent) {
        coordinator.mouseDragged(to: globalPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        coordinator.mouseUp(at: globalPoint(for: event))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            coordinator.confirmScrollingCapture()
        case 53:
            coordinator.cancel()
        default:
            super.keyDown(with: event)
        }
    }

    func layoutActionControls() {
        ensureActionControls()

        guard coordinator.shouldShowActionControls(on: displayPreview.snapshot.displayID),
              let localPoint = coordinator.actionControlsPoint(for: displayPreview.snapshot),
              let actionPanel,
              let captureButton,
              let cancelButton else {
            captureButton?.isHidden = true
            cancelButton?.isHidden = true
            actionPanel?.isHidden = true
            return
        }

        let spacing: CGFloat = 8
        let panelPadding: CGFloat = 10
        let buttonHeight: CGFloat = 32
        let captureSize = captureButton.sizeThatFits(CGSize(width: 180, height: buttonHeight))
        let cancelSize = cancelButton.sizeThatFits(CGSize(width: 120, height: buttonHeight))
        let controlsWidth = captureSize.width + cancelSize.width + spacing
        let panelSize = CGSize(width: controlsWidth + panelPadding * 2, height: buttonHeight + panelPadding * 2)
        let panelX = min(max(localPoint.x - panelSize.width / 2, 12), bounds.maxX - panelSize.width - 12)
        let panelY = min(max(localPoint.y + 14, 12), bounds.maxY - panelSize.height - 12)
        let buttonY = panelY + panelPadding
        let buttonX = panelX + panelPadding

        actionPanel.frame = CGRect(origin: CGPoint(x: panelX, y: panelY), size: panelSize)
        captureButton.frame = CGRect(x: buttonX, y: buttonY, width: captureSize.width, height: buttonHeight)
        cancelButton.frame = CGRect(x: captureButton.frame.maxX + spacing, y: buttonY, width: cancelSize.width, height: buttonHeight)
        actionPanel.isHidden = false
        captureButton.isHidden = false
        cancelButton.isHidden = false
    }

    private func ensureActionControls() {
        guard actionPanel == nil, captureButton == nil, cancelButton == nil else {
            return
        }

        let actionPanel = NSView()
        actionPanel.wantsLayer = true
        actionPanel.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        actionPanel.layer?.cornerRadius = 14
        actionPanel.layer?.borderWidth = 1
        actionPanel.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        actionPanel.layer?.shadowColor = NSColor.black.cgColor
        actionPanel.layer?.shadowOpacity = 0.28
        actionPanel.layer?.shadowRadius = 18
        actionPanel.layer?.shadowOffset = CGSize(width: 0, height: -4)
        actionPanel.isHidden = true
        addSubview(actionPanel)

        let captureButton = NSButton(title: "Capture Scroll", target: nil, action: nil)
        captureButton.target = self
        captureButton.action = #selector(confirmScrollingCapture)
        captureButton.bezelStyle = .rounded
        captureButton.controlSize = .regular
        captureButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        captureButton.isHidden = true
        addSubview(captureButton)

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.target = self
        cancelButton.action = #selector(cancelScrollingCapture)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular
        cancelButton.isHidden = true
        addSubview(cancelButton)

        self.actionPanel = actionPanel
        self.captureButton = captureButton
        self.cancelButton = cancelButton
    }

    @objc private func confirmScrollingCapture() {
        coordinator.confirmScrollingCapture()
    }

    @objc private func cancelScrollingCapture() {
        coordinator.cancel()
    }

    private func drawSelection(_ selectionRect: CGRect) {
        let localSelection = displayTransform.overlayLocalRect(fromCaptureGlobalRect: selectionRect)
        guard localSelection.gscIsFinite else {
            drawInstructions("Drag over the scrollable viewport. Esc cancels.")
            return
        }

        NSGraphicsContext.current?.cgContext.saveGState()
        NSBezierPath(roundedRect: localSelection, xRadius: 12, yRadius: 12).addClip()
        displayImage.draw(in: bounds)
        NSGraphicsContext.current?.cgContext.restoreGState()

        let fill = NSBezierPath(roundedRect: localSelection, xRadius: 12, yRadius: 12)
        NSColor.systemBlue.withAlphaComponent(0.10).setFill()
        fill.fill()

        let border = NSBezierPath(roundedRect: localSelection, xRadius: 12, yRadius: 12)
        NSColor.systemBlue.setStroke()
        border.lineWidth = 3
        border.stroke()

        drawInstructions(actionControlsVisible ? "Click Capture Scroll or press Return • Esc cancels" : "Release to place Capture Scroll controls • Esc cancels")
    }

    private func drawInstructions(_ text: String) {
        NSString(string: text).draw(
            in: CGRect(x: 24, y: 24, width: 560, height: 24),
            withAttributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold)
            ]
        )
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard localPoint.gscIsFinite else {
            return .zero
        }

        let capturePoint = displayTransform.captureGlobalPoint(fromOverlayLocalPoint: localPoint)
        return capturePoint.gscIsFinite ? capturePoint : .zero
    }

    private var actionControlsVisible: Bool {
        guard let captureButton else {
            return false
        }

        return !captureButton.isHidden
    }
}

private extension CGRect {
    var area: CGFloat {
        max(width, 0) * max(height, 0)
    }
}
