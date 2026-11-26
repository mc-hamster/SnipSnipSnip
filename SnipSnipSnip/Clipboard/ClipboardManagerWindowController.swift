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

        if let displayID,
           let screen = NSScreen.screens.first(where: { $0.gscDisplayID == displayID }),
           let frame = Self.frameForPresentation(
               window.frame,
               on: screen.frame,
               visibleFrame: screen.visibleFrame,
               hasPositionedWindow: hasPositionedWindow
           ) {
            window.setFrame(frame, display: true)
        } else if !hasPositionedWindow {
            window.center()
        }
        hasPositionedWindow = true

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: ClipboardManagerWindowID.didShowNotification, object: window)
    }

    static func frameForPresentation(
        _ currentFrame: CGRect,
        on screenFrame: CGRect,
        visibleFrame: CGRect,
        hasPositionedWindow: Bool
    ) -> CGRect? {
        let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        guard !hasPositionedWindow || !screenFrame.contains(center) else { return nil }
        return CGRect(
            x: visibleFrame.midX - currentFrame.width / 2,
            y: visibleFrame.midY - currentFrame.height / 2,
            width: currentFrame.width,
            height: currentFrame.height
        ).gscContained(in: visibleFrame)
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
