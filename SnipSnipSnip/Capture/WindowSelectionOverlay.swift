import AppKit
import CoreGraphics

nonisolated struct WindowSelectionPrompt {
    let instructionText: String
    let listButtonTitle: String?
    let windowLabel: @Sendable (CaptureWindowSummary) -> String
    let targetActionHelp: String

    init(instructionText: String, listButtonTitle: String?,
         windowLabel: @escaping @Sendable (CaptureWindowSummary) -> String,
         targetActionHelp: String = String(localized: "Press to capture this window.")) {
        self.instructionText = instructionText
        self.listButtonTitle = listButtonTitle
        self.windowLabel = windowLabel
        self.targetActionHelp = targetActionHelp
    }

    static let capture = WindowSelectionPrompt(
        instructionText: String(localized: "Hover a window, then click to capture. Esc cancels."),
        listButtonTitle: nil,
        windowLabel: \.displayTitle
    )

    static let video = WindowSelectionPrompt(
        instructionText: String(localized: "Hover a window, then click to record Video. Esc cancels."),
        listButtonTitle: nil,
        windowLabel: \.displayTitle,
        targetActionHelp: String(localized: "Press to record this window.")
    )
}

nonisolated enum WindowSelectionOutcome {
    case window(CaptureWindowSummary)
    case chooseFromList
    case cancelled
}

@MainActor
final class WindowSelectionSession: NSObject {
    private let snapshot: DesktopCompositeSnapshot
    private let windows: [CaptureWindowSummary]
    private let prompt: WindowSelectionPrompt
    private var continuation: CheckedContinuation<WindowSelectionOutcome, Never>?
    private var overlayWindows: [WindowSelectionWindow] = []
    private var hoveredWindowID: CGWindowID?
    private var transitionStartTime = CACurrentMediaTime()

    init(
        snapshot: DesktopCompositeSnapshot,
        windows: [CaptureWindowSummary],
        prompt: WindowSelectionPrompt = .capture
    ) {
        self.snapshot = snapshot
        self.windows = windows
        self.prompt = prompt
    }

    func begin() async -> CaptureWindowSummary? {
        let outcome = await beginOutcome()
        guard case .window(let window) = outcome else {
            return nil
        }
        return window
    }

    func beginOutcome() async -> WindowSelectionOutcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentOverlay()
        }
    }

    private func presentOverlay() {

        overlayWindows = snapshot.displayPreviews.compactMap { displayPreview in
            let displayWindows = CaptureWindowTargetResolver.windows(
                windows,
                intersecting: displayPreview.snapshot
            )
            
            let overlay = WindowSelectionWindow(
                displayPreview: displayPreview,
                windows: displayWindows,
                prompt: prompt,
                onHoverChange: { [weak self] window in self?.updateHover(window: window) },
                onMouseExit: { [weak self] in self?.refreshHoverAtPointer() }
            ) { [weak self] outcome in
                self?.finish(with: outcome)
            }

            overlay.orderFrontRegardless()
            return overlay
        }

        overlayWindows.first?.makeKeyAndOrderFront(nil)
        refreshHoverAtPointer()
    }

    private func refreshHoverAtPointer() {
        let pointer = NSEvent.mouseLocation
        if let overlay = overlayWindows.first(where: { $0.frame.contains(pointer) }) {
            overlay.refreshHover(at: pointer)
        } else {
            updateHover(window: nil)
        }
    }

    private func updateHover(window: CaptureWindowSummary?) {
        if hoveredWindowID != window?.id {
            hoveredWindowID = window?.id
            transitionStartTime = CACurrentMediaTime()
        }
        overlayWindows.forEach { $0.updateHover(window: window, transitionStartTime: transitionStartTime) }
    }

    private func finish(with outcome: WindowSelectionOutcome) {
        let continuation = continuation
        self.continuation = nil
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = []
        continuation?.resume(returning: outcome)
    }
}

private final class WindowSelectionWindow: NSPanel {
    private let displayFrame: CGRect
    
