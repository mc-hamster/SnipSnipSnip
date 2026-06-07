import AppKit
import Combine
import SwiftUI

@MainActor
final class ScreenRulerCoordinator: ObservableObject {
    @Published private(set) var activeRulerCount = 0

    private var windowControllers: [UUID: ScreenRulerWindowController] = [:]
    private var preferences: ScreenRulerPreferences

    init(preferences: ScreenRulerPreferences = .default) {
        self.preferences = preferences.sanitized()
    }

    var hasActiveRulers: Bool {
        activeRulerCount > 0
    }

    func updatePreferences(_ preferences: ScreenRulerPreferences) {
        self.preferences = preferences.sanitized()
        for controller in windowControllers.values {
            controller.model.preferences = self.preferences
        }
    }

    func present(_ kind: ScreenRulerKind) {
        let model = ScreenRulerWindowModel(kind: kind, preferences: preferences)
        let controller = ScreenRulerWindowController(
            model: model,
            onClose: { [weak self] id in
                self?.windowControllers[id] = nil
                self?.refreshCount()
            }
        )

        windowControllers[model.id] = controller
        refreshCount()
        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()
    }

    func closeAll() {
        for controller in Array(windowControllers.values) {
            controller.close()
        }

        windowControllers.removeAll()
        refreshCount()
    }

    private func refreshCount() {
        activeRulerCount = windowControllers.count
    }
}

@MainActor
final class ScreenRulerWindowModel: ObservableObject, Identifiable {
    let id = UUID()
    let kind: ScreenRulerKind

    @Published var preferences: ScreenRulerPreferences
    @Published var mouseLocation: CGPoint?

    init(kind: ScreenRulerKind, preferences: ScreenRulerPreferences) {
        self.kind = kind
        self.preferences = preferences.sanitized()
    }

    var title: String {
        kind.label
    }
}

@MainActor
final class ScreenRulerWindowController: NSWindowController {
    let model: ScreenRulerWindowModel

    private let onClose: (UUID) -> Void
    private var hasNotifiedClose = false
    private var cancellables: Set<AnyCancellable> = []

    init(model: ScreenRulerWindowModel, onClose: @escaping (UUID) -> Void) {
        self.model = model
        self.onClose = onClose

        let panel = NSPanel(
            contentRect: Self.initialFrame(for: model.kind),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(ScreenRulerWindowID.prefix + model.id.uuidString)
        panel.title = model.title
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.minSize = Self.minimumSize(for: model.kind)
        panel.contentView = NSHostingView(
            rootView: ScreenRulerWindowView(
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
        preconditionFailure("ScreenRulerWindowController is programmatic-only; use init(model:onClose:) instead of init(coder:).")
    }

    override func close() {
        super.close()
        notifyClosed()
    }

    private func notifyClosed() {
        guard !hasNotifiedClose else {
            return
        }

        hasNotifiedClose = true
        onClose(model.id)
    }

    private static func initialFrame(for kind: ScreenRulerKind) -> CGRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 160, y: 160, width: 900, height: 600)
        let size: CGSize

        switch kind {
        case .horizontal:
            size = CGSize(width: 640, height: 86)
        case .vertical:
            size = CGSize(width: 86, height: 520)
        }

        return CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func minimumSize(for kind: ScreenRulerKind) -> CGSize {
        switch kind {
        case .horizontal:
            return CGSize(width: 220, height: 70)
        case .vertical:
            return CGSize(width: 70, height: 220)
        }
    }

    private func observeModel() {
        model.$preferences
            .sink { [weak self] preferences in
                self?.window?.alphaValue = preferences.sanitized().opacity
            }
            .store(in: &cancellables)
    }
}

extension ScreenRulerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        notifyClosed()
    }
}

private struct ScreenRulerWindowView: View {
    @ObservedObject var model: ScreenRulerWindowModel
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            rulerContent
                .padding(12)

            WindowInteractionOverlayView(kind: model.kind) { point in
                model.mouseLocation = point
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            controls
                .padding(6)
                .zIndex(2)
        }
    }

    @ViewBuilder
    private var rulerContent: some View {
        rulerBody
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.22), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var rulerBody: some View {
        switch model.kind {
        case .horizontal:
            LinearScreenRulerView(axis: .horizontal, model: model)
        case .vertical:
            LinearScreenRulerView(axis: .vertical, model: model)
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .help("Close this ruler.")
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .padding(5)
        .background(.regularMaterial, in: Capsule())
    }
}

private enum RulerAxis {
    case horizontal
    case vertical
}

private struct LinearScreenRulerView: View {
    let axis: RulerAxis
    @ObservedObject var model: ScreenRulerWindowModel

