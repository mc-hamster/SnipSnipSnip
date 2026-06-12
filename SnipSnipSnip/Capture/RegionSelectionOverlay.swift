import AppKit
import CoreGraphics

@MainActor
final class RegionSelectionSession: NSObject {
    private let snapshot: DesktopCompositeSnapshot
    private let windows: [CaptureWindowSummary]
    private let preferences: RegionCapturePreferences
    private let initialSelectionRect: CGRect?
    private var continuation: CheckedContinuation<RegionCaptureSelection?, Never>?
    private var coordinator: RegionSelectionCoordinator?
    private var livePreviewSource: LiveDesktopPreviewSource?
    private var overlayWindows: [RegionSelectionWindow] = []
    private var cursorHidden = false
    private var localEventMonitor: Any?

    init(
        snapshot: DesktopCompositeSnapshot,
        windows: [CaptureWindowSummary] = [],
        preferences: RegionCapturePreferences,
        initialSelectionRect: CGRect? = nil
    ) {
        self.snapshot = snapshot
        self.windows = windows
        self.preferences = preferences
        self.initialSelectionRect = initialSelectionRect?.gscIntegralStandardized
    }

    func begin() async -> RegionCaptureSelection? {
        if preferences.overlayMode.showsMagnifyingGlass {
            let livePreviewSource = LiveDesktopPreviewSource(displays: snapshot.displays)
            do {
                try await livePreviewSource.start()
                self.livePreviewSource = livePreviewSource
            } catch {
                self.livePreviewSource = nil
            }
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentOverlay()
        }
    }

    private func presentOverlay() {
        NSApp.activate(ignoringOtherApps: true)

        let coordinator = RegionSelectionCoordinator(
            snapshot: snapshot,
            windows: windows,
            preferences: preferences,
            initialSelectionRect: initialSelectionRect,
            onCaptureCursorHiddenChange: { [weak self] shouldHideCursor in
                self?.setCaptureCursorHidden(shouldHideCursor)
            },
            onComplete: { [weak self] selection in
                self?.finish(with: selection)
            }
        )
        self.coordinator = coordinator

        overlayWindows = snapshot.displayPreviews.map { displayPreview in
            let overlay = RegionSelectionWindow(
                displayPreview: displayPreview,
                coordinator: coordinator,
                livePreviewSource: livePreviewSource
            )
            overlay.orderFrontRegardless()
            return overlay
        }

        overlayWindows.first?.makeKeyAndOrderFront(nil)
        installEventMonitor(for: coordinator)

        setCaptureCursorHidden(true)

        coordinator.mouseMoved(to: NSEvent.mouseLocation, eventTimestamp: nil)
    }

    private func setCaptureCursorHidden(_ hidden: Bool) {
        guard cursorHidden != hidden else {
            return
        }

        if hidden {
            NSCursor.hide()
        } else {
            NSCursor.unhide()
        }

        cursorHidden = hidden
    }

    private func finish(with selection: RegionCaptureSelection?) {
        let continuation = continuation
        self.continuation = nil
        setCaptureCursorHidden(false)
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        coordinator?.finish()
        coordinator = nil
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = []
        let livePreviewSource = self.livePreviewSource
        self.livePreviewSource = nil
        Task {
            await livePreviewSource?.stop()
        }
        continuation?.resume(returning: selection)
    }

    private func installEventMonitor(for coordinator: RegionSelectionCoordinator) {
        guard localEventMonitor == nil else {
            return
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self, weak coordinator] event in
            guard let self, let coordinator else {
                return event
            }

            switch event.type {
            case .keyDown:
                if event.window?.firstResponder is NSTextView {
                    if event.keyCode == 53 {
                        coordinator.keyDown(with: event)
                        return nil
                    }
                    return event
                }
                // Handle key events directly in the monitor so Esc/Enter work even when
                // focus hasn't settled on the overlay window's first responder yet.
                coordinator.keyDown(with: event)
                return nil
            default:
                break
            }

            if self.eventTargetsInteractiveOverlayControl(event) {
                return event
            }

            let point = self.globalPoint(for: event)

            switch event.type {
            case .mouseMoved:
                coordinator.mouseMoved(to: point, eventTimestamp: event.timestamp)
            case .leftMouseDown:
                coordinator.mouseDown(at: point, in: event.window, eventTimestamp: event.timestamp)
            case .leftMouseDragged:
                coordinator.mouseDragged(to: point, eventTimestamp: event.timestamp)
            case .leftMouseUp:
                coordinator.mouseUp(at: point, eventTimestamp: event.timestamp)
            default:
                break
            }

            return event
        }
    }

    private func eventTargetsInteractiveOverlayControl(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            break
        default:
            return false
        }

        guard let contentView = event.window?.contentView else {
            return false
        }

        let localPoint = contentView.convert(event.locationInWindow, from: nil)
        var hitView = contentView.hitTest(localPoint)

        while let currentView = hitView {
            if currentView is NSControl || currentView is NSTextView {
                return true
            }

            hitView = currentView.superview
        }

        return false
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        let screenPoint: CGPoint

        if let window = event.window {
            screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPoint = NSEvent.mouseLocation
        }

        if let display = snapshot.displayPreviews.first(where: {
            $0.snapshot.overlayFrame.insetBy(dx: -1, dy: -1).contains(screenPoint)
        })?.snapshot {
            return captureGlobalPoint(fromOverlayGlobalPoint: screenPoint, on: display)
        }

        return screenPoint
    }
}

