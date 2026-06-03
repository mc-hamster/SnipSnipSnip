import AppKit

@MainActor
final class ScrollingCaptureProgressOverlay {
    private let window: NSWindow
    private let view: ScrollingCaptureProgressView
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private let onCancel: () -> Void
    private let onDone: () -> Void

    init(onCancel: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.onCancel = onCancel
        self.onDone = onDone
        view = ScrollingCaptureProgressView(onCancel: onCancel, onDone: onDone)
        window = ScrollingCaptureProgressWindow(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = true
        window.contentView = view
        window.center()
    }

    func show() {
        window.orderFrontRegardless()
        installKeyMonitors()
    }

    func show(avoiding rect: CGRect) {
        position(avoiding: rect)
        show()
    }

    func update(segmentCount: Int, capacityFraction: Double, warning: String?) {
        view.segmentCount = segmentCount
        view.capacityFraction = capacityFraction
        view.warning = warning
    }

    func close() {
        removeKeyMonitors()
        window.orderOut(nil)
    }

    private func installKeyMonitors() {
        guard localKeyMonitor == nil, globalKeyMonitor == nil else {
            return
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKeyEvent(event) else {
                return event
            }

            return nil
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleKeyEvent(event)
        }
    }

    private func removeKeyMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }

        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76:
            onDone()
            return true
        case 53:
            onCancel()
            return true
        default:
            return false
        }
    }

    private func position(avoiding rect: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else {
            window.center()
            return
        }

        let margin: CGFloat = 18
        let size = window.frame.size
        let candidates = [
            CGPoint(x: rect.maxX + margin, y: rect.maxY - size.height),
            CGPoint(x: rect.minX - size.width - margin, y: rect.maxY - size.height),
            CGPoint(x: rect.maxX - size.width, y: rect.minY - size.height - margin),
            CGPoint(x: rect.minX, y: rect.maxY + margin)
        ]

        let visibleFrame = screen.visibleFrame
        let selectedCandidate = candidates.first { candidate in
            visibleFrame.contains(CGRect(origin: candidate, size: size))
        } ?? CGPoint(
            x: visibleFrame.maxX - size.width - margin,
            y: visibleFrame.maxY - size.height - margin
        )

        window.setFrameOrigin(CGPoint(
            x: min(max(selectedCandidate.x, visibleFrame.minX + margin), visibleFrame.maxX - size.width - margin),
            y: min(max(selectedCandidate.y, visibleFrame.minY + margin), visibleFrame.maxY - size.height - margin)
        ))
    }
}

private final class ScrollingCaptureProgressWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ScrollingCaptureProgressView: NSView {
    var segmentCount = 1 {
        didSet { needsDisplay = true }
    }
    var capacityFraction: Double = 0 {
        didSet { needsDisplay = true }
    }
    var warning: String? {
        didSet { needsDisplay = true }
    }

    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let onCancel: () -> Void
    private let onDone: () -> Void

    init(onCancel: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.onCancel = onCancel
        self.onDone = onDone
        super.init(frame: CGRect(x: 0, y: 0, width: 380, height: 160))
        wantsLayer = true
        configureButtons()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        doneButton.frame = CGRect(x: bounds.maxX - 190, y: bounds.maxY - 48, width: 82, height: 30)
        cancelButton.frame = CGRect(x: bounds.maxX - 98, y: bounds.maxY - 48, width: 82, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        panel.fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        // Title
        NSString(string: "Capturing scrolling area…").draw(
            in: CGRect(x: 18, y: 18, width: bounds.width - 36, height: 22),
            withAttributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold)
            ]
        )

        // Segment count
        NSString(string: "\(segmentCount) segment\(segmentCount == 1 ? "" : "s") captured").draw(
            in: CGRect(x: 18, y: 44, width: bounds.width - 36, height: 20),
            withAttributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            ]
        )

        // Capacity fill bar
        drawCapacityBar(at: CGRect(x: 18, y: 70, width: bounds.width - 36, height: 7))

        // Keyboard hint
        NSString(string: "Return: Done  ·  Esc: Cancel").draw(
            in: CGRect(x: 18, y: 85, width: bounds.width - 36, height: 18),
            withAttributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ]
        )

        if let warning {
            NSString(string: warning).draw(
                in: CGRect(x: 18, y: 107, width: bounds.width - 36, height: 20),
                withAttributes: [
                    .foregroundColor: NSColor.systemOrange,
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium)
                ]
            )
        }
    }

    private func drawCapacityBar(at rect: CGRect) {
        let fraction = max(0.02, capacityFraction) // always show a sliver so bar is visible from frame 1
        let radius = rect.height / 2

        // Track
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.separatorColor.withAlphaComponent(0.28).setFill()
        track.fill()

        // Fill — color shifts green → amber → red as capacity is consumed
        let fillWidth = max(rect.height, rect.width * CGFloat(fraction)) // at least as wide as a circle
        let fillRect = CGRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        barColor(for: capacityFraction).setFill()
        fill.fill()

        // Capacity label to the right
        let label = capacityFraction < 0.01
            ? "< 1%"
            : String(format: "%.0f%%", capacityFraction * 100)

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        ]
        let labelSize = (label as NSString).size(withAttributes: labelAttrs)
        let labelX = rect.maxX - labelSize.width
        let labelY = rect.minY - (labelSize.height - rect.height) / 2 - 1
        (label as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: labelAttrs)
    }

    private func barColor(for fraction: Double) -> NSColor {
        if fraction >= 0.90 {
            return .systemRed
        } else if fraction >= 0.65 {
            return .systemOrange
        } else {
            return .systemGreen
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onDone()
        case 53:
            onCancel()
        default:
            super.keyDown(with: event)
        }
    }

    private func configureButtons() {
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .regular
        doneButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        doneButton.keyEquivalent = "\r"
        addSubview(doneButton)

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular
        cancelButton.keyEquivalent = "\u{1b}"
        addSubview(cancelButton)
    }

    @objc private func cancel() {
        onCancel()
    }

    @objc private func done() {
        onDone()
    }
}
