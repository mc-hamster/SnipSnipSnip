import CoreGraphics
import Foundation
import ImageIO

/// Keeps long Guides from retaining a decoded display-sized backing store for
/// every step. PNG-backed CGImages decode on demand, while the HUD and editor
/// lists use small dedicated thumbnails.
nonisolated enum GuideImageMemory {
    static func compressedCopy(of image: CGImage) -> CGImage? {
        guard let data = try? ImageExporter.pngData(for: image),
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary)
    }

    static func thumbnail(of image: CGImage, maximumPixelDimension: Int = 240) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maximumPixelDimension else { return image }
        let scale = CGFloat(maximumPixelDimension) / CGFloat(longest)
        let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Serializes thumbnail rendering so opening a long Guide cannot start hundreds
/// of decoded-image jobs at once. Visible rows still publish independently as
/// soon as each thumbnail is ready.
actor GuideThumbnailLoader {
    func thumbnail(of image: CGImage) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return GuideImageMemory.thumbnail(of: image)
    }
}