    init(
        displayPreview: DisplayPreview,
        windows: [CaptureWindowSummary],
        prompt: WindowSelectionPrompt,
        onHoverChange: @escaping (CaptureWindowSummary?) -> Void,
        onMouseExit: @escaping () -> Void,
        onComplete: @escaping (WindowSelectionOutcome) -> Void
    ) {
        self.displayFrame = displayPreview.snapshot.overlayFrame
        super.init(
            contentRect: displayPreview.snapshot.overlayFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllApplications,
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        ignoresMouseEvents = false
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        contentView = WindowSelectionView(
            displayPreview: displayPreview,
            windows: windows,
            displayFrame: displayFrame,
            prompt: prompt,
            onHoverChange: onHoverChange,
            onMouseExit: onMouseExit,
            onComplete: onComplete
        )
        makeFirstResponder(contentView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func refreshHover(at screenPoint: CGPoint) {
        (contentView as? WindowSelectionView)?.refreshHover(at: screenPoint)
    }

    func updateHover(window: CaptureWindowSummary?, transitionStartTime: CFTimeInterval) {
        (contentView as? WindowSelectionView)?.updateHover(window: window, transitionStartTime: transitionStartTime)
    }
}

private final class WindowSelectionView: NSView {
    private let windows: [CaptureWindowSummary]
    private let displayTransform: CaptureDisplayTransform
    private let displayFrame: CGRect
    private let prompt: WindowSelectionPrompt
    private let onComplete: (WindowSelectionOutcome) -> Void
    private let onHoverChange: (CaptureWindowSummary?) -> Void
    private let onMouseExit: () -> Void
    private var hoveredWindowID: CGWindowID?
    // Screen-space (AppKit) rect of the hovered window, refreshed each mouseMoved.
    private var hoveredScreenRect: CGRect?
    private var trackingAreaRef: NSTrackingArea?
    private let highlightView: CaptureSelectionWindowHighlightView

    init(
        displayPreview: DisplayPreview,
        windows: [CaptureWindowSummary],
        displayFrame: CGRect,
        prompt: WindowSelectionPrompt,
        onHoverChange: @escaping (CaptureWindowSummary?) -> Void,
        onMouseExit: @escaping () -> Void,
        onComplete: @escaping (WindowSelectionOutcome) -> Void
    ) {
        self.windows = windows
        self.displayTransform = displayPreview.snapshot.captureDisplayTransform
        self.prompt = prompt
        self.displayFrame = displayFrame
        self.onComplete = onComplete
        self.onHoverChange = onHoverChange
        self.onMouseExit = onMouseExit
        self.highlightView = CaptureSelectionWindowHighlightView(frame: CGRect(origin: .zero, size: displayPreview.snapshot.overlayFrame.size))
        super.init(frame: CGRect(origin: .zero, size: displayPreview.snapshot.overlayFrame.size))
        wantsLayer = true
        highlightView.autoresizingMask = [.width, .height]
        addSubview(highlightView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Window selection targets"))
        setAccessibilityHelp(String(localized: "Choose a visible window or open the list of available windows."))
        setAccessibilityIdentifier("capture.window.targets")
        if let listButtonTitle = prompt.listButtonTitle {
            let listButton = NSButton(
                title: listButtonTitle,
                target: self,
                action: #selector(chooseFromList)
            )
            listButton.bezelStyle = .rounded
            listButton.controlSize = .large
            listButton.translatesAutoresizingMaskIntoConstraints = false
            listButton.setAccessibilityHelp(String(localized: "Open a list of available windows."))
            addSubview(listButton)
            NSLayoutConstraint.activate([
                listButton.topAnchor.constraint(equalTo: topAnchor, constant: 20),
                listButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24)
            ])
        }
        refreshAccessibilityTargets(postNotification: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        let targetRect = hoveredScreenRect.map { viewLocalRect(fromScreenRect: $0) }
        CaptureSelectionAppearance.drawDimming(in: bounds, excluding: targetRect)
        var instructionBounds = bounds
        if prompt.listButtonTitle != nil { instructionBounds.size.width = max(0, bounds.width - 200) }
        CaptureSelectionAppearance.drawInstructions(prompt.instructionText, in: instructionBounds)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit()
    }

    override func mouseMoved(with event: NSEvent) {
        refreshHover(at: appKitScreenPoint(from: event))
    }

    func refreshHover(at screenPoint: CGPoint) {
        let resolved = resolveWindow(at: screenPoint)
        onHoverChange(resolved?.window)
    }

    override func mouseDown(with event: NSEvent) {
        let screenPoint = appKitScreenPoint(from: event)
        guard let selected = resolveWindow(at: screenPoint)?.window else {
            NSSound.beep()
            return
        }

        onComplete(.window(selected))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onComplete(.cancelled)
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func chooseFromList() {
        onComplete(.chooseFromList)
    }

    func updateHover(window: CaptureWindowSummary?, transitionStartTime: CFTimeInterval) {
        let selected = window.flatMap { target in windows.first { $0.id == target.id } }
        let screenRect = selected.map { displayTransform.overlayGlobalRect(fromCaptureGlobalRect: $0.frame) }
        guard hoveredWindowID != selected?.id || hoveredScreenRect != screenRect else { return }
        hoveredWindowID = selected?.id
        hoveredScreenRect = screenRect
        highlightView.refresh(
            windowID: selected?.id,
            rect: screenRect.map { viewLocalRect(fromScreenRect: $0) },
            label: selected.map { prompt.windowLabel($0) },
            transitionStartTime: transitionStartTime
        )
        needsDisplay = true
        refreshAccessibilityTargets(postNotification: true)
    }

    fileprivate func captureWindowForAccessibility(id: CGWindowID) -> Bool {
        guard let selected = windows.first(where: { $0.id == id }) else {
            return false
        }
        onComplete(.window(selected))
        return true
    }

    private func refreshAccessibilityTargets(postNotification: Bool) {
        let targets = windows.compactMap { candidate -> WindowCaptureAccessibilityElement? in
            let visibleRect = displayTransform.overlayGlobalRect(fromCaptureGlobalRect: candidate.frame)
                .intersection(displayFrame)
            guard !visibleRect.isNull, visibleRect.width > 0, visibleRect.height > 0 else {
                return nil
            }
            return WindowCaptureAccessibilityElement(
                target: self,
                window: candidate,
                frame: visibleRect,
                isSelected: candidate.id == hoveredWindowID,
                label: prompt.windowLabel(candidate),
                actionHelp: prompt.targetActionHelp
            )
        }
        setAccessibilityChildren(targets)
        if postNotification {
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
    }

    // Convert event position to AppKit global screen coords.
    // Ask AppKit for the actual window placement instead of assuming the overlay
    // landed exactly at displayFrame; Sidecar can shift borderless windows slightly.
    private func appKitScreenPoint(from event: NSEvent) -> CGPoint {
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? CGPoint(
            x: displayFrame.minX + event.locationInWindow.x,
            y: displayFrame.minY + event.locationInWindow.y
        )
        return screenPoint
    }

    // Convert an AppKit screen-space rect to flipped view-local coordinates.
    // Use the real NSWindow placement when available so drawing stays aligned with
    // hit-testing even if the system nudges the overlay window.
    private func viewLocalRect(fromScreenRect screenRect: CGRect) -> CGRect {
        if let window {
            let windowRect = window.convertFromScreen(screenRect)
            return convert(windowRect, from: nil).standardized
        }

        return AppKitOverlayTransform(overlayFrame: displayFrame)
            .localRect(fromGlobalRect: screenRect).standardized
    }

    private func resolveWindow(at screenPoint: CGPoint) -> (window: CaptureWindowSummary, screenRect: CGRect)? {
        guard let selected = CaptureWindowTargetResolver.resolve(
            atOverlayScreenPoint: screenPoint,
            in: windows,
            displayTransform: displayTransform
        ) else { return nil }
        return (selected, displayTransform.overlayGlobalRect(fromCaptureGlobalRect: selected.frame))
    }
}

nonisolated private final class WindowCaptureAccessibilityElement: NSAccessibilityElement {
    weak var target: WindowSelectionView?
    private let windowID: CGWindowID

    init(
        target: WindowSelectionView,
        window: CaptureWindowSummary,
        frame: CGRect,
        isSelected: Bool,
        label: String,
        actionHelp: String
    ) {
        self.target = target
        self.windowID = window.id
        super.init()
        setAccessibilityParent(target)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityValue(
            "\(Int(window.frame.width)) by \(Int(window.frame.height)) pixels"
        )
        setAccessibilitySelected(isSelected)
        setAccessibilityFrame(frame)
        setAccessibilityHelp(actionHelp)
        setAccessibilityIdentifier("capture.window.target.\(window.id)")
    }

    override func accessibilityPerformPress() -> Bool {
        let target = target
        let windowID = windowID
        return MainActor.assumeIsolated { [weak target] in
            target?.captureWindowForAccessibility(id: windowID) ?? false
        }
    }
}
