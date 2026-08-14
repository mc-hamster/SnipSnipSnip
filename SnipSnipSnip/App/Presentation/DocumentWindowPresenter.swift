import AppKit
import Foundation
import SwiftUI

nonisolated enum MainWindowLayout {
    static let defaultContentSize = CGSize(width: 1280, height: 700)
    static let minimumContentSize = CGSize(width: 1240, height: 600)

    static func minimumContentSize(for kind: DocumentWindowContentKind) -> CGSize {
        switch kind {
        case .screenshot:
            minimumContentSize
        case .video:
            CGSize(width: minimumContentSize.width, height: 780)
        case .guide:
            CGSize(width: 1280, height: 800)
        }
    }
}

nonisolated enum DocumentWindowPlacementPolicy {
    static func resizedFrame(
        currentFrame: CGRect,
        targetSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let resolvedSize = CGSize(
            width: min(max(targetSize.width, 1), max(visibleFrame.width, 1)),
            height: min(max(targetSize.height, 1), max(visibleFrame.height, 1))
        )
        let proposedOrigin = CGPoint(
            x: currentFrame.minX,
            y: currentFrame.maxY - resolvedSize.height
        )
        let maximumOrigin = CGPoint(
            x: visibleFrame.maxX - resolvedSize.width,
            y: visibleFrame.maxY - resolvedSize.height
        )

        return CGRect(
            x: min(max(proposedOrigin.x, visibleFrame.minX), max(visibleFrame.minX, maximumOrigin.x)),
            y: min(max(proposedOrigin.y, visibleFrame.minY), max(visibleFrame.minY, maximumOrigin.y)),
            width: resolvedSize.width,
            height: resolvedSize.height
        ).integral
    }
}

@MainActor
struct LiveDocumentWindowPresenter: DocumentWindowPresenting {
    let screens: any ScreenTopologyProviding

    func syncMainWindowDocumentState(documentURL: URL?, hasUnsavedChanges: Bool, title: String) {
        guard let window = mainWindow else {
            return
        }

        if window.representedURL != documentURL {
            window.representedURL = documentURL
        }

        if window.isDocumentEdited != hasUnsavedChanges {
            window.isDocumentEdited = hasUnsavedChanges
        }

        if window.title != title {
            window.title = title
        }
    }

    func resizeMainWindowForContent(pixelSize: CGSize, kind: DocumentWindowContentKind, animated: Bool) -> Bool {
        guard let window = mainWindow,
              let screenContext = screenContext(for: window) else {
            return false
        }

        let imagePointSize = CGSize(
            width: pixelSize.width / screenContext.scale,
            height: pixelSize.height / screenContext.scale
        )

        // Chrome overhead: inspector sidebar + scrollbar gutter (width), header + toolbar + dividers (height)
        let chromeWidth: CGFloat = 300 + 30
        let chromeHeight: CGFloat = 150

        let minSize = MainWindowLayout.minimumContentSize(for: kind)
        window.contentMinSize = minSize
        let maxSize = screenContext.visibleFrame.size

        let targetWidth = min(max(imagePointSize.width + chromeWidth, minSize.width), maxSize.width)
        let targetHeight = min(max(imagePointSize.height + chromeHeight, minSize.height), maxSize.height)
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        let targetFrame = DocumentWindowPlacementPolicy.resizedFrame(
            currentFrame: window.frame,
            targetSize: targetSize,
            visibleFrame: screenContext.visibleFrame
        )

        guard targetFrame.width > 0, targetFrame.height > 0 else {
            return false
        }

        if window.frame != targetFrame {
            window.setFrame(targetFrame, display: true, animate: animated)
        }

        return true
    }

