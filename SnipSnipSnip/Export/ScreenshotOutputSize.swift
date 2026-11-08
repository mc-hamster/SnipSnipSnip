import CoreGraphics
import Foundation

nonisolated enum ScreenshotOutputSize: Equatable, Sendable {
    case original
    case half
    case customWidth(Int)

    static let maximumDimension = 32_768
    static let maximumPixelCount = 64_000_000

    func pixelSize(for original: CGSize) throws -> CGSize {
        guard original.width.isFinite, original.height.isFinite,
              original.width > 0, original.height > 0 else { throw ScreenshotOutputSizeError.invalidSize }
        let source = CGSize(width: original.width.rounded(.up), height: original.height.rounded(.up))
        let result: CGSize
        switch self {
        case .original: return source
        case .half:
            result = CGSize(width: max(1, (source.width / 2).rounded(.down)), height: max(1, (source.height / 2).rounded(.down)))
        case let .customWidth(width):
            guard width > 0, width <= Self.maximumDimension else { throw ScreenshotOutputSizeError.invalidSize }
            result = CGSize(width: CGFloat(width), height: max(1, (CGFloat(width) * source.height / source.width).rounded()))
        }
        guard result.width <= CGFloat(Self.maximumDimension), result.height <= CGFloat(Self.maximumDimension),
              result.width * result.height <= CGFloat(Self.maximumPixelCount) else { throw ScreenshotOutputSizeError.tooLarge }
        return result
    }

    func resized(_ image: CGImage) throws -> CGImage {
        let original = CGSize(width: image.width, height: image.height)
        let size = try pixelSize(for: original)
        guard size != original else { return image }
        guard let context = SRGBBitmapContext.make(width: Int(size.width), height: Int(size.height)) else {
            throw ScreenshotOutputError.renderingFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let resized = context.makeImage() else { throw ScreenshotOutputError.renderingFailed }
        return resized
    }

    var label: String {
        switch self {
        case .original: String(localized: "Original Size")
        case .half: String(localized: "Half Size")
        case .customWidth: String(localized: "Custom Width")
        }
    }
}

nonisolated enum ScreenshotOutputSizeError: LocalizedError {
    case invalidSize
    case tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidSize: "Enter a width from 1 to 32,768 pixels."
        case .tooLarge: "Choose a smaller width. Resized output is limited to 32,768 pixels per side and 64 million pixels in total."
        }
    }
}
