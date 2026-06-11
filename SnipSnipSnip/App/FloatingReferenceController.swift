import AppKit
import Combine
import SwiftUI

struct FloatingReferenceRequest {
    let title: String
    let subtitle: String?
    let image: CGImage
    let outOfCapturePatternSettings: EditorOutOfCapturePatternSettings
}

@MainActor
final class FloatingReferenceCoordinator: ObservableObject {
    @Published private(set) var activeReferenceCount = 0

    private var windowControllers: [UUID: FloatingReferenceWindowController] = [:]
    private var referenceOrder: [UUID] = []

    var hasActiveReferences: Bool {
        activeReferenceCount > 0
    }

    func present(_ request: FloatingReferenceRequest) {
        closeOldestReferencesIfNeeded()

        let model = FloatingReferenceWindowModel(request: request)
        let windowFrame = FloatingReferenceWindowPlacementPolicy.initialFrame(
            forPixelSize: model.pixelSize,
            visibleFrame: FloatingReferenceWindowPlacementPolicy.preferredVisibleFrame(),
            referenceIndex: referenceOrder.count
        )
        let windowController = FloatingReferenceWindowController(
            model: model,
            initialFrame: windowFrame,
            onClose: { [weak self] id in
                self?.referenceDidClose(id)
            }
        )

        windowControllers[model.id] = windowController
        referenceOrder.append(model.id)
        refreshCounts()
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    func closeAll() {
        for controller in Array(windowControllers.values) {
            controller.close()
        }

        windowControllers.removeAll()
        referenceOrder.removeAll()
        refreshCounts()
    }

    private func closeOldestReferencesIfNeeded() {
        let referencesToClose = FloatingReferenceRetentionPolicy.referencesToCloseBeforeAddingReference(
            currentOrder: referenceOrder
        )

        for id in referencesToClose {
            windowControllers[id]?.close()
        }
    }

    private func referenceDidClose(_ id: UUID) {
        windowControllers[id] = nil
        referenceOrder.removeAll { $0 == id }
        refreshCounts()
    }

    private func refreshCounts() {
        activeReferenceCount = windowControllers.count
    }
}

nonisolated enum FloatingReferenceRetentionPolicy {
    static let maximumActiveReferences = 8

    static func referencesToCloseBeforeAddingReference(
        currentOrder: [UUID],
        maximumActiveReferences: Int = Self.maximumActiveReferences
    ) -> [UUID] {
        guard maximumActiveReferences > 0 else {
            return currentOrder
        }

        let maximumExistingReferences = maximumActiveReferences - 1
        let overflowCount = max(currentOrder.count - maximumExistingReferences, 0)
        return Array(currentOrder.prefix(overflowCount))
    }
}

nonisolated enum FloatingReferenceWindowPlacementPolicy {
    private static let edgePadding: CGFloat = 28
    private static let cascadeStep: CGFloat = 26
    private static let maximumCascadeSteps = 8

    @MainActor
    static func preferredVisibleFrame() -> CGRect {
        let mouseLocation = NSEvent.mouseLocation

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen.visibleFrame
        }

        if let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main {
            return screen.visibleFrame
        }

        return NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
    }

    static func initialFrame(
        forPixelSize pixelSize: CGSize,
        visibleFrame: CGRect,
        referenceIndex: Int
    ) -> CGRect {
        let size = FloatingReferenceWindowSizing.initialWindowSize(
            for: pixelSize,
            fittingWithin: visibleFrame.size
        )
        return initialFrame(forWindowSize: size, visibleFrame: visibleFrame, referenceIndex: referenceIndex)
    }

