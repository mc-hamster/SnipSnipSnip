import AppKit
import Foundation

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

        let minSize: CGSize
        switch kind {
        case .screenshot:
            minSize = CGSize(width: 900, height: 600)
        case .video:
            minSize = CGSize(width: 1200, height: 780)
        }
        let maxSize = screenContext.visibleFrame.size

        let targetWidth = min(max(imagePointSize.width + chromeWidth, minSize.width), maxSize.width)
        let targetHeight = min(max(imagePointSize.height + chromeHeight, minSize.height), maxSize.height)
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        let targetOrigin = CGPoint(
            x: screenContext.visibleFrame.midX - targetSize.width / 2,
            y: screenContext.visibleFrame.midY - targetSize.height / 2
        )
        let targetFrame = CGRect(origin: targetOrigin, size: targetSize).integral

        guard targetFrame.width > 0, targetFrame.height > 0 else {
            return false
        }

        if window.frame != targetFrame {
            window.setFrame(targetFrame, display: true, animate: animated)
        }

        return true
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == AppSceneID.mainWindow }
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
