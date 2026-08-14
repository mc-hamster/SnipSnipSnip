import AppKit
import Combine
import SwiftUI

@MainActor
final class ScreenRulerCoordinator: ObservableObject {
    @Published private(set) var activeRulerCount = 0

    private var windowControllers: [UUID: ScreenRulerWindowController] = [:]
    private var preferences: ScreenRulerPreferences
    private var preferencesChangeHandler: ((ScreenRulerPreferences) -> Void)?

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

    func setPreferencesChangeHandler(_ handler: @escaping (ScreenRulerPreferences) -> Void) {
        preferencesChangeHandler = handler
    }

    func present(_ kind: ScreenRulerKind) {
        let model = ScreenRulerWindowModel(
            kind: kind,
            preferences: preferences
        )
        let controller = ScreenRulerWindowController(
            model: model,
            onClose: { [weak self] id in
                self?.windowControllers[id] = nil
                self?.refreshCount()
            }
        )

        windowControllers[model.id] = controller
        refreshCount()
        Task { @MainActor [weak self, weak controller] in
            await Task.yield()
            guard let self,
                  let controller,
                  self.windowControllers[model.id] === controller else {
                return
            }

            controller.showWindow(nil)
            controller.window?.orderFrontRegardless()
        }
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

    init(
        kind: ScreenRulerKind,
        preferences: ScreenRulerPreferences
    ) {
        self.kind = kind
        self.preferences = preferences.sanitized()
    }

    var title: String {
        kind.label
    }

    func toggleTickEdge() {
        var nextPreferences = preferences

        switch kind {
        case .horizontal:
            nextPreferences.horizontalTickEdge = nextPreferences.horizontalTickEdge.toggled
            if nextPreferences.horizontalTickEdge == .bottom {
                nextPreferences.horizontalOrigin = nextPreferences.horizontalOrigin.toggled
            }
        case .vertical:
            nextPreferences.verticalTickEdge = nextPreferences.verticalTickEdge.toggled
            if nextPreferences.verticalTickEdge == .left {
                nextPreferences.verticalOrigin = nextPreferences.verticalOrigin.toggled
            }
        }

        preferences = nextPreferences.sanitized()
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
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSApp.keyWindow?.screen
            ?? NSApp.mainWindow?.screen
            ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame
            ?? CGRect(x: 160, y: 160, width: 900, height: 600)
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
            return CGSize(width: 220, height: 86)
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

nonisolated enum ScreenRulerResizeGripLayout {
    static let rulerSideInset: CGFloat = 12
    static let rulerTopInset: CGFloat = 28
    static let rulerBottomInset: CGFloat = 12
    static let closeButtonHitSize: CGFloat = 28
    static let closeButtonVisualSize: CGFloat = 20
    static let controlExclusionWidth = closeButtonHitSize
    static let controlExclusionHeight = closeButtonHitSize
    static let resizeTargetDepth: CGFloat = 56

    static func visibleRulerBounds(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + rulerSideInset,
            y: bounds.minY + rulerBottomInset,
            width: max(0, bounds.width - rulerSideInset * 2),
            height: max(0, bounds.height - rulerTopInset - rulerBottomInset)
        )
    }

    static func controlExclusionRect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.maxX - controlExclusionWidth,
            y: bounds.maxY - controlExclusionHeight,
            width: controlExclusionWidth,
            height: controlExclusionHeight
        )
    }

    static func closeButtonVisualRect(in bounds: CGRect) -> CGRect {
        let inset = (closeButtonHitSize - closeButtonVisualSize) / 2
        return CGRect(
            x: bounds.maxX - closeButtonHitSize + inset,
            y: bounds.maxY - closeButtonHitSize + inset,
            width: closeButtonVisualSize,
            height: closeButtonVisualSize
        )
    }

    static func gripLineBounds(for kind: ScreenRulerKind, in bounds: CGRect) -> CGRect {
        let rulerBounds = visibleRulerBounds(in: bounds)

        switch kind {
        case .horizontal:
            let minimumY = rulerBounds.minY + 4
            let maximumY = max(
                minimumY,
                min(rulerBounds.maxY - 4, controlExclusionRect(in: bounds).minY - 4)
            )
            return CGRect(
                x: rulerBounds.maxX - 18,
                y: minimumY,
                width: 12,
                height: maximumY - minimumY
            )
        case .vertical:
            let gripWidth = min(42, max(0, rulerBounds.width - 16))
            return CGRect(
                x: rulerBounds.midX - gripWidth / 2,
                y: rulerBounds.minY + 6,
                width: gripWidth,
                height: 12
            )
        }
    }

    static func resizeTargetRect(for kind: ScreenRulerKind, in bounds: CGRect) -> CGRect {
        switch kind {
        case .horizontal:
            return CGRect(
                x: bounds.maxX - resizeTargetDepth,
                y: bounds.minY,
                width: resizeTargetDepth,
                height: max(0, controlExclusionRect(in: bounds).minY - bounds.minY)
            )
        case .vertical:
            return CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: min(resizeTargetDepth, bounds.height)
            )
        }
    }
}