    func restoreMainWindowForCaptureHome(animated: Bool) {
        guard let window = mainWindow,
              let screenContext = screenContext(for: window) else {
            return
        }

        let minimumContentSize = MainWindowLayout.minimumContentSize
        window.contentMinSize = minimumContentSize

        let minimumFrameSize = window.frameRect(
            forContentRect: CGRect(origin: .zero, size: minimumContentSize)
        ).size
        let targetSize = CGSize(
            width: max(window.frame.width, minimumFrameSize.width),
            height: max(window.frame.height, minimumFrameSize.height)
        )
        let targetFrame = DocumentWindowPlacementPolicy.resizedFrame(
            currentFrame: window.frame,
            targetSize: targetSize,
            visibleFrame: screenContext.visibleFrame
        )

        guard targetFrame != window.frame else {
            return
        }
        window.setFrame(targetFrame, display: true, animate: animated)
    }

    private var mainWindow: NSWindow? {
        guard let application = NSApp else {
            return nil
        }
        return application.windows.first {
            $0.identifier?.rawValue == AppSceneID.mainWindow
        }
    }

    private func screenContext(for window: NSWindow) -> (visibleFrame: CGRect, scale: CGFloat)? {
        if let windowScreen = window.screen {
            return (windowScreen.visibleFrame, windowScreen.backingScaleFactor)
        }

        if let fallbackScreen = screens.mainScreen ?? screens.screens.first {
            return (fallbackScreen.visibleFrame, fallbackScreen.backingScaleFactor)
        }

        return nil
    }

}

struct MainWindowMinimumSizeBridge: NSViewRepresentable {
    let preferredContentSize: CGSize

    func makeNSView(context: Context) -> MainWindowMinimumSizeView {
        MainWindowMinimumSizeView(preferredContentSize: preferredContentSize)
    }

    func updateNSView(_ nsView: MainWindowMinimumSizeView, context: Context) {
        nsView.preferredContentSize = preferredContentSize
        nsView.refreshMinimumSize()
    }
}

final class MainWindowMinimumSizeView: NSView {
    var preferredContentSize: CGSize
    private var windowObservers: [NSObjectProtocol] = []
    private var isApplyingMinimumSize = false
    private var isMinimumSizeRefreshScheduled = false

    init(preferredContentSize: CGSize) {
        self.preferredContentSize = preferredContentSize
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        removeWindowObservers()
        super.viewDidMoveToWindow()
        refreshMinimumSize()

        guard let window else {
            return
        }
        let center = NotificationCenter.default
        windowObservers = [
            NSWindow.didChangeScreenNotification,
            NSWindow.didUpdateNotification,
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
        ].map { name in
            center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshMinimumSize()
                }
            }
        }
    }

    func refreshMinimumSize() {
        applyMinimumSize()

        guard !isMinimumSizeRefreshScheduled else {
            return
        }
        isMinimumSizeRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.isMinimumSizeRefreshScheduled = false
            self.applyMinimumSize()
        }
    }

    private func applyMinimumSize() {
        guard !isApplyingMinimumSize else {
            return
        }
        guard let window,
              let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return
        }
        isApplyingMinimumSize = true
        defer { isApplyingMinimumSize = false }

        let minimumContentSize = preferredContentSize
        if window.contentMinSize != minimumContentSize {
            window.contentMinSize = minimumContentSize
        }

        let minimumFrameSize = window.frameRect(
            forContentRect: CGRect(origin: .zero, size: minimumContentSize)
        ).size
        let targetSize = CGSize(
            width: max(window.frame.width, minimumFrameSize.width),
            height: max(window.frame.height, minimumFrameSize.height)
        )
        guard targetSize != window.frame.size else {
            return
        }
        let fittedFrame = CGRect(
            origin: CGPoint(
                x: targetSize.width <= visibleFrame.width
                    ? min(max(window.frame.minX, visibleFrame.minX), visibleFrame.maxX - targetSize.width)
                    : visibleFrame.minX,
                y: targetSize.height <= visibleFrame.height
                    ? min(max(window.frame.maxY - targetSize.height, visibleFrame.minY), visibleFrame.maxY - targetSize.height)
                    : visibleFrame.maxY - targetSize.height
            ),
            size: targetSize
        )
        window.setFrame(fittedFrame, display: true)
    }

    private func removeWindowObservers() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
    }

    deinit {
        MainActor.assumeIsolated {
            removeWindowObservers()
        }
    }
}
