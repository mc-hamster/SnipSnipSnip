import AppKit

nonisolated struct RegionSelectionWindowHover: Equatable {
    let window: CaptureWindowSummary

    static func resolve(
        at cursorGlobalPoint: CGPoint?,
        in windows: [CaptureWindowSummary],
        selectionRect: CGRect?,
        isInteracting: Bool
    ) -> Self? {
        guard selectionRect == nil, !isInteracting, let cursorGlobalPoint,
              let window = gscTopmostWindow(at: cursorGlobalPoint, in: windows) else {
            return nil
        }
        return Self(window: window)
    }

    func localOutlineRect(on display: DisplaySnapshot) -> CGRect? {
        guard window.frame.intersects(display.frame) else { return nil }
        // Transform the full window before clipping in the view. A window spanning
        // displays must not acquire a false border at the seam between them.
        return display.captureDisplayTransform.overlayLocalRect(fromCaptureGlobalRect: window.frame)
    }
}

@MainActor
struct RegionSelectionWindowOutlineRenderer {
    static func accentLineWidth(increaseContrast: Bool) -> CGFloat {
        increaseContrast ? 3 : 1
    }

    func draw(in rect: CGRect, increaseContrast: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let border = NSBezierPath(rect: rect)
        // Opaque light and dark edges keep the hint visible over any desktop
        // content, independently of accent color and transparency preferences.
        NSColor.black.setStroke()
        border.lineWidth = increaseContrast ? 7 : 5
        border.stroke()
        NSColor.white.setStroke()
        border.lineWidth = increaseContrast ? 5 : 3
        border.stroke()
        NSColor.controlAccentColor.setStroke()
        border.lineWidth = Self.accentLineWidth(increaseContrast: increaseContrast)
        border.stroke()
    }
}

@MainActor
enum RegionSelectionWindowOutlineAnimation {
    static let key = "region.windowHover.crawl"

    static func update(
        on layer: CAShapeLayer,
        isVisible: Bool,
        reduceMotion: Bool,
        increaseContrast: Bool,
        beginTime: CFTimeInterval
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.fillColor = nil
        layer.strokeColor = NSColor.white.cgColor
        layer.lineWidth = RegionSelectionWindowOutlineRenderer.accentLineWidth(increaseContrast: increaseContrast)
        layer.lineDashPattern = [6, 10]
        layer.isHidden = !isVisible || reduceMotion

        guard !layer.isHidden else {
            layer.removeAnimation(forKey: key)
            return
        }
        guard layer.animation(forKey: key) == nil else { return }

        let crawl = CABasicAnimation(keyPath: "lineDashPhase")
        crawl.fromValue = CGFloat(0)
        crawl.toValue = CGFloat(-16)
        crawl.duration = 2.8
        crawl.repeatCount = .infinity
        crawl.timingFunction = CAMediaTimingFunction(name: .linear)
        // One full dash period makes each loop seamless. All displays share the
        // session clock, and moving the pointer never restarts the crawl.
        crawl.beginTime = layer.convertTime(beginTime, from: nil)
        layer.add(crawl, forKey: key)
    }
}
