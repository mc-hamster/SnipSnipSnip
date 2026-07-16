import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

nonisolated struct GuideFrameComposition: @unchecked Sendable {
    let image: CGImage
    let sourceRect: CGRect
}

nonisolated struct GuideFrameComposer: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func compose(
        frame: GuideBufferedFrame,
        source: GuideCaptureSource,
        capturedDisplayFrame: CGRect,
        transientFrame: CGRect? = nil
    ) throws -> GuideFrameComposition {
        let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
        guard let fullImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw ScreenCapturePlatformError.imageUnavailable
        }
        let sourceRect = cropRect(for: source, displayFrame: capturedDisplayFrame, transientFrame: transientFrame)
        guard sourceRect != capturedDisplayFrame else {
            return GuideFrameComposition(image: fullImage, sourceRect: sourceRect)
        }
        let scaleX = CGFloat(fullImage.width) / capturedDisplayFrame.width
        let scaleY = CGFloat(fullImage.height) / capturedDisplayFrame.height
        let local = CGRect(
            x: (sourceRect.minX - capturedDisplayFrame.minX) * scaleX,
            y: (sourceRect.minY - capturedDisplayFrame.minY) * scaleY,
            width: sourceRect.width * scaleX,
            height: sourceRect.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height))
        guard local.width > 0, local.height > 0, let cropped = fullImage.cropping(to: local) else {
            throw ScreenCapturePlatformError.imageUnavailable
        }
        return GuideFrameComposition(image: cropped, sourceRect: sourceRect)
    }

    private func cropRect(for source: GuideCaptureSource, displayFrame: CGRect, transientFrame: CGRect?) -> CGRect {
        switch source {
        case .window(_, _, _, let frame):
            return expandedPrimaryFrame(frame, transientFrame: transientFrame, displayFrame: displayFrame)
        case .app(_, _, _, let initialFrame):
            return expandedPrimaryFrame(initialFrame, transientFrame: transientFrame, displayFrame: displayFrame)
        case .region(let rect): return rect.intersection(displayFrame)
        case .displays: return displayFrame
        }
    }

    private func expandedPrimaryFrame(_ primaryFrame: CGRect, transientFrame: CGRect?, displayFrame: CGRect) -> CGRect {
        var result = primaryFrame.insetBy(dx: -24, dy: -24)
        if let transientFrame, !transientFrame.isEmpty {
            // The Accessibility target is often a row inside a menu or picker. A generous
            // expansion retains the surrounding transient control without retaining the display.
            result = result.union(transientFrame.insetBy(dx: -48, dy: -48))
        }
        return result.intersection(displayFrame)
    }
}
