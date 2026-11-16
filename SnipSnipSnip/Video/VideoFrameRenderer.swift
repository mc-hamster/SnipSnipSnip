import AppKit
import AVFoundation
import CoreImage

/// Immutable render state. AVPlayer, image generation, and export all use this
/// renderer, including the same timing, cursor, and presentation geometry.
nonisolated final class VideoFrameRenderer: @unchecked Sendable {
    let outputSize: CGSize
    private let contentSize: CGSize
    private let contentRect: CGRect
    private let effects: VideoEffects
    private let interactions: VideoInteractionTrack?
    private let background: CIImage
    private let contentMask: CIImage
    private let cursorImage: CIImage
    private let clickImage: CIImage
    private let pointScale: Double
    private let shortcutImages: [String: CIImage]
    private let timeline: VideoEditTimeline?
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(document: EditableVideoDocument, contentSize: CGSize, cursorImage: CGImage,
         clickImage: CGImage, shortcutImages: [String: CGImage], timeline: VideoEditTimeline?) throws {
        let frameLimit: CGFloat = 16_384
        func validSize(_ size: CGSize) -> Bool {
            size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1
                && size.width <= frameLimit && size.height <= frameLimit && size.width * size.height <= 67_108_864
        }
        guard validSize(contentSize) else {
            throw VideoExportError.exportFailedWithReason("This video is too large to render safely. Use a smaller recording region or lower recording quality.")
        }
        self.contentSize = contentSize
        effects = document.session.effects
        interactions = document.recording.interactions
        self.timeline = timeline
        self.cursorImage = CIImage(cgImage: cursorImage)
        self.clickImage = CIImage(cgImage: clickImage)
        self.shortcutImages = shortcutImages.mapValues { CIImage(cgImage: $0) }
        pointScale = contentSize.width / max(document.recording.bounds.width, 1)
        let presentation = effects.presentation
        let size: CGSize
        let rect: CGRect
        let backdrop: CIImage
        if presentation.isEnabled {
            guard validSize(ScreenshotPresentationRenderer.layout(contentSize: contentSize, presentation: presentation).canvasSize) else {
                throw VideoExportError.exportFailedWithReason("This video background is too large to render safely. Reduce the space around the video or choose Match Video.")
            }
            guard let blankContext = SRGBBitmapContext.make(width: max(Int(contentSize.width), 1), height: max(Int(contentSize.height), 1)),
                  let blank = blankContext.makeImage(),
                  let result = ScreenshotPresentationRenderer.renderWithLayout(contentImage: blank, presentation: presentation) else {
                throw VideoExportError.exportFailed
            }
            size = result.layout.canvasSize
            let layoutRect = result.layout.contentRect
            rect = CGRect(x: layoutRect.minX, y: size.height - layoutRect.maxY, width: layoutRect.width, height: layoutRect.height)
            backdrop = CIImage(cgImage: result.image)
        } else {
            size = contentSize
            rect = CGRect(origin: .zero, size: size)
            backdrop = CIImage(color: .black).cropped(to: rect)
        }
        // H.264 requires even dimensions. Any rounding adds at most one background pixel.
        outputSize = CGSize(width: ceil(size.width / 2) * 2, height: ceil(size.height / 2) * 2)
        contentRect = rect
        background = backdrop.composited(over: CIImage(color: .black)).cropped(to: CGRect(origin: .zero, size: outputSize))
        let radius = presentation.isEnabled ? min(presentation.cornerRadius * rect.width / max(contentSize.width, 1), min(rect.width, rect.height) / 2) : 0
        guard let maskContext = SRGBBitmapContext.make(width: Int(outputSize.width), height: Int(outputSize.height)) else {
            throw VideoExportError.exportFailed
        }
        maskContext.setFillColor(CGColor(gray: 1, alpha: 1))
        maskContext.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        maskContext.fillPath()
        guard let mask = maskContext.makeImage() else { throw VideoExportError.exportFailed }
        contentMask = CIImage(cgImage: mask)
    }

    /// The source placement in the finished frame, using SwiftUI's top-left coordinates.
    var sourceRectInOutput: CGRect {
        CGRect(x: contentRect.minX, y: outputSize.height - contentRect.maxY,
               width: contentRect.width, height: contentRect.height)
    }

    func render(_ source: CIImage, at time: Double, applyingZooms: Bool = true) -> CIImage {
        let sourceTime = timeline?.sourceTime(for: time) ?? time
        let sourceBounds = CGRect(origin: .zero, size: contentSize)
        var image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .cropped(to: sourceBounds)
        if let track = interactions {
            if effects.showsClicks {
                for click in track.clicks where sourceTime >= click.time && sourceTime - click.time < 0.45 {
                    let progress = (sourceTime - click.time) / 0.45
                    let width = (32 + 26 * progress) * pointScale
                    let ring = placed(clickImage, center: click.position, width: width)
                        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - progress)])
                    image = ring.composited(over: image)
                }
            }
            if effects.showsCursor, let point = track.cursor(at: sourceTime, smooth: effects.smoothsCursor) {
                let width = 24 * effects.cursorScale * pointScale
                let scale = width / cursorImage.extent.width
                let cursor = cursorImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: point.x * contentSize.width,
                                                      y: (1 - point.y) * contentSize.height - cursorImage.extent.height * scale))
                image = cursor.composited(over: image)
            }
        }

        let focused = (applyingZooms ? zoomed(image, at: sourceTime) : image).cropped(to: sourceBounds)
        var content = focused
        if applyingZooms, effects.motionBlur > 0, effects.zooms.contains(where: { $0.amount(at: sourceTime) > 0 && $0.amount(at: sourceTime) < 1 }) {
            let offset = effects.motionBlur / 90
            let preceding = zoomed(image, at: max(sourceTime - offset, 0)).cropped(to: sourceBounds)
            content = focused.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: preceding, kCIInputTimeKey: 0.35])
        }
        content = content.transformed(by: CGAffineTransform(scaleX: contentRect.width / contentSize.width, y: contentRect.height / contentSize.height))
            .transformed(by: CGAffineTransform(translationX: contentRect.minX, y: contentRect.minY))
        var output = content.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: contentMask])
        if effects.showsShortcuts,
           let shortcut = interactions?.shortcuts.last(where: { $0.time <= sourceTime && sourceTime - $0.time < 1.6 }),
           let badge = shortcutImages[shortcut.label] {
            let scale = min(pointScale, outputSize.width / 640)
            let scaled = badge.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            output = scaled.transformed(by: CGAffineTransform(translationX: (outputSize.width - scaled.extent.width) / 2, y: 24 * scale)).composited(over: output)
        }
        return output.cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    func cgImage(_ image: CGImage, at time: Double, applyingZooms: Bool = true) -> CGImage? {
        let output = render(CIImage(cgImage: image), at: time, applyingZooms: applyingZooms)
        return context.createCGImage(output, from: output.extent)
    }

    private func zoomed(_ image: CIImage, at time: Double) -> CIImage {
        guard let zoom = effects.zooms.last(where: { $0.start <= time && time <= $0.end }) else { return image }
        let geometry = VideoZoomGeometry.resolve(zoom, at: time, interactions: interactions)
        let scale = geometry.scale
        let center = geometry.center
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: contentSize.width * (0.5 - center.x * scale),
                                              y: contentSize.height * (0.5 - (1 - center.y) * scale)))
    }

    private func placed(_ image: CIImage, center: VideoPoint, width: Double) -> CIImage {
        let scale = width / image.extent.width
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: center.x * contentSize.width - width / 2,
                                              y: (1 - center.y) * contentSize.height - width / 2))
    }
}

