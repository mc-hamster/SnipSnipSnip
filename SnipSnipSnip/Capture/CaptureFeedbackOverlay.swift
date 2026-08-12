import AppKit

@MainActor
final class CaptureFeedbackOverlay {
    private static var postCaptureOverlay: CaptureFeedbackOverlay?

    private let window: NSWindow
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField

    init(title: String, detail: String? = nil) {
        let contentView = NSView(frame: CGRect(x: 0, y: 0, width: 260, height: 112))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        contentView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        contentView.layer?.borderWidth = 1
        contentView.layer?.cornerRadius = 20

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        let detailLabel = NSTextField(labelWithString: detail ?? "")
        detailLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.isHidden = detail == nil

        let stackView = NSStackView(views: [titleLabel, detailLabel])
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 224),
            titleLabel.heightAnchor.constraint(equalToConstant: 34),
            detailLabel.widthAnchor.constraint(equalToConstant: 224),
            detailLabel.heightAnchor.constraint(equalToConstant: 20)
        ])

        self.titleLabel = titleLabel
        self.detailLabel = detailLabel
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
        window.contentView = contentView
        positionNearTopCenter()
    }

    func show() {
        window.orderFrontRegardless()
    }

    func update(title: String, detail: String? = nil) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
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
