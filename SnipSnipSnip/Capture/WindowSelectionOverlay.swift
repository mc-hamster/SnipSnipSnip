import AppKit
import CoreGraphics

private enum WindowPickerDiagnostics {
    /// Window picking occurs before a capture finishes and can reveal titles,
    /// owners, and desktop geometry. Keep this legacy debug hook permanently
    /// non-emitting; capture-session diagnostics belong behind the explicit
    /// privacy-aware sink.
    nonisolated static func log(
        _ message: @autoclosure () -> String
    ) {
        _ = message
    }
}

nonisolated struct WindowSelectionPrompt {
    let instructionText: String
    let listButtonTitle: String?
    let windowLabel: @Sendable (CaptureWindowSummary) -> String

    static let capture = WindowSelectionPrompt(
        instructionText: "Hover a window, then click to capture. Esc cancels.",
        listButtonTitle: nil,
        windowLabel: \.displayTitle
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
    private let capabilities: AppCapabilitySnapshot
    private let accessibility: any AccessibilityPlatform
    private let screens: any ScreenTopologyProviding
    private let prompt: WindowSelectionPrompt
    private var continuation: CheckedContinuation<WindowSelectionOutcome, Never>?
    private var overlayWindows: [WindowSelectionWindow] = []

    init(
        snapshot: DesktopCompositeSnapshot,
        windows: [CaptureWindowSummary],
        capabilities: AppCapabilitySnapshot,
        accessibility: any AccessibilityPlatform = AccessibilityPlatformFactory.defaultPlatform(),
        screens: any ScreenTopologyProviding = SystemScreenTopologyService(),
        prompt: WindowSelectionPrompt = .capture
    ) {
        self.snapshot = snapshot
        self.windows = windows
        self.capabilities = capabilities
        self.accessibility = accessibility
        self.screens = screens
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
        NSApp.activate(ignoringOtherApps: true)

        // Normalize CGWindowList bounds against the active capture desktop union.
        // Mixed-height multi-display setups otherwise inherit the wrong top edge.
        let visibleBounds = visibleWindowBoundsSources(desktopFrame: snapshot.globalFrame)

        #if DEBUG
        WindowPickerDiagnostics.log("[WindowPicker] Diagnostics version: 2026-05-13-stale-highlight-fix-v6")
        WindowPickerDiagnostics.log("[WindowPicker] presentOverlay: \(windows.count) total windows")
        WindowPickerDiagnostics.log("[WindowPicker] Display previews: \(snapshot.displayPreviews.count)")
        #endif

        overlayWindows = snapshot.displayPreviews.compactMap { displayPreview in
            let displayWindows = windows.filter {
                let converted = resolvedOverlayScreenRect(
                    for: $0,
                    using: visibleBounds.converted,
                    storedBoundsSpace: .overlayScreen,
                    displayTransform: displayPreview.snapshot.captureDisplayTransform
                )
                let raw = resolvedOverlayScreenRect(
                    for: $0,
                    using: visibleBounds.raw,
                    storedBoundsSpace: .overlayScreen,
                    displayTransform: displayPreview.snapshot.captureDisplayTransform
                )
                return converted.intersects(displayPreview.snapshot.overlayFrame)
                    || raw.intersects(displayPreview.snapshot.overlayFrame)
            }
            
            #if DEBUG
            WindowPickerDiagnostics.log("[WindowPicker] Display \(displayPreview.snapshot.displayID): capture=\(displayPreview.snapshot.frame) overlay=\(displayPreview.snapshot.overlayFrame) -> \(displayWindows.count) windows")
            for w in displayWindows {
                WindowPickerDiagnostics.log("[WindowPicker]   - \(w.displayTitle)")
            }
            #endif
            
            let overlay = WindowSelectionWindow(
                displayPreview: displayPreview,
                windows: displayWindows,
                desktopFrame: snapshot.globalFrame,
                capabilities: capabilities,
                accessibility: accessibility,
                screens: screens,
                prompt: prompt
            ) { [weak self] outcome in
                self?.finish(with: outcome)
            }

            overlay.orderFrontRegardless()
            return overlay
        }

        overlayWindows.first?.makeKeyAndOrderFront(nil)
    }

    private func finish(with outcome: WindowSelectionOutcome) {
        let continuation = continuation
        self.continuation = nil
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = []
        continuation?.resume(returning: outcome)
    }
}

private final class WindowSelectionWindow: NSWindow {
    private let displayFrame: CGRect
    
    init(
        displayPreview: DisplayPreview,
        windows: [CaptureWindowSummary],
        desktopFrame: CGRect,
        capabilities: AppCapabilitySnapshot,
        accessibility: any AccessibilityPlatform,
        screens: any ScreenTopologyProviding,
        prompt: WindowSelectionPrompt,
        onComplete: @escaping (WindowSelectionOutcome) -> Void
    ) {
        self.displayFrame = displayPreview.snapshot.overlayFrame
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
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        contentView = WindowSelectionView(
            displayPreview: displayPreview,
            windows: windows,
            desktopFrame: desktopFrame,
            displayFrame: displayFrame,
            capabilities: capabilities,
            accessibility: accessibility,
            screens: screens,
            prompt: prompt,
            onComplete: onComplete
        )
        makeFirstResponder(contentView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class WindowSelectionView: NSView {
    private let windows: [CaptureWindowSummary]
    private let displayTransform: CaptureDisplayTransform
    private let accessibilityTransform: CaptureAccessibilityTransform?
    private let desktopFrame: CGRect
    private let displayFrame: CGRect
    private let capabilities: AppCapabilitySnapshot
    private let accessibility: any AccessibilityPlatform
    private let screens: any ScreenTopologyProviding
    private let prompt: WindowSelectionPrompt
    private let onComplete: (WindowSelectionOutcome) -> Void
    private var hoveredWindowID: CGWindowID?
    // Screen-space (AppKit) rect of the hovered window, refreshed each mouseMoved.
    private var hoveredScreenRect: CGRect?
    private var trackingAreaRef: NSTrackingArea?

    init(
        displayPreview: DisplayPreview,
        windows: [CaptureWindowSummary],
        desktopFrame: CGRect,
        displayFrame: CGRect,
        capabilities: AppCapabilitySnapshot,
        accessibility: any AccessibilityPlatform,
        screens: any ScreenTopologyProviding,
        prompt: WindowSelectionPrompt,
        onComplete: @escaping (WindowSelectionOutcome) -> Void
    ) {
        self.windows = windows
        self.displayTransform = displayPreview.snapshot.captureDisplayTransform
        self.capabilities = capabilities
        self.accessibility = accessibility
        self.screens = screens
        self.prompt = prompt
#if APP_STORE_BUILD
        self.accessibilityTransform = nil
#else
        self.accessibilityTransform = Self.makeAccessibilityTransform(for: displayPreview.snapshot, screens: screens)
#endif
        self.desktopFrame = desktopFrame.standardized
        self.displayFrame = displayFrame
        self.onComplete = onComplete
        super.init(frame: CGRect(origin: .zero, size: displayPreview.snapshot.overlayFrame.size))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Window capture targets")
        setAccessibilityHelp("Choose a visible window or open the list of capturable targets.")
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
            listButton.setAccessibilityHelp("Open a list of capturable targets.")
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

        let dimPath = NSBezierPath(rect: bounds)

        if let hoveredWindow = windows.first(where: { $0.id == hoveredWindowID }),
           let screenRect = hoveredScreenRect
        {
            let highlightRect = viewLocalRect(fromScreenRect: screenRect)
            
            #if DEBUG
            WindowPickerDiagnostics.log("[WindowPicker.draw] hoveredWindow: \(hoveredWindow.displayTitle)")
            WindowPickerDiagnostics.log("[WindowPicker.draw] screenRect: \(screenRect)")
            WindowPickerDiagnostics.log("[WindowPicker.draw] displayFrame: \(displayFrame)")
            WindowPickerDiagnostics.log("[WindowPicker.draw] bounds: \(bounds)")
            WindowPickerDiagnostics.log("[WindowPicker.draw] highlightRect (view-local): \(highlightRect)")
            #endif
            
            dimPath.append(NSBezierPath(roundedRect: highlightRect, xRadius: 14, yRadius: 14))
            dimPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.36).setFill()
            dimPath.fill()

            let fillPath = NSBezierPath(roundedRect: highlightRect, xRadius: 14, yRadius: 14)
            NSColor.systemBlue.withAlphaComponent(0.16).setFill()
            fillPath.fill()

            let borderPath = NSBezierPath(roundedRect: highlightRect, xRadius: 14, yRadius: 14)
            NSColor.systemBlue.setStroke()
            borderPath.lineWidth = 3
            borderPath.stroke()

            drawLabel(for: hoveredWindow, rect: highlightRect)
        } else {
            NSColor.black.withAlphaComponent(0.36).setFill()
            dimPath.fill()
        }

        let instructions = NSString(string: prompt.instructionText)
        instructions.draw(
            in: CGRect(x: 24, y: 24, width: 440, height: 24),
            withAttributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold)
            ]
        )
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(windowID: nil, screenRect: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        let screenPoint = appKitScreenPoint(from: event)
        let freshBounds = visibleWindowBoundsSources(desktopFrame: desktopFrame)
        let resolved = resolveWindow(at: screenPoint, boundsSources: freshBounds)
        updateHover(windowID: resolved?.window.id, screenRect: resolved?.screenRect)
    }

    override func mouseDown(with event: NSEvent) {
        let screenPoint = appKitScreenPoint(from: event)
        let freshBounds = visibleWindowBoundsSources(desktopFrame: desktopFrame)

        guard let selected = resolveWindow(at: screenPoint, boundsSources: freshBounds)?.window else {
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

    private func drawLabel(for window: CaptureWindowSummary, rect: CGRect) {
        let labelRect = CGRect(
            x: rect.minX,
            y: max(rect.minY - 54, 16),
            width: min(max(rect.width, 220), 420),
            height: 44
        )

        let background = NSBezierPath(roundedRect: labelRect, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.82).setFill()
        background.fill()

        let text = NSString(string: prompt.windowLabel(window))
        text.draw(
            in: labelRect.insetBy(dx: 14, dy: 10),
            withAttributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
            ]
        )
    }

    private func updateHover(windowID: CGWindowID?, screenRect: CGRect?) {
        guard hoveredWindowID != windowID || hoveredScreenRect != screenRect else {
            return
        }

        hoveredWindowID = windowID
        hoveredScreenRect = screenRect
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
        let boundsSources = visibleWindowBoundsSources(desktopFrame: desktopFrame)
        let targets = windows.compactMap { candidate -> WindowCaptureAccessibilityElement? in
            let convertedRect = resolvedOverlayScreenRect(
                for: candidate,
                using: boundsSources.converted,
                storedBoundsSpace: .overlayScreen,
                displayTransform: displayTransform
            )
            let rawRect = resolvedOverlayScreenRect(
                for: candidate,
                using: boundsSources.raw,
                storedBoundsSpace: .overlayScreen,
                displayTransform: displayTransform
            )
            let visibleRect = gscPreferredHighlightRect(
                primary: rawRect,
                alternate: convertedRect
            ).intersection(displayFrame)
            guard !visibleRect.isNull, visibleRect.width > 0, visibleRect.height > 0 else {
                return nil
            }
            return WindowCaptureAccessibilityElement(
                target: self,
                window: candidate,
                frame: visibleRect,
                isSelected: candidate.id == hoveredWindowID
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
        #if DEBUG
        WindowPickerDiagnostics.log("[WindowPicker.appKitScreenPoint] Event conversion:")
        WindowPickerDiagnostics.log("[WindowPicker.appKitScreenPoint]   event.locationInWindow: \(event.locationInWindow)")
        WindowPickerDiagnostics.log("[WindowPicker.appKitScreenPoint]   displayFrame: \(displayFrame)")
        if let window {
            WindowPickerDiagnostics.log("[WindowPicker.appKitScreenPoint]   actualWindowFrame: \(window.frame)")
        }
        WindowPickerDiagnostics.log("[WindowPicker.appKitScreenPoint]   Result screen point: \(screenPoint)")
        #endif
        return screenPoint
    }

    // Convert an AppKit screen-space rect to flipped view-local coordinates.
    // Use the real NSWindow placement when available so drawing stays aligned with
    // hit-testing even if the system nudges the overlay window.
    private func viewLocalRect(fromScreenRect screenRect: CGRect) -> CGRect {
        if let window {
            let windowRect = window.convertFromScreen(screenRect)
            let localRect = convert(windowRect, from: nil).gscIntegralStandardized

            #if DEBUG
            WindowPickerDiagnostics.log("[WindowPicker.viewLocalRect] Conversion:")
            WindowPickerDiagnostics.log("[WindowPicker.viewLocalRect]   screenRect: \(screenRect)")
            WindowPickerDiagnostics.log("[WindowPicker.viewLocalRect]   displayFrame: \(displayFrame)")
            WindowPickerDiagnostics.log("[WindowPicker.viewLocalRect]   actualWindowFrame: \(window.frame)")
            WindowPickerDiagnostics.log("[WindowPicker.viewLocalRect]   windowRect: \(windowRect)")
            WindowPickerDiagnostics.log("[WindowPicker.viewLocalRect]   Result: \(localRect)")

            return localRect
            #else
            return localRect
            #endif
        }

        #if DEBUG
        let localRect = CGRect(
            x: screenRect.minX - displayFrame.minX,
            y: displayFrame.maxY - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        ).gscIntegralStandardized
        
        WindowPickerDiagnostics.log("[WindowPicker.viewLocalRect] Conversion:")
        WindowPickerDiagnostics.log("[WindowPicker.viewLocalRect]   screenRect.minX=\(screenRect.minX) - displayFrame.minX=\(displayFrame.minX) = localX=\(localRect.minX)")
        WindowPickerDiagnostics.log("[WindowPicker.viewLocalRect]   displayFrame.maxY=\(displayFrame.maxY) - screenRect.maxY=\(screenRect.maxY) = localY=\(localRect.minY)")
        WindowPickerDiagnostics.log("[WindowPicker.viewLocalRect]   screenRect.maxY=\(screenRect.maxY), screenRect.minY=\(screenRect.minY)")
        WindowPickerDiagnostics.log("[WindowPicker.viewLocalRect]   Result: \(localRect)")
        
        return localRect
        #else
        return CGRect(
            x: screenRect.minX - displayFrame.minX,
            y: displayFrame.maxY - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        ).gscIntegralStandardized
        #endif
    }

    private func resolveWindow(
        at screenPoint: CGPoint,
        boundsSources: WindowBoundsSources
    ) -> (window: CaptureWindowSummary, screenRect: CGRect)? {
#if !APP_STORE_BUILD
        if capabilities.isEnabled(.accessibilityAutomation),
           let accessibilityResolved = resolveAccessibilityWindow(at: screenPoint, boundsSources: boundsSources) {
            return accessibilityResolved
        }
#endif

        let rawWindow = resolvedTopmostWindow(
            at: screenPoint,
            in: windows,
            using: boundsSources.raw,
            storedBoundsSpace: .overlayScreen,
            displayTransform: displayTransform
        )
        let convertedWindow = resolvedTopmostWindow(
            at: screenPoint,
            in: windows,
            using: boundsSources.converted,
            storedBoundsSpace: .overlayScreen,
            displayTransform: displayTransform
        )

        #if DEBUG
        let debugPrefix = "[WindowPicker]"
        WindowPickerDiagnostics.log("\(debugPrefix) Cursor at screen point: \(screenPoint)")
        WindowPickerDiagnostics.log("\(debugPrefix) Converted window: \(convertedWindow?.displayTitle ?? "nil")")
        WindowPickerDiagnostics.log("\(debugPrefix) Raw window: \(rawWindow?.displayTitle ?? "nil")")
        #endif

        switch (convertedWindow, rawWindow) {
        case (nil, nil):
            #if DEBUG
            WindowPickerDiagnostics.log("\(debugPrefix) No window found at cursor")
            #endif
            return nil
        case let (nil, window?):
            let rect = resolvedOverlayScreenRect(
                for: window,
                using: boundsSources.raw,
                storedBoundsSpace: .overlayScreen,
                displayTransform: displayTransform
            )
            #if DEBUG
            WindowPickerDiagnostics.log("\(debugPrefix) Using raw: \(window.displayTitle) at \(rect)")
            #endif
            return (window, rect)
        case let (window?, nil):
            let rect = resolvedOverlayScreenRect(
                for: window,
                using: boundsSources.converted,
                storedBoundsSpace: .overlayScreen,
                displayTransform: displayTransform
            )
            #if DEBUG
            WindowPickerDiagnostics.log("\(debugPrefix) Using converted: \(window.displayTitle) at \(rect)")
            if let sourceRect = boundsSources.converted[window.id], sourceRect != rect {
                WindowPickerDiagnostics.log("\(debugPrefix) Converted source rect: \(sourceRect)")
                WindowPickerDiagnostics.log("\(debugPrefix) Converted mapped rect: \(rect)")
            }
            #endif
            return (window, rect)
        case let (converted?, raw?):
            let convertedRect = resolvedOverlayScreenRect(
                for: converted,
                using: boundsSources.converted,
                storedBoundsSpace: .overlayScreen,
                displayTransform: displayTransform
            )
            let rawRect = resolvedOverlayScreenRect(
                for: raw,
                using: boundsSources.raw,
                storedBoundsSpace: .overlayScreen,
                displayTransform: displayTransform
            )

            let rawCoverage = overlayCoverage(for: rawRect)
            let convertedCoverage = overlayCoverage(for: convertedRect)
            #if DEBUG
            let debugPrefix = "[WindowPicker]"
            WindowPickerDiagnostics.log("\(debugPrefix) Raw: \(raw.displayTitle) at \(rawRect), coverage: \(rawCoverage)")
            WindowPickerDiagnostics.log("\(debugPrefix) Converted: \(converted.displayTitle) at \(convertedRect), coverage: \(convertedCoverage)")
            if let sourceRect = boundsSources.converted[converted.id], sourceRect != convertedRect {
                WindowPickerDiagnostics.log("\(debugPrefix) Converted source rect: \(sourceRect)")
                WindowPickerDiagnostics.log("\(debugPrefix) Converted mapped rect: \(convertedRect)")
            }
            #endif

            if raw.id == converted.id || rawCoverage > 0 {
                let highlightRect = gscPreferredHighlightRect(primary: rawRect, alternate: convertedRect)
                #if DEBUG
                WindowPickerDiagnostics.log("\(debugPrefix) Choosing raw bounds for \(raw.displayTitle)")
                WindowPickerDiagnostics.log("\(debugPrefix) Highlight rect: \(highlightRect)")
                #endif
                return (raw, highlightRect)
            }

            #if DEBUG
            WindowPickerDiagnostics.log("\(debugPrefix) Falling back to converted bounds for \(converted.displayTitle)")
            #endif
            return (converted, convertedRect)
        }
}

#if !APP_STORE_BUILD
    private func resolveAccessibilityWindow(
        at screenPoint: CGPoint,
        boundsSources: WindowBoundsSources
    ) -> (window: CaptureWindowSummary, screenRect: CGRect)? {
        guard accessibility.isProcessTrusted() else {
            return nil
        }

        let systemElement = accessibility.systemWideElement()
        var resolvedAccessibilityPoint: CGPoint?
        var resolvedWindowElement: AccessibilityElementHandle?

        for accessibilityPoint in accessibilityHitTestPoints(forOverlayScreenPoint: screenPoint) {
            let hitResult = accessibility.element(at: accessibilityPoint, from: systemElement)
            let hitElement = hitResult.element

            guard hitResult.status == .success,
                  let hitElement,
                  let windowElement = accessibilityWindowElement(startingAt: hitElement) else {
                continue
            }

            resolvedAccessibilityPoint = accessibilityPoint
            resolvedWindowElement = windowElement
            break
        }

        guard let accessibilityPoint = resolvedAccessibilityPoint,
              let windowElement = resolvedWindowElement else {
            return nil
        }

        let accessibilityRect = accessibilityAppKitScreenRect(of: windowElement)
        guard let window = resolveAccessibilityMatchedWindow(
            for: windowElement,
            at: screenPoint,
            accessibilityRect: accessibilityRect,
            boundsSources: boundsSources
        ) else {
            return nil
        }

        let rawRect = resolvedOverlayScreenRect(
            for: window,
            using: boundsSources.raw,
            storedBoundsSpace: .overlayScreen,
            displayTransform: displayTransform
        )
        let highlightRect = accessibilityRect.map { gscPreferredHighlightRect(primary: $0, alternate: rawRect) } ?? rawRect

        #if DEBUG
        WindowPickerDiagnostics.log("[WindowPicker] Accessibility resolved: \(window.displayTitle) id=\(window.id)")
        WindowPickerDiagnostics.log("[WindowPicker] Accessibility point: \(accessibilityPoint)")
        WindowPickerDiagnostics.log("[WindowPicker] Raw rect: \(rawRect)")
        if let accessibilityRect {
            WindowPickerDiagnostics.log("[WindowPicker] AX rect: \(accessibilityRect)")
            WindowPickerDiagnostics.log("[WindowPicker] AX highlight rect: \(highlightRect)")
        }
        #endif

        return (window, highlightRect)
    }

    private func resolveAccessibilityMatchedWindow(
        for windowElement: AccessibilityElementHandle,
        at screenPoint: CGPoint,
        accessibilityRect: CGRect?,
        boundsSources: WindowBoundsSources
    ) -> CaptureWindowSummary? {
        if let identity = accessibility.windowIdentity(for: windowElement),
           let matched = windows.first(where: { $0.id == identity.windowID }) {
            return matched
        }

        let ownerResult = accessibility.processIdentifier(for: windowElement)
        guard ownerResult.status == .success else {
            return nil
        }

        let candidates = windows.filter { $0.ownerPID == ownerResult.processID }
        guard !candidates.isEmpty else {
            return nil
        }

        if let accessibilityRect,
           let bestOverlap = candidates.max(by: { accessibilityMatchScore(for: $0, against: accessibilityRect, boundsSources: boundsSources) < accessibilityMatchScore(for: $1, against: accessibilityRect, boundsSources: boundsSources) }),
           accessibilityMatchScore(for: bestOverlap, against: accessibilityRect, boundsSources: boundsSources) > 0 {
            return bestOverlap
        }

        return resolvedTopmostWindow(
            at: screenPoint,
            in: candidates,
            using: boundsSources.raw,
            storedBoundsSpace: .overlayScreen,
            displayTransform: displayTransform
        )
            ?? resolvedTopmostWindow(
                at: screenPoint,
                in: candidates,
                using: boundsSources.converted,
                storedBoundsSpace: .overlayScreen,
                displayTransform: displayTransform
            )
            ?? candidates.min(by: { $0.focusRank < $1.focusRank })
    }

    private func accessibilityMatchScore(
        for window: CaptureWindowSummary,
        against accessibilityRect: CGRect,
        boundsSources: WindowBoundsSources
    ) -> CGFloat {
        let rawRect = resolvedOverlayScreenRect(
            for: window,
            using: boundsSources.raw,
            storedBoundsSpace: .overlayScreen,
            displayTransform: displayTransform
        )
        let convertedRect = resolvedOverlayScreenRect(
            for: window,
            using: boundsSources.converted,
            storedBoundsSpace: .overlayScreen,
            displayTransform: displayTransform
        )
        return max(overlapScore(between: rawRect, and: accessibilityRect), overlapScore(between: convertedRect, and: accessibilityRect))
    }

    private func overlapScore(between lhs: CGRect, and rhs: CGRect) -> CGFloat {
        let lhsArea = max(lhs.width, 0) * max(lhs.height, 0)
        let rhsArea = max(rhs.width, 0) * max(rhs.height, 0)
        let baseline = min(lhsArea, rhsArea)
        guard baseline > 0 else {
            return 0
        }

        let intersection = lhs.intersection(rhs)
        let intersectionArea = max(intersection.width, 0) * max(intersection.height, 0)
        return intersectionArea / baseline
    }

    private func accessibilityWindowElement(
        startingAt element: AccessibilityElementHandle
    ) -> AccessibilityElementHandle? {
        var current: AccessibilityElementHandle? = element
        var visited = Set<AccessibilityElementHandle>()

        while let candidate = current {
            guard visited.insert(candidate).inserted else {
                return nil
            }

            if let window = elementAttribute("AXWindow", from: candidate) {
                return window
            }

            if accessibilityRole(of: candidate) == "AXWindow" {
                return candidate
            }

            current = elementAttribute("AXParent", from: candidate)
        }

        return nil
    }

    private func accessibilityRole(of element: AccessibilityElementHandle) -> String? {
        attribute("AXRole", from: element) as? String
    }

    private func accessibilityHitTestPoints(forOverlayScreenPoint screenPoint: CGPoint) -> [CGPoint] {
        let capturePoint = displayTransform.captureGlobalPoint(fromOverlayGlobalPoint: screenPoint)
        guard let accessibilityTransform else {
            return [capturePoint]
        }

        let mappedPoint = accessibilityTransform.accessibilityPoint(fromCapturePoint: capturePoint)
        var points = [mappedPoint]
        if hypot(mappedPoint.x - capturePoint.x, mappedPoint.y - capturePoint.y) > 0.5 {
            points.append(capturePoint)
        }
        return points
    }

    private func accessibilityAppKitScreenRect(of element: AccessibilityElementHandle) -> CGRect? {
        guard let accessibilityRect = accessibilityFrame(of: element) else {
            return nil
        }

        if let accessibilityTransform {
            let captureRect = accessibilityTransform.captureRect(fromAccessibilityRect: accessibilityRect)
            let minPoint = displayTransform.overlayGlobalPoint(fromCaptureGlobalPoint: CGPoint(x: captureRect.minX, y: captureRect.maxY))
            let maxPoint = displayTransform.overlayGlobalPoint(fromCaptureGlobalPoint: CGPoint(x: captureRect.maxX, y: captureRect.minY))
            return CGRect(
                x: min(minPoint.x, maxPoint.x),
                y: min(minPoint.y, maxPoint.y),
                width: abs(maxPoint.x - minPoint.x),
                height: abs(maxPoint.y - minPoint.y)
            ).gscIntegralStandardized
        }

        let desktopFrame = screens.screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }.standardized
        return gscAppKitScreenRect(fromCGWindowBounds: accessibilityRect, desktopFrame: desktopFrame)
    }

    private func accessibilityFrame(of element: AccessibilityElementHandle) -> CGRect? {
        accessibility.frame(of: element)?.gscIntegralStandardized
    }

    private func attribute(_ name: String, from element: AccessibilityElementHandle) -> Any? {
        let result = accessibility.copyAttribute(name, from: element)
        return result.status == .success ? result.value : nil
    }

    private func elementAttribute(
        _ name: String,
        from element: AccessibilityElementHandle
    ) -> AccessibilityElementHandle? {
        attribute(name, from: element) as? AccessibilityElementHandle
    }

    private static func makeAccessibilityTransform(
        for snapshot: DisplaySnapshot,
        screens: any ScreenTopologyProviding
    ) -> CaptureAccessibilityTransform? {
        guard let screen = screens.screen(withDisplayID: snapshot.displayID) else {
            return nil
        }

        return CaptureAccessibilityTransform(
            captureFrame: snapshot.frame,
            accessibilityFrame: screen.frame
        )
    }
#endif

    private func overlayCoverage(for rect: CGRect) -> CGFloat {
        let area = max(rect.width, 0) * max(rect.height, 0)
        guard area > 0 else { return 0 }
        let intersection = rect.intersection(displayFrame)
        let overlap = max(intersection.width, 0) * max(intersection.height, 0)
        return overlap / area
    }
}

nonisolated private final class WindowCaptureAccessibilityElement: NSAccessibilityElement {
    weak var target: WindowSelectionView?
    private let windowID: CGWindowID

    init(
        target: WindowSelectionView,
        window: CaptureWindowSummary,
        frame: CGRect,
        isSelected: Bool
    ) {
        self.target = target
        self.windowID = window.id
        super.init()
        setAccessibilityParent(target)
        setAccessibilityRole(.button)
        setAccessibilityLabel(window.displayTitle)
        setAccessibilityValue(
            "\(Int(window.frame.width)) by \(Int(window.frame.height)) pixels"
        )
        setAccessibilitySelected(isSelected)
        setAccessibilityFrame(frame)
        setAccessibilityHelp("Press to capture this window.")
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

private struct WindowBoundsSources {
    let converted: [CGWindowID: CGRect]
    let raw: [CGWindowID: CGRect]
}

private enum StoredWindowBoundsSpace {
    case overlayScreen
    case captureGlobal
}

private func resolvedOverlayScreenRect(
    for window: CaptureWindowSummary,
    using boundsByID: [CGWindowID: CGRect],
    storedBoundsSpace: StoredWindowBoundsSpace,
    displayTransform: CaptureDisplayTransform
) -> CGRect {
    if let bounds = boundsByID[window.id] {
        switch storedBoundsSpace {
        case .overlayScreen:
            return bounds
        case .captureGlobal:
            return displayTransform.overlayGlobalRect(fromCaptureGlobalRect: bounds)
        }
    }

    return displayTransform.overlayGlobalRect(fromCaptureGlobalRect: window.frame)
}

private func resolvedTopmostWindow(
    at point: CGPoint,
    in windows: [CaptureWindowSummary],
    using boundsByID: [CGWindowID: CGRect],
    storedBoundsSpace: StoredWindowBoundsSpace,
    displayTransform: CaptureDisplayTransform
) -> CaptureWindowSummary? {
    windows
        .filter {
            resolvedOverlayScreenRect(
                for: $0,
                using: boundsByID,
                storedBoundsSpace: storedBoundsSpace,
                displayTransform: displayTransform
            ).contains(point)
        }
        .min { left, right in
            if left.focusRank != right.focusRank {
                return left.focusRank < right.focusRank
            }

            let leftBounds = resolvedOverlayScreenRect(
                for: left,
                using: boundsByID,
                storedBoundsSpace: storedBoundsSpace,
                displayTransform: displayTransform
            )
            let rightBounds = resolvedOverlayScreenRect(
                for: right,
                using: boundsByID,
                storedBoundsSpace: storedBoundsSpace,
                displayTransform: displayTransform
            )
            let leftArea = max(leftBounds.width, 0) * max(leftBounds.height, 0)
            let rightArea = max(rightBounds.width, 0) * max(rightBounds.height, 0)
            if leftArea != rightArea {
                return leftArea < rightArea
            }

            return left.id < right.id
        }
}

private func visibleWindowBoundsSources(screens: any ScreenTopologyProviding = SystemScreenTopologyService()) -> WindowBoundsSources {
    visibleWindowBoundsSources(desktopFrame: screens.screens.reduce(CGRect.null) { partialResult, screen in
        partialResult.union(screen.frame)
    })
}

private func visibleWindowBoundsSources(desktopFrame: CGRect) -> WindowBoundsSources {
    guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return WindowBoundsSources(converted: [:], raw: [:])
    }

    return WindowBoundsSources(
        converted: gscWindowBoundsByID(from: windowInfo, desktopFrame: desktopFrame),
        raw: rawWindowBoundsByID(from: windowInfo, desktopFrame: desktopFrame)
    )
}

private func rawWindowBoundsByID(from windowInfo: [[String: Any]], desktopFrame: CGRect) -> [CGWindowID: CGRect] {
    let normalizedDesktopFrame = desktopFrame.standardized

    return windowInfo.reduce(into: [:]) { partialResult, info in
        guard let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
              let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any] else {
            return
        }

        var bounds = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &bounds) else {
            return
        }

        partialResult[CGWindowID(windowNumber.uint32Value)] = gscAppKitScreenRect(
            fromCGWindowBounds: bounds,
            desktopFrame: normalizedDesktopFrame
        )
    }
}
