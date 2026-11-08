import AppKit
import CryptoKit
import ImageIO

nonisolated enum ClipboardImageIdentity {
    /// Compare lossless image copies in a fixed pixel format, independent of
    /// encoding, metadata, or the additional formats offered by the source app.
    static func pixelHash(for data: Data, pasteboardItems: [PasteboardItemSnapshot]) -> String? {
        // The preview represents only the first item/page/frame. Keep complete
        // payload identity for selections, documents, vectors, and animations.
        guard pasteboardItems.count <= 1,
              !pasteboardItems.flatMap(\.representations).contains(where: { representation in
                  if [NSPasteboard.PasteboardType.pdf.rawValue, "public.svg-image"].contains(representation.typeIdentifier) {
                      return true
                  }
                  guard let source = CGImageSourceCreateWithData(representation.data as CFData, nil) else { return false }
                  return CGImageSourceGetCount(source) > 1
              }),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let pixels = context.data else { return nil }

        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var hasher = SHA256()
        hasher.update(data: Data("ClipboardImagePixels.v1:\(image.width)x\(image.height):".utf8))
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: pixels, count: context.bytesPerRow * image.height))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
