import AppKit
import SwiftUI

enum ClipboardManagerWindowID {
    static let identifier = "clipboard-history"
    static let didShowNotification = Notification.Name("ClipboardHistoryDidShow")

    static func isClipboardManagerWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue == identifier
    }
}

@MainActor
final class ClipboardManagerWindowController: NSWindowController {
    private weak var clipboard: ClipboardWorkflowModel?
    private let workspace: any WorkspaceServicing
    private var previousApplication: ClipboardReturnTarget?
    private var hasPositionedWindow = false

    init(clipboard: ClipboardWorkflowModel, workspace: any WorkspaceServicing) {
        self.clipboard = clipboard
        self.workspace = workspace

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(ClipboardManagerWindowID.identifier)
        panel.title = "Clipboard History"
        panel.contentMinSize = NSSize(width: 400, height: 460)
        panel.titlebarAppearsTransparent = false
        panel.titleVisibility = .hidden
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = true
        super.init(window: panel)
        panel.contentView = NSHostingView(rootView: ClipboardManagerView(
            clipboard: clipboard,
            returnToPreviousApplication: { [weak self] in self?.returnToPreviousApplication() ?? false }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("ClipboardManagerWindowController is programmatic-only; use init(model:) instead of init(coder:).")
    }

    func show(on displayID: CGDirectDisplayID? = nil) {
        guard let window else {
            return
        }

        if !window.isVisible {
            previousApplication = ClipboardReturnTarget(
                application: workspace.frontmostApplication,
                ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier
            )
        }

        if !hasPositionedWindow {
            if let screen = NSScreen.screens.first(where: {
                $0.gscDisplayID == displayID
            }) {
                let visibleFrame = screen.visibleFrame
                window.setFrameOrigin(
                    CGPoint(
                        x: visibleFrame.midX - window.frame.width / 2,
                        y: visibleFrame.midY - window.frame.height / 2
                    )
                )
            } else {
                window.center()
            }
            hasPositionedWindow = true
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: ClipboardManagerWindowID.didShowNotification, object: window)
    }

    @discardableResult
    func returnToPreviousApplication() -> Bool {
        guard let window, window.isKeyWindow,
              let processIdentifier = previousApplication?.availableProcessIdentifier(in: workspace.runningApplications),
              workspace.activateApplication(processIdentifier: processIdentifier) else { return false }
        // Keep the utility mounted: returning is not closing its draft session.
        window.orderOut(nil)
        return true
    }
}