    var body: some View {
        Canvas { context, size in
            drawBackground(in: &context, size: size)
            drawTicks(in: &context, size: size)
            drawMouseDistance(in: &context, size: size)
        }
        .frame(
            minWidth: axis == .horizontal ? 180 : 46,
            minHeight: axis == .vertical ? 180 : 46
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func drawBackground(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .color(Color.black.opacity(0.18)))
    }

    private func drawTicks(in context: inout GraphicsContext, size: CGSize) {
        let preferences = model.preferences.sanitized()
        let length = axis == .horizontal ? size.width : size.height
        let thickness = axis == .horizontal ? size.height : size.width
        let tickCount = max(1, Int(length / preferences.tickSpacing))

        for index in 0...tickCount {
            let position = CGFloat(index) * preferences.tickSpacing
            let isMajor = index % preferences.majorTickEvery == 0
            let isHalf = preferences.showsHalfMarkers && index % max(1, preferences.majorTickEvery / 2) == 0
            let tickLength = isMajor ? thickness * 0.78 : (isHalf ? thickness * 0.52 : thickness * 0.34)
            var path = Path()

            if axis == .horizontal {
                path.move(to: CGPoint(x: position, y: thickness))
                path.addLine(to: CGPoint(x: position, y: thickness - tickLength))
            } else {
                path.move(to: CGPoint(x: 0, y: position))
                path.addLine(to: CGPoint(x: tickLength, y: position))
            }

            context.stroke(path, with: .color(Color.primary.opacity(isMajor ? 0.82 : 0.48)), lineWidth: isMajor ? 1.25 : 0.75)

            if isMajor {
                drawLabel("\(Int(round(position)))", at: labelPoint(for: position, thickness: thickness), in: &context)
            }
        }
    }

    private func drawMouseDistance(in context: inout GraphicsContext, size: CGSize) {
        guard model.preferences.showsMouseDistance,
              let mouseLocation = model.mouseLocation,
              mouseLocation.x >= 0,
              mouseLocation.y >= 0,
              mouseLocation.x <= size.width,
              mouseLocation.y <= size.height else {
            return
        }

        let canvasMouseLocation = axis == .horizontal
            ? mouseLocation
            : CGPoint(x: mouseLocation.x, y: size.height - mouseLocation.y)
        let value = axis == .horizontal ? canvasMouseLocation.x : canvasMouseLocation.y
        let label = "\(Int(round(value))) px"
        let point = axis == .horizontal
            ? CGPoint(x: min(max(canvasMouseLocation.x + 26, 42), size.width - 42), y: 18)
            : CGPoint(x: min(max(size.width / 2, 36), size.width - 36), y: min(max(canvasMouseLocation.y - 18, 18), size.height - 18))

        var line = Path()
        if axis == .horizontal {
            line.move(to: CGPoint(x: canvasMouseLocation.x, y: 0))
            line.addLine(to: CGPoint(x: canvasMouseLocation.x, y: size.height))
        } else {
            line.move(to: CGPoint(x: 0, y: canvasMouseLocation.y))
            line.addLine(to: CGPoint(x: size.width, y: canvasMouseLocation.y))
        }
        context.stroke(line, with: .color(.accentColor.opacity(0.85)), lineWidth: 1)
        drawBadge(label, at: point, in: &context)
    }

    private func labelPoint(for position: CGFloat, thickness: CGFloat) -> CGPoint {
        switch axis {
        case .horizontal:
            return CGPoint(x: position + 18, y: thickness - 18)
        case .vertical:
            return CGPoint(x: 26, y: position + 12)
        }
    }

    private func drawLabel(_ text: String, at point: CGPoint, in context: inout GraphicsContext) {
        context.draw(
            Text(text).font(.caption2.monospacedDigit()).foregroundStyle(.primary.opacity(0.78)),
            at: point,
            anchor: .center
        )
    }

    private func drawBadge(_ text: String, at point: CGPoint, in context: inout GraphicsContext) {
        let badgeRect = CGRect(x: point.x - 34, y: point.y - 11, width: 68, height: 22)
        context.fill(Path(roundedRect: badgeRect, cornerRadius: 5), with: .color(.accentColor.opacity(0.88)))
        context.draw(Text(text).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white), at: point)
    }
}

private struct WindowInteractionOverlayView: NSViewRepresentable {
    let kind: ScreenRulerKind
    let onMouseLocationChange: (CGPoint?) -> Void

    func makeNSView(context: Context) -> InteractionOverlayView {
        InteractionOverlayView(kind: kind, onMouseLocationChange: onMouseLocationChange)
    }

    func updateNSView(_ nsView: InteractionOverlayView, context: Context) {
        nsView.kind = kind
        nsView.onMouseLocationChange = onMouseLocationChange
    }

    final class InteractionOverlayView: NSView {
        private enum Interaction {
            case move
            case right
            case bottom
        }

        private let edgeHitSize: CGFloat = 18
        private let cornerHitSize: CGFloat = 56
        private let controlExclusionWidth: CGFloat = 52
        private let controlExclusionHeight: CGFloat = 40
        var kind: ScreenRulerKind {
            didSet {
                needsDisplay = true
            }
        }
        var onMouseLocationChange: (CGPoint?) -> Void
        private var dragStartPoint: CGPoint?
        private var dragStartFrame: CGRect?
        private var dragStartTopY: CGFloat?
        private var dragStartBottomInset: CGFloat?
        private var activeInteraction: Interaction?
        private var trackingArea: NSTrackingArea?

