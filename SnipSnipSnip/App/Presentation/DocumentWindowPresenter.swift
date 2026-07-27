import AppKit
import Foundation

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

        let minSize: CGSize
        switch kind {
        case .screenshot:
            minSize = CGSize(width: 900, height: 600)
        case .video:
            minSize = CGSize(width: 1200, height: 780)
        case .guide:
            minSize = CGSize(width: 1280, height: 800)
        }
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