@MainActor
enum VideoRenderAssets {
    static func cursor() throws -> CGImage {
        // Draw at the actual hot spot so click highlights and zoom targets agree.
        guard let context = SRGBBitmapContext.make(width: 48, height: 64) else { throw VideoExportError.exportFailed }
        context.translateBy(x: 0, y: 64)
        context.scaleBy(x: 2, y: -2)
        context.move(to: CGPoint(x: 1, y: 1))
        context.addLines(between: [CGPoint(x: 1, y: 25), CGPoint(x: 7, y: 19), CGPoint(x: 12, y: 30), CGPoint(x: 17, y: 28), CGPoint(x: 12, y: 17), CGPoint(x: 21, y: 17)])
        context.closePath()
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1.3)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        guard let image = context.makeImage() else { throw VideoExportError.exportFailed }
        return image
    }

    static func click() throws -> CGImage {
        guard let context = SRGBBitmapContext.make(width: 96, height: 96) else { throw VideoExportError.exportFailed }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(5)
        context.strokeEllipse(in: CGRect(x: 5, y: 5, width: 86, height: 86))
        guard let image = context.makeImage() else { throw VideoExportError.exportFailed }
        return image
    }

    static func shortcuts(_ track: VideoInteractionTrack?) -> [String: CGImage] {
        var result: [String: CGImage] = [:]
        for label in Set(track?.shortcuts.map(\.label) ?? []) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.white]
            let text = NSAttributedString(string: label, attributes: attributes)
            let size = text.size()
            let image = NSImage(size: CGSize(width: size.width + 32, height: 48), flipped: false) { rect in
                NSColor.black.withAlphaComponent(0.82).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
                text.draw(at: CGPoint(x: 16, y: (48 - size.height) / 2))
                return true
            }
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { result[label] = cgImage }
        }
        return result
    }
}
