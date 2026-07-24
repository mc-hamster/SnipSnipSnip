import AppKit
import Carbon
import CoreGraphics
import CoreMedia
import Foundation

nonisolated enum GuideEventMonitorError: LocalizedError {
    case accessibilityRequired

    var errorDescription: String? {
        "Guide needs Accessibility access to observe clicks, scrolling, and shortcuts. Open System Settings > Privacy & Security > Accessibility, enable \(AppBranding.displayName), then try again."
    }
}

#if !APP_STORE_BUILD
@MainActor
final class GuideEventMonitor {
    typealias Handler = @MainActor (GuideObservedEvent, CMTime) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitors: [Any] = []
    private var handler: Handler?
    // The event tap and AppKit fallback can be delivered at slightly different
    // times. Keep button state independently so a delayed duplicate cannot
    // replace a rapid click before its own mouse-up is handled.
    private var pendingMouseDowns: [Int: (GuideObservedEvent, CMTime)] = [:]
    private var draggedButtons: Set<Int> = []
    private var latestDragEvents: [Int: GuideObservedEvent] = [:]
    private var lastFinalizedMouseUp: (button: Int, timestamp: TimeInterval)?
    private var lastObservedEvent: GuideObservedEvent?

    func start(handler: @escaping Handler) throws {
        stop()
        self.handler = handler
        // A sandboxed listen-only tap can be created and enabled successfully yet deliver no
        // events. Keep the AppKit monitor active as a live fallback; receiveObserved(_:) removes
        // the duplicate when both APIs report the same underlying event.
        let installedEventTap = installEventTap()
        let installedGlobalMonitor = installGlobalMonitors()
        if installedEventTap || installedGlobalMonitor { return }
        self.handler = nil
        throw GuideEventMonitorError.accessibilityRequired
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        globalMonitors.forEach(NSEvent.removeMonitor)
        globalMonitors.removeAll()
        handler = nil
        pendingMouseDowns.removeAll()
        draggedButtons.removeAll()
        latestDragEvents.removeAll()
        lastFinalizedMouseUp = nil
        lastObservedEvent = nil
    }

    private func installEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<GuideEventMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                // The source is installed on the main run loop. Consume the borrowed CGEvent
                // synchronously because it is not guaranteed to survive an asynchronous hop.
                MainActor.assumeIsolated {
                    monitor.receive(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func installGlobalMonitors() -> Bool {
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
            .scrollWheel, .swipe, .keyDown, .mouseMoved
        ]
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }) else { return false }
        globalMonitors = [monitor]
        return true
    }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        let location = event.location
        let time = TimeInterval(event.timestamp) / 1_000_000_000
        let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
        if [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) {
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            draggedButtons.insert(button)
            let observed = GuideObservedEvent(timestamp: time, location: location, payload: .cursorMoved)
            latestDragEvents[button] = observed
            handler?(observed, timestamp)
            return
        }
        if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type) {
            finishMouseDown(button: Int(event.getIntegerValueField(.mouseEventButtonNumber)), timestamp: time, captureTimestamp: timestamp)
            return
        }
        let payload: GuideObservedEvent.Payload
        switch type {
        case .mouseMoved:
            payload = .cursorMoved
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            payload = .mouseDown(
                button: Int(event.getIntegerValueField(.mouseEventButtonNumber)),
                clickCount: Int(event.getIntegerValueField(.mouseEventClickState))
            )
        case .scrollWheel:
            payload = .scroll(
                deltaX: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                deltaY: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            )
        case .keyDown:
            guard !IsSecureEventInputEnabled() else { return }
            let nsEvent = NSEvent(cgEvent: event)
            payload = .keyDown(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: event.flags.rawValue,
                characters: nsEvent?.charactersIgnoringModifiers,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        default: return
        }
        let observed = GuideObservedEvent(timestamp: time, location: location, payload: payload)
        receiveObserved(observed, timestamp: timestamp)
    }

    private func receiveObserved(_ observed: GuideObservedEvent, timestamp: CMTime) {
        if let previous = lastObservedEvent,
           previous.payload == observed.payload,
           abs(previous.timestamp - observed.timestamp) < 0.002,
           hypot(previous.location.x - observed.location.x, previous.location.y - observed.location.y) < 0.5 {
            return
        }
        lastObservedEvent = observed
        let payload = observed.payload
        if case .mouseDown(let button, _) = payload {
            pendingMouseDowns[button] = (observed, timestamp)
            draggedButtons.remove(button)
            latestDragEvents[button] = nil
        } else {
            handler?(observed, timestamp)
        }
    }

    private func receive(_ event: NSEvent) {
        let timestampValue = event.cgEvent
            .map { TimeInterval($0.timestamp) / 1_000_000_000 }
            ?? ProcessInfo.processInfo.systemUptime
        let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
        let location = event.cgEvent?.location
            ?? CursorCaptureGeometry.captureGlobalPoint(fromAppKitGlobalPoint: NSEvent.mouseLocation)
            ?? NSEvent.mouseLocation
        if [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type) {
            draggedButtons.insert(event.buttonNumber)
            let observed = GuideObservedEvent(timestamp: timestampValue, location: location, payload: .cursorMoved)
            latestDragEvents[event.buttonNumber] = observed
            handler?(observed, timestamp)
            return
        }
        if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type) {
            finishMouseDown(button: event.buttonNumber, timestamp: timestampValue, captureTimestamp: timestamp)
            return
        }
        let payload: GuideObservedEvent.Payload
        switch event.type {
        case .mouseMoved:
            payload = .cursorMoved
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            payload = .mouseDown(button: event.buttonNumber, clickCount: event.clickCount)
        case .scrollWheel:
            payload = .scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        case .swipe:
            payload = .swipe(deltaX: event.deltaX, deltaY: event.deltaY)
        case .keyDown:
            guard !IsSecureEventInputEnabled() else { return }
            payload = .keyDown(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue), characters: event.charactersIgnoringModifiers, isRepeat: event.isARepeat)
        default: return
        }
        let observed = GuideObservedEvent(timestamp: timestampValue, location: location, payload: payload)
        receiveObserved(observed, timestamp: timestamp)
    }

    private func finishMouseDown(button: Int, timestamp: TimeInterval, captureTimestamp: CMTime) {
        // The event tap and global monitor both receive mouse-up. Ignore the
        // second delivery rather than allowing it to consume a later click.
        if let lastFinalizedMouseUp,
           lastFinalizedMouseUp.button == button,
           abs(lastFinalizedMouseUp.timestamp - timestamp) < 0.002 {
            return
        }
        lastFinalizedMouseUp = (button, timestamp)
        defer {
            pendingMouseDowns[button] = nil
            draggedButtons.remove(button)
            latestDragEvents[button] = nil
        }
        guard let pending = pendingMouseDowns[button] else { return }
        if button == 0, draggedButtons.contains(button), let drag = latestDragEvents[button] {
            handler?(GuideObservedEvent(timestamp: drag.timestamp, location: drag.location, payload: .selection), captureTimestamp)
        } else if !draggedButtons.contains(button) {
            handler?(pending.0, pending.1)
        }
    }
}
#else
@MainActor
final class GuideEventMonitor {
    typealias Handler = @MainActor (GuideObservedEvent, CMTime) -> Void

    func start(handler: @escaping Handler) throws {
        _ = handler
        throw GuideEventMonitorError.accessibilityRequired
    }

    func stop() {}
}
#endif