private struct ScreenRulerWindowView: View {
    @ObservedObject var model: ScreenRulerWindowModel
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            rulerContent
                .padding(.horizontal, ScreenRulerResizeGripLayout.rulerSideInset)
                .padding(.top, ScreenRulerResizeGripLayout.rulerTopInset)
                .padding(.bottom, ScreenRulerResizeGripLayout.rulerBottomInset)

            WindowInteractionOverlayView(kind: model.kind) { point in
                model.mouseLocation = point
            } onClick: {
                model.toggleTickEdge()
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            controls
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
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.caption2.weight(.semibold))
                .frame(
                    width: ScreenRulerResizeGripLayout.closeButtonVisualSize,
                    height: ScreenRulerResizeGripLayout.closeButtonVisualSize
                )
                .background(.regularMaterial, in: Circle())
                .frame(
                    width: ScreenRulerResizeGripLayout.closeButtonHitSize,
                    height: ScreenRulerResizeGripLayout.closeButtonHitSize
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help("Close this ruler.")
        .accessibilityLabel("Close this ruler.")
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
            let value = CGFloat(index) * preferences.tickSpacing
            let position = displayPosition(for: value, length: length, preferences: preferences)
            let isMajor = index % preferences.majorTickEvery == 0
            let isHalf = preferences.showsHalfMarkers && index % max(1, preferences.majorTickEvery / 2) == 0
            let tickLength = isMajor ? thickness * 0.78 : (isHalf ? thickness * 0.52 : thickness * 0.34)
            var path = Path()

            if axis == .horizontal {
                switch preferences.horizontalTickEdge {
                case .top:
                    path.move(to: CGPoint(x: position, y: 0))
                    path.addLine(to: CGPoint(x: position, y: tickLength))
                case .bottom:
                    path.move(to: CGPoint(x: position, y: thickness))
                    path.addLine(to: CGPoint(x: position, y: thickness - tickLength))
                }
            } else {
                switch preferences.verticalTickEdge {
                case .left:
                    path.move(to: CGPoint(x: 0, y: position))
                    path.addLine(to: CGPoint(x: tickLength, y: position))
                case .right:
                    path.move(to: CGPoint(x: thickness, y: position))
                    path.addLine(to: CGPoint(x: thickness - tickLength, y: position))
                }
            }

            context.stroke(path, with: .color(Color.primary.opacity(isMajor ? 0.82 : 0.48)), lineWidth: isMajor ? 1.25 : 0.75)

            if isMajor {
                drawLabel("\(Int(round(value)))", at: labelPoint(for: position, length: length, thickness: thickness), in: &context)
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
        let value = measurementValue(for: canvasMouseLocation, size: size, preferences: model.preferences.sanitized())
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

    private func displayPosition(for value: CGFloat, length: CGFloat, preferences: ScreenRulerPreferences) -> CGFloat {
        switch axis {
        case .horizontal:
            switch preferences.horizontalOrigin {
            case .left:
                return value
            case .right:
                return length - value
            }
        case .vertical:
            switch preferences.verticalOrigin {
            case .top:
                return value
            case .bottom:
                return length - value
            }
        }
    }

    private func measurementValue(for point: CGPoint, size: CGSize, preferences: ScreenRulerPreferences) -> CGFloat {
        switch axis {
        case .horizontal:
            switch preferences.horizontalOrigin {
            case .left:
                return point.x
            case .right:
                return size.width - point.x
            }
        case .vertical:
            switch preferences.verticalOrigin {
            case .top:
                return point.y
            case .bottom:
                return size.height - point.y
            }
        }
    }

    private func labelPoint(for position: CGFloat, length: CGFloat, thickness: CGFloat) -> CGPoint {
        switch axis {
        case .horizontal:
            let x = min(max(position + horizontalLabelOffset(for: position, length: length), 18), max(18, length - 18))
            switch model.preferences.sanitized().horizontalTickEdge {
            case .top:
                return CGPoint(x: x, y: 18)
            case .bottom:
                return CGPoint(x: x, y: thickness - 18)
            }
        case .vertical:
            let y = min(max(position + verticalLabelOffset(for: position, length: length), 12), max(12, length - 12))
            switch model.preferences.sanitized().verticalTickEdge {
            case .left:
                return CGPoint(x: 26, y: y)
            case .right:
                return CGPoint(x: thickness - 26, y: y)
            }
        }
    }

    private func horizontalLabelOffset(for position: CGFloat, length: CGFloat) -> CGFloat {
        position > length / 2 ? -18 : 18
    }

    private func verticalLabelOffset(for position: CGFloat, length: CGFloat) -> CGFloat {
        position > length / 2 ? -12 : 12
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
    let onClick: () -> Void

    func makeNSView(context: Context) -> InteractionOverlayView {
        InteractionOverlayView(kind: kind, onMouseLocationChange: onMouseLocationChange, onClick: onClick)
    }

    func updateNSView(_ nsView: InteractionOverlayView, context: Context) {
        nsView.kind = kind
        nsView.onMouseLocationChange = onMouseLocationChange
        nsView.onClick = onClick
    }

    final class InteractionOverlayView: NSView {
        private enum Interaction {
            case move
            case right
            case bottom
        }

        private let clickMovementThreshold: CGFloat = 3
        var kind: ScreenRulerKind {
            didSet {
                needsDisplay = true
            }
        }
        var onMouseLocationChange: (CGPoint?) -> Void
        var onClick: () -> Void
        private var dragStartPoint: CGPoint?
        private var dragStartFrame: CGRect?
        private var dragStartTopY: CGFloat?
        private var dragStartBottomInset: CGFloat?
        private var activeInteraction: Interaction?
        private var didDrag = false
        private var trackingArea: NSTrackingArea?

        init(
            kind: ScreenRulerKind,
            onMouseLocationChange: @escaping (CGPoint?) -> Void,
            onClick: @escaping () -> Void
        ) {
            self.kind = kind
            self.onMouseLocationChange = onMouseLocationChange
            self.onClick = onClick
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
            let gripBounds = ScreenRulerResizeGripLayout.gripLineBounds(
                for: kind,
                in: bounds
            )

            switch kind {
            case .horizontal:
                for x in stride(from: gripBounds.minX, through: gripBounds.maxX, by: 6) {
                    path.move(to: CGPoint(x: x, y: gripBounds.minY))
                    path.line(to: CGPoint(x: x, y: gripBounds.maxY))
                }
            case .vertical:
                for y in stride(from: gripBounds.minY, through: gripBounds.maxY, by: 6) {
                    path.move(to: CGPoint(x: gripBounds.minX, y: y))
                    path.line(to: CGPoint(x: gripBounds.maxX, y: y))
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
            didDrag = false

            if isInResizeTarget(localPoint) {
                NSCursor.closedHand.set()
            }
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
            if abs(deltaX) > clickMovementThreshold || abs(deltaY) > clickMovementThreshold {
                didDrag = true
            }
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
            let shouldToggleTickEdge = activeInteraction != nil && !didDrag
            let localPoint = convert(event.locationInWindow, from: nil)
            dragStartPoint = nil
            dragStartFrame = nil
            dragStartTopY = nil
            dragStartBottomInset = nil
            activeInteraction = nil
            didDrag = false

            if shouldToggleTickEdge {
                onClick()
            }

            updateCursor(for: localPoint)
        }

        override func resetCursorRects() {
            let resizeTarget = ScreenRulerResizeGripLayout.resizeTargetRect(
                for: kind,
                in: bounds
            )

            switch kind {
            case .horizontal:
                addCursorRect(
                    CGRect(
                        x: bounds.minX,
                        y: bounds.minY,
                        width: max(0, resizeTarget.minX - bounds.minX),
                        height: bounds.height
                    ),
                    cursor: .openHand
                )
            case .vertical:
                addCursorRect(
                    CGRect(
                        x: bounds.minX,
                        y: resizeTarget.maxY,
                        width: bounds.width,
                        height: max(0, bounds.maxY - resizeTarget.maxY)
                    ),
                    cursor: .openHand
                )
            }

            addCursorRect(
                resizeTarget,
                cursor: .openHand
            )
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                removeTrackingArea(trackingArea)
            }

            let area = NSTrackingArea(
                rect: bounds,
                options: [
                    .activeAlways,
                    .inVisibleRect,
                    .mouseMoved,
                    .mouseEnteredAndExited,
                    .cursorUpdate
                ],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            let localPoint = convert(event.locationInWindow, from: nil)
            updateCursor(for: localPoint)
            onMouseLocationChange(localPoint)
        }

        override func mouseEntered(with event: NSEvent) {
            let localPoint = convert(event.locationInWindow, from: nil)
            updateCursor(for: localPoint)
            onMouseLocationChange(localPoint)
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
            onMouseLocationChange(nil)
        }

        override func cursorUpdate(with event: NSEvent) {
            updateCursor(for: convert(event.locationInWindow, from: nil))
        }

        private func interaction(at point: CGPoint) -> Interaction {
            switch kind {
            case .horizontal:
                if isInResizeTarget(point) {
                    return .right
                }
            case .vertical:
                if isInResizeTarget(point) {
                    return .bottom
                }
            }

            return .move
        }

        private func isInResizeTarget(_ point: CGPoint) -> Bool {
            ScreenRulerResizeGripLayout.resizeTargetRect(for: kind, in: bounds)
                .contains(point)
        }

        private func updateCursor(for point: CGPoint) {
            if isInControlStrip(point) {
                NSCursor.arrow.set()
            } else if isInResizeTarget(point) {
                (activeInteraction == nil ? NSCursor.openHand : NSCursor.closedHand)
                    .set()
            } else {
                NSCursor.openHand.set()
            }
        }

        private func isInControlStrip(_ point: CGPoint) -> Bool {
            ScreenRulerResizeGripLayout.controlExclusionRect(in: bounds)
                .contains(point)
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
