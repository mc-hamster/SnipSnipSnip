import AppKit

nonisolated struct CaptureSelectionMotionPolicy {
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increaseContrast: Bool

    var allowsCrawl: Bool { !reduceMotion }
    var allowsEntryFade: Bool { !reduceMotion && !reduceTransparency && !increaseContrast }
}

@MainActor
struct CaptureSelectionOutlineRenderer {
    func draw(in rect: CGRect, increaseContrast: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let border = NSBezierPath(rect: rect)
        // The opaque silver rail stays readable independently of its subtle
        // moving highlight; the dark keyline provides contrast on light content.
        NSColor.black.setStroke()
        border.lineWidth = increaseContrast ? 5 : 3
        border.stroke()
        NSColor(calibratedWhite: increaseContrast ? 1 : 0.76, alpha: 1).setStroke()
        border.lineWidth = increaseContrast ? 3 : 1.5
        border.stroke()
    }
}

@MainActor
enum CaptureSelectionOutlineAnimation {
    static let key = "region.windowHover.appear"

    static func update(
        on layer: CALayer,
        isVisible: Bool,
        animatesEntry: Bool,
        allowsAnimation: Bool,
        beginTime: CFTimeInterval
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.opacity = 1

        guard isVisible, allowsAnimation else {
            layer.removeAnimation(forKey: key)
            return
        }
        guard animatesEntry else { return }

        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = Float(0.7)
        appear.toValue = Float(1)
        appear.duration = 0.18
        appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // Each target change shares a clock across displays. The model stays
        // fully visible after this one short animation; there is no loop.
        appear.beginTime = layer.convertTime(beginTime, from: nil)
        layer.add(appear, forKey: key)
    }
}

/// Two tapered graphite markers travel in lockstep, half a perimeter apart,
/// around an unbroken silver rail. Each marker retains its bright leading tip.
@MainActor
enum CaptureSelectionBorderCrawl {
    static let key = "capture.windowHover.sheen"
    static let duration: CFTimeInterval = 4.8
    static let crawlerCount = 2
    static let layerCount = 8
    private static let lengthFactors: [CGFloat] = [1, 0.86, 0.72, 0.58, 0.44, 0.30, 0.16, 0.12]
    private static let opacities: [Float] = [0.10, 0.14, 0.19, 0.25, 0.33, 0.44, 0.60, 0.95]

    static func update(
        on layers: [CAShapeLayer],
        rect: CGRect?,
        allowsAnimation: Bool,
        increaseContrast: Bool = false,
        restarts: Bool,
        beginTime: CFTimeInterval
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let perimeter = rect.map { 2 * ($0.width + $0.height) } ?? 0
        guard let rect, allowsAnimation,
              rect.width > 0, rect.height > 0,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              perimeter.isFinite else {
            for layer in layers {
                layer.isHidden = true
                layer.removeAnimation(forKey: key)
            }
            return
        }
        let fullLength = perimeter * 0.10
        let spacing = perimeter / CGFloat(crawlerCount)
        let path = CGPath(rect: rect, transform: nil)
        for (index, layer) in layers.enumerated() {
            guard index < layerCount else { continue }
            let length = fullLength * lengthFactors[index]
            let isLeadingTip = index == layerCount - 1
            let offset = isLeadingTip ? fullLength - length : (fullLength - length) / 2
            layer.isHidden = false
            layer.path = path
            layer.fillColor = nil
            let markerColor = increaseContrast ? NSColor.black : NSColor(calibratedWhite: 0.12, alpha: 1)
            layer.strokeColor = (isLeadingTip ? NSColor.white : markerColor).cgColor
            layer.lineWidth = increaseContrast ? 3 : 1.5
            layer.lineCap = .round
            layer.opacity = opacities[index]
            layer.lineDashPattern = [NSNumber(value: Double(length)), NSNumber(value: Double(spacing - length))]
            layer.lineDashPhase = -offset
            // Two identical dash cycles fit the perimeter, keeping the crawlers
            // opposite each other with no loop jump or display-scale phase drift.
            if let existing = layer.animation(forKey: key) as? CABasicAnimation,
               !restarts,
               (existing.toValue as? NSNumber)?.doubleValue == Double(-offset - perimeter) {
                continue
            }
            let crawl = CABasicAnimation(keyPath: "lineDashPhase")
            crawl.fromValue = -offset
            crawl.toValue = -offset - perimeter
            crawl.duration = duration
            crawl.repeatCount = .infinity
            crawl.timingFunction = CAMediaTimingFunction(name: .linear)
            crawl.beginTime = layer.convertTime(beginTime, from: nil)
            layer.add(crawl, forKey: key)
        }
    }
}