        init(kind: ScreenRulerKind, onMouseLocationChange: @escaping (CGPoint?) -> Void) {
            self.kind = kind
            self.onMouseLocationChange = onMouseLocationChange
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            preconditionFailure("ScreenRulerContentView is programmatic-only; use init(kind:onMouseLocationChange:) instead of init(coder:).")
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            isInControlStrip(point) ? nil : self
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.8

            switch kind {
            case .horizontal:
                let gripHeight: CGFloat = min(42, max(24, bounds.height - 20))
                let centerY = bounds.midY
                for offset in stride(from: CGFloat(8), through: 24, by: 8) {
                    path.move(to: CGPoint(x: bounds.maxX - offset, y: centerY - gripHeight / 2))
                    path.line(to: CGPoint(x: bounds.maxX - offset, y: centerY + gripHeight / 2))
                }
            case .vertical:
                let gripWidth: CGFloat = min(42, max(24, bounds.width - 20))
                let centerX = bounds.midX
                for offset in stride(from: CGFloat(8), through: 24, by: 8) {
                    path.move(to: CGPoint(x: centerX - gripWidth / 2, y: bounds.minY + offset))
                    path.line(to: CGPoint(x: centerX + gripWidth / 2, y: bounds.minY + offset))
                }
            }

            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            let localPoint = convert(event.locationInWindow, from: nil)
            activeInteraction = interaction(at: localPoint)
            dragStartPoint = NSEvent.mouseLocation
            dragStartFrame = window?.frame
            dragStartTopY = window?.frame.maxY
            dragStartBottomInset = window.map { NSEvent.mouseLocation.y - $0.frame.minY }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window,
                  let dragStartPoint,
                  let dragStartFrame,
                  let activeInteraction else {
                return
            }

            let currentPoint = NSEvent.mouseLocation
            let deltaX = currentPoint.x - dragStartPoint.x
            let deltaY = currentPoint.y - dragStartPoint.y
            var nextFrame = dragStartFrame

            switch activeInteraction {
            case .move:
                nextFrame.origin.x = dragStartFrame.origin.x + deltaX
                nextFrame.origin.y = dragStartFrame.origin.y + deltaY
            case .right:
                nextFrame.size.width = max(window.minSize.width, dragStartFrame.width + deltaX)
            case .bottom:
                resizeBottomEdge(
                    currentPoint: currentPoint,
                    minimumHeight: window.minSize.height,
                    frame: &nextFrame
                )
            }

            window.setFrame(nextFrame, display: true)
        }

        override func mouseUp(with event: NSEvent) {
            dragStartPoint = nil
            dragStartFrame = nil
            dragStartTopY = nil
            dragStartBottomInset = nil
            activeInteraction = nil
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                removeTrackingArea(trackingArea)
            }

            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            onMouseLocationChange(convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            onMouseLocationChange(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onMouseLocationChange(nil)
        }

        private func interaction(at point: CGPoint) -> Interaction {
            let isRight = point.x >= bounds.maxX - edgeHitSize
            let isBottom = point.y <= bounds.minY + edgeHitSize

            switch kind {
            case .horizontal:
                if isRight || point.x >= bounds.maxX - cornerHitSize {
                    return .right
                }
            case .vertical:
                if isBottom || point.y <= bounds.minY + cornerHitSize {
                    return .bottom
                }
            }

            return .move
        }

        private func isInControlStrip(_ point: CGPoint) -> Bool {
            point.x >= bounds.maxX - controlExclusionWidth
                && point.y >= bounds.maxY - controlExclusionHeight
        }

        private func resizeBottomEdge(currentPoint: CGPoint, minimumHeight: CGFloat, frame: inout CGRect) {
            let topY = dragStartTopY ?? frame.maxY
            let bottomInset = dragStartBottomInset ?? 0
            let proposedBottomY = currentPoint.y - bottomInset
            let height = max(minimumHeight, topY - proposedBottomY)

            frame.size.height = height
            frame.origin.y = topY - height
        }
    }
}

private struct WindowMouseTrackingView: NSViewRepresentable {
    let onMouseLocationChange: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(onMouseLocationChange: onMouseLocationChange)
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMouseLocationChange = onMouseLocationChange
    }

    final class TrackingView: NSView {
        var onMouseLocationChange: (CGPoint?) -> Void
        private var trackingArea: NSTrackingArea?

        init(onMouseLocationChange: @escaping (CGPoint?) -> Void) {
            self.onMouseLocationChange = onMouseLocationChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            preconditionFailure("ScreenRulerTrackingView is programmatic-only; use init(onMouseLocationChange:) instead of init(coder:).")
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                removeTrackingArea(trackingArea)
            }

            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            onMouseLocationChange(convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            onMouseLocationChange(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onMouseLocationChange(nil)
        }
    }
}