    static func initialFrame(
        forWindowSize windowSize: CGSize,
        visibleFrame: CGRect,
        referenceIndex: Int
    ) -> CGRect {
        let usableWidth = max(visibleFrame.width - edgePadding * 2, 1)
        let usableHeight = max(visibleFrame.height - edgePadding * 2, 1)
        let minimumWidth = min(FloatingReferenceWindowSizing.minimumWindowSize.width, usableWidth)
        let minimumHeight = min(FloatingReferenceWindowSizing.minimumWindowSize.height, usableHeight)
        let clampedSize = CGSize(
            width: min(max(windowSize.width, minimumWidth), usableWidth),
            height: min(max(windowSize.height, minimumHeight), usableHeight)
        )
        let cascadeOffset = CGFloat(referenceIndex % maximumCascadeSteps) * cascadeStep
        let proposedOrigin = CGPoint(
            x: visibleFrame.maxX - clampedSize.width - edgePadding - cascadeOffset,
            y: visibleFrame.maxY - clampedSize.height - edgePadding - cascadeOffset
        )
        let minX = visibleFrame.minX + edgePadding
        let maxX = visibleFrame.maxX - edgePadding - clampedSize.width
        let minY = visibleFrame.minY + edgePadding
        let maxY = visibleFrame.maxY - edgePadding - clampedSize.height

        return CGRect(
            x: min(max(proposedOrigin.x, minX), max(minX, maxX)),
            y: min(max(proposedOrigin.y, minY), max(minY, maxY)),
            width: clampedSize.width,
            height: clampedSize.height
        ).integral
    }
}

nonisolated enum FloatingReferenceWindowSizing {
    static let defaultWindowSize = CGSize(width: 520, height: 340)
    static let minimumWindowSize = CGSize(width: 360, height: 220)
    static let maximumWindowSize = CGSize(width: 720, height: 520)

    static func initialWindowSize(for pixelSize: CGSize, fittingWithin availableSize: CGSize? = nil) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return clampedForAvailableDisplay(defaultWindowSize, availableSize: availableSize)
        }

        let aspectRatio = pixelSize.width / pixelSize.height
        var size = pixelSize

        if size.width > maximumWindowSize.width {
            size.width = maximumWindowSize.width
            size.height = size.width / aspectRatio
        }

        if size.height > maximumWindowSize.height {
            size.height = maximumWindowSize.height
            size.width = size.height * aspectRatio
        }

        if size.width < minimumWindowSize.width {
            size.width = minimumWindowSize.width
            size.height = size.width / aspectRatio
        }

        if size.height < minimumWindowSize.height {
            size.height = minimumWindowSize.height
            size.width = size.height * aspectRatio
        }

        return clampedForAvailableDisplay(CGSize(
            width: min(max(size.width, minimumWindowSize.width), maximumWindowSize.width),
            height: min(max(size.height, minimumWindowSize.height), maximumWindowSize.height)
        ), availableSize: availableSize)
    }

    private static func clampedForAvailableDisplay(_ size: CGSize, availableSize: CGSize?) -> CGSize {
        guard let availableSize else {
            return size
        }

        return CGSize(
            width: min(size.width, max(availableSize.width, 1)),
            height: min(size.height, max(availableSize.height, 1))
        )
    }
}

@MainActor
final class FloatingReferenceCloseNotifier {
    private(set) var didNotifyClose = false
    private let id: UUID
    private let onClose: (UUID) -> Void

    init(id: UUID, onClose: @escaping (UUID) -> Void) {
        self.id = id
        self.onClose = onClose
    }

    func notifyIfNeeded() {
        guard !didNotifyClose else {
            return
        }

        didNotifyClose = true
        onClose(id)
    }
}

enum FloatingReferenceZoomAction {
    case zoomOut
    case zoomIn
    case fit
}

struct FloatingReferenceZoomRequest: Equatable {
    let id = UUID()
    let action: FloatingReferenceZoomAction
}

@MainActor
final class FloatingReferenceWindowModel: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let image: CGImage
    let pixelSize: CGSize
    let outOfCapturePatternSettings: EditorOutOfCapturePatternSettings

    @Published var opacity: Double = 1
    @Published var zoomRequest: FloatingReferenceZoomRequest?

    init(request: FloatingReferenceRequest) {
        title = request.title
        subtitle = request.subtitle
        image = request.image
        pixelSize = CGSize(width: request.image.width, height: request.image.height)
        outOfCapturePatternSettings = request.outOfCapturePatternSettings
    }
}

@MainActor
final class FloatingReferenceWindowController: NSWindowController {
    let model: FloatingReferenceWindowModel

    private var cancellables: Set<AnyCancellable> = []
    private let closeNotifier: FloatingReferenceCloseNotifier

