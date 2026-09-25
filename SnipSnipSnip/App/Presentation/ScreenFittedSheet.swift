import AppKit
import SwiftUI

nonisolated enum SheetLayout {
    static func contentSize(preferred: CGSize, visibleFrame: CGRect, parentContentFrame: CGRect?) -> CGSize {
        // Leave room for the attachment and screen edges. The form scrolls while
        // the sheet's title and confirmation/cancellation controls stay visible.
        let availableHeight = min(
            visibleFrame.height - 48,
            (parentContentFrame?.maxY ?? visibleFrame.maxY) - visibleFrame.minY - 32
        )
        return MainWindowLayout.fittedContentSize(
            preferred: preferred,
            available: CGSize(width: visibleFrame.width - 32, height: availableHeight)
        )
    }
}

extension View {
    func screenFittedSheet(preferredSize: CGSize) -> some View {
        modifier(ScreenFittedSheetModifier(preferredSize: preferredSize))
    }
}

private struct ScreenFittedSheetModifier: ViewModifier {
    let preferredSize: CGSize
    @State private var fittedSize: CGSize?

    func body(content: Content) -> some View {
        let size = fittedSize ?? initialSize
        content
            .frame(width: size.width, height: size.height)
            .background(SheetSizeReader(preferredSize: preferredSize) { fittedSize = $0 })
    }

    private var initialSize: CGSize {
        let parent = NSApp?.keyWindow?.sheetParent ?? NSApp?.keyWindow
        guard let screen = parent?.screen ?? NSScreen.main else { return preferredSize }
        return SheetLayout.contentSize(
            preferred: preferredSize, visibleFrame: screen.visibleFrame,
            parentContentFrame: parent.map { $0.convertToScreen($0.contentLayoutRect) }
        )
    }
}

private struct SheetSizeReader: NSViewRepresentable {
    let preferredSize: CGSize
    let onChange: (CGSize) -> Void

    func makeNSView(context: Context) -> SheetSizeView {
        SheetSizeView(preferredSize: preferredSize, onChange: onChange)
    }

    func updateNSView(_ nsView: SheetSizeView, context: Context) {
        nsView.preferredSize = preferredSize
        nsView.onChange = onChange
        nsView.refresh()
    }
}

private final class SheetSizeView: NSView {
    var preferredSize: CGSize
    var onChange: (CGSize) -> Void
    private var observers: [NSObjectProtocol] = []
    private var lastSize: CGSize?

    init(preferredSize: CGSize, onChange: @escaping (CGSize) -> Void) {
        self.preferredSize = preferredSize
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            for observedWindow in [window, window.sheetParent].compactMap({ $0 }) {
                for name in [NSWindow.didChangeScreenNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: observedWindow, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.refresh() }
                    })
                }
            }
        }
        refresh()
    }

    func refresh() {
        guard let window, let screen = window.screen ?? window.sheetParent?.screen else { return }
        let size = SheetLayout.contentSize(
            preferred: preferredSize, visibleFrame: screen.visibleFrame,
            parentContentFrame: window.sheetParent.map { $0.convertToScreen($0.contentLayoutRect) }
        )
        guard size != lastSize else { return }
        lastSize = size
        DispatchQueue.main.async { [weak self] in self?.onChange(size) }
    }

    deinit {
        MainActor.assumeIsolated { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
