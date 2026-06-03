import AppKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct PromisedFilePayload: @unchecked Sendable {
    let suggestedFilename: String
    let contentType: UTType
    let writer: @MainActor @Sendable (URL) async throws -> Void
    let completion: (@MainActor @Sendable (Result<URL, Error>) -> Void)?

    init(
        suggestedFilename: String,
        contentType: UTType,
        writer: @escaping @MainActor @Sendable (URL) async throws -> Void,
        completion: (@MainActor @Sendable (Result<URL, Error>) -> Void)? = nil
    ) {
        self.suggestedFilename = suggestedFilename
        self.contentType = contentType
        self.writer = writer
        self.completion = completion
    }

    func write(to destinationURL: URL) async throws {
        do {
            try await writer(destinationURL)
            await completion?(.success(destinationURL))
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            await completion?(.failure(error))
            throw error
        }
    }
}

struct PromisedFileDragView: NSViewRepresentable {
    let accessibilityLabel: String
    let payloadProvider: @MainActor () -> PromisedFilePayload?
    var showsIcon = true

    func makeNSView(context: Context) -> PromisedFileDragNSView {
        PromisedFileDragNSView(
            accessibilityLabel: accessibilityLabel,
            payloadProvider: payloadProvider,
            showsIcon: showsIcon
        )
    }

    func updateNSView(_ nsView: PromisedFileDragNSView, context: Context) {
        nsView.accessibilityLabelText = accessibilityLabel
        nsView.setAccessibilityLabel(accessibilityLabel)
        nsView.payloadProvider = payloadProvider
        nsView.showsIcon = showsIcon
        nsView.needsDisplay = true
    }
}

final class PromisedFileDragNSView: NSView, NSDraggingSource {
    private static let clickGuidanceTitle = "Drag to share"
    private static let clickGuidanceMessage = "Click and hold, then drag this item into Finder, Mail, Messages, or another app to share the rendered file."
    private static let visibleLabel = "Drag"

    var accessibilityLabelText: String
    var payloadProvider: @MainActor () -> PromisedFilePayload?
    var showsIcon: Bool

    private var mouseDownEvent: NSEvent?
    private var isPressed = false
    private var draggingDelegate: PromisedFileProviderDelegate?
    private var activeDelegates: [PromisedFileProviderDelegate] = []
    private var clickGuidancePopover: NSPopover?
    private var hiddenWindowDuringDrag: NSWindow?
    private var dragWindowWasKey = false

    init(
        accessibilityLabel: String,
        payloadProvider: @escaping @MainActor () -> PromisedFilePayload?,
        showsIcon: Bool
    ) {
        self.accessibilityLabelText = accessibilityLabel
        self.payloadProvider = payloadProvider
        self.showsIcon = showsIcon
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        showsIcon ? NSSize(width: 68, height: 30) : .zero
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        setAccessibilityLabel(accessibilityLabelText)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard showsIcon else {
            return
        }

        let buttonBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: buttonBounds, xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(isPressed ? 0.14 : 0.08).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.28).setStroke()
        path.lineWidth = 0.75
        path.stroke()

        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: "document.badge.arrow.up", accessibilityDescription: accessibilityLabelText)?
            .withSymbolConfiguration(configuration)
        image?.draw(in: NSRect(x: 10, y: (bounds.height - 14) / 2, width: 14, height: 14))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let label = NSAttributedString(string: Self.visibleLabel, attributes: attributes)
        let labelSize = label.size()
        label.draw(at: NSPoint(x: 30, y: (bounds.height - labelSize.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        isPressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent,
              let payload = payloadProvider() else {
            return
        }

        self.mouseDownEvent = nil
        isPressed = false
        needsDisplay = true
        let delegate = PromisedFileProviderDelegate(payload: payload) { [weak self] delegate in
            self?.activeDelegates.removeAll { $0 === delegate }
        }
        let provider = NSFilePromiseProvider(fileType: payload.contentType.identifier, delegate: delegate)
        let draggingItem = NSDraggingItem(pasteboardWriter: provider)
        let dragImage = NSImage(systemSymbolName: "document.badge.arrow.up", accessibilityDescription: accessibilityLabelText)
            ?? NSWorkspace.shared.icon(for: payload.contentType)
        draggingItem.setDraggingFrame(NSRect(origin: .zero, size: NSSize(width: 32, height: 32)), contents: dragImage)
        draggingDelegate = delegate
        activeDelegates.append(delegate)

        beginDraggingSession(with: [draggingItem], event: mouseDownEvent, source: self)
        hideContainingWindowForDrag()
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil {
            showClickGuidance()
        }
        mouseDownEvent = nil
        isPressed = false
        needsDisplay = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.isEmpty {
            if let draggingDelegate {
                activeDelegates.removeAll { $0 === draggingDelegate }
            }
        }
        draggingDelegate = nil
        restoreContainingWindowAfterDrag()
    }

    private func showClickGuidance() {
        clickGuidancePopover?.close()

        let content = VStack(alignment: .leading, spacing: 6) {
            Text(Self.clickGuidanceTitle)
                .font(.headline)
            Text(Self.clickGuidanceMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 96)
        popover.contentViewController = NSHostingController(rootView: content)
        clickGuidancePopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    private func hideContainingWindowForDrag() {
        clickGuidancePopover?.close()
        guard hiddenWindowDuringDrag == nil,
              let window,
              window.isVisible,
              !window.isMiniaturized else {
            return
        }

        hiddenWindowDuringDrag = window
        dragWindowWasKey = window.isKeyWindow
        window.orderOut(nil)
    }

    private func restoreContainingWindowAfterDrag() {
        guard let window = hiddenWindowDuringDrag else {
            return
        }

        hiddenWindowDuringDrag = nil
        DispatchQueue.main.async {
            if self.dragWindowWasKey {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
            self.dragWindowWasKey = false
        }
    }
}

nonisolated final class PromisedFileProviderDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    nonisolated private final class CompletionHandler: @unchecked Sendable {
        private let handler: (Error?) -> Void

        init(_ handler: @escaping (Error?) -> Void) {
            self.handler = handler
        }

        nonisolated func callAsFunction(_ error: Error?) {
            handler(error)
        }
    }

    private let payload: PromisedFilePayload
    private let didFinish: @MainActor (PromisedFileProviderDelegate) -> Void
    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(payload: PromisedFilePayload, didFinish: @escaping @MainActor (PromisedFileProviderDelegate) -> Void) {
        self.payload = payload
        self.didFinish = didFinish
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        payload.suggestedFilename
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let completionHandler = CompletionHandler(completionHandler)
        let didStartAccessing = url.startAccessingSecurityScopedResource()

        Task {
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
                Task { @MainActor in
                    didFinish(self)
                }
            }

            do {
                try await payload.write(to: url)
                await completePromise(with: nil, completionHandler: completionHandler)
            } catch {
                await completePromise(with: error, completionHandler: completionHandler)
            }
        }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        operationQueue
    }

    nonisolated private func completePromise(with error: Error?, completionHandler: CompletionHandler) async {
        await withCheckedContinuation { continuation in
            operationQueue.addOperation {
                completionHandler(error)
                continuation.resume()
            }
        }
    }
}