    init(
        model: FloatingReferenceWindowModel,
        initialFrame: CGRect,
        onClose: @escaping (UUID) -> Void
    ) {
        self.model = model
        closeNotifier = FloatingReferenceCloseNotifier(id: model.id, onClose: onClose)

        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = model.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.minSize = FloatingReferenceWindowSizing.minimumWindowSize
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(
            rootView: FloatingReferenceWindowView(
                model: model,
                onClose: { [weak panel] in
                    panel?.close()
                }
            )
        )

        super.init(window: panel)
        panel.delegate = self
        observeModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("FloatingReferenceWindowController is programmatic-only; use init(model:onClose:) instead of init(coder:).")
    }

    override func close() {
        super.close()
        closeNotifier.notifyIfNeeded()
    }

    private func observeModel() {
        model.$opacity
            .sink { [weak self] opacity in
                self?.window?.alphaValue = max(0.35, min(opacity, 1))
            }
            .store(in: &cancellables)
    }
}

extension FloatingReferenceWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        closeNotifier.notifyIfNeeded()
    }
}

private struct FloatingReferenceWindowView: View {
    @ObservedObject var model: FloatingReferenceWindowModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            menuBar

            ZoomableReferenceImageView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.16))
                .help("Floating reference image. Scroll to pan, pinch to zoom, or use the zoom controls.")
        }
        .background(.regularMaterial)
    }

    private var menuBar: some View {
        HStack(spacing: 8) {
            dragHandle

            titleBlock

            Spacer(minLength: 8)

            zoomMenu

            Divider()
                .frame(height: 18)
                .opacity(0.28)

            opacityControls

            closeButton
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
    }

    private var dragHandle: some View {
        ZStack {
            Image(systemName: "line.horizontal.3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)

            WindowDragHandleView()
                .frame(width: 30, height: 30)
        }
        .help("Drag to move this floating reference.")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            if let subtitle = model.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .layoutPriority(1)
        .help(referenceTitleHelp)
    }

    private var zoomMenu: some View {
        Menu {
            Button("Zoom In") {
                model.zoomRequest = FloatingReferenceZoomRequest(action: .zoomIn)
            }

            Button("Zoom Out") {
                model.zoomRequest = FloatingReferenceZoomRequest(action: .zoomOut)
            }

            Divider()

            Button("Fit to View") {
                model.zoomRequest = FloatingReferenceZoomRequest(action: .fit)
            }
        } label: {
            Label("Zoom", systemImage: "magnifyingglass")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Zoom in, zoom out, or fit the reference image to the view.")
    }

    private var opacityControls: some View {
        HStack(spacing: 8) {
            Button {
                model.opacity = 1
            } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(model.opacity >= 0.995)
            .help("Reset opacity to 100%.")

            ClickToSlideOpacityControl(value: $model.opacity, range: 0.35...1)
                .frame(width: 96, height: 20)
                .help("Set reference opacity. Click anywhere on the track or drag the knob.")
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help("Close this floating reference.")
    }

    private var referenceTitleHelp: String {
        if let subtitle = model.subtitle {
            return "\(model.title) - \(subtitle)"
        }

        return model.title
    }
}

private struct ZoomableReferenceImageView: NSViewRepresentable {
    @ObservedObject var model: FloatingReferenceWindowModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ZoomableReferenceCanvasView {
        let canvasView = ZoomableReferenceCanvasView()
        canvasView.configure(
            image: model.image,
            outOfCapturePatternSettings: model.outOfCapturePatternSettings
        )
        return canvasView
    }

    func updateNSView(_ nsView: ZoomableReferenceCanvasView, context: Context) {
        nsView.configure(
            image: model.image,
            outOfCapturePatternSettings: model.outOfCapturePatternSettings
        )

        if let request = model.zoomRequest,
           request.id != context.coordinator.lastZoomRequestID {
            context.coordinator.lastZoomRequestID = request.id
            nsView.applyZoomAction(request.action)
        }
    }

    final class Coordinator {
        var lastZoomRequestID: UUID?
    }
}

private final class ZoomableReferenceCanvasView: NSView {
    private var currentImage: CGImage?
    private var imageSize: CGSize = .zero
    private var image: NSImage?
    private var outOfCapturePatternSettings: EditorOutOfCapturePatternSettings = .default
    private var viewport = EditorViewport()
    private var followsFitToViewport = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("ZoomableReferenceCanvasView is programmatic-only; use init(frame:) instead of init(coder:).")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        synchronizeViewportToBounds()

        if followsFitToViewport {
            viewport = viewport.zoomedToFit()
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        guard let image else {
            return
        }

        let imageRect = viewport.imageRect.integral
        OutOfCapturePatternRenderer.draw(
            bounds: bounds,
            excluding: imageRect,
            settings: outOfCapturePatternSettings,
            appearance: effectiveAppearance
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        image.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    func configure(
        image: CGImage,
        outOfCapturePatternSettings: EditorOutOfCapturePatternSettings
    ) {
        let imageDidChange = currentImage !== image
        let patternDidChange = self.outOfCapturePatternSettings != outOfCapturePatternSettings

        guard imageDidChange || patternDidChange else {
            return
        }

        self.outOfCapturePatternSettings = outOfCapturePatternSettings

        if imageDidChange {
            currentImage = image
            imageSize = CGSize(width: image.width, height: image.height)
            self.image = NSImage(cgImage: image, size: imageSize)
            viewport = viewport.updatingContentSize(imageSize, fitToWindow: true)
            followsFitToViewport = true
            needsLayout = true
        }

        needsDisplay = true
    }

    func applyZoomAction(_ action: FloatingReferenceZoomAction) {
        synchronizeViewportToBounds()

        switch action {
        case .zoomOut:
            followsFitToViewport = false
            viewport = viewport.zoomed(to: viewport.zoomScale / 1.25)
        case .zoomIn:
            followsFitToViewport = false
            viewport = viewport.zoomed(to: viewport.zoomScale * 1.25)
        case .fit:
            followsFitToViewport = true
            viewport = viewport.zoomedToFit()
        }

        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        followsFitToViewport = false
        synchronizeViewportToBounds()
        let factor = max(0.05, 1 + event.magnification)
        viewport = viewport.zoomed(to: viewport.zoomScale * factor, anchoredAt: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        synchronizeViewportToBounds()
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command) || modifiers.contains(.option) {
            guard event.scrollingDeltaY != 0 else {
                return
            }

            followsFitToViewport = false
            let factor = pow(1.0018, event.scrollingDeltaY)
            viewport = viewport.zoomed(to: viewport.zoomScale * factor, anchoredAt: convert(event.locationInWindow, from: nil))
        } else {
            viewport = viewport.panned(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }

        needsDisplay = true
    }

    private func synchronizeViewportToBounds() {
        viewport = viewport.updatingCanvasSize(bounds.size)
    }
}

private struct WindowDragHandleView: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleNSView {
        DragHandleNSView()
    }

    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}
}

private final class DragHandleNSView: NSView {
    override var acceptsFirstResponder: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct ClickToSlideOpacityControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private let knobDiameter: CGFloat = 14
    private let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let progress = progress(for: value)
            let trackWidth = max(proxy.size.width - knobDiameter, 1)
            let knobOffset = trackWidth * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(height: trackHeight)
                    .padding(.horizontal, knobDiameter / 2)

                Capsule()
                    .fill(Color.accentColor.opacity(0.82))
                    .frame(width: knobOffset + knobDiameter / 2, height: trackHeight)
                    .padding(.leading, knobDiameter / 2)

                Circle()
                    .fill(Color.primary.opacity(0.94))
                    .frame(width: knobDiameter, height: knobDiameter)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
                    .offset(x: knobOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        updateValue(from: drag.location.x, in: proxy.size.width)
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reference opacity")
        .accessibilityValue("\(Int(round(value * 100))) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05

            switch direction {
            case .increment:
                value = clamped(value + step)
            case .decrement:
                value = clamped(value - step)
            @unknown default:
                break
            }
        }
    }

    private func updateValue(from x: CGFloat, in width: CGFloat) {
        let trackWidth = max(width - knobDiameter, 1)
        let normalizedX = min(max(x - knobDiameter / 2, 0), trackWidth)
        let progress = Double(normalizedX / trackWidth)
        value = clamped(range.lowerBound + progress * (range.upperBound - range.lowerBound))
    }

    private func progress(for value: Double) -> CGFloat {
        CGFloat((clamped(value) - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
