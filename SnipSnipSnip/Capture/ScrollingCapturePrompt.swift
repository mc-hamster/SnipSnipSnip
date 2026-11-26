import AppKit

@MainActor
enum ScrollingCaptureModeSelection {
    static func present(on displayID: CGDirectDisplayID?) async -> ScrollingCaptureMode? {
        let screen = displayID.flatMap { id in NSScreen.screens.first { $0.gscDisplayID == id } }
            ?? (NSApp.isActive ? NSApp.keyWindow?.screen : nil)
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let choice = await ScrollingCapturePrompt().present(
            title: "Capture Scrolling Content",
            message: "Auto Scroll moves the selected app for you and requires Accessibility. With Manual Scroll, scroll normally and choose Stop when you’re finished. Manual Scroll needs only Screen Recording.",
            primaryAction: "Auto Scroll",
            secondaryAction: "Manual Scroll",
            on: screen
        )
        switch choice {
        case .primary: return .automatic
        case .secondary: return .manual
        case .cancel: return nil
        }
    }
}

@MainActor
enum ScrollingCaptureTargetConfirmation {
    private static let showsConfirmationKey = "ScrollingCaptureShowsTargetConfirmation"

    enum Choice {
        case start
        case chooseAnotherArea
        case cancel
    }

    static func present(target: ScrollingCaptureTarget) async -> Choice {
        let defaults = UserDefaults.standard
        if target.mode == .automatic, defaults.object(forKey: showsConfirmationKey) != nil,
           !defaults.bool(forKey: showsConfirmationKey) {
            return .start
        }

        let guidance = target.mode == .manual
            ? "Scroll normally in the selected area. Click Stop when you’re finished."
            : "SnipSnipSnip scrolls the selected app automatically. Stable pages, lists, and documents work best; animated or changing content may need a seam review."
        let viewport = target.viewportRect
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        let screen = NSScreen.screens.first { screen in
            guard let displayID = screen.gscDisplayID else { return false }
            return CGDisplayBounds(displayID).contains(center)
        }

        let showAgain = target.mode == .automatic
            ? NSButton(checkboxWithTitle: "Show this again", target: nil, action: nil)
            : nil
        showAgain?.state = .on

        let choice = await ScrollingCapturePrompt().present(
            title: "Ready to Capture \(target.sourceName)",
            message: "Selected area: \(Int(viewport.width)) × \(Int(viewport.height)) points. \(guidance)",
            primaryAction: "Start Capture",
            secondaryAction: "Choose Another Area",
            accessory: showAgain,
            on: screen
        )
        if let showAgain { defaults.set(showAgain.state == .on, forKey: showsConfirmationKey) }
        switch choice {
        case .primary: return .start
        case .secondary: return .chooseAnotherArea
        case .cancel: return .cancel
        }
    }
}

@MainActor
private final class ScrollingCapturePrompt: NSObject, NSWindowDelegate {
    enum Choice: Int {
        case primary
        case secondary
        case cancel
    }

    private let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.titled, .closable, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    private var continuation: CheckedContinuation<Choice, Never>?

    func present(
        title: String,
        message: String,
        primaryAction: String,
        secondaryAction: String,
        accessory: NSView? = nil,
        on screen: NSScreen?
    ) async -> Choice {
        panel.delegate = self
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let width: CGFloat = 400
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.maximumNumberOfLines = 2
        heading.preferredMaxLayoutWidth = width
        let label = NSTextField(wrappingLabelWithString: message)
        label.preferredMaxLayoutWidth = width
        let details = NSStackView(views: [heading, label] + (accessory.map { [$0] } ?? []))
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 10
        NSLayoutConstraint.activate([
            heading.widthAnchor.constraint(equalToConstant: width),
            label.widthAnchor.constraint(equalToConstant: width)
        ])

        let buttons = [primaryAction, secondaryAction, "Cancel"].enumerated().map { index, title in
            let button = NSButton(title: title, target: self, action: #selector(choose(_:)))
            button.tag = index
            button.keyEquivalentModifierMask = []
            return button
        }
        buttons.first?.keyEquivalent = "\r"
        buttons.last?.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: Array(buttons.reversed()))
        let stack = NSStackView(views: [details, actions])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])

        let contentSize = content.fittingSize
        panel.titleVisibility = .hidden
        panel.contentView = content
        panel.setContentSize(contentSize)
        panel.defaultButtonCell = buttons.first?.cell as? NSButtonCell
        panel.autorecalculatesKeyViewLoop = true
        panel.initialFirstResponder = buttons.first
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }

        let choice: Choice = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancel)
                    return
                }
                self.continuation = continuation
                // A nonactivating panel can take keyboard focus without switching to the app's Space.
                panel.orderFrontRegardless()
                panel.makeKey()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(with: .cancel) }
        }
        panel.orderOut(nil)
        return choice
    }

    @objc private func choose(_ sender: NSButton) {
        finish(with: Choice(rawValue: sender.tag) ?? .cancel)
    }

    func windowWillClose(_ notification: Notification) {
        finish(with: .cancel)
    }

    private func finish(with choice: Choice) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: choice)
    }
}