private final class RegionSelectionWindow: NSWindow {
    init(displayPreview: DisplayPreview, coordinator: RegionSelectionCoordinator, livePreviewSource: LiveDesktopPreviewSource?) {
        super.init(
            contentRect: displayPreview.snapshot.overlayFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        contentView = RegionSelectionView(
            displayPreview: displayPreview,
            coordinator: coordinator,
            livePreviewSource: livePreviewSource
        )
        makeFirstResponder(contentView)
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

@MainActor
private final class RegionSelectionCoordinator {
    private enum DragMode {
        case creating(anchor: CGPoint)
        case moving(anchor: CGPoint, original: CGRect)
        case resizing(handle: ResizeHandle, original: CGRect)
    }

    private struct WeakView {
        weak var view: RegionSelectionView?
    }

    private let snapshot: DesktopCompositeSnapshot
    private let windows: [CaptureWindowSummary]
    let preferences: RegionCapturePreferences
    private let onCaptureCursorHiddenChange: (Bool) -> Void
    private let onComplete: (RegionCaptureSelection?) -> Void
    private let clickToDragThreshold: CGFloat = 4
    private var views: [WeakView] = []
    private var dragMode: DragMode?
    private var mouseDownGlobalPoint: CGPoint?
    private var actionControlsDisplayID: CGDirectDisplayID?
    private var actionControlsGlobalPoint: CGPoint?
    private var lastCursorGlobalPointInSelection: CGPoint?
    private var lastProcessedEventSignature: ProcessedEventSignature?
    private var lockedAspectRatio: CGFloat?

    private(set) var selectionRect: CGRect?
    private(set) var cursorGlobalPoint: CGPoint?
    private(set) var activeDisplayID: CGDirectDisplayID?

    private struct ProcessedEventSignature: Equatable {
        let kind: String
        let timestamp: TimeInterval
    }

    init(
        snapshot: DesktopCompositeSnapshot,
        windows: [CaptureWindowSummary],
        preferences: RegionCapturePreferences,
        initialSelectionRect: CGRect? = nil,
        onCaptureCursorHiddenChange: @escaping (Bool) -> Void,
        onComplete: @escaping (RegionCaptureSelection?) -> Void
    ) {
        self.snapshot = snapshot
        self.windows = windows
        self.preferences = preferences
        self.onCaptureCursorHiddenChange = onCaptureCursorHiddenChange
        self.onComplete = onComplete

        if let initialSelectionRect {
            let normalizedSelection = initialSelectionRect
                .gscIntegralStandardized
                .gscClamped(to: snapshot.globalFrame)

            if normalizedSelection.width > 2, normalizedSelection.height > 2 {
                self.selectionRect = normalizedSelection
                let controlsDisplay = displayPreviewForControls(
                    near: CGPoint(x: normalizedSelection.midX, y: normalizedSelection.midY),
                    selectionRect: normalizedSelection
                )
                actionControlsDisplayID = controlsDisplay?.snapshot.displayID
                actionControlsGlobalPoint = clampedActionPoint(
                    CGPoint(x: normalizedSelection.maxX, y: normalizedSelection.maxY),
                    in: controlsDisplay?.snapshot.frame
                )
            }
        }
    }

    func register(_ view: RegionSelectionView) {
        views.append(WeakView(view: view))
    }

    func finish() {
        views.removeAll()
    }

    func shouldShowActionControls(on displayID: CGDirectDisplayID) -> Bool {
        preferences.showsRegionConfirmationControls && actionControlsDisplayID == displayID && selectionRect != nil
    }

    var isActivelyDraggingSelection: Bool {
        dragMode != nil
    }

    var showsCaptureAimingUI: Bool {
        !isAdjustingPrecisionSelection
    }

    var isAspectRatioLocked: Bool {
        lockedAspectRatio != nil
    }

    private var isAdjustingPrecisionSelection: Bool {
        guard preferences.advancedControlsEnabled, selectionRect != nil else {
            return false
        }

        if case .creating = dragMode {
            return false
        }

        return true
    }

    func actionControlsPoint(for display: DisplaySnapshot) -> CGPoint? {
        guard let actionControlsGlobalPoint else {
            return nil
        }

        return display.captureDisplayTransform.overlayLocalPoint(fromCaptureGlobalPoint: actionControlsGlobalPoint)
    }

    func mouseMoved(to point: CGPoint, eventTimestamp: TimeInterval?) {
        guard shouldProcessEvent(kind: "mouseMoved", timestamp: eventTimestamp) else {
            return
        }
        cursorGlobalPoint = point
        activeDisplayID = displayID(containing: point)
        rememberCursorLocationIfInsideSelection(point)
        notifyViews()
    }

    func mouseDown(at point: CGPoint, in window: NSWindow?, eventTimestamp: TimeInterval?) {
        guard shouldProcessEvent(kind: "mouseDown", timestamp: eventTimestamp) else {
            return
        }
        window?.makeKeyAndOrderFront(nil)
        cursorGlobalPoint = point
        activeDisplayID = displayID(containing: point)
        rememberCursorLocationIfInsideSelection(point)
        mouseDownGlobalPoint = point
        actionControlsDisplayID = nil
        actionControlsGlobalPoint = nil

        if let selectionRect, let handle = handle(at: point, in: selectionRect) {
            dragMode = .resizing(handle: handle, original: selectionRect)
            notifyViews()
            return
        }

        if let selectionRect, selectionRect.insetBy(dx: -6, dy: -6).contains(point) {
            dragMode = .moving(anchor: point, original: selectionRect)
            notifyViews()
            return
        }

        selectionRect = nil
        lastCursorGlobalPointInSelection = nil
        lockedAspectRatio = nil
        dragMode = nil
        notifyViews()
    }

    func mouseDragged(to point: CGPoint, eventTimestamp: TimeInterval?) {
        guard shouldProcessEvent(kind: "mouseDragged", timestamp: eventTimestamp) else {
            return
        }
        cursorGlobalPoint = point
        activeDisplayID = displayID(containing: point)
        rememberCursorLocationIfInsideSelection(point)

        if dragMode == nil, let mouseDownGlobalPoint {
            let deltaX = point.x - mouseDownGlobalPoint.x
            let deltaY = point.y - mouseDownGlobalPoint.y

            if hypot(deltaX, deltaY) >= clickToDragThreshold {
                selectionRect = CGRect(origin: mouseDownGlobalPoint, size: .zero)
                dragMode = .creating(anchor: mouseDownGlobalPoint)
            }
        }

        switch dragMode {
        case let .creating(anchor):
            selectionRect = CGRect(
                x: min(anchor.x, point.x),
                y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x),
                height: abs(point.y - anchor.y)
            ).gscClamped(to: snapshot.globalFrame)
        case let .moving(anchor, original):
            let delta = CGSize(width: point.x - anchor.x, height: point.y - anchor.y)
            selectionRect = original.offsetBy(dx: delta.width, dy: delta.height).gscClamped(to: snapshot.globalFrame)
        case let .resizing(handle, original):
            selectionRect = RegionPrecisionGeometry.resizedRect(
                original,
                handle: handle,
                point: point,
                aspectRatio: lockedAspectRatio,
                within: snapshot.globalFrame
            )
        case .none:
            break
        }

        notifyViews()
    }

    func mouseUp(at point: CGPoint, eventTimestamp: TimeInterval?) {
        guard shouldProcessEvent(kind: "mouseUp", timestamp: eventTimestamp) else {
            return
        }
        cursorGlobalPoint = point
        activeDisplayID = displayID(containing: point)
        let completedDragMode = dragMode
        dragMode = nil
        mouseDownGlobalPoint = nil

        switch completedDragMode {
        case .creating, .moving, .resizing:
            guard let selectionRect, selectionRect.width > 2, selectionRect.height > 2 else {
                self.selectionRect = nil
                actionControlsDisplayID = nil
                actionControlsGlobalPoint = nil
                lastCursorGlobalPointInSelection = nil
                lockedAspectRatio = nil
                notifyViews()
                return
            }

            let normalizedSelection = selectionRect.gscIntegralStandardized

            if preferences.autoCapturesOnMouseUp {
                onComplete(.region(normalizedSelection, cursorCaptureGlobalLocation: point))
                return
            }

            self.selectionRect = normalizedSelection
            rememberCursorLocationIfInsideSelection(point)
            let controlsDisplay = displayPreviewForControls(near: point, selectionRect: normalizedSelection)
            actionControlsDisplayID = controlsDisplay?.snapshot.displayID
            actionControlsGlobalPoint = clampedActionPoint(point, in: controlsDisplay?.snapshot.frame)
        case .none:
            actionControlsDisplayID = nil
            actionControlsGlobalPoint = nil
            if let clickedWindow = gscTopmostWindow(at: point, in: windows) {
                onComplete(.window(clickedWindow))
                return
            }
        }

        notifyViews()
    }

    func keyDown(with event: NSEvent) {
        if preferences.advancedControlsEnabled, handlePrecisionKeyDown(event) {
            return
        }

        switch event.keyCode {
        case 36, 76:
            confirmRegionCapture()
        case 53:
            if selectionRect != nil {
                cancelSelection()
            } else {
                onComplete(nil)
            }
        default:
            break
        }
    }

    func confirmRegionCapture() {
        guard let selectionRect, selectionRect.width > 2, selectionRect.height > 2 else {
            NSSound.beep()
            return
        }

        onComplete(.region(
            selectionRect.gscIntegralStandardized,
            cursorCaptureGlobalLocation: lastCursorGlobalPointInSelection
        ))
    }

    func cancelSelection() {
        selectionRect = nil
        actionControlsDisplayID = nil
        actionControlsGlobalPoint = nil
        lastCursorGlobalPointInSelection = nil
        lockedAspectRatio = nil
        notifyViews()
    }

    func setSelectionSize(width: CGFloat?, height: CGFloat?) {
        guard let selectionRect else {
            NSSound.beep()
            return
        }

        self.selectionRect = RegionPrecisionGeometry.rectBySettingSize(
            selectionRect,
            width: width,
            height: height,
            lockedAspectRatio: lockedAspectRatio,
            within: snapshot.globalFrame
        )
        if lockedAspectRatio != nil, let updatedRect = self.selectionRect, updatedRect.height > 0 {
            lockedAspectRatio = updatedRect.width / updatedRect.height
        }
        notifyViews()
    }

    func setAspectRatioLocked(_ isLocked: Bool) {
        if isLocked,
           let selectionRect,
           selectionRect.width > 0,
           selectionRect.height > 0 {
            lockedAspectRatio = selectionRect.width / selectionRect.height
        } else {
            lockedAspectRatio = nil
        }

        notifyViews()
    }

    private func rememberCursorLocationIfInsideSelection(_ point: CGPoint) {
        guard selectionRect?.contains(point) == true else {
            return
        }

        lastCursorGlobalPointInSelection = point
    }

    private func handlePrecisionKeyDown(_ event: NSEvent) -> Bool {
        guard selectionRect != nil else {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
        let delta: CGSize

        switch event.keyCode {
        case 123:
            delta = CGSize(width: -step, height: 0)
        case 124:
            delta = CGSize(width: step, height: 0)
        case 125:
            delta = CGSize(width: 0, height: step)
        case 126:
            delta = CGSize(width: 0, height: -step)
        default:
            return false
        }

        selectionRect = RegionPrecisionGeometry.nudgedRect(selectionRect ?? .null, by: delta, within: snapshot.globalFrame)
        notifyViews()
        return true
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> ResizeHandle? {
        ResizeHandle.allCases.first { handle in
            let location = handle.position(in: rect)
            return CGRect(x: location.x - 8, y: location.y - 8, width: 16, height: 16).contains(point)
        }
    }

    private func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
        snapshot.displayPreviews.first(where: { $0.snapshot.frame.contains(point) })?.snapshot.displayID
    }

    private func displayPreviewForControls(near point: CGPoint, selectionRect: CGRect) -> DisplayPreview? {
        if let display = snapshot.displayPreviews.first(where: { $0.snapshot.frame.contains(point) }) {
            return display
        }

        return snapshot.displayPreviews
            .filter { $0.snapshot.frame.intersects(selectionRect) }
            .max { left, right in
                left.snapshot.frame.intersection(selectionRect).area < right.snapshot.frame.intersection(selectionRect).area
            }
    }

    private func clampedActionPoint(_ point: CGPoint, in displayFrame: CGRect?) -> CGPoint? {
        guard let displayFrame else {
            return nil
        }

        return CGPoint(
            x: min(max(point.x, displayFrame.minX + 12), displayFrame.maxX - 12),
            y: min(max(point.y, displayFrame.minY + 12), displayFrame.maxY - 12)
        )
    }

    private func notifyViews() {
        onCaptureCursorHiddenChange(showsCaptureAimingUI)
        views.removeAll { $0.view == nil }
        views.forEach { $0.view?.refreshSelectionState() }
    }

    private func shouldProcessEvent(kind: String, timestamp: TimeInterval?) -> Bool {
        guard let timestamp else {
            return true
        }

        let signature = ProcessedEventSignature(kind: kind, timestamp: timestamp)
        if lastProcessedEventSignature == signature {
            return false
        }

        lastProcessedEventSignature = signature
        return true
    }
}

private final class RegionSelectionView: NSView, NSTextFieldDelegate {
    private let displayPreview: DisplayPreview
    private let coordinator: RegionSelectionCoordinator
    private let canvasView: RegionSelectionCanvasView
    private let crosshairOverlayView: RegionSelectionCrosshairOverlayView?
    private let cursorOverlayView: RegionSelectionCursorOverlayView
    private var trackingAreaRef: NSTrackingArea?
    private let widthField = NSTextField()
    private let dimensionSeparatorLabel = NSTextField(labelWithString: "x")
    private let heightField = NSTextField()
    private let aspectLockButton = NSButton(checkboxWithTitle: "Lock Ratio", target: nil, action: nil)
    private let captureButton = NSButton(title: "Capture", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var lastSelectionRect: CGRect?
    private var lastShowsActionControls = false
    private var lastActionControlsVisible = false
    private var lastAspectRatioLocked = false

    init(displayPreview: DisplayPreview, coordinator: RegionSelectionCoordinator, livePreviewSource: LiveDesktopPreviewSource?) {
        self.displayPreview = displayPreview
        self.coordinator = coordinator
        self.canvasView = RegionSelectionCanvasView(displayPreview: displayPreview)
        self.crosshairOverlayView = coordinator.preferences.overlayMode.showsCrosshair
            ? RegionSelectionCrosshairOverlayView(displayPreview: displayPreview)
            : nil
        self.cursorOverlayView = RegionSelectionCursorOverlayView(
            displayPreview: displayPreview,
            fallbackImage: displayPreview.image,
            livePreviewSource: livePreviewSource,
            overlayMode: coordinator.preferences.overlayMode
        )
        super.init(frame: CGRect(origin: .zero, size: displayPreview.snapshot.overlayFrame.size))
        wantsLayer = true
        configureDynamicViews()
        configureButtons()
        coordinator.register(self)
        refreshSelectionState()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator.mouseMoved(to: globalPoint(for: event), eventTimestamp: event.timestamp)
    }

    override func mouseDown(with event: NSEvent) {
        guard !eventTargetsInteractiveControl(event) else {
            super.mouseDown(with: event)
            return
        }

        coordinator.mouseDown(at: globalPoint(for: event), in: window, eventTimestamp: event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !eventTargetsInteractiveControl(event) else {
            super.mouseDragged(with: event)
            return
        }

        coordinator.mouseDragged(to: globalPoint(for: event), eventTimestamp: event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        guard !eventTargetsInteractiveControl(event) else {
            super.mouseUp(with: event)
            return
        }

        coordinator.mouseUp(at: globalPoint(for: event), eventTimestamp: event.timestamp)
    }

    override func keyDown(with event: NSEvent) {
        coordinator.keyDown(with: event)
    }

    func refreshSelectionState() {
        let selectionRect = coordinator.selectionRect
        let showsActionControls = coordinator.shouldShowActionControls(on: displayPreview.snapshot.displayID)
        let isActivelyDraggingSelection = coordinator.isActivelyDraggingSelection

        if selectionRect != lastSelectionRect ||
            showsActionControls != lastShowsActionControls ||
            coordinator.isAspectRatioLocked != lastAspectRatioLocked {
            updateActionButtons()
            let actionControlsVisible = showsActionControls && !captureButton.isHidden
            canvasView.refresh(
                selectionRect: selectionRect,
                showsActionControls: showsActionControls,
                actionControlsVisible: actionControlsVisible,
                isActivelyDraggingSelection: isActivelyDraggingSelection
            )

            lastSelectionRect = selectionRect
            lastShowsActionControls = showsActionControls
            lastActionControlsVisible = actionControlsVisible
            lastAspectRatioLocked = coordinator.isAspectRatioLocked
        }

        let captureAimingCursorPoint = coordinator.showsCaptureAimingUI
            ? coordinator.cursorGlobalPoint
            : nil
        crosshairOverlayView?.refresh(
            cursorGlobalPoint: captureAimingCursorPoint,
            isActivelyDraggingSelection: isActivelyDraggingSelection
        )
        cursorOverlayView.refresh(
            cursorGlobalPoint: captureAimingCursorPoint,
            selectionRect: selectionRect,
            isActivelyDraggingSelection: isActivelyDraggingSelection
        )
    }

    private func configureButtons() {
        configureDimensionField(widthField)
        configureDimensionField(heightField)
        dimensionSeparatorLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        dimensionSeparatorLabel.textColor = .white
        dimensionSeparatorLabel.alignment = .center
        dimensionSeparatorLabel.isHidden = true
        addSubview(dimensionSeparatorLabel)

        aspectLockButton.target = self
        aspectLockButton.action = #selector(toggleAspectRatioLock)
        aspectLockButton.controlSize = .small
        aspectLockButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        aspectLockButton.isHidden = true
        addSubview(aspectLockButton)

        captureButton.target = self
        captureButton.action = #selector(confirmRegionCapture)
        captureButton.bezelStyle = .rounded
        captureButton.controlSize = .regular
        captureButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        captureButton.isHidden = true
        addSubview(captureButton)

        cancelButton.target = self
        cancelButton.action = #selector(cancelSelection)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular
        cancelButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        cancelButton.isHidden = true
        addSubview(cancelButton)
    }

    private func configureDimensionField(_ field: NSTextField) {
        field.delegate = self
        field.target = self
        field.action = #selector(applyPrecisionSizeFromFields)
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.placeholderString = "px"
        field.isHidden = true
        addSubview(field)
    }

    private func configureDynamicViews() {
        canvasView.frame = bounds
        canvasView.autoresizingMask = [.width, .height]
        addSubview(canvasView)

        if let crosshairOverlayView {
            crosshairOverlayView.frame = bounds
            crosshairOverlayView.autoresizingMask = [.width, .height]
            addSubview(crosshairOverlayView)
        }

        cursorOverlayView.frame = bounds
        cursorOverlayView.autoresizingMask = [.width, .height]
        addSubview(cursorOverlayView)
    }

    private func updateActionButtons() {
        guard coordinator.preferences.showsRegionConfirmationControls,
              coordinator.shouldShowActionControls(on: displayPreview.snapshot.displayID),
              let localPoint = coordinator.actionControlsPoint(for: displayPreview.snapshot) else {
            widthField.isHidden = true
            dimensionSeparatorLabel.isHidden = true
            heightField.isHidden = true
            aspectLockButton.isHidden = true
            captureButton.isHidden = true
            cancelButton.isHidden = true
            return
        }

        placeActionButtons(below: localPoint)
        updatePrecisionControls(above: captureButton.frame.minY)
    }

    private func placeActionButtons(below localPoint: CGPoint) {
        let buttonHeight: CGFloat = 30
        let captureSize = captureButton.sizeThatFits(CGSize(width: 160, height: buttonHeight))
        let cancelSize = cancelButton.sizeThatFits(CGSize(width: 160, height: buttonHeight))
        let spacing: CGFloat = 8
        let totalWidth = captureSize.width + cancelSize.width + spacing
        let x = min(max(localPoint.x - (totalWidth / 2), 12), bounds.width - totalWidth - 12)
        let y = min(localPoint.y + 8, bounds.height - buttonHeight - 12)

        captureButton.frame = CGRect(x: x, y: y, width: captureSize.width, height: buttonHeight)
        cancelButton.frame = CGRect(x: captureButton.frame.maxX + spacing, y: y, width: cancelSize.width, height: buttonHeight)
        captureButton.isHidden = false
        cancelButton.isHidden = false
    }

    private func updatePrecisionControls(above buttonY: CGFloat) {
        guard coordinator.preferences.advancedControlsEnabled,
              let selectionRect = coordinator.selectionRect else {
            widthField.isHidden = true
            dimensionSeparatorLabel.isHidden = true
            heightField.isHidden = true
            aspectLockButton.isHidden = true
            return
        }

        if widthField.currentEditor() == nil {
            widthField.stringValue = "\(Int(selectionRect.width.rounded()))"
        }
        if heightField.currentEditor() == nil {
            heightField.stringValue = "\(Int(selectionRect.height.rounded()))"
        }

        aspectLockButton.state = coordinator.isAspectRatioLocked ? .on : .off

        let fieldWidth: CGFloat = 72
        let fieldHeight: CGFloat = 24
        let spacerWidth: CGFloat = 18
        let lockSize = aspectLockButton.sizeThatFits(CGSize(width: 120, height: fieldHeight))
        let totalWidth = fieldWidth + spacerWidth + fieldWidth + 10 + lockSize.width
        let x = min(max(captureButton.frame.minX, 12), bounds.width - totalWidth - 12)
        let y = max(buttonY - fieldHeight - 8, 12)

        widthField.frame = CGRect(x: x, y: y, width: fieldWidth, height: fieldHeight)
        dimensionSeparatorLabel.frame = CGRect(x: widthField.frame.maxX, y: y + 3, width: spacerWidth, height: fieldHeight - 6)
        heightField.frame = CGRect(x: widthField.frame.maxX + spacerWidth, y: y, width: fieldWidth, height: fieldHeight)
        aspectLockButton.frame = CGRect(x: heightField.frame.maxX + 10, y: y + 1, width: lockSize.width, height: fieldHeight)

        widthField.isHidden = false
        dimensionSeparatorLabel.isHidden = false
        heightField.isHidden = false
        aspectLockButton.isHidden = false
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        let localPoint = convert(event.locationInWindow, from: nil)
        return displayPreview.snapshot.captureDisplayTransform.captureGlobalPoint(fromOverlayLocalPoint: localPoint)
    }

    private func eventTargetsInteractiveControl(_ event: NSEvent) -> Bool {
        let localPoint = convert(event.locationInWindow, from: nil)
        var hitView = hitTest(localPoint)

        while let currentView = hitView {
            if currentView is NSControl || currentView is NSTextView {
                return true
            }

            hitView = currentView.superview
        }

        return false
    }

    @objc
    private func confirmRegionCapture() {
        coordinator.confirmRegionCapture()
    }

    @objc
    private func cancelSelection() {
        coordinator.cancelSelection()
    }

    @objc
    private func applyPrecisionSizeFromFields() {
        applyPrecisionSizeFromFieldsChanged(changedField: nil)
    }

    private func applyPrecisionSizeFromFieldsChanged(changedField: NSTextField?) {
        let width = Double(widthField.stringValue).map { CGFloat($0) }
        let height = Double(heightField.stringValue).map { CGFloat($0) }

        if coordinator.isAspectRatioLocked {
            if changedField === widthField {
                coordinator.setSelectionSize(width: width, height: nil)
                return
            }

            if changedField === heightField {
                coordinator.setSelectionSize(width: nil, height: height)
                return
            }
        }

        coordinator.setSelectionSize(width: width, height: height)
    }

    @objc
    private func toggleAspectRatioLock() {
        coordinator.setAspectRatioLocked(aspectLockButton.state == .on)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        applyPrecisionSizeFromFieldsChanged(changedField: obj.object as? NSTextField)
    }
}

private final class RegionSelectionCanvasView: RegionSelectionPassThroughView {
    private let displayPreview: DisplayPreview
    private var selectionRect: CGRect?
    private var showsActionControls = false
    private var actionControlsVisible = false
    private var isActivelyDraggingSelection = false

    init(displayPreview: DisplayPreview) {
        self.displayPreview = displayPreview
        super.init(frame: CGRect(origin: .zero, size: displayPreview.snapshot.overlayFrame.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    func refresh(selectionRect: CGRect?, showsActionControls: Bool, actionControlsVisible: Bool, isActivelyDraggingSelection: Bool) {
        let previousSelectionRect = self.selectionRect
        let previousShowsActionControls = self.showsActionControls
        let previousActionControlsVisible = self.actionControlsVisible
        let previousIsActivelyDraggingSelection = self.isActivelyDraggingSelection

        self.selectionRect = selectionRect
        self.showsActionControls = showsActionControls
        self.actionControlsVisible = actionControlsVisible
        self.isActivelyDraggingSelection = isActivelyDraggingSelection

        invalidateSelectionOverlay(
            previousSelectionRect: previousSelectionRect,
            currentSelectionRect: selectionRect,
            previousShowsActionControls: previousShowsActionControls,
            currentShowsActionControls: showsActionControls,
            previousActionControlsVisible: previousActionControlsVisible,
            currentActionControlsVisible: actionControlsVisible,
            previousIsActivelyDraggingSelection: previousIsActivelyDraggingSelection,
            currentIsActivelyDraggingSelection: isActivelyDraggingSelection
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)

        let dimPath = NSBezierPath(rect: bounds)

        if let selectionRect {
            let displayFrame = displayPreview.snapshot.frame
            let visibleSelection = selectionRect.intersection(displayFrame).gscIntegralStandardized

            if visibleSelection.width > 0, visibleSelection.height > 0 {
                let localSelection = overlayLocalRect(fromCaptureGlobalRect: visibleSelection, display: displayPreview.snapshot)
                dimPath.append(NSBezierPath(rect: localSelection))
                dimPath.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.42).setFill()
                dimPath.fill()

                NSColor.white.setStroke()
                let border = NSBezierPath(rect: localSelection)
                border.lineWidth = 2
                border.stroke()

                if isActivelyDraggingSelection {
                    drawActiveSelectionDimensions(selectionRect, localSelection: localSelection)
                } else {
                    drawHandles(for: selectionRect)
                }

                if showsActionControls && !isActivelyDraggingSelection {
                    let info = NSString(string: actionControlsVisible ? "Click Capture or press Return • Esc cancels" : "Release to place Capture controls • Esc cancels")
                    let infoRect = CGRect(x: localSelection.minX, y: max(localSelection.minY - 28, 16), width: 220, height: 20)
                    info.draw(in: infoRect, withAttributes: [
                        .foregroundColor: NSColor.white,
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium)
                    ])
                }
            } else {
                NSColor.black.withAlphaComponent(0.42).setFill()
                dimPath.fill()
            }
        } else {
            NSColor.black.withAlphaComponent(0.42).setFill()
            dimPath.fill()
            let info = NSString(string: showsActionControls ? "Drag to select a region. Click Capture or press Return when ready. Esc cancels." : "Drag to select a region. Release captures. Esc cancels.")
            let infoRect = CGRect(x: 24, y: 24, width: 520, height: 22)
            info.draw(in: infoRect, withAttributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold)
            ])
        }

    }

    private func drawHandles(for selectionRect: CGRect) {
        NSColor.white.setFill()
        let displayHitFrame = displayPreview.snapshot.frame.insetBy(dx: -8, dy: -8)

        for handle in ResizeHandle.allCases {
            let globalLocation = handle.position(in: selectionRect)

            guard displayHitFrame.contains(globalLocation) else {
                continue
            }

            let localLocation = overlayLocalPoint(fromCaptureGlobalPoint: globalLocation, display: displayPreview.snapshot)
            CGRect(x: localLocation.x - 4, y: localLocation.y - 4, width: 8, height: 8).fill()
        }
    }

    private func drawActiveSelectionDimensions(_ selectionRect: CGRect, localSelection: CGRect) {
        let dimensions = NSString(
            string: "\(Int(selectionRect.width.rounded())) × \(Int(selectionRect.height.rounded()))"
        )
        let labelRect = CGRect(
            x: localSelection.minX,
            y: max(localSelection.minY - 28, 16),
            width: 132,
            height: 18
        )

        NSColor.black.withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: labelRect.insetBy(dx: -6, dy: -3), xRadius: 8, yRadius: 8).fill()
        dimensions.draw(
            in: labelRect,
            withAttributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            ]
        )
    }

    private func invalidateSelectionOverlay(
        previousSelectionRect: CGRect?,
        currentSelectionRect: CGRect?,
        previousShowsActionControls: Bool,
        currentShowsActionControls: Bool,
        previousActionControlsVisible: Bool,
        currentActionControlsVisible: Bool,
        previousIsActivelyDraggingSelection: Bool,
        currentIsActivelyDraggingSelection: Bool
    ) {
        var dirtyRects: [CGRect] = []
        dirtyRects.append(dirtyRectForSelection(previousSelectionRect, showsActionControls: previousShowsActionControls))
        dirtyRects.append(dirtyRectForSelection(currentSelectionRect, showsActionControls: currentShowsActionControls))

        if (previousSelectionRect == nil) != (currentSelectionRect == nil) ||
            previousShowsActionControls != currentShowsActionControls ||
            previousActionControlsVisible != currentActionControlsVisible ||
            previousIsActivelyDraggingSelection != currentIsActivelyDraggingSelection {
            dirtyRects.append(instructionsDirtyRect())
        }

        for rect in dirtyRects {
            let clippedRect = rect.intersection(bounds)

            guard !clippedRect.isNull, !clippedRect.isEmpty else {
                continue
            }

            setNeedsDisplay(clippedRect)
        }
    }

    private func dirtyRectForSelection(_ globalRect: CGRect?, showsActionControls: Bool) -> CGRect {
        guard let globalRect else {
            return .null
        }

        let displayFrame = displayPreview.snapshot.frame
        let visibleSelection = globalRect.intersection(displayFrame).gscIntegralStandardized

        guard visibleSelection.width > 0, visibleSelection.height > 0 else {
            return .null
        }

        var dirtyRect = overlayLocalRect(fromCaptureGlobalRect: visibleSelection, display: displayPreview.snapshot).insetBy(dx: -16, dy: -40)

        if showsActionControls {
            dirtyRect = dirtyRect.union(bounds)
        }

        return dirtyRect
    }

    private func instructionsDirtyRect() -> CGRect {
        CGRect(x: 16, y: 16, width: 560, height: 36)
    }

}

private final class RegionSelectionCrosshairOverlayView: RegionSelectionPassThroughView {
    private let displayPreview: DisplayPreview
    private let horizontalShadowLine = CALayer()
    private let horizontalHighlightLine = CALayer()
    private let verticalShadowLine = CALayer()
    private let verticalHighlightLine = CALayer()
    private var cursorGlobalPoint: CGPoint?

    init(displayPreview: DisplayPreview) {
        self.displayPreview = displayPreview
        super.init(frame: CGRect(origin: .zero, size: displayPreview.snapshot.overlayFrame.size))
        wantsLayer = true
        configureLineLayer(horizontalShadowLine, color: NSColor.black.withAlphaComponent(0.65))
        configureLineLayer(horizontalHighlightLine, color: NSColor.white.withAlphaComponent(0.95))
        configureLineLayer(verticalShadowLine, color: NSColor.black.withAlphaComponent(0.65))
        configureLineLayer(verticalHighlightLine, color: NSColor.white.withAlphaComponent(0.95))
        layer?.addSublayer(horizontalShadowLine)
        layer?.addSublayer(verticalShadowLine)
        layer?.addSublayer(horizontalHighlightLine)
        layer?.addSublayer(verticalHighlightLine)
        hideLines()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    func refresh(cursorGlobalPoint: CGPoint?, isActivelyDraggingSelection: Bool) {
        guard self.cursorGlobalPoint != cursorGlobalPoint else {
            if isActivelyDraggingSelection {
                hideLines()
            }
            return
        }

        self.cursorGlobalPoint = cursorGlobalPoint

        guard let cursorGlobalPoint, !isActivelyDraggingSelection else {
            hideLines()
            return
        }

        let displayFrame = displayPreview.snapshot.frame
        let localPoint = overlayLocalPoint(fromCaptureGlobalPoint: cursorGlobalPoint, display: displayPreview.snapshot)
        let horizontalVisible = displayFrame.minY <= cursorGlobalPoint.y && cursorGlobalPoint.y <= displayFrame.maxY
        let verticalVisible = displayFrame.minX <= cursorGlobalPoint.x && cursorGlobalPoint.x <= displayFrame.maxX

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if horizontalVisible {
            let shadowRect = CGRect(x: bounds.minX, y: floor(localPoint.y - 1.5), width: bounds.width, height: 3)
            let highlightRect = CGRect(x: bounds.minX, y: floor(localPoint.y - 0.5), width: bounds.width, height: 1)
            horizontalShadowLine.frame = shadowRect
            horizontalHighlightLine.frame = highlightRect
            horizontalShadowLine.isHidden = false
            horizontalHighlightLine.isHidden = false
        } else {
            horizontalShadowLine.isHidden = true
            horizontalHighlightLine.isHidden = true
        }

        if verticalVisible {
            let shadowRect = CGRect(x: floor(localPoint.x - 1.5), y: bounds.minY, width: 3, height: bounds.height)
            let highlightRect = CGRect(x: floor(localPoint.x - 0.5), y: bounds.minY, width: 1, height: bounds.height)
            verticalShadowLine.frame = shadowRect
            verticalHighlightLine.frame = highlightRect
            verticalShadowLine.isHidden = false
            verticalHighlightLine.isHidden = false
        } else {
            verticalShadowLine.isHidden = true
            verticalHighlightLine.isHidden = true
        }

        CATransaction.commit()
    }

    private func hideLines() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        horizontalShadowLine.isHidden = true
        horizontalHighlightLine.isHidden = true
        verticalShadowLine.isHidden = true
        verticalHighlightLine.isHidden = true
        CATransaction.commit()
    }

    private func configureLineLayer(_ layer: CALayer, color: NSColor) {
        layer.backgroundColor = color.cgColor
        layer.actions = [
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull(),
            "hidden": NSNull()
        ]
    }
}

@MainActor
private final class RegionSelectionCursorOverlayView: RegionSelectionPassThroughView {
    private let displayPreview: DisplayPreview
    private let fallbackImage: CGImage
    private weak var livePreviewSource: LiveDesktopPreviewSource?
    private let overlayMode: RegionCaptureOverlayMode
    private var livePreviewObserverToken: UUID?
    private var cursorGlobalPoint: CGPoint?
    private var selectionRect: CGRect?
    private var isActivelyDraggingSelection = false

    init(displayPreview: DisplayPreview, fallbackImage: CGImage, livePreviewSource: LiveDesktopPreviewSource?, overlayMode: RegionCaptureOverlayMode) {
        self.displayPreview = displayPreview
        self.fallbackImage = fallbackImage
        self.livePreviewSource = livePreviewSource
        self.overlayMode = overlayMode
        super.init(frame: CGRect(origin: .zero, size: displayPreview.snapshot.overlayFrame.size))
        wantsLayer = true
        livePreviewObserverToken = livePreviewSource?.addObserver(for: displayPreview.snapshot.displayID) { [weak self] in
            self?.handleLivePreviewFrame()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    func refresh(cursorGlobalPoint: CGPoint?, selectionRect: CGRect?, isActivelyDraggingSelection: Bool) {
        guard self.cursorGlobalPoint != cursorGlobalPoint ||
                self.selectionRect != selectionRect ||
                self.isActivelyDraggingSelection != isActivelyDraggingSelection else {
            return
        }

        let previousCursorGlobalPoint = self.cursorGlobalPoint

        // Compute old dirty rects BEFORE updating state so loupeRect uses the previous
        // isActivelyDraggingSelection/selectionRect values. If state is updated first, the old
        // loupe position is computed with the new formula and the ghost loupe is never cleared.
        var dirtyRects = dirtyRectsForCursor(at: previousCursorGlobalPoint)

        self.cursorGlobalPoint = cursorGlobalPoint
        self.selectionRect = selectionRect
        self.isActivelyDraggingSelection = isActivelyDraggingSelection

        dirtyRects.append(contentsOf: dirtyRectsForCursor(at: cursorGlobalPoint))

        for rect in dirtyRects {
            let clippedRect = rect.intersection(bounds)

            guard !clippedRect.isNull, !clippedRect.isEmpty else {
                continue
            }

            setNeedsDisplay(clippedRect)
        }
    }

    private func handleLivePreviewFrame() {
        guard overlayMode.showsMagnifyingGlass,
              let cursorGlobalPoint,
              displayPreview.snapshot.frame.contains(cursorGlobalPoint) else {
            return
        }

        let localPoint = overlayLocalPoint(fromCaptureGlobalPoint: cursorGlobalPoint, display: displayPreview.snapshot)
        let dirtyRect = loupeDirtyRect(at: localPoint).insetBy(dx: -6, dy: -6).intersection(bounds)
        guard !dirtyRect.isNull, !dirtyRect.isEmpty else {
            return
        }

        setNeedsDisplay(dirtyRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)

        guard let cursorGlobalPoint else {
            return
        }

        if overlayMode.showsMagnifyingGlass,
           displayPreview.snapshot.frame.contains(cursorGlobalPoint) {
            drawLoupe(at: overlayLocalPoint(fromCaptureGlobalPoint: cursorGlobalPoint, display: displayPreview.snapshot))
        }
    }

    private func dirtyRectsForCursor(at globalPoint: CGPoint?) -> [CGRect] {
        guard let globalPoint else {
            return []
        }

        let displayFrame = displayPreview.snapshot.frame
        let localPoint = overlayLocalPoint(fromCaptureGlobalPoint: globalPoint, display: displayPreview.snapshot)
        var dirtyRects: [CGRect] = []

        if overlayMode.showsMagnifyingGlass,
           displayFrame.contains(globalPoint) {
            dirtyRects.append(loupeDirtyRect(at: localPoint).insetBy(dx: -6, dy: -6))
        }

        return dirtyRects
    }

    private func loupeDirtyRect(at localPoint: CGPoint) -> CGRect {
        let loupeRect = loupeRect(at: localPoint)

        return loupeRect.insetBy(dx: -12, dy: -12)
    }

    private func drawLoupe(at localPoint: CGPoint) {
        guard bounds.contains(localPoint) else {
            return
        }

        let previewImage = livePreviewSource?.image(for: displayPreview.snapshot.displayID) ?? fallbackImage
        let previewTransform = CapturePreviewTransform(
            displayTransform: displayPreview.snapshot.captureDisplayTransform,
            previewPixelSize: CGSize(width: previewImage.width, height: previewImage.height)
        )

        let cropSize: CGFloat = 20
        let logicalCropRect = gscCenteredCropRect(around: localPoint, size: cropSize, within: bounds)
        let imageSourceRect = previewTransform.appKitSourceRect(fromOverlayLocalRect: logicalCropRect)

        let loupeRect = loupeRect(at: localPoint)
        let imageRect = loupeRect.insetBy(dx: 10, dy: 10)
        let previewNSImage = NSImage(cgImage: previewImage, size: NSSize(width: previewImage.width, height: previewImage.height))
        let loupePath = NSBezierPath(roundedRect: loupeRect, xRadius: 18, yRadius: 18)

        NSGraphicsContext.current?.cgContext.saveGState()
        NSShadow().applyLoupeShadow()
        NSColor(calibratedWhite: 0.06, alpha: 0.96).setFill()
        loupePath.fill()
        NSGraphicsContext.current?.cgContext.restoreGState()

        NSGraphicsContext.current?.cgContext.saveGState()
        NSBezierPath(roundedRect: imageRect, xRadius: 12, yRadius: 12).addClip()

        let previousInterpolation = NSGraphicsContext.current?.imageInterpolation
        NSGraphicsContext.current?.imageInterpolation = .none
        previewNSImage.draw(
            in: imageRect,
            from: imageSourceRect,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.current?.imageInterpolation = previousInterpolation ?? .default
        NSGraphicsContext.current?.cgContext.restoreGState()

        NSColor.white.withAlphaComponent(0.92).setStroke()
        let border = NSBezierPath(roundedRect: loupeRect, xRadius: 18, yRadius: 18)
        border.lineWidth = 2
        border.stroke()

        NSColor.white.withAlphaComponent(0.22).setStroke()
        let innerBorder = NSBezierPath(roundedRect: imageRect, xRadius: 12, yRadius: 12)
        innerBorder.lineWidth = 1
        innerBorder.stroke()

        drawLoupeCaption(in: loupeRect)
    }

    private func loupeRect(at localPoint: CGPoint) -> CGRect {
        let loupeSize = CGSize(width: 132, height: 156)
        let horizontalPadding: CGFloat = 18
        let verticalPadding: CGFloat = 18
        let preferredX: CGFloat
        let preferredY: CGFloat

        if isActivelyDraggingSelection,
           let selectionRect {
            let localSelectionRect = overlayLocalRect(fromCaptureGlobalRect: selectionRect, display: displayPreview.snapshot)
            preferredX = localPoint.x <= localSelectionRect.midX
                ? localSelectionRect.maxX + 20
                : localSelectionRect.minX - loupeSize.width - 20
            preferredY = localSelectionRect.minY - loupeSize.height - 16
        } else {
            preferredX = localPoint.x < bounds.midX
                ? localPoint.x + 32
                : localPoint.x - loupeSize.width - 32
            preferredY = localPoint.y < bounds.midY
                ? localPoint.y + 28
                : localPoint.y - loupeSize.height - 28
        }

        let origin = CGPoint(
            x: min(max(preferredX, horizontalPadding), bounds.maxX - loupeSize.width - horizontalPadding),
            y: min(max(preferredY, verticalPadding), bounds.maxY - loupeSize.height - verticalPadding)
        )

        return CGRect(origin: origin, size: loupeSize)
    }

    private func drawLoupeCaption(in loupeRect: CGRect) {
        guard isActivelyDraggingSelection, let selectionRect else {
            return
        }

        let captionText = "\(Int(selectionRect.width.rounded())) × \(Int(selectionRect.height.rounded()))"
        NSString(string: captionText).draw(
            in: CGRect(x: loupeRect.minX + 12, y: loupeRect.maxY - 24, width: loupeRect.width - 24, height: 14),
            withAttributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.78),
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
            ]
        )
    }
}

private extension NSShadow {
    func applyLoupeShadow() {
        shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadowBlurRadius = 18
        shadowOffset = CGSize(width: 0, height: -6)
        set()
    }
}

private class RegionSelectionPassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private extension CGRect {
    var area: CGFloat {
        guard width > 0, height > 0 else {
            return 0
        }

        return width * height
    }
}

private func captureGlobalPoint(fromOverlayGlobalPoint overlayGlobalPoint: CGPoint, on display: DisplaySnapshot) -> CGPoint {
    display.captureDisplayTransform.captureGlobalPoint(fromOverlayGlobalPoint: overlayGlobalPoint)
}

private func overlayLocalPoint(fromCaptureGlobalPoint captureGlobalPoint: CGPoint, display: DisplaySnapshot) -> CGPoint {
    display.captureDisplayTransform.overlayLocalPoint(fromCaptureGlobalPoint: captureGlobalPoint)
}

private func overlayLocalRect(fromCaptureGlobalRect captureGlobalRect: CGRect, display: DisplaySnapshot) -> CGRect {
    display.captureDisplayTransform.overlayLocalRect(fromCaptureGlobalRect: captureGlobalRect)
}
