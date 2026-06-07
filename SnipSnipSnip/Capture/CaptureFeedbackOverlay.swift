import AppKit

@MainActor
final class CaptureFeedbackOverlay {
    private static var postCaptureOverlay: CaptureFeedbackOverlay?

    private let window: NSWindow
    private let view: CaptureFeedbackOverlayView

    init(title: String, detail: String? = nil) {
        view = CaptureFeedbackOverlayView(title: title, detail: detail)
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 112),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = true
        window.hasShadow = true
        window.contentView = view
        positionNearTopCenter()
    }

    func show() {
        window.orderFrontRegardless()
    }

    func update(title: String, detail: String? = nil) {
        view.title = title
        view.detail = detail
    }

    func close() {
        window.orderOut(nil)
    }

    static func showCapturedFeedback() {
        postCaptureOverlay?.close()

        let overlay = CaptureFeedbackOverlay(title: "Captured", detail: "Opening editor")
        postCaptureOverlay = overlay
        overlay.show()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard postCaptureOverlay === overlay else {
                return
            }

            overlay.close()
            postCaptureOverlay = nil
        }
    }

    private func positionNearTopCenter() {
        guard let screen = NSScreen.main else {
            window.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 36
        ))
    }
}

private final class CaptureFeedbackOverlayView: NSView {
    var title: String {
        didSet { needsDisplay = true }
    }
    var detail: String? {
        didSet { needsDisplay = true }
    }

    init(title: String, detail: String?) {
        self.title = title
        self.detail = detail
        super.init(frame: CGRect(x: 0, y: 0, width: 260, height: 112))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 20, yRadius: 20)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        panel.fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        let titleRect = CGRect(x: 18, y: detail == nil ? 34 : 26, width: bounds.width - 36, height: 34)
        NSString(string: title).draw(
            in: titleRect,
            withAttributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold),
                .paragraphStyle: centeredParagraphStyle
            ]
        )

        if let detail {
            NSString(string: detail).draw(
                in: CGRect(x: 18, y: 65, width: bounds.width - 36, height: 20),
                withAttributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .paragraphStyle: centeredParagraphStyle
                ]
            )
        }
    }

    private var centeredParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }
}
