import AppKit
import CoreGraphics

@MainActor
final class DisplaySelectionSession {
    private let displays: [DisplaySnapshot]
    private var continuation: CheckedContinuation<CGDirectDisplayID?, Never>?
    private var overlayWindows: [DisplaySelectionWindow] = []

    init(displays: [DisplaySnapshot]) {
        self.displays = displays
    }

    func begin() async -> CGDirectDisplayID? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentOverlay()
        }
    }

    private func presentOverlay() {
        NSApp.activate(ignoringOtherApps: true)

        overlayWindows = displays.map { display in
            let overlay = DisplaySelectionWindow(display: display) { [weak self] displayID in
                self?.finish(with: displayID)
            }
            overlay.orderFrontRegardless()
            return overlay
        }

        overlayWindows.first?.makeKeyAndOrderFront(nil)
    }

    private func finish(with displayID: CGDirectDisplayID?) {
        let continuation = continuation
        self.continuation = nil
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = []
        continuation?.resume(returning: displayID)
    }
}

private final class DisplaySelectionWindow: NSWindow {
    init(
        display: DisplaySnapshot,
        onComplete: @escaping (CGDirectDisplayID?) -> Void
    ) {
        super.init(
            contentRect: display.overlayFrame,
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
        contentView = DisplaySelectionView(display: display, onComplete: onComplete)
        makeFirstResponder(contentView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class DisplaySelectionView: NSView {
    private let display: DisplaySnapshot
    private let onComplete: (CGDirectDisplayID?) -> Void
    private var isHovering = false
    private var trackingAreaRef: NSTrackingArea?

    init(
        display: DisplaySnapshot,
        onComplete: @escaping (CGDirectDisplayID?) -> Void
    ) {
        self.display = display
        self.onComplete = onComplete
        super.init(frame: CGRect(origin: .zero, size: display.overlayFrame.size))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Capture \(display.name)")
        setAccessibilityHelp("Select this display and start the Guide.")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor.black.withAlphaComponent(reduceTransparency ? 0.68 : 0.38).setFill()
        bounds.fill()

        if isHovering {
            NSColor.controlAccentColor.withAlphaComponent(reduceTransparency ? 0.32 : 0.18).setFill()
            bounds.fill()

            let border = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 6, dy: 6),
                xRadius: 16,
                yRadius: 16
            )
            NSColor.controlAccentColor.setStroke()
            border.lineWidth = increaseContrast ? 6 : 4
            border.stroke()
        }

        drawInstructions()
        drawDisplayLabel()
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(true)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        onComplete(display.displayID)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onComplete(nil)
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onComplete(display.displayID)
        return true
    }

    private func updateHover(_ hovering: Bool) {
        guard isHovering != hovering else {
            return
        }
        isHovering = hovering
        needsDisplay = true
    }

    private func drawInstructions() {
        let instructions = NSString(
            string: "Click this display to start the Guide. Esc returns to setup."
        )
        instructions.draw(
            in: CGRect(x: 24, y: 24, width: min(bounds.width - 48, 520), height: 24),
            withAttributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold)
            ]
        )
    }

    private func drawDisplayLabel() {
        let label = NSString(string: display.name)
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold)
        ]
        let size = label.size(withAttributes: attributes)
        let labelRect = CGRect(
            x: max(24, bounds.midX - size.width / 2 - 18),
            y: max(70, bounds.midY - size.height / 2 - 12),
            width: size.width + 36,
            height: size.height + 24
        )

        let background = NSBezierPath(roundedRect: labelRect, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.82).setFill()
        background.fill()
        label.draw(
            at: CGPoint(x: labelRect.minX + 18, y: labelRect.minY + 12),
            withAttributes: attributes
        )
    }
}
