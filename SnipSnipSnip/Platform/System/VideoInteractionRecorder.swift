import AppKit
import Carbon
import CoreMedia

/// Sampling pointer position requires no Accessibility permission. Only explicitly
/// enabled shortcut recording uses an event monitor, and never captures typed text.
@MainActor
final class VideoInteractionRecorder: ScreenRecordingPlatformFrameSink, @unchecked Sendable {
    nonisolated private let originLock = NSLock()
    nonisolated(unsafe) private var firstFrameTime: Double?
    private let target: ScreenRecordingTarget
    private var bounds: CGRect
    private var track = VideoInteractionTrack()
    private var timer: Timer?
    private var keyboardMonitor: Any?
    private var mouseMonitor: Any?
    private var wasPressed = false
    private var lastClickTime = -1.0
    private var lastGeometryUpdate = -1.0

    init(target: ScreenRecordingTarget) {
        self.target = target
        if let source = target.sourceRect {
            bounds = source.offsetBy(dx: target.contentBounds.minX, dy: target.contentBounds.minY)
        } else {
            bounds = target.contentBounds
        }
    }

    isolated deinit {
        timer?.invalidate()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    nonisolated func recordingPlatformDidOutputFrame(_ frame: GuideBufferedFrame) {
        originLock.lock()
        if firstFrameTime == nil { firstFrameTime = frame.timestamp.seconds }
        originLock.unlock()
    }

    func begin(recordsShortcuts: Bool) {
        _ = finish()
        track = VideoInteractionTrack()
        originLock.lock()
        firstFrameTime = nil
        originLock.unlock()
        wasPressed = CGEventSource.buttonState(.combinedSessionState, button: .left)
        lastClickTime = -1
        lastGeometryUpdate = -1
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordClick() }
        }
        if recordsShortcuts,
           AccessibilityPlatformFactory.defaultPlatform().isProcessTrusted() {
            keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.recordShortcut(event) }
            }
        }
    }

    func finish() -> VideoInteractionTrack {
        timer?.invalidate()
        timer = nil
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyboardMonitor = nil
        mouseMonitor = nil
        return track
    }

    private var time: Double? {
        originLock.lock()
        let origin = firstFrameTime
        originLock.unlock()
        return origin.map { max(CMClockGetTime(CMClockGetHostTimeClock()).seconds - $0, 0) }
    }

    private var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func point(_ location: CGPoint) -> VideoPoint {
        VideoPoint(x: (location.x - bounds.minX) / max(bounds.width, 1),
                   y: (location.y - bounds.minY) / max(bounds.height, 1))
    }

    private func sample() {
        guard let time else { return }
        if case .window(let id) = target.source, time - lastGeometryUpdate > 0.2 {
            lastGeometryUpdate = time
            if let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
               let dictionary = windows.first?[kCGWindowBounds as String] as? [String: Any],
               let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
                bounds = frame
            }
        }
        let location = pointer
        let pressed = CGEventSource.buttonState(.combinedSessionState, button: .left)
        if pressed && !wasPressed { recordClick() }
        wasPressed = pressed
        let sample = VideoCursorSample(time: time, position: point(location), visible: bounds.contains(location))
        // Stationary samples are sparse, but keep boundary samples for interpolation.
        if let previous = track.samples.last,
           previous.position == sample.position, previous.visible == sample.visible,
           time - previous.time < 0.15 { return }
        track.samples.append(sample)
    }

    private func recordClick() {
        guard let time, time - lastClickTime > 0.08, bounds.contains(pointer) else { return }
        track.clicks.append(VideoClick(time: time, position: point(pointer)))
        lastClickTime = time
    }

    private func recordShortcut(_ event: NSEvent) {
        guard let time, !IsSecureEventInputEnabled(), !event.isARepeat, bounds.contains(pointer),
              event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control),
              let key = Self.shortcutKeyNames[event.keyCode] else { return }
        let flags = event.modifierFlags
        let label = (flags.contains(.control) ? "⌃" : "")
            + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "") + key
        track.shortcuts.append(VideoShortcut(time: time, label: label))
    }

    private static let shortcutKeyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 36: "↩", 48: "⇥",
        49: "Space", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