@MainActor
enum CaptureSelectionAppearance {
    static func drawDimming(in bounds: CGRect, excluding targetRect: CGRect?) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        let dim = NSBezierPath(rect: bounds)
        if let targetRect, targetRect.intersects(bounds) {
            dim.append(NSBezierPath(rect: targetRect))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.32).setFill()
        dim.fill()
    }

    static func drawInstructions(_ text: String, in bounds: CGRect) {
        NSString(string: text).draw(
            in: CGRect(x: bounds.minX + 24, y: bounds.minY + 24, width: min(720, max(0, bounds.width - 48)), height: 64),
            withAttributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold)
            ]
        )
    }

    static func labelRect(for contentSize: CGSize, targetRect: CGRect, in bounds: CGRect) -> CGRect? {
        guard bounds.width > 24, bounds.height > 48 else { return nil }
        let width = min(max(contentSize.width + 20, 80), 384, bounds.width - 24)
        let height: CGFloat = 24
        let above = targetRect.minY - height - 6
        // Keep target names clear of the fixed instructions at the top left.
        let preferredY = above >= bounds.minY + 96 ? above : targetRect.maxY + 6
        return CGRect(
            x: min(max(targetRect.minX, bounds.minX + 12), bounds.maxX - width - 12),
            y: min(max(preferredY, bounds.minY + 12), bounds.maxY - height - 12),
            width: width,
            height: height
        )
    }

    static func drawLabel(_ text: String, targetRect: CGRect, in bounds: CGRect) {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let title = NSString(string: text)
        guard let rect = labelRect(for: title.size(withAttributes: [.font: font]), targetRect: targetRect, in: bounds) else { return }
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        NSColor.black.withAlphaComponent(opaque ? 1 : 0.82).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        title.draw(in: rect.insetBy(dx: 10, dy: 4), withAttributes: [
            .foregroundColor: NSColor.white,
            .font: font,
            .paragraphStyle: paragraph
        ])
    }
}

/// Decorative, click-through target feedback shared by Region and Window picking.
@MainActor
final class CaptureSelectionWindowHighlightView: NSView {
    private let renderer = CaptureSelectionOutlineRenderer()
    private let crawlLayers = (0..<CaptureSelectionBorderCrawl.layerCount).map { _ in CAShapeLayer() }
    private var outlineRect: CGRect?
    private var windowID: CGWindowID?
    private var label: String?
    private var transitionStartTime: CFTimeInterval = 0
    private var accessibilityDisplayObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for crawlLayer in crawlLayers {
            crawlLayer.frame = bounds
            crawlLayer.isHidden = true
            layer?.addSublayer(crawlLayer)
        }
        setAccessibilityElement(false)
        accessibilityDisplayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateAnimation()
                self?.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let accessibilityDisplayObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityDisplayObserver)
        }
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateCrawlBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateCrawlBackingScale()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for crawlLayer in crawlLayers { crawlLayer.frame = bounds }
        CATransaction.commit()
    }

    private func updateCrawlBackingScale() {
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for crawlLayer in crawlLayers { crawlLayer.contentsScale = scale }
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func refresh(windowID: CGWindowID?, rect: CGRect?, label: String?, transitionStartTime: CFTimeInterval) {
        let targetChanged = self.windowID != windowID
        guard outlineRect != rect || targetChanged || self.label != label else { return }
        outlineRect = rect
        self.windowID = windowID
        self.label = label
        self.transitionStartTime = transitionStartTime
        updateAnimation(animatesEntry: targetChanged)
        needsDisplay = true
    }

    private func updateAnimation(animatesEntry: Bool = false) {
        guard let layer else { return }
        let workspace = NSWorkspace.shared
        let motion = CaptureSelectionMotionPolicy(
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
        CaptureSelectionBorderCrawl.update(
            on: crawlLayers,
            rect: outlineRect,
            allowsAnimation: motion.allowsCrawl,
            increaseContrast: motion.increaseContrast,
            restarts: animatesEntry,
            beginTime: transitionStartTime
        )
        CaptureSelectionOutlineAnimation.update(
            on: layer,
            isVisible: outlineRect != nil,
            animatesEntry: animatesEntry,
            allowsAnimation: motion.allowsEntryFade,
            beginTime: transitionStartTime
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        guard let outlineRect else { return }
        NSBezierPath(rect: bounds).addClip()
        renderer.draw(in: outlineRect, increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        if let label {
            CaptureSelectionAppearance.drawLabel(label, targetRect: outlineRect, in: bounds)
        }
    }
}
